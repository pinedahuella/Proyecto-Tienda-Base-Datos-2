-- 003_productos.sql
-- El catalogo: categorias, productos, variantes, imagenes y los tres
-- historiales del alcance de productos.
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
-- Datos de prueba
-- ============================================================
-- El documento del curso pide un conjunto de datos representativo que
-- sustente las consultas de las entregas siguientes. De aqui salen los
-- eventos que el ETL carga en Mongo, asi que las fechas van escritas a mano
-- y no con now(): con now() todo el historial cae en el mismo instante y no
-- queda nada que reconstruir.
--
-- Las filas de prueba llevan id explicito porque el historial y las
-- imagenes tienen que apuntarles, y buscarlas por nombre no sirve: el
-- nombre de un producto cambia a mitad del historial. Las secuencias se
-- reajustan al final para que la aplicacion siga numerando donde esto
-- termino.
--
-- Las fechas llevan la zona de Guatemala escrita, -06, para que no dependan
-- de la zona en la que este el servidor.
--
-- Regla que cumplen todas las filas vivas: sus valores son los del ultimo
-- renglon de su historial, pero su fecha_creacion es la del primero, que es
-- cuando nacio la fila.


-- El vendedor dueno de los tres productos. El correo es unico, asi que
-- ON CONFLICT deja que la insercion pase de largo si la cuenta ya esta.
INSERT INTO usuarios (
    correo_electronico, usuario, nombre, apellido, contrasena_hash,
    fecha_nacimiento, fecha_creacion, id_rol_usuario, id_estado_usuario
)
SELECT
    'vendedor.prueba@mesh.com',
    'vendedor_prueba',
    'Carlos',
    'Ramirez',
    '$2b$12$K7QpX2mWv9LrTaZbCdEfGhu3NjYkS8vQ1oPzRxLmTbCw5AeDfHgIr',
    '1990-05-14',
    '2026-01-02 08:00:00-06',
    (SELECT id_rol_usuario    FROM rol_usuario    WHERE rol_usuario_nombre    = 'vendedor'),
    (SELECT id_estado_usuario FROM estado_usuario WHERE estado_usuario_nombre = 'activo')
ON CONFLICT (correo_electronico) DO NOTHING;


-- ------------------------------------------------------------
-- Categorias
-- ------------------------------------------------------------
-- Tres ramas, dos de ellas con nieto, para que el arbol se pueda recorrer
-- de verdad:
--   Ropa > Ropa de hombre > Camisas
--   Electronica > Computadoras
--   Hogar > Cocina
--
-- Camisas queda en 12.00 y no en 10.00 porque la comision subio el 1 de
-- marzo.

INSERT INTO categorias (id_categoria, nombre, porcentaje_comision, fecha_creacion, id_categoria_padre) VALUES
    (1, 'Ropa',            8.00, '2026-01-05 10:00:00-06', NULL),
    (2, 'Ropa de hombre',  8.00, '2026-01-05 10:05:00-06', 1),
    (3, 'Camisas',        12.00, '2026-01-05 10:10:00-06', 2),
    (4, 'Electronica',     5.00, '2026-01-05 10:15:00-06', NULL),
    (5, 'Computadoras',    6.00, '2026-01-05 10:20:00-06', 4),
    (6, 'Hogar',           7.00, '2026-01-05 10:25:00-06', NULL),
    (7, 'Cocina',          7.50, '2026-01-05 10:30:00-06', 6);

INSERT INTO categorias_historial (id_categoria_historial, id_categoria, nombre, porcentaje_comision, fecha_creacion) VALUES
    (1,  1, 'Ropa',            8.00, '2026-01-05 10:00:00-06'),
    (2,  2, 'Ropa de hombre',  8.00, '2026-01-05 10:05:00-06'),
    (3,  3, 'Camisas',        10.00, '2026-01-05 10:10:00-06'),
    -- La tienda sube la comision de camisas. Ese dia nadie toco la camisa
    -- de lino y aun asi su comision cambio: por eso el pedido apunta
    -- tambien al historial de la categoria y no solo al del producto.
    (4,  3, 'Camisas',        12.00, '2026-03-01 09:00:00-06'),
    (5,  4, 'Electronica',     5.00, '2026-01-05 10:15:00-06'),
    (6,  5, 'Computadoras',    6.00, '2026-01-05 10:20:00-06'),
    (7,  6, 'Hogar',           7.00, '2026-01-05 10:25:00-06'),
    (8,  7, 'Cocina',          7.50, '2026-01-05 10:30:00-06');


-- ------------------------------------------------------------
-- Productos
-- ------------------------------------------------------------
-- El producto 1 se llama distinto al principio y al final: el 10 de febrero
-- se renombro.

INSERT INTO productos (id_producto, nombre, descripcion, fecha_creacion, id_usuario, id_estado_producto, id_categoria)
SELECT
    v.id_producto, v.nombre, v.descripcion, v.fecha_creacion,
    (SELECT id_usuario FROM usuarios WHERE correo_electronico = 'vendedor.prueba@mesh.com'),
    (SELECT id_estado_producto FROM estado_producto WHERE estado_producto_nombre = 'activo'),
    v.id_categoria
FROM (VALUES
    (1::bigint, 'Camisa de lino manga larga', 'Camisa de lino de corte regular, cuello italiano',           '2026-01-10 09:00:00-06'::timestamptz, 3::bigint),
    (2,         'Laptop 14 pulgadas',         'Laptop de 14 pulgadas para trabajo y estudio',               '2026-01-15 11:30:00-06',              5),
    (3,         'Cafetera de goteo',          'Cafetera de goteo con jarra de vidrio y filtro permanente',  '2026-02-01 08:00:00-06',              7)
) AS v (id_producto, nombre, descripcion, fecha_creacion, id_categoria);

INSERT INTO productos_historial (id_producto_historial, id_producto, nombre, descripcion, fecha_creacion) VALUES
    (1,  1, 'Camisa de lino',             'Camisa de lino de corte regular, cuello italiano', '2026-01-10 09:00:00-06'),
    -- Solo cambia el nombre. El precio ya habia subido el 5 de febrero y
    -- ese cambio no aparece aqui: son dos historiales distintos y cada uno
    -- guarda lo suyo.
    (2,  1, 'Camisa de lino manga larga', 'Camisa de lino de corte regular, cuello italiano', '2026-02-10 14:00:00-06'),

    (3,  2, 'Laptop 14 pulgadas',         'Laptop de 14 pulgadas para trabajo y estudio',     '2026-01-15 11:30:00-06'),

    (4,  3, 'Cafetera de goteo',          'Cafetera de goteo con jarra de vidrio',            '2026-02-01 08:00:00-06'),
    -- Aqui al reves: cambia la descripcion y el nombre se queda igual
    (5,  3, 'Cafetera de goteo',          'Cafetera de goteo con jarra de vidrio y filtro permanente', '2026-03-05 16:00:00-06');


-- ------------------------------------------------------------
-- Variantes
-- ------------------------------------------------------------

INSERT INTO productos_variantes (id_producto_variante, id_producto, nombre_variante, precio, fecha_creacion, id_estado_variantes, descripcion)
SELECT
    v.id_producto_variante, v.id_producto, v.nombre_variante, v.precio, v.fecha_creacion,
    (SELECT id_estado_variante FROM estado_variantes WHERE estado_variante_nombre = 'activa'),
    v.descripcion
FROM (VALUES
    (1::bigint, 1::bigint, 'M azul',      169.00::numeric, '2026-01-10 09:00:00-06'::timestamptz, 'Talla M, color azul'),
    (2,         1,         'L azul',      159.00,          '2026-01-10 09:00:00-06',              'Talla L, color azul'),
    (3,         2,         '8 GB RAM',   4299.00,          '2026-01-15 11:30:00-06',              'Pantalla de 14 pulgadas, 8 GB de RAM, 256 GB SSD'),
    (4,         2,         '16 GB RAM',  4999.00,          '2026-01-15 11:30:00-06',              'Pantalla de 14 pulgadas, 16 GB de RAM, 1 TB SSD'),
    (5,         3,         '1.2 litros',  349.00,          '2026-02-01 08:00:00-06',              'Jarra de 1.2 litros, rinde 10 tazas')
) AS v (id_producto_variante, id_producto, nombre_variante, precio, fecha_creacion, descripcion);

INSERT INTO productos_variantes_historial (id_producto_variante_historial, id_producto_variante, nombre_variante, precio, descripcion, fecha_creacion) VALUES
    (1,  1, 'M azul',      149.00, 'Talla M, color azul', '2026-01-10 09:00:00-06'),
    -- 5 de febrero sube el precio, 10 de febrero se renombra el producto.
    -- Dos modificaciones, dos fechas, dos campos que no se pisan: quien
    -- reconstruya con la creacion mas la ultima modificacion pierde una de
    -- las dos.
    (2,  1, 'M azul',      169.00, 'Talla M, color azul', '2026-02-05 11:00:00-06'),

    (3,  2, 'L azul',      159.00, 'Talla L, color azul', '2026-01-10 09:00:00-06'),

    (4,  3, '8 GB RAM',   4299.00, 'Pantalla de 14 pulgadas, 8 GB de RAM, 256 GB SSD',  '2026-01-15 11:30:00-06'),

    (5,  4, '16 GB RAM',  5199.00, 'Pantalla de 14 pulgadas, 16 GB de RAM, 512 GB SSD', '2026-01-15 11:30:00-06'),
    -- El mismo caso pero dentro de un solo historial: primero baja el
    -- precio y despues cambia el disco. Tomar la creacion y la ultima fila
    -- devuelve 5199.00, que nunca fue el precio de esta variante con 1 TB.
    (6,  4, '16 GB RAM',  4999.00, 'Pantalla de 14 pulgadas, 16 GB de RAM, 512 GB SSD', '2026-02-18 10:00:00-06'),
    (7,  4, '16 GB RAM',  4999.00, 'Pantalla de 14 pulgadas, 16 GB de RAM, 1 TB SSD',   '2026-03-20 15:00:00-06'),

    (8,  5, '1.2 litros',  349.00, 'Jarra de 1.2 litros, rinde 10 tazas', '2026-02-01 08:00:00-06');


-- ------------------------------------------------------------
-- Imagenes
-- ------------------------------------------------------------
-- Nueve URLs para diez posiciones: la foto de camisas surtidas la usan las
-- dos variantes de la camisa. Eso es lo que permite la tabla de union y lo
-- que no permitiria una columna de URL dentro de la variante.

INSERT INTO imagen_producto (id_imagen_producto, imagen_producto_url) VALUES
    (1, 'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Blue_Business_Shirt.jpg/960px-Blue_Business_Shirt.jpg'),
    (2, 'https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Button_down_dress_shirts_for_men.jpg/960px-Button_down_dress_shirts_for_men.jpg'),
    (3, 'https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Pink_and_blue_dress_shirts%2C_JCPenney.jpg/960px-Pink_and_blue_dress_shirts%2C_JCPenney.jpg'),
    (4, 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/37/Schenker_VIA14_Laptop_asv2021-01.jpg/960px-Schenker_VIA14_Laptop_asv2021-01.jpg'),
    (5, 'https://upload.wikimedia.org/wikipedia/commons/thumb/9/95/ThinkPad_T480.jpg/960px-ThinkPad_T480.jpg'),
    (6, 'https://upload.wikimedia.org/wikipedia/commons/thumb/a/a6/Lenovo_ThinkPad_T470.jpg/960px-Lenovo_ThinkPad_T470.jpg'),
    (7, 'https://upload.wikimedia.org/wikipedia/commons/thumb/2/28/ThinkPad_T480_%282%29_%28cropped%29.jpg/960px-ThinkPad_T480_%282%29_%28cropped%29.jpg'),
    (8, 'https://upload.wikimedia.org/wikipedia/commons/thumb/b/bb/Hamilton_Beach_home_coffee_maker.jpg/960px-Hamilton_Beach_home_coffee_maker.jpg'),
    (9, 'https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Our_new_coffee_maker_%282006%29_Hamilton_Beach.jpg/960px-Our_new_coffee_maker_%282006%29_Hamilton_Beach.jpg');

INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden) VALUES
    (1, 1, 1),
    (2, 1, 2),
    (3, 2, 1),
    (2, 2, 2),
    (4, 3, 1),
    (5, 3, 2),
    (6, 4, 1),
    (7, 4, 2),
    (8, 5, 1),
    (9, 5, 2);


-- ------------------------------------------------------------
-- Secuencias
-- ------------------------------------------------------------
-- Los id de arriba se escribieron a mano, asi que las secuencias siguen en
-- 1 y el primer producto que cree la aplicacion chocaria con el id 1. Esto
-- las deja apuntando al ultimo id usado.

SELECT setval(pg_get_serial_sequence('categorias',          'id_categoria'),         max(id_categoria))         FROM categorias;
SELECT setval(pg_get_serial_sequence('productos',           'id_producto'),          max(id_producto))          FROM productos;
SELECT setval(pg_get_serial_sequence('productos_variantes', 'id_producto_variante'), max(id_producto_variante)) FROM productos_variantes;
SELECT setval(pg_get_serial_sequence('imagen_producto',     'id_imagen_producto'),   max(id_imagen_producto))   FROM imagen_producto;
SELECT setval(pg_get_serial_sequence('categorias_historial',          'id_categoria_historial'),          max(id_categoria_historial))          FROM categorias_historial;
SELECT setval(pg_get_serial_sequence('productos_historial',           'id_producto_historial'),           max(id_producto_historial))           FROM productos_historial;
SELECT setval(pg_get_serial_sequence('productos_variantes_historial', 'id_producto_variante_historial'),  max(id_producto_variante_historial))  FROM productos_variantes_historial;
