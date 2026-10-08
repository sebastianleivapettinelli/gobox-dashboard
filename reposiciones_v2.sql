-- ============================================================================
-- GO BOX · reposiciones_v2.sql  (para index_v8.html)
-- Requiere reposiciones_v1.sql. Idempotente. No modifica datos existentes.
--
-- 1) registrar_reposicion (v2): además de la cantidad, si un espacio trae sku_nuevo cambia el
--    producto y el precio del espacio (precio_venta_espacio). Valida que el SKU nuevo exista en bodega.
-- 2) aplicar_bodega_reposicion: UNA vez por reposición, mueve inventario_bodega.cantidad_actual:
--       − lo que entró a la máquina (Dejé − Encontré; o todo lo dejado si cambió el producto)
--       + lo que salió de la máquina, solo para los SKU que el usuario marcó "vuelve a bodega"
--    El cálculo se hace aquí con el detalle guardado (no se confía en números enviados por la app).
--    Rechaza si la bodega de algún SKU quedaría negativa o si ya se aplicó.
-- ============================================================================

alter table public.reposiciones add column if not exists bodega_movimientos jsonb;
alter table public.reposiciones add column if not exists bodega_aplicada_at timestamptz;
alter table public.reposiciones add column if not exists bodega_usuario text;

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
    v_id     uuid;
    v_fila   jsonb;
    v_fin    int;
    v_n      int;
    v_sku    text;
    v_precio numeric;
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

        v_sku := nullif(v_fila->>'sku_nuevo', '');
        if v_sku is not null then
            if not exists (select 1 from inventario_bodega where sku = v_sku) then
                raise exception 'El producto % (espacio %) no está en la bodega', v_sku, v_fila->>'espacio';
            end if;
            v_precio := (v_fila->>'precio_nuevo')::numeric;
            if v_precio is null or v_precio <= 0 then
                raise exception 'Falta el precio del producto nuevo en el espacio %', v_fila->>'espacio';
            end if;
            update asignaciones_maquina
               set cantidad_asignada = v_fin, sku = v_sku, precio_venta_espacio = v_precio
             where id::text = v_fila->>'asignacion_id'
               and maquina_id::text = p_maquina_id
               and sku = v_fila->>'sku';
        else
            update asignaciones_maquina
               set cantidad_asignada = v_fin
             where id::text = v_fila->>'asignacion_id'
               and maquina_id::text = p_maquina_id
               and sku = v_fila->>'sku';
        end if;
        get diagnostics v_n = row_count;
        if v_n <> 1 then
            raise exception 'El espacio % cambió desde que abriste la reposición (producto o asignación distinta). Actualiza la página y revisa.', v_fila->>'espacio';
        end if;
    end loop;

    return v_id;
end;
$$;

revoke all on function public.registrar_reposicion(text, text, jsonb, text, text) from public, anon;
grant execute on function public.registrar_reposicion(text, text, jsonb, text, text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.aplicar_bodega_reposicion(
    p_reposicion_id  uuid,
    p_devuelve       jsonb default '[]'::jsonb,   -- ["SKU", ...] cuyo retiro vuelve a bodega
    p_usuario        text default null
) returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_rep    reposiciones%rowtype;
    v_movs   jsonb;
    r        record;
    v_nueva  int;
begin
    select * into v_rep from reposiciones where id = p_reposicion_id for update;
    if not found then
        raise exception 'No existe la reposición %', p_reposicion_id;
    end if;
    if v_rep.bodega_aplicada_at is not null then
        raise exception 'La bodega de esta reposición ya se actualizó (%)', v_rep.bodega_aplicada_at;
    end if;

    for r in
        with d as (
            select x->>'sku' as sku,
                   nullif(x->>'sku_nuevo', '') as sku_nuevo,
                   coalesce((x->>'encontrado')::int, 0) as enc,
                   coalesce((x->>'final')::int, 0) as fin
              from jsonb_array_elements(v_rep.detalle) x
        ), mov as (
            select case when sku_nuevo is not null and sku_nuevo <> sku then sku_nuevo else sku end as s,
                   case when sku_nuevo is not null and sku_nuevo <> sku then fin else greatest(fin - enc, 0) end as entra,
                   0 as sale
              from d
            union all
            select sku,
                   0,
                   case when sku_nuevo is not null and sku_nuevo <> sku then enc else greatest(enc - fin, 0) end
              from d
        )
        select s as sku, sum(entra)::int as entra, sum(sale)::int as sale,
               (case when p_devuelve ? s then sum(sale) else 0 end)::int as devuelto
          from mov group by s
         having sum(entra) > 0 or sum(sale) > 0
    loop
        if r.devuelto - r.entra <> 0 then
            update inventario_bodega
               set cantidad_actual = cantidad_actual + (r.devuelto - r.entra)
             where sku = r.sku
            returning cantidad_actual into v_nueva;
            if not found then
                raise exception 'El producto % no está en la bodega', r.sku;
            end if;
            if v_nueva < 0 then
                raise exception 'La bodega de % quedaría en % unidades. Revisa Inventario o lo anotado.', r.sku, v_nueva;
            end if;
        end if;
        v_movs := coalesce(v_movs, '[]'::jsonb) || jsonb_build_object(
            'sku', r.sku, 'entra', r.entra, 'sale', r.sale, 'devuelto', r.devuelto, 'delta', r.devuelto - r.entra);
    end loop;

    update reposiciones
       set bodega_movimientos = coalesce(v_movs, '[]'::jsonb),
           bodega_aplicada_at = now(),
           bodega_usuario = p_usuario
     where id = p_reposicion_id;

    return coalesce(v_movs, '[]'::jsonb);
end;
$$;

-- La app solo puede marcar la bodega como aplicada a través de la función (columnas puntuales).
grant update (bodega_movimientos, bodega_aplicada_at, bodega_usuario) on public.reposiciones to authenticated;
drop policy if exists "reposiciones_update_bodega_autenticados" on public.reposiciones;
create policy "reposiciones_update_bodega_autenticados" on public.reposiciones
    for update to authenticated using (true) with check (true);

revoke all on function public.aplicar_bodega_reposicion(uuid, jsonb, text) from public, anon;
grant execute on function public.aplicar_bodega_reposicion(uuid, jsonb, text) to authenticated;
