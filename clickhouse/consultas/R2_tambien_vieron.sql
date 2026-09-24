-- R2_tambien_vieron.sql -- "QUIENES VIERON ESTE PRODUCTO TAMBIEN VIERON"
--
-- QUE DEVUELVE: para un producto P, los productos que aparecen en las mismas
-- sesiones que P, ordenados por AFINIDAD.
--
-- POR QUE AFINIDAD Y NO "CUANTAS SESIONES EN COMUN": con el conteo pelado,
-- el producto mas visto de la tienda sale "parecido" a todo, porque aparece en
-- todas las sesiones. La afinidad es el coseno:
--
--     sesiones_en_comun / sqrt(sesiones_de_P * sesiones_de_Q)
--
-- y castiga a Q por ser popular en general. Medido en la prueba, con P visto
-- en 8 sesiones: un producto con 4 sesiones en comun pero visto en 24 da
-- 4 / raiz(8 x 24) = 0.289; otro con 3 en comun visto en solo 3 da
-- 3 / raiz(8 x 3) = 0.612 y sale primero, que es lo correcto -- el segundo se
-- mira CON P, el primero se mira con todo.
--
-- `min_sesiones_en_comun` evita que una sola sesion rara arme una relacion.
--
-- Cada (sesion, producto) cuenta una vez: alguien que refresca la ficha diez
-- veces no es diez personas.
--
-- Parametros: lote, producto, dias_historial, min_sesiones_en_comun, limite.
WITH
    pares AS (
        SELECT DISTINCT sesion, id_producto
          FROM vista_producto
         WHERE lote = {lote:String}
           AND fecha >= now() - INTERVAL {dias_historial:UInt32} DAY
    ),
    alcance AS (
        SELECT id_producto, count() AS sesiones FROM pares GROUP BY id_producto
    )
SELECT
    q.id_producto                                        AS id_producto,
    count()                                              AS sesiones_en_comun,
    any(a.sesiones)                                      AS sesiones_del_producto,
    round(count() / sqrt(
        (SELECT sesiones FROM alcance WHERE id_producto = {producto:UInt64})
        * any(a.sesiones)), 3)                           AS afinidad
FROM pares AS q
INNER JOIN alcance AS a ON a.id_producto = q.id_producto
WHERE q.sesion IN (SELECT sesion FROM pares WHERE id_producto = {producto:UInt64})
  AND q.id_producto != {producto:UInt64}
GROUP BY q.id_producto
HAVING sesiones_en_comun >= {min_sesiones_en_comun:UInt32}
ORDER BY afinidad DESC, sesiones_en_comun DESC
LIMIT {limite:UInt32};
