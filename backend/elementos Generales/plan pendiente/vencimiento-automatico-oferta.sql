-- ============================================================
-- vencimiento-automatico-oferta.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada despues de la ultima migracion real
-- existente (hoy 027_similares_con_indice.sql; el 026 ya esta reservado
-- para casos de fraude, asi que esta seria la 028) -- mismo workflow de
-- siempre (ver anillos-fraude-persistencia.sql, mismo folder, para el
-- precedente).
--
-- Arregla el bug real: `VentasLimitadasService.revisarVencidas()` decidia
-- si un descuento/venta relampago ya vencio preguntandole a Redis "?existe
-- la clave?" -- y Redis no distingue "vencio de verdad" de "se perdio"
-- (un FLUSHALL, un volumen borrado). Un descuento PERMANENTE (sin
-- duracion_segundos) tambien tiene una clave en Redis, solo que sin TTL;
-- si Redis se vacia, esa clave desaparece igual que una que si vencio, y el
-- worker lo borraba de PostgreSQL para siempre, sin que nadie lo pidiera.
--
-- La solucion: que PostgreSQL sea quien sepa "cuando vence esto", no Redis.
-- Dos columnas, ambas NULL = permanente (nunca vence solo, el worker no lo
-- toca pase lo que pase en Redis):
--
--   - fecha_vencimiento_descuento: cuando se apaga solo el % de descuento
--     (aplicado por POST /vendedor/ofertas/:id/descuento).
--   - fecha_vencimiento_venta_limitada: cuando se apaga sola la venta
--     relampago (abierta por POST /vendedor/ofertas/:id/venta-limitada).
--
-- Fuera de alcance A PROPOSITO (decision del usuario, 2026-09-27): si Redis
-- se vacia, la clave de la venta relampago (el contador de stock que usa el
-- checkout) NO se vuelve a sembrar sola. Con este cambio ya no se pierde el
-- descuento en PostgreSQL, pero la venta relampago puede quedar "pausada"
-- (el checkout la trata como oferta normal) hasta que venza sola o el
-- vendedor la reabra a mano. Revivir la clave de Redis es un problema
-- aparte (que stock resembrar, que las reservas en curso se pierden si o
-- si) que se deja fuera de esta ronda.
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS) y reversible: un `.\arrancar.ps1 -Reiniciar`
-- reconstruye la base desde las migraciones reales y borra esto.
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
