-- ============================================================
-- clasificador-resenas/semilla/quitar.sql
-- ============================================================
-- GENERADO por clasificador-resenas/semilla/generar.js. Deshace resenas.sql:
-- las resenas de las 40 cuentas, sus respuestas y votos, y sus compras, con el
-- stock devuelto. Las cuentas se quedan. Se corre a mano:
--   docker cp clasificador-resenas/semilla/quitar.sql mesh-postgres:/tmp/quitar.sql
--   docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 -f /tmp/quitar.sql
--   bash etl/cargar_compras.sh
--
-- La ultima linea las borra de ClickHouse: cada pedido borrado queda anotado
-- en pedido_quitado (la 046) y el ETL de compras borra sus lineas de
-- compra_producto y devolucion_producto. arrancar.ps1 corre ese ETL en cada
-- arranque. Antes de la 046 ClickHouse se quedaba con ellas (480 lineas del
-- 2026-10-04).
-- ============================================================

BEGIN;

CREATE TEMP TABLE sembradas ON COMMIT DROP AS
SELECT id_usuario FROM usuarios WHERE correo_electronico IN (
    'sofia.ramirez@mesh.com',
    'diego.morales@mesh.com',
    'valeria.castillo@mesh.com',
    'jorge.mendez@mesh.com',
    'andrea.pineda@mesh.com',
    'luis.barrios@mesh.com',
    'gabriela.orellana@mesh.com',
    'fernando.cifuentes@mesh.com',
    'daniela.monterroso@mesh.com',
    'ricardo.juarez@mesh.com',
    'mariela.estrada@mesh.com',
    'pablo.godinez@mesh.com',
    'karla.aguilar@mesh.com',
    'esteban.solorzano@mesh.com',
    'lucia.velasquez@mesh.com',
    'hector.mazariegos@mesh.com',
    'ximena.paredes@mesh.com',
    'oscar.quinonez@mesh.com',
    'natalia.rodas@mesh.com',
    'mario.cabrera@mesh.com',
    'paula.arriaga@mesh.com',
    'rodrigo.samayoa@mesh.com',
    'camila.galindo@mesh.com',
    'javier.asturias@mesh.com',
    'elena.fuentes@mesh.com',
    'sergio.coronado@mesh.com',
    'rocio.marroquin@mesh.com',
    'alejandro.toledo@mesh.com',
    'ines.cordova@mesh.com',
    'manuel.batres@mesh.com',
    'beatriz.lemus@mesh.com',
    'raul.escobar@mesh.com',
    'carolina.sandoval@mesh.com',
    'emilio.recinos@mesh.com',
    'silvia.arevalo@mesh.com',
    'tomas.villatoro@mesh.com',
    'adriana.polanco@mesh.com',
    'ivan.chacon@mesh.com',
    'monica.duarte@mesh.com',
    'gustavo.alvarado@mesh.com'
);

-- Los comentarios raiz de sus resenas y todo lo que cuelga de ellos.
CREATE TEMP TABLE hilo ON COMMIT DROP AS
WITH RECURSIVE h AS (
    SELECT r.id_comentario, 0 AS nivel FROM resena r WHERE r.id_usuario IN (SELECT id_usuario FROM sembradas)
    UNION ALL
    SELECT c.id_comentario, h.nivel + 1 FROM comentario c JOIN h ON c.id_comentario_padre = h.id_comentario
)
SELECT id_comentario, nivel FROM h;

DELETE FROM senal_fraude_resena WHERE id_resena IN (SELECT id_resena FROM resena WHERE id_usuario IN (SELECT id_usuario FROM sembradas));
DELETE FROM likes WHERE id_comentario IN (SELECT id_comentario FROM hilo);
DELETE FROM resena WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
-- De las hojas a la raiz: la llave al padre es RESTRICT.
DO $hilo$
DECLARE v_nivel integer;
BEGIN
    FOR v_nivel IN SELECT DISTINCT nivel FROM hilo ORDER BY nivel DESC LOOP
        DELETE FROM comentario WHERE id_comentario IN (SELECT id_comentario FROM hilo WHERE nivel = v_nivel);
    END LOOP;
END
$hilo$;

-- Las compras: el stock vuelve a la oferta (el trigger de oferta avisa a Mongo).
CREATE TEMP TABLE pedidos_sembrados ON COMMIT DROP AS
SELECT id_pedido FROM pedido WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

UPDATE oferta o SET stock = o.stock + m.cantidad
  FROM (SELECT sm.id_oferta, sum(sm.cantidad * -mm.valor) AS cantidad
          FROM stock_movimiento sm
          JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
         WHERE sm.id_pedido IN (SELECT id_pedido FROM pedidos_sembrados)
         GROUP BY sm.id_oferta) m
 WHERE o.id_oferta = m.id_oferta;

-- Para ClickHouse: el ETL de compras los borra de alli.
INSERT INTO pedido_quitado (id_pedido, motivo)
SELECT id_pedido, 'semilla-clasificador' FROM pedidos_sembrados
ON CONFLICT (id_pedido) DO UPDATE SET aplicado_en = NULL, fecha = now(), motivo = EXCLUDED.motivo;

DELETE FROM senal_fraude_pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM stock_movimiento WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pago WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pedido_producto WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);

DO $comprobar$
BEGIN
    IF EXISTS (SELECT 1 FROM resena WHERE id_usuario IN (SELECT id_usuario FROM sembradas))
       OR EXISTS (SELECT 1 FROM pedido WHERE id_usuario IN (SELECT id_usuario FROM sembradas)) THEN
        RAISE EXCEPTION 'Quedaron resenas o pedidos de las cuentas sembradas';
    END IF;
    RAISE NOTICE 'Siembra del clasificador quitada';
END
$comprobar$;

COMMIT;
