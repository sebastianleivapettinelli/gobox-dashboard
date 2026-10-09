-- ============================================================================
-- GO BOX · maquinas_serial_pos_v1.sql  (para index_v13.html) — YA APLICADO en Supabase el 09-10-2026
-- Desde oct-2026 las máquinas pueden compartir Serial AMIT: la máquina de cada venta se identifica
-- por el Serial POS (lector de tarjetas, columna "Serial pos" del reporte de PayScan).
-- ============================================================================
alter table public.maquinas add column if not exists serial_pos text;
update public.maquinas set serial_pos = '1500032797' where id = 'MAQ-001' and serial_pos is null;  -- Parque Lomas
update public.maquinas set serial_pos = '1500075489' where id = 'MAQ-002' and serial_pos is null;  -- Edificio New
create unique index if not exists maquinas_serial_pos_unico on public.maquinas (serial_pos) where serial_pos is not null and serial_pos <> '';
