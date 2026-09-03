-- ============================================================
-- inventario-limitado.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada en el orden correcto.
--
-- Este archivo existe para dos cosas:
--   1. Dejar por escrito, en la forma exacta, que cambio de esquema pide
--      el plan `inventario-limitado.md` (mismo folder) -- por ahora, solo
--      el paso 1 de ese plan.
--   2. Poder aplicarlo al contenedor local `mesh-postgres` mientras se
--      desarrolla el backend en paralelo, sin esperar la migracion.
--
-- Aplicado en local el 2026-09-03 con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS) y reversible: un `.\arrancar.ps1
-- -Reiniciar` reconstruye la base desde las migraciones reales y borra
-- todo esto.
-- ============================================================

ALTER TABLE oferta
  ADD COLUMN IF NOT EXISTS es_inventario_limitado boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN oferta.es_inventario_limitado IS
    'true si esta oferta puntual esta operando (o puede operar) bajo el mecanismo de venta relampago de Redis (redis/inventario_limitado.lua) en vez del flujo normal de stock via FOR UPDATE. Lo decide el vendedor al abrir la venta; no se marca sola.';


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT count(*) AS ofertas_totales,
       count(*) FILTER (WHERE es_inventario_limitado) AS marcadas_limitadas
FROM oferta;
