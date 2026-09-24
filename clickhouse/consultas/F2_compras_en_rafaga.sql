-- F2_compras_en_rafaga.sql -- MUCHOS PEDIDOS DE UNA CUENTA EN POCOS MINUTOS
--
-- QUE DEVUELVE: cuentas que hicieron al menos `min_pedidos_rafaga` pedidos
-- dentro de una ventana de `minutos_rafaga` minutos, en cualquier momento del
-- periodo. Con el momento de la peor rafaga.
--
-- POR QUE IMPORTA, en esta tienda en concreto: para calificar hace falta una
-- compra pagada. Un anillo tiene que COMPRAR antes de resenar, y un guion que
-- arma cuentas compra en rafaga. Esta es la huella de compra de lo que Neo4j ve
-- como anillo, y por eso las reglas del backend cruzan las dos (ver
-- docs/fraude-entrega3/02-reglas-backend.md). Tambien es la cara de una tarjeta
-- robada: vaciarla antes de que la bloqueen.
--
-- VENTANA MOVIL, no cubetas de 15 minutos: con cubetas fijas, cinco pedidos
-- entre las 10:08 y las 10:22 quedan partidos en dos cubetas de 2 y 3 y no
-- salen. Aqui cada pedido abre su propia ventana y se cuentan los que caen
-- dentro. Es la misma leccion que la A.3 del grafo, que antes media un rango y
-- no una ventana.
--
-- Se hace con un self-join y no con una funcion de ventana RANGE porque el
-- ancho del RANGE de ClickHouse tiene que ser un literal y aqui es un parametro.
--
-- Parametros: lote, dias_ventana, minutos_rafaga, min_pedidos_rafaga, limite.
-- El alias es `momento` y no `fecha` a proposito: ClickHouse deja que un alias
-- del SELECT tape a la columna del mismo nombre en el WHERE, y con
-- "min(fecha) AS fecha" el filtro de fecha se convertia en un agregado dentro
-- del WHERE (ILLEGAL_AGGREGATION). En PostgreSQL eso no pasa.
WITH pedidos AS (
    SELECT id_usuario, id_pedido, min(fecha) AS momento, any(ip) AS ip
      FROM compra_producto FINAL
     WHERE lote = {lote:String}
       AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
     GROUP BY id_usuario, id_pedido
)
SELECT
    id_usuario,
    max(en_ventana)                 AS pedidos_en_la_peor_rafaga,
    argMax(desde, en_ventana)       AS empezo,
    any(total)                      AS pedidos_en_el_periodo
FROM (
    SELECT p.id_usuario AS id_usuario, p.momento AS desde,
           countIf(q.momento >= p.momento
                   AND q.momento < p.momento + toIntervalMinute({minutos_rafaga:UInt32})) AS en_ventana
      FROM pedidos AS p
     INNER JOIN pedidos AS q ON q.id_usuario = p.id_usuario
     GROUP BY p.id_usuario, p.id_pedido, p.momento
) AS r
INNER JOIN (SELECT id_usuario, count() AS total FROM pedidos GROUP BY id_usuario) AS t USING (id_usuario)
GROUP BY id_usuario
HAVING pedidos_en_la_peor_rafaga >= {min_pedidos_rafaga:UInt32}
ORDER BY pedidos_en_la_peor_rafaga DESC
LIMIT {limite:UInt32};
