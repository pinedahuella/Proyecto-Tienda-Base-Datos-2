-- 003_productos.sql
-- El catalogo: categorias, productos, variantes, imagenes y los tres
-- historiales del alcance de productos.
--
-- Solo esquema. Los datos de prueba viven en migrations/datos/, que corre
-- despues: asi se puede agregar otro conjunto de productos sin volver a tocar
-- las tablas. Los valores de estado_producto y estado_variantes si se quedan
-- aqui, porque sin ellos no se puede insertar un producto.
--
-- El orden importa: primero los catalogos y categorias, que no dependen de
-- nada; luego productos (que referencia usuarios, del 001), luego las
-- variantes, y al final los historiales, que referencian a la fila viva.


-- ============================================================
-- estado_producto
-- ============================================================
CREATE TABLE estado_producto (
    id_estado_producto      smallserial PRIMARY KEY,
    estado_producto_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_producto IS 'Catalogo de estados de un producto';


-- ============================================================
-- estado_variantes
-- ============================================================
-- La llave se llama id_estado_variante en singular y la FK que la apunta
-- desde productos_variantes se llama id_estado_variantes en plural. Asi
-- esta en el diagrama; se respeta para que el codigo y el diagrama digan lo
-- mismo.
CREATE TABLE estado_variantes (
    id_estado_variante      smallserial PRIMARY KEY,
    estado_variante_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_variantes IS 'Catalogo de estados de una variante';


-- ============================================================
-- categorias
-- ============================================================
-- La jerarquia se arma con id_categoria_padre apuntando a esta misma tabla:
-- ropa > ropa de hombre > camisas sin repetir la rama en cada producto. La
-- raiz es la que lo tiene en NULL.
--
-- Lleva bigserial y no smallserial porque no es un catalogo: tiene fecha,
-- comision y un historial propio. Los catalogos solo tienen nombre.
CREATE TABLE categorias (
    id_categoria         bigserial PRIMARY KEY,
    nombre               varchar(100) NOT NULL,
    porcentaje_comision  numeric(5,2) NOT NULL,
    fecha_creacion       timestamptz  NOT NULL DEFAULT now(),

    -- RESTRICT: no se borra una categoria que todavia tiene hijas colgando
    id_categoria_padre   bigint REFERENCES categorias(id_categoria)
                         ON DELETE RESTRICT
);

COMMENT ON TABLE categorias IS 'Arbol de categorias del catalogo. La version vigente';
COMMENT ON COLUMN categorias.porcentaje_comision IS 'Lo que cobra la tienda por vender en esta categoria';
COMMENT ON COLUMN categorias.id_categoria_padre IS 'NULL solo en las categorias raiz';

-- "las hijas de esta categoria" es como se recorre el arbol
CREATE INDEX idx_categorias_padre ON categorias(id_categoria_padre);


-- ============================================================
-- productos
-- ============================================================
-- Un producto tiene un solo vendedor y una sola categoria. Una segunda
-- categoria dejaria sin respuesta que comision cobrar, que es el motivo por
-- el que no es una relacion de muchos a muchos.
CREATE TABLE productos (
    id_producto     bigserial PRIMARY KEY,
    nombre          varchar(200) NOT NULL,
    descripcion     text,
    fecha_creacion  timestamptz  NOT NULL DEFAULT now(),

    -- jsonb y no una tabla de atributos: cada categoria trae su propio juego
    -- de campos y ninguno se repite entre categorias, asi que una tabla
    -- clave-valor solo agregaria un join para devolver lo mismo. Va nullable
    -- porque un producto puede no tener ninguna.
    --

    -- RESTRICT: no se puede borrar un usuario que todavia tiene productos
    id_usuario          bigint   NOT NULL REFERENCES usuarios(id_usuario)
                        ON DELETE RESTRICT,
    id_estado_producto  smallint NOT NULL REFERENCES estado_producto(id_estado_producto)
                        ON DELETE RESTRICT,
    id_categoria        bigint   NOT NULL REFERENCES categorias(id_categoria)
                        ON DELETE RESTRICT
);

COMMENT ON TABLE productos IS 'Productos publicados. La version vigente';
COMMENT ON COLUMN productos.id_usuario IS 'El vendedor. Uno solo por producto';
COMMENT ON COLUMN productos.descripcion IS 'Aqui cae toda caracteristica variable: no hay atributos comunes a todas las categorias';

CREATE INDEX idx_productos_usuario   ON productos(id_usuario);
CREATE INDEX idx_productos_categoria ON productos(id_categoria);
CREATE INDEX idx_productos_estado    ON productos(id_estado_producto);


-- ============================================================
-- productos_variantes
-- ============================================================
-- El precio vive aqui y no en productos porque lo que se compra es una
-- talla o una capacidad concreta, no el producto en abstracto.
CREATE TABLE productos_variantes (
    id_producto_variante  bigserial PRIMARY KEY,

    id_producto      bigint        NOT NULL REFERENCES productos(id_producto)
                     ON DELETE RESTRICT,
    nombre_variante  varchar(100)  NOT NULL,
    precio           numeric(12,2) NOT NULL,
    fecha_creacion   timestamptz   NOT NULL DEFAULT now(),

    -- El nombre en plural es el del diagrama; apunta a la llave singular
    id_estado_variantes  smallint NOT NULL REFERENCES estado_variantes(id_estado_variante)
                         ON DELETE RESTRICT,

    descripcion      text
);

COMMENT ON TABLE productos_variantes IS 'Lo que realmente se vende: talla, capacidad, color. La version vigente';
COMMENT ON COLUMN productos_variantes.precio IS 'numeric y no float: el dinero no admite el redondeo binario';

CREATE INDEX idx_productos_variantes_producto ON productos_variantes(id_producto);
CREATE INDEX idx_productos_variantes_estado   ON productos_variantes(id_estado_variantes);


-- ============================================================
-- imagen_producto
-- ============================================================
-- Solo guarda la URL. La misma foto sirve para varias variantes, por eso es
-- una tabla aparte y no una columna, y por eso la URL es unica: la foto se
-- guarda una vez y se apunta desde donde haga falta.
CREATE TABLE imagen_producto (
    id_imagen_producto   bigserial PRIMARY KEY,
    imagen_producto_url  varchar(500) NOT NULL UNIQUE
);

COMMENT ON TABLE imagen_producto IS 'Las imagenes del catalogo, una fila por URL';


-- ============================================================
-- imagen_producto_producto
-- ============================================================
-- La tabla que une imagen_producto con productos_variantes. Se llama asi
-- por su llave, id_imagen_producto_producto, tal como esta en el diagrama.
--
-- Es de muchos a muchos porque una foto de grupo aparece en varias
-- variantes y una variante muestra varias fotos.
CREATE TABLE imagen_producto_producto (
    id_imagen_producto_producto  bigserial PRIMARY KEY,

    id_imagen_producto    bigint NOT NULL REFERENCES imagen_producto(id_imagen_producto)
                          ON DELETE RESTRICT,
    id_producto_variante  bigint NOT NULL REFERENCES productos_variantes(id_producto_variante)
                          ON DELETE RESTRICT,

    numero_orden  smallint NOT NULL,

    -- Dos imagenes no pueden pelearse la misma posicion en la misma
    -- variante: sin esto el orden de la galeria dependeria del azar
    UNIQUE (id_producto_variante, numero_orden)
);

COMMENT ON TABLE imagen_producto_producto IS 'Que imagenes muestra cada variante y en que orden';
COMMENT ON COLUMN imagen_producto_producto.numero_orden IS 'La 1 es la portada de la variante';

CREATE INDEX idx_imagen_producto_producto_imagen
    ON imagen_producto_producto(id_imagen_producto);


-- ============================================================
-- productos_historial
-- ============================================================
-- Solo se inserta, nunca se actualiza ni se borra: cada fila es la version
-- del producto que regia desde su fecha_creacion. Se agrega una al crear el
-- producto y otra cada vez que se edita.
--
-- Guarda el estado completo, no el cambio. En SQL es lo natural: saber que
-- decia el producto un dia cualquiera es leer una fila, no sumar filas. El
-- ETL es el que traduce esto al registro de eventos que vive en Mongo.
--
-- No lleva estado: el estado vive en la fila viva, que si cambia.
CREATE TABLE productos_historial (
    id_producto_historial  bigserial PRIMARY KEY,

    id_producto     bigint       NOT NULL REFERENCES productos(id_producto)
                    ON DELETE RESTRICT,
    nombre          varchar(200) NOT NULL,
    descripcion     text,
    fecha_creacion  timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE productos_historial IS 'Cada version por la que ha pasado un producto';
COMMENT ON COLUMN productos_historial.fecha_creacion IS 'Desde cuando rige esta version, no cuando se toco por ultima vez';

-- "que decia este producto el 3 de marzo": con este indice la base entra
-- directo y lee una fila, sin recorrer el historial completo
CREATE INDEX idx_productos_historial_producto
    ON productos_historial(id_producto, fecha_creacion DESC);


-- ============================================================
-- productos_variantes_historial
-- ============================================================
-- Corre por separado del historial del producto. Si se renombra el producto
-- no se escribe nada aqui, y si sube el precio no se escribe nada alla: por
-- eso una linea de pedido apunta a los dos historiales y no a uno solo.
CREATE TABLE productos_variantes_historial (
    id_producto_variante_historial  bigserial PRIMARY KEY,

    id_producto_variante  bigint        NOT NULL REFERENCES productos_variantes(id_producto_variante)
                          ON DELETE RESTRICT,
    nombre_variante       varchar(100)  NOT NULL,
    precio                numeric(12,2) NOT NULL,
    descripcion           text,
    fecha_creacion        timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE productos_variantes_historial IS 'Cada version por la que ha pasado una variante, con el precio de ese dia';

CREATE INDEX idx_productos_variantes_historial_variante
    ON productos_variantes_historial(id_producto_variante, fecha_creacion DESC);


-- ============================================================
-- categorias_historial
-- ============================================================
-- El tercer historial. La comision cambia sin que nadie toque el producto,
-- y una venta tiene que cobrar la que regia ese dia.
--
-- No guarda id_categoria_padre: mover una categoria de rama no cambia lo
-- que se le cobro a una venta, y el historial existe para eso.
CREATE TABLE categorias_historial (
    id_categoria_historial  bigserial PRIMARY KEY,

    id_categoria         bigint       NOT NULL REFERENCES categorias(id_categoria)
                         ON DELETE RESTRICT,
    nombre               varchar(100) NOT NULL,
    porcentaje_comision  numeric(5,2) NOT NULL,
    fecha_creacion       timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE categorias_historial IS 'Cada version por la que ha pasado una categoria, con la comision de ese dia';

CREATE INDEX idx_categorias_historial_categoria
    ON categorias_historial(id_categoria, fecha_creacion DESC);


-- ============================================================
-- Valores de los catalogos
-- ============================================================
-- No son datos de prueba: sin ellos no se puede crear un producto.

INSERT INTO estado_producto (estado_producto_nombre) VALUES
    ('borrador'),
    ('activo'),
    ('inactivo');

INSERT INTO estado_variantes (estado_variante_nombre) VALUES
    ('activa'),
    ('inactiva');


-- ============================================================
-- Los datos de prueba
-- ============================================================
-- No estan en este archivo. Estan en migrations/datos/, un archivo por
-- conjunto, y se corren despues de todas las migraciones. Ver
-- migrations/README.md.
