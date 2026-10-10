-- ============================================================================
-- GO BOX · reposiciones_v4.sql  (para index_v14.html)
-- Requiere reposiciones_v1..v3. Idempotente. No modifica datos.
-- editar_reposicion: corrige una reposición guardada ANTES de actualizar la bodega.
--   Solo si su bodega no se aplicó y es la última reposición de esa máquina.
--   En una transacción: reemplaza el detalle y deja cada espacio con lo nuevo
--   (cantidad = "Dejé"; producto/precio si se cambió o se deshizo un cambio).
--   Rechaza si un espacio cambió desde la reposición (por ejemplo, editado en Espacios).
-- ============================================================================

create or replace function public.editar_reposicion(
    p_reposicion_id  uuid,
    p_detalle        jsonb,
    p_notas          text default null,
    p_usuario        text default null
) returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
    v_rep     reposiciones%rowtype;
    v_fila    jsonb;
    v_old     jsonb;
    v_sku_act text;
    v_sku     text;
    v_precio  numeric;
    v_fin     int;
    v_n       int;
begin
    select * into v_rep from reposiciones where id = p_reposicion_id for update;
    if not found then
        raise exception 'No existe la reposición %', p_reposicion_id;
    end if;
    if v_rep.bodega_aplicada_at is not null then
        raise exception 'La bodega de esta reposición ya se actualizó; ya no se puede editar';
    end if;
    if exists (select 1 from reposiciones
               where maquina_id = v_rep.maquina_id and fecha_hora_local > v_rep.fecha_hora_local) then
        raise exception 'Hay una reposición posterior en esta máquina; solo se puede editar la última';
    end if;
    if jsonb_typeof(p_detalle) <> 'array' or jsonb_array_length(p_detalle) <> jsonb_array_length(v_rep.detalle) then
        raise exception 'El detalle editado no coincide con los espacios de la reposición';
    end if;

    for v_fila in select * from jsonb_array_elements(p_detalle) loop
        select x into v_old from jsonb_array_elements(v_rep.detalle) x
         where x->>'asignacion_id' = v_fila->>'asignacion_id';
        if v_old is null then
            raise exception 'El espacio % no pertenece a esta reposición', v_fila->>'espacio';
        end if;
        if v_fila->>'sku' is distinct from v_old->>'sku' then
            raise exception 'El producto original del espacio % no coincide', v_fila->>'espacio';
        end if;
        v_fin := (v_fila->>'final')::int;
        if v_fin is null or v_fin < 0 then
            raise exception 'Cantidad "Dejé" inválida en el espacio %', v_fila->>'espacio';
        end if;

        -- Producto que el espacio debería tener hoy según la reposición guardada
        v_sku_act := coalesce(nullif(v_old->>'sku_nuevo', ''), v_old->>'sku');
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
             where id::text = v_fila->>'asignacion_id' and maquina_id::text = v_rep.maquina_id and sku = v_sku_act;
        elsif nullif(v_old->>'sku_nuevo', '') is not null then
            -- se deshizo un cambio de producto: vuelve el producto y precio anteriores
            update asignaciones_maquina
               set cantidad_asignada = v_fin, sku = v_old->>'sku',
                   precio_venta_espacio = coalesce((v_old->>'precio_anterior')::numeric, precio_venta_espacio)
             where id::text = v_fila->>'asignacion_id' and maquina_id::text = v_rep.maquina_id and sku = v_sku_act;
        else
            update asignaciones_maquina
               set cantidad_asignada = v_fin
             where id::text = v_fila->>'asignacion_id' and maquina_id::text = v_rep.maquina_id and sku = v_sku_act;
        end if;
        get diagnostics v_n = row_count;
        if v_n <> 1 then
            raise exception 'El espacio % cambió desde la reposición (producto distinto). Revísalo en Espacios.', v_fila->>'espacio';
        end if;
    end loop;

    update reposiciones set detalle = p_detalle, notas = p_notas where id = p_reposicion_id;
    return p_reposicion_id;
end;
$$;

grant update (detalle, notas) on public.reposiciones to authenticated;
revoke all on function public.editar_reposicion(uuid, jsonb, text, text) from public, anon;
grant execute on function public.editar_reposicion(uuid, jsonb, text, text) to authenticated;
