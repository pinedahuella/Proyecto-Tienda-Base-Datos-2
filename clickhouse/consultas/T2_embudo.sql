-- T2_embudo.sql -- DONDE SE CAE LA VENTA: VISTA, CARRITO, COMPRA, DEVOLUCION
--
-- QUE DEVUELVE: por producto, cuantas sesiones lo vieron, cuantas cuentas lo
-- agregaron al carrito, cuantos pedidos y unidades salieron y cuantas volvieron.
-- Y un diagnostico, solo para los que tienen un problema:
--
--   mucho_interes_poca_compra  al menos `min_sesiones_embudo` sesiones lo
--                              vieron y la conversion (pedidos / sesiones) no
--                              pasa de `max_conversion`. La gente llega y se va:
--                              precio, fotos o descripcion.
--   devolucion_alta            lo que vuelve es al menos `min_tasa_devolucion`
--                              de lo vendido. El producto no es lo que dice.
--
-- Es una pregunta que en PostgreSQL no se puede hacer: ahi solo existe la
-- compra, las vistas y los carritos que no terminaron no se guardan.
--
-- FINAL en las dos tablas ReplacingMergeTree: sin el, una compra que el ETL
-- cargo dos veces cuenta dos veces hasta que ClickHouse fusione las partes.
--
-- Parametros: lote, dias_ventana, min_sesiones_embudo, max_conversion,
-- min_tasa_devolucion, limite.
WITH
    v AS (SELECT id_producto, uniqExact(sesion) AS sesiones FROM vista_producto
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY id_producto),
    c AS (SELECT id_producto, uniqExact(id_usuario) AS en_carrito FROM carrito_producto
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY id_producto),
    k AS (SELECT id_producto, uniqExact(id_pedido) AS pedidos, sum(cantidad) AS unidades
            FROM compra_producto FINAL
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY id_producto),
    -- Sin lo que cancelo la tienda: el comprador no lo devolvio (2026-11-07).
    d AS (SELECT id_producto, sum(cantidad) AS devueltas FROM devolucion_producto FINAL
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
             AND por_la_tienda = 0
           GROUP BY id_producto),
    ids AS (SELECT id_producto FROM v UNION DISTINCT SELECT id_producto FROM k)
SELECT
    ids.id_producto                                             AS id_producto,
    v.sesiones                                                  AS sesiones,
    c.en_carrito                                                AS en_carrito,
    k.pedidos                                                   AS pedidos,
    k.unidades                                                  AS unidades,
    d.devueltas                                                 AS devueltas,
    if(sesiones = 0, 0, round(pedidos / sesiones, 3))           AS conversion,
    if(unidades = 0, 0, round(devueltas / unidades, 2))         AS tasa_devolucion,
    multiIf(sesiones >= {min_sesiones_embudo:UInt32}
              AND conversion <= {max_conversion:Float64}, 'mucho_interes_poca_compra',
            unidades > 0
              AND tasa_devolucion >= {min_tasa_devolucion:Float64}, 'devolucion_alta',
            'normal')                                           AS diagnostico
FROM ids
LEFT JOIN v ON v.id_producto = ids.id_producto
LEFT JOIN c ON c.id_producto = ids.id_producto
LEFT JOIN k ON k.id_producto = ids.id_producto
LEFT JOIN d ON d.id_producto = ids.id_producto
WHERE diagnostico != 'normal'
ORDER BY diagnostico, sesiones DESC
LIMIT {limite:UInt32};
