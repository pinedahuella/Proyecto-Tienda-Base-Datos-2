-- siembra_consultas.sql -- lo que las consultas de clickhouse/consultas/ tienen que encontrar, y lo que NO
--
-- Se carga en una base APARTE, mesh_prueba_consultas, que el arnes
-- (clickhouse/correr_consultas.sh) crea con el mismo 001_esquema.sql y borra al
-- terminar. La base de eventos real (mesh_eventos) no se toca: ClickHouse no
-- tiene transacciones que deshacer, y borrar filas de una tabla con vista
-- materializada deja el resumen desfasado (clickhouse/README.md, "borrar un
-- lote son DOS mitades"). Una base entera que se tira es lo unico limpio.
--
-- Todas las fechas son relativas a now(): las consultas miran "los ultimos N
-- dias" y con fechas fijas la prueba dejaria de pasar sola.
--
-- Los ids son chicos e inventados (productos 1 a 99, cuentas 1001 a 6006).
-- Cada escenario usa sus propios ids para que ninguno dispare otro sin querer.
-- Todo va con lote = 'real' porque la base entera es de prueba.

-- ============================================================
-- R1 VISTOS RECIENTEMENTE: la cuenta 1001, en su sesion u1001
-- ============================================================
-- Miro el 1 dos veces, despues el 2, despues el 3. Compro el 2. El 8 lo miro
-- hace 40 dias: fuera del historial de 30. El 4 lo miro alguien SIN cuenta en
-- otra sesion: no es de 1001.
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
VALUES (now64(3) - INTERVAL 5 HOUR,  1, 1001, 'u1001', toIPv6('::ffff:10.1.0.1'), 'catalogo'),
       (now64(3) - INTERVAL 4 HOUR,  1, 1001, 'u1001', toIPv6('::ffff:10.1.0.1'), 'catalogo'),
       (now64(3) - INTERVAL 3 HOUR,  2, 1001, 'u1001', toIPv6('::ffff:10.1.0.1'), 'catalogo'),
       (now64(3) - INTERVAL 1 HOUR,  3, 1001, 'u1001', toIPv6('::ffff:10.1.0.1'), 'buscador'),
       (now64(3) - INTERVAL 40 DAY,  8, 1001, 'u1001-vieja', toIPv6('::ffff:10.1.0.1'), 'catalogo'),
       (now64(3) - INTERVAL 2 HOUR,  4, NULL, 'anonima', toIPv6('::ffff:10.1.0.2'), 'directo');
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
VALUES (now64(3) - INTERVAL 150 MINUTE, 2, 2, 1001, 1, 90001, toIPv6('::ffff:10.1.0.1')),
       (now64(3) - INTERVAL 10 DAY,    16, 16, 1001, 1, 90002, toIPv6('::ffff:10.1.0.1'));


-- ============================================================
-- R2 / R3 CO-VISITAS: otras sesiones alrededor del producto 3
-- ============================================================
--   sa: 3, 10, 11, 16    sb: 3, 10    sc: 3, 10, 12    sd: 1, 11
--   sf, sg, sh, si: 3, 15             y el 15 solo en otras 20 sesiones
-- El 10 se ve SIEMPRE con el 3 (3 de 3 sesiones); el 15 esta en todas partes
-- (24 sesiones). El 16 lo compro 1001: R3 no se lo puede recomendar.
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - INTERVAL 1 DAY, p, NULL, s, toIPv6('::ffff:10.2.0.1'), 'catalogo'
  FROM (SELECT arrayJoin([('sa', 3), ('sa', 10), ('sa', 11), ('sa', 16),
                          ('sb', 3), ('sb', 10),
                          ('sc', 3), ('sc', 10), ('sc', 12),
                          ('sd', 1), ('sd', 11),
                          ('sf', 3), ('sf', 15), ('sg', 3), ('sg', 15),
                          ('sh', 3), ('sh', 15), ('si', 3), ('si', 15)]) AS t,
               t.1 AS s, t.2 AS p);
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - INTERVAL 2 DAY, 15, NULL, concat('solo15-', toString(number)),
       toIPv6('::ffff:10.2.0.2'), 'catalogo'
  FROM numbers(20);


-- ============================================================
-- R4 POPULARES DE UNA LISTA: los candidatos 10, 11, 12, 15 y 99
-- ============================================================
-- Ademas de las vistas de arriba: tres cuentas agregan el 12 al carrito (3 x 3
-- puntos) y se venden dos unidades del 11 (2 x 5). El 99 no tiene nada.
INSERT INTO carrito_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, ip)
SELECT now64(3) - INTERVAL 1 DAY, 12, 12, 1200 + number, 1, toIPv6('::ffff:10.3.0.1')
  FROM numbers(3);
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
VALUES (now64(3) - INTERVAL 1 DAY, 11, 11, 1210, 2, 90010, toIPv6('::ffff:10.3.0.2'));


-- ============================================================
-- T1 EN ASCENSO
-- ============================================================
-- El 20: una vista por dia durante tres semanas y diez por dia la ultima.
-- El 21: cinco por dia, parejo (no crecio). El 22: 15 vistas nuevas y nada
-- antes (crecio, pero con muy poco volumen).
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - toIntervalDay(8 + number), 20, NULL, concat('t20b-', toString(number)),
       toIPv6('::ffff:10.4.0.1'), 'catalogo'
  FROM numbers(20);
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - toIntervalDay(intDiv(number, 10)) - INTERVAL 1 HOUR, 20, NULL,
       concat('t20r-', toString(number)), toIPv6('::ffff:10.4.0.1'), 'catalogo'
  FROM numbers(70);
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - toIntervalDay(intDiv(number, 5)) - INTERVAL 1 HOUR, 21, NULL,
       concat('t21-', toString(number)), toIPv6('::ffff:10.4.0.2'), 'catalogo'
  FROM numbers(140);
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - INTERVAL 1 DAY, 22, NULL, concat('t22-', toString(number)),
       toIPv6('::ffff:10.4.0.3'), 'catalogo'
  FROM numbers(15);


-- ============================================================
-- T2 EMBUDO
-- ============================================================
-- El 25: 25 sesiones lo miran, nadie lo compra. El 24 (control): 25 sesiones
-- y 5 pedidos, conversion 0.2. El 26: se vende 10 veces y vuelven 4.
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - INTERVAL 3 DAY, p, NULL, concat('emb', toString(p), '-', toString(number)),
       toIPv6('::ffff:10.5.0.1'), 'catalogo'
  FROM numbers(25) ARRAY JOIN [24, 25] AS p;
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 3 DAY, 24, 24, 2400 + number, 1, 92400 + number,
       toIPv6(concat('::ffff:10.24.0.', toString(number)))
  FROM numbers(5);
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 6 DAY, 26, 26, 2600 + number, 1, 92600 + number,
       toIPv6(concat('::ffff:10.26.0.', toString(number)))
  FROM numbers(10);
INSERT INTO devolucion_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 2 DAY, 26, 26, 2600 + number, 1, 92600 + number,
       toIPv6(concat('::ffff:10.26.0.', toString(number)))
  FROM numbers(4);


-- ============================================================
-- T3 BUSQUEDAS SIN RESPUESTA
-- ============================================================
-- "dron acuatico": 4 sesiones, cero resultados, una escrita con mayusculas y
-- espacios (tiene que contar igual). "cable hdmi": 3 sesiones, hay resultados
-- y nadie hace clic. "mouse" (control): hay clics. "asdf" (control): una sola
-- sesion, tres veces.
INSERT INTO busqueda_realizada (fecha, termino, resultados, id_usuario, sesion)
VALUES (now64(3) - INTERVAL 1 DAY, 'dron acuatico',   0, NULL, 'b1'),
       (now64(3) - INTERVAL 1 DAY, 'dron acuatico',   0, NULL, 'b2'),
       (now64(3) - INTERVAL 1 DAY, 'dron acuatico',   0, NULL, 'b3'),
       (now64(3) - INTERVAL 1 DAY, ' Dron Acuatico ', 0, NULL, 'b4'),
       (now64(3) - INTERVAL 1 DAY, 'cable hdmi',     12, NULL, 'b1'),
       (now64(3) - INTERVAL 1 DAY, 'cable hdmi',     12, NULL, 'b2'),
       (now64(3) - INTERVAL 1 DAY, 'cable hdmi',     12, NULL, 'b3'),
       (now64(3) - INTERVAL 1 DAY, 'mouse',           8, NULL, 'b1'),
       (now64(3) - INTERVAL 1 DAY, 'mouse',           8, NULL, 'b2'),
       (now64(3) - INTERVAL 1 DAY, 'mouse',           8, NULL, 'b3'),
       (now64(3) - INTERVAL 1 DAY, 'asdf',            0, NULL, 'b9'),
       (now64(3) - INTERVAL 1 DAY, 'asdf',            0, NULL, 'b9'),
       (now64(3) - INTERVAL 1 DAY, 'asdf',            0, NULL, 'b9');
INSERT INTO busqueda_clic (fecha, termino, id_producto, posicion, id_usuario, sesion)
VALUES (now64(3) - INTERVAL 1 DAY, 'mouse', 40, 1, NULL, 'b1'),
       (now64(3) - INTERVAL 1 DAY, 'mouse', 41, 2, NULL, 'b2');


-- ============================================================
-- F1 VISTAS INFLADAS: el 27, 300 vistas desde 3 sesiones y una IP
-- ============================================================
INSERT INTO vista_producto (fecha, id_producto, id_usuario, sesion, ip, origen)
SELECT now64(3) - toIntervalMinute(number), 27, NULL, concat('inflado-', toString(number % 3)),
       toIPv6('::ffff:10.6.0.1'), 'directo'
  FROM numbers(300);


-- ============================================================
-- F2 COMPRAS EN RAFAGA
-- ============================================================
-- 2001: seis pedidos, uno cada dos minutos. 2002 (control): seis pedidos, uno
-- por dia.
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 2 DAY + toIntervalMinute(2 * number), 50, 50, 2001, 1,
       92001 * 10 + number, toIPv6('::ffff:10.7.1.1')
  FROM numbers(6);
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - toIntervalDay(1 + number), 51, 51, 2002, 1,
       92002 * 10 + number, toIPv6('::ffff:10.7.1.2')
  FROM numbers(6);


-- ============================================================
-- F3 VARIAS CUENTAS COMPRANDO DESDE LA MISMA IP
-- ============================================================
-- 10.9.9.9: cinco cuentas. 10.9.9.8 (control): tres. 127.0.0.1 (control):
-- siete, pero es la IP del equipo y esta en ips_de_confianza.
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 4 DAY, 52, 52, 5001 + number, 1, 95000 + number, toIPv6('::ffff:10.9.9.9')
  FROM numbers(5);
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 4 DAY, 52, 52, 5101 + number, 1, 95100 + number, toIPv6('::ffff:10.9.9.8')
  FROM numbers(3);
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 4 DAY, 52, 52, 5201 + number, 1, 95200 + number, toIPv6('::ffff:127.0.0.1')
  FROM numbers(7);
-- Y '::' (control): seis cuentas con la IP vacia, como las compras que el ETL
-- copia de PostgreSQL sin IP. Es el falso positivo que dio la base real.
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 4 DAY, 52, 52, 5301 + number, 1, 95300 + number, toIPv6('::')
  FROM numbers(6);


-- ============================================================
-- F4 CARRITO ACAPARADOR
-- ============================================================
-- 3001: 40 unidades del 28, de a 4, y no compra ninguna. 3002 (control): las
-- mismas 40 y las compra. 3003 (control): 5 unidades sin comprar, muy pocas.
INSERT INTO carrito_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, ip)
SELECT now64(3) - INTERVAL 1 DAY + toIntervalMinute(number), 28, 28, u, 4, toIPv6('::ffff:10.8.0.1')
  FROM numbers(10) ARRAY JOIN [3001, 3002] AS u;
INSERT INTO carrito_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, ip)
VALUES (now64(3) - INTERVAL 1 DAY, 28, 28, 3003, 5, toIPv6('::ffff:10.8.0.3'));
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
VALUES (now64(3) - INTERVAL 20 HOUR, 28, 28, 3002, 40, 93002, toIPv6('::ffff:10.8.0.2'));


-- ============================================================
-- F5 DEVOLUCIONES SERIALES
-- ============================================================
-- 4001: compra 5 y devuelve 4. 4002 (control): devuelve 1 de 5. 4003
-- (control): devuelve 2 de 2, el 100 %, pero por debajo del minimo de 3.
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 9 DAY + toIntervalHour(number), 29, 29, u, 1, u * 10 + number,
       toIPv6('::ffff:10.10.0.1')
  FROM numbers(5) ARRAY JOIN [4001, 4002] AS u;
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 9 DAY + toIntervalHour(number), 29, 29, 4003, 1, 40030 + number,
       toIPv6('::ffff:10.10.0.2')
  FROM numbers(2);
INSERT INTO devolucion_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 5 DAY + toIntervalHour(number), 29, 29, 4001, 1, 40010 + number,
       toIPv6('::ffff:10.10.0.1')
  FROM numbers(4);
INSERT INTO devolucion_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
VALUES (now64(3) - INTERVAL 5 DAY, 29, 29, 4002, 1, 40020, toIPv6('::ffff:10.10.0.1'));
INSERT INTO devolucion_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip)
SELECT now64(3) - INTERVAL 5 DAY + toIntervalHour(number), 29, 29, 4003, 1, 40030 + number,
       toIPv6('::ffff:10.10.0.2')
  FROM numbers(2);


-- ============================================================
-- F6 GRANJA DE REGISTROS
-- ============================================================
-- 10.7.7.7: seis cuentas en 30 minutos. 10.8.8.8 (control): seis, una por
-- dia. 127.0.0.1 (control): diez en diez minutos, pero es la IP del equipo.
INSERT INTO evento_registro (fecha, id_usuario, ip, id_log_registro)
SELECT now64(3) - INTERVAL 3 DAY + toIntervalMinute(5 * number), 6001 + number,
       toIPv6('::ffff:10.7.7.7'), 96000 + number
  FROM numbers(6);
INSERT INTO evento_registro (fecha, id_usuario, ip, id_log_registro)
SELECT now64(3) - toIntervalDay(1 + number), 6101 + number,
       toIPv6('::ffff:10.8.8.8'), 96100 + number
  FROM numbers(6);
INSERT INTO evento_registro (fecha, id_usuario, ip, id_log_registro)
SELECT now64(3) - INTERVAL 3 DAY + toIntervalMinute(number), 6201 + number,
       toIPv6('::ffff:127.0.0.1'), 96200 + number
  FROM numbers(10);
