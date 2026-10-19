-- ============================================================
-- semilla-combos/quitar.sql
-- ============================================================
-- Deshace combos.sql entero: los pedidos de las 8 cuentas combo*@mesh.com con
-- su pago y su kardex, el stock devuelto a cada oferta, sus direcciones y las
-- cuentas. El proximo arranque las vuelve a sembrar. Se corre a mano:
--
--   docker cp semilla-combos/quitar.sql mesh-postgres:/tmp/quitar_combos.sql
--   docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 -f /tmp/quitar_combos.sql
--   bash etl/cargar_compras.sh
--
-- La ultima linea es la que las borra de ClickHouse. Desde psql no se llega a
-- ClickHouse, asi que cada pedido borrado queda anotado en pedido_quitado (la
-- 046) y el ETL de compras borra sus lineas de compra_producto y
-- devolucion_producto al empezar. arrancar.ps1 corre ese ETL en cada arranque,
-- asi que si despues se arranca no hace falta la tercera linea.
--
-- Neo4j no necesita nada: al borrar los pedidos, los triggers de la 041 encolan
-- cada cuenta en evento_grafo_compra y el backend le quita sus :Compra.
-- ============================================================

BEGIN;

CREATE TEMP TABLE sembradas ON COMMIT DROP AS
SELECT id_usuario FROM usuarios WHERE correo_electronico IN (
    'combo1@mesh.com', 'combo2@mesh.com', 'combo3@mesh.com', 'combo4@mesh.com',
    'combo5@mesh.com', 'combo6@mesh.com', 'combo7@mesh.com', 'combo8@mesh.com'
);

CREATE TEMP TABLE pedidos_sembrados ON COMMIT DROP AS
SELECT id_pedido FROM pedido WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

-- El stock vuelve a la oferta (el trigger de oferta avisa a Mongo y al
-- buscador de ofertas).
UPDATE oferta o SET stock = o.stock + m.cantidad
  FROM (SELECT sm.id_oferta, sum(sm.cantidad * -mm.valor) AS cantidad
          FROM stock_movimiento sm
          JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
         WHERE sm.id_pedido IN (SELECT id_pedido FROM pedidos_sembrados)
         GROUP BY sm.id_oferta) m
 WHERE o.id_oferta = m.id_oferta;

-- Para ClickHouse: el ETL de compras los borra de alli.
INSERT INTO pedido_quitado (id_pedido, motivo)
SELECT id_pedido, 'semilla-combos' FROM pedidos_sembrados
ON CONFLICT (id_pedido) DO UPDATE SET aplicado_en = NULL, fecha = now(), motivo = EXCLUDED.motivo;

DELETE FROM senal_fraude_pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM reserva_venta_relampago WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM stock_movimiento WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pago WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pedido_producto WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);

-- Lo que una persona pudo dejar al entrar con una de estas cuentas.
DELETE FROM seguimiento_oferta WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM log_login WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM log_registro WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

DELETE FROM direccion_historial WHERE id_direccion IN (
    SELECT id_direccion FROM direcciones WHERE id_usuario IN (SELECT id_usuario FROM sembradas));
DELETE FROM direcciones WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM usuarios WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

DO $comprobar$
DECLARE
    v_pedidos integer;
BEGIN
    IF EXISTS (SELECT 1 FROM usuarios WHERE correo_electronico LIKE 'combo_@mesh.com') THEN
        RAISE EXCEPTION 'Quedaron cuentas de la semilla de combos';
    END IF;
    SELECT count(*) INTO v_pedidos FROM pedidos_sembrados;
    RAISE NOTICE 'Semilla de combos quitada: % pedidos, que el ETL de compras borra de ClickHouse', v_pedidos;
END
$comprobar$;

COMMIT;
