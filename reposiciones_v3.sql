-- ============================================================================
-- GO BOX · reposiciones_v3.sql  (para index_v12.html)
-- Requiere reposiciones_v1.sql y v2. Idempotente. No modifica datos.
-- aplicar_bodega_reposicion (v3): si un espacio trae origen_alt {sku, cantidad}, esas unidades se
-- descuentan de ese otro producto/lote en vez del producto asignado al espacio
-- ("Saqué de otro producto" en la pestaña Reponer).
-- ============================================================================

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
                   coalesce((x->>'final')::int, 0) as fin,
                   nullif(x->'origen_alt'->>'sku', '') as alt_sku,
                   coalesce((x->'origen_alt'->>'cantidad')::int, 0) as alt_cant
              from jsonb_array_elements(v_rep.detalle) x
        ), e as (
            select d.*,
                   case when sku_nuevo is not null and sku_nuevo <> sku then sku_nuevo else sku end as sku_entra,
                   case when sku_nuevo is not null and sku_nuevo <> sku then fin else greatest(fin - enc, 0) end as entra_total
              from d
        ), mov as (
            -- lo que entró, menos lo que salió de otro producto/lote (origen_alt)
            select sku_entra as s, entra_total - least(entra_total, alt_cant) as entra, 0 as sale from e
            union all
            select alt_sku, least(entra_total, alt_cant), 0 from e where alt_sku is not null and alt_cant > 0
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

revoke all on function public.aplicar_bodega_reposicion(uuid, jsonb, text) from public, anon;
grant execute on function public.aplicar_bodega_reposicion(uuid, jsonb, text) to authenticated;
