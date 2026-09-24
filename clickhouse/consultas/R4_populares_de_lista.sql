-- R4_populares_de_lista.sql -- "SIMILARES": LOS MAS BUSCADOS DE UNA LISTA QUE DA EL BACKEND
--
-- QUE DEVUELVE: de una lista de productos candidatos, cuales se estan moviendo
-- mas en los ultimos `dias_recientes` dias, con un puntaje que pesa distinto
-- mirar, agregar al carrito y comprar.
--
-- POR QUE RECIBE LA LISTA EN VEZ DE SACARLA: "similar" en esta tienda quiere
-- decir "de la misma categoria y parecido precio", y la categoria vive en
-- MongoDB, no aqui. ClickHouse guarda eventos con ids sueltos a proposito
-- (clickhouse/README.md: es una proyeccion, no el catalogo). Asi que el reparto
-- es: Mongo contesta "que productos son parecidos a este" y ClickHouse contesta
-- "de esos, cuales quiere la gente ahora". Cada base hace lo que sabe.
--
-- Los pesos 1 / 3 / 5: una vista es curiosidad, un carrito es intencion, una
-- compra es decision. Se escriben aqui y no como parametro porque cambiarlos
-- cambia el significado del puntaje, no un umbral.
--
-- Un candidato sin ningun evento no sale: el backend lo pone al final.
--
-- Parametros: lote, candidatos (Array(UInt64)), dias_recientes, limite.
SELECT
    id_producto,
    sum(puntos)                    AS puntaje,
    sumIf(n, tipo = 'vista')       AS sesiones_que_lo_vieron,
    sumIf(n, tipo = 'carrito')     AS cuentas_que_lo_agregaron,
    sumIf(n, tipo = 'compra')      AS unidades_vendidas
FROM (
    SELECT id_producto, 'vista' AS tipo, uniqExact(sesion) AS n, n * 1 AS puntos
      FROM vista_producto
     WHERE lote = {lote:String}
       AND fecha >= now() - INTERVAL {dias_recientes:UInt32} DAY
       AND has({candidatos:Array(UInt64)}, id_producto)
     GROUP BY id_producto
    UNION ALL
    SELECT id_producto, 'carrito', uniqExact(id_usuario), uniqExact(id_usuario) * 3
      FROM carrito_producto
     WHERE lote = {lote:String}
       AND fecha >= now() - INTERVAL {dias_recientes:UInt32} DAY
       AND has({candidatos:Array(UInt64)}, id_producto)
     GROUP BY id_producto
    UNION ALL
    SELECT id_producto, 'compra', sum(cantidad), sum(cantidad) * 5
      FROM compra_producto FINAL
     WHERE lote = {lote:String}
       AND fecha >= now() - INTERVAL {dias_recientes:UInt32} DAY
       AND has({candidatos:Array(UInt64)}, id_producto)
     GROUP BY id_producto
)
GROUP BY id_producto
ORDER BY puntaje DESC, id_producto
LIMIT {limite:UInt32};
