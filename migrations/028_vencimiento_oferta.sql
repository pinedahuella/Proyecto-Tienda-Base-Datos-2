-- ============================================================
-- 028_vencimiento_oferta.sql
-- ============================================================
-- Cuando vence solo un descuento o una venta relampago lo sabe PostgreSQL, ya
-- no Redis. Hasta aqui el worker del backend (VentasLimitadasService, cada
-- minuto) daba por vencido todo descuento cuya clave de Redis no existiera, y
-- Redis no distingue "vencio" de "se perdio": un FLUSHALL o un volumen borrado
-- se llevaba tambien los descuentos PERMANENTES, para siempre. Era la fila 28
-- de docs/PENDIENTES.md.
--
--   fecha_vencimiento_descuento       cuando se apaga solo el % de descuento
--   fecha_vencimiento_venta_limitada  cuando se cierra sola la venta relampago
--
-- En las dos, NULL quiere decir permanente: el worker no la toca pase lo que
-- pase en Redis. Son dos y no una porque un descuento y la venta relampago de
-- encima pueden llevar duraciones distintas, y cerrar la venta a mano no toca
-- el descuento.
--
--
-- DE DONDE SALE
-- ============================================================
-- Del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/vencimiento-automatico-oferta.sql`,
-- copiado tal cual. Su diseno y sus pruebas (con un FLUSHALL real) estan en
-- `vencimiento-automatico-oferta.md`, en la misma carpeta.
--
-- Queda fuera a proposito, por decision suya: si Redis se vacia a media venta
-- relampago, la clave del contador de stock (`mesh:oferta:<id>`) no se vuelve
-- a sembrar. La venta queda "pausada" (el checkout la trata como oferta
-- normal) hasta que venza o el vendedor la reabra, pero el descuento ya no se
-- pierde.
--
-- La clave `mesh:oferta:<id>:descuento` dejo de existir. arrancar.ps1 la
-- sembraba en su paso 5b-2 para los descuentos de la semilla; ese paso ahora
-- solo comprueba que nacieron permanentes.
--
-- Es idempotente, con IF NOT EXISTS, porque `arrancar.ps1` la vuelve a correr
-- en cada arranque y la base del companero ya la tiene.
-- ============================================================

BEGIN;

ALTER TABLE oferta
  ADD COLUMN IF NOT EXISTS fecha_vencimiento_descuento timestamptz NULL,
  ADD COLUMN IF NOT EXISTS fecha_vencimiento_venta_limitada timestamptz NULL;

COMMENT ON COLUMN oferta.fecha_vencimiento_descuento IS
  'Cuando se apaga solo el porcentaje_descuento (NULL = permanente, nunca vence solo). Fuente de verdad para VentasLimitadasService.revisarDescuentosVencidos() -- ya no se decide preguntando a Redis.';
COMMENT ON COLUMN oferta.fecha_vencimiento_venta_limitada IS
  'Cuando se apaga sola la venta relampago (NULL = permanente, nunca vence sola). Fuente de verdad para VentasLimitadasService.revisarVentasLimitadasVencidas() -- ya no se decide preguntando a Redis. La clave de Redis (mesh:oferta:<id>) sigue viva para el checkout, esta columna no la reemplaza, solo deja de usarse su ausencia como señal de vencimiento.';

COMMIT;
