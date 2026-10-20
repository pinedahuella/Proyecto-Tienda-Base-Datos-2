-- ============================================================
-- semilla-fraude/quitar.sql
-- ============================================================
-- Deshace fraude.sql entero: las cuentas fraude.*@mesh.com con sus resenas,
-- sus pedidos (con su pago, su kardex y el stock devuelto), las ofertas de los
-- tres vendedores de la semilla, y las senales de fraude que salieron de todo
-- eso. El proximo arranque las vuelve a sembrar, con fechas nuevas. Se corre a
-- mano:
--
--   docker cp semilla-fraude/quitar.sql mesh-postgres:/tmp/quitar_fraude.sql
--   docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 -f /tmp/quitar_fraude.sql
--   bash etl/cargar_compras.sh
--
-- La ultima linea las borra de ClickHouse: cada pedido borrado queda anotado en
-- pedido_quitado (la 046) y el ETL de compras borra sus lineas. arrancar.ps1
-- corre ese ETL en cada arranque.
--
-- Lo demas lo hacen las colas, con el backend arriba: evento_grafo quita las
-- resenas de Neo4j, el vector de cada comentario se va de vector_comentario en
-- cascada, evento_producto recalcula en Mongo la nota y el stock de cada
-- producto tocado y evento_oferta saca del buscador las ofertas borradas. Los
-- casos de fraude que se quedan sin evidencia los borra el agrupador en su
-- siguiente vuelta (o node pruebas/correr_detectores_fraude.cjs casos).
--
-- Si alguien que no es de la semilla le compro a uno de sus vendedores (en una
-- demo, por ejemplo), no se borra nada y se dice cual: ese pedido es de otra
-- persona.
-- ============================================================

BEGIN;

CREATE TEMP TABLE sembradas ON COMMIT DROP AS
SELECT id_usuario FROM usuarios WHERE correo_electronico LIKE 'fraude.%@mesh.com';

CREATE TEMP TABLE ofertas_sembradas ON COMMIT DROP AS
SELECT id_oferta FROM oferta WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

CREATE TEMP TABLE pedidos_sembrados ON COMMIT DROP AS
SELECT id_pedido FROM pedido WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

CREATE TEMP TABLE resenas_sembradas ON COMMIT DROP AS
SELECT id_resena, id_comentario FROM resena
 WHERE id_usuario IN (SELECT id_usuario FROM sembradas)
    OR id_usuario_vendedor IN (SELECT id_usuario FROM sembradas);

DO $ajenos$
DECLARE
    v_pedido bigint;
BEGIN
    SELECT sm.id_pedido INTO v_pedido
      FROM stock_movimiento sm
     WHERE sm.id_oferta IN (SELECT id_oferta FROM ofertas_sembradas)
       AND sm.id_pedido IS NOT NULL
       AND sm.id_pedido NOT IN (SELECT id_pedido FROM pedidos_sembrados)
     LIMIT 1;
    IF v_pedido IS NOT NULL THEN
        RAISE EXCEPTION 'El pedido % le compro a un vendedor de la semilla de fraude y no es de la semilla: quitalo o cancelalo antes', v_pedido;
    END IF;
END
$ajenos$;

-- Las senales que salieron de la semilla: las que nombran a una de sus
-- cuentas, a una de sus resenas o a uno de sus pedidos. Al borrarlas se van en
-- cascada sus cuentas, resenas, productos, pedidos, IPs, avisos y evidencias.
DELETE FROM senal_fraude s
 WHERE EXISTS (SELECT 1 FROM senal_fraude_cuenta x WHERE x.id_senal_fraude = s.id_senal_fraude
                 AND x.id_usuario IN (SELECT id_usuario FROM sembradas))
    OR EXISTS (SELECT 1 FROM senal_fraude_resena x WHERE x.id_senal_fraude = s.id_senal_fraude
                 AND x.id_resena IN (SELECT id_resena FROM resenas_sembradas))
    OR EXISTS (SELECT 1 FROM senal_fraude_pedido x WHERE x.id_senal_fraude = s.id_senal_fraude
                 AND x.id_pedido IN (SELECT id_pedido FROM pedidos_sembrados));

-- Las tablas de antes del modelo unico de senales (la 031), por si quedo algo.
DELETE FROM anillo_fraude_resena WHERE id_resena IN (SELECT id_resena FROM resenas_sembradas);
DELETE FROM hallazgo_evento_fraude_cuenta WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM notificacion_fraude WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM alerta_fraude WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM evidencia_caso_fraude_cuenta WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

-- El stock vuelve a cada oferta: la venta lo resto y la devolucion ya lo
-- sumo, asi que se deshace la suma de los dos.
UPDATE oferta o SET stock = o.stock + m.cantidad
  FROM (SELECT sm.id_oferta, sum(sm.cantidad * -mm.valor) AS cantidad
          FROM stock_movimiento sm
          JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
         WHERE sm.id_pedido IN (SELECT id_pedido FROM pedidos_sembrados)
         GROUP BY sm.id_oferta) m
 WHERE o.id_oferta = m.id_oferta
   AND o.id_oferta NOT IN (SELECT id_oferta FROM ofertas_sembradas);

-- Para ClickHouse: el ETL de compras los borra de alli.
INSERT INTO pedido_quitado (id_pedido, motivo)
SELECT id_pedido, 'semilla-fraude' FROM pedidos_sembrados
ON CONFLICT (id_pedido) DO UPDATE SET aplicado_en = NULL, fecha = now(), motivo = EXCLUDED.motivo;

-- Las resenas y sus comentarios (con las respuestas y los likes que les
-- hayan dejado). El vector de cada comentario se va en cascada.
DELETE FROM likes WHERE id_comentario IN (SELECT id_comentario FROM resenas_sembradas)
                     OR id_comentario IN (SELECT id_comentario FROM comentario
                                           WHERE id_comentario_padre IN (SELECT id_comentario FROM resenas_sembradas))
                     OR id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM comentario WHERE id_comentario_padre IN (SELECT id_comentario FROM resenas_sembradas);
DELETE FROM resena WHERE id_resena IN (SELECT id_resena FROM resenas_sembradas);
DELETE FROM comentario WHERE id_comentario IN (SELECT id_comentario FROM resenas_sembradas);

-- Los pedidos.
DELETE FROM reserva_venta_relampago WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM stock_movimiento WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pago WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pedido_producto WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);
DELETE FROM pedido WHERE id_pedido IN (SELECT id_pedido FROM pedidos_sembrados);

-- Las ofertas de los tres vendedores de la semilla.
DELETE FROM stock_movimiento WHERE id_oferta IN (SELECT id_oferta FROM ofertas_sembradas);
DELETE FROM rechazo_oferta WHERE id_oferta IN (SELECT id_oferta FROM ofertas_sembradas);
DELETE FROM precio_historial WHERE id_oferta IN (SELECT id_oferta FROM ofertas_sembradas);
DELETE FROM oferta WHERE id_oferta IN (SELECT id_oferta FROM ofertas_sembradas);

-- Lo que una persona pudo dejar al entrar con una de estas cuentas.
DELETE FROM seguimiento_oferta WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM propuesta_producto WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM log_login WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM log_registro WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

DELETE FROM direccion_historial WHERE id_direccion IN (
    SELECT id_direccion FROM direcciones WHERE id_usuario IN (SELECT id_usuario FROM sembradas));
DELETE FROM direcciones WHERE id_usuario IN (SELECT id_usuario FROM sembradas);
DELETE FROM usuarios WHERE id_usuario IN (SELECT id_usuario FROM sembradas);

DO $comprobar$
DECLARE
    v_pedidos integer;
    v_resenas integer;
BEGIN
    IF EXISTS (SELECT 1 FROM usuarios WHERE correo_electronico LIKE 'fraude.%@mesh.com') THEN
        RAISE EXCEPTION 'Quedaron cuentas de la semilla de fraude';
    END IF;
    SELECT count(*) INTO v_pedidos FROM pedidos_sembrados;
    SELECT count(*) INTO v_resenas FROM resenas_sembradas;
    RAISE NOTICE 'Semilla de fraude quitada: % resenas y % pedidos, que el ETL de compras borra de ClickHouse', v_resenas, v_pedidos;
END
$comprobar$;

COMMIT;
