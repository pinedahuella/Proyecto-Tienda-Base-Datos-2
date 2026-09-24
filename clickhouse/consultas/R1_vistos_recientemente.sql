-- R1_vistos_recientemente.sql -- "VISTOS RECIENTEMENTE", COMO EN CUALQUIER TIENDA EN LINEA
--
-- QUE DEVUELVE: los ultimos productos distintos que miro una persona, del mas
-- nuevo al mas viejo, y si ya los compro.
--
-- QUIEN ES "LA PERSONA": su cuenta si inicio sesion, o su `sesion` si no. Las
-- dos a la vez, con OR, porque quien mira sin cuenta y despues entra tiene que
-- ver tambien lo que miro antes de entrar (misma sesion, id_usuario NULL). El
-- backend pasa usuario = 0 cuando no hay cuenta; ningun id real es 0.
--
-- `ya_comprado` no filtra, informa: el portal decide si esconderlos (para
-- "vistos recientemente" conviene mostrarlos; para "para ti", R3 los quita).
--
-- Parametros: lote, usuario, sesion, dias_historial, limite.
SELECT
    id_producto,
    max(fecha)                AS ultima_vista,
    count()                   AS veces,
    id_producto IN (
        SELECT id_producto FROM compra_producto
         WHERE lote = {lote:String} AND id_usuario = {usuario:UInt64}
    )                         AS ya_comprado
FROM vista_producto
WHERE lote = {lote:String}
  AND fecha >= now() - INTERVAL {dias_historial:UInt32} DAY
  AND (({usuario:UInt64} != 0 AND id_usuario = {usuario:UInt64})
       OR sesion = {sesion:String})
GROUP BY id_producto
ORDER BY ultima_vista DESC
LIMIT {limite:UInt32};
