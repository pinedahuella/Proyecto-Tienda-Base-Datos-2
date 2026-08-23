-- datos/005_pedidos.sql
-- Siete pedidos con sus pagos, el inventario de las 92 variantes del catalogo
-- y el libro de movimientos que lo sustenta.
--
-- Los id empiezan en 1 en pedido, su detalle, el pago, el inventario y los
-- movimientos: esas tablas son nuevas y no las escribe nadie mas.
--
-- En usuarios, direcciones y direccion_historial NO se escribe ningun id a
-- mano. Esas tres las escribe la aplicacion cuando alguien se registra o
-- guarda una direccion, asi que sus numeros caen distintos en cada maquina.
-- Se insertan comprobando que no existan y se referencian por correo y por
-- fecha, nunca por numero.
--
-- Los pedidos van fechados a lo largo de 2026 a proposito, y ninguno vende un
-- producto antes de que existiera. Dos de ellos compran la misma camisa en
-- momentos distintos: el de enero se lleva la variante a 149 con 10 % de
-- comision, y el de marzo la otra variante ya con 12 %, porque esa categoria
-- subio la comision el 1 de marzo. Eso es lo que hace visible que la venta
-- guarda lo que regia ese dia y no lo de hoy.
--
-- El precio, el nombre y la comision NO se escriben a mano: se buscan en los
-- tres historiales con la fecha del pedido. Asi el conjunto de datos no puede
-- contradecir al catalogo, y de paso deja escrito como se congela una venta.
--
-- El stock inicial de cada variante sale de una formula, 10 + (id % 15), para
-- que sea el mismo en cualquier maquina y no haga falta escribir 92 numeros.
--
-- Todo inserta con ON CONFLICT DO NOTHING y con id escrito a mano: la segunda
-- corrida choca contra la llave primaria y no duplica.


-- ------------------------------------------------------------
-- Los dos compradores
-- ------------------------------------------------------------
-- Hacen falta porque un pedido es de alguien. Se insertan como el vendedor de
-- datos/001: comprobando las DOS restricciones unicas de usuarios, el correo y
-- el nombre, porque un ON CONFLICT solo vigila una.
--
-- La contrasena de los dos es Comprador123. Va hasheada con scrypt en el
-- formato salt:hash, que es el que compara el backend; un hash de bcrypt aqui
-- no sirve y deja la cuenta inservible sin dar ningun error.

INSERT INTO usuarios (
    correo_electronico, usuario, nombre, apellido, contrasena_hash,
    fecha_nacimiento, fecha_creacion, id_rol_usuario, id_estado_usuario
)
SELECT v.correo, v.usuario, v.nombre, v.apellido, v.hash, v.nacimiento, v.creacion,
       (SELECT id_rol_usuario    FROM rol_usuario    WHERE rol_usuario_nombre    = 'comprador'),
       (SELECT id_estado_usuario FROM estado_usuario WHERE estado_usuario_nombre = 'activo')
FROM (VALUES
    ('compradora.norte@mesh.com', 'compradora_norte', 'Lucia', 'Marroquin',
     '11a44efcfc4c03401306beb80a7c93b8:785c672b5beeaf6bf0c6c655b23762e78eaff15739847464159696ba9e02a45d52e73e41c90b868ba9500652a20ea71e7fde4ff4bc1d72ae7f7f5a2ec601e5db',
     '1995-03-22'::date, '2026-01-02 09:00:00-06'::timestamptz),
    ('comprador.sur@mesh.com', 'comprador_sur', 'Diego', 'Alvarado',
     '54df38449a0169a7a0b8d5f2cd55d586:c8dc6282e13d0f8820f0822f3c1a2e6700020cefb828b0d7c2bc2b0abc0ef12272eb500cd3b473f5f1c140710b22d8b47a87a6d9f6dd51e29de667515f9e1757',
     '1992-11-08', '2026-01-03 09:00:00-06')
) AS v (correo, usuario, nombre, apellido, hash, nacimiento, creacion)
WHERE NOT EXISTS (
    SELECT 1 FROM usuarios u
    WHERE u.correo_electronico = v.correo OR u.usuario = v.usuario
);


-- ------------------------------------------------------------
-- Sus direcciones
-- ------------------------------------------------------------
-- Con fecha ANTERIOR a los pedidos: un pedido apunta a la version de la
-- direccion que regia al comprar, y una version no puede ser posterior al
-- pedido que la usa.
--
-- Sin id a mano, y sin ON CONFLICT: se comprueba que esa persona no tenga ya
-- una direccion con esa misma fecha, que es lo que identifica a esta.

INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, codigo_postal, fecha_creacion, id_estado_direccion)
SELECT u.id_usuario, v.pais, v.departamento, v.ciudad, v.codigo, v.fecha,
       (SELECT id_estado_direccion FROM estado_direccion WHERE estado_direccion_nombre = 'activa')
FROM (VALUES
    ('compradora.norte@mesh.com', 'Guatemala', 'Guatemala',      'Ciudad de Guatemala', '01010', '2026-01-05 09:00:00-06'::timestamptz),
    ('comprador.sur@mesh.com',    'Guatemala', 'Quetzaltenango', 'Quetzaltenango',      '09001', '2026-01-08 10:00:00-06')
) AS v (correo, pais, departamento, ciudad, codigo, fecha)
JOIN usuarios u ON u.correo_electronico = v.correo
WHERE NOT EXISTS (
    SELECT 1 FROM direcciones d
    WHERE d.id_usuario = u.id_usuario AND d.fecha_creacion = v.fecha
);

INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, codigo_postal, fecha_creacion)
SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.codigo_postal, d.fecha_creacion
FROM direcciones d
JOIN usuarios u ON u.id_usuario = d.id_usuario
WHERE u.correo_electronico IN ('compradora.norte@mesh.com', 'comprador.sur@mesh.com')
  AND NOT EXISTS (
      SELECT 1 FROM direccion_historial dh
      WHERE dh.id_direccion = d.id_direccion AND dh.fecha_creacion = d.fecha_creacion
  );


-- ------------------------------------------------------------
-- Los pedidos
-- ------------------------------------------------------------

-- El comprador y su direccion se buscan por correo, nunca por numero: los id
-- de usuario los reparte la aplicacion y caen distintos en cada maquina.

INSERT INTO pedido (id_pedido, fecha_creacion, id_usuario, id_direccion_historial, id_estado_pedido)
SELECT v.id_pedido, v.fecha, u.id_usuario, dh.id_direccion_historial,
       (SELECT id_estado_pedido FROM estado_pedido WHERE estado_pedido_nombre = v.estado)
FROM (VALUES
    (1, '2026-01-20 11:00:00-06'::timestamptz, 'compradora.norte@mesh.com', 'entregado'),
    (2, '2026-02-10 16:30:00-06',              'comprador.sur@mesh.com',    'entregado'),
    (3, '2026-03-15 09:45:00-06',              'compradora.norte@mesh.com', 'entregado'),
    (4, '2026-05-10 14:00:00-06',              'comprador.sur@mesh.com',    'cancelado'),
    (5, '2026-06-02 10:15:00-06',              'compradora.norte@mesh.com', 'enviado'),
    (6, '2026-07-14 18:20:00-06',              'comprador.sur@mesh.com',    'comprado'),
    (7, '2026-08-20 08:05:00-06',              'compradora.norte@mesh.com', 'pendiente')
) AS v (id_pedido, fecha, correo, estado)
JOIN usuarios u ON u.correo_electronico = v.correo
JOIN direcciones d ON d.id_usuario = u.id_usuario
JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
                          AND dh.fecha_creacion = d.fecha_creacion
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Las lineas
-- ------------------------------------------------------------
-- Aqui esta el congelado. Cada valor copiado sale del historial que regia en
-- la fecha del pedido: la ultima version con fecha menor o igual.
--
-- Notese que la comision no se busca por producto sino por su CATEGORIA, que
-- es de donde sale, y el nombre de la variante por su propio historial: los
-- tres corren por separado y pueden haber cambiado en dias distintos.

INSERT INTO pedido_producto (
    id_pedido_producto, id_pedido, id_producto_mongo, id_producto_variante_mongo,
    nombre_producto, nombre_variante, precio_unitario, porcentaje_comision, cantidad)
SELECT
    v.id_linea,
    v.id_pedido,
    pr.id_producto,
    v.id_variante,
    (SELECT ph.nombre FROM productos_historial ph
      WHERE ph.id_producto = pr.id_producto AND ph.fecha_creacion <= p.fecha_creacion
      ORDER BY ph.fecha_creacion DESC LIMIT 1),
    (SELECT vh.nombre_variante FROM productos_variantes_historial vh
      WHERE vh.id_producto_variante = v.id_variante AND vh.fecha_creacion <= p.fecha_creacion
      ORDER BY vh.fecha_creacion DESC LIMIT 1),
    (SELECT vh.precio FROM productos_variantes_historial vh
      WHERE vh.id_producto_variante = v.id_variante AND vh.fecha_creacion <= p.fecha_creacion
      ORDER BY vh.fecha_creacion DESC LIMIT 1),
    (SELECT ch.porcentaje_comision FROM categorias_historial ch
      WHERE ch.id_categoria = pr.id_categoria AND ch.fecha_creacion <= p.fecha_creacion
      ORDER BY ch.fecha_creacion DESC LIMIT 1),
    v.cantidad
FROM (VALUES
    (1, 1,  1::bigint, 2),
    (2, 1,  4,         1),
    (3, 2,  3,         1),
    (4, 3,  2,         1),
    (5, 4, 60,         1),
    (6, 5, 12,         1),
    (7, 5, 20,         2),
    (8, 6, 35,         1),
    (9, 7, 50,         3)
) AS v (id_linea, id_pedido, id_variante, cantidad)
JOIN pedido p              ON p.id_pedido = v.id_pedido
JOIN productos_variantes pv ON pv.id_producto_variante = v.id_variante
JOIN productos pr           ON pr.id_producto = pv.id_producto
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Los pagos
-- ------------------------------------------------------------
-- El monto se calcula sumando las lineas del pedido: escribirlo a mano seria
-- pedir que no cuadre. El cancelado tiene un pago rechazado y el pendiente uno
-- sin fecha, que es lo que significa estar pendiente.

INSERT INTO pago (id_pago, id_pedido, id_metodo_pago, monto, fecha_cancelacion, id_estado_pago)
SELECT v.id_pago, v.id_pedido,
       (SELECT id_metodo_pago FROM metodo_pago WHERE metodo_nombre = v.metodo),
       (SELECT sum(pp.precio_unitario * pp.cantidad) FROM pedido_producto pp WHERE pp.id_pedido = v.id_pedido),
       v.fecha,
       (SELECT id_estado_pago FROM estado_pago WHERE estado_pago_nombre = v.estado)
FROM (VALUES
    (1, 1, 'tarjeta',                 '2026-01-20 11:02:00-06'::timestamptz, 'aprobado'),
    (2, 2, 'transferencia',           '2026-02-10 17:10:00-06',              'aprobado'),
    (3, 3, 'tarjeta',                 '2026-03-15 09:47:00-06',              'aprobado'),
    (4, 4, 'tarjeta',                 NULL,                                  'rechazado'),
    (5, 5, 'efectivo contra entrega', '2026-06-04 12:00:00-06',              'aprobado'),
    (6, 6, 'tarjeta',                 '2026-07-14 18:22:00-06',              'aprobado'),
    (7, 7, 'tarjeta',                 NULL,                                  'pendiente')
) AS v (id_pago, id_pedido, metodo, fecha, estado)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- El inventario
-- ------------------------------------------------------------
-- Una fila por variante del catalogo. El stock se deja en el inicial y al
-- final del archivo se recalcula desde los movimientos: asi queda demostrado
-- que el saldo se deriva del libro y no al reves.
--
-- Solo las 92 variantes que vienen del catalogo relacional. Las de un producto
-- que publique un vendedor no estan aqui: esas las crea la aplicacion al
-- publicar, porque solo existen en Mongo.

INSERT INTO inventario (id_inventario, id_producto_mongo, id_producto_variante_mongo, stock, fecha_actualizacion)
SELECT pv.id_producto_variante,
       pv.id_producto,
       pv.id_producto_variante,
       10 + (pv.id_producto_variante % 15),
       p.fecha_creacion
FROM productos_variantes pv
JOIN productos p ON p.id_producto = pv.id_producto
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Los movimientos: la mercaderia que entro
-- ------------------------------------------------------------
-- Una reposicion por variante, con la fecha en que se publico el producto: el
-- stock aparece cuando el vendedor lo trae, no antes. La hace el vendedor
-- dueno del producto.

INSERT INTO stock_movimiento (
    id_stock_movimiento, fecha_movimiento, id_inventario, id_motivo_movimiento,
    id_usuario, id_pedido, cantidad, stock_resultante)
SELECT i.id_inventario,
       p.fecha_creacion,
       i.id_inventario,
       (SELECT id_motivo_movimiento FROM motivo_movimiento WHERE motivo_nombre = 'reposicion'),
       p.id_usuario,
       NULL,
       10 + (i.id_producto_variante_mongo % 15),
       10 + (i.id_producto_variante_mongo % 15)
FROM inventario i
JOIN productos p ON p.id_producto = i.id_producto_mongo
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Los movimientos: lo que salio vendido
-- ------------------------------------------------------------
-- Uno por linea de pedido, con la fecha del pedido y apuntando a el. El
-- id arranca en 1000 para no chocar con las reposiciones, que ocupan del 1 al
-- 92 (una por variante).

INSERT INTO stock_movimiento (
    id_stock_movimiento, fecha_movimiento, id_inventario, id_motivo_movimiento,
    id_usuario, id_pedido, cantidad, stock_resultante)
SELECT 1000 + pp.id_pedido_producto,
       p.fecha_creacion,
       i.id_inventario,
       (SELECT id_motivo_movimiento FROM motivo_movimiento WHERE motivo_nombre = 'venta'),
       p.id_usuario,
       p.id_pedido,
       pp.cantidad,
       (10 + (i.id_producto_variante_mongo % 15)) - pp.cantidad
FROM pedido_producto pp
JOIN pedido p     ON p.id_pedido = pp.id_pedido
JOIN inventario i ON i.id_producto_mongo          = pp.id_producto_mongo
                 AND i.id_producto_variante_mongo = pp.id_producto_variante_mongo
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- El movimiento que devuelve lo del pedido cancelado
-- ------------------------------------------------------------
-- El pedido 4 se cancelo al dia siguiente. La salida no se borra: se compensa
-- con una entrada. Un libro mayor no se corrige borrando renglones.

INSERT INTO stock_movimiento (
    id_stock_movimiento, fecha_movimiento, id_inventario, id_motivo_movimiento,
    id_usuario, id_pedido, cantidad, stock_resultante)
SELECT 2000 + pp.id_pedido_producto,
       p.fecha_creacion + interval '1 day',
       i.id_inventario,
       (SELECT id_motivo_movimiento FROM motivo_movimiento WHERE motivo_nombre = 'devolucion'),
       p.id_usuario,
       p.id_pedido,
       pp.cantidad,
       10 + (i.id_producto_variante_mongo % 15)
FROM pedido_producto pp
JOIN pedido p     ON p.id_pedido = pp.id_pedido
JOIN inventario i ON i.id_producto_mongo          = pp.id_producto_mongo
                 AND i.id_producto_variante_mongo = pp.id_producto_variante_mongo
WHERE p.id_pedido = 4
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- El saldo se recalcula desde el libro
-- ------------------------------------------------------------
-- Esto no es un parche: es la regla. inventario.stock es la lectura rapida y
-- los movimientos son la verdad, asi que el saldo se deriva sumando cada
-- cantidad por el signo de su motivo. Correr esto dos veces da lo mismo.

UPDATE inventario i
SET stock = COALESCE((
        SELECT sum(sm.cantidad * mm.valor)
        FROM stock_movimiento sm
        JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
        WHERE sm.id_inventario = i.id_inventario
    ), 0),
    fecha_actualizacion = COALESCE((
        SELECT max(sm.fecha_movimiento) FROM stock_movimiento sm WHERE sm.id_inventario = i.id_inventario
    ), i.fecha_actualizacion);


-- ------------------------------------------------------------
-- Secuencias
-- ------------------------------------------------------------

SELECT setval(pg_get_serial_sequence('pedido',              'id_pedido'),              max(id_pedido))              FROM pedido;
SELECT setval(pg_get_serial_sequence('pedido_producto',     'id_pedido_producto'),     max(id_pedido_producto))     FROM pedido_producto;
SELECT setval(pg_get_serial_sequence('pago',                'id_pago'),                max(id_pago))                FROM pago;
SELECT setval(pg_get_serial_sequence('inventario',          'id_inventario'),          max(id_inventario))          FROM inventario;
SELECT setval(pg_get_serial_sequence('stock_movimiento',    'id_stock_movimiento'),    max(id_stock_movimiento))    FROM stock_movimiento;
