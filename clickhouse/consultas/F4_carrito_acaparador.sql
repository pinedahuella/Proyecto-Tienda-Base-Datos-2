-- F4_carrito_acaparador.sql -- LA CUENTA QUE LLENA EL CARRITO Y NO COMPRA
--
-- FUERA DE USO desde el 2026-10-17 (limpieza de fraude de Jose David, migracion 042):
-- el tipo carrito_acaparador no existe. Su premisa (apartar unidades hasta que el
-- carrito vence) quedo vieja con el carrito en PostgreSQL: una oferta normal no
-- reserva nada, y una venta relampago reserva 15 min con PostgreSQL impidiendo vender
-- de mas. Se deja como historia; clickhouse/pruebas/comprobar.py la sigue midiendo.
--
-- QUE DEVUELVE: pares (cuenta, producto) donde la cuenta agrego al carrito al
-- menos `min_unidades_acaparadas` unidades y compro a lo sumo
-- `max_tasa_compra_acaparador` de ellas.
--
-- POR QUE IMPORTA, en esta tienda en concreto: la venta relampago aparta
-- existencias al agregar al carrito (migrations/014_inventario_limitado.sql y
-- el Lua de Redis). Quien agrega 40 unidades de una oferta limitada y no compra
-- las deja secuestradas hasta que el carrito vence: es sacar del mercado a los
-- demas compradores sin pagar nada. Tambien es como se ve un bot de reventa
-- probando cuanto puede apartar.
--
-- `veces` al lado: 40 unidades de un solo golpe es un error de dedo; 40
-- agregadas de a una en diez minutos es un guion.
--
-- Parametros: lote, dias_ventana, min_unidades_acaparadas,
-- max_tasa_compra_acaparador, limite.
WITH
    carrito AS (SELECT id_usuario, id_producto, sum(cantidad) AS agregadas, count() AS veces
                  FROM carrito_producto
                 WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                 GROUP BY id_usuario, id_producto),
    compra  AS (SELECT id_usuario, id_producto, sum(cantidad) AS compradas
                  FROM compra_producto FINAL
                 WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
                 GROUP BY id_usuario, id_producto)
SELECT
    c.id_usuario                              AS id_usuario,
    c.id_producto                             AS id_producto,
    c.agregadas                               AS agregadas,
    c.veces                                   AS veces,
    k.compradas                               AS compradas,
    round(k.compradas / c.agregadas, 2)       AS tasa_compra
FROM carrito AS c
LEFT JOIN compra AS k ON k.id_usuario = c.id_usuario AND k.id_producto = c.id_producto
WHERE c.agregadas >= {min_unidades_acaparadas:UInt32}
  AND tasa_compra <= {max_tasa_compra_acaparador:Float64}
ORDER BY c.agregadas DESC
LIMIT {limite:UInt32};
