-- T3_busquedas_sin_respuesta.sql -- LO QUE LA GENTE PIDE Y LA TIENDA NO TIENE
--
-- QUE DEVUELVE: terminos de busqueda con un problema, y cual:
--
--   no_tenemos    todas las busquedas del termino dieron CERO resultados.
--                 Es demanda que se va a otra tienda: lo primero que un
--                 vendedor querria saber.
--   no_convence   hubo resultados y nadie hizo clic en ninguno. El catalogo
--                 tiene algo, pero no lo que se busca, o no se ve bien.
--
-- Se exige `min_sesiones_busqueda` sesiones distintas: una persona que busco
-- "asdf" tres veces no es demanda.
--
-- El termino se compara en minusculas y sin espacios en las puntas. El backend
-- lo guarda tal como se escribio, y "Dron" y "dron " son la misma demanda.
--
-- Parametros: lote, dias_ventana, min_sesiones_busqueda, limite.
WITH
    b AS (SELECT lower(trim(BOTH ' ' FROM termino)) AS t,
                 count() AS busquedas, uniqExact(sesion) AS sesiones,
                 countIf(resultados = 0) AS sin_resultados,
                 max(resultados) AS mas_resultados
            FROM busqueda_realizada
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY t),
    k AS (SELECT lower(trim(BOTH ' ' FROM termino)) AS t, count() AS clics
            FROM busqueda_clic
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY t)
SELECT
    b.t              AS termino,
    b.busquedas      AS busquedas,
    b.sesiones       AS sesiones,
    b.mas_resultados AS mas_resultados,
    k.clics          AS clics,
    multiIf(b.sin_resultados = b.busquedas, 'no_tenemos',
            k.clics = 0,                    'no_convence',
            'normal') AS diagnostico
FROM b LEFT JOIN k ON k.t = b.t
WHERE b.sesiones >= {min_sesiones_busqueda:UInt32}
  AND diagnostico != 'normal'
ORDER BY diagnostico, sesiones DESC
LIMIT {limite:UInt32};
