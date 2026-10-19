-- ============================================================
-- 046_pedido_quitado.sql
-- ============================================================
-- Los pedidos que una semilla quito de PostgreSQL y que ClickHouse todavia
-- tiene. Es la otra mitad de los quitar.sql de las semillas
-- (clasificador-resenas/semilla/ y semilla-combos/).
--
-- POR QUE HACE FALTA. compra_producto y devolucion_producto son una COPIA de
-- stock_movimiento (etl/cargar_compras.sh y su gemelo en arrancar.ps1), y la
-- copia solo agrega lo que falta: nunca borra. Cuando un quitar.sql borraba sus
-- pedidos de PostgreSQL, ClickHouse se quedaba con las lineas para siempre. Asi
-- quedaron 480 lineas de los pedidos 771 a 1250 desde el 2026-10-04, y por eso
-- arrancar avisaba que las ventas no cuadraban y etl_compras.sh daba 5 FALLA.
--
-- COMO SE USA. Un quitar.sql corre en psql y desde ahi no se llega a
-- ClickHouse. Asi que deja aqui el id de cada pedido que borra, en la misma
-- transaccion, y el ETL de compras (al principio de cada corrida) borra esas
-- lineas de las dos tablas de ClickHouse y marca la fila con aplicado_en. Es
-- el mismo patron de cola que evento_grafo y evento_producto.
--
-- Por pedido y no por linea: un pedido quitado se va entero. El ETL solo borra
-- un pedido que ya NO esta en PostgreSQL, para que una fila puesta aqui por
-- error no se lleve una venta que existe.
--
-- Es idempotente: arrancar.ps1 lo vuelve a correr en cada arranque.
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS pedido_quitado (
    id_pedido     bigint PRIMARY KEY,
    fecha         timestamptz NOT NULL DEFAULT now(),
    motivo        text NOT NULL CHECK (btrim(motivo) <> ''),
    aplicado_en   timestamptz
);

COMMENT ON TABLE pedido_quitado IS
    'Pedidos borrados de PostgreSQL a proposito (los quitar.sql de las semillas) cuyas lineas hay que borrar tambien de compra_producto y devolucion_producto en ClickHouse. La llenan los quitar.sql; la vacia el ETL de compras';
COMMENT ON COLUMN pedido_quitado.id_pedido IS
    'El pedido que se borro. SIN FK a proposito: el pedido ya no existe';
COMMENT ON COLUMN pedido_quitado.motivo IS
    'Quien lo quito, por ejemplo semilla-combos';
COMMENT ON COLUMN pedido_quitado.aplicado_en IS
    'NULL = falta borrarlo de ClickHouse. Con fecha = ya se borro';

CREATE INDEX IF NOT EXISTS idx_pedido_quitado_pendiente
    ON pedido_quitado (id_pedido)
    WHERE aplicado_en IS NULL;

COMMIT;
