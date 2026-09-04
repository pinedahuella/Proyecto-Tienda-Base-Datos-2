-- ============================================================
-- borrar_ofertas_mongo.sql -- la mitad de PostgreSQL del borrado
-- ============================================================
-- Borra las ofertas de los productos que `mongo/lote/borrar_lote_mongo.js`
-- acaba de quitar de MongoDB.
--
-- Lee /tmp/mesh-lote-mongo-borrados.csv, que es la lista de ids que aquel
-- escribio ANTES de borrar. Es la unica forma de saber cuales eran: una vez
-- borrado el documento, el id no lleva a ninguna parte.
--
-- La ruta va fija por lo mismo que en ofertas_mongo.sql: `\copy` no expande
-- las variables de psql en la posicion del archivo, y el nombre fijo es la
-- convencion que ya usa el ETL.
--
--
-- UN PRODUCTO VENDIDO NO SE BORRA, Y SE SALTA
-- ============================================================
-- `pedido_producto` referencia `precio_historial` con ON DELETE RESTRICT, asi
-- que borrar la oferta de algo que alguien compro exigiria borrar el pedido, y
-- un pedido sin lineas miente sobre lo que se vendio.
--
-- Esos se SALTAN y se borra el resto, diciendo cuantos y por que -- el mismo
-- criterio que borrar_lote.sql. Abortar el lote entero por una oferta vendida
-- dejaria sin borrar todas las demas.
--
-- OJO con la consecuencia, que hay que decirla: si una oferta se salta, su
-- producto YA no esta en Mongo (esto corre despues), asi que queda una oferta
-- apuntando a un documento que no existe. Es feo y es lo menos malo: la otra
-- opcion era borrar el pedido de alguien.


BEGIN;

CREATE TEMP TABLE lote_borrar (id_producto bigint) ON COMMIT DROP;

\copy lote_borrar FROM '/tmp/mesh-lote-mongo-borrados.csv' WITH (FORMAT csv)


DO $antes$
DECLARE
    v_ids      bigint;
    v_ofertas  bigint;
    v_vendidas bigint;
BEGIN
    SELECT count(*) INTO v_ids FROM lote_borrar;
    IF v_ids = 0 THEN
        RAISE EXCEPTION 'El csv de ids no trajo ninguna fila'
            USING HINT = 'Corre antes mongo/lote/borrar_lote_mongo.js.';
    END IF;

    SELECT count(*) INTO v_ofertas
    FROM oferta WHERE id_producto_mongo IN (SELECT id_producto FROM lote_borrar);

    SELECT count(DISTINCT o.id_oferta) INTO v_vendidas
    FROM pedido_producto pp
    JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
    JOIN oferta o ON o.id_oferta = ph.id_oferta
    WHERE o.id_producto_mongo IN (SELECT id_producto FROM lote_borrar);

    IF v_vendidas > 0 THEN
        RAISE NOTICE 'Se saltan % ofertas que tienen ventas detras: esas no se pueden borrar.', v_vendidas;
        RAISE NOTICE 'Su producto ya no esta en MongoDB, asi que quedan apuntando a un';
        RAISE NOTICE 'documento que no existe. Es lo menos malo: la alternativa era borrar';
        RAISE NOTICE 'el pedido de alguien.';
    END IF;

    RAISE NOTICE 'A borrar: % ofertas de % productos (% se saltan)',
                 v_ofertas - v_vendidas, v_ids, v_vendidas;
END
$antes$;


-- Las que SI se pueden borrar: las que no tienen ninguna linea de pedido
-- detras. Se calcula una vez y se guarda, porque las tres borradas de abajo
-- tienen que mirar exactamente el mismo conjunto.
CREATE TEMP TABLE lote_ofertas_borrables ON COMMIT DROP AS
SELECT o.id_oferta
FROM oferta o
WHERE o.id_producto_mongo IN (SELECT id_producto FROM lote_borrar)
  AND NOT EXISTS (
      SELECT 1
      FROM pedido_producto pp
      JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
      WHERE ph.id_oferta = o.id_oferta);

-- En orden de llaves foraneas: todas son ON DELETE RESTRICT, asi que una
-- borrada fuera de orden falla en vez de arrastrar.
DELETE FROM stock_movimiento WHERE id_oferta IN (SELECT id_oferta FROM lote_ofertas_borrables);
DELETE FROM rechazo_oferta   WHERE id_oferta IN (SELECT id_oferta FROM lote_ofertas_borrables);
DELETE FROM precio_historial WHERE id_oferta IN (SELECT id_oferta FROM lote_ofertas_borrables);
DELETE FROM oferta           WHERE id_oferta IN (SELECT id_oferta FROM lote_ofertas_borrables);


DO $verificar$
DECLARE
    v_mal    bigint;
    v_quedan bigint;
BEGIN
    SELECT count(*) INTO v_mal
    FROM oferta WHERE id_oferta IN (SELECT id_oferta FROM lote_ofertas_borrables);
    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas que se iban a borrar siguen ahi', v_mal;
    END IF;

    -- Ningun resto: ni kardex ni historial de precio de las ofertas borradas.
    SELECT count(*) INTO v_mal
    FROM stock_movimiento WHERE id_oferta IN (SELECT id_oferta FROM lote_ofertas_borrables);
    IF v_mal > 0 THEN
        RAISE EXCEPTION '% movimientos de kardex se quedaron sin su oferta', v_mal;
    END IF;

    SELECT count(*) INTO v_quedan
    FROM oferta WHERE id_producto_mongo IN (SELECT id_producto FROM lote_borrar);

    IF v_quedan = 0 THEN
        RAISE NOTICE 'Borrado verificado. No queda ninguna oferta de esos productos.';
    ELSE
        RAISE NOTICE 'Borrado verificado. Quedan % ofertas, las que tienen ventas detras.', v_quedan;
    END IF;
END
$verificar$;


COMMIT;
