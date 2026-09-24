-- F5_devoluciones_seriales.sql -- LA CUENTA QUE DEVUELVE CASI TODO
--
-- QUE DEVUELVE: cuentas con al menos `min_devoluciones` unidades devueltas y
-- una tasa (devueltas / compradas) de al menos `min_tasa_devolucion_cuenta`.
--
-- POR QUE IMPORTA: T2 mira la devolucion desde el PRODUCTO (el producto no es
-- lo que dice). Esta la mira desde la CUENTA: quien compra, usa y devuelve, o
-- quien compra para poder resenar y despues devuelve. Lo segundo cruza con el
-- grafo: una cuenta de un anillo que devuelve lo que compro gano su resena
-- gratis, y la regla R-CASI-3 del backend lo trata asi.
--
-- Se exige un minimo absoluto ademas de la tasa: 1 devuelta de 1 comprada es
-- el 100 % y no dice nada.
--
-- Parametros: lote, dias_ventana, min_devoluciones, min_tasa_devolucion_cuenta, limite.
WITH
    k AS (SELECT id_usuario, sum(cantidad) AS compradas, uniqExact(id_pedido) AS pedidos
            FROM compra_producto FINAL
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY id_usuario),
    d AS (SELECT id_usuario, sum(cantidad) AS devueltas
            FROM devolucion_producto FINAL
           WHERE lote = {lote:String} AND fecha >= now() - INTERVAL {dias_ventana:UInt32} DAY
           GROUP BY id_usuario)
SELECT
    d.id_usuario                          AS id_usuario,
    k.pedidos                             AS pedidos,
    k.compradas                           AS compradas,
    d.devueltas                           AS devueltas,
    round(d.devueltas / greatest(k.compradas, 1), 2) AS tasa_devolucion
FROM d LEFT JOIN k ON k.id_usuario = d.id_usuario
WHERE d.devueltas >= {min_devoluciones:UInt32}
  AND tasa_devolucion >= {min_tasa_devolucion_cuenta:Float64}
ORDER BY tasa_devolucion DESC, devueltas DESC
LIMIT {limite:UInt32};
