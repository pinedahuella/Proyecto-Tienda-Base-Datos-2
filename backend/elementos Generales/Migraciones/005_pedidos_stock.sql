-- 005_pedidos_stock.sql
-- El pedido, el pago y el inventario: las nueve tablas del ER que faltaban del
-- alcance de la venta.
--
-- Solo esquema. Los valores de los cuatro catalogos (estado de pedido, estado
-- de pago, metodo de pago y motivo de movimiento) se quedan aqui, como los
-- estados del 003, porque sin ellos no se puede insertar ni un pedido ni un
-- movimiento. Los pedidos de prueba viven en migrations/datos/.
--
-- El orden importa: primero los cuatro catalogos, que no dependen de nada;
-- luego pedido (que referencia usuarios y direccion_historial, del 001 y el
-- 002); luego su detalle y el pago; y al final inventario y sus movimientos.


-- ============================================================
-- Lo que cambia respecto al catalogo: el producto ya no vive aqui
-- ============================================================
-- En el ER, la linea del pedido apunta a productos_historial, a
-- productos_variantes_historial y a categorias_historial. Eso congelaba el
-- nombre, el precio y la comision del dia de la venta, que es lo correcto: una
-- venta no puede cambiar porque manana suban el precio.
--
-- Pero el catalogo se mudo a MongoDB. Un producto que publica un vendedor nace
-- SOLO alla y no tiene ninguna fila en esos historiales, asi que esas tres
-- llaves foraneas solo funcionarian para los productos del conjunto de prueba.
--
-- Se resuelve en dos partes:
--
--   1. Los id que viven en Mongo se guardan con el sufijo _mongo
--      (id_producto_mongo, id_producto_variante_mongo). NO son llaves
--      foraneas y no pueden serlo: PostgreSQL no puede garantizar integridad
--      referencial contra otra base. El sufijo esta para que quien lea la
--      tabla lo sepa de un vistazo y no busque una FK que no existe.
--
--   2. Lo que aquellas tres FK congelaban se COPIA dentro de la linea:
--      nombre, precio unitario y porcentaje de comision, tal como estaban al
--      vender. Asi la factura se imprime sin preguntarle nada a Mongo, y
--      renombrar un producto no reescribe las ventas viejas.
--
-- Para "como era el producto ese dia" (la ficha completa, no lo cobrado) se
-- usa la fecha del pedido contra productos_eventos en Mongo, que es donde vive
-- el historial del catalogo.


-- ============================================================
-- estado_pedido
-- ============================================================
CREATE TABLE estado_pedido (
    id_estado_pedido      smallserial PRIMARY KEY,
    estado_pedido_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_pedido IS 'Catalogo de estados por los que pasa un pedido';


-- ============================================================
-- estado_pago
-- ============================================================
-- El estado del pago corre por su cuenta y no es el del pedido: un pedido
-- puede estar enviado y su pago reembolsado.
CREATE TABLE estado_pago (
    id_estado_pago      smallserial PRIMARY KEY,
    estado_pago_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_pago IS 'Catalogo de estados de un pago';


-- ============================================================
-- metodo_pago
-- ============================================================
CREATE TABLE metodo_pago (
    id_metodo_pago  smallserial PRIMARY KEY,
    metodo_nombre   varchar(40) NOT NULL UNIQUE
);

COMMENT ON TABLE metodo_pago IS 'Con que se paga: tarjeta, transferencia, contra entrega';


-- ============================================================
-- motivo_movimiento
-- ============================================================
-- Por que se movio el stock. El signo vive AQUI y no en cada movimiento: una
-- venta siempre resta y una reposicion siempre suma, asi que un movimiento no
-- puede contradecir a su motivo. Es lo que dice el ER con "valor (+, -)".
--
-- Se guarda como 1 y -1 en vez de los caracteres '+' y '-' para que el saldo
-- se pueda calcular sumando: cantidad * valor.
CREATE TABLE motivo_movimiento (
    id_motivo_movimiento  smallserial PRIMARY KEY,
    motivo_nombre         varchar(40) NOT NULL UNIQUE,
    descripcion           varchar(200),

    valor  smallint NOT NULL CHECK (valor IN (1, -1))
);

COMMENT ON TABLE motivo_movimiento IS 'Catalogo de motivos de movimiento de stock';
COMMENT ON COLUMN motivo_movimiento.valor IS 'El signo del motivo: 1 suma al stock, -1 resta';


-- ============================================================
-- pedido
-- ============================================================
-- Apunta a direccion_historial y no a direcciones: guarda la VERSION de la
-- direccion que regia al comprar. Si la persona edita su direccion medio ano
-- despues, el pedido tiene que seguir diciendo a donde se mando de verdad.
--
-- No lleva total. El total es la suma de sus lineas y cambiaria solo si
-- alguien lo escribiera mal; se calcula cuando se necesita.
CREATE TABLE pedido (
    id_pedido       bigserial   PRIMARY KEY,
    fecha_creacion  timestamptz NOT NULL DEFAULT now(),

    -- RESTRICT: no se borra un usuario que tiene pedidos. Un pedido es un
    -- documento de la tienda, no una pertenencia del cliente.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    id_direccion_historial  bigint NOT NULL REFERENCES direccion_historial(id_direccion_historial)
                            ON DELETE RESTRICT,

    id_estado_pedido  smallint NOT NULL REFERENCES estado_pedido(id_estado_pedido)
                      ON DELETE RESTRICT
);

COMMENT ON TABLE pedido IS 'La compra: quien, cuando, a donde y en que estado';
COMMENT ON COLUMN pedido.id_direccion_historial IS 'La version de la direccion que regia al comprar, no la actual';
COMMENT ON COLUMN pedido.fecha_creacion IS 'Tambien es la fecha con la que se reconstruye el producto en Mongo';

-- "los pedidos de este cliente, del mas nuevo al mas viejo"
CREATE INDEX idx_pedido_usuario ON pedido(id_usuario, fecha_creacion DESC);
CREATE INDEX idx_pedido_estado  ON pedido(id_estado_pedido);


-- ============================================================
-- pedido_producto
-- ============================================================
-- El detalle: que se llevo, cuanto y a que precio.
--
-- Los dos id_*_mongo no son llaves foraneas. Estan para poder volver al
-- documento; lo que hace falta para cobrar y para imprimir ya esta copiado
-- aqui al lado.
--
-- Se guardan los DOS id, producto y variante, y no solo el de la variante:
-- en Mongo las variantes van embebidas dentro del producto y nada garantiza
-- que dos productos distintos no tengan una variante con el mismo numero. El
-- par si es inequivoco.
CREATE TABLE pedido_producto (
    id_pedido_producto  bigserial PRIMARY KEY,

    id_pedido  bigint NOT NULL REFERENCES pedido(id_pedido)
               ON DELETE RESTRICT,

    id_producto_mongo           bigint NOT NULL,
    id_producto_variante_mongo  bigint NOT NULL,

    -- La copia de lo acordado. No se actualiza nunca.
    nombre_producto      varchar(200)  NOT NULL,
    nombre_variante      varchar(100)  NOT NULL,
    precio_unitario      numeric(12,2) NOT NULL CHECK (precio_unitario >= 0),
    porcentaje_comision  numeric(5,2)  NOT NULL CHECK (porcentaje_comision >= 0),

    cantidad  integer NOT NULL CHECK (cantidad > 0),

    -- El mismo producto y la misma variante no pueden ir dos veces en un
    -- pedido: eso es una linea con mas cantidad, no dos lineas.
    UNIQUE (id_pedido, id_producto_mongo, id_producto_variante_mongo)
);

COMMENT ON TABLE pedido_producto IS 'Las lineas del pedido, con lo vendido copiado tal como estaba ese dia';
COMMENT ON COLUMN pedido_producto.id_producto_mongo IS 'El _id del documento en MongoDB. Sin FK: la sostiene la aplicacion';
COMMENT ON COLUMN pedido_producto.precio_unitario IS 'El precio de esa variante al vender, no el de hoy';
COMMENT ON COLUMN pedido_producto.porcentaje_comision IS 'La comision de su categoria al vender: es lo que gano la tienda';

CREATE INDEX idx_pedido_producto_pedido   ON pedido_producto(id_pedido);
-- "cuanto se ha vendido de este producto": el reporte mas comun
CREATE INDEX idx_pedido_producto_producto ON pedido_producto(id_producto_mongo, id_producto_variante_mongo);


-- ============================================================
-- pago
-- ============================================================
-- Un pedido puede tener mas de un pago: un intento rechazado y uno aprobado
-- despues, o un reembolso. Por eso el pago apunta al pedido y no al reves.
CREATE TABLE pago (
    id_pago  bigserial PRIMARY KEY,

    id_pedido  bigint NOT NULL REFERENCES pedido(id_pedido)
               ON DELETE RESTRICT,

    id_metodo_pago  smallint NOT NULL REFERENCES metodo_pago(id_metodo_pago)
                    ON DELETE RESTRICT,

    monto  numeric(12,2) NOT NULL CHECK (monto >= 0),

    -- "cancelar" en el sentido de saldar. Va nula mientras el pago no se haya
    -- hecho todavia: un pago pendiente existe y no tiene fecha.
    fecha_cancelacion  timestamptz,

    id_estado_pago  smallint NOT NULL REFERENCES estado_pago(id_estado_pago)
                    ON DELETE RESTRICT
);

COMMENT ON TABLE pago IS 'Los pagos de un pedido. Puede haber mas de uno';
COMMENT ON COLUMN pago.fecha_cancelacion IS 'Cuando se salda. NULL mientras esta pendiente';

CREATE INDEX idx_pago_pedido ON pago(id_pedido);
CREATE INDEX idx_pago_estado ON pago(id_estado_pago);


-- ============================================================
-- inventario
-- ============================================================
-- El saldo de stock, una fila por variante.
--
-- La llave natural es el PAR producto + variante, por lo mismo que en la linea
-- del pedido: el numero de variante solo es unico dentro de su documento. El
-- UNIQUE del par es lo que impide dos saldos para la misma variante, que es lo
-- que en el ER garantizaba la llave foranea.
CREATE TABLE inventario (
    id_inventario  bigserial PRIMARY KEY,

    id_producto_mongo           bigint NOT NULL,
    id_producto_variante_mongo  bigint NOT NULL,

    stock                integer     NOT NULL DEFAULT 0 CHECK (stock >= 0),
    fecha_actualizacion  timestamptz NOT NULL DEFAULT now(),

    UNIQUE (id_producto_mongo, id_producto_variante_mongo)
);

COMMENT ON TABLE inventario IS 'Cuantas unidades hay de cada variante. El saldo; el detalle esta en stock_movimiento';
COMMENT ON COLUMN inventario.stock IS 'Nunca negativo: no se puede deber mercaderia';


-- ============================================================
-- stock_movimiento
-- ============================================================
-- El libro mayor del inventario: cada entrada y cada salida, con el saldo que
-- quedo. Solo se inserta, nunca se actualiza ni se borra.
--
-- inventario.stock es la lectura rapida; la verdad son estas filas. Si los dos
-- no cuadran, manda la suma de los movimientos.
--
-- cantidad va siempre en positivo. Si suma o resta lo dice el motivo, y por
-- eso no puede haber un movimiento con signo contrario al suyo.
CREATE TABLE stock_movimiento (
    id_stock_movimiento  bigserial   PRIMARY KEY,
    fecha_movimiento     timestamptz NOT NULL DEFAULT now(),

    id_inventario  bigint NOT NULL REFERENCES inventario(id_inventario)
                   ON DELETE RESTRICT,

    id_motivo_movimiento  smallint NOT NULL REFERENCES motivo_movimiento(id_motivo_movimiento)
                          ON DELETE RESTRICT,

    -- Quien lo hizo. El vendedor que repone, o el cliente cuya compra
    -- descuenta. RESTRICT por lo mismo que en pedido.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    -- Solo cuando el movimiento nace de una venta o de su devolucion. Una
    -- reposicion o un ajuste no tienen pedido.
    id_pedido  bigint REFERENCES pedido(id_pedido)
               ON DELETE RESTRICT,

    cantidad          integer NOT NULL CHECK (cantidad > 0),
    stock_resultante  integer NOT NULL CHECK (stock_resultante >= 0)
);

COMMENT ON TABLE stock_movimiento IS 'Cada movimiento de stock, con el saldo que dejo';
COMMENT ON COLUMN stock_movimiento.cantidad IS 'Siempre positiva. El signo lo pone el motivo';
COMMENT ON COLUMN stock_movimiento.stock_resultante IS 'El saldo despues de este movimiento: deja auditar sin sumar todo de nuevo';
COMMENT ON COLUMN stock_movimiento.id_pedido IS 'NULL cuando el movimiento no viene de una venta';

-- "el historial de esta variante, del mas nuevo al mas viejo"
CREATE INDEX idx_stock_movimiento_inventario ON stock_movimiento(id_inventario, fecha_movimiento DESC);
CREATE INDEX idx_stock_movimiento_pedido     ON stock_movimiento(id_pedido);


-- ============================================================
-- Valores de los catalogos
-- ============================================================
-- No son datos de prueba: sin ellos no se puede insertar ni un pedido ni un
-- movimiento de stock.

INSERT INTO estado_pedido (estado_pedido_nombre) VALUES
    ('pendiente'),
    ('pagado'),
    ('enviado'),
    ('entregado'),
    ('cancelado');

INSERT INTO estado_pago (estado_pago_nombre) VALUES
    ('pendiente'),
    ('aprobado'),
    ('rechazado'),
    ('reembolsado');

INSERT INTO metodo_pago (metodo_nombre) VALUES
    ('tarjeta'),
    ('transferencia'),
    ('efectivo contra entrega');

INSERT INTO motivo_movimiento (motivo_nombre, descripcion, valor) VALUES
    ('venta',           'Salida por un pedido',                        -1),
    ('devolucion',      'Entrada por un pedido devuelto',               1),
    ('reposicion',      'Entrada de mercaderia que trae el vendedor',   1),
    ('ajuste positivo', 'Correccion de inventario hacia arriba',        1),
    ('ajuste negativo', 'Correccion de inventario hacia abajo',        -1),
    ('merma',           'Perdida, dano o vencimiento',                 -1);


-- ============================================================
-- Los pedidos de prueba
-- ============================================================
-- No estan en este archivo. Estan en migrations/datos/, un archivo por
-- conjunto, y se corren despues de todas las migraciones. Ver
-- migrations/README.md.
