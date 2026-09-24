-- F1_vistas_infladas.sql -- EL PRODUCTO QUE ALGUIEN ESTA INFLANDO
--
-- QUE DEVUELVE: productos cuyas vistas vienen de muy pocas sesiones: al menos
-- `min_vistas_por_sesion` vistas por sesion en promedio.
--
-- POR QUE IMPORTA: "mas vistos" y "en ascenso" (T1) se alimentan de vistas.
-- Un vendedor que refresca su propia ficha 300 veces desde tres pestanas sube
-- a la portada sin que nadie lo haya querido ver. Esta consulta es la que
-- separa la moda del empuje, y T1 lleva la misma medida en una columna.
--
-- `ips` al lado: tres sesiones desde una sola IP es una persona con tres
-- ventanas.
--
-- Parametros: lote, dias_ventana, min_vistas_por_sesion, limite.
SELECT
    id_producto,
    count()                                  AS vistas,
    uniqExact(sesion)                        AS sesiones,
    round(vistas / sesiones, 1)              AS vistas_por_sesion,
    uniqExact(ip)                            AS ips,
    topK(3)(sesion)                          AS sesiones_que_mas_miran
FROM vista_producto
WHERE lote = {lote:String}
  AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
GROUP BY id_producto
HAVING vistas_por_sesion >= {min_vistas_por_sesion:UInt32}
ORDER BY vistas_por_sesion DESC
LIMIT {limite:UInt32};
