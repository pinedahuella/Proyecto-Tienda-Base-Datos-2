-- F6_granja_de_registros.sql -- MUCHAS CUENTAS NACIDAS DESDE LA MISMA IP EN POCO TIEMPO
--
-- FUERA DE USO EN EL BACKEND desde el 2026-10-17: la granja de registros sale de
-- Elasticsearch (mesh_eventos_autenticacion), en
-- FraudeLoginRetrospectivoService.evaluarGranjaDeRegistros(), con los mismos numeros
-- (5 cuentas en 60 min, 30 dias). En ClickHouse nunca podia dispararse: evento_registro
-- esta vacia desde que el backend dejo de escribir log_registro el 2026-09-10. Se deja
-- como historia.
--
-- QUE DEVUELVE: IPs desde las que se registraron al menos
-- `min_registros_por_ip` cuentas dentro de una ventana de `minutos_registro`
-- minutos, con las cuentas de la peor ventana.
--
-- POR QUE IMPORTA: es el nacimiento de lo que Neo4j ve despues como granja
-- (B.2) o como reputacion expres (B.7). El grafo ve las cuentas cuando ya
-- resenaron; esta consulta las ve el dia que nacieron, antes de que hagan
-- nada. Y las listas de ids son las que el backend cruza con el grafo.
--
-- Ventana movil por self-join, por lo mismo que F2.
--
-- Parametros: lote, dias_ventana, minutos_registro, min_registros_por_ip,
-- ips_de_confianza, limite.
WITH r AS (
    SELECT ip, id_usuario, fecha
      FROM evento_registro FINAL
     WHERE lote = {lote:String}
       AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
       AND NOT has({ips_de_confianza:Array(String)}, toString(ip))
       AND ip != toIPv6('::')          -- IP desconocida, ver F3
)
SELECT
    toString(ip)                                  AS ip,
    max(cuantas)                                  AS cuentas_en_la_peor_ventana,
    argMax(desde, cuantas)                        AS empezo,
    arraySort(argMax(cuentas_de_la_ventana, cuantas)) AS cuentas
FROM (
    SELECT a.ip AS ip, a.fecha AS desde,
           countIf(b.fecha >= a.fecha
                   AND b.fecha < a.fecha + toIntervalMinute({minutos_registro:UInt32})) AS cuantas,
           groupArrayIf(b.id_usuario, b.fecha >= a.fecha
                   AND b.fecha < a.fecha + toIntervalMinute({minutos_registro:UInt32})) AS cuentas_de_la_ventana
      FROM r AS a INNER JOIN r AS b ON b.ip = a.ip
     GROUP BY a.ip, a.id_usuario, a.fecha
)
GROUP BY ip
HAVING cuentas_en_la_peor_ventana >= {min_registros_por_ip:UInt32}
ORDER BY cuentas_en_la_peor_ventana DESC
LIMIT {limite:UInt32};
