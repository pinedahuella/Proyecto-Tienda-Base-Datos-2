-- datos/002_catalogo_ampliado.sql
-- El conjunto que amplia el catalogo: 47 productos mas, para llegar a 50.
--
-- Los id continuan donde termino datos/001_catalogo_base.sql, sin saltos: los
-- productos van del 4 al 50, las variantes del 6 al 92 y las categorias del 8
-- al 27. Este archivo no reescribe nada de aquel, solo sigue contando.
--
-- Ninguno de estos productos tiene modificaciones. Cada uno lleva una sola
-- fila de productos_historial, cada variante una sola de
-- productos_variantes_historial y cada categoria nueva una sola de
-- categorias_historial, todas con el mismo instante que la fila viva. Los
-- tres productos del conjunto base son los que prueban la reconstruccion por
-- fecha; estos prueban el volumen y la variedad de categorias.
--
-- Las cuatro fechas de un producto tienen que ser el mismo instante: el ETL
-- arma un evento por cada fecha distinta que encuentre en los tres
-- historiales, asi que un minuto de diferencia entre el producto y su
-- variante inventa una modificacion que nadie hizo.
--
-- Por lo mismo, todos estos productos nacen en abril o despues. La comision
-- de Camisas cambio el 1 de marzo, y un producto de esa categoria nacido
-- antes heredaria ese cambio como si fuera suyo.
--
-- Todo inserta con ON CONFLICT DO NOTHING y con id escrito a mano: asi la
-- segunda corrida choca contra la llave primaria y no duplica. Sin el
-- ON CONFLICT el error diria "already exists", que es justo lo que
-- arrancar.ps1 interpreta como "ya estaba aplicada".
--
-- Las fechas llevan la zona de Guatemala escrita, -06, para que no dependan
-- de la zona en la que este el servidor.


-- ------------------------------------------------------------
-- Vendedor
-- ------------------------------------------------------------
-- Un segundo vendedor para que el catalogo no sea de una sola cuenta: las
-- consultas por vendedor no dicen nada si todo es del mismo. Se resuelve por
-- correo y nunca por id, porque los id de usuario los reparte la aplicacion
-- al registrarse y en cada maquina caen distintos.

INSERT INTO usuarios (
    correo_electronico, usuario, nombre, apellido, contrasena_hash,
    fecha_nacimiento, fecha_creacion, id_rol_usuario, id_estado_usuario
)
SELECT
    'ventas.norte@mesh.com',
    'ventas_norte',
    'Lucia',
    'Mendez',
    '$2b$12$R4tYuI8oPlKjHgFdSaZxCe7bNmQwErTyUiOpAsDfGhJkLzXcVbNmO',
    '1988-11-23',
    '2026-03-05 09:00:00-06',
    (SELECT id_rol_usuario    FROM rol_usuario    WHERE rol_usuario_nombre    = 'vendedor'),
    (SELECT id_estado_usuario FROM estado_usuario WHERE estado_usuario_nombre = 'activo')
WHERE NOT EXISTS (
    -- usuarios tiene DOS restricciones unicas, el correo y el nombre de usuario.
    -- Un ON CONFLICT solo puede vigilar una: si alguien ya se registro con el
    -- nombre ventas_norte y otro correo, la migracion reventaba. Con NOT EXISTS
    -- se comprueban las dos antes de intentar el INSERT.
    SELECT 1 FROM usuarios
    WHERE correo_electronico = 'ventas.norte@mesh.com'
       OR usuario            = 'ventas_norte'
);


-- ------------------------------------------------------------
-- Categorias
-- ------------------------------------------------------------
-- Veinte categorias mas. Casi todas cuelgan de las siete que ya existen:
--   Ropa > Ropa de mujer > Vestidos
--   Ropa > Ropa de hombre > Pantalones
--   Ropa > Calzado > Botas, Sandalias, Tenis
--   Electronica > Audio > Audifonos
--   Electronica > Telefonia > Telefonos
--   Electronica > Computadoras > Monitores, Accesorios de computadora
--   Hogar > Iluminacion
--   Hogar > Cocina > Electrodomesticos de cocina
--
-- Deportes y Libros son ramas nuevas y por eso nacen con el padre en NULL,
-- igual que Ropa, Electronica y Hogar: en este modelo un departamento de
-- primer nivel es una raiz. Colgarlos de cualquiera de los tres existentes
-- daria un arbol que no se parece a la tienda.
--
-- Todas se crean el 10 de marzo, antes que cualquier producto de este
-- archivo, y con una sola fila de historial: su comision nunca ha cambiado.

INSERT INTO categorias (id_categoria, nombre, porcentaje_comision, fecha_creacion, id_categoria_padre) VALUES
    (8, 'Ropa de mujer',                8.00, '2026-03-10 09:00:00-06', 1),
    (9, 'Vestidos',                     9.00, '2026-03-10 09:05:00-06', 8),
    (10, 'Pantalones',                   8.50, '2026-03-10 09:10:00-06', 2),
    (11, 'Calzado',                      9.00, '2026-03-10 09:15:00-06', 1),
    (12, 'Botas',                       10.00, '2026-03-10 09:20:00-06', 11),
    (13, 'Sandalias',                    9.50, '2026-03-10 09:25:00-06', 11),
    (14, 'Tenis',                       10.50, '2026-03-10 09:30:00-06', 11),
    (15, 'Audio',                        6.00, '2026-03-10 09:35:00-06', 4),
    (16, 'Audifonos',                    6.50, '2026-03-10 09:40:00-06', 15),
    (17, 'Telefonia',                    5.50, '2026-03-10 09:45:00-06', 4),
    (18, 'Telefonos',                    6.00, '2026-03-10 09:50:00-06', 17),
    (19, 'Monitores',                    6.50, '2026-03-10 09:55:00-06', 5),
    (20, 'Accesorios de computadora',    7.00, '2026-03-10 10:00:00-06', 5),
    (21, 'Iluminacion',                  7.00, '2026-03-10 10:05:00-06', 6),
    (22, 'Electrodomesticos de cocina',  8.00, '2026-03-10 10:10:00-06', 7),
    (23, 'Deportes',                     7.50, '2026-03-10 10:15:00-06', NULL),
    (24, 'Fitness',                      8.00, '2026-03-10 10:20:00-06', 23),
    (25, 'Ciclismo',                     7.00, '2026-03-10 10:25:00-06', 23),
    (26, 'Libros',                       5.00, '2026-03-10 10:30:00-06', NULL),
    (27, 'Libros de texto',              5.50, '2026-03-10 10:35:00-06', 26)
ON CONFLICT DO NOTHING;

INSERT INTO categorias_historial (id_categoria_historial, id_categoria, nombre, porcentaje_comision, fecha_creacion) VALUES
    (9, 8, 'Ropa de mujer',                8.00, '2026-03-10 09:00:00-06'),
    (10, 9, 'Vestidos',                     9.00, '2026-03-10 09:05:00-06'),
    (11, 10, 'Pantalones',                   8.50, '2026-03-10 09:10:00-06'),
    (12, 11, 'Calzado',                      9.00, '2026-03-10 09:15:00-06'),
    (13, 12, 'Botas',                       10.00, '2026-03-10 09:20:00-06'),
    (14, 13, 'Sandalias',                    9.50, '2026-03-10 09:25:00-06'),
    (15, 14, 'Tenis',                       10.50, '2026-03-10 09:30:00-06'),
    (16, 15, 'Audio',                        6.00, '2026-03-10 09:35:00-06'),
    (17, 16, 'Audifonos',                    6.50, '2026-03-10 09:40:00-06'),
    (18, 17, 'Telefonia',                    5.50, '2026-03-10 09:45:00-06'),
    (19, 18, 'Telefonos',                    6.00, '2026-03-10 09:50:00-06'),
    (20, 19, 'Monitores',                    6.50, '2026-03-10 09:55:00-06'),
    (21, 20, 'Accesorios de computadora',    7.00, '2026-03-10 10:00:00-06'),
    (22, 21, 'Iluminacion',                  7.00, '2026-03-10 10:05:00-06'),
    (23, 22, 'Electrodomesticos de cocina',  8.00, '2026-03-10 10:10:00-06'),
    (24, 23, 'Deportes',                     7.50, '2026-03-10 10:15:00-06'),
    (25, 24, 'Fitness',                      8.00, '2026-03-10 10:20:00-06'),
    (26, 25, 'Ciclismo',                     7.00, '2026-03-10 10:25:00-06'),
    (27, 26, 'Libros',                       5.00, '2026-03-10 10:30:00-06'),
    (28, 27, 'Libros de texto',              5.50, '2026-03-10 10:35:00-06')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Productos
-- ------------------------------------------------------------

INSERT INTO productos (id_producto, nombre, descripcion, fecha_creacion, id_usuario, id_estado_producto, id_categoria)
SELECT
    v.id_producto, v.nombre, v.descripcion, v.fecha_creacion,
    -- Se busca por correo, pero con red debajo: si alguien ya ocupaba ese
    -- nombre de usuario, el INSERT de arriba no lo creo y esta consulta daria
    -- nulo, que la columna no acepta. Cae entonces a cualquier vendedor.
    COALESCE(
        (SELECT id_usuario FROM usuarios WHERE correo_electronico = v.correo),
        (SELECT id_usuario FROM usuarios
          WHERE id_rol_usuario = (SELECT id_rol_usuario FROM rol_usuario
                                   WHERE rol_usuario_nombre = 'vendedor')
          ORDER BY id_usuario LIMIT 1)
    ),
    (SELECT id_estado_producto FROM estado_producto WHERE estado_producto_nombre = 'activo'),
    v.id_categoria
FROM (VALUES
    (4::bigint, 'Camisa oxford de algodon', 'Camisa oxford de corte slim con cuello button down', '2026-04-01 08:00:00-06'::timestamptz, 'vendedor.prueba@mesh.com', 3::bigint),
    (5, 'Camisa tenida artesanal', 'Camisa de algodon tenida a mano, pieza unica', '2026-04-02 09:00:00-06', 'ventas.norte@mesh.com', 3),
    (6, 'Camisa formal manga corta', 'Camisa formal de manga corta para clima calido', '2026-04-03 10:00:00-06', 'vendedor.prueba@mesh.com', 3),
    (7, 'Jeans de corte recto', 'Pantalon de mezclilla de corte recto y tiro medio', '2026-04-04 11:00:00-06', 'ventas.norte@mesh.com', 10),
    (8, 'Jeans desgastado', 'Pantalon de mezclilla con lavado stone wash', '2026-04-05 12:00:00-06', 'vendedor.prueba@mesh.com', 10),
    (9, 'Pantalon de vestir', 'Pantalon de vestir sin pinzas, caida recta', '2026-04-06 13:00:00-06', 'ventas.norte@mesh.com', 10),
    (10, 'Vestido de punto cuello alto', 'Vestido de punto midi con cuello alto', '2026-04-07 14:00:00-06', 'vendedor.prueba@mesh.com', 9),
    (11, 'Vestido casual de invierno', 'Vestido corto de manga larga para diario', '2026-04-08 15:00:00-06', 'ventas.norte@mesh.com', 9),
    (12, 'Botas de cuero', 'Botas de cuero con suela de goma para uso diario', '2026-04-09 16:00:00-06', 'vendedor.prueba@mesh.com', 12),
    (13, 'Botas de trabajo con casquillo', 'Botas de trabajo con casquillo de acero y suela antiderrapante', '2026-04-10 08:00:00-06', 'ventas.norte@mesh.com', 12),
    (14, 'Sandalias de playa', 'Sandalias de caucho con plantilla texturizada', '2026-04-11 09:00:00-06', 'vendedor.prueba@mesh.com', 13),
    (15, 'Sandalias de bano', 'Sandalias livianas de espuma para interiores', '2026-04-12 10:00:00-06', 'ventas.norte@mesh.com', 13),
    (16, 'Tenis para correr', 'Tenis de malla transpirable para correr en asfalto', '2026-04-13 11:00:00-06', 'vendedor.prueba@mesh.com', 14),
    (17, 'Tenis urbanos de lona', 'Tenis de lona con suela vulcanizada para uso diario', '2026-04-14 12:00:00-06', 'ventas.norte@mesh.com', 14),
    (18, 'Audifonos inalambricos de diadema', 'Audifonos de diadema con bluetooth y bateria de larga duracion', '2026-04-15 13:00:00-06', 'vendedor.prueba@mesh.com', 16),
    (19, 'Audifonos con cable', 'Audifonos de diadema con cable de 3.5 milimetros', '2026-04-16 14:00:00-06', 'ventas.norte@mesh.com', 16),
    (20, 'Audifonos deportivos', 'Audifonos intrauriculares resistentes al sudor', '2026-04-17 15:00:00-06', 'vendedor.prueba@mesh.com', 16),
    (21, 'Telefono inteligente de 6.1 pulgadas', 'Telefono inteligente de gama media con camara de 48 megapixeles', '2026-04-18 16:00:00-06', 'ventas.norte@mesh.com', 18),
    (22, 'Telefono basico', 'Telefono de teclas con bateria de larga duracion', '2026-04-19 08:00:00-06', 'vendedor.prueba@mesh.com', 18),
    (23, 'Telefono inteligente de 6.7 pulgadas', 'Telefono inteligente de pantalla grande y bateria de 5000 miliamperios', '2026-04-20 09:00:00-06', 'ventas.norte@mesh.com', 18),
    (24, 'Monitor de 24 pulgadas', 'Monitor de 24 pulgadas con panel IPS para oficina', '2026-04-21 10:00:00-06', 'vendedor.prueba@mesh.com', 19),
    (25, 'Monitor de 27 pulgadas para juegos', 'Monitor de 27 pulgadas a 144 hercios', '2026-04-22 11:00:00-06', 'ventas.norte@mesh.com', 19),
    (26, 'Laptop de 15 pulgadas', 'Laptop de 15.6 pulgadas para trabajo diario', '2026-04-23 12:00:00-06', 'vendedor.prueba@mesh.com', 5),
    (27, 'Laptop empresarial de 14 pulgadas', 'Laptop empresarial con teclado retroiluminado y lector de huella', '2026-04-24 13:00:00-06', 'ventas.norte@mesh.com', 5),
    (28, 'Laptop ligera para estudio', 'Laptop de 13.3 pulgadas y 1.2 kilogramos', '2026-04-25 14:00:00-06', 'vendedor.prueba@mesh.com', 5),
    (29, 'Teclado mecanico', 'Teclado mecanico con distribucion en espanol latinoamericano', '2026-04-26 15:00:00-06', 'ventas.norte@mesh.com', 20),
    (30, 'Mouse inalambrico', 'Mouse optico con receptor USB', '2026-04-27 16:00:00-06', 'vendedor.prueba@mesh.com', 20),
    (31, 'Base enfriadora para laptop', 'Base de aluminio con dos ventiladores', '2026-04-28 08:00:00-06', 'ventas.norte@mesh.com', 20),
    (32, 'Lampara de escritorio inteligente', 'Lampara de escritorio que se controla desde el telefono', '2026-04-29 09:00:00-06', 'vendedor.prueba@mesh.com', 21),
    (33, 'Lampara de pie', 'Lampara de pie con interruptor de pedal', '2026-04-30 10:00:00-06', 'ventas.norte@mesh.com', 21),
    (34, 'Tira de luz LED', 'Tira de luz LED con control remoto y cambio de color', '2026-05-01 11:00:00-06', 'vendedor.prueba@mesh.com', 21),
    (35, 'Juego de moldes para reposteria', 'Juego de seis moldes de acero antiadherente', '2026-05-02 12:00:00-06', 'ventas.norte@mesh.com', 7),
    (36, 'Batidora de mano', 'Batidora de mano de cinco velocidades', '2026-05-03 13:00:00-06', 'vendedor.prueba@mesh.com', 7),
    (37, 'Juego de tazones de mezcla', 'Tres tazones de vidrio templado apilables', '2026-05-04 14:00:00-06', 'ventas.norte@mesh.com', 7),
    (38, 'Licuadora de vaso de vidrio', 'Licuadora de tres velocidades con vaso de vidrio', '2026-05-05 15:00:00-06', 'vendedor.prueba@mesh.com', 22),
    (39, 'Horno tostador', 'Horno tostador de 20 litros con temporizador', '2026-05-06 16:00:00-06', 'ventas.norte@mesh.com', 22),
    (40, 'Freidora de aire', 'Freidora de aire con canasta antiadherente', '2026-05-07 08:00:00-06', 'vendedor.prueba@mesh.com', 22),
    (41, 'Mancuerna de disco ajustable', 'Mancuerna con discos intercambiables para entrenar en casa', '2026-05-08 09:00:00-06', 'ventas.norte@mesh.com', 24),
    (42, 'Banda elastica de resistencia', 'Banda de latex de dos metros para ejercicio', '2026-05-09 10:00:00-06', 'vendedor.prueba@mesh.com', 24),
    (43, 'Tapete de yoga', 'Tapete de seis milimetros con superficie antiderrapante', '2026-05-10 11:00:00-06', 'ventas.norte@mesh.com', 24),
    (44, 'Bicicleta urbana', 'Bicicleta urbana de aluminio con siete velocidades', '2026-05-11 12:00:00-06', 'vendedor.prueba@mesh.com', 25),
    (45, 'Casco para ciclista', 'Casco de policarbonato con 18 ventilas', '2026-05-12 13:00:00-06', 'ventas.norte@mesh.com', 25),
    (46, 'Luz trasera recargable', 'Luz trasera de 60 lumenes con carga por USB', '2026-05-13 14:00:00-06', 'vendedor.prueba@mesh.com', 25),
    (47, 'Balon de futbol numero 5', 'Balon de poliuretano numero 5 para cancha de pasto', '2026-05-14 15:00:00-06', 'ventas.norte@mesh.com', 23),
    (48, 'Bases de datos, teoria y practica', 'Libro de texto de bases de datos relacionales y no relacionales', '2026-05-15 16:00:00-06', 'vendedor.prueba@mesh.com', 27),
    (49, 'Calculo de una variable', 'Libro de texto de calculo diferencial e integral', '2026-05-16 08:00:00-06', 'ventas.norte@mesh.com', 27),
    (50, 'El camino de las nubes', 'Novela sobre un viaje por el altiplano', '2026-05-17 09:00:00-06', 'vendedor.prueba@mesh.com', 26)
) AS v (id_producto, nombre, descripcion, fecha_creacion, correo, id_categoria)
ON CONFLICT DO NOTHING;

-- Una sola fila por producto, con la misma fecha y el mismo texto que la fila
-- viva: asi el ETL escribe un evento de creacion y ninguna modificacion.

INSERT INTO productos_historial (id_producto_historial, id_producto, nombre, descripcion, fecha_creacion) VALUES
    (6, 4, 'Camisa oxford de algodon',             'Camisa oxford de corte slim con cuello button down',                     '2026-04-01 08:00:00-06'),
    (7, 5, 'Camisa tenida artesanal',              'Camisa de algodon tenida a mano, pieza unica',                           '2026-04-02 09:00:00-06'),
    (8, 6, 'Camisa formal manga corta',            'Camisa formal de manga corta para clima calido',                         '2026-04-03 10:00:00-06'),
    (9, 7, 'Jeans de corte recto',                 'Pantalon de mezclilla de corte recto y tiro medio',                      '2026-04-04 11:00:00-06'),
    (10, 8, 'Jeans desgastado',                     'Pantalon de mezclilla con lavado stone wash',                            '2026-04-05 12:00:00-06'),
    (11, 9, 'Pantalon de vestir',                   'Pantalon de vestir sin pinzas, caida recta',                             '2026-04-06 13:00:00-06'),
    (12, 10, 'Vestido de punto cuello alto',         'Vestido de punto midi con cuello alto',                                  '2026-04-07 14:00:00-06'),
    (13, 11, 'Vestido casual de invierno',           'Vestido corto de manga larga para diario',                               '2026-04-08 15:00:00-06'),
    (14, 12, 'Botas de cuero',                       'Botas de cuero con suela de goma para uso diario',                       '2026-04-09 16:00:00-06'),
    (15, 13, 'Botas de trabajo con casquillo',       'Botas de trabajo con casquillo de acero y suela antiderrapante',         '2026-04-10 08:00:00-06'),
    (16, 14, 'Sandalias de playa',                   'Sandalias de caucho con plantilla texturizada',                          '2026-04-11 09:00:00-06'),
    (17, 15, 'Sandalias de bano',                    'Sandalias livianas de espuma para interiores',                           '2026-04-12 10:00:00-06'),
    (18, 16, 'Tenis para correr',                    'Tenis de malla transpirable para correr en asfalto',                     '2026-04-13 11:00:00-06'),
    (19, 17, 'Tenis urbanos de lona',                'Tenis de lona con suela vulcanizada para uso diario',                    '2026-04-14 12:00:00-06'),
    (20, 18, 'Audifonos inalambricos de diadema',    'Audifonos de diadema con bluetooth y bateria de larga duracion',         '2026-04-15 13:00:00-06'),
    (21, 19, 'Audifonos con cable',                  'Audifonos de diadema con cable de 3.5 milimetros',                       '2026-04-16 14:00:00-06'),
    (22, 20, 'Audifonos deportivos',                 'Audifonos intrauriculares resistentes al sudor',                         '2026-04-17 15:00:00-06'),
    (23, 21, 'Telefono inteligente de 6.1 pulgadas', 'Telefono inteligente de gama media con camara de 48 megapixeles',        '2026-04-18 16:00:00-06'),
    (24, 22, 'Telefono basico',                      'Telefono de teclas con bateria de larga duracion',                       '2026-04-19 08:00:00-06'),
    (25, 23, 'Telefono inteligente de 6.7 pulgadas', 'Telefono inteligente de pantalla grande y bateria de 5000 miliamperios', '2026-04-20 09:00:00-06'),
    (26, 24, 'Monitor de 24 pulgadas',               'Monitor de 24 pulgadas con panel IPS para oficina',                      '2026-04-21 10:00:00-06'),
    (27, 25, 'Monitor de 27 pulgadas para juegos',   'Monitor de 27 pulgadas a 144 hercios',                                   '2026-04-22 11:00:00-06'),
    (28, 26, 'Laptop de 15 pulgadas',                'Laptop de 15.6 pulgadas para trabajo diario',                            '2026-04-23 12:00:00-06'),
    (29, 27, 'Laptop empresarial de 14 pulgadas',    'Laptop empresarial con teclado retroiluminado y lector de huella',       '2026-04-24 13:00:00-06'),
    (30, 28, 'Laptop ligera para estudio',           'Laptop de 13.3 pulgadas y 1.2 kilogramos',                               '2026-04-25 14:00:00-06'),
    (31, 29, 'Teclado mecanico',                     'Teclado mecanico con distribucion en espanol latinoamericano',           '2026-04-26 15:00:00-06'),
    (32, 30, 'Mouse inalambrico',                    'Mouse optico con receptor USB',                                          '2026-04-27 16:00:00-06'),
    (33, 31, 'Base enfriadora para laptop',          'Base de aluminio con dos ventiladores',                                  '2026-04-28 08:00:00-06'),
    (34, 32, 'Lampara de escritorio inteligente',    'Lampara de escritorio que se controla desde el telefono',                '2026-04-29 09:00:00-06'),
    (35, 33, 'Lampara de pie',                       'Lampara de pie con interruptor de pedal',                                '2026-04-30 10:00:00-06'),
    (36, 34, 'Tira de luz LED',                      'Tira de luz LED con control remoto y cambio de color',                   '2026-05-01 11:00:00-06'),
    (37, 35, 'Juego de moldes para reposteria',      'Juego de seis moldes de acero antiadherente',                            '2026-05-02 12:00:00-06'),
    (38, 36, 'Batidora de mano',                     'Batidora de mano de cinco velocidades',                                  '2026-05-03 13:00:00-06'),
    (39, 37, 'Juego de tazones de mezcla',           'Tres tazones de vidrio templado apilables',                              '2026-05-04 14:00:00-06'),
    (40, 38, 'Licuadora de vaso de vidrio',          'Licuadora de tres velocidades con vaso de vidrio',                       '2026-05-05 15:00:00-06'),
    (41, 39, 'Horno tostador',                       'Horno tostador de 20 litros con temporizador',                           '2026-05-06 16:00:00-06'),
    (42, 40, 'Freidora de aire',                     'Freidora de aire con canasta antiadherente',                             '2026-05-07 08:00:00-06'),
    (43, 41, 'Mancuerna de disco ajustable',         'Mancuerna con discos intercambiables para entrenar en casa',             '2026-05-08 09:00:00-06'),
    (44, 42, 'Banda elastica de resistencia',        'Banda de latex de dos metros para ejercicio',                            '2026-05-09 10:00:00-06'),
    (45, 43, 'Tapete de yoga',                       'Tapete de seis milimetros con superficie antiderrapante',                '2026-05-10 11:00:00-06'),
    (46, 44, 'Bicicleta urbana',                     'Bicicleta urbana de aluminio con siete velocidades',                     '2026-05-11 12:00:00-06'),
    (47, 45, 'Casco para ciclista',                  'Casco de policarbonato con 18 ventilas',                                 '2026-05-12 13:00:00-06'),
    (48, 46, 'Luz trasera recargable',               'Luz trasera de 60 lumenes con carga por USB',                            '2026-05-13 14:00:00-06'),
    (49, 47, 'Balon de futbol numero 5',             'Balon de poliuretano numero 5 para cancha de pasto',                     '2026-05-14 15:00:00-06'),
    (50, 48, 'Bases de datos, teoria y practica',    'Libro de texto de bases de datos relacionales y no relacionales',        '2026-05-15 16:00:00-06'),
    (51, 49, 'Calculo de una variable',              'Libro de texto de calculo diferencial e integral',                       '2026-05-16 08:00:00-06'),
    (52, 50, 'El camino de las nubes',               'Novela sobre un viaje por el altiplano',                                 '2026-05-17 09:00:00-06')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Variantes
-- ------------------------------------------------------------
-- De una a tres por producto. Las caracteristicas de la variante son las que
-- la separan de sus hermanas: la talla, la capacidad, el color. Lo que
-- comparten todas se queda arriba, en el producto.
--
-- La fecha es la misma del producto, la misma en las cuatro filas.

INSERT INTO productos_variantes (id_producto_variante, id_producto, nombre_variante, precio, fecha_creacion, id_estado_variantes, descripcion)
SELECT
    v.id_producto_variante, v.id_producto, v.nombre_variante, v.precio, v.fecha_creacion,
    (SELECT id_estado_variante FROM estado_variantes WHERE estado_variante_nombre = 'activa'),
    v.descripcion
FROM (VALUES
    (6::bigint, 4::bigint, 'S blanca', 189.00::numeric, '2026-04-01 08:00:00-06'::timestamptz, 'Talla S, color blanco'),
    (7, 4, 'M blanca', 189.00, '2026-04-01 08:00:00-06', 'Talla M, color blanco'),
    (8, 4, 'L celeste', 199.00, '2026-04-01 08:00:00-06', 'Talla L, color celeste'),
    (9, 5, 'Unitalla multicolor', 145.00, '2026-04-02 09:00:00-06', 'Talla unica, estampado irrepetible'),
    (10, 6, 'M celeste', 175.00, '2026-04-03 10:00:00-06', 'Talla M, color celeste'),
    (11, 6, 'L celeste', 175.00, '2026-04-03 10:00:00-06', 'Talla L, color celeste'),
    (12, 7, '30 azul', 259.00, '2026-04-04 11:00:00-06', 'Cintura 30, azul indigo'),
    (13, 7, '32 azul', 259.00, '2026-04-04 11:00:00-06', 'Cintura 32, azul indigo'),
    (14, 7, '34 negro', 269.00, '2026-04-04 11:00:00-06', 'Cintura 34, negro'),
    (15, 8, '32 claro', 279.00, '2026-04-05 12:00:00-06', 'Cintura 32, azul claro'),
    (16, 8, '34 claro', 279.00, '2026-04-05 12:00:00-06', 'Cintura 34, azul claro'),
    (17, 9, '32 gris', 320.00, '2026-04-06 13:00:00-06', 'Cintura 32, gris oxford'),
    (18, 9, '34 gris', 320.00, '2026-04-06 13:00:00-06', 'Cintura 34, gris oxford'),
    (19, 10, 'S gris', 349.00, '2026-04-07 14:00:00-06', 'Talla S, gris jaspeado'),
    (20, 10, 'M gris', 349.00, '2026-04-07 14:00:00-06', 'Talla M, gris jaspeado'),
    (21, 10, 'L gris', 359.00, '2026-04-07 14:00:00-06', 'Talla L, gris jaspeado'),
    (22, 11, 'M vino', 299.00, '2026-04-08 15:00:00-06', 'Talla M, color vino'),
    (23, 11, 'L vino', 299.00, '2026-04-08 15:00:00-06', 'Talla L, color vino'),
    (24, 12, '40 cafe', 780.00, '2026-04-09 16:00:00-06', 'Numero 40, cafe'),
    (25, 12, '42 cafe', 780.00, '2026-04-09 16:00:00-06', 'Numero 42, cafe'),
    (26, 12, '43 negro', 799.00, '2026-04-09 16:00:00-06', 'Numero 43, negro'),
    (27, 13, '41 cafe', 890.00, '2026-04-10 08:00:00-06', 'Numero 41, cafe oscuro'),
    (28, 13, '43 cafe', 890.00, '2026-04-10 08:00:00-06', 'Numero 43, cafe oscuro'),
    (29, 14, '38 azul', 89.00, '2026-04-11 09:00:00-06', 'Numero 38, azul'),
    (30, 14, '40 azul', 89.00, '2026-04-11 09:00:00-06', 'Numero 40, azul'),
    (31, 14, '42 negro', 95.00, '2026-04-11 09:00:00-06', 'Numero 42, negro'),
    (32, 15, '39 blanco', 65.00, '2026-04-12 10:00:00-06', 'Numero 39, blanco'),
    (33, 15, '41 blanco', 65.00, '2026-04-12 10:00:00-06', 'Numero 41, blanco'),
    (34, 16, '40 negro', 650.00, '2026-04-13 11:00:00-06', 'Numero 40, negro'),
    (35, 16, '42 negro', 650.00, '2026-04-13 11:00:00-06', 'Numero 42, negro'),
    (36, 16, '43 blanco', 665.00, '2026-04-13 11:00:00-06', 'Numero 43, blanco'),
    (37, 17, '40 beige', 380.00, '2026-04-14 12:00:00-06', 'Numero 40, beige'),
    (38, 17, '42 beige', 380.00, '2026-04-14 12:00:00-06', 'Numero 42, beige'),
    (39, 18, 'Negro', 599.00, '2026-04-15 13:00:00-06', 'Color negro, estuche blando incluido'),
    (40, 18, 'Azul', 599.00, '2026-04-15 13:00:00-06', 'Color azul, estuche blando incluido'),
    (41, 19, 'Estandar', 249.00, '2026-04-16 14:00:00-06', 'Color negro, cable de 1.2 metros'),
    (42, 20, 'Negro', 429.00, '2026-04-17 15:00:00-06', 'Color negro con gancho de oreja'),
    (43, 20, 'Verde', 429.00, '2026-04-17 15:00:00-06', 'Color verde con gancho de oreja'),
    (44, 21, '128 GB', 3899.00, '2026-04-18 16:00:00-06', '128 GB de almacenamiento, 6 GB de RAM'),
    (45, 21, '256 GB', 4399.00, '2026-04-18 16:00:00-06', '256 GB de almacenamiento, 8 GB de RAM'),
    (46, 22, 'Unico', 299.00, '2026-04-19 08:00:00-06', 'Version unica, doble tarjeta SIM'),
    (47, 23, '256 GB', 5299.00, '2026-04-20 09:00:00-06', '256 GB de almacenamiento, 8 GB de RAM'),
    (48, 23, '512 GB', 5999.00, '2026-04-20 09:00:00-06', '512 GB de almacenamiento, 12 GB de RAM'),
    (49, 24, 'Con base', 1290.00, '2026-04-21 10:00:00-06', 'Incluye base de escritorio'),
    (50, 24, 'Solo VESA', 1250.00, '2026-04-21 10:00:00-06', 'Sin base, montaje VESA de 100 milimetros'),
    (51, 25, 'Plano', 2590.00, '2026-04-22 11:00:00-06', 'Pantalla plana, panel IPS'),
    (52, 25, 'Curvo', 2890.00, '2026-04-22 11:00:00-06', 'Pantalla curva de 1500R, panel VA'),
    (53, 26, '8 GB RAM', 4599.00, '2026-04-23 12:00:00-06', '8 GB de RAM, 512 GB SSD'),
    (54, 26, '16 GB RAM', 5299.00, '2026-04-23 12:00:00-06', '16 GB de RAM, 1 TB SSD'),
    (55, 27, '16 GB RAM', 7499.00, '2026-04-24 13:00:00-06', '16 GB de RAM, 1 TB SSD'),
    (56, 27, '32 GB RAM', 8999.00, '2026-04-24 13:00:00-06', '32 GB de RAM, 2 TB SSD'),
    (57, 28, '8 GB RAM', 3499.00, '2026-04-25 14:00:00-06', '8 GB de RAM, 256 GB SSD'),
    (58, 29, 'Sin teclado numerico', 690.00, '2026-04-26 15:00:00-06', 'Formato compacto sin teclado numerico'),
    (59, 29, 'Completo', 790.00, '2026-04-26 15:00:00-06', 'Formato completo con teclado numerico'),
    (60, 30, 'Negro', 210.00, '2026-04-27 16:00:00-06', 'Color negro, funciona con una pila AA'),
    (61, 31, 'Estandar', 320.00, '2026-04-28 08:00:00-06', 'Altura de cinco posiciones'),
    (62, 32, 'Blanca', 850.00, '2026-04-29 09:00:00-06', 'Cuerpo blanco'),
    (63, 32, 'Negra', 850.00, '2026-04-29 09:00:00-06', 'Cuerpo negro'),
    (64, 33, 'Estandar', 620.00, '2026-04-30 10:00:00-06', 'Altura de 1.6 metros'),
    (65, 34, '3 metros', 180.00, '2026-05-01 11:00:00-06', 'Rollo de 3 metros'),
    (66, 34, '5 metros', 260.00, '2026-05-01 11:00:00-06', 'Rollo de 5 metros'),
    (67, 35, 'Estandar', 275.00, '2026-05-02 12:00:00-06', 'Seis moldes de distinto diametro'),
    (68, 36, 'Blanca', 420.00, '2026-05-03 13:00:00-06', 'Color blanco'),
    (69, 36, 'Roja', 420.00, '2026-05-03 13:00:00-06', 'Color rojo'),
    (70, 37, 'Estandar', 199.00, '2026-05-04 14:00:00-06', 'Tazones de 1, 2 y 3 litros'),
    (71, 38, '1.5 litros', 549.00, '2026-05-05 15:00:00-06', 'Vaso de 1.5 litros'),
    (72, 38, '2 litros', 649.00, '2026-05-05 15:00:00-06', 'Vaso de 2 litros'),
    (73, 39, 'Estandar', 899.00, '2026-05-06 16:00:00-06', 'Incluye bandeja y rejilla'),
    (74, 40, '4 litros', 1150.00, '2026-05-07 08:00:00-06', 'Canasta de 4 litros'),
    (75, 40, '6 litros', 1390.00, '2026-05-07 08:00:00-06', 'Canasta de 6 litros'),
    (76, 41, '5 kg', 180.00, '2026-05-08 09:00:00-06', 'Una mancuerna de 5 kilogramos'),
    (77, 41, '10 kg', 320.00, '2026-05-08 09:00:00-06', 'Una mancuerna de 10 kilogramos'),
    (78, 42, 'Ligera', 75.00, '2026-05-09 10:00:00-06', 'Resistencia ligera, color verde'),
    (79, 42, 'Media', 85.00, '2026-05-09 10:00:00-06', 'Resistencia media, color azul'),
    (80, 42, 'Fuerte', 95.00, '2026-05-09 10:00:00-06', 'Resistencia fuerte, color negro'),
    (81, 43, 'Morado', 260.00, '2026-05-10 11:00:00-06', 'Color morado, incluye correa'),
    (82, 44, 'Cuadro M', 4200.00, '2026-05-11 12:00:00-06', 'Cuadro talla M, color negro'),
    (83, 44, 'Cuadro L', 4200.00, '2026-05-11 12:00:00-06', 'Cuadro talla L, color negro'),
    (84, 45, 'M blanco', 480.00, '2026-05-12 13:00:00-06', 'Talla M, color blanco'),
    (85, 45, 'L blanco', 480.00, '2026-05-12 13:00:00-06', 'Talla L, color blanco'),
    (86, 46, 'Estandar', 150.00, '2026-05-13 14:00:00-06', 'Sujecion de silicon al poste del asiento'),
    (87, 47, 'Estandar', 320.00, '2026-05-14 15:00:00-06', 'Cosido a maquina, camara de butilo'),
    (88, 48, 'Pasta blanda', 480.00, '2026-05-15 16:00:00-06', 'Tercera edicion, pasta blanda'),
    (89, 48, 'Pasta dura', 690.00, '2026-05-15 16:00:00-06', 'Tercera edicion, pasta dura'),
    (90, 49, 'Pasta blanda', 520.00, '2026-05-16 08:00:00-06', 'Segunda edicion, pasta blanda'),
    (91, 50, 'Pasta blanda', 145.00, '2026-05-17 09:00:00-06', 'Edicion en pasta blanda'),
    (92, 50, 'Bolsillo', 99.00, '2026-05-17 09:00:00-06', 'Edicion de bolsillo')
) AS v (id_producto_variante, id_producto, nombre_variante, precio, fecha_creacion, descripcion)
ON CONFLICT DO NOTHING;

-- Una fila por variante, aunque no tenga modificaciones. Hace falta: el ETL
-- arma el arreglo de variantes de cada evento leyendo este historial y no la
-- fila viva, asi que una variante sin historial no aparece en el documento y
-- nada avisa.

INSERT INTO productos_variantes_historial (id_producto_variante_historial, id_producto_variante, nombre_variante, precio, descripcion, fecha_creacion) VALUES
    (9, 6, 'S blanca',              189.00, 'Talla S, color blanco',                    '2026-04-01 08:00:00-06'),
    (10, 7, 'M blanca',              189.00, 'Talla M, color blanco',                    '2026-04-01 08:00:00-06'),
    (11, 8, 'L celeste',             199.00, 'Talla L, color celeste',                   '2026-04-01 08:00:00-06'),
    (12, 9, 'Unitalla multicolor',   145.00, 'Talla unica, estampado irrepetible',       '2026-04-02 09:00:00-06'),
    (13, 10, 'M celeste',             175.00, 'Talla M, color celeste',                   '2026-04-03 10:00:00-06'),
    (14, 11, 'L celeste',             175.00, 'Talla L, color celeste',                   '2026-04-03 10:00:00-06'),
    (15, 12, '30 azul',               259.00, 'Cintura 30, azul indigo',                  '2026-04-04 11:00:00-06'),
    (16, 13, '32 azul',               259.00, 'Cintura 32, azul indigo',                  '2026-04-04 11:00:00-06'),
    (17, 14, '34 negro',              269.00, 'Cintura 34, negro',                        '2026-04-04 11:00:00-06'),
    (18, 15, '32 claro',              279.00, 'Cintura 32, azul claro',                   '2026-04-05 12:00:00-06'),
    (19, 16, '34 claro',              279.00, 'Cintura 34, azul claro',                   '2026-04-05 12:00:00-06'),
    (20, 17, '32 gris',               320.00, 'Cintura 32, gris oxford',                  '2026-04-06 13:00:00-06'),
    (21, 18, '34 gris',               320.00, 'Cintura 34, gris oxford',                  '2026-04-06 13:00:00-06'),
    (22, 19, 'S gris',                349.00, 'Talla S, gris jaspeado',                   '2026-04-07 14:00:00-06'),
    (23, 20, 'M gris',                349.00, 'Talla M, gris jaspeado',                   '2026-04-07 14:00:00-06'),
    (24, 21, 'L gris',                359.00, 'Talla L, gris jaspeado',                   '2026-04-07 14:00:00-06'),
    (25, 22, 'M vino',                299.00, 'Talla M, color vino',                      '2026-04-08 15:00:00-06'),
    (26, 23, 'L vino',                299.00, 'Talla L, color vino',                      '2026-04-08 15:00:00-06'),
    (27, 24, '40 cafe',               780.00, 'Numero 40, cafe',                          '2026-04-09 16:00:00-06'),
    (28, 25, '42 cafe',               780.00, 'Numero 42, cafe',                          '2026-04-09 16:00:00-06'),
    (29, 26, '43 negro',              799.00, 'Numero 43, negro',                         '2026-04-09 16:00:00-06'),
    (30, 27, '41 cafe',               890.00, 'Numero 41, cafe oscuro',                   '2026-04-10 08:00:00-06'),
    (31, 28, '43 cafe',               890.00, 'Numero 43, cafe oscuro',                   '2026-04-10 08:00:00-06'),
    (32, 29, '38 azul',                89.00, 'Numero 38, azul',                          '2026-04-11 09:00:00-06'),
    (33, 30, '40 azul',                89.00, 'Numero 40, azul',                          '2026-04-11 09:00:00-06'),
    (34, 31, '42 negro',               95.00, 'Numero 42, negro',                         '2026-04-11 09:00:00-06'),
    (35, 32, '39 blanco',              65.00, 'Numero 39, blanco',                        '2026-04-12 10:00:00-06'),
    (36, 33, '41 blanco',              65.00, 'Numero 41, blanco',                        '2026-04-12 10:00:00-06'),
    (37, 34, '40 negro',              650.00, 'Numero 40, negro',                         '2026-04-13 11:00:00-06'),
    (38, 35, '42 negro',              650.00, 'Numero 42, negro',                         '2026-04-13 11:00:00-06'),
    (39, 36, '43 blanco',             665.00, 'Numero 43, blanco',                        '2026-04-13 11:00:00-06'),
    (40, 37, '40 beige',              380.00, 'Numero 40, beige',                         '2026-04-14 12:00:00-06'),
    (41, 38, '42 beige',              380.00, 'Numero 42, beige',                         '2026-04-14 12:00:00-06'),
    (42, 39, 'Negro',                 599.00, 'Color negro, estuche blando incluido',     '2026-04-15 13:00:00-06'),
    (43, 40, 'Azul',                  599.00, 'Color azul, estuche blando incluido',      '2026-04-15 13:00:00-06'),
    (44, 41, 'Estandar',              249.00, 'Color negro, cable de 1.2 metros',         '2026-04-16 14:00:00-06'),
    (45, 42, 'Negro',                 429.00, 'Color negro con gancho de oreja',          '2026-04-17 15:00:00-06'),
    (46, 43, 'Verde',                 429.00, 'Color verde con gancho de oreja',          '2026-04-17 15:00:00-06'),
    (47, 44, '128 GB',               3899.00, '128 GB de almacenamiento, 6 GB de RAM',    '2026-04-18 16:00:00-06'),
    (48, 45, '256 GB',               4399.00, '256 GB de almacenamiento, 8 GB de RAM',    '2026-04-18 16:00:00-06'),
    (49, 46, 'Unico',                 299.00, 'Version unica, doble tarjeta SIM',         '2026-04-19 08:00:00-06'),
    (50, 47, '256 GB',               5299.00, '256 GB de almacenamiento, 8 GB de RAM',    '2026-04-20 09:00:00-06'),
    (51, 48, '512 GB',               5999.00, '512 GB de almacenamiento, 12 GB de RAM',   '2026-04-20 09:00:00-06'),
    (52, 49, 'Con base',             1290.00, 'Incluye base de escritorio',               '2026-04-21 10:00:00-06'),
    (53, 50, 'Solo VESA',            1250.00, 'Sin base, montaje VESA de 100 milimetros', '2026-04-21 10:00:00-06'),
    (54, 51, 'Plano',                2590.00, 'Pantalla plana, panel IPS',                '2026-04-22 11:00:00-06'),
    (55, 52, 'Curvo',                2890.00, 'Pantalla curva de 1500R, panel VA',        '2026-04-22 11:00:00-06'),
    (56, 53, '8 GB RAM',             4599.00, '8 GB de RAM, 512 GB SSD',                  '2026-04-23 12:00:00-06'),
    (57, 54, '16 GB RAM',            5299.00, '16 GB de RAM, 1 TB SSD',                   '2026-04-23 12:00:00-06'),
    (58, 55, '16 GB RAM',            7499.00, '16 GB de RAM, 1 TB SSD',                   '2026-04-24 13:00:00-06'),
    (59, 56, '32 GB RAM',            8999.00, '32 GB de RAM, 2 TB SSD',                   '2026-04-24 13:00:00-06'),
    (60, 57, '8 GB RAM',             3499.00, '8 GB de RAM, 256 GB SSD',                  '2026-04-25 14:00:00-06'),
    (61, 58, 'Sin teclado numerico',  690.00, 'Formato compacto sin teclado numerico',    '2026-04-26 15:00:00-06'),
    (62, 59, 'Completo',              790.00, 'Formato completo con teclado numerico',    '2026-04-26 15:00:00-06'),
    (63, 60, 'Negro',                 210.00, 'Color negro, funciona con una pila AA',    '2026-04-27 16:00:00-06'),
    (64, 61, 'Estandar',              320.00, 'Altura de cinco posiciones',               '2026-04-28 08:00:00-06'),
    (65, 62, 'Blanca',                850.00, 'Cuerpo blanco',                            '2026-04-29 09:00:00-06'),
    (66, 63, 'Negra',                 850.00, 'Cuerpo negro',                             '2026-04-29 09:00:00-06'),
    (67, 64, 'Estandar',              620.00, 'Altura de 1.6 metros',                     '2026-04-30 10:00:00-06'),
    (68, 65, '3 metros',              180.00, 'Rollo de 3 metros',                        '2026-05-01 11:00:00-06'),
    (69, 66, '5 metros',              260.00, 'Rollo de 5 metros',                        '2026-05-01 11:00:00-06'),
    (70, 67, 'Estandar',              275.00, 'Seis moldes de distinto diametro',         '2026-05-02 12:00:00-06'),
    (71, 68, 'Blanca',                420.00, 'Color blanco',                             '2026-05-03 13:00:00-06'),
    (72, 69, 'Roja',                  420.00, 'Color rojo',                               '2026-05-03 13:00:00-06'),
    (73, 70, 'Estandar',              199.00, 'Tazones de 1, 2 y 3 litros',               '2026-05-04 14:00:00-06'),
    (74, 71, '1.5 litros',            549.00, 'Vaso de 1.5 litros',                       '2026-05-05 15:00:00-06'),
    (75, 72, '2 litros',              649.00, 'Vaso de 2 litros',                         '2026-05-05 15:00:00-06'),
    (76, 73, 'Estandar',              899.00, 'Incluye bandeja y rejilla',                '2026-05-06 16:00:00-06'),
    (77, 74, '4 litros',             1150.00, 'Canasta de 4 litros',                      '2026-05-07 08:00:00-06'),
    (78, 75, '6 litros',             1390.00, 'Canasta de 6 litros',                      '2026-05-07 08:00:00-06'),
    (79, 76, '5 kg',                  180.00, 'Una mancuerna de 5 kilogramos',            '2026-05-08 09:00:00-06'),
    (80, 77, '10 kg',                 320.00, 'Una mancuerna de 10 kilogramos',           '2026-05-08 09:00:00-06'),
    (81, 78, 'Ligera',                 75.00, 'Resistencia ligera, color verde',          '2026-05-09 10:00:00-06'),
    (82, 79, 'Media',                  85.00, 'Resistencia media, color azul',            '2026-05-09 10:00:00-06'),
    (83, 80, 'Fuerte',                 95.00, 'Resistencia fuerte, color negro',          '2026-05-09 10:00:00-06'),
    (84, 81, 'Morado',                260.00, 'Color morado, incluye correa',             '2026-05-10 11:00:00-06'),
    (85, 82, 'Cuadro M',             4200.00, 'Cuadro talla M, color negro',              '2026-05-11 12:00:00-06'),
    (86, 83, 'Cuadro L',             4200.00, 'Cuadro talla L, color negro',              '2026-05-11 12:00:00-06'),
    (87, 84, 'M blanco',              480.00, 'Talla M, color blanco',                    '2026-05-12 13:00:00-06'),
    (88, 85, 'L blanco',              480.00, 'Talla L, color blanco',                    '2026-05-12 13:00:00-06'),
    (89, 86, 'Estandar',              150.00, 'Sujecion de silicon al poste del asiento', '2026-05-13 14:00:00-06'),
    (90, 87, 'Estandar',              320.00, 'Cosido a maquina, camara de butilo',       '2026-05-14 15:00:00-06'),
    (91, 88, 'Pasta blanda',          480.00, 'Tercera edicion, pasta blanda',            '2026-05-15 16:00:00-06'),
    (92, 89, 'Pasta dura',            690.00, 'Tercera edicion, pasta dura',              '2026-05-15 16:00:00-06'),
    (93, 90, 'Pasta blanda',          520.00, 'Segunda edicion, pasta blanda',            '2026-05-16 08:00:00-06'),
    (94, 91, 'Pasta blanda',          145.00, 'Edicion en pasta blanda',                  '2026-05-17 09:00:00-06'),
    (95, 92, 'Bolsillo',               99.00, 'Edicion de bolsillo',                      '2026-05-17 09:00:00-06')
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Imagenes
-- ------------------------------------------------------------
-- Diecinueve URL comprobadas para cuarenta y siete productos: la misma foto
-- se reparte entre varios. Eso es lo que permite la tabla de union, y de paso
-- se ejercita el caso que una columna de URL dentro de la variante no
-- soportaria.
--
-- Solo se insertan dieciseis. Tres de las diecinueve ya estan en
-- datos/001_catalogo_base.sql con los id 3, 4 y 7, y la URL es UNIQUE: si se
-- volvieran a insertar con otro id, el ON CONFLICT las descartaria
-- en silencio y la tabla de union quedaria apuntando a un id que no existe.
-- Por eso esas tres se referencian por su id original.

INSERT INTO imagen_producto (id_imagen_producto, imagen_producto_url) VALUES
    (10, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/00/Simple_sweater_dress_with_with_turtleneck_-_pose_1.jpg/960px-Simple_sweater_dress_with_with_turtleneck_-_pose_1.jpg'),
    (11, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/1-2-3-4_Cake_cooking_implements.JPG/960px-1-2-3-4_Cake_cooking_implements.JPG'),
    (12, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/Jeans_Jeans_Jeans.jpg/960px-Jeans_Jeans_Jeans.jpg'),
    (13, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/Sony_WH-CH510_Bluetooth_Over-Ear_Headphone.jpg/960px-Sony_WH-CH510_Bluetooth_Over-Ear_Headphone.jpg'),
    (14, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/02/TieDyeShirtMpegMan.jpg/960px-TieDyeShirtMpegMan.jpg'),
    (15, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Cycling_Amsterdam_03.jpg/960px-Cycling_Amsterdam_03.jpg'),
    (16, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/06/Dekala_Arches%E2%84%A2_Smart_Lamp.jpg/960px-Dekala_Arches%E2%84%A2_Smart_Lamp.jpg'),
    (17, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/Jeans_2009.jpg/960px-Jeans_2009.jpg'),
    (18, 'https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Attractive_man_lifting_dumbbell_weight_for_exercise_in_fitness_gym.jpg/960px-Attractive_man_lifting_dumbbell_weight_for_exercise_in_fitness_gym.jpg'),
    (19, 'https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg'),
    (20, 'https://upload.wikimedia.org/wikipedia/commons/thumb/2/2b/Stack_of_multicolored_books_on_a_table.jpg/960px-Stack_of_multicolored_books_on_a_table.jpg'),
    (21, 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png'),
    (22, 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/39/Altura_Estadio_Mushuc_Runa.jpg/960px-Altura_Estadio_Mushuc_Runa.jpg'),
    (23, 'https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Headphones_1.jpg/960px-Headphones_1.jpg'),
    (24, 'https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/Flip_flop.jpg/960px-Flip_flop.jpg'),
    (25, 'https://upload.wikimedia.org/wikipedia/commons/thumb/5/57/Smartphone_Use.jpg/960px-Smartphone_Use.jpg')
ON CONFLICT DO NOTHING;

-- Una imagen por producto, en la posicion 1 de todas sus variantes. La tabla
-- no lleva id escrito a mano: es la unica de este archivo que sigue numerando
-- con su secuencia, igual que en el conjunto base.

INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden) VALUES
    (3, 6, 1),
    (3, 7, 1),
    (3, 8, 1),
    (14, 9, 1),
    (3, 10, 1),
    (3, 11, 1),
    (12, 12, 1),
    (12, 13, 1),
    (12, 14, 1),
    (17, 15, 1),
    (17, 16, 1),
    (17, 17, 1),
    (17, 18, 1),
    (10, 19, 1),
    (10, 20, 1),
    (10, 21, 1),
    (10, 22, 1),
    (10, 23, 1),
    (19, 24, 1),
    (19, 25, 1),
    (19, 26, 1),
    (19, 27, 1),
    (19, 28, 1),
    (24, 29, 1),
    (24, 30, 1),
    (24, 31, 1),
    (24, 32, 1),
    (24, 33, 1),
    (18, 34, 1),
    (18, 35, 1),
    (18, 36, 1),
    (22, 37, 1),
    (22, 38, 1),
    (13, 39, 1),
    (13, 40, 1),
    (23, 41, 1),
    (13, 42, 1),
    (13, 43, 1),
    (25, 44, 1),
    (25, 45, 1),
    (25, 46, 1),
    (25, 47, 1),
    (25, 48, 1),
    (21, 49, 1),
    (21, 50, 1),
    (21, 51, 1),
    (21, 52, 1),
    (4, 53, 1),
    (4, 54, 1),
    (7, 55, 1),
    (7, 56, 1),
    (4, 57, 1),
    (7, 58, 1),
    (7, 59, 1),
    (7, 60, 1),
    (21, 61, 1),
    (16, 62, 1),
    (16, 63, 1),
    (16, 64, 1),
    (16, 65, 1),
    (16, 66, 1),
    (11, 67, 1),
    (11, 68, 1),
    (11, 69, 1),
    (11, 70, 1),
    (11, 71, 1),
    (11, 72, 1),
    (11, 73, 1),
    (11, 74, 1),
    (11, 75, 1),
    (18, 76, 1),
    (18, 77, 1),
    (18, 78, 1),
    (18, 79, 1),
    (18, 80, 1),
    (18, 81, 1),
    (15, 82, 1),
    (15, 83, 1),
    (15, 84, 1),
    (15, 85, 1),
    (15, 86, 1),
    (22, 87, 1),
    (20, 88, 1),
    (20, 89, 1),
    (20, 90, 1),
    (20, 91, 1),
    (20, 92, 1)
ON CONFLICT DO NOTHING;


-- ------------------------------------------------------------
-- Secuencias
-- ------------------------------------------------------------
-- Los id de arriba se escribieron a mano. Esto deja cada secuencia apuntando
-- al ultimo id usado, para que la aplicacion siga numerando desde ahi. Se
-- calcula con max(), asi que da igual cuantos conjuntos de datos se hayan
-- corrido antes: el ultimo archivo en correr deja el valor bueno.

SELECT setval(pg_get_serial_sequence('categorias',          'id_categoria'),         max(id_categoria))         FROM categorias;
SELECT setval(pg_get_serial_sequence('productos',           'id_producto'),          max(id_producto))          FROM productos;
SELECT setval(pg_get_serial_sequence('productos_variantes', 'id_producto_variante'), max(id_producto_variante)) FROM productos_variantes;
SELECT setval(pg_get_serial_sequence('imagen_producto',     'id_imagen_producto'),   max(id_imagen_producto))   FROM imagen_producto;
SELECT setval(pg_get_serial_sequence('categorias_historial',          'id_categoria_historial'),          max(id_categoria_historial))          FROM categorias_historial;
SELECT setval(pg_get_serial_sequence('productos_historial',           'id_producto_historial'),           max(id_producto_historial))           FROM productos_historial;
SELECT setval(pg_get_serial_sequence('productos_variantes_historial', 'id_producto_variante_historial'),  max(id_producto_variante_historial))  FROM productos_variantes_historial;
