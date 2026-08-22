-- datos/002_catalogo_ampliado.sql
-- El conjunto que amplia el catalogo: 47 productos mas, para llegar a 50.
--
-- Este archivo es dueno de los id 1001 a 2000 en todas las tablas con id
-- escrito a mano. Se escribio sin abrir datos/001_catalogo_base.sql y no lo
-- toca: por eso los bloques de id no se pisan y un conjunto nuevo es solo un
-- archivo nuevo con el bloque siguiente.
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
    (1001, 'Ropa de mujer',                8.00, '2026-03-10 09:00:00-06', 1),
    (1002, 'Vestidos',                     9.00, '2026-03-10 09:05:00-06', 1001),
    (1003, 'Pantalones',                   8.50, '2026-03-10 09:10:00-06', 2),
    (1004, 'Calzado',                      9.00, '2026-03-10 09:15:00-06', 1),
    (1005, 'Botas',                       10.00, '2026-03-10 09:20:00-06', 1004),
    (1006, 'Sandalias',                    9.50, '2026-03-10 09:25:00-06', 1004),
    (1007, 'Tenis',                       10.50, '2026-03-10 09:30:00-06', 1004),
    (1008, 'Audio',                        6.00, '2026-03-10 09:35:00-06', 4),
    (1009, 'Audifonos',                    6.50, '2026-03-10 09:40:00-06', 1008),
    (1010, 'Telefonia',                    5.50, '2026-03-10 09:45:00-06', 4),
    (1011, 'Telefonos',                    6.00, '2026-03-10 09:50:00-06', 1010),
    (1012, 'Monitores',                    6.50, '2026-03-10 09:55:00-06', 5),
    (1013, 'Accesorios de computadora',    7.00, '2026-03-10 10:00:00-06', 5),
    (1014, 'Iluminacion',                  7.00, '2026-03-10 10:05:00-06', 6),
    (1015, 'Electrodomesticos de cocina',  8.00, '2026-03-10 10:10:00-06', 7),
    (1016, 'Deportes',                     7.50, '2026-03-10 10:15:00-06', NULL),
    (1017, 'Fitness',                      8.00, '2026-03-10 10:20:00-06', 1016),
    (1018, 'Ciclismo',                     7.00, '2026-03-10 10:25:00-06', 1016),
    (1019, 'Libros',                       5.00, '2026-03-10 10:30:00-06', NULL),
    (1020, 'Libros de texto',              5.50, '2026-03-10 10:35:00-06', 1019)
ON CONFLICT DO NOTHING;

INSERT INTO categorias_historial (id_categoria_historial, id_categoria, nombre, porcentaje_comision, fecha_creacion) VALUES
    (1001, 1001, 'Ropa de mujer',                8.00, '2026-03-10 09:00:00-06'),
    (1002, 1002, 'Vestidos',                     9.00, '2026-03-10 09:05:00-06'),
    (1003, 1003, 'Pantalones',                   8.50, '2026-03-10 09:10:00-06'),
    (1004, 1004, 'Calzado',                      9.00, '2026-03-10 09:15:00-06'),
    (1005, 1005, 'Botas',                       10.00, '2026-03-10 09:20:00-06'),
    (1006, 1006, 'Sandalias',                    9.50, '2026-03-10 09:25:00-06'),
    (1007, 1007, 'Tenis',                       10.50, '2026-03-10 09:30:00-06'),
    (1008, 1008, 'Audio',                        6.00, '2026-03-10 09:35:00-06'),
    (1009, 1009, 'Audifonos',                    6.50, '2026-03-10 09:40:00-06'),
    (1010, 1010, 'Telefonia',                    5.50, '2026-03-10 09:45:00-06'),
    (1011, 1011, 'Telefonos',                    6.00, '2026-03-10 09:50:00-06'),
    (1012, 1012, 'Monitores',                    6.50, '2026-03-10 09:55:00-06'),
    (1013, 1013, 'Accesorios de computadora',    7.00, '2026-03-10 10:00:00-06'),
    (1014, 1014, 'Iluminacion',                  7.00, '2026-03-10 10:05:00-06'),
    (1015, 1015, 'Electrodomesticos de cocina',  8.00, '2026-03-10 10:10:00-06'),
    (1016, 1016, 'Deportes',                     7.50, '2026-03-10 10:15:00-06'),
    (1017, 1017, 'Fitness',                      8.00, '2026-03-10 10:20:00-06'),
    (1018, 1018, 'Ciclismo',                     7.00, '2026-03-10 10:25:00-06'),
    (1019, 1019, 'Libros',                       5.00, '2026-03-10 10:30:00-06'),
    (1020, 1020, 'Libros de texto',              5.50, '2026-03-10 10:35:00-06')
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
    (1001::bigint, 'Camisa oxford de algodon', 'Camisa oxford de corte slim con cuello button down', '2026-04-01 08:00:00-06'::timestamptz, 'vendedor.prueba@mesh.com', 3::bigint),
    (1002, 'Camisa tenida artesanal', 'Camisa de algodon tenida a mano, pieza unica', '2026-04-02 09:00:00-06', 'ventas.norte@mesh.com', 3),
    (1003, 'Camisa formal manga corta', 'Camisa formal de manga corta para clima calido', '2026-04-03 10:00:00-06', 'vendedor.prueba@mesh.com', 3),
    (1004, 'Jeans de corte recto', 'Pantalon de mezclilla de corte recto y tiro medio', '2026-04-04 11:00:00-06', 'ventas.norte@mesh.com', 1003),
    (1005, 'Jeans desgastado', 'Pantalon de mezclilla con lavado stone wash', '2026-04-05 12:00:00-06', 'vendedor.prueba@mesh.com', 1003),
    (1006, 'Pantalon de vestir', 'Pantalon de vestir sin pinzas, caida recta', '2026-04-06 13:00:00-06', 'ventas.norte@mesh.com', 1003),
    (1007, 'Vestido de punto cuello alto', 'Vestido de punto midi con cuello alto', '2026-04-07 14:00:00-06', 'vendedor.prueba@mesh.com', 1002),
    (1008, 'Vestido casual de invierno', 'Vestido corto de manga larga para diario', '2026-04-08 15:00:00-06', 'ventas.norte@mesh.com', 1002),
    (1009, 'Botas de cuero', 'Botas de cuero con suela de goma para uso diario', '2026-04-09 16:00:00-06', 'vendedor.prueba@mesh.com', 1005),
    (1010, 'Botas de trabajo con casquillo', 'Botas de trabajo con casquillo de acero y suela antiderrapante', '2026-04-10 08:00:00-06', 'ventas.norte@mesh.com', 1005),
    (1011, 'Sandalias de playa', 'Sandalias de caucho con plantilla texturizada', '2026-04-11 09:00:00-06', 'vendedor.prueba@mesh.com', 1006),
    (1012, 'Sandalias de bano', 'Sandalias livianas de espuma para interiores', '2026-04-12 10:00:00-06', 'ventas.norte@mesh.com', 1006),
    (1013, 'Tenis para correr', 'Tenis de malla transpirable para correr en asfalto', '2026-04-13 11:00:00-06', 'vendedor.prueba@mesh.com', 1007),
    (1014, 'Tenis urbanos de lona', 'Tenis de lona con suela vulcanizada para uso diario', '2026-04-14 12:00:00-06', 'ventas.norte@mesh.com', 1007),
    (1015, 'Audifonos inalambricos de diadema', 'Audifonos de diadema con bluetooth y bateria de larga duracion', '2026-04-15 13:00:00-06', 'vendedor.prueba@mesh.com', 1009),
    (1016, 'Audifonos con cable', 'Audifonos de diadema con cable de 3.5 milimetros', '2026-04-16 14:00:00-06', 'ventas.norte@mesh.com', 1009),
    (1017, 'Audifonos deportivos', 'Audifonos intrauriculares resistentes al sudor', '2026-04-17 15:00:00-06', 'vendedor.prueba@mesh.com', 1009),
    (1018, 'Telefono inteligente de 6.1 pulgadas', 'Telefono inteligente de gama media con camara de 48 megapixeles', '2026-04-18 16:00:00-06', 'ventas.norte@mesh.com', 1011),
    (1019, 'Telefono basico', 'Telefono de teclas con bateria de larga duracion', '2026-04-19 08:00:00-06', 'vendedor.prueba@mesh.com', 1011),
    (1020, 'Telefono inteligente de 6.7 pulgadas', 'Telefono inteligente de pantalla grande y bateria de 5000 miliamperios', '2026-04-20 09:00:00-06', 'ventas.norte@mesh.com', 1011),
    (1021, 'Monitor de 24 pulgadas', 'Monitor de 24 pulgadas con panel IPS para oficina', '2026-04-21 10:00:00-06', 'vendedor.prueba@mesh.com', 1012),
    (1022, 'Monitor de 27 pulgadas para juegos', 'Monitor de 27 pulgadas a 144 hercios', '2026-04-22 11:00:00-06', 'ventas.norte@mesh.com', 1012),
    (1023, 'Laptop de 15 pulgadas', 'Laptop de 15.6 pulgadas para trabajo diario', '2026-04-23 12:00:00-06', 'vendedor.prueba@mesh.com', 5),
    (1024, 'Laptop empresarial de 14 pulgadas', 'Laptop empresarial con teclado retroiluminado y lector de huella', '2026-04-24 13:00:00-06', 'ventas.norte@mesh.com', 5),
    (1025, 'Laptop ligera para estudio', 'Laptop de 13.3 pulgadas y 1.2 kilogramos', '2026-04-25 14:00:00-06', 'vendedor.prueba@mesh.com', 5),
    (1026, 'Teclado mecanico', 'Teclado mecanico con distribucion en espanol latinoamericano', '2026-04-26 15:00:00-06', 'ventas.norte@mesh.com', 1013),
    (1027, 'Mouse inalambrico', 'Mouse optico con receptor USB', '2026-04-27 16:00:00-06', 'vendedor.prueba@mesh.com', 1013),
    (1028, 'Base enfriadora para laptop', 'Base de aluminio con dos ventiladores', '2026-04-28 08:00:00-06', 'ventas.norte@mesh.com', 1013),
    (1029, 'Lampara de escritorio inteligente', 'Lampara de escritorio que se controla desde el telefono', '2026-04-29 09:00:00-06', 'vendedor.prueba@mesh.com', 1014),
    (1030, 'Lampara de pie', 'Lampara de pie con interruptor de pedal', '2026-04-30 10:00:00-06', 'ventas.norte@mesh.com', 1014),
    (1031, 'Tira de luz LED', 'Tira de luz LED con control remoto y cambio de color', '2026-05-01 11:00:00-06', 'vendedor.prueba@mesh.com', 1014),
    (1032, 'Juego de moldes para reposteria', 'Juego de seis moldes de acero antiadherente', '2026-05-02 12:00:00-06', 'ventas.norte@mesh.com', 7),
    (1033, 'Batidora de mano', 'Batidora de mano de cinco velocidades', '2026-05-03 13:00:00-06', 'vendedor.prueba@mesh.com', 7),
    (1034, 'Juego de tazones de mezcla', 'Tres tazones de vidrio templado apilables', '2026-05-04 14:00:00-06', 'ventas.norte@mesh.com', 7),
    (1035, 'Licuadora de vaso de vidrio', 'Licuadora de tres velocidades con vaso de vidrio', '2026-05-05 15:00:00-06', 'vendedor.prueba@mesh.com', 1015),
    (1036, 'Horno tostador', 'Horno tostador de 20 litros con temporizador', '2026-05-06 16:00:00-06', 'ventas.norte@mesh.com', 1015),
    (1037, 'Freidora de aire', 'Freidora de aire con canasta antiadherente', '2026-05-07 08:00:00-06', 'vendedor.prueba@mesh.com', 1015),
    (1038, 'Mancuerna de disco ajustable', 'Mancuerna con discos intercambiables para entrenar en casa', '2026-05-08 09:00:00-06', 'ventas.norte@mesh.com', 1017),
    (1039, 'Banda elastica de resistencia', 'Banda de latex de dos metros para ejercicio', '2026-05-09 10:00:00-06', 'vendedor.prueba@mesh.com', 1017),
    (1040, 'Tapete de yoga', 'Tapete de seis milimetros con superficie antiderrapante', '2026-05-10 11:00:00-06', 'ventas.norte@mesh.com', 1017),
    (1041, 'Bicicleta urbana', 'Bicicleta urbana de aluminio con siete velocidades', '2026-05-11 12:00:00-06', 'vendedor.prueba@mesh.com', 1018),
    (1042, 'Casco para ciclista', 'Casco de policarbonato con 18 ventilas', '2026-05-12 13:00:00-06', 'ventas.norte@mesh.com', 1018),
    (1043, 'Luz trasera recargable', 'Luz trasera de 60 lumenes con carga por USB', '2026-05-13 14:00:00-06', 'vendedor.prueba@mesh.com', 1018),
    (1044, 'Balon de futbol numero 5', 'Balon de poliuretano numero 5 para cancha de pasto', '2026-05-14 15:00:00-06', 'ventas.norte@mesh.com', 1016),
    (1045, 'Bases de datos, teoria y practica', 'Libro de texto de bases de datos relacionales y no relacionales', '2026-05-15 16:00:00-06', 'vendedor.prueba@mesh.com', 1020),
    (1046, 'Calculo de una variable', 'Libro de texto de calculo diferencial e integral', '2026-05-16 08:00:00-06', 'ventas.norte@mesh.com', 1020),
    (1047, 'El camino de las nubes', 'Novela sobre un viaje por el altiplano', '2026-05-17 09:00:00-06', 'vendedor.prueba@mesh.com', 1019)
) AS v (id_producto, nombre, descripcion, fecha_creacion, correo, id_categoria)
ON CONFLICT DO NOTHING;

-- Una sola fila por producto, con la misma fecha y el mismo texto que la fila
-- viva: asi el ETL escribe un evento de creacion y ninguna modificacion.

INSERT INTO productos_historial (id_producto_historial, id_producto, nombre, descripcion, fecha_creacion) VALUES
    (1001, 1001, 'Camisa oxford de algodon',             'Camisa oxford de corte slim con cuello button down',                     '2026-04-01 08:00:00-06'),
    (1002, 1002, 'Camisa tenida artesanal',              'Camisa de algodon tenida a mano, pieza unica',                           '2026-04-02 09:00:00-06'),
    (1003, 1003, 'Camisa formal manga corta',            'Camisa formal de manga corta para clima calido',                         '2026-04-03 10:00:00-06'),
    (1004, 1004, 'Jeans de corte recto',                 'Pantalon de mezclilla de corte recto y tiro medio',                      '2026-04-04 11:00:00-06'),
    (1005, 1005, 'Jeans desgastado',                     'Pantalon de mezclilla con lavado stone wash',                            '2026-04-05 12:00:00-06'),
    (1006, 1006, 'Pantalon de vestir',                   'Pantalon de vestir sin pinzas, caida recta',                             '2026-04-06 13:00:00-06'),
    (1007, 1007, 'Vestido de punto cuello alto',         'Vestido de punto midi con cuello alto',                                  '2026-04-07 14:00:00-06'),
    (1008, 1008, 'Vestido casual de invierno',           'Vestido corto de manga larga para diario',                               '2026-04-08 15:00:00-06'),
    (1009, 1009, 'Botas de cuero',                       'Botas de cuero con suela de goma para uso diario',                       '2026-04-09 16:00:00-06'),
    (1010, 1010, 'Botas de trabajo con casquillo',       'Botas de trabajo con casquillo de acero y suela antiderrapante',         '2026-04-10 08:00:00-06'),
    (1011, 1011, 'Sandalias de playa',                   'Sandalias de caucho con plantilla texturizada',                          '2026-04-11 09:00:00-06'),
    (1012, 1012, 'Sandalias de bano',                    'Sandalias livianas de espuma para interiores',                           '2026-04-12 10:00:00-06'),
    (1013, 1013, 'Tenis para correr',                    'Tenis de malla transpirable para correr en asfalto',                     '2026-04-13 11:00:00-06'),
    (1014, 1014, 'Tenis urbanos de lona',                'Tenis de lona con suela vulcanizada para uso diario',                    '2026-04-14 12:00:00-06'),
    (1015, 1015, 'Audifonos inalambricos de diadema',    'Audifonos de diadema con bluetooth y bateria de larga duracion',         '2026-04-15 13:00:00-06'),
    (1016, 1016, 'Audifonos con cable',                  'Audifonos de diadema con cable de 3.5 milimetros',                       '2026-04-16 14:00:00-06'),
    (1017, 1017, 'Audifonos deportivos',                 'Audifonos intrauriculares resistentes al sudor',                         '2026-04-17 15:00:00-06'),
    (1018, 1018, 'Telefono inteligente de 6.1 pulgadas', 'Telefono inteligente de gama media con camara de 48 megapixeles',        '2026-04-18 16:00:00-06'),
    (1019, 1019, 'Telefono basico',                      'Telefono de teclas con bateria de larga duracion',                       '2026-04-19 08:00:00-06'),
    (1020, 1020, 'Telefono inteligente de 6.7 pulgadas', 'Telefono inteligente de pantalla grande y bateria de 5000 miliamperios', '2026-04-20 09:00:00-06'),
    (1021, 1021, 'Monitor de 24 pulgadas',               'Monitor de 24 pulgadas con panel IPS para oficina',                      '2026-04-21 10:00:00-06'),
    (1022, 1022, 'Monitor de 27 pulgadas para juegos',   'Monitor de 27 pulgadas a 144 hercios',                                   '2026-04-22 11:00:00-06'),
    (1023, 1023, 'Laptop de 15 pulgadas',                'Laptop de 15.6 pulgadas para trabajo diario',                            '2026-04-23 12:00:00-06'),
    (1024, 1024, 'Laptop empresarial de 14 pulgadas',    'Laptop empresarial con teclado retroiluminado y lector de huella',       '2026-04-24 13:00:00-06'),
    (1025, 1025, 'Laptop ligera para estudio',           'Laptop de 13.3 pulgadas y 1.2 kilogramos',                               '2026-04-25 14:00:00-06'),
    (1026, 1026, 'Teclado mecanico',                     'Teclado mecanico con distribucion en espanol latinoamericano',           '2026-04-26 15:00:00-06'),
    (1027, 1027, 'Mouse inalambrico',                    'Mouse optico con receptor USB',                                          '2026-04-27 16:00:00-06'),
    (1028, 1028, 'Base enfriadora para laptop',          'Base de aluminio con dos ventiladores',                                  '2026-04-28 08:00:00-06'),
    (1029, 1029, 'Lampara de escritorio inteligente',    'Lampara de escritorio que se controla desde el telefono',                '2026-04-29 09:00:00-06'),
    (1030, 1030, 'Lampara de pie',                       'Lampara de pie con interruptor de pedal',                                '2026-04-30 10:00:00-06'),
    (1031, 1031, 'Tira de luz LED',                      'Tira de luz LED con control remoto y cambio de color',                   '2026-05-01 11:00:00-06'),
    (1032, 1032, 'Juego de moldes para reposteria',      'Juego de seis moldes de acero antiadherente',                            '2026-05-02 12:00:00-06'),
    (1033, 1033, 'Batidora de mano',                     'Batidora de mano de cinco velocidades',                                  '2026-05-03 13:00:00-06'),
    (1034, 1034, 'Juego de tazones de mezcla',           'Tres tazones de vidrio templado apilables',                              '2026-05-04 14:00:00-06'),
    (1035, 1035, 'Licuadora de vaso de vidrio',          'Licuadora de tres velocidades con vaso de vidrio',                       '2026-05-05 15:00:00-06'),
    (1036, 1036, 'Horno tostador',                       'Horno tostador de 20 litros con temporizador',                           '2026-05-06 16:00:00-06'),
    (1037, 1037, 'Freidora de aire',                     'Freidora de aire con canasta antiadherente',                             '2026-05-07 08:00:00-06'),
    (1038, 1038, 'Mancuerna de disco ajustable',         'Mancuerna con discos intercambiables para entrenar en casa',             '2026-05-08 09:00:00-06'),
    (1039, 1039, 'Banda elastica de resistencia',        'Banda de latex de dos metros para ejercicio',                            '2026-05-09 10:00:00-06'),
    (1040, 1040, 'Tapete de yoga',                       'Tapete de seis milimetros con superficie antiderrapante',                '2026-05-10 11:00:00-06'),
    (1041, 1041, 'Bicicleta urbana',                     'Bicicleta urbana de aluminio con siete velocidades',                     '2026-05-11 12:00:00-06'),
    (1042, 1042, 'Casco para ciclista',                  'Casco de policarbonato con 18 ventilas',                                 '2026-05-12 13:00:00-06'),
    (1043, 1043, 'Luz trasera recargable',               'Luz trasera de 60 lumenes con carga por USB',                            '2026-05-13 14:00:00-06'),
    (1044, 1044, 'Balon de futbol numero 5',             'Balon de poliuretano numero 5 para cancha de pasto',                     '2026-05-14 15:00:00-06'),
    (1045, 1045, 'Bases de datos, teoria y practica',    'Libro de texto de bases de datos relacionales y no relacionales',        '2026-05-15 16:00:00-06'),
    (1046, 1046, 'Calculo de una variable',              'Libro de texto de calculo diferencial e integral',                       '2026-05-16 08:00:00-06'),
    (1047, 1047, 'El camino de las nubes',               'Novela sobre un viaje por el altiplano',                                 '2026-05-17 09:00:00-06')
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
    (1001::bigint, 1001::bigint, 'S blanca', 189.00::numeric, '2026-04-01 08:00:00-06'::timestamptz, 'Talla S, color blanco'),
    (1002, 1001, 'M blanca', 189.00, '2026-04-01 08:00:00-06', 'Talla M, color blanco'),
    (1003, 1001, 'L celeste', 199.00, '2026-04-01 08:00:00-06', 'Talla L, color celeste'),
    (1004, 1002, 'Unitalla multicolor', 145.00, '2026-04-02 09:00:00-06', 'Talla unica, estampado irrepetible'),
    (1005, 1003, 'M celeste', 175.00, '2026-04-03 10:00:00-06', 'Talla M, color celeste'),
    (1006, 1003, 'L celeste', 175.00, '2026-04-03 10:00:00-06', 'Talla L, color celeste'),
    (1007, 1004, '30 azul', 259.00, '2026-04-04 11:00:00-06', 'Cintura 30, azul indigo'),
    (1008, 1004, '32 azul', 259.00, '2026-04-04 11:00:00-06', 'Cintura 32, azul indigo'),
    (1009, 1004, '34 negro', 269.00, '2026-04-04 11:00:00-06', 'Cintura 34, negro'),
    (1010, 1005, '32 claro', 279.00, '2026-04-05 12:00:00-06', 'Cintura 32, azul claro'),
    (1011, 1005, '34 claro', 279.00, '2026-04-05 12:00:00-06', 'Cintura 34, azul claro'),
    (1012, 1006, '32 gris', 320.00, '2026-04-06 13:00:00-06', 'Cintura 32, gris oxford'),
    (1013, 1006, '34 gris', 320.00, '2026-04-06 13:00:00-06', 'Cintura 34, gris oxford'),
    (1014, 1007, 'S gris', 349.00, '2026-04-07 14:00:00-06', 'Talla S, gris jaspeado'),
    (1015, 1007, 'M gris', 349.00, '2026-04-07 14:00:00-06', 'Talla M, gris jaspeado'),
    (1016, 1007, 'L gris', 359.00, '2026-04-07 14:00:00-06', 'Talla L, gris jaspeado'),
    (1017, 1008, 'M vino', 299.00, '2026-04-08 15:00:00-06', 'Talla M, color vino'),
    (1018, 1008, 'L vino', 299.00, '2026-04-08 15:00:00-06', 'Talla L, color vino'),
    (1019, 1009, '40 cafe', 780.00, '2026-04-09 16:00:00-06', 'Numero 40, cafe'),
    (1020, 1009, '42 cafe', 780.00, '2026-04-09 16:00:00-06', 'Numero 42, cafe'),
    (1021, 1009, '43 negro', 799.00, '2026-04-09 16:00:00-06', 'Numero 43, negro'),
    (1022, 1010, '41 cafe', 890.00, '2026-04-10 08:00:00-06', 'Numero 41, cafe oscuro'),
    (1023, 1010, '43 cafe', 890.00, '2026-04-10 08:00:00-06', 'Numero 43, cafe oscuro'),
    (1024, 1011, '38 azul', 89.00, '2026-04-11 09:00:00-06', 'Numero 38, azul'),
    (1025, 1011, '40 azul', 89.00, '2026-04-11 09:00:00-06', 'Numero 40, azul'),
    (1026, 1011, '42 negro', 95.00, '2026-04-11 09:00:00-06', 'Numero 42, negro'),
    (1027, 1012, '39 blanco', 65.00, '2026-04-12 10:00:00-06', 'Numero 39, blanco'),
    (1028, 1012, '41 blanco', 65.00, '2026-04-12 10:00:00-06', 'Numero 41, blanco'),
    (1029, 1013, '40 negro', 650.00, '2026-04-13 11:00:00-06', 'Numero 40, negro'),
    (1030, 1013, '42 negro', 650.00, '2026-04-13 11:00:00-06', 'Numero 42, negro'),
    (1031, 1013, '43 blanco', 665.00, '2026-04-13 11:00:00-06', 'Numero 43, blanco'),
    (1032, 1014, '40 beige', 380.00, '2026-04-14 12:00:00-06', 'Numero 40, beige'),
    (1033, 1014, '42 beige', 380.00, '2026-04-14 12:00:00-06', 'Numero 42, beige'),
    (1034, 1015, 'Negro', 599.00, '2026-04-15 13:00:00-06', 'Color negro, estuche blando incluido'),
    (1035, 1015, 'Azul', 599.00, '2026-04-15 13:00:00-06', 'Color azul, estuche blando incluido'),
    (1036, 1016, 'Estandar', 249.00, '2026-04-16 14:00:00-06', 'Color negro, cable de 1.2 metros'),
    (1037, 1017, 'Negro', 429.00, '2026-04-17 15:00:00-06', 'Color negro con gancho de oreja'),
    (1038, 1017, 'Verde', 429.00, '2026-04-17 15:00:00-06', 'Color verde con gancho de oreja'),
    (1039, 1018, '128 GB', 3899.00, '2026-04-18 16:00:00-06', '128 GB de almacenamiento, 6 GB de RAM'),
    (1040, 1018, '256 GB', 4399.00, '2026-04-18 16:00:00-06', '256 GB de almacenamiento, 8 GB de RAM'),
    (1041, 1019, 'Unico', 299.00, '2026-04-19 08:00:00-06', 'Version unica, doble tarjeta SIM'),
    (1042, 1020, '256 GB', 5299.00, '2026-04-20 09:00:00-06', '256 GB de almacenamiento, 8 GB de RAM'),
    (1043, 1020, '512 GB', 5999.00, '2026-04-20 09:00:00-06', '512 GB de almacenamiento, 12 GB de RAM'),
    (1044, 1021, 'Con base', 1290.00, '2026-04-21 10:00:00-06', 'Incluye base de escritorio'),
    (1045, 1021, 'Solo VESA', 1250.00, '2026-04-21 10:00:00-06', 'Sin base, montaje VESA de 100 milimetros'),
    (1046, 1022, 'Plano', 2590.00, '2026-04-22 11:00:00-06', 'Pantalla plana, panel IPS'),
    (1047, 1022, 'Curvo', 2890.00, '2026-04-22 11:00:00-06', 'Pantalla curva de 1500R, panel VA'),
    (1048, 1023, '8 GB RAM', 4599.00, '2026-04-23 12:00:00-06', '8 GB de RAM, 512 GB SSD'),
    (1049, 1023, '16 GB RAM', 5299.00, '2026-04-23 12:00:00-06', '16 GB de RAM, 1 TB SSD'),
    (1050, 1024, '16 GB RAM', 7499.00, '2026-04-24 13:00:00-06', '16 GB de RAM, 1 TB SSD'),
    (1051, 1024, '32 GB RAM', 8999.00, '2026-04-24 13:00:00-06', '32 GB de RAM, 2 TB SSD'),
    (1052, 1025, '8 GB RAM', 3499.00, '2026-04-25 14:00:00-06', '8 GB de RAM, 256 GB SSD'),
    (1053, 1026, 'Sin teclado numerico', 690.00, '2026-04-26 15:00:00-06', 'Formato compacto sin teclado numerico'),
    (1054, 1026, 'Completo', 790.00, '2026-04-26 15:00:00-06', 'Formato completo con teclado numerico'),
    (1055, 1027, 'Negro', 210.00, '2026-04-27 16:00:00-06', 'Color negro, funciona con una pila AA'),
    (1056, 1028, 'Estandar', 320.00, '2026-04-28 08:00:00-06', 'Altura de cinco posiciones'),
    (1057, 1029, 'Blanca', 850.00, '2026-04-29 09:00:00-06', 'Cuerpo blanco'),
    (1058, 1029, 'Negra', 850.00, '2026-04-29 09:00:00-06', 'Cuerpo negro'),
    (1059, 1030, 'Estandar', 620.00, '2026-04-30 10:00:00-06', 'Altura de 1.6 metros'),
    (1060, 1031, '3 metros', 180.00, '2026-05-01 11:00:00-06', 'Rollo de 3 metros'),
    (1061, 1031, '5 metros', 260.00, '2026-05-01 11:00:00-06', 'Rollo de 5 metros'),
    (1062, 1032, 'Estandar', 275.00, '2026-05-02 12:00:00-06', 'Seis moldes de distinto diametro'),
    (1063, 1033, 'Blanca', 420.00, '2026-05-03 13:00:00-06', 'Color blanco'),
    (1064, 1033, 'Roja', 420.00, '2026-05-03 13:00:00-06', 'Color rojo'),
    (1065, 1034, 'Estandar', 199.00, '2026-05-04 14:00:00-06', 'Tazones de 1, 2 y 3 litros'),
    (1066, 1035, '1.5 litros', 549.00, '2026-05-05 15:00:00-06', 'Vaso de 1.5 litros'),
    (1067, 1035, '2 litros', 649.00, '2026-05-05 15:00:00-06', 'Vaso de 2 litros'),
    (1068, 1036, 'Estandar', 899.00, '2026-05-06 16:00:00-06', 'Incluye bandeja y rejilla'),
    (1069, 1037, '4 litros', 1150.00, '2026-05-07 08:00:00-06', 'Canasta de 4 litros'),
    (1070, 1037, '6 litros', 1390.00, '2026-05-07 08:00:00-06', 'Canasta de 6 litros'),
    (1071, 1038, '5 kg', 180.00, '2026-05-08 09:00:00-06', 'Una mancuerna de 5 kilogramos'),
    (1072, 1038, '10 kg', 320.00, '2026-05-08 09:00:00-06', 'Una mancuerna de 10 kilogramos'),
    (1073, 1039, 'Ligera', 75.00, '2026-05-09 10:00:00-06', 'Resistencia ligera, color verde'),
    (1074, 1039, 'Media', 85.00, '2026-05-09 10:00:00-06', 'Resistencia media, color azul'),
    (1075, 1039, 'Fuerte', 95.00, '2026-05-09 10:00:00-06', 'Resistencia fuerte, color negro'),
    (1076, 1040, 'Morado', 260.00, '2026-05-10 11:00:00-06', 'Color morado, incluye correa'),
    (1077, 1041, 'Cuadro M', 4200.00, '2026-05-11 12:00:00-06', 'Cuadro talla M, color negro'),
    (1078, 1041, 'Cuadro L', 4200.00, '2026-05-11 12:00:00-06', 'Cuadro talla L, color negro'),
    (1079, 1042, 'M blanco', 480.00, '2026-05-12 13:00:00-06', 'Talla M, color blanco'),
    (1080, 1042, 'L blanco', 480.00, '2026-05-12 13:00:00-06', 'Talla L, color blanco'),
    (1081, 1043, 'Estandar', 150.00, '2026-05-13 14:00:00-06', 'Sujecion de silicon al poste del asiento'),
    (1082, 1044, 'Estandar', 320.00, '2026-05-14 15:00:00-06', 'Cosido a maquina, camara de butilo'),
    (1083, 1045, 'Pasta blanda', 480.00, '2026-05-15 16:00:00-06', 'Tercera edicion, pasta blanda'),
    (1084, 1045, 'Pasta dura', 690.00, '2026-05-15 16:00:00-06', 'Tercera edicion, pasta dura'),
    (1085, 1046, 'Pasta blanda', 520.00, '2026-05-16 08:00:00-06', 'Segunda edicion, pasta blanda'),
    (1086, 1047, 'Pasta blanda', 145.00, '2026-05-17 09:00:00-06', 'Edicion en pasta blanda'),
    (1087, 1047, 'Bolsillo', 99.00, '2026-05-17 09:00:00-06', 'Edicion de bolsillo')
) AS v (id_producto_variante, id_producto, nombre_variante, precio, fecha_creacion, descripcion)
ON CONFLICT DO NOTHING;

-- Una fila por variante, aunque no tenga modificaciones. Hace falta: el ETL
-- arma el arreglo de variantes de cada evento leyendo este historial y no la
-- fila viva, asi que una variante sin historial no aparece en el documento y
-- nada avisa.

INSERT INTO productos_variantes_historial (id_producto_variante_historial, id_producto_variante, nombre_variante, precio, descripcion, fecha_creacion) VALUES
    (1001, 1001, 'S blanca',              189.00, 'Talla S, color blanco',                    '2026-04-01 08:00:00-06'),
    (1002, 1002, 'M blanca',              189.00, 'Talla M, color blanco',                    '2026-04-01 08:00:00-06'),
    (1003, 1003, 'L celeste',             199.00, 'Talla L, color celeste',                   '2026-04-01 08:00:00-06'),
    (1004, 1004, 'Unitalla multicolor',   145.00, 'Talla unica, estampado irrepetible',       '2026-04-02 09:00:00-06'),
    (1005, 1005, 'M celeste',             175.00, 'Talla M, color celeste',                   '2026-04-03 10:00:00-06'),
    (1006, 1006, 'L celeste',             175.00, 'Talla L, color celeste',                   '2026-04-03 10:00:00-06'),
    (1007, 1007, '30 azul',               259.00, 'Cintura 30, azul indigo',                  '2026-04-04 11:00:00-06'),
    (1008, 1008, '32 azul',               259.00, 'Cintura 32, azul indigo',                  '2026-04-04 11:00:00-06'),
    (1009, 1009, '34 negro',              269.00, 'Cintura 34, negro',                        '2026-04-04 11:00:00-06'),
    (1010, 1010, '32 claro',              279.00, 'Cintura 32, azul claro',                   '2026-04-05 12:00:00-06'),
    (1011, 1011, '34 claro',              279.00, 'Cintura 34, azul claro',                   '2026-04-05 12:00:00-06'),
    (1012, 1012, '32 gris',               320.00, 'Cintura 32, gris oxford',                  '2026-04-06 13:00:00-06'),
    (1013, 1013, '34 gris',               320.00, 'Cintura 34, gris oxford',                  '2026-04-06 13:00:00-06'),
    (1014, 1014, 'S gris',                349.00, 'Talla S, gris jaspeado',                   '2026-04-07 14:00:00-06'),
    (1015, 1015, 'M gris',                349.00, 'Talla M, gris jaspeado',                   '2026-04-07 14:00:00-06'),
    (1016, 1016, 'L gris',                359.00, 'Talla L, gris jaspeado',                   '2026-04-07 14:00:00-06'),
    (1017, 1017, 'M vino',                299.00, 'Talla M, color vino',                      '2026-04-08 15:00:00-06'),
    (1018, 1018, 'L vino',                299.00, 'Talla L, color vino',                      '2026-04-08 15:00:00-06'),
    (1019, 1019, '40 cafe',               780.00, 'Numero 40, cafe',                          '2026-04-09 16:00:00-06'),
    (1020, 1020, '42 cafe',               780.00, 'Numero 42, cafe',                          '2026-04-09 16:00:00-06'),
    (1021, 1021, '43 negro',              799.00, 'Numero 43, negro',                         '2026-04-09 16:00:00-06'),
    (1022, 1022, '41 cafe',               890.00, 'Numero 41, cafe oscuro',                   '2026-04-10 08:00:00-06'),
    (1023, 1023, '43 cafe',               890.00, 'Numero 43, cafe oscuro',                   '2026-04-10 08:00:00-06'),
    (1024, 1024, '38 azul',                89.00, 'Numero 38, azul',                          '2026-04-11 09:00:00-06'),
    (1025, 1025, '40 azul',                89.00, 'Numero 40, azul',                          '2026-04-11 09:00:00-06'),
    (1026, 1026, '42 negro',               95.00, 'Numero 42, negro',                         '2026-04-11 09:00:00-06'),
    (1027, 1027, '39 blanco',              65.00, 'Numero 39, blanco',                        '2026-04-12 10:00:00-06'),
    (1028, 1028, '41 blanco',              65.00, 'Numero 41, blanco',                        '2026-04-12 10:00:00-06'),
    (1029, 1029, '40 negro',              650.00, 'Numero 40, negro',                         '2026-04-13 11:00:00-06'),
    (1030, 1030, '42 negro',              650.00, 'Numero 42, negro',                         '2026-04-13 11:00:00-06'),
    (1031, 1031, '43 blanco',             665.00, 'Numero 43, blanco',                        '2026-04-13 11:00:00-06'),
    (1032, 1032, '40 beige',              380.00, 'Numero 40, beige',                         '2026-04-14 12:00:00-06'),
    (1033, 1033, '42 beige',              380.00, 'Numero 42, beige',                         '2026-04-14 12:00:00-06'),
    (1034, 1034, 'Negro',                 599.00, 'Color negro, estuche blando incluido',     '2026-04-15 13:00:00-06'),
    (1035, 1035, 'Azul',                  599.00, 'Color azul, estuche blando incluido',      '2026-04-15 13:00:00-06'),
    (1036, 1036, 'Estandar',              249.00, 'Color negro, cable de 1.2 metros',         '2026-04-16 14:00:00-06'),
    (1037, 1037, 'Negro',                 429.00, 'Color negro con gancho de oreja',          '2026-04-17 15:00:00-06'),
    (1038, 1038, 'Verde',                 429.00, 'Color verde con gancho de oreja',          '2026-04-17 15:00:00-06'),
    (1039, 1039, '128 GB',               3899.00, '128 GB de almacenamiento, 6 GB de RAM',    '2026-04-18 16:00:00-06'),
    (1040, 1040, '256 GB',               4399.00, '256 GB de almacenamiento, 8 GB de RAM',    '2026-04-18 16:00:00-06'),
    (1041, 1041, 'Unico',                 299.00, 'Version unica, doble tarjeta SIM',         '2026-04-19 08:00:00-06'),
    (1042, 1042, '256 GB',               5299.00, '256 GB de almacenamiento, 8 GB de RAM',    '2026-04-20 09:00:00-06'),
    (1043, 1043, '512 GB',               5999.00, '512 GB de almacenamiento, 12 GB de RAM',   '2026-04-20 09:00:00-06'),
    (1044, 1044, 'Con base',             1290.00, 'Incluye base de escritorio',               '2026-04-21 10:00:00-06'),
    (1045, 1045, 'Solo VESA',            1250.00, 'Sin base, montaje VESA de 100 milimetros', '2026-04-21 10:00:00-06'),
    (1046, 1046, 'Plano',                2590.00, 'Pantalla plana, panel IPS',                '2026-04-22 11:00:00-06'),
    (1047, 1047, 'Curvo',                2890.00, 'Pantalla curva de 1500R, panel VA',        '2026-04-22 11:00:00-06'),
    (1048, 1048, '8 GB RAM',             4599.00, '8 GB de RAM, 512 GB SSD',                  '2026-04-23 12:00:00-06'),
    (1049, 1049, '16 GB RAM',            5299.00, '16 GB de RAM, 1 TB SSD',                   '2026-04-23 12:00:00-06'),
    (1050, 1050, '16 GB RAM',            7499.00, '16 GB de RAM, 1 TB SSD',                   '2026-04-24 13:00:00-06'),
    (1051, 1051, '32 GB RAM',            8999.00, '32 GB de RAM, 2 TB SSD',                   '2026-04-24 13:00:00-06'),
    (1052, 1052, '8 GB RAM',             3499.00, '8 GB de RAM, 256 GB SSD',                  '2026-04-25 14:00:00-06'),
    (1053, 1053, 'Sin teclado numerico',  690.00, 'Formato compacto sin teclado numerico',    '2026-04-26 15:00:00-06'),
    (1054, 1054, 'Completo',              790.00, 'Formato completo con teclado numerico',    '2026-04-26 15:00:00-06'),
    (1055, 1055, 'Negro',                 210.00, 'Color negro, funciona con una pila AA',    '2026-04-27 16:00:00-06'),
    (1056, 1056, 'Estandar',              320.00, 'Altura de cinco posiciones',               '2026-04-28 08:00:00-06'),
    (1057, 1057, 'Blanca',                850.00, 'Cuerpo blanco',                            '2026-04-29 09:00:00-06'),
    (1058, 1058, 'Negra',                 850.00, 'Cuerpo negro',                             '2026-04-29 09:00:00-06'),
    (1059, 1059, 'Estandar',              620.00, 'Altura de 1.6 metros',                     '2026-04-30 10:00:00-06'),
    (1060, 1060, '3 metros',              180.00, 'Rollo de 3 metros',                        '2026-05-01 11:00:00-06'),
    (1061, 1061, '5 metros',              260.00, 'Rollo de 5 metros',                        '2026-05-01 11:00:00-06'),
    (1062, 1062, 'Estandar',              275.00, 'Seis moldes de distinto diametro',         '2026-05-02 12:00:00-06'),
    (1063, 1063, 'Blanca',                420.00, 'Color blanco',                             '2026-05-03 13:00:00-06'),
    (1064, 1064, 'Roja',                  420.00, 'Color rojo',                               '2026-05-03 13:00:00-06'),
    (1065, 1065, 'Estandar',              199.00, 'Tazones de 1, 2 y 3 litros',               '2026-05-04 14:00:00-06'),
    (1066, 1066, '1.5 litros',            549.00, 'Vaso de 1.5 litros',                       '2026-05-05 15:00:00-06'),
    (1067, 1067, '2 litros',              649.00, 'Vaso de 2 litros',                         '2026-05-05 15:00:00-06'),
    (1068, 1068, 'Estandar',              899.00, 'Incluye bandeja y rejilla',                '2026-05-06 16:00:00-06'),
    (1069, 1069, '4 litros',             1150.00, 'Canasta de 4 litros',                      '2026-05-07 08:00:00-06'),
    (1070, 1070, '6 litros',             1390.00, 'Canasta de 6 litros',                      '2026-05-07 08:00:00-06'),
    (1071, 1071, '5 kg',                  180.00, 'Una mancuerna de 5 kilogramos',            '2026-05-08 09:00:00-06'),
    (1072, 1072, '10 kg',                 320.00, 'Una mancuerna de 10 kilogramos',           '2026-05-08 09:00:00-06'),
    (1073, 1073, 'Ligera',                 75.00, 'Resistencia ligera, color verde',          '2026-05-09 10:00:00-06'),
    (1074, 1074, 'Media',                  85.00, 'Resistencia media, color azul',            '2026-05-09 10:00:00-06'),
    (1075, 1075, 'Fuerte',                 95.00, 'Resistencia fuerte, color negro',          '2026-05-09 10:00:00-06'),
    (1076, 1076, 'Morado',                260.00, 'Color morado, incluye correa',             '2026-05-10 11:00:00-06'),
    (1077, 1077, 'Cuadro M',             4200.00, 'Cuadro talla M, color negro',              '2026-05-11 12:00:00-06'),
    (1078, 1078, 'Cuadro L',             4200.00, 'Cuadro talla L, color negro',              '2026-05-11 12:00:00-06'),
    (1079, 1079, 'M blanco',              480.00, 'Talla M, color blanco',                    '2026-05-12 13:00:00-06'),
    (1080, 1080, 'L blanco',              480.00, 'Talla L, color blanco',                    '2026-05-12 13:00:00-06'),
    (1081, 1081, 'Estandar',              150.00, 'Sujecion de silicon al poste del asiento', '2026-05-13 14:00:00-06'),
    (1082, 1082, 'Estandar',              320.00, 'Cosido a maquina, camara de butilo',       '2026-05-14 15:00:00-06'),
    (1083, 1083, 'Pasta blanda',          480.00, 'Tercera edicion, pasta blanda',            '2026-05-15 16:00:00-06'),
    (1084, 1084, 'Pasta dura',            690.00, 'Tercera edicion, pasta dura',              '2026-05-15 16:00:00-06'),
    (1085, 1085, 'Pasta blanda',          520.00, 'Segunda edicion, pasta blanda',            '2026-05-16 08:00:00-06'),
    (1086, 1086, 'Pasta blanda',          145.00, 'Edicion en pasta blanda',                  '2026-05-17 09:00:00-06'),
    (1087, 1087, 'Bolsillo',               99.00, 'Edicion de bolsillo',                      '2026-05-17 09:00:00-06')
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
-- volvieran a insertar con un id de este bloque, el ON CONFLICT las descartaria
-- en silencio y la tabla de union quedaria apuntando a un id que no existe.
-- Por eso esas tres se referencian por su id original.

INSERT INTO imagen_producto (id_imagen_producto, imagen_producto_url) VALUES
    (1001, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/00/Simple_sweater_dress_with_with_turtleneck_-_pose_1.jpg/960px-Simple_sweater_dress_with_with_turtleneck_-_pose_1.jpg'),
    (1002, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/1-2-3-4_Cake_cooking_implements.JPG/960px-1-2-3-4_Cake_cooking_implements.JPG'),
    (1003, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/Jeans_Jeans_Jeans.jpg/960px-Jeans_Jeans_Jeans.jpg'),
    (1004, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/01/Sony_WH-CH510_Bluetooth_Over-Ear_Headphone.jpg/960px-Sony_WH-CH510_Bluetooth_Over-Ear_Headphone.jpg'),
    (1005, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/02/TieDyeShirtMpegMan.jpg/960px-TieDyeShirtMpegMan.jpg'),
    (1006, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Cycling_Amsterdam_03.jpg/960px-Cycling_Amsterdam_03.jpg'),
    (1007, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/06/Dekala_Arches%E2%84%A2_Smart_Lamp.jpg/960px-Dekala_Arches%E2%84%A2_Smart_Lamp.jpg'),
    (1008, 'https://upload.wikimedia.org/wikipedia/commons/thumb/0/0c/Jeans_2009.jpg/960px-Jeans_2009.jpg'),
    (1009, 'https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Attractive_man_lifting_dumbbell_weight_for_exercise_in_fitness_gym.jpg/960px-Attractive_man_lifting_dumbbell_weight_for_exercise_in_fitness_gym.jpg'),
    (1010, 'https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg'),
    (1011, 'https://upload.wikimedia.org/wikipedia/commons/thumb/2/2b/Stack_of_multicolored_books_on_a_table.jpg/960px-Stack_of_multicolored_books_on_a_table.jpg'),
    (1012, 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png'),
    (1013, 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/39/Altura_Estadio_Mushuc_Runa.jpg/960px-Altura_Estadio_Mushuc_Runa.jpg'),
    (1014, 'https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Headphones_1.jpg/960px-Headphones_1.jpg'),
    (1015, 'https://upload.wikimedia.org/wikipedia/commons/thumb/4/47/Flip_flop.jpg/960px-Flip_flop.jpg'),
    (1016, 'https://upload.wikimedia.org/wikipedia/commons/thumb/5/57/Smartphone_Use.jpg/960px-Smartphone_Use.jpg')
ON CONFLICT DO NOTHING;

-- Una imagen por producto, en la posicion 1 de todas sus variantes. La tabla
-- no lleva id escrito a mano: es la unica del bloque que sigue numerando con
-- su secuencia, igual que en el conjunto base.

INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden) VALUES
    (3, 1001, 1),
    (3, 1002, 1),
    (3, 1003, 1),
    (1005, 1004, 1),
    (3, 1005, 1),
    (3, 1006, 1),
    (1003, 1007, 1),
    (1003, 1008, 1),
    (1003, 1009, 1),
    (1008, 1010, 1),
    (1008, 1011, 1),
    (1008, 1012, 1),
    (1008, 1013, 1),
    (1001, 1014, 1),
    (1001, 1015, 1),
    (1001, 1016, 1),
    (1001, 1017, 1),
    (1001, 1018, 1),
    (1010, 1019, 1),
    (1010, 1020, 1),
    (1010, 1021, 1),
    (1010, 1022, 1),
    (1010, 1023, 1),
    (1015, 1024, 1),
    (1015, 1025, 1),
    (1015, 1026, 1),
    (1015, 1027, 1),
    (1015, 1028, 1),
    (1009, 1029, 1),
    (1009, 1030, 1),
    (1009, 1031, 1),
    (1013, 1032, 1),
    (1013, 1033, 1),
    (1004, 1034, 1),
    (1004, 1035, 1),
    (1014, 1036, 1),
    (1004, 1037, 1),
    (1004, 1038, 1),
    (1016, 1039, 1),
    (1016, 1040, 1),
    (1016, 1041, 1),
    (1016, 1042, 1),
    (1016, 1043, 1),
    (1012, 1044, 1),
    (1012, 1045, 1),
    (1012, 1046, 1),
    (1012, 1047, 1),
    (4, 1048, 1),
    (4, 1049, 1),
    (7, 1050, 1),
    (7, 1051, 1),
    (4, 1052, 1),
    (7, 1053, 1),
    (7, 1054, 1),
    (7, 1055, 1),
    (1012, 1056, 1),
    (1007, 1057, 1),
    (1007, 1058, 1),
    (1007, 1059, 1),
    (1007, 1060, 1),
    (1007, 1061, 1),
    (1002, 1062, 1),
    (1002, 1063, 1),
    (1002, 1064, 1),
    (1002, 1065, 1),
    (1002, 1066, 1),
    (1002, 1067, 1),
    (1002, 1068, 1),
    (1002, 1069, 1),
    (1002, 1070, 1),
    (1009, 1071, 1),
    (1009, 1072, 1),
    (1009, 1073, 1),
    (1009, 1074, 1),
    (1009, 1075, 1),
    (1009, 1076, 1),
    (1006, 1077, 1),
    (1006, 1078, 1),
    (1006, 1079, 1),
    (1006, 1080, 1),
    (1006, 1081, 1),
    (1013, 1082, 1),
    (1011, 1083, 1),
    (1011, 1084, 1),
    (1011, 1085, 1),
    (1011, 1086, 1),
    (1011, 1087, 1)
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
