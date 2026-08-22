-- datos/001_catalogo_base.sql
-- El conjunto de datos original: tres productos con historial de verdad.
--
-- Estos tres son los que prueban la reconstruccion por fecha, y por eso
-- llevan modificaciones. El ejemplo del 15 de marzo que esta escrito en
-- etl/README.md sale de aqui: si se cambia una fecha o un precio, ese
-- ejemplo deja de cuadrar.
--
-- Los id van escritos a mano y cuentan seguido desde 1, sin saltos. Este es el
-- primer conjunto, asi que arranca en 1; el que sigue continua donde este
-- termina.
--
-- Todo inserta con ON CONFLICT DO NOTHING. A diferencia de las migraciones,
-- este archivo si llega a ejecutarse en cada arranque, y sin eso la segunda
-- corrida se cae por llave duplicada. El mensaje de Postgres en ese caso
-- dice "already exists", que es justo lo que arrancar.ps1 interpreta como
-- "ya estaba aplicada": el error pasaria inadvertido.
--
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
WHERE NOT EXISTS (
    -- usuarios tiene DOS restricciones unicas, el correo y el nombre. Un
    -- ON CONFLICT solo vigila una, y si el nombre ya estaba ocupado la
    -- migracion reventaba. Asi se comprueban las dos antes de intentarlo.
    SELECT 1 FROM usuarios
    WHERE correo_electronico = 'vendedor.prueba@mesh.com'
       OR usuario            = 'vendedor_prueba'
);


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
    (7, 'Cocina',          7.50, '2026-01-05 10:30:00-06', 6)
ON CONFLICT DO NOTHING;

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
    (8,  7, 'Cocina',          7.50, '2026-01-05 10:30:00-06')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Productos
-- ------------------------------------------------------------
-- El producto 1 se llama distinto al principio y al final: el 10 de febrero
-- se renombro.

INSERT INTO productos (id_producto, nombre, descripcion, fecha_creacion, id_usuario, id_estado_producto, id_categoria)
SELECT
    v.id_producto, v.nombre, v.descripcion, v.fecha_creacion,
    -- Se busca por correo, pero con red debajo: si alguien ya ocupaba ese
    -- nombre de usuario, el INSERT de arriba no lo creo y esta consulta daria
    -- nulo, que la columna no acepta. Cae entonces a cualquier vendedor.
    COALESCE(
        (SELECT id_usuario FROM usuarios WHERE correo_electronico = 'vendedor.prueba@mesh.com'),
        (SELECT id_usuario FROM usuarios
          WHERE id_rol_usuario = (SELECT id_rol_usuario FROM rol_usuario
                                   WHERE rol_usuario_nombre = 'vendedor')
          ORDER BY id_usuario LIMIT 1)
    ),
    (SELECT id_estado_producto FROM estado_producto WHERE estado_producto_nombre = 'activo'),
    v.id_categoria
FROM (VALUES
    (1::bigint, 'Camisa de lino manga larga', 'Camisa de lino de corte regular, cuello italiano',           '2026-01-10 09:00:00-06'::timestamptz, 3::bigint),
    (2,         'Laptop 14 pulgadas',         'Laptop de 14 pulgadas para trabajo y estudio',               '2026-01-15 11:30:00-06',              5),
    (3,         'Cafetera de goteo',          'Cafetera de goteo con jarra de vidrio y filtro permanente',  '2026-02-01 08:00:00-06',              7)
) AS v (id_producto, nombre, descripcion, fecha_creacion, id_categoria)
ON CONFLICT DO NOTHING;

INSERT INTO productos_historial (id_producto_historial, id_producto, nombre, descripcion, fecha_creacion) VALUES
    (1,  1, 'Camisa de lino',             'Camisa de lino de corte regular, cuello italiano', '2026-01-10 09:00:00-06'),
    -- Solo cambia el nombre. El precio ya habia subido el 5 de febrero y
    -- ese cambio no aparece aqui: son dos historiales distintos y cada uno
    -- guarda lo suyo.
    (2,  1, 'Camisa de lino manga larga', 'Camisa de lino de corte regular, cuello italiano', '2026-02-10 14:00:00-06'),

    (3,  2, 'Laptop 14 pulgadas',         'Laptop de 14 pulgadas para trabajo y estudio',     '2026-01-15 11:30:00-06'),

    (4,  3, 'Cafetera de goteo',          'Cafetera de goteo con jarra de vidrio',            '2026-02-01 08:00:00-06'),
    -- Aqui al reves: cambia la descripcion y el nombre se queda igual
    (5,  3, 'Cafetera de goteo',          'Cafetera de goteo con jarra de vidrio y filtro permanente', '2026-03-05 16:00:00-06')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Variantes
-- ------------------------------------------------------------

-- Las caracteristicas de la variante son las que la separan de sus
-- hermanas. La talla esta en las dos variantes de la camisa porque es lo
-- unico que las distingue; el material no, que ese es del producto entero.
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
) AS v (id_producto_variante, id_producto, nombre_variante, precio, fecha_creacion, descripcion)
ON CONFLICT DO NOTHING;

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

    (8,  5, '1.2 litros',  349.00, 'Jarra de 1.2 litros, rinde 10 tazas', '2026-02-01 08:00:00-06')
ON CONFLICT DO NOTHING;


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
    (9, 'https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Our_new_coffee_maker_%282006%29_Hamilton_Beach.jpg/960px-Our_new_coffee_maker_%282006%29_Hamilton_Beach.jpg')
-- Sin nombrar la restriccion: aqui se puede chocar por dos, la llave
-- primaria y el UNIQUE de la URL
ON CONFLICT DO NOTHING;

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
    (9, 5, 2)
ON CONFLICT DO NOTHING;


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
