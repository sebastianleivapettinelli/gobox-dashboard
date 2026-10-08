-- ============================================================================
-- GO BOX · reposiciones_v1.sql  (para index_v7.html, pestaña "Reponer")
-- Ejecutar UNA vez en Supabase → SQL Editor. Es idempotente: se puede volver a correr.
-- No modifica datos existentes: solo crea la tabla reposiciones y la función registrar_reposicion.
--
-- Qué hace:
--   reposiciones            una fila por reposición (máquina + hora local de Chile + detalle por espacio)
--   registrar_reposicion()  en UNA transacción: guarda la reposición y deja cantidad_asignada = "Dejé"
--                           en cada espacio. Si algo falla, no queda nada a medias.
-- La bodega (inventario_bodega) NO se toca.
-- ============================================================================

create table if not exists public.reposiciones (
    id                uuid primary key default gen_random_uuid(),
    maquina_id        text not null,                 -- maquinas.id como texto
    fecha_hora_local  text not null                  -- 'YYYY-MM-DDTHH:MM', hora de Chile (mismo formato que CONTEO_BASE)
                      check (fecha_hora_local ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$'),
    detalle           jsonb not null default '[]'::jsonb,
        -- [{ asignacion_id, espacio, sku, base_anterior, cargado_anterior, encontrado, final }, ...]
    notas             text,
    usuario           text,
    user_id           uuid default auth.uid(),
    created_at        timestamptz not null default now()
);

create index if not exists reposiciones_maquina_fecha_idx
    on public.reposiciones (maquina_id, fecha_hora_local desc);

-- Seguridad: solo usuarios con sesión iniciada. Sin UPDATE ni DELETE desde la app
-- (es un registro de auditoría; un error se corrige con una nueva reposición).
alter table public.reposiciones enable row level security;
revoke all on public.reposiciones from anon;
grant select, insert on public.reposiciones to authenticated;

drop policy if exists "reposiciones_select_autenticados" on public.reposiciones;
create policy "reposiciones_select_autenticados" on public.reposiciones
    for select to authenticated using (true);

drop policy if exists "reposiciones_insert_autenticados" on public.reposiciones;
create policy "reposiciones_insert_autenticados" on public.reposiciones
    for insert to authenticated with check (true);

-- ----------------------------------------------------------------------------
-- registrar_reposicion: inserta la reposición y actualiza las cantidades.
-- SECURITY INVOKER: corre con los permisos (y RLS) del usuario que inició sesión.
-- ----------------------------------------------------------------------------
create or replace function public.registrar_reposicion(
    p_maquina_id        text,
    p_fecha_hora_local  text,
    p_detalle           jsonb,
    p_notas             text default null,
    p_usuario           text default null
) returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_id   uuid;
    v_fila jsonb;
    v_fin  int;
    v_n    int;
begin
    if p_fecha_hora_local !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then
        raise exception 'Fecha/hora inválida: %', p_fecha_hora_local;
    end if;
    if jsonb_typeof(p_detalle) <> 'array' or jsonb_array_length(p_detalle) = 0 then
        raise exception 'La reposición no trae espacios';
    end if;
    if exists (select 1 from reposiciones
               where maquina_id = p_maquina_id and fecha_hora_local >= p_fecha_hora_local) then
        raise exception 'Ya hay una reposición registrada a esa hora o después para esta máquina';
    end if;

    insert into reposiciones (maquina_id, fecha_hora_local, detalle, notas, usuario)
    values (p_maquina_id, p_fecha_hora_local, p_detalle, p_notas, p_usuario)
    returning id into v_id;

    for v_fila in select * from jsonb_array_elements(p_detalle) loop
        v_fin := (v_fila->>'final')::int;
        if v_fin is null or v_fin < 0 then
            raise exception 'Cantidad "Dejé" inválida en el espacio %', v_fila->>'espacio';
        end if;
        update asignaciones_maquina
           set cantidad_asignada = v_fin
         where id::text = v_fila->>'asignacion_id'
           and maquina_id::text = p_maquina_id;
        get diagnostics v_n = row_count;
        if v_n <> 1 then
            raise exception 'No se encontró la asignación del espacio % (¿cambió el planograma?)', v_fila->>'espacio';
        end if;
    end loop;

    return v_id;
end;
$$;

revoke all on function public.registrar_reposicion(text, text, jsonb, text, text) from public, anon;
grant execute on function public.registrar_reposicion(text, text, jsonb, text, text) to authenticated;

-- Verificación rápida (debe devolver la tabla vacía y la función):
-- select count(*) from public.reposiciones;
-- select proname from pg_proc where proname = 'registrar_reposicion';
