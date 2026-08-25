-- 006_pedidos.sql
-- El pedido, el pago y el kardex del stock.
--
-- Solo esquema. Los valores de los cuatro catalogos (estado de pedido, estado
-- de pago, metodo de pago y motivo de movimiento) se quedan aqui, como los
-- estados del 003, porque sin ellos no se puede insertar ni un pedido ni un
-- movimiento. Los pedidos de prueba viven en migrations/datos/.
--
-- El orden importa: primero los cuatro catalogos, que no dependen de nada;
-- luego pedido (que referencia usuarios y direccion_historial, del 001 y el
-- 002); luego su detalle y el pago; y al final el kardex, que cuelga de
-- oferta (005).


-- ============================================================
-- Como llega la linea del pedido al precio y al vendedor
-- ============================================================
-- La linea NO copia el precio ni el id del vendedor. Guarda un solo puntero:
--
--   pedido_producto.id_precio_historial
--     -> precio_historial.precio      cuanto se cobro
--     -> precio_historial.id_oferta
--          -> oferta.id_usuario       quien vendio
--
-- Funciona porque cada eslabon es INMUTABLE: una fila de precio_historial no
-- se actualiza nunca, y una oferta no cambia de dueno. Copiar el precio seria
-- guardar un dato deducible, el mismo motivo por el que pedido no lleva total.
--
-- Y de ahi sale una regla que hay que respetar en todo el sistema: NADA de esa
-- cadena se puede borrar jamas. Por eso van tres RESTRICT seguidos, y por eso
-- retirar una oferta es cambiarle el estado y nunca un DELETE.
--
-- Lo que SI se copia son los nombres, porque esos si cambian y no se pueden
-- deducir: si manana el vendedor se cambia el usuario, la factura vieja tiene
-- que seguir diciendo a quien se le compro ese dia.
--
-- Los dos id_*_mongo no son llaves foraneas y no pueden serlo: el catalogo se
-- lee desde MongoDB y PostgreSQL no puede garantizar integridad referencial
-- contra otra base. El sufijo esta para que quien lea la tabla lo sepa de un
-- vistazo y no busque una FK que no existe.


-- ============================================================
-- estado_pedido
-- ============================================================
-- Se llama comprado y no pagado: un pedido contra entrega esta comprado y
-- todavia no pagado. El estado del dinero vive en pago, que tiene el suyo.
CREATE TABLE estado_pedido (
    id_estado_pedido      smallserial PRIMARY KEY,
    estado_pedido_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_pedido IS 'Catalogo de estados de un pedido';


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

COMMENT ON TABLE metodo_pago IS 'Catalogo de formas de pago';


-- ============================================================
-- motivo_movimiento
-- ============================================================
-- Por que se movio el stock. El signo vive AQUI y no en cada movimiento: una
-- venta siempre resta y una reposicion siempre suma, asi que un movimiento no
-- puede contradecir a su motivo. Es lo que dice el ER con "valor (+, -)".
--
-- Se guarda como 1 y -1 en vez de los caracteres para que el saldo se pueda
-- calcular sumando: cantidad * valor.
CREATE TABLE motivo_movimiento (
    id_motivo_movimiento  smallserial PRIMARY KEY,
    motivo_nombre         varchar(40) NOT NULL UNIQUE,
    descripcion           text,
    valor                 smallint NOT NULL CHECK (valor IN (1, -1))
);

COMMENT ON TABLE motivo_movimiento IS 'Por que se movio el stock, y si suma o resta';
COMMENT ON COLUMN motivo_movimiento.valor IS '1 suma, -1 resta. El signo es del motivo, no del movimiento';


-- ============================================================
-- pedido
-- ============================================================
-- Apunta a direccion_historial y no a direcciones: guarda la VERSION de la
-- direccion que regia al comprar. Si la persona edita su direccion medio ano
-- despues, el pedido tiene que seguir diciendo a donde se mando de verdad.
--
-- No lleva total. El total es la suma de sus lineas y cambiaria solo si
-- alguien lo escribiera mal; se calcula cuando se necesita.
--
-- Un pedido puede mezclar vendedores: tres lineas de tres personas distintas
-- caben en el mismo pedido y en el mismo pago. Es como funciona el modelo
-- multi-vendedor.
CREATE TABLE pedido (
    id_pedido       bigserial   PRIMARY KEY,
    fecha_creacion  timestamptz NOT NULL DEFAULT now(),

    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    id_direccion_historial  bigint NOT NULL REFERENCES direccion_historial(id_direccion_historial)
                            ON DELETE RESTRICT,

    id_estado_pedido  smallint NOT NULL REFERENCES estado_pedido(id_estado_pedido)
                      ON DELETE RESTRICT
);

COMMENT ON TABLE pedido IS 'La cabecera de la compra. Sin total: se suma de sus lineas';

-- "los pedidos de este cliente, del mas nuevo al mas viejo"
CREATE INDEX idx_pedido_usuario ON pedido(id_usuario, fecha_creacion DESC);
CREATE INDEX idx_pedido_estado  ON pedido(id_estado_pedido);


-- ============================================================
-- pedido_producto
-- ============================================================
-- El detalle: que se llevo, cuanto, y de quien.
CREATE TABLE pedido_producto (
    id_pedido_producto  bigserial PRIMARY KEY,

    id_pedido  bigint NOT NULL REFERENCES pedido(id_pedido)
               ON DELETE RESTRICT,

    -- El unico puntero que hace falta: de aqui salen el precio, la oferta y
    -- el vendedor. RESTRICT porque es el hilo entero de la factura.
    id_precio_historial  bigint NOT NULL REFERENCES precio_historial(id_precio_historial)
                         ON DELETE RESTRICT,

    -- Para volver al documento del catalogo. No son FK.
    id_producto_mongo           bigint NOT NULL,
    id_producto_variante_mongo  bigint NOT NULL,

    cantidad  integer NOT NULL CHECK (cantidad > 0),

    -- Lo que si se copia: los nombres cambian y no se deducen
    nombre_producto  varchar(200) NOT NULL,
    nombre_variante  varchar(100) NOT NULL,
    nombre_vendedor  varchar(200) NOT NULL
);

COMMENT ON TABLE pedido_producto IS 'Las lineas del pedido. El precio y el vendedor salen de id_precio_historial';
COMMENT ON COLUMN pedido_producto.id_precio_historial IS 'De aqui salen el precio cobrado, la oferta y el vendedor. Nunca se borra';
COMMENT ON COLUMN pedido_producto.nombre_vendedor IS 'Como se llamaba el vendedor ese dia. Se copia porque el nombre cambia';

CREATE INDEX idx_pedido_producto_pedido ON pedido_producto(id_pedido);
CREATE INDEX idx_pedido_producto_precio ON pedido_producto(id_precio_historial);

-- "que se ha vendido de este producto": para el catalogo y para los reportes
CREATE INDEX idx_pedido_producto_mongo
    ON pedido_producto(id_producto_mongo, id_producto_variante_mongo);


-- ============================================================
-- Por que no hay UNIQUE sobre la linea
-- ============================================================
-- La regla es "una linea por oferta en cada pedido": llevarse dos veces lo
-- mismo del mismo vendedor es una linea con mas cantidad, no dos lineas.
--
-- Pero esa regla no se puede escribir como UNIQUE, porque la oferta no esta
-- en esta tabla: se llega a ella cruzando precio_historial, y una restriccion
-- de unicidad no puede atravesar una llave foranea.
--
-- Un UNIQUE sobre los dos id_*_mongo tampoco sirve: prohibiria comprar la
-- misma variante a DOS vendedores distintos en el mismo pedido, que es
-- legitimo y es justo lo que este modelo permite.
--
-- La aplica agregar_linea (007), que busca por oferta antes de insertar. Es
-- una de las razones por las que el pedido se arma con funciones y no con
-- INSERT sueltos desde el backend.


-- ============================================================
-- pago
-- ============================================================
-- Uno por pedido, aunque el pedido mezcle vendedores: quien compra paga una
-- vez. Sin comision no hay nada que repartir.
--
-- monto es lo que efectivamente se cobro, y por eso no es lo mismo que la
-- suma de las lineas: un reembolso parcial las deja iguales y el monto no.
CREATE TABLE pago (
    id_pago  bigserial PRIMARY KEY,

    id_pedido  bigint NOT NULL REFERENCES pedido(id_pedido)
               ON DELETE RESTRICT,

    id_metodo_pago  smallint NOT NULL REFERENCES metodo_pago(id_metodo_pago)
                    ON DELETE RESTRICT,

    monto  numeric(12,2) NOT NULL CHECK (monto >= 0),

    -- Cuando se cancelo la deuda, no cuando se anulo el pedido. Es el termino
    -- contable: NULL mientras no se ha cobrado.
    fecha_cancelacion  timestamptz,

    id_estado_pago  smallint NOT NULL REFERENCES estado_pago(id_estado_pago)
                    ON DELETE RESTRICT
);

COMMENT ON TABLE pago IS 'El cobro de un pedido';
COMMENT ON COLUMN pago.fecha_cancelacion IS 'Cuando se cancelo la deuda (se pago), no cuando se anulo el pedido';

CREATE INDEX idx_pago_pedido ON pago(id_pedido);


-- ============================================================
-- stock_movimiento
-- ============================================================
-- El kardex. Cada entrada y salida de una oferta, con el saldo que dejo.
--
-- Cuelga de oferta y no de una tabla de inventario aparte, porque el stock ya
-- vive en la oferta: son la misma cosa.
--
-- Con stock_resultante se reconstruye el stock a cualquier fecha leyendo una
-- fila, sin sumar el libro entero. Es lo que contesta la "disponibilidad" que
-- pide el enunciado.
CREATE TABLE stock_movimiento (
    id_stock_movimiento  bigserial   PRIMARY KEY,
    fecha_movimiento     timestamptz NOT NULL DEFAULT now(),

    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta)
               ON DELETE RESTRICT,

    id_motivo_movimiento  smallint NOT NULL REFERENCES motivo_movimiento(id_motivo_movimiento)
                          ON DELETE RESTRICT,

    -- Quien lo provoco: el vendedor que repone, o el cliente cuya compra
    -- descuenta. El DUENO del stock no es este: sale de oferta.id_usuario.
    -- Se llama distinto para que nadie confunda los dos.
    id_usuario_modifico  bigint NOT NULL REFERENCES usuarios(id_usuario)
                         ON DELETE RESTRICT,

    -- Solo cuando el movimiento nace de una venta o de su devolucion. Una
    -- reposicion o un ajuste no tienen pedido.
    id_pedido  bigint REFERENCES pedido(id_pedido)
               ON DELETE RESTRICT,

    cantidad          integer NOT NULL CHECK (cantidad > 0),
    stock_resultante  integer NOT NULL CHECK (stock_resultante >= 0)
);

COMMENT ON TABLE stock_movimiento IS 'Kardex: cada entrada y salida de una oferta, con el saldo que dejo';
COMMENT ON COLUMN stock_movimiento.cantidad IS 'Siempre positiva. El signo lo pone el motivo';
COMMENT ON COLUMN stock_movimiento.stock_resultante IS 'El saldo despues del movimiento. Reconstruye el stock a cualquier fecha';
COMMENT ON COLUMN stock_movimiento.id_usuario_modifico IS 'Quien lo provoco. El dueno del stock sale de oferta.id_usuario';

-- "el libro de esta oferta, del mas nuevo al mas viejo": es como se
-- reconstruye el stock a una fecha
CREATE INDEX idx_stock_movimiento_oferta
    ON stock_movimiento(id_oferta, fecha_movimiento DESC);

CREATE INDEX idx_stock_movimiento_pedido ON stock_movimiento(id_pedido);


-- ============================================================
-- Valores de los catalogos
-- ============================================================
-- No son datos de prueba: sin ellos no se puede insertar un pedido.

INSERT INTO estado_pedido (estado_pedido_nombre) VALUES
    ('pendiente'),
    ('comprado'),
    ('enviado'),
    ('entregado'),
    ('cancelado');

INSERT INTO estado_pago (estado_pago_nombre) VALUES
    ('pendiente'),
    ('pagado'),
    ('reembolsado'),
    ('fallido');

INSERT INTO metodo_pago (metodo_nombre) VALUES
    ('tarjeta'),
    ('transferencia'),
    ('efectivo contra entrega');

INSERT INTO motivo_movimiento (motivo_nombre, descripcion, valor) VALUES
    ('reposicion', 'El vendedor agrega unidades a su oferta',              1),
    ('venta',      'Se descuenta lo que se llevo un pedido comprado',     -1),
    ('devolucion', 'Vuelven las unidades de un pedido cancelado',          1),
    ('ajuste',     'Correccion manual: merma, inventario fisico, error',  -1);
