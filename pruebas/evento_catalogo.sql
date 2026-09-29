-- evento_catalogo.sql
-- Prueba de las migraciones 029 y 030: que cambiar el precio o la cantidad de
-- una oferta encole su producto en evento_catalogo, y que la copia del catalogo
-- no encole nada ni mueva la fecha de la oferta.
--
-- Se corre asi, contra la base levantada, y NO deja nada escrito (todo va
-- dentro de una transaccion que termina en ROLLBACK):
--
--   docker exec -i mesh-postgres psql -U <usuario> -d <base> -qtAX -v ON_ERROR_STOP=1 < pruebas/evento_catalogo.sql
--
-- Cada caso escribe OK o corta con ERROR diciendo cual fallo.

BEGIN;

CREATE TEMP TABLE prueba_ctx ON COMMIT DROP AS
SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
       o.fecha_actualizacion,
       (SELECT coalesce(max(id_evento), 0) FROM evento_catalogo) AS desde
  FROM oferta o
  JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
 WHERE eo.estado_oferta_nombre = 'activa' AND o.stock > 0
 ORDER BY o.id_oferta
 LIMIT 1;

CREATE OR REPLACE FUNCTION pg_temp.nuevos() RETURNS bigint LANGUAGE sql AS $$
    SELECT count(*) FROM evento_catalogo
     WHERE id_evento > (SELECT desde FROM prueba_ctx)
$$;

CREATE OR REPLACE FUNCTION pg_temp.revisar(p_caso text, p_esperado bigint) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v bigint := pg_temp.nuevos();
BEGIN
    IF v <> p_esperado THEN
        RAISE EXCEPTION 'FALLA % -- se esperaban % evento(s) nuevos y hay %', p_caso, p_esperado, v;
    END IF;
    RETURN 'OK ' || p_caso;
END $$;

-- 1. La copia del catalogo no encola nada ni mueve la fecha
UPDATE oferta SET nombre_variante = nombre_variante || ' x'
 WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);
SELECT pg_temp.revisar('cambiar la copia del catalogo no encola', 0);
SELECT CASE WHEN fecha_actualizacion = (SELECT fecha_actualizacion FROM prueba_ctx)
            THEN 'OK cambiar la copia no mueve fecha_actualizacion'
            ELSE 'FALLA la copia movio fecha_actualizacion' END
  FROM oferta WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);

-- 2. Un UPDATE que deja el stock igual no encola
UPDATE oferta SET stock = stock WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);
SELECT pg_temp.revisar('stock igual no encola', 0);

-- 3. Cambiar la cantidad por la funcion de siempre encola uno
SELECT reponer_stock(c.id_oferta, 3, 'reposicion', o.id_usuario) IS NOT NULL
  FROM prueba_ctx c JOIN oferta o ON o.id_oferta = c.id_oferta;
SELECT pg_temp.revisar('reponer_stock encola uno', 1);

-- 4. Precio, descuento y estado, uno cada uno
UPDATE oferta SET precio = precio + 1 WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);
SELECT pg_temp.revisar('cambiar el precio encola', 2);
UPDATE oferta SET porcentaje_descuento = 10 WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);
SELECT pg_temp.revisar('poner descuento encola', 3);
UPDATE oferta SET id_estado_oferta = (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'pausada')
 WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);
SELECT pg_temp.revisar('pausar encola', 4);

-- 5. Todos apuntan al producto de la oferta y dicen 'cambio'
SELECT CASE WHEN bool_and(id_producto_mongo = (SELECT id_producto_mongo FROM prueba_ctx)
                          AND operacion = 'cambio' AND procesado_en IS NULL)
            THEN 'OK los eventos llevan el producto, cambio y pendientes'
            ELSE 'FALLA producto u operacion equivocados' END
  FROM evento_catalogo WHERE id_evento > (SELECT desde FROM prueba_ctx);

-- 6. Un cambio que se deshace se lleva su evento
SAVEPOINT antes_de_deshacer;
UPDATE oferta SET stock = stock + 5 WHERE id_oferta = (SELECT id_oferta FROM prueba_ctx);
ROLLBACK TO SAVEPOINT antes_de_deshacer;
SELECT pg_temp.revisar('un cambio deshecho no deja evento', 4);

-- 7. Una oferta nueva encola 'alta' y al borrarla 'baja'
INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, id_estado_oferta)
SELECT c.id_producto_mongo, c.id_producto_variante_mongo, u.id_usuario, 10,
       (SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'pendiente')
  FROM prueba_ctx c
  CROSS JOIN LATERAL (
      SELECT id_usuario FROM usuarios u
       WHERE NOT EXISTS (SELECT 1 FROM oferta o
                          WHERE o.id_usuario = u.id_usuario
                            AND o.id_producto_mongo = c.id_producto_mongo
                            AND o.id_producto_variante_mongo = c.id_producto_variante_mongo)
       ORDER BY id_usuario LIMIT 1) u;
SELECT pg_temp.revisar('oferta nueva encola alta', 5);
-- precio_historial no deja borrar una oferta (RESTRICT), asi que en la vida
-- real una oferta no se borra. La baja se prueba igual, quitando antes su
-- historial, por si algun dia se permite.
DELETE FROM precio_historial
 WHERE id_oferta = (SELECT id_oferta FROM evento_catalogo
                     WHERE id_evento > (SELECT desde FROM prueba_ctx) AND operacion = 'alta');
DELETE FROM oferta
 WHERE id_oferta = (SELECT id_oferta FROM evento_catalogo
                     WHERE id_evento > (SELECT desde FROM prueba_ctx) AND operacion = 'alta');
SELECT pg_temp.revisar('oferta borrada encola baja', 6);
SELECT CASE WHEN count(*) FILTER (WHERE operacion = 'alta') = 1
             AND count(*) FILTER (WHERE operacion = 'baja') = 1
            THEN 'OK alta y baja con su operacion'
            ELSE 'FALLA alta o baja sin su operacion' END
  FROM evento_catalogo WHERE id_evento > (SELECT desde FROM prueba_ctx);

-- 8. copiar_catalogo_a_oferta no encola
SELECT copiar_catalogo_a_oferta(
    jsonb_build_array(jsonb_build_object(
        'id_producto', c.id_producto_mongo, 'id_producto_variante', c.id_producto_variante_mongo,
        'nombre_producto', 'Prueba', 'nombre_variante', 'Prueba', 'imagen', NULL,
        'producto_visible', true, 'variante_activa', true))) >= 1
  FROM prueba_ctx c;
SELECT pg_temp.revisar('copiar_catalogo_a_oferta no encola', 6);

ROLLBACK;
