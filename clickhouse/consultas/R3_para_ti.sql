-- R3_para_ti.sql -- "PARA TI": RECOMENDACIONES POR LOS ULTIMOS GUSTOS DE LA PERSONA
--
-- QUE DEVUELVE: productos que la persona todavia no miro de cerca ni compro,
-- sacados de lo que miraron OTRAS sesiones que vieron lo mismo que ella hace
-- poco. Es R2 aplicada a varios productos a la vez y con memoria que se apaga.
--
-- COMO:
--   1. Semillas: los ultimos `semillas` productos distintos que miro.
--   2. Cada semilla pesa segun que tan reciente es, con vida media de
--      `vida_media_horas`: lo que miro hace una hora pesa 1, lo de hace tres
--      dias pesa 0.5 (con 72 h), lo de hace seis 0.25. "Ultimos gustos" quiere
--      decir eso: lo de ayer manda sobre lo del mes pasado, sin borrarlo.
--   3. Se buscan las sesiones de OTRAS personas que vieron cada semilla, y todo
--      lo demas que vieron esas sesiones es candidato. El puntaje de un
--      candidato es la suma de los pesos de las semillas que lo trajeron,
--      dividida por la raiz de su popularidad (ver abajo).
--   4. Se quitan las semillas y lo que ya compro.
--
-- `porque_viste` dice que semillas trajeron cada candidato: es el "porque
-- viste X" que el portal puede mostrar, y lo que hace revisable la regla.
--
-- Si la persona no tiene historial, esto devuelve vacio y el backend cae a T1
-- (lo que esta en ascenso). Esta escrito en docs/fraude-entrega3/03-clickhouse.md.
--
-- Parametros: lote, usuario, dias_historial, semillas, vida_media_horas, limite.
WITH
    semillas AS (
        SELECT id_producto,
               exp2(-dateDiff('second', max(fecha), now()) / 3600
                    / {vida_media_horas:Float64}) AS peso
          FROM vista_producto
         WHERE lote = {lote:String}
           AND id_usuario = {usuario:UInt64}
           AND fecha >= now() - INTERVAL {dias_historial:UInt32} DAY
         GROUP BY id_producto
         ORDER BY max(fecha) DESC
         LIMIT {semillas:UInt32}
    ),
    ajenos AS (
        -- Solo sesiones de otras personas. Las propias recomendarian lo que ella
        -- ya vio, que no es recomendar.
        SELECT DISTINCT sesion, id_producto
          FROM vista_producto
         WHERE lote = {lote:String}
           AND fecha >= now() - INTERVAL {dias_historial:UInt32} DAY
           AND (id_usuario IS NULL OR id_usuario != {usuario:UInt64})
    ),
    puentes AS (
        SELECT a.sesion AS sesion, s.id_producto AS semilla, s.peso AS peso
          FROM ajenos AS a
         INNER JOIN semillas AS s ON s.id_producto = a.id_producto
    ),
    alcance AS (
        SELECT id_producto, count() AS sesiones FROM ajenos GROUP BY id_producto
    )
-- El puntaje se divide por la raiz de cuantas sesiones ven el candidato en
-- general, por lo mismo que la afinidad de R2: sin eso, "para ti" termina
-- siendo "lo mas visto de la tienda" para todo el mundo. Medido en la prueba:
-- sin dividir, el producto popular (24 sesiones) salia PRIMERO para la cuenta
-- 1001 solo por estar en todas partes; dividiendo sale ultimo y arriba quedan
-- los que se miran junto con lo que ella miro.
SELECT
    c.id_producto                                       AS id_producto,
    round(sum(p.peso) / sqrt(any(a.sesiones)), 3)       AS puntaje,
    uniqExact(c.sesion)                                 AS sesiones,
    arraySort(groupUniqArray(p.semilla))                AS porque_viste
FROM ajenos AS c
INNER JOIN puentes AS p ON p.sesion = c.sesion
INNER JOIN alcance AS a ON a.id_producto = c.id_producto
WHERE c.id_producto NOT IN (SELECT id_producto FROM semillas)
  AND c.id_producto NOT IN (
        SELECT id_producto FROM compra_producto
         WHERE lote = {lote:String} AND id_usuario = {usuario:UInt64})
GROUP BY c.id_producto
ORDER BY puntaje DESC, sesiones DESC, id_producto
LIMIT {limite:UInt32};
