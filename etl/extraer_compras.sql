-- extraer_compras.sql
-- Saca de PostgreSQL las lineas de venta o de devolucion que ClickHouse todavia
-- no tiene, ya en TabSeparated, listas para entrar por una tuberia a
--
--   clickhouse-client ... INSERT INTO compra_producto (...) FORMAT TabSeparated
--
-- No se corre a mano. Lo corre etl/cargar_compras.sh, que sabe que ya esta
-- copiado. Aqui solo se traduce. Es una COPIA y no una mudanza: son dos SELECT
-- y no borran ni actualizan nada, y la verdad de las compras sigue en
-- PostgreSQL (stock_movimiento, pedido, pago).
--
-- Variables de psql, las pone el script:
--
--   :motivo   'venta'  -> compra_producto
--             'devolucion' -> devolucion_producto
--   :ya       lo que ClickHouse ya tiene con lote 'real', como una lista
--             "id_pedido:id_oferta" separada por comas. Vacia la primera vez.
--
--
-- DE DONDE SALE CADA COLUMNA, Y POR QUE STOCK_MOVIMIENTO
-- ============================================================
-- La fuente es stock_movimiento con motivo 'venta' o 'devolucion', y no
-- pedido_producto, por una razon que se midio: pedido_producto guarda lo que el
-- comprador PUSO en el carrito, y stock_movimiento guarda lo que se DESCONTO de
-- verdad al pagar. Solo el segundo existe cuando la compra ocurrio, y solo el
-- segundo tiene fecha de compra. Un pedido pendiente tiene lineas y ninguna
-- venta.
--
--   fecha        fecha_movimiento, en SEGUNDOS DESDE LA EPOCA con milisegundos
--                (extract(epoch ...)), y no como texto "YYYY-MM-DD HH:MM:SS".
--                ClickHouse lee un texto sin zona en la del SERVIDOR, que aqui es
--                America/Guatemala (TZ del docker-compose), y el backend tambien
--                escribe hora de Guatemala. Una epoca es el mismo instante en
--                cualquier zona, asi que este archivo no tiene que saber cual es.
--                (etl/extraer_eventos.sql formatea en UTC y lee mal en esa zona:
--                queda anotado en etl/README.md.)
--   id_producto  el del catalogo, que es el de Mongo (oferta.id_producto_mongo)
--   id_oferta    la oferta que se desconto
--   id_usuario   quien compro, sacado del PEDIDO. id_usuario_modifico del
--                movimiento seria lo mismo hoy, pero es "quien toco el stock" y
--                el dia que un admin cancele un pedido ajeno dejaria de serlo.
--   cantidad     tal cual: en stock_movimiento las ventas y las devoluciones van
--                en positivo y el signo lo lleva el motivo.
--   id_pedido    el pedido
--   ip           '::' -- PostgreSQL no guarda la IP de una compra. Es el mismo
--                comodin que ya usa el ETL de logins para un dato que no existe.
--   lote         'real'
--
-- Sin GROUP BY, una fila por (pedido, oferta): stock_movimiento ya trae una sola
-- por par y motivo (medido: 0 duplicados en 148 filas), y agrupar de mas esconderia
-- una fila repetida el dia que aparezca.
--
--
-- LA DEDUPLICACION ES POR PAR, NO POR MARCA DE AGUA
-- ============================================================
-- etl/cargar_eventos.sh copia "todo lo que este por encima del mayor id ya
-- copiado". Aqui no serviria: hay DOS caminos que escriben compras y el segundo
-- llega tarde. carrito.service.ts anota la compra al instante, pero
-- comprarPedido (pedido pendiente, pedidos.service.ts) NUNCA la anota. Un pedido
-- viejo pagado hoy tendria un id menor que el ultimo copiado, y una marca de agua
-- se lo saltaria para siempre. Por eso se compara contra el CONJUNTO de pares que
-- ClickHouse ya tiene: lo que el backend escribio se respeta, y lo que le falto
-- (o lo que nunca paso por ahi) se completa.
--
-- El par incluye id_oferta y no solo el pedido porque un pedido puede comprar el
-- mismo producto a dos vendedores. Con solo el pedido, la segunda linea se daba
-- por copiada. Ver la clave de ordenacion en clickhouse/001_esquema.sql.
--
-- string_to_array('', ',') es un arreglo vacio, y `<> ALL` contra un arreglo
-- vacio es verdadero: la primera corrida trae todo.

SELECT
    round(extract(epoch FROM sm.fecha_movimiento)::numeric, 3),
    o.id_producto_mongo,
    sm.id_oferta,
    p.id_usuario,
    sm.cantidad,
    sm.id_pedido,
    '::',
    'real'
FROM stock_movimiento sm
JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
JOIN oferta o             ON o.id_oferta = sm.id_oferta
JOIN pedido p             ON p.id_pedido = sm.id_pedido
WHERE mm.motivo_nombre = :'motivo'
  AND sm.id_pedido IS NOT NULL
  AND (sm.id_pedido::text || ':' || sm.id_oferta::text) <> ALL (string_to_array(:'ya', ','))
ORDER BY sm.id_stock_movimiento;
