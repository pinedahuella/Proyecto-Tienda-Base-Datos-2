-- 001_catalogo.sql
-- GENERADO por migrations/datos/generador.js. No editar a mano: la proxima
-- corrida del generador lo reescribe. Para cambiar algo, se cambia el
-- generador y se vuelve a correr.
--
--   node migrations/datos/generador.js
--
-- Que trae, y por que esta armado asi:
--
--   * El catalogo es COMPARTIDO. Un producto no es de nadie: describe una
--     cosa. Quien la vende y a como es una fila de oferta.
--   * La cuenta de la tienda (tienda@mesh.com) tiene oferta de TODAS las
--     variantes, y su precio es el que se ensena en la pagina.
--   * Los otros cuatro vendedores ofertan un subconjunto, repartido con una
--     semilla fija: asi hay productos con un solo precio y otros con cinco.
--   * Ningun id va a mano. Todo se busca por nombre o por correo, porque un
--     id escrito a mano corre en una maquina y revienta en la de al lado.


-- ============================================================
-- Por que se apaga un trigger a la mitad
-- ============================================================
-- El trigger del 005 escribe una fila de precio_historial cada vez que nace
-- o cambia una oferta, y le pone now(). Eso es lo correcto para la
-- aplicacion, pero este conjunto de datos necesita fechas del PASADO: sin
-- ellas no habria nada que reconstruir y la Entrega 1 se quedaria sin su
-- demostracion.
--
-- Asi que las filas de precio se escriben a mano, con sus fechas, y el
-- trigger se apaga mientras tanto. Se vuelve a encender al final, y al final
-- tambien se comprueba que el saldo de cada oferta cuadre con su kardex.

BEGIN;

ALTER TABLE oferta DISABLE TRIGGER trg_oferta_registrar_precio;

-- ============================================================
-- Las cuentas
-- ============================================================
-- Contrasenas: Vendedor123 para la tienda y los cuatro vendedores,
-- Comprador123 para los compradores, Admin123 para el admin. Son hashes de
-- scrypt en formato salt:hash, el mismo que usa el backend.
--
-- NOT EXISTS sobre las DOS restricciones unicas de usuarios, no solo sobre
-- el correo: si alguien ya se registro con ese nombre de usuario, un
-- ON CONFLICT (correo_electronico) revienta igual.

INSERT INTO usuarios (correo_electronico, usuario, nombre, apellido, contrasena_hash, id_rol_usuario, id_estado_usuario)
SELECT v.correo, v.usuario, v.nombre, v.apellido, v.clave, r.id_rol_usuario, e.id_estado_usuario
FROM (VALUES
    ('tienda@mesh.com', 'mesh_tienda', 'Mesh', 'Tienda', '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5', 'vendedor'),
    ('ventas.norte@mesh.com', 'ventas_norte', 'Carlos', 'Ramirez', '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5', 'vendedor'),
    ('ventas.sur@mesh.com', 'ventas_sur', 'Lucia', 'Morales', '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5', 'vendedor'),
    ('ventas.oriente@mesh.com', 'ventas_oriente', 'Andres', 'Castillo', '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5', 'vendedor'),
    ('ventas.poniente@mesh.com', 'ventas_poniente', 'Paola', 'Guzman', '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5', 'vendedor'),
    ('compradora.norte@mesh.com', 'compradora_norte', 'Ana', 'Lopez', '9f8e7d6c5b4a39281706f5e4d3c2b1a0:d3af92a164ee8d7608de4ccb96f35d5295245949d9eefffe9dbe892d2cad0cad2fb0c921d6c561264f3a0895242d86893173d1aa9235f77703ef61c86eb13d35', 'comprador'),
    ('comprador.sur@mesh.com', 'comprador_sur', 'Miguel', 'Herrera', '9f8e7d6c5b4a39281706f5e4d3c2b1a0:d3af92a164ee8d7608de4ccb96f35d5295245949d9eefffe9dbe892d2cad0cad2fb0c921d6c561264f3a0895242d86893173d1aa9235f77703ef61c86eb13d35', 'comprador'),
    ('admin@mesh.com', 'admin_mesh', 'Sofia', 'Vega', '0011223344556677889aabbccddeeff0:ac37be7b7ff5172d000f7f0c844ae57eee77959dc4614ba59ec74aba548099fd03e01a3c47daa403da682c9ff95465d8b8b9bc401acb94fceab6f5794ba7328a', 'admin')
) AS v(correo, usuario, nombre, apellido, clave, rol)
JOIN rol_usuario    r ON r.rol_usuario_nombre    = v.rol
JOIN estado_usuario e ON e.estado_usuario_nombre = 'activo'
WHERE NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.correo_electronico = v.correo)
  AND NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.usuario            = v.usuario);

-- Las direcciones de los compradores. Sin una direccion no se puede crear
-- un pedido: crear_pedido pide su id_direccion_historial.
INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, codigo_postal, id_estado_direccion)
SELECT u.id_usuario, v.pais, v.departamento, v.ciudad, v.codigo, ed.id_estado_direccion
FROM (VALUES
    ('compradora.norte@mesh.com', 'Guatemala', 'Guatemala',     'Guatemala', '01010'),
    ('comprador.sur@mesh.com',    'Guatemala', 'Sacatepequez',  'Antigua Guatemala', '03001')
) AS v(correo, pais, departamento, ciudad, codigo)
JOIN usuarios u ON u.correo_electronico = v.correo
JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa'
WHERE NOT EXISTS (SELECT 1 FROM direcciones d WHERE d.id_usuario = u.id_usuario);

-- Su primera version en el historial. El pedido apunta AQUI y no a
-- direcciones: guarda a donde se mando de verdad, aunque despues la editen.
INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, codigo_postal)
SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.codigo_postal
FROM direcciones d
WHERE NOT EXISTS (SELECT 1 FROM direccion_historial h WHERE h.id_direccion = d.id_direccion);

-- ============================================================
-- Las categorias: dos niveles
-- ============================================================
-- Las raices primero, porque las hojas las referencian. Una raiz agrupa y
-- no lleva nada: ni caracteristicas ni productos. Lo garantizan los dos
-- triggers del 003.

INSERT INTO categorias (nombre, id_categoria_padre) VALUES
    ('Electronica', NULL),
    ('Hogar', NULL),
    ('Ropa de hombre', NULL),
    ('Deportes', NULL),
    ('Libros', NULL),
    ('Belleza', NULL);

INSERT INTO categorias (nombre, id_categoria_padre)
SELECT v.hoja, p.id_categoria
FROM (VALUES
    ('Laptops', 'Electronica'),
    ('Telefonos', 'Electronica'),
    ('Audifonos', 'Electronica'),
    ('Monitores', 'Electronica'),
    ('Cocina', 'Hogar'),
    ('Muebles', 'Hogar'),
    ('Iluminacion', 'Hogar'),
    ('Camisas', 'Ropa de hombre'),
    ('Pantalones', 'Ropa de hombre'),
    ('Zapatos', 'Ropa de hombre'),
    ('Futbol', 'Deportes'),
    ('Ciclismo', 'Deportes'),
    ('Fitness', 'Deportes'),
    ('Literatura', 'Libros'),
    ('Tecnicos', 'Libros'),
    ('Cuidado facial', 'Belleza'),
    ('Fragancias', 'Belleza')
) AS v(hoja, raiz)
JOIN categorias p ON p.nombre = v.raiz AND p.id_categoria_padre IS NULL;

-- ============================================================
-- Las definiciones de caracteristica
-- ============================================================
-- Se definen una vez y las usan muchas categorias. La unidad va en la
-- definicion y no en cada valor: asi el valor queda limpio (16, no "16 GB")
-- y se puede comparar y ordenar como numero.

INSERT INTO caracteristica (nombre, id_tipo_dato, unidad)
SELECT v.nombre, t.id_tipo_dato, v.unidad
FROM (VALUES
    ('Marca', 'texto', NULL),
    ('Modelo', 'texto', NULL),
    ('Pais de origen', 'texto', NULL),
    ('Garantia', 'entero', 'meses'),
    ('Material principal', 'texto', NULL),
    ('Peso', 'decimal', 'kg'),
    ('Potencia', 'entero', 'W'),
    ('Duracion de la bateria', 'decimal', 'h'),
    ('Inalambrico', 'booleano', NULL),
    ('Impermeable', 'booleano', NULL),
    ('Requiere ensamblaje', 'booleano', NULL),
    ('Apto para lavavajillas', 'booleano', NULL),
    ('Contenido del paquete', 'lista', NULL),
    ('Certificaciones', 'lista', NULL),
    ('Autor', 'texto', NULL),
    ('Editorial', 'texto', NULL),
    ('Paginas', 'entero', 'paginas'),
    ('Idioma', 'texto', NULL),
    ('Anio de publicacion', 'entero', NULL),
    ('Tipo de piel', 'texto', NULL),
    ('Ingredientes destacados', 'lista', NULL),
    ('Tipo de fragancia', 'texto', NULL),
    ('Nivel de resistencia', 'texto', NULL),
    ('Origen del algodon', 'texto', NULL)
) AS v(nombre, tipo, unidad)
JOIN tipo_dato t ON t.tipo_dato = v.tipo;

INSERT INTO caracteristica_variante (nombre, id_tipo_dato, unidad)
SELECT v.nombre, t.id_tipo_dato, v.unidad
FROM (VALUES
    ('Color', 'texto', NULL),
    ('Talla', 'texto', NULL),
    ('Numero de calzado', 'entero', NULL),
    ('Memoria RAM', 'entero', 'GB'),
    ('Almacenamiento', 'entero', 'GB'),
    ('Tamano de pantalla', 'decimal', 'pulgadas'),
    ('Tasa de refresco', 'entero', 'Hz'),
    ('Capacidad', 'decimal', 'L'),
    ('Volumen', 'entero', 'ml'),
    ('Acabado', 'texto', NULL),
    ('Formato', 'texto', NULL),
    ('Longitud del cable', 'decimal', 'm')
) AS v(nombre, tipo, unidad)
JOIN tipo_dato t ON t.tipo_dato = v.tipo;

-- ============================================================
-- Que ofrece cada hoja
-- ============================================================
-- Esto arma el formulario de publicar. NO dice que tiene un producto: de lo
-- que la categoria ofrece, casi nadie llena todo, y esa es justamente la
-- heterogeneidad que la Entrega 1 tiene que ensenar.

INSERT INTO categoria_caracteristica (id_categoria, id_caracteristica)
SELECT c.id_categoria, k.id_caracteristica
FROM (VALUES
    ('Laptops', 'Marca'),
    ('Laptops', 'Modelo'),
    ('Laptops', 'Pais de origen'),
    ('Laptops', 'Garantia'),
    ('Laptops', 'Peso'),
    ('Laptops', 'Duracion de la bateria'),
    ('Laptops', 'Contenido del paquete'),
    ('Laptops', 'Certificaciones'),
    ('Laptops', 'Material principal'),
    ('Telefonos', 'Marca'),
    ('Telefonos', 'Modelo'),
    ('Telefonos', 'Pais de origen'),
    ('Telefonos', 'Garantia'),
    ('Telefonos', 'Peso'),
    ('Telefonos', 'Impermeable'),
    ('Telefonos', 'Contenido del paquete'),
    ('Telefonos', 'Duracion de la bateria'),
    ('Telefonos', 'Certificaciones'),
    ('Audifonos', 'Marca'),
    ('Audifonos', 'Modelo'),
    ('Audifonos', 'Garantia'),
    ('Audifonos', 'Inalambrico'),
    ('Audifonos', 'Impermeable'),
    ('Audifonos', 'Duracion de la bateria'),
    ('Audifonos', 'Peso'),
    ('Audifonos', 'Contenido del paquete'),
    ('Monitores', 'Marca'),
    ('Monitores', 'Modelo'),
    ('Monitores', 'Garantia'),
    ('Monitores', 'Peso'),
    ('Monitores', 'Certificaciones'),
    ('Monitores', 'Contenido del paquete'),
    ('Monitores', 'Material principal'),
    ('Cocina', 'Marca'),
    ('Cocina', 'Material principal'),
    ('Cocina', 'Pais de origen'),
    ('Cocina', 'Garantia'),
    ('Cocina', 'Potencia'),
    ('Cocina', 'Apto para lavavajillas'),
    ('Cocina', 'Contenido del paquete'),
    ('Cocina', 'Peso'),
    ('Muebles', 'Marca'),
    ('Muebles', 'Modelo'),
    ('Muebles', 'Material principal'),
    ('Muebles', 'Peso'),
    ('Muebles', 'Requiere ensamblaje'),
    ('Muebles', 'Garantia'),
    ('Muebles', 'Contenido del paquete'),
    ('Muebles', 'Pais de origen'),
    ('Muebles', 'Certificaciones'),
    ('Iluminacion', 'Marca'),
    ('Iluminacion', 'Modelo'),
    ('Iluminacion', 'Potencia'),
    ('Iluminacion', 'Garantia'),
    ('Iluminacion', 'Inalambrico'),
    ('Iluminacion', 'Material principal'),
    ('Iluminacion', 'Certificaciones'),
    ('Iluminacion', 'Pais de origen'),
    ('Iluminacion', 'Peso'),
    ('Camisas', 'Marca'),
    ('Camisas', 'Modelo'),
    ('Camisas', 'Material principal'),
    ('Camisas', 'Origen del algodon'),
    ('Camisas', 'Pais de origen'),
    ('Camisas', 'Certificaciones'),
    ('Camisas', 'Peso'),
    ('Camisas', 'Contenido del paquete'),
    ('Pantalones', 'Marca'),
    ('Pantalones', 'Modelo'),
    ('Pantalones', 'Material principal'),
    ('Pantalones', 'Pais de origen'),
    ('Pantalones', 'Origen del algodon'),
    ('Pantalones', 'Certificaciones'),
    ('Pantalones', 'Peso'),
    ('Zapatos', 'Marca'),
    ('Zapatos', 'Modelo'),
    ('Zapatos', 'Material principal'),
    ('Zapatos', 'Impermeable'),
    ('Zapatos', 'Garantia'),
    ('Zapatos', 'Pais de origen'),
    ('Zapatos', 'Peso'),
    ('Zapatos', 'Certificaciones'),
    ('Futbol', 'Marca'),
    ('Futbol', 'Modelo'),
    ('Futbol', 'Material principal'),
    ('Futbol', 'Certificaciones'),
    ('Futbol', 'Pais de origen'),
    ('Futbol', 'Peso'),
    ('Futbol', 'Garantia'),
    ('Futbol', 'Contenido del paquete'),
    ('Ciclismo', 'Marca'),
    ('Ciclismo', 'Modelo'),
    ('Ciclismo', 'Material principal'),
    ('Ciclismo', 'Garantia'),
    ('Ciclismo', 'Peso'),
    ('Ciclismo', 'Certificaciones'),
    ('Ciclismo', 'Contenido del paquete'),
    ('Ciclismo', 'Pais de origen'),
    ('Fitness', 'Marca'),
    ('Fitness', 'Modelo'),
    ('Fitness', 'Material principal'),
    ('Fitness', 'Nivel de resistencia'),
    ('Fitness', 'Peso'),
    ('Fitness', 'Contenido del paquete'),
    ('Fitness', 'Certificaciones'),
    ('Fitness', 'Pais de origen'),
    ('Literatura', 'Autor'),
    ('Literatura', 'Editorial'),
    ('Literatura', 'Paginas'),
    ('Literatura', 'Idioma'),
    ('Literatura', 'Anio de publicacion'),
    ('Literatura', 'Peso'),
    ('Literatura', 'Pais de origen'),
    ('Literatura', 'Material principal'),
    ('Literatura', 'Certificaciones'),
    ('Tecnicos', 'Autor'),
    ('Tecnicos', 'Editorial'),
    ('Tecnicos', 'Paginas'),
    ('Tecnicos', 'Idioma'),
    ('Tecnicos', 'Anio de publicacion'),
    ('Tecnicos', 'Certificaciones'),
    ('Tecnicos', 'Peso'),
    ('Tecnicos', 'Pais de origen'),
    ('Tecnicos', 'Material principal'),
    ('Cuidado facial', 'Marca'),
    ('Cuidado facial', 'Modelo'),
    ('Cuidado facial', 'Tipo de piel'),
    ('Cuidado facial', 'Ingredientes destacados'),
    ('Cuidado facial', 'Pais de origen'),
    ('Cuidado facial', 'Certificaciones'),
    ('Cuidado facial', 'Contenido del paquete'),
    ('Cuidado facial', 'Peso'),
    ('Fragancias', 'Marca'),
    ('Fragancias', 'Tipo de fragancia'),
    ('Fragancias', 'Pais de origen'),
    ('Fragancias', 'Ingredientes destacados'),
    ('Fragancias', 'Certificaciones'),
    ('Fragancias', 'Contenido del paquete'),
    ('Fragancias', 'Peso'),
    ('Fragancias', 'Garantia')
) AS v(hoja, caracteristica)
JOIN categorias      c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL
JOIN caracteristica  k ON k.nombre = v.caracteristica;

INSERT INTO categoria_caracteristica_variante (id_categoria, id_caracteristica_variante)
SELECT c.id_categoria, k.id_caracteristica
FROM (VALUES
    ('Laptops', 'Memoria RAM'),
    ('Laptops', 'Almacenamiento'),
    ('Laptops', 'Tamano de pantalla'),
    ('Laptops', 'Color'),
    ('Laptops', 'Acabado'),
    ('Telefonos', 'Almacenamiento'),
    ('Telefonos', 'Color'),
    ('Telefonos', 'Tamano de pantalla'),
    ('Telefonos', 'Memoria RAM'),
    ('Audifonos', 'Color'),
    ('Audifonos', 'Acabado'),
    ('Audifonos', 'Longitud del cable'),
    ('Monitores', 'Tamano de pantalla'),
    ('Monitores', 'Tasa de refresco'),
    ('Monitores', 'Color'),
    ('Monitores', 'Acabado'),
    ('Cocina', 'Capacidad'),
    ('Cocina', 'Color'),
    ('Cocina', 'Acabado'),
    ('Muebles', 'Color'),
    ('Muebles', 'Acabado'),
    ('Muebles', 'Talla'),
    ('Iluminacion', 'Color'),
    ('Iluminacion', 'Acabado'),
    ('Iluminacion', 'Longitud del cable'),
    ('Camisas', 'Talla'),
    ('Camisas', 'Color'),
    ('Camisas', 'Acabado'),
    ('Pantalones', 'Talla'),
    ('Pantalones', 'Color'),
    ('Pantalones', 'Acabado'),
    ('Zapatos', 'Numero de calzado'),
    ('Zapatos', 'Color'),
    ('Zapatos', 'Acabado'),
    ('Futbol', 'Talla'),
    ('Futbol', 'Color'),
    ('Ciclismo', 'Talla'),
    ('Ciclismo', 'Color'),
    ('Ciclismo', 'Acabado'),
    ('Fitness', 'Color'),
    ('Fitness', 'Talla'),
    ('Literatura', 'Formato'),
    ('Literatura', 'Color'),
    ('Tecnicos', 'Formato'),
    ('Cuidado facial', 'Volumen'),
    ('Cuidado facial', 'Color'),
    ('Fragancias', 'Volumen'),
    ('Fragancias', 'Color')
) AS v(hoja, caracteristica)
JOIN categorias             c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL
JOIN caracteristica_variante k ON k.nombre = v.caracteristica;

-- ============================================================
-- Los productos: 34 en 17 categorias hoja
-- ============================================================
-- Cuelgan de una hoja, nunca de una raiz. Las fechas estan escalonadas a lo
-- largo del ano: sin un pasado no hay nada que reconstruir.

INSERT INTO productos (nombre, descripcion, fecha_creacion, id_estado_producto, id_categoria)
SELECT v.nombre, v.descripcion, v.fecha::timestamptz, ep.id_estado_producto, c.id_categoria
FROM (VALUES
    ('Laptop Aurora 14', 'Ultraligera de 14 pulgadas con chasis de aluminio y teclado retroiluminado.', '2026-01-04 10:52:00-06', 'Laptops'),
    ('Laptop Bastion 16', 'Estacion de trabajo de 16 pulgadas para render y compilacion.', '2026-01-09 10:22:00-06', 'Laptops'),
    ('Laptop Nimbo 13', 'Equipo de entrada para estudio y oficina, silencioso y sin ventilador.', '2026-01-14 10:32:00-06', 'Laptops'),
    ('Telefono Vela 7', 'Pantalla OLED de 6.4 pulgadas y camara principal de 50 MP.', '2026-01-24 10:15:00-06', 'Telefonos'),
    ('Telefono Ceibo Lite', 'Bateria de dos dias y ranura para memoria expandible.', '2026-01-24 10:38:00-06', 'Telefonos'),
    ('Audifonos Sereno ANC', 'Diadema cerrada con cancelacion activa y estuche rigido.', '2026-02-01 10:34:00-06', 'Audifonos'),
    ('Audifonos Brisa Sport', 'Intraurales con gancho de silicona, pensados para correr.', '2026-02-06 10:02:00-06', 'Audifonos'),
    ('Audifonos Estudio 900', 'Monitoreo de referencia con cable desmontable de 3 metros.', '2026-02-11 10:26:00-06', 'Audifonos'),
    ('Monitor Horizonte 27', 'Panel IPS de 27 pulgadas con base ajustable en altura.', '2026-02-16 10:25:00-06', 'Monitores'),
    ('Monitor Panorama 34', 'Ultrapanoramico curvo de 34 pulgadas, ideal para dos ventanas lado a lado.', '2026-02-21 10:15:00-06', 'Monitores'),
    ('Cafetera Alba Espresso', 'Cafetera de brazo con vaporizador y bandeja recogegotas extraible.', '2026-02-08 12:00:00-06', 'Cocina'),
    ('Juego de ollas Fuego 5 piezas', 'Cinco piezas de acero tricapa con tapas de vidrio templado.', '2026-03-03 10:48:00-06', 'Cocina'),
    ('Licuadora Torbellino 1200', 'Vaso de vidrio y cuchillas de seis puntas para hielo.', '2026-03-08 10:15:00-06', 'Cocina'),
    ('Escritorio Roble 120', 'Tablero de 120 por 60 cm con pasacables y estructura de acero.', '2026-03-13 10:05:00-06', 'Muebles'),
    ('Silla ergonomica Vertebra', 'Respaldo de malla, soporte lumbar regulable y apoyabrazos 3D.', '2026-03-18 10:04:00-06', 'Muebles'),
    ('Lampara de escritorio Faro', 'Brazo articulado con tres temperaturas de color y puerto USB.', '2026-03-23 10:38:00-06', 'Iluminacion'),
    ('Tira LED Aurora 5 m', 'Cinco metros regulables con control remoto y adhesivo 3M.', '2026-03-28 10:05:00-06', 'Iluminacion'),
    ('Camisa de lino manga larga', 'Lino lavado de corte regular con cuello italiano.', '2026-01-12 09:00:00-06', 'Camisas'),
    ('Camisa oxford clasica', 'Oxford de algodon peinado, cuello con botones.', '2026-04-10 10:16:00-06', 'Camisas'),
    ('Pantalon chino resistente', 'Sarga de algodon con elastano, corte recto.', '2026-04-15 10:25:00-06', 'Pantalones'),
    ('Zapato de cuero Senda', 'Cuero vacuno con suela de goma cosida.', '2026-04-20 10:48:00-06', 'Zapatos'),
    ('Bota impermeable Cumbre', 'Membrana impermeable y suela con agarre para roca mojada.', '2026-04-25 10:56:00-06', 'Zapatos'),
    ('Balon de futbol numero 5', 'Costura termosellada, apto para cancha de grama sintetica.', '2026-04-06 08:00:00-06', 'Futbol'),
    ('Espinilleras Muralla', 'Placa rigida con espuma de alta densidad y mallas sujetadoras.', '2026-05-07 10:27:00-06', 'Futbol'),
    ('Casco de ruta Aerodino', 'Veintidos ventilaciones y ajuste micrometrico en la nuca.', '2026-05-12 10:20:00-06', 'Ciclismo'),
    ('Bomba de piso Piston', 'Manometro analogico hasta 160 psi y cabezal para las dos valvulas.', '2026-05-17 10:26:00-06', 'Ciclismo'),
    ('Set de bandas elasticas', 'Cinco bandas de latex con distinta resistencia y bolsa de malla.', '2026-05-22 10:34:00-06', 'Fitness'),
    ('Tapete de yoga Raiz 6 mm', 'Seis milimetros de TPE con superficie antideslizante en las dos caras.', '2026-05-27 10:59:00-06', 'Fitness'),
    ('El camino de las nubes', 'Novela de viaje por el altiplano, ganadora del premio nacional.', '2026-05-20 09:00:00-06', 'Literatura'),
    ('Cuentos de la ceiba', 'Doce relatos breves sobre la memoria y el desarraigo.', '2026-06-09 10:52:00-06', 'Literatura'),
    ('Bases de datos distribuidas', 'Consistencia, particionado y replicacion, con ejercicios resueltos.', '2026-06-14 10:03:00-06', 'Tecnicos'),
    ('Serum de niacinamida 10%', 'Serum ligero para textura y marcas, de uso nocturno.', '2026-06-19 10:45:00-06', 'Cuidado facial'),
    ('Protector solar mineral FPS 50', 'Filtro mineral sin fragancia, apto para piel sensible.', '2026-06-24 10:16:00-06', 'Cuidado facial'),
    ('Eau de parfum Bruma', 'Salida citrica, fondo amaderado, doce horas de fijacion.', '2026-07-01 10:57:00-06', 'Fragancias')
) AS v(nombre, descripcion, fecha, hoja)
JOIN estado_producto ep ON ep.estado_producto_nombre = 'activo'
JOIN categorias      c  ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;

-- Las variantes. Son del CATALOGO y no del vendedor: los cinco que venden
-- la misma laptop ofertan la misma variante, cada uno con su precio.
INSERT INTO productos_variantes (id_producto, nombre_variante, descripcion, fecha_creacion, id_estado_variantes)
SELECT p.id_producto, v.nombre_variante, v.descripcion, v.fecha::timestamptz, ev.id_estado_variante
FROM (VALUES
    ('Laptop Aurora 14', '16 GB / 512 GB', NULL, '2026-01-04 10:52:00-06'),
    ('Laptop Aurora 14', '32 GB / 1 TB', NULL, '2026-01-04 10:52:00-06'),
    ('Laptop Bastion 16', '32 GB / 1 TB', NULL, '2026-01-09 10:22:00-06'),
    ('Laptop Bastion 16', '64 GB / 2 TB', NULL, '2026-01-09 10:22:00-06'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', NULL, '2026-01-14 10:32:00-06'),
    ('Telefono Vela 7', '128 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '256 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '512 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Ceibo Lite', '64 GB', NULL, '2026-01-24 10:38:00-06'),
    ('Telefono Ceibo Lite', '128 GB', NULL, '2026-01-24 10:38:00-06'),
    ('Audifonos Sereno ANC', 'Negro', NULL, '2026-02-01 10:34:00-06'),
    ('Audifonos Sereno ANC', 'Arena', NULL, '2026-02-01 10:34:00-06'),
    ('Audifonos Brisa Sport', 'Verde lima', NULL, '2026-02-06 10:02:00-06'),
    ('Audifonos Brisa Sport', 'Gris', NULL, '2026-02-06 10:02:00-06'),
    ('Audifonos Estudio 900', 'Cable 3 m', NULL, '2026-02-11 10:26:00-06'),
    ('Monitor Horizonte 27', '75 Hz', NULL, '2026-02-16 10:25:00-06'),
    ('Monitor Horizonte 27', '165 Hz', NULL, '2026-02-16 10:25:00-06'),
    ('Monitor Panorama 34', '100 Hz', NULL, '2026-02-21 10:15:00-06'),
    ('Cafetera Alba Espresso', '1.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Cafetera Alba Espresso', '2.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Juego de ollas Fuego 5 piezas', 'Estandar', NULL, '2026-03-03 10:48:00-06'),
    ('Licuadora Torbellino 1200', '1.5 L', NULL, '2026-03-08 10:15:00-06'),
    ('Licuadora Torbellino 1200', '2 L', NULL, '2026-03-08 10:15:00-06'),
    ('Escritorio Roble 120', 'Natural', NULL, '2026-03-13 10:05:00-06'),
    ('Escritorio Roble 120', 'Nogal', NULL, '2026-03-13 10:05:00-06'),
    ('Silla ergonomica Vertebra', 'Negra', NULL, '2026-03-18 10:04:00-06'),
    ('Silla ergonomica Vertebra', 'Gris', NULL, '2026-03-18 10:04:00-06'),
    ('Lampara de escritorio Faro', 'Blanca', NULL, '2026-03-23 10:38:00-06'),
    ('Lampara de escritorio Faro', 'Negra', NULL, '2026-03-23 10:38:00-06'),
    ('Tira LED Aurora 5 m', 'Multicolor', NULL, '2026-03-28 10:05:00-06'),
    ('Camisa de lino manga larga', 'S azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'M azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'L blanca', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa oxford clasica', 'M celeste', NULL, '2026-04-10 10:16:00-06'),
    ('Camisa oxford clasica', 'L celeste', NULL, '2026-04-10 10:16:00-06'),
    ('Pantalon chino resistente', '32 beige', NULL, '2026-04-15 10:25:00-06'),
    ('Pantalon chino resistente', '34 beige', NULL, '2026-04-15 10:25:00-06'),
    ('Pantalon chino resistente', '34 azul', NULL, '2026-04-15 10:25:00-06'),
    ('Zapato de cuero Senda', '40 cafe', NULL, '2026-04-20 10:48:00-06'),
    ('Zapato de cuero Senda', '42 cafe', NULL, '2026-04-20 10:48:00-06'),
    ('Zapato de cuero Senda', '42 negro', NULL, '2026-04-20 10:48:00-06'),
    ('Bota impermeable Cumbre', '41', NULL, '2026-04-25 10:56:00-06'),
    ('Bota impermeable Cumbre', '43', NULL, '2026-04-25 10:56:00-06'),
    ('Balon de futbol numero 5', 'Blanco', NULL, '2026-04-06 08:00:00-06'),
    ('Balon de futbol numero 5', 'Naranja', NULL, '2026-04-06 08:00:00-06'),
    ('Espinilleras Muralla', 'M', NULL, '2026-05-07 10:27:00-06'),
    ('Espinilleras Muralla', 'L', NULL, '2026-05-07 10:27:00-06'),
    ('Casco de ruta Aerodino', 'M blanco', NULL, '2026-05-12 10:20:00-06'),
    ('Casco de ruta Aerodino', 'L negro', NULL, '2026-05-12 10:20:00-06'),
    ('Bomba de piso Piston', 'Estandar', NULL, '2026-05-17 10:26:00-06'),
    ('Set de bandas elasticas', 'Set completo', NULL, '2026-05-22 10:34:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Verde', NULL, '2026-05-27 10:59:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Morado', NULL, '2026-05-27 10:59:00-06'),
    ('El camino de las nubes', 'Pasta blanda', NULL, '2026-05-20 09:00:00-06'),
    ('El camino de las nubes', 'Pasta dura', NULL, '2026-05-20 09:00:00-06'),
    ('Cuentos de la ceiba', 'Pasta blanda', NULL, '2026-06-09 10:52:00-06'),
    ('Bases de datos distribuidas', 'Pasta dura', NULL, '2026-06-14 10:03:00-06'),
    ('Bases de datos distribuidas', 'Digital', NULL, '2026-06-14 10:03:00-06'),
    ('Serum de niacinamida 10%', '30 ml', NULL, '2026-06-19 10:45:00-06'),
    ('Serum de niacinamida 10%', '50 ml', NULL, '2026-06-19 10:45:00-06'),
    ('Protector solar mineral FPS 50', '50 ml', NULL, '2026-06-24 10:16:00-06'),
    ('Eau de parfum Bruma', '50 ml', NULL, '2026-07-01 10:57:00-06'),
    ('Eau de parfum Bruma', '100 ml', NULL, '2026-07-01 10:57:00-06')
) AS v(producto, nombre_variante, descripcion, fecha)
JOIN productos       p  ON p.nombre = v.producto
JOIN estado_variantes ev ON ev.estado_variante_nombre = 'activa';

-- ============================================================
-- La primera version de cada historial
-- ============================================================
-- Nace con el producto. Sin esta fila, preguntar por una fecha anterior al
-- primer CAMBIO contestaria vacio, y "no existia" se leeria igual que
-- "nunca cambio".

INSERT INTO productos_historial (id_producto, nombre, descripcion, id_categoria, fecha_creacion)
SELECT p.id_producto, v.nombre, v.descripcion, c.id_categoria, v.fecha::timestamptz
FROM (VALUES
    ('Laptop Aurora 14', 'Laptop Aurora 14', 'Ultraligera de 14 pulgadas.', 'Laptops', '2026-01-04 10:52:00-06'),
    ('Laptop Aurora 14', 'Laptop Aurora 14 (2026)', 'Ultraligera de 14 pulgadas.', 'Laptops', '2026-02-18 15:00:00-06'),
    ('Laptop Aurora 14', 'Laptop Aurora 14', 'Ultraligera de 14 pulgadas con chasis de aluminio y teclado retroiluminado.', 'Laptops', '2026-04-18 14:00:00-06'),
    ('Laptop Bastion 16', 'Laptop Bastion 16', 'Estacion de trabajo de 16 pulgadas para render y compilacion.', 'Laptops', '2026-01-09 10:22:00-06'),
    ('Laptop Nimbo 13', 'Laptop Nimbo 13', 'Equipo de entrada para estudio y oficina, silencioso y sin ventilador.', 'Laptops', '2026-01-14 10:32:00-06'),
    ('Telefono Vela 7', 'Telefono Vela 7 Plus', 'Pantalla OLED de 6.4 pulgadas.', 'Telefonos', '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', 'Telefono Vela 7', 'Pantalla OLED de 6.4 pulgadas y camara principal de 50 MP.', 'Telefonos', '2026-03-24 14:00:00-06'),
    ('Telefono Ceibo Lite', 'Telefono Ceibo Lite', 'Bateria de dos dias y ranura para memoria expandible.', 'Telefonos', '2026-01-24 10:38:00-06'),
    ('Audifonos Sereno ANC', 'Audifonos Sereno ANC', 'Diadema cerrada con cancelacion activa y estuche rigido.', 'Audifonos', '2026-02-01 10:34:00-06'),
    ('Audifonos Brisa Sport', 'Audifonos Brisa Sport', 'Intraurales con gancho de silicona, pensados para correr.', 'Audifonos', '2026-02-06 10:02:00-06'),
    ('Audifonos Estudio 900', 'Audifonos Estudio 900', 'Monitoreo de referencia con cable desmontable de 3 metros.', 'Audifonos', '2026-02-11 10:26:00-06'),
    ('Monitor Horizonte 27', 'Monitor Horizonte 27', 'Panel IPS de 27 pulgadas con base ajustable en altura.', 'Monitores', '2026-02-16 10:25:00-06'),
    ('Monitor Panorama 34', 'Monitor Panorama 34', 'Ultrapanoramico curvo de 34 pulgadas, ideal para dos ventanas lado a lado.', 'Monitores', '2026-02-21 10:15:00-06'),
    ('Cafetera Alba Espresso', 'Cafetera Alba Espresso', 'Cafetera de brazo con vaporizador.', 'Cocina', '2026-02-08 12:00:00-06'),
    ('Cafetera Alba Espresso', 'Cafetera Alba Espresso', 'Cafetera de brazo con vaporizador y bandeja recogegotas extraible.', 'Cocina', '2026-04-08 14:00:00-06'),
    ('Juego de ollas Fuego 5 piezas', 'Juego de ollas Fuego 5 piezas', 'Cinco piezas de acero tricapa con tapas de vidrio templado.', 'Cocina', '2026-03-03 10:48:00-06'),
    ('Licuadora Torbellino 1200', 'Licuadora Torbellino 1200', 'Vaso de vidrio y cuchillas de seis puntas para hielo.', 'Cocina', '2026-03-08 10:15:00-06'),
    ('Escritorio Roble 120', 'Escritorio Roble 120', 'Tablero de 120 por 60 cm con pasacables y estructura de acero.', 'Muebles', '2026-03-13 10:05:00-06'),
    ('Silla ergonomica Vertebra', 'Silla ergonomica Vertebra', 'Respaldo de malla, soporte lumbar regulable y apoyabrazos 3D.', 'Muebles', '2026-03-18 10:04:00-06'),
    ('Lampara de escritorio Faro', 'Lampara de escritorio Faro', 'Brazo articulado con tres temperaturas de color y puerto USB.', 'Iluminacion', '2026-03-23 10:38:00-06'),
    ('Tira LED Aurora 5 m', 'Tira LED Aurora 5 m', 'Cinco metros regulables con control remoto y adhesivo 3M.', 'Iluminacion', '2026-03-28 10:05:00-06'),
    ('Camisa de lino manga larga', 'Camisa de lino', 'Camisa de lino de corte regular.', 'Camisas', '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'Camisa de lino', 'Lino lavado de corte regular con cuello italiano.', 'Camisas', '2026-03-04 11:30:00-06'),
    ('Camisa de lino manga larga', 'Camisa de lino manga larga', 'Lino lavado de corte regular con cuello italiano.', 'Camisas', '2026-05-04 14:00:00-06'),
    ('Camisa oxford clasica', 'Camisa oxford clasica', 'Oxford de algodon peinado, cuello con botones.', 'Camisas', '2026-04-10 10:16:00-06'),
    ('Pantalon chino resistente', 'Pantalon chino resistente', 'Sarga de algodon con elastano, corte recto.', 'Pantalones', '2026-04-15 10:25:00-06'),
    ('Zapato de cuero Senda', 'Zapato de cuero Senda', 'Cuero vacuno con suela de goma cosida.', 'Zapatos', '2026-04-20 10:48:00-06'),
    ('Bota impermeable Cumbre', 'Bota impermeable Cumbre', 'Membrana impermeable y suela con agarre para roca mojada.', 'Zapatos', '2026-04-25 10:56:00-06'),
    ('Balon de futbol numero 5', 'Balon de futbol numero 5', 'Costura termosellada, apto para cancha de grama sintetica.', 'Fitness', '2026-04-06 08:00:00-06'),
    ('Balon de futbol numero 5', 'Balon de futbol numero 5', 'Costura termosellada, apto para cancha de grama sintetica.', 'Futbol', '2026-06-06 14:00:00-06'),
    ('Espinilleras Muralla', 'Espinilleras Muralla', 'Placa rigida con espuma de alta densidad y mallas sujetadoras.', 'Futbol', '2026-05-07 10:27:00-06'),
    ('Casco de ruta Aerodino', 'Casco de ruta Aerodino', 'Veintidos ventilaciones y ajuste micrometrico en la nuca.', 'Ciclismo', '2026-05-12 10:20:00-06'),
    ('Bomba de piso Piston', 'Bomba de piso Piston', 'Manometro analogico hasta 160 psi y cabezal para las dos valvulas.', 'Ciclismo', '2026-05-17 10:26:00-06'),
    ('Set de bandas elasticas', 'Set de bandas elasticas', 'Cinco bandas de latex con distinta resistencia y bolsa de malla.', 'Fitness', '2026-05-22 10:34:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Tapete de yoga Raiz 6 mm', 'Seis milimetros de TPE con superficie antideslizante en las dos caras.', 'Fitness', '2026-05-27 10:59:00-06'),
    ('El camino de las nubes', 'El camino de las nubes (primera edicion)', 'Novela de viaje por el altiplano, ganadora del premio nacional.', 'Literatura', '2026-05-20 09:00:00-06'),
    ('El camino de las nubes', 'El camino de las nubes', 'Novela de viaje por el altiplano, ganadora del premio nacional.', 'Literatura', '2026-07-20 14:00:00-06'),
    ('Cuentos de la ceiba', 'Cuentos de la ceiba', 'Doce relatos breves sobre la memoria y el desarraigo.', 'Literatura', '2026-06-09 10:52:00-06'),
    ('Bases de datos distribuidas', 'Bases de datos distribuidas', 'Consistencia, particionado y replicacion, con ejercicios resueltos.', 'Tecnicos', '2026-06-14 10:03:00-06'),
    ('Serum de niacinamida 10%', 'Serum de niacinamida 10%', 'Serum ligero para textura y marcas, de uso nocturno.', 'Cuidado facial', '2026-06-19 10:45:00-06'),
    ('Protector solar mineral FPS 50', 'Protector solar mineral FPS 50', 'Filtro mineral sin fragancia, apto para piel sensible.', 'Cuidado facial', '2026-06-24 10:16:00-06'),
    ('Eau de parfum Bruma', 'Eau de parfum Bruma', 'Salida citrica, fondo amaderado, doce horas de fijacion.', 'Fragancias', '2026-07-01 10:57:00-06')
) AS v(clave, nombre, descripcion, hoja, fecha)
JOIN productos  p ON p.nombre = v.clave
JOIN categorias c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;

INSERT INTO productos_variantes_historial (id_producto_variante, nombre_variante, descripcion, fecha_creacion)
SELECT pv.id_producto_variante, v.nombre_variante, v.descripcion, v.fecha::timestamptz
FROM (VALUES
    ('Laptop Aurora 14', '16 GB / 512 GB', '16 GB', NULL, '2026-01-04 10:52:00-06'),
    ('Laptop Aurora 14', '16 GB / 512 GB', '16 GB / 512 GB', NULL, '2026-03-04 14:00:00-06'),
    ('Laptop Aurora 14', '32 GB / 1 TB', '32 GB / 1 TB', NULL, '2026-01-04 10:52:00-06'),
    ('Laptop Bastion 16', '32 GB / 1 TB', '32 GB / 1 TB', NULL, '2026-01-09 10:22:00-06'),
    ('Laptop Bastion 16', '64 GB / 2 TB', '64 GB / 2 TB', NULL, '2026-01-09 10:22:00-06'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', '8 GB / 256 GB', NULL, '2026-01-14 10:32:00-06'),
    ('Telefono Vela 7', '128 GB', '128 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '256 GB', '256 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '512 GB', '512 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Ceibo Lite', '64 GB', '64 GB', NULL, '2026-01-24 10:38:00-06'),
    ('Telefono Ceibo Lite', '128 GB', '128 GB', NULL, '2026-01-24 10:38:00-06'),
    ('Audifonos Sereno ANC', 'Negro', 'Negro', NULL, '2026-02-01 10:34:00-06'),
    ('Audifonos Sereno ANC', 'Arena', 'Arena', NULL, '2026-02-01 10:34:00-06'),
    ('Audifonos Brisa Sport', 'Verde lima', 'Verde lima', NULL, '2026-02-06 10:02:00-06'),
    ('Audifonos Brisa Sport', 'Gris', 'Gris', NULL, '2026-02-06 10:02:00-06'),
    ('Audifonos Estudio 900', 'Cable 3 m', 'Cable 3 m', NULL, '2026-02-11 10:26:00-06'),
    ('Monitor Horizonte 27', '75 Hz', '75 Hz', NULL, '2026-02-16 10:25:00-06'),
    ('Monitor Horizonte 27', '165 Hz', '165 Hz', NULL, '2026-02-16 10:25:00-06'),
    ('Monitor Panorama 34', '100 Hz', '100 Hz', NULL, '2026-02-21 10:15:00-06'),
    ('Cafetera Alba Espresso', '1.5 L', '1.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Cafetera Alba Espresso', '2.5 L', '2.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Juego de ollas Fuego 5 piezas', 'Estandar', 'Estandar', NULL, '2026-03-03 10:48:00-06'),
    ('Licuadora Torbellino 1200', '1.5 L', '1.5 L', NULL, '2026-03-08 10:15:00-06'),
    ('Licuadora Torbellino 1200', '2 L', '2 L', NULL, '2026-03-08 10:15:00-06'),
    ('Escritorio Roble 120', 'Natural', 'Natural', NULL, '2026-03-13 10:05:00-06'),
    ('Escritorio Roble 120', 'Nogal', 'Nogal', NULL, '2026-03-13 10:05:00-06'),
    ('Silla ergonomica Vertebra', 'Negra', 'Negra', NULL, '2026-03-18 10:04:00-06'),
    ('Silla ergonomica Vertebra', 'Gris', 'Gris', NULL, '2026-03-18 10:04:00-06'),
    ('Lampara de escritorio Faro', 'Blanca', 'Blanca', NULL, '2026-03-23 10:38:00-06'),
    ('Lampara de escritorio Faro', 'Negra', 'Negra', NULL, '2026-03-23 10:38:00-06'),
    ('Tira LED Aurora 5 m', 'Multicolor', 'Multicolor', NULL, '2026-03-28 10:05:00-06'),
    ('Camisa de lino manga larga', 'S azul', 'S azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'M azul', 'Mediana azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'M azul', 'M azul', NULL, '2026-03-12 14:00:00-06'),
    ('Camisa de lino manga larga', 'L blanca', 'L blanca', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa oxford clasica', 'M celeste', 'M celeste', NULL, '2026-04-10 10:16:00-06'),
    ('Camisa oxford clasica', 'L celeste', 'L celeste', NULL, '2026-04-10 10:16:00-06'),
    ('Pantalon chino resistente', '32 beige', '32 beige', NULL, '2026-04-15 10:25:00-06'),
    ('Pantalon chino resistente', '34 beige', '34 beige', NULL, '2026-04-15 10:25:00-06'),
    ('Pantalon chino resistente', '34 azul', '34 azul', NULL, '2026-04-15 10:25:00-06'),
    ('Zapato de cuero Senda', '40 cafe', '40 cafe', NULL, '2026-04-20 10:48:00-06'),
    ('Zapato de cuero Senda', '42 cafe', '42 cafe', NULL, '2026-04-20 10:48:00-06'),
    ('Zapato de cuero Senda', '42 negro', '42 negro', NULL, '2026-04-20 10:48:00-06'),
    ('Bota impermeable Cumbre', '41', '41', NULL, '2026-04-25 10:56:00-06'),
    ('Bota impermeable Cumbre', '43', '43', NULL, '2026-04-25 10:56:00-06'),
    ('Balon de futbol numero 5', 'Blanco', 'Blanco', NULL, '2026-04-06 08:00:00-06'),
    ('Balon de futbol numero 5', 'Naranja', 'Naranja', NULL, '2026-04-06 08:00:00-06'),
    ('Espinilleras Muralla', 'M', 'M', NULL, '2026-05-07 10:27:00-06'),
    ('Espinilleras Muralla', 'L', 'L', NULL, '2026-05-07 10:27:00-06'),
    ('Casco de ruta Aerodino', 'M blanco', 'M blanco', NULL, '2026-05-12 10:20:00-06'),
    ('Casco de ruta Aerodino', 'L negro', 'L negro', NULL, '2026-05-12 10:20:00-06'),
    ('Bomba de piso Piston', 'Estandar', 'Estandar', NULL, '2026-05-17 10:26:00-06'),
    ('Set de bandas elasticas', 'Set completo', 'Set completo', NULL, '2026-05-22 10:34:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Verde', 'Verde', NULL, '2026-05-27 10:59:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Morado', 'Morado', NULL, '2026-05-27 10:59:00-06'),
    ('El camino de las nubes', 'Pasta blanda', 'Pasta blanda', NULL, '2026-05-20 09:00:00-06'),
    ('El camino de las nubes', 'Pasta dura', 'Pasta dura', NULL, '2026-05-20 09:00:00-06'),
    ('Cuentos de la ceiba', 'Pasta blanda', 'Pasta blanda', NULL, '2026-06-09 10:52:00-06'),
    ('Bases de datos distribuidas', 'Pasta dura', 'Pasta dura', NULL, '2026-06-14 10:03:00-06'),
    ('Bases de datos distribuidas', 'Digital', 'Digital', NULL, '2026-06-14 10:03:00-06'),
    ('Serum de niacinamida 10%', '30 ml', '30 ml', NULL, '2026-06-19 10:45:00-06'),
    ('Serum de niacinamida 10%', '50 ml', '50 ml', NULL, '2026-06-19 10:45:00-06'),
    ('Protector solar mineral FPS 50', '50 ml', '50 ml', NULL, '2026-06-24 10:16:00-06'),
    ('Eau de parfum Bruma', '50 ml', '50 ml', NULL, '2026-07-01 10:57:00-06'),
    ('Eau de parfum Bruma', '100 ml', '100 ml', NULL, '2026-07-01 10:57:00-06')
) AS v(producto, variante, nombre_variante, descripcion, fecha)
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante;

-- ============================================================
-- Los valores: 185 de producto y 132 de variante
-- ============================================================
-- Siempre texto, y sin la unidad. tipo_dato dice como leerlo y el ETL lo
-- convierte al tipo real al llevarlo a Mongo. Una caracteristica de tipo
-- lista son varias filas con el mismo nombre.

INSERT INTO producto_caracteristica (id_producto, id_caracteristica, valor)
SELECT p.id_producto, k.id_caracteristica, v.valor
FROM (VALUES
    ('Laptop Aurora 14', 'Marca', 'Aurora'),
    ('Laptop Aurora 14', 'Modelo', 'A14-2026'),
    ('Laptop Aurora 14', 'Pais de origen', 'China'),
    ('Laptop Aurora 14', 'Garantia', '24'),
    ('Laptop Aurora 14', 'Peso', '1.28'),
    ('Laptop Aurora 14', 'Duracion de la bateria', '11.5'),
    ('Laptop Aurora 14', 'Contenido del paquete', 'Laptop'),
    ('Laptop Aurora 14', 'Contenido del paquete', 'Cargador USB-C'),
    ('Laptop Aurora 14', 'Contenido del paquete', 'Guia rapida'),
    ('Laptop Bastion 16', 'Marca', 'Bastion'),
    ('Laptop Bastion 16', 'Modelo', 'W16-Pro'),
    ('Laptop Bastion 16', 'Garantia', '36'),
    ('Laptop Bastion 16', 'Peso', '2.15'),
    ('Laptop Bastion 16', 'Duracion de la bateria', '7'),
    ('Laptop Bastion 16', 'Certificaciones', 'MIL-STD-810H'),
    ('Laptop Bastion 16', 'Certificaciones', 'Energy Star'),
    ('Laptop Bastion 16', 'Material principal', 'Aleacion de magnesio'),
    ('Laptop Nimbo 13', 'Marca', 'Nimbo'),
    ('Laptop Nimbo 13', 'Modelo', 'N13'),
    ('Laptop Nimbo 13', 'Pais de origen', 'Vietnam'),
    ('Laptop Nimbo 13', 'Garantia', '12'),
    ('Laptop Nimbo 13', 'Peso', '1.05'),
    ('Telefono Vela 7', 'Marca', 'Vela'),
    ('Telefono Vela 7', 'Modelo', 'V7'),
    ('Telefono Vela 7', 'Garantia', '12'),
    ('Telefono Vela 7', 'Peso', '0.19'),
    ('Telefono Vela 7', 'Impermeable', 'true'),
    ('Telefono Vela 7', 'Contenido del paquete', 'Telefono'),
    ('Telefono Vela 7', 'Contenido del paquete', 'Cable USB-C'),
    ('Telefono Vela 7', 'Contenido del paquete', 'Pin de bandeja'),
    ('Telefono Ceibo Lite', 'Marca', 'Ceibo'),
    ('Telefono Ceibo Lite', 'Modelo', 'Lite-3'),
    ('Telefono Ceibo Lite', 'Pais de origen', 'India'),
    ('Telefono Ceibo Lite', 'Garantia', '12'),
    ('Telefono Ceibo Lite', 'Duracion de la bateria', '48'),
    ('Audifonos Sereno ANC', 'Marca', 'Sereno'),
    ('Audifonos Sereno ANC', 'Modelo', 'ANC-2'),
    ('Audifonos Sereno ANC', 'Garantia', '24'),
    ('Audifonos Sereno ANC', 'Inalambrico', 'true'),
    ('Audifonos Sereno ANC', 'Duracion de la bateria', '38'),
    ('Audifonos Sereno ANC', 'Peso', '0.26'),
    ('Audifonos Sereno ANC', 'Contenido del paquete', 'Audifonos'),
    ('Audifonos Sereno ANC', 'Contenido del paquete', 'Estuche rigido'),
    ('Audifonos Sereno ANC', 'Contenido del paquete', 'Cable de 3.5 mm'),
    ('Audifonos Sereno ANC', 'Contenido del paquete', 'Cable USB-C'),
    ('Audifonos Brisa Sport', 'Marca', 'Brisa'),
    ('Audifonos Brisa Sport', 'Garantia', '12'),
    ('Audifonos Brisa Sport', 'Inalambrico', 'true'),
    ('Audifonos Brisa Sport', 'Impermeable', 'true'),
    ('Audifonos Brisa Sport', 'Duracion de la bateria', '9'),
    ('Audifonos Estudio 900', 'Marca', 'Estudio'),
    ('Audifonos Estudio 900', 'Modelo', '900'),
    ('Audifonos Estudio 900', 'Garantia', '24'),
    ('Audifonos Estudio 900', 'Inalambrico', 'false'),
    ('Audifonos Estudio 900', 'Peso', '0.31'),
    ('Monitor Horizonte 27', 'Marca', 'Horizonte'),
    ('Monitor Horizonte 27', 'Modelo', 'H27'),
    ('Monitor Horizonte 27', 'Garantia', '36'),
    ('Monitor Horizonte 27', 'Peso', '5.4'),
    ('Monitor Horizonte 27', 'Certificaciones', 'TUV Eye Comfort'),
    ('Monitor Horizonte 27', 'Certificaciones', 'Energy Star'),
    ('Monitor Panorama 34', 'Marca', 'Panorama'),
    ('Monitor Panorama 34', 'Modelo', 'UW34'),
    ('Monitor Panorama 34', 'Garantia', '24'),
    ('Monitor Panorama 34', 'Peso', '7.9'),
    ('Monitor Panorama 34', 'Material principal', 'Plastico ABS'),
    ('Cafetera Alba Espresso', 'Marca', 'Alba'),
    ('Cafetera Alba Espresso', 'Material principal', 'Acero inoxidable'),
    ('Cafetera Alba Espresso', 'Potencia', '1350'),
    ('Cafetera Alba Espresso', 'Garantia', '24'),
    ('Cafetera Alba Espresso', 'Contenido del paquete', 'Cafetera'),
    ('Cafetera Alba Espresso', 'Contenido del paquete', 'Portafiltro doble'),
    ('Cafetera Alba Espresso', 'Contenido del paquete', 'Cuchara medidora'),
    ('Juego de ollas Fuego 5 piezas', 'Marca', 'Fuego'),
    ('Juego de ollas Fuego 5 piezas', 'Material principal', 'Acero tricapa'),
    ('Juego de ollas Fuego 5 piezas', 'Apto para lavavajillas', 'true'),
    ('Juego de ollas Fuego 5 piezas', 'Garantia', '120'),
    ('Juego de ollas Fuego 5 piezas', 'Peso', '6.2'),
    ('Licuadora Torbellino 1200', 'Marca', 'Torbellino'),
    ('Licuadora Torbellino 1200', 'Potencia', '1200'),
    ('Licuadora Torbellino 1200', 'Garantia', '12'),
    ('Licuadora Torbellino 1200', 'Apto para lavavajillas', 'true'),
    ('Licuadora Torbellino 1200', 'Material principal', 'Vidrio'),
    ('Escritorio Roble 120', 'Marca', 'Roble'),
    ('Escritorio Roble 120', 'Material principal', 'Madera de pino'),
    ('Escritorio Roble 120', 'Requiere ensamblaje', 'true'),
    ('Escritorio Roble 120', 'Peso', '18.5'),
    ('Escritorio Roble 120', 'Garantia', '24'),
    ('Escritorio Roble 120', 'Contenido del paquete', 'Tablero'),
    ('Escritorio Roble 120', 'Contenido del paquete', 'Patas'),
    ('Escritorio Roble 120', 'Contenido del paquete', 'Tornilleria'),
    ('Escritorio Roble 120', 'Contenido del paquete', 'Llave allen'),
    ('Silla ergonomica Vertebra', 'Marca', 'Vertebra'),
    ('Silla ergonomica Vertebra', 'Material principal', 'Malla y nylon'),
    ('Silla ergonomica Vertebra', 'Requiere ensamblaje', 'true'),
    ('Silla ergonomica Vertebra', 'Garantia', '60'),
    ('Silla ergonomica Vertebra', 'Peso', '14'),
    ('Lampara de escritorio Faro', 'Marca', 'Faro'),
    ('Lampara de escritorio Faro', 'Potencia', '9'),
    ('Lampara de escritorio Faro', 'Garantia', '24'),
    ('Lampara de escritorio Faro', 'Material principal', 'Aluminio'),
    ('Tira LED Aurora 5 m', 'Marca', 'Aurora'),
    ('Tira LED Aurora 5 m', 'Potencia', '24'),
    ('Tira LED Aurora 5 m', 'Inalambrico', 'true'),
    ('Tira LED Aurora 5 m', 'Garantia', '12'),
    ('Tira LED Aurora 5 m', 'Certificaciones', 'CE'),
    ('Tira LED Aurora 5 m', 'Certificaciones', 'RoHS'),
    ('Camisa de lino manga larga', 'Marca', 'Telar'),
    ('Camisa de lino manga larga', 'Material principal', 'Lino'),
    ('Camisa de lino manga larga', 'Pais de origen', 'Portugal'),
    ('Camisa oxford clasica', 'Marca', 'Telar'),
    ('Camisa oxford clasica', 'Material principal', 'Algodon'),
    ('Camisa oxford clasica', 'Origen del algodon', 'Peru'),
    ('Camisa oxford clasica', 'Certificaciones', 'OEKO-TEX Standard 100'),
    ('Pantalon chino resistente', 'Marca', 'Rumbo'),
    ('Pantalon chino resistente', 'Material principal', 'Algodon y elastano'),
    ('Pantalon chino resistente', 'Pais de origen', 'Guatemala'),
    ('Zapato de cuero Senda', 'Marca', 'Senda'),
    ('Zapato de cuero Senda', 'Material principal', 'Cuero vacuno'),
    ('Zapato de cuero Senda', 'Pais de origen', 'Leon'),
    ('Zapato de cuero Senda', 'Peso', '0.82'),
    ('Bota impermeable Cumbre', 'Marca', 'Cumbre'),
    ('Bota impermeable Cumbre', 'Material principal', 'Nobuck'),
    ('Bota impermeable Cumbre', 'Impermeable', 'true'),
    ('Bota impermeable Cumbre', 'Garantia', '12'),
    ('Bota impermeable Cumbre', 'Peso', '1.15'),
    ('Balon de futbol numero 5', 'Marca', 'Portero'),
    ('Balon de futbol numero 5', 'Material principal', 'Poliuretano'),
    ('Balon de futbol numero 5', 'Certificaciones', 'FIFA Basic'),
    ('Balon de futbol numero 5', 'Peso', '0.43'),
    ('Espinilleras Muralla', 'Marca', 'Muralla'),
    ('Espinilleras Muralla', 'Material principal', 'Polipropileno'),
    ('Espinilleras Muralla', 'Peso', '0.16'),
    ('Casco de ruta Aerodino', 'Marca', 'Aerodino'),
    ('Casco de ruta Aerodino', 'Material principal', 'Policarbonato y EPS'),
    ('Casco de ruta Aerodino', 'Certificaciones', 'CPSC'),
    ('Casco de ruta Aerodino', 'Certificaciones', 'EN 1078'),
    ('Casco de ruta Aerodino', 'Peso', '0.27'),
    ('Casco de ruta Aerodino', 'Garantia', '24'),
    ('Bomba de piso Piston', 'Marca', 'Piston'),
    ('Bomba de piso Piston', 'Material principal', 'Acero'),
    ('Bomba de piso Piston', 'Garantia', '24'),
    ('Bomba de piso Piston', 'Contenido del paquete', 'Bomba'),
    ('Bomba de piso Piston', 'Contenido del paquete', 'Adaptador de balon'),
    ('Bomba de piso Piston', 'Contenido del paquete', 'Aguja'),
    ('Set de bandas elasticas', 'Marca', 'Tension'),
    ('Set de bandas elasticas', 'Material principal', 'Latex natural'),
    ('Set de bandas elasticas', 'Nivel de resistencia', 'Progresiva 5 a 25 kg'),
    ('Set de bandas elasticas', 'Contenido del paquete', '5 bandas'),
    ('Set de bandas elasticas', 'Contenido del paquete', 'Bolsa de malla'),
    ('Set de bandas elasticas', 'Contenido del paquete', 'Guia de ejercicios'),
    ('Tapete de yoga Raiz 6 mm', 'Marca', 'Raiz'),
    ('Tapete de yoga Raiz 6 mm', 'Material principal', 'TPE'),
    ('Tapete de yoga Raiz 6 mm', 'Peso', '1.1'),
    ('El camino de las nubes', 'Autor', 'Renata Solis'),
    ('El camino de las nubes', 'Editorial', 'Piedra Santa'),
    ('El camino de las nubes', 'Paginas', '312'),
    ('El camino de las nubes', 'Idioma', 'Espanol'),
    ('El camino de las nubes', 'Anio de publicacion', '2024'),
    ('Cuentos de la ceiba', 'Autor', 'Tomas Arriaga'),
    ('Cuentos de la ceiba', 'Editorial', 'Cadejo'),
    ('Cuentos de la ceiba', 'Paginas', '186'),
    ('Cuentos de la ceiba', 'Idioma', 'Espanol'),
    ('Cuentos de la ceiba', 'Anio de publicacion', '2022'),
    ('Bases de datos distribuidas', 'Autor', 'H. Ortega'),
    ('Bases de datos distribuidas', 'Editorial', 'Tecnos'),
    ('Bases de datos distribuidas', 'Paginas', '540'),
    ('Bases de datos distribuidas', 'Idioma', 'Espanol'),
    ('Bases de datos distribuidas', 'Anio de publicacion', '2025'),
    ('Serum de niacinamida 10%', 'Marca', 'Clara'),
    ('Serum de niacinamida 10%', 'Tipo de piel', 'Mixta a grasa'),
    ('Serum de niacinamida 10%', 'Ingredientes destacados', 'Niacinamida'),
    ('Serum de niacinamida 10%', 'Ingredientes destacados', 'Zinc PCA'),
    ('Serum de niacinamida 10%', 'Pais de origen', 'Corea del Sur'),
    ('Protector solar mineral FPS 50', 'Marca', 'Clara'),
    ('Protector solar mineral FPS 50', 'Tipo de piel', 'Sensible'),
    ('Protector solar mineral FPS 50', 'Ingredientes destacados', 'Oxido de zinc'),
    ('Protector solar mineral FPS 50', 'Ingredientes destacados', 'Vitamina E'),
    ('Protector solar mineral FPS 50', 'Certificaciones', 'Dermatologicamente probado'),
    ('Eau de parfum Bruma', 'Marca', 'Bruma'),
    ('Eau de parfum Bruma', 'Tipo de fragancia', 'Amaderada citrica'),
    ('Eau de parfum Bruma', 'Pais de origen', 'Francia'),
    ('Eau de parfum Bruma', 'Ingredientes destacados', 'Bergamota'),
    ('Eau de parfum Bruma', 'Ingredientes destacados', 'Cedro'),
    ('Eau de parfum Bruma', 'Ingredientes destacados', 'Vetiver')
) AS v(producto, caracteristica, valor)
JOIN productos      p ON p.nombre = v.producto
JOIN caracteristica k ON k.nombre = v.caracteristica;

INSERT INTO producto_variante_caracteristica_variante (id_producto_variante, id_caracteristica_variante, valor)
SELECT pv.id_producto_variante, k.id_caracteristica, v.valor
FROM (VALUES
    ('Laptop Aurora 14', '16 GB / 512 GB', 'Memoria RAM', '16'),
    ('Laptop Aurora 14', '16 GB / 512 GB', 'Almacenamiento', '512'),
    ('Laptop Aurora 14', '16 GB / 512 GB', 'Tamano de pantalla', '14'),
    ('Laptop Aurora 14', '16 GB / 512 GB', 'Color', 'Gris grafito'),
    ('Laptop Aurora 14', '32 GB / 1 TB', 'Memoria RAM', '32'),
    ('Laptop Aurora 14', '32 GB / 1 TB', 'Almacenamiento', '1024'),
    ('Laptop Aurora 14', '32 GB / 1 TB', 'Tamano de pantalla', '14'),
    ('Laptop Aurora 14', '32 GB / 1 TB', 'Color', 'Gris grafito'),
    ('Laptop Aurora 14', '32 GB / 1 TB', 'Acabado', 'Mate'),
    ('Laptop Bastion 16', '32 GB / 1 TB', 'Memoria RAM', '32'),
    ('Laptop Bastion 16', '32 GB / 1 TB', 'Almacenamiento', '1024'),
    ('Laptop Bastion 16', '32 GB / 1 TB', 'Tamano de pantalla', '16'),
    ('Laptop Bastion 16', '32 GB / 1 TB', 'Color', 'Negro'),
    ('Laptop Bastion 16', '64 GB / 2 TB', 'Memoria RAM', '64'),
    ('Laptop Bastion 16', '64 GB / 2 TB', 'Almacenamiento', '2048'),
    ('Laptop Bastion 16', '64 GB / 2 TB', 'Tamano de pantalla', '16'),
    ('Laptop Bastion 16', '64 GB / 2 TB', 'Color', 'Negro'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', 'Memoria RAM', '8'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', 'Almacenamiento', '256'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', 'Tamano de pantalla', '13.3'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', 'Color', 'Plata'),
    ('Telefono Vela 7', '128 GB', 'Almacenamiento', '128'),
    ('Telefono Vela 7', '128 GB', 'Color', 'Azul medianoche'),
    ('Telefono Vela 7', '128 GB', 'Tamano de pantalla', '6.4'),
    ('Telefono Vela 7', '256 GB', 'Almacenamiento', '256'),
    ('Telefono Vela 7', '256 GB', 'Color', 'Azul medianoche'),
    ('Telefono Vela 7', '256 GB', 'Tamano de pantalla', '6.4'),
    ('Telefono Vela 7', '512 GB', 'Almacenamiento', '512'),
    ('Telefono Vela 7', '512 GB', 'Color', 'Grafito'),
    ('Telefono Vela 7', '512 GB', 'Tamano de pantalla', '6.4'),
    ('Telefono Ceibo Lite', '64 GB', 'Almacenamiento', '64'),
    ('Telefono Ceibo Lite', '64 GB', 'Color', 'Verde'),
    ('Telefono Ceibo Lite', '64 GB', 'Tamano de pantalla', '6.1'),
    ('Telefono Ceibo Lite', '128 GB', 'Almacenamiento', '128'),
    ('Telefono Ceibo Lite', '128 GB', 'Color', 'Negro'),
    ('Telefono Ceibo Lite', '128 GB', 'Tamano de pantalla', '6.1'),
    ('Audifonos Sereno ANC', 'Negro', 'Color', 'Negro'),
    ('Audifonos Sereno ANC', 'Negro', 'Acabado', 'Mate'),
    ('Audifonos Sereno ANC', 'Arena', 'Color', 'Arena'),
    ('Audifonos Sereno ANC', 'Arena', 'Acabado', 'Mate'),
    ('Audifonos Brisa Sport', 'Verde lima', 'Color', 'Verde lima'),
    ('Audifonos Brisa Sport', 'Gris', 'Color', 'Gris'),
    ('Audifonos Estudio 900', 'Cable 3 m', 'Color', 'Negro'),
    ('Audifonos Estudio 900', 'Cable 3 m', 'Longitud del cable', '3'),
    ('Monitor Horizonte 27', '75 Hz', 'Tamano de pantalla', '27'),
    ('Monitor Horizonte 27', '75 Hz', 'Tasa de refresco', '75'),
    ('Monitor Horizonte 27', '75 Hz', 'Color', 'Negro'),
    ('Monitor Horizonte 27', '165 Hz', 'Tamano de pantalla', '27'),
    ('Monitor Horizonte 27', '165 Hz', 'Tasa de refresco', '165'),
    ('Monitor Horizonte 27', '165 Hz', 'Color', 'Negro'),
    ('Monitor Horizonte 27', '165 Hz', 'Acabado', 'Antirreflejo'),
    ('Monitor Panorama 34', '100 Hz', 'Tamano de pantalla', '34'),
    ('Monitor Panorama 34', '100 Hz', 'Tasa de refresco', '100'),
    ('Monitor Panorama 34', '100 Hz', 'Color', 'Grafito'),
    ('Cafetera Alba Espresso', '1.5 L', 'Capacidad', '1.5'),
    ('Cafetera Alba Espresso', '1.5 L', 'Color', 'Acero'),
    ('Cafetera Alba Espresso', '1.5 L', 'Acabado', 'Cepillado'),
    ('Cafetera Alba Espresso', '2.5 L', 'Capacidad', '2.5'),
    ('Cafetera Alba Espresso', '2.5 L', 'Color', 'Negro'),
    ('Juego de ollas Fuego 5 piezas', 'Estandar', 'Color', 'Acero'),
    ('Juego de ollas Fuego 5 piezas', 'Estandar', 'Acabado', 'Pulido'),
    ('Licuadora Torbellino 1200', '1.5 L', 'Capacidad', '1.5'),
    ('Licuadora Torbellino 1200', '1.5 L', 'Color', 'Rojo'),
    ('Licuadora Torbellino 1200', '2 L', 'Capacidad', '2'),
    ('Licuadora Torbellino 1200', '2 L', 'Color', 'Negro'),
    ('Escritorio Roble 120', 'Natural', 'Color', 'Natural'),
    ('Escritorio Roble 120', 'Natural', 'Acabado', 'Barnizado'),
    ('Escritorio Roble 120', 'Nogal', 'Color', 'Nogal'),
    ('Escritorio Roble 120', 'Nogal', 'Acabado', 'Barnizado'),
    ('Silla ergonomica Vertebra', 'Negra', 'Color', 'Negro'),
    ('Silla ergonomica Vertebra', 'Gris', 'Color', 'Gris'),
    ('Lampara de escritorio Faro', 'Blanca', 'Color', 'Blanco'),
    ('Lampara de escritorio Faro', 'Blanca', 'Longitud del cable', '1.8'),
    ('Lampara de escritorio Faro', 'Negra', 'Color', 'Negro'),
    ('Lampara de escritorio Faro', 'Negra', 'Longitud del cable', '1.8'),
    ('Tira LED Aurora 5 m', 'Multicolor', 'Color', 'Multicolor'),
    ('Tira LED Aurora 5 m', 'Multicolor', 'Longitud del cable', '5'),
    ('Camisa de lino manga larga', 'S azul', 'Talla', 'S'),
    ('Camisa de lino manga larga', 'S azul', 'Color', 'Azul'),
    ('Camisa de lino manga larga', 'M azul', 'Talla', 'M'),
    ('Camisa de lino manga larga', 'M azul', 'Color', 'Azul'),
    ('Camisa de lino manga larga', 'L blanca', 'Talla', 'L'),
    ('Camisa de lino manga larga', 'L blanca', 'Color', 'Blanco'),
    ('Camisa oxford clasica', 'M celeste', 'Talla', 'M'),
    ('Camisa oxford clasica', 'M celeste', 'Color', 'Celeste'),
    ('Camisa oxford clasica', 'M celeste', 'Acabado', 'Lavado suave'),
    ('Camisa oxford clasica', 'L celeste', 'Talla', 'L'),
    ('Camisa oxford clasica', 'L celeste', 'Color', 'Celeste'),
    ('Pantalon chino resistente', '32 beige', 'Talla', '32'),
    ('Pantalon chino resistente', '32 beige', 'Color', 'Beige'),
    ('Pantalon chino resistente', '34 beige', 'Talla', '34'),
    ('Pantalon chino resistente', '34 beige', 'Color', 'Beige'),
    ('Pantalon chino resistente', '34 azul', 'Talla', '34'),
    ('Pantalon chino resistente', '34 azul', 'Color', 'Azul marino'),
    ('Zapato de cuero Senda', '40 cafe', 'Numero de calzado', '40'),
    ('Zapato de cuero Senda', '40 cafe', 'Color', 'Cafe'),
    ('Zapato de cuero Senda', '42 cafe', 'Numero de calzado', '42'),
    ('Zapato de cuero Senda', '42 cafe', 'Color', 'Cafe'),
    ('Zapato de cuero Senda', '42 negro', 'Numero de calzado', '42'),
    ('Zapato de cuero Senda', '42 negro', 'Color', 'Negro'),
    ('Zapato de cuero Senda', '42 negro', 'Acabado', 'Pulido'),
    ('Bota impermeable Cumbre', '41', 'Numero de calzado', '41'),
    ('Bota impermeable Cumbre', '41', 'Color', 'Marron'),
    ('Bota impermeable Cumbre', '43', 'Numero de calzado', '43'),
    ('Bota impermeable Cumbre', '43', 'Color', 'Marron'),
    ('Balon de futbol numero 5', 'Blanco', 'Talla', '5'),
    ('Balon de futbol numero 5', 'Blanco', 'Color', 'Blanco'),
    ('Balon de futbol numero 5', 'Naranja', 'Talla', '5'),
    ('Balon de futbol numero 5', 'Naranja', 'Color', 'Naranja'),
    ('Espinilleras Muralla', 'M', 'Talla', 'M'),
    ('Espinilleras Muralla', 'M', 'Color', 'Negro'),
    ('Espinilleras Muralla', 'L', 'Talla', 'L'),
    ('Espinilleras Muralla', 'L', 'Color', 'Negro'),
    ('Casco de ruta Aerodino', 'M blanco', 'Talla', 'M'),
    ('Casco de ruta Aerodino', 'M blanco', 'Color', 'Blanco'),
    ('Casco de ruta Aerodino', 'L negro', 'Talla', 'L'),
    ('Casco de ruta Aerodino', 'L negro', 'Color', 'Negro'),
    ('Casco de ruta Aerodino', 'L negro', 'Acabado', 'Mate'),
    ('Bomba de piso Piston', 'Estandar', 'Color', 'Negro'),
    ('Set de bandas elasticas', 'Set completo', 'Color', 'Multicolor'),
    ('Tapete de yoga Raiz 6 mm', 'Verde', 'Color', 'Verde'),
    ('Tapete de yoga Raiz 6 mm', 'Morado', 'Color', 'Morado'),
    ('El camino de las nubes', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('El camino de las nubes', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Cuentos de la ceiba', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('Bases de datos distribuidas', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Bases de datos distribuidas', 'Digital', 'Formato', 'PDF con DRM'),
    ('Serum de niacinamida 10%', '30 ml', 'Volumen', '30'),
    ('Serum de niacinamida 10%', '50 ml', 'Volumen', '50'),
    ('Protector solar mineral FPS 50', '50 ml', 'Volumen', '50'),
    ('Eau de parfum Bruma', '50 ml', 'Volumen', '50'),
    ('Eau de parfum Bruma', '100 ml', 'Volumen', '100')
) AS v(producto, variante, caracteristica, valor)
JOIN productos            p  ON p.nombre = v.producto
JOIN productos_variantes  pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
JOIN caracteristica_variante k ON k.nombre = v.caracteristica;

-- ============================================================
-- Imagenes
-- ============================================================
-- La URL se guarda una vez y se apunta desde cada variante que la usa. Son
-- del catalogo, no del vendedor: los cinco que venden la misma laptop
-- ensenan las mismas fotos, y eso es lo que hace util un catalogo comun.

INSERT INTO imagen_producto (imagen_producto_url) VALUES
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Laptop-hard-drive-exposed.jpg/960px-Laptop-hard-drive-exposed.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/Smartphone_icon.png/960px-Smartphone_icon.png'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8e/Sennheiser_HD_650.jpg/960px-Sennheiser_HD_650.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Blue_Business_Shirt.jpg/960px-Blue_Business_Shirt.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Espresso_machine_at_work.jpg/960px-Espresso_machine_at_work.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/d3/Soccerball.svg/960px-Soccerball.svg.png'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Open_book_nae_02.svg/960px-Open_book_nae_02.svg.png');

INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden)
SELECT im.id_imagen_producto, pv.id_producto_variante, v.orden
FROM (VALUES
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Laptop-hard-drive-exposed.jpg/960px-Laptop-hard-drive-exposed.jpg', 'Laptop Aurora 14', '16 GB / 512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Laptop-hard-drive-exposed.jpg/960px-Laptop-hard-drive-exposed.jpg', 'Laptop Aurora 14', '32 GB / 1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/Smartphone_icon.png/960px-Smartphone_icon.png', 'Telefono Vela 7', '128 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/Smartphone_icon.png/960px-Smartphone_icon.png', 'Telefono Vela 7', '256 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/60/Smartphone_icon.png/960px-Smartphone_icon.png', 'Telefono Vela 7', '512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8e/Sennheiser_HD_650.jpg/960px-Sennheiser_HD_650.jpg', 'Audifonos Sereno ANC', 'Negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8e/Sennheiser_HD_650.jpg/960px-Sennheiser_HD_650.jpg', 'Audifonos Sereno ANC', 'Arena', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Blue_Business_Shirt.jpg/960px-Blue_Business_Shirt.jpg', 'Camisa de lino manga larga', 'S azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Blue_Business_Shirt.jpg/960px-Blue_Business_Shirt.jpg', 'Camisa de lino manga larga', 'M azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Blue_Business_Shirt.jpg/960px-Blue_Business_Shirt.jpg', 'Camisa de lino manga larga', 'L blanca', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Espresso_machine_at_work.jpg/960px-Espresso_machine_at_work.jpg', 'Cafetera Alba Espresso', '1.5 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Espresso_machine_at_work.jpg/960px-Espresso_machine_at_work.jpg', 'Cafetera Alba Espresso', '2.5 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/d3/Soccerball.svg/960px-Soccerball.svg.png', 'Balon de futbol numero 5', 'Blanco', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/d3/Soccerball.svg/960px-Soccerball.svg.png', 'Balon de futbol numero 5', 'Naranja', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Open_book_nae_02.svg/960px-Open_book_nae_02.svg.png', 'El camino de las nubes', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Open_book_nae_02.svg/960px-Open_book_nae_02.svg.png', 'El camino de las nubes', 'Pasta dura', 1)
) AS v(url, producto, variante, orden)
JOIN imagen_producto     im ON im.imagen_producto_url = v.url
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante;

-- ============================================================
-- Las ofertas: 168 sobre 63 variantes
-- ============================================================
-- Aqui vive el precio y el stock. Una fila por vendedor y variante, que es
-- lo que garantiza el UNIQUE del 005.
--
-- La tienda tiene oferta de todas: por eso ningun producto se queda sin
-- precio que ensenar. Los otros cuatro entran a veces si y a veces no, con
-- una semilla fija, asi que hay variantes con un solo precio y otras con
-- cinco. Alguna sale pausada o en cero a proposito: si todas estuvieran
-- activas y con stock, la pantalla nunca ensenaria los casos que si van a
-- pasar de verdad.

INSERT INTO oferta (id_producto_variante, id_usuario, precio, stock, id_estado_oferta, fecha_creacion, fecha_actualizacion)
SELECT pv.id_producto_variante, u.id_usuario, v.precio, v.stock, eo.id_estado_oferta, v.fecha::timestamptz, v.fecha::timestamptz
FROM (VALUES
    ('tienda@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6200.00, 10, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6343.00, 4, 'activa', '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8804.00, 21, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 9226.00, 20, 'pausada', '2026-01-04 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8919.00, 25, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 9456.00, 4, 'activa', '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9400.00, 31, 'activa', '2026-01-09 10:22:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9708.00, 22, 'activa', '2026-01-09 10:22:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 8842.00, 10, 'pausada', '2026-01-09 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 14570.00, 15, 'activa', '2026-01-09 10:22:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 13803.00, 15, 'pausada', '2026-01-09 10:22:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 15520.00, 0, 'activa', '2026-01-09 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 4100.00, 22, 'activa', '2026-01-14 10:32:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 4029.00, 15, 'activa', '2026-01-14 10:32:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 3856.00, 8, 'activa', '2026-01-14 10:32:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '128 GB', 5300.00, 14, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Vela 7', '128 GB', 5264.00, 2, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Vela 7', '128 GB', 5556.00, 22, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '128 GB', 5324.00, 15, 'activa', '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '256 GB', 6254.00, 12, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '256 GB', 6351.00, 23, 'activa', '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '512 GB', 7208.00, 12, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Vela 7', '512 GB', 7319.00, 25, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Vela 7', '512 GB', 7022.00, 22, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Vela 7', '512 GB', 6759.00, 3, 'activa', '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1850.00, 26, 'activa', '2026-01-24 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1891.00, 8, 'activa', '2026-01-24 10:38:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2257.00, 5, 'activa', '2026-01-24 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2403.00, 23, 'activa', '2026-01-24 10:38:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1450.00, 39, 'activa', '2026-02-01 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1337.00, 23, 'activa', '2026-02-01 10:34:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Arena', 1450.00, 33, 'activa', '2026-02-01 10:34:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 620.00, 0, 'activa', '2026-02-06 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 636.00, 21, 'activa', '2026-02-06 10:02:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Gris', 620.00, 24, 'activa', '2026-02-06 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 571.00, 13, 'activa', '2026-02-06 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Brisa Sport', 'Gris', 653.00, 21, 'activa', '2026-02-06 10:02:00-06'),
    ('tienda@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2100.00, 6, 'activa', '2026-02-11 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 1950.00, 1, 'activa', '2026-02-11 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2209.00, 11, 'activa', '2026-02-11 10:26:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2750.00, 20, 'activa', '2026-02-16 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2690.00, 5, 'activa', '2026-02-16 10:25:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3658.00, 26, 'activa', '2026-02-16 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3367.00, 12, 'activa', '2026-02-16 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3416.00, 21, 'activa', '2026-02-16 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3742.00, 18, 'activa', '2026-02-16 10:25:00-06'),
    ('tienda@mesh.com', 'Monitor Panorama 34', '100 Hz', 5900.00, 34, 'activa', '2026-02-21 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Panorama 34', '100 Hz', 5667.00, 18, 'activa', '2026-02-21 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Panorama 34', '100 Hz', 5765.00, 16, 'activa', '2026-02-21 10:15:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1980.00, 11, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1969.00, 24, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1852.00, 4, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 2001.00, 14, 'activa', '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2455.00, 4, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2296.00, 7, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2530.00, 2, 'activa', '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1240.00, 31, 'activa', '2026-03-03 10:48:00-06'),
    ('ventas.poniente@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1327.00, 24, 'activa', '2026-03-03 10:48:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 890.00, 24, 'activa', '2026-03-08 10:15:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1023.00, 0, 'activa', '2026-03-08 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1061.00, 10, 'activa', '2026-03-08 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1023.00, 8, 'activa', '2026-03-08 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1098.00, 10, 'activa', '2026-03-08 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1068.00, 19, 'activa', '2026-03-08 10:15:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Natural', 2350.00, 29, 'activa', '2026-03-13 10:05:00-06'),
    ('ventas.norte@mesh.com', 'Escritorio Roble 120', 'Natural', 2208.00, 23, 'activa', '2026-03-13 10:05:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Natural', 2396.00, 23, 'pausada', '2026-03-13 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Escritorio Roble 120', 'Natural', 2339.00, 11, 'activa', '2026-03-13 10:05:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Nogal', 2350.00, 23, 'activa', '2026-03-13 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Escritorio Roble 120', 'Nogal', 2402.00, 8, 'pausada', '2026-03-13 10:05:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3100.00, 11, 'activa', '2026-03-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3202.00, 21, 'activa', '2026-03-18 10:04:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3100.00, 25, 'activa', '2026-03-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3215.00, 18, 'activa', '2026-03-18 10:04:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 480.00, 29, 'activa', '2026-03-23 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 477.00, 22, 'activa', '2026-03-23 10:38:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra', 480.00, 29, 'activa', '2026-03-23 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de escritorio Faro', 'Negra', 481.00, 2, 'activa', '2026-03-23 10:38:00-06'),
    ('tienda@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 320.00, 13, 'activa', '2026-03-28 10:05:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'S azul', 340.00, 0, 'activa', '2026-01-12 09:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de lino manga larga', 'S azul', 363.00, 1, 'activa', '2026-01-12 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de lino manga larga', 'S azul', 325.00, 1, 'activa', '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'M azul', 340.00, 26, 'activa', '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'L blanca', 340.00, 27, 'activa', '2026-01-12 09:00:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de lino manga larga', 'L blanca', 333.00, 10, 'activa', '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'M celeste', 290.00, 40, 'activa', '2026-04-10 10:16:00-06'),
    ('ventas.sur@mesh.com', 'Camisa oxford clasica', 'M celeste', 297.00, 0, 'activa', '2026-04-10 10:16:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'L celeste', 290.00, 20, 'activa', '2026-04-10 10:16:00-06'),
    ('ventas.norte@mesh.com', 'Camisa oxford clasica', 'L celeste', 308.00, 10, 'pausada', '2026-04-10 10:16:00-06'),
    ('ventas.sur@mesh.com', 'Camisa oxford clasica', 'L celeste', 269.00, 14, 'activa', '2026-04-10 10:16:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa oxford clasica', 'L celeste', 290.00, 21, 'activa', '2026-04-10 10:16:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 420.00, 0, 'activa', '2026-04-15 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon chino resistente', '32 beige', 441.00, 7, 'activa', '2026-04-15 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '32 beige', 434.00, 8, 'activa', '2026-04-15 10:25:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 beige', 420.00, 0, 'activa', '2026-04-15 10:25:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 azul', 420.00, 33, 'activa', '2026-04-15 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 azul', 387.00, 23, 'activa', '2026-04-15 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon chino resistente', '34 azul', 392.00, 3, 'activa', '2026-04-15 10:25:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '40 cafe', 780.00, 36, 'activa', '2026-04-20 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '40 cafe', 772.00, 11, 'activa', '2026-04-20 10:48:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 cafe', 780.00, 27, 'activa', '2026-04-20 10:48:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '42 cafe', 773.00, 0, 'activa', '2026-04-20 10:48:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 cafe', 832.00, 17, 'activa', '2026-04-20 10:48:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 negro', 780.00, 36, 'activa', '2026-04-20 10:48:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 negro', 805.00, 5, 'activa', '2026-04-20 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '42 negro', 793.00, 1, 'activa', '2026-04-20 10:48:00-06'),
    ('ventas.poniente@mesh.com', 'Zapato de cuero Senda', '42 negro', 793.00, 19, 'activa', '2026-04-20 10:48:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '41', 1150.00, 10, 'activa', '2026-04-25 10:56:00-06'),
    ('ventas.sur@mesh.com', 'Bota impermeable Cumbre', '41', 1063.00, 0, 'activa', '2026-04-25 10:56:00-06'),
    ('ventas.poniente@mesh.com', 'Bota impermeable Cumbre', '41', 1194.00, 3, 'activa', '2026-04-25 10:56:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '43', 1150.00, 34, 'activa', '2026-04-25 10:56:00-06'),
    ('ventas.sur@mesh.com', 'Bota impermeable Cumbre', '43', 1132.00, 13, 'activa', '2026-04-25 10:56:00-06'),
    ('ventas.oriente@mesh.com', 'Bota impermeable Cumbre', '43', 1183.00, 0, 'activa', '2026-04-25 10:56:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 260.00, 0, 'activa', '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Naranja', 260.00, 0, 'activa', '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'M', 145.00, 4, 'activa', '2026-05-07 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Espinilleras Muralla', 'M', 156.00, 0, 'activa', '2026-05-07 10:27:00-06'),
    ('ventas.poniente@mesh.com', 'Espinilleras Muralla', 'M', 134.00, 2, 'activa', '2026-05-07 10:27:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'L', 145.00, 4, 'activa', '2026-05-07 10:27:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'L', 138.00, 1, 'activa', '2026-05-07 10:27:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'L', 137.00, 1, 'activa', '2026-05-07 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Espinilleras Muralla', 'L', 137.00, 2, 'activa', '2026-05-07 10:27:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 690.00, 34, 'activa', '2026-05-12 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 690.00, 14, 'activa', '2026-05-12 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 736.00, 24, 'activa', '2026-05-12 10:20:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'L negro', 690.00, 31, 'activa', '2026-05-12 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Casco de ruta Aerodino', 'L negro', 688.00, 0, 'activa', '2026-05-12 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Casco de ruta Aerodino', 'L negro', 713.00, 0, 'activa', '2026-05-12 10:20:00-06'),
    ('tienda@mesh.com', 'Bomba de piso Piston', 'Estandar', 310.00, 3, 'activa', '2026-05-17 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Bomba de piso Piston', 'Estandar', 315.00, 5, 'activa', '2026-05-17 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Bomba de piso Piston', 'Estandar', 294.00, 11, 'activa', '2026-05-17 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Bomba de piso Piston', 'Estandar', 288.00, 10, 'activa', '2026-05-17 10:26:00-06'),
    ('tienda@mesh.com', 'Set de bandas elasticas', 'Set completo', 195.00, 32, 'activa', '2026-05-22 10:34:00-06'),
    ('ventas.norte@mesh.com', 'Set de bandas elasticas', 'Set completo', 183.00, 19, 'activa', '2026-05-22 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Set de bandas elasticas', 'Set completo', 204.00, 6, 'activa', '2026-05-22 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Set de bandas elasticas', 'Set completo', 186.00, 14, 'activa', '2026-05-22 10:34:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 380.00, 23, 'activa', '2026-05-27 10:59:00-06'),
    ('ventas.oriente@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 401.00, 1, 'activa', '2026-05-27 10:59:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 380.00, 28, 'activa', '2026-05-27 10:59:00-06'),
    ('ventas.oriente@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 378.00, 1, 'activa', '2026-05-27 10:59:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta blanda', 180.00, 0, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta blanda', 188.00, 21, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta blanda', 166.00, 10, 'activa', '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta dura', 279.00, 36, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta dura', 259.00, 17, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta dura', 296.00, 13, 'activa', '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 145.00, 7, 'activa', '2026-06-09 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 149.00, 2, 'pausada', '2026-06-09 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 136.00, 25, 'activa', '2026-06-09 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 150.00, 17, 'activa', '2026-06-09 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 138.00, 21, 'activa', '2026-06-09 10:52:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 620.00, 25, 'activa', '2026-06-14 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 592.00, 23, 'activa', '2026-06-14 10:03:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Digital', 341.00, 22, 'activa', '2026-06-14 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Bases de datos distribuidas', 'Digital', 321.00, 14, 'activa', '2026-06-14 10:03:00-06'),
    ('ventas.poniente@mesh.com', 'Bases de datos distribuidas', 'Digital', 367.00, 8, 'activa', '2026-06-14 10:03:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '30 ml', 210.00, 0, 'activa', '2026-06-19 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Serum de niacinamida 10%', '30 ml', 197.00, 20, 'activa', '2026-06-19 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Serum de niacinamida 10%', '30 ml', 215.00, 0, 'activa', '2026-06-19 10:45:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '50 ml', 311.00, 9, 'activa', '2026-06-19 10:45:00-06'),
    ('ventas.poniente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 322.00, 24, 'activa', '2026-06-19 10:45:00-06'),
    ('tienda@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 265.00, 26, 'activa', '2026-06-24 10:16:00-06'),
    ('ventas.oriente@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 258.00, 12, 'pausada', '2026-06-24 10:16:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '50 ml', 720.00, 32, 'activa', '2026-07-01 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Eau de parfum Bruma', '50 ml', 705.00, 7, 'activa', '2026-07-01 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Eau de parfum Bruma', '50 ml', 717.00, 18, 'activa', '2026-07-01 10:57:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '100 ml', 1166.00, 9, 'activa', '2026-07-01 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Eau de parfum Bruma', '100 ml', 1092.00, 25, 'activa', '2026-07-01 10:57:00-06')
) AS v(correo, producto, variante, precio, stock, estado, fecha)
JOIN usuarios            u  ON u.correo_electronico = v.correo
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
JOIN estado_oferta       eo ON eo.estado_oferta_nombre = v.estado;

-- ============================================================
-- El historial de precio: 220 filas
-- ============================================================
-- Una por el nacimiento de cada oferta, mas los cambios de una de cada
-- cuatro. Es lo que hace reconstruible el precio a una fecha: sin ningun
-- cambio, la funcion existiria pero no habria como ensenarla.
--
-- Se escriben a mano porque el trigger siempre pondria now(), y estas
-- fechas son del pasado. Por eso esta apagado arriba.

INSERT INTO precio_historial (id_oferta, precio, id_usuario_modifico, fecha_creacion)
SELECT o.id_oferta, v.precio, u.id_usuario, v.fecha::timestamptz
FROM (VALUES
    ('tienda@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6200.00, '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6343.00, '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8804.00, '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 9226.00, '2026-01-04 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8919.00, '2026-01-04 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 9456.00, '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9400.00, '2026-01-09 10:22:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9708.00, '2026-01-09 10:22:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 8842.00, '2026-01-09 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 14570.00, '2026-01-09 10:22:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 13803.00, '2026-01-09 10:22:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 15520.00, '2026-01-09 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 4100.00, '2026-01-14 10:32:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 4029.00, '2026-01-14 10:32:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 3856.00, '2026-01-14 10:32:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '128 GB', 5300.00, '2026-01-24 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Vela 7', '128 GB', 5264.00, '2026-01-24 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Vela 7', '128 GB', 5556.00, '2026-01-24 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '128 GB', 5324.00, '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '256 GB', 6254.00, '2026-01-24 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '256 GB', 6351.00, '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '512 GB', 7208.00, '2026-01-24 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Vela 7', '512 GB', 7319.00, '2026-01-24 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Vela 7', '512 GB', 7022.00, '2026-01-24 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Vela 7', '512 GB', 6759.00, '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1850.00, '2026-01-24 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1891.00, '2026-01-24 10:38:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2257.00, '2026-01-24 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2403.00, '2026-01-24 10:38:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1450.00, '2026-02-01 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1337.00, '2026-02-01 10:34:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Arena', 1450.00, '2026-02-01 10:34:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 620.00, '2026-02-06 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 636.00, '2026-02-06 10:02:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Gris', 620.00, '2026-02-06 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 571.00, '2026-02-06 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Brisa Sport', 'Gris', 653.00, '2026-02-06 10:02:00-06'),
    ('tienda@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2100.00, '2026-02-11 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 1950.00, '2026-02-11 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2209.00, '2026-02-11 10:26:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2750.00, '2026-02-16 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2690.00, '2026-02-16 10:25:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3658.00, '2026-02-16 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3367.00, '2026-02-16 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3416.00, '2026-02-16 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3742.00, '2026-02-16 10:25:00-06'),
    ('tienda@mesh.com', 'Monitor Panorama 34', '100 Hz', 5900.00, '2026-02-21 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Panorama 34', '100 Hz', 5667.00, '2026-02-21 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Panorama 34', '100 Hz', 5765.00, '2026-02-21 10:15:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1980.00, '2026-02-08 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1969.00, '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1852.00, '2026-02-08 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 2001.00, '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2455.00, '2026-02-08 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2296.00, '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2530.00, '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1240.00, '2026-03-03 10:48:00-06'),
    ('ventas.poniente@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1327.00, '2026-03-03 10:48:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 890.00, '2026-03-08 10:15:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1023.00, '2026-03-08 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1061.00, '2026-03-08 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1023.00, '2026-03-08 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1098.00, '2026-03-08 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1068.00, '2026-03-08 10:15:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Natural', 2350.00, '2026-03-13 10:05:00-06'),
    ('ventas.norte@mesh.com', 'Escritorio Roble 120', 'Natural', 2208.00, '2026-03-13 10:05:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Natural', 2396.00, '2026-03-13 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Escritorio Roble 120', 'Natural', 2339.00, '2026-03-13 10:05:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Nogal', 2350.00, '2026-03-13 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Escritorio Roble 120', 'Nogal', 2402.00, '2026-03-13 10:05:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3100.00, '2026-03-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3202.00, '2026-03-18 10:04:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3100.00, '2026-03-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3215.00, '2026-03-18 10:04:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 480.00, '2026-03-23 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 477.00, '2026-03-23 10:38:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra', 480.00, '2026-03-23 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de escritorio Faro', 'Negra', 481.00, '2026-03-23 10:38:00-06'),
    ('tienda@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 320.00, '2026-03-28 10:05:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'S azul', 340.00, '2026-01-12 09:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de lino manga larga', 'S azul', 363.00, '2026-01-12 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de lino manga larga', 'S azul', 325.00, '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'M azul', 340.00, '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'L blanca', 340.00, '2026-01-12 09:00:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de lino manga larga', 'L blanca', 333.00, '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'M celeste', 290.00, '2026-04-10 10:16:00-06'),
    ('ventas.sur@mesh.com', 'Camisa oxford clasica', 'M celeste', 297.00, '2026-04-10 10:16:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'L celeste', 290.00, '2026-04-10 10:16:00-06'),
    ('ventas.norte@mesh.com', 'Camisa oxford clasica', 'L celeste', 308.00, '2026-04-10 10:16:00-06'),
    ('ventas.sur@mesh.com', 'Camisa oxford clasica', 'L celeste', 269.00, '2026-04-10 10:16:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa oxford clasica', 'L celeste', 290.00, '2026-04-10 10:16:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 420.00, '2026-04-15 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon chino resistente', '32 beige', 441.00, '2026-04-15 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '32 beige', 434.00, '2026-04-15 10:25:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 beige', 420.00, '2026-04-15 10:25:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 azul', 420.00, '2026-04-15 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 azul', 387.00, '2026-04-15 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon chino resistente', '34 azul', 392.00, '2026-04-15 10:25:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '40 cafe', 780.00, '2026-04-20 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '40 cafe', 772.00, '2026-04-20 10:48:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 cafe', 780.00, '2026-04-20 10:48:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '42 cafe', 773.00, '2026-04-20 10:48:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 cafe', 832.00, '2026-04-20 10:48:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 negro', 780.00, '2026-04-20 10:48:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 negro', 805.00, '2026-04-20 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '42 negro', 793.00, '2026-04-20 10:48:00-06'),
    ('ventas.poniente@mesh.com', 'Zapato de cuero Senda', '42 negro', 793.00, '2026-04-20 10:48:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '41', 1150.00, '2026-04-25 10:56:00-06'),
    ('ventas.sur@mesh.com', 'Bota impermeable Cumbre', '41', 1063.00, '2026-04-25 10:56:00-06'),
    ('ventas.poniente@mesh.com', 'Bota impermeable Cumbre', '41', 1194.00, '2026-04-25 10:56:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '43', 1150.00, '2026-04-25 10:56:00-06'),
    ('ventas.sur@mesh.com', 'Bota impermeable Cumbre', '43', 1132.00, '2026-04-25 10:56:00-06'),
    ('ventas.oriente@mesh.com', 'Bota impermeable Cumbre', '43', 1183.00, '2026-04-25 10:56:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 260.00, '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Naranja', 260.00, '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'M', 145.00, '2026-05-07 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Espinilleras Muralla', 'M', 156.00, '2026-05-07 10:27:00-06'),
    ('ventas.poniente@mesh.com', 'Espinilleras Muralla', 'M', 134.00, '2026-05-07 10:27:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'L', 145.00, '2026-05-07 10:27:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'L', 138.00, '2026-05-07 10:27:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'L', 137.00, '2026-05-07 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Espinilleras Muralla', 'L', 137.00, '2026-05-07 10:27:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 690.00, '2026-05-12 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 690.00, '2026-05-12 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 736.00, '2026-05-12 10:20:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'L negro', 690.00, '2026-05-12 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Casco de ruta Aerodino', 'L negro', 688.00, '2026-05-12 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Casco de ruta Aerodino', 'L negro', 713.00, '2026-05-12 10:20:00-06'),
    ('tienda@mesh.com', 'Bomba de piso Piston', 'Estandar', 310.00, '2026-05-17 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Bomba de piso Piston', 'Estandar', 315.00, '2026-05-17 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Bomba de piso Piston', 'Estandar', 294.00, '2026-05-17 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Bomba de piso Piston', 'Estandar', 288.00, '2026-05-17 10:26:00-06'),
    ('tienda@mesh.com', 'Set de bandas elasticas', 'Set completo', 195.00, '2026-05-22 10:34:00-06'),
    ('ventas.norte@mesh.com', 'Set de bandas elasticas', 'Set completo', 183.00, '2026-05-22 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Set de bandas elasticas', 'Set completo', 204.00, '2026-05-22 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Set de bandas elasticas', 'Set completo', 186.00, '2026-05-22 10:34:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 380.00, '2026-05-27 10:59:00-06'),
    ('ventas.oriente@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 401.00, '2026-05-27 10:59:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 380.00, '2026-05-27 10:59:00-06'),
    ('ventas.oriente@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 378.00, '2026-05-27 10:59:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta blanda', 180.00, '2026-05-20 09:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta blanda', 188.00, '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta blanda', 166.00, '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta dura', 279.00, '2026-05-20 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta dura', 259.00, '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta dura', 296.00, '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 145.00, '2026-06-09 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 149.00, '2026-06-09 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 136.00, '2026-06-09 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 150.00, '2026-06-09 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 138.00, '2026-06-09 10:52:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 620.00, '2026-06-14 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 592.00, '2026-06-14 10:03:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Digital', 341.00, '2026-06-14 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Bases de datos distribuidas', 'Digital', 321.00, '2026-06-14 10:03:00-06'),
    ('ventas.poniente@mesh.com', 'Bases de datos distribuidas', 'Digital', 367.00, '2026-06-14 10:03:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '30 ml', 210.00, '2026-06-19 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Serum de niacinamida 10%', '30 ml', 197.00, '2026-06-19 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Serum de niacinamida 10%', '30 ml', 215.00, '2026-06-19 10:45:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '50 ml', 311.00, '2026-06-19 10:45:00-06'),
    ('ventas.poniente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 322.00, '2026-06-19 10:45:00-06'),
    ('tienda@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 265.00, '2026-06-24 10:16:00-06'),
    ('ventas.oriente@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 258.00, '2026-06-24 10:16:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '50 ml', 720.00, '2026-07-01 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Eau de parfum Bruma', '50 ml', 705.00, '2026-07-01 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Eau de parfum Bruma', '50 ml', 717.00, '2026-07-01 10:57:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '100 ml', 1166.00, '2026-07-01 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Eau de parfum Bruma', '100 ml', 1092.00, '2026-07-01 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8043.00, '2026-03-22 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8984.00, '2026-03-19 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '256 GB', 6067.00, '2026-03-02 12:00:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '512 GB', 6912.00, '2026-03-25 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Vela 7', '512 GB', 7565.00, '2026-03-12 12:00:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2385.00, '2026-03-11 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2202.00, '2026-03-11 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 1930.00, '2026-05-24 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 642.00, '2026-04-02 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 612.00, '2026-06-10 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Brisa Sport', 'Gris', 719.00, '2026-04-07 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Brisa Sport', 'Gris', 666.00, '2026-06-17 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2011.00, '2026-04-23 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 1848.00, '2026-06-09 12:00:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3811.00, '2026-04-06 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3561.00, '2026-04-14 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3365.00, '2026-04-01 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 2033.00, '2026-04-27 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1857.00, '2026-06-25 12:00:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2243.00, '2026-04-23 12:00:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2421.00, '2026-06-02 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Licuadora Torbellino 1200', '2 L', 942.00, '2026-05-06 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1238.00, '2026-05-22 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1321.00, '2026-07-11 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Natural', 2237.00, '2026-05-14 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Natural', 2476.00, '2026-07-06 12:00:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 2847.00, '2026-05-24 12:00:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3330.00, '2026-05-08 12:00:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra', 442.00, '2026-05-04 12:00:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra', 400.00, '2026-07-25 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'M celeste', 273.00, '2026-06-13 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 471.00, '2026-06-04 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 530.00, '2026-08-01 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 beige', 442.00, '2026-06-07 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 azul', 374.00, '2026-06-05 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 azul', 422.00, '2026-08-26 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '42 cafe', 687.00, '2026-06-22 12:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 234.00, '2026-06-22 12:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 249.00, '2026-08-22 12:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'M', 131.00, '2026-07-08 12:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'M', 125.00, '2026-08-25 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'L', 125.00, '2026-07-25 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'L', 141.00, '2026-08-01 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'L', 144.00, '2026-07-24 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Casco de ruta Aerodino', 'L negro', 644.00, '2026-07-04 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Bomba de piso Piston', 'Estandar', 340.00, '2026-07-14 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Bomba de piso Piston', 'Estandar', 276.00, '2026-07-12 12:00:00-06'),
    ('tienda@mesh.com', 'Set de bandas elasticas', 'Set completo', 175.00, '2026-07-14 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Bases de datos distribuidas', 'Digital', 291.00, '2026-08-24 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Bases de datos distribuidas', 'Digital', 267.00, '2026-08-12 12:00:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '30 ml', 187.00, '2026-08-11 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 294.00, '2026-08-01 12:00:00-06')
) AS v(correo, producto, variante, precio, fecha)
JOIN usuarios            u  ON u.correo_electronico = v.correo
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
JOIN oferta              o  ON o.id_producto_variante = pv.id_producto_variante AND o.id_usuario = u.id_usuario;

-- La oferta se pone en su precio de HOY, que es el ultimo de su historial.
-- Se deriva del historial en vez de escribirse otra vez: si se escribiera
-- aparte, los dos podrian discrepar y nadie se enteraria.
UPDATE oferta o
SET precio = ultimo.precio
FROM (
    SELECT DISTINCT ON (id_oferta) id_oferta, precio
    FROM precio_historial
    ORDER BY id_oferta, fecha_creacion DESC, id_precio_historial DESC
) AS ultimo
WHERE ultimo.id_oferta = o.id_oferta;

-- ============================================================
-- El kardex: la reposicion que explica el stock
-- ============================================================
-- Cada oferta nace con un movimiento de reposicion por sus unidades, para
-- que el libro mayor nazca cuadrado. Si el saldo existiera sin un
-- movimiento que lo explique, el kardex dejaria de servir para reconstruir
-- la disponibilidad, que es lo unico para lo que existe.

INSERT INTO stock_movimiento (id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido, cantidad, stock_resultante, fecha_movimiento)
SELECT o.id_oferta, m.id_motivo_movimiento, o.id_usuario, NULL, o.stock, o.stock, o.fecha_creacion
FROM oferta o
JOIN motivo_movimiento m ON m.motivo_nombre = 'reposicion'
WHERE o.stock > 0;

-- ============================================================
-- Dos pedidos comprados
-- ============================================================
-- No se insertan a mano: se arman con las MISMAS funciones que usa la
-- aplicacion. Asi el conjunto de datos no puede contradecir al flujo real,
-- y de paso queda probado que las funciones corren.

DO $bloque$
DECLARE
    v_pedido  bigint;
    v_dir     bigint;
    v_usuario bigint;
    v_of      record;
BEGIN
    -- Pedido de la compradora del norte: dos lineas de vendedores distintos,
    -- que es lo que solo puede pasar en un modelo multi-vendedor.
    SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir
    FROM usuarios u
    JOIN direcciones d        ON d.id_usuario = u.id_usuario
    JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
    WHERE u.correo_electronico = 'compradora.norte@mesh.com'
    LIMIT 1;

    v_pedido := crear_pedido(v_usuario, v_dir);

    FOR v_of IN
        SELECT o.id_oferta, p.id_producto, pv.id_producto_variante, p.nombre AS np, pv.nombre_variante AS nv
        FROM oferta o
        JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante
        JOIN productos p            ON p.id_producto = pv.id_producto
        JOIN estado_oferta eo       ON eo.id_estado_oferta = o.id_estado_oferta
        WHERE eo.estado_oferta_nombre = 'activa' AND o.stock >= 2
        ORDER BY o.id_oferta
        LIMIT 2
    LOOP
        PERFORM agregar_linea(v_pedido, jsonb_build_object(
            'id_oferta', v_of.id_oferta, 'cantidad', 1,
            'id_producto', v_of.id_producto, 'id_producto_variante', v_of.id_producto_variante,
            'nombre_producto', v_of.np, 'nombre_variante', v_of.nv));
    END LOOP;

    PERFORM comprar_pedido(v_pedido, 'tarjeta');

    -- Pedido del comprador del sur: una linea, contra entrega
    SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir
    FROM usuarios u
    JOIN direcciones d        ON d.id_usuario = u.id_usuario
    JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
    WHERE u.correo_electronico = 'comprador.sur@mesh.com'
    LIMIT 1;

    v_pedido := crear_pedido(v_usuario, v_dir);

    SELECT o.id_oferta, p.id_producto, pv.id_producto_variante, p.nombre AS np, pv.nombre_variante AS nv
    INTO v_of
    FROM oferta o
    JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante
    JOIN productos p            ON p.id_producto = pv.id_producto
    JOIN estado_oferta eo       ON eo.id_estado_oferta = o.id_estado_oferta
    WHERE eo.estado_oferta_nombre = 'activa' AND o.stock >= 3
    ORDER BY o.id_oferta DESC
    LIMIT 1;

    PERFORM agregar_linea(v_pedido, jsonb_build_object(
        'id_oferta', v_of.id_oferta, 'cantidad', 2,
        'id_producto', v_of.id_producto, 'id_producto_variante', v_of.id_producto_variante,
        'nombre_producto', v_of.np, 'nombre_variante', v_of.nv));

    PERFORM comprar_pedido(v_pedido, 'efectivo contra entrega');
END
$bloque$;

-- ============================================================
-- El trigger vuelve, y el conjunto se comprueba a si mismo
-- ============================================================
-- Un conjunto de datos que no se verifica es un conjunto de datos que
-- miente en silencio. Estas tres comprobaciones fallan la migracion entera
-- si algo no cuadra, en vez de dejar la base torcida y que alguien lo
-- descubra tres semanas despues.

ALTER TABLE oferta ENABLE TRIGGER trg_oferta_registrar_precio;

DO $verificar$
DECLARE
    v_mal  integer;
BEGIN
    -- 1. El saldo de cada oferta es la suma de su kardex
    SELECT count(*) INTO v_mal
    FROM oferta o
    LEFT JOIN (
        SELECT sm.id_oferta, sum(sm.cantidad * mm.valor) AS saldo
        FROM stock_movimiento sm
        JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
        GROUP BY sm.id_oferta
    ) k ON k.id_oferta = o.id_oferta
    WHERE o.stock <> coalesce(k.saldo, 0);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas tienen un stock que su kardex no explica', v_mal;
    END IF;

    -- 2. El precio de cada oferta es el ultimo de su historial
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN LATERAL (
        SELECT precio FROM precio_historial ph
        WHERE ph.id_oferta = o.id_oferta
        ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC LIMIT 1
    ) ultimo ON true
    WHERE o.precio <> ultimo.precio;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas tienen un precio distinto al ultimo de su historial', v_mal;
    END IF;

    -- 3. Toda variante tiene la oferta de la tienda: es lo que garantiza que
    --    ningun producto se quede sin precio que ensenar en la pagina
    SELECT count(*) INTO v_mal
    FROM productos_variantes pv
    WHERE NOT EXISTS (
        SELECT 1 FROM oferta o
        JOIN usuarios u ON u.id_usuario = o.id_usuario
        WHERE o.id_producto_variante = pv.id_producto_variante
          AND u.correo_electronico = 'tienda@mesh.com'
    );

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% variantes no tienen oferta de la tienda', v_mal;
    END IF;

    RAISE NOTICE 'Conjunto de datos verificado: kardex, precios y ofertas de la tienda cuadran';
END
$verificar$;

COMMIT;
