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
INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, id_estado_direccion)
SELECT u.id_usuario, v.pais, v.departamento, v.ciudad, v.calle, v.codigo, ed.id_estado_direccion
FROM (VALUES
    ('compradora.norte@mesh.com', 'Guatemala', 'Guatemala',     'Guatemala',         '6a. Avenida 9-18, Zona 10, Edificio Vista Real, Nivel 3', '01010'),
    ('comprador.sur@mesh.com',    'Guatemala', 'Sacatepequez',  'Antigua Guatemala', '5a. Avenida Norte 22, frente al Arco de Santa Catalina',   '03001')
) AS v(correo, pais, departamento, ciudad, calle, codigo)
JOIN usuarios u ON u.correo_electronico = v.correo
JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa'
WHERE NOT EXISTS (SELECT 1 FROM direcciones d WHERE d.id_usuario = u.id_usuario);

-- Su primera version en el historial. El pedido apunta AQUI y no a
-- direcciones: guarda a donde se mando de verdad, aunque despues la editen.
-- La calle se copia igual que el resto: si faltara aqui, la etiqueta de un
-- pedido viejo se quedaria sin ella.
INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal)
SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.direccion_exacta, d.codigo_postal
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
-- Los productos: 102 en 17 categorias hoja
-- ============================================================
-- Cuelgan de una hoja, nunca de una raiz. Las fechas estan escalonadas a lo
-- largo del ano: sin un pasado no hay nada que reconstruir.

INSERT INTO productos (nombre, descripcion, fecha_creacion, id_estado_producto, id_categoria)
SELECT v.nombre, v.descripcion, v.fecha::timestamptz, ep.id_estado_producto, c.id_categoria
FROM (VALUES
    ('Laptop Aurora 14', 'Ultraligera de 14 pulgadas con chasis de aluminio y teclado retroiluminado.', '2026-01-04 10:52:00-06', 'Laptops'),
    ('Laptop Bastion 16', 'Estacion de trabajo de 16 pulgadas para render y compilacion.', '2026-01-05 10:22:00-06', 'Laptops'),
    ('Laptop Nimbo 13', 'Equipo de entrada para estudio y oficina, silencioso y sin ventilador.', '2026-01-06 10:32:00-06', 'Laptops'),
    ('Laptop Lienzo 15', 'Convertible de 15.6 pulgadas con bisagra de 360 grados y lapiz optico incluido.', '2026-01-07 10:02:00-06', 'Laptops'),
    ('Laptop Cumbre 17 Gamer', 'Portatil de 17.3 pulgadas con refrigeracion de doble ventilador y teclado mecanico.', '2026-01-08 10:38:00-06', 'Laptops'),
    ('Laptop Vireo Air 12', 'Netbook de 12.5 pulgadas para clases y navegacion, arranca en menos de diez segundos.', '2026-01-09 10:34:00-06', 'Laptops'),
    ('Laptop Ambar Campus 14', 'Chasis reforzado con bisagras probadas a diez mil aperturas, pensada para mochila.', '2026-01-10 10:02:00-06', 'Laptops'),
    ('Telefono Vela 7', 'Pantalla OLED de 6.4 pulgadas y camara principal de 50 MP.', '2026-01-24 10:15:00-06', 'Telefonos'),
    ('Telefono Ceibo Lite', 'Bateria de dos dias y ranura para memoria expandible.', '2026-01-12 10:25:00-06', 'Telefonos'),
    ('Telefono Nautilo Pro', 'Triple camara con teleobjetivo de tres aumentos y carga completa en treinta minutos.', '2026-01-13 10:15:00-06', 'Telefonos'),
    ('Telefono Pedernal Rugged', 'Carcasa con esquinas reforzadas y bateria de gran capacidad para trabajo de campo.', '2026-01-14 10:25:00-06', 'Telefonos'),
    ('Telefono Bruma Mini', 'Cuerpo compacto de 5.8 pulgadas que se maneja con una sola mano.', '2026-01-15 10:48:00-06', 'Telefonos'),
    ('Telefono Cuarzo Duo', 'Doble linea con dos ranuras SIM activas y radio FM sin auriculares.', '2026-01-16 10:15:00-06', 'Telefonos'),
    ('Audifonos Sereno ANC', 'Diadema cerrada con cancelacion activa y estuche rigido.', '2026-01-17 10:05:00-06', 'Audifonos'),
    ('Audifonos Brisa Sport', 'Intraurales con gancho de silicona, pensados para correr.', '2026-01-18 10:04:00-06', 'Audifonos'),
    ('Audifonos Estudio 900', 'Monitoreo de referencia con cable desmontable de 3 metros.', '2026-01-19 10:38:00-06', 'Audifonos'),
    ('Audifonos Colibri Micro TWS', 'Intraurales sin cable con estuche de carga del tamano de una caja de fosforos.', '2026-01-20 10:05:00-06', 'Audifonos'),
    ('Audifonos Marea Diadema Abierta', 'Diadema de rejilla abierta con almohadillas de terciopelo reemplazables.', '2026-01-21 10:04:00-06', 'Audifonos'),
    ('Audifonos Duna Trabajo', 'Microfono de brazo abatible y base de carga de escritorio para llamadas largas.', '2026-01-22 10:16:00-06', 'Audifonos'),
    ('Audifonos Zumbo Cable', 'Intraurales con cable plano antienredos y control de una tecla.', '2026-01-23 10:25:00-06', 'Audifonos'),
    ('Monitor Horizonte 27', 'Panel IPS de 27 pulgadas con base ajustable en altura.', '2026-01-24 10:48:00-06', 'Monitores'),
    ('Monitor Panorama 34', 'Ultrapanoramico curvo de 34 pulgadas, ideal para dos ventanas lado a lado.', '2026-01-25 10:56:00-06', 'Monitores'),
    ('Monitor Vitral 24', 'Panel IPS de 23.8 pulgadas con entrada HDMI y DisplayPort, base fija.', '2026-01-26 10:42:00-06', 'Monitores'),
    ('Monitor Cenit 32 4K', 'Resolucion 4K en 31.5 pulgadas, con calibracion de fabrica y puerto USB-C de 65 W.', '2026-01-27 10:27:00-06', 'Monitores'),
    ('Monitor Vertice 27 Gamer', 'Panel de 27 pulgadas con sincronizacion adaptativa y tiempo de respuesta de 1 ms.', '2026-01-28 10:20:00-06', 'Monitores'),
    ('Monitor Nube 22', 'Monitor de 21.5 pulgadas para oficina, con altavoces integrados.', '2026-02-01 10:26:00-06', 'Monitores'),
    ('Cafetera Alba Espresso', 'Cafetera de brazo con vaporizador y bandeja recogegotas extraible.', '2026-02-08 12:00:00-06', 'Cocina'),
    ('Juego de ollas Fuego 5 piezas', 'Cinco piezas de acero tricapa con tapas de vidrio templado.', '2026-02-03 10:59:00-06', 'Cocina'),
    ('Licuadora Torbellino 1200', 'Vaso de vidrio y cuchillas de seis puntas para hielo.', '2026-02-04 10:34:00-06', 'Cocina'),
    ('Hervidor electrico Vapor 1.7', 'Hervidor de 1.7 litros con apagado automatico y filtro antisarro extraible.', '2026-02-05 10:52:00-06', 'Cocina'),
    ('Cacerola honda Comal 18', 'Cacerola de acero tricapa con tapa de vidrio templado y mango remachado.', '2026-02-06 10:03:00-06', 'Cocina'),
    ('Olla arrocera Grano 8 tazas', 'Cocina hasta ocho tazas de arroz y pasa sola a mantener el calor.', '2026-02-07 10:45:00-06', 'Cocina'),
    ('Tabla de picar Cedro grande', 'Tabla de bambu de 40 por 28 cm con canal para jugos en las dos caras.', '2026-02-08 10:16:00-06', 'Cocina'),
    ('Escritorio Roble 120', 'Tablero de 120 por 60 cm con pasacables y estructura de acero.', '2026-02-09 10:57:00-06', 'Muebles'),
    ('Silla ergonomica Vertebra', 'Respaldo de malla, soporte lumbar regulable y apoyabrazos 3D.', '2026-02-10 10:26:00-06', 'Muebles'),
    ('Librero Hoja 5 niveles', 'Cinco entrepanos de 80 cm de ancho, con anclaje de pared incluido.', '2026-02-11 10:12:00-06', 'Muebles'),
    ('Mesa de centro Guijarro', 'Mesa baja de madera maciza de 100 por 55 cm, llega armada de fabrica.', '2026-02-12 10:08:00-06', 'Muebles'),
    ('Silla de comedor Vara', 'Silla de madera de haya con respaldo de listones y asiento a 45 cm del piso.', '2026-02-13 10:38:00-06', 'Muebles'),
    ('Comoda Sendero 4 gavetas', 'Gavetas con correderas metalicas y tope antivuelco para fijar a la pared.', '2026-02-14 10:20:00-06', 'Muebles'),
    ('Lampara de escritorio Faro', 'Brazo articulado con tres temperaturas de color y puerto USB.', '2026-02-15 10:07:00-06', 'Iluminacion'),
    ('Tira LED Aurora 5 m', 'Cinco metros regulables con control remoto y adhesivo 3M.', '2026-02-16 10:30:00-06', 'Iluminacion'),
    ('Lampara colgante Candela 40', 'Pantalla tejida de mimbre de 40 cm de diametro con cable textil regulable.', '2026-02-17 10:42:00-06', 'Iluminacion'),
    ('Lampara de pie Vigia 165', 'Poste de 165 cm con pedal de encendido y difusor de tela orientable.', '2026-02-18 10:55:00-06', 'Iluminacion'),
    ('Plafon LED Solaz 24', 'Plafon de superficie de 40 cm que se atornilla directo al techo, sin balastro.', '2026-02-19 10:59:00-06', 'Iluminacion'),
    ('Farol solar de jardin Luciernaga', 'Estaca para cesped con panel solar y sensor de anochecer, se clava sin cablear.', '2026-02-20 10:29:00-06', 'Iluminacion'),
    ('Camisa de lino manga larga', 'Lino lavado de corte regular con cuello italiano.', '2026-01-12 09:00:00-06', 'Camisas'),
    ('Camisa oxford clasica', 'Oxford de algodon peinado, cuello con botones.', '2026-02-22 10:47:00-06', 'Camisas'),
    ('Camisa guayabera Xelaju', 'Guayabera de lino con cuatro bolsas y alforzas verticales al frente y a la espalda.', '2026-02-23 10:01:00-06', 'Camisas'),
    ('Camisa de vestir Meridiano', 'Popelina de algodon peinado con cuello semiingles y punos de gemelo opcional.', '2026-02-24 10:47:00-06', 'Camisas'),
    ('Camisa de mezclilla Remache', 'Mezclilla de 6 onzas con botones a presion y canesu doble en la espalda.', '2026-02-25 10:02:00-06', 'Camisas'),
    ('Camisa polo pique Cardumen', 'Pique de algodon con cuello acanalado y abertura de tres botones.', '2026-02-26 10:34:00-06', 'Camisas'),
    ('Pantalon chino resistente', 'Sarga de algodon con elastano, corte recto.', '2026-02-27 10:30:00-06', 'Pantalones'),
    ('Pantalon de mezclilla Yunque', 'Mezclilla rigida de 13 onzas, cinco bolsas y remaches de cobre en los esfuerzos.', '2026-02-28 10:57:00-06', 'Pantalones'),
    ('Pantalon cargo Vereda', 'Ripstop con seis bolsas, rodilla articulada y jareta en el tobillo.', '2026-03-01 10:46:00-06', 'Pantalones'),
    ('Pantalon de vestir Consulado', 'Lana fria de corte ajustado, con pretina interior antideslizante y bajo sin dobladillo.', '2026-03-02 10:20:00-06', 'Pantalones'),
    ('Pantalon jogger Ocaso', 'Felpa de algodon con cintura elastica, cordon plano y punos acanalados.', '2026-03-03 10:57:00-06', 'Pantalones'),
    ('Zapato de cuero Senda', 'Cuero vacuno con suela de goma cosida.', '2026-03-04 10:14:00-06', 'Zapatos'),
    ('Bota impermeable Cumbre', 'Membrana impermeable y suela con agarre para roca mojada.', '2026-03-05 10:09:00-06', 'Zapatos'),
    ('Tenis urbano Vereda 90', 'Malla transpirable sobre suela de EVA inyectada, para caminar todo el dia.', '2026-03-06 10:37:00-06', 'Zapatos'),
    ('Mocasin de gamuza Roble', 'Gamuza sin forro con suela flexible de goma, se usa sin calcetin.', '2026-03-07 10:45:00-06', 'Zapatos'),
    ('Bota de trabajo Yunque S3', 'Puntera de acero y plantilla antiperforacion, suela resistente a hidrocarburos.', '2026-03-08 10:39:00-06', 'Zapatos'),
    ('Sandalia de cuero Litoral', 'Tres tiras de cuero curtido con vegetales y hebilla de laton macizo.', '2026-03-09 10:19:00-06', 'Zapatos'),
    ('Balon de futbol numero 5', 'Costura termosellada, apto para cancha de grama sintetica.', '2026-04-06 08:00:00-06', 'Futbol'),
    ('Espinilleras Muralla', 'Placa rigida con espuma de alta densidad y mallas sujetadoras.', '2026-03-11 10:26:00-06', 'Futbol'),
    ('Guantes de portero Zarpa 300', 'Latex de cuatro milimetros con corte negativo y correa elastica ancha.', '2026-03-12 10:51:00-06', 'Futbol'),
    ('Zapato de tacos Relampago FG', 'Doce tacos conicos para grama natural firme y empeine de microfibra sin costuras.', '2026-03-13 10:57:00-06', 'Futbol'),
    ('Red de porteria Trama 7 x 2', 'Par de redes de malla trenzada para porteria reglamentaria, con ganchos incluidos.', '2026-03-14 10:14:00-06', 'Futbol'),
    ('Uniforme de entrenamiento Cantera', 'Camiseta, pantaloneta y medias en tejido que seca rapido, sin numeracion.', '2026-03-15 10:07:00-06', 'Futbol'),
    ('Casco de ruta Aerodino', 'Veintidos ventilaciones y ajuste micrometrico en la nuca.', '2026-03-16 10:04:00-06', 'Ciclismo'),
    ('Bomba de piso Piston', 'Manometro analogico hasta 160 psi y cabezal para las dos valvulas.', '2026-03-17 10:22:00-06', 'Ciclismo'),
    ('Guantes de ciclismo Palma Corta', 'Medio dedo con gel en la eminencia tenar y lengueta para quitarlos de un tiron.', '2026-03-18 10:15:00-06', 'Ciclismo'),
    ('Sillin de ruta Vertebra SR-2', 'Canal central aliviado y rieles de acero cromado compatibles con cualquier tija.', '2026-03-19 10:19:00-06', 'Ciclismo'),
    ('Maillot de ruta Peloton', 'Cierre completo, tres bolsillos traseros y paneles de malla bajo los brazos.', '2026-03-20 10:20:00-06', 'Ciclismo'),
    ('Candado plegable Cerrojo F8', 'Ocho barras de acero templado que se pliegan en una funda atornillable al cuadro.', '2026-03-21 10:10:00-06', 'Ciclismo'),
    ('Set de bandas elasticas', 'Cinco bandas de latex con distinta resistencia y bolsa de malla.', '2026-03-22 10:04:00-06', 'Fitness'),
    ('Tapete de yoga Raiz 6 mm', 'Seis milimetros de TPE con superficie antideslizante en las dos caras.', '2026-03-23 10:35:00-06', 'Fitness'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de mancuernas con discos intercambiables de 1.25 a 5 kg y seguro de rosca.', '2026-03-24 10:18:00-06', 'Fitness'),
    ('Pesa rusa Yunque', 'Hierro fundido de una sola pieza con asa ancha para agarre a dos manos.', '2026-03-25 10:54:00-06', 'Fitness'),
    ('Cuerda de salto Relampago', 'Cable de acero de tres metros con rodamientos, ajustable a la altura del usuario.', '2026-03-26 10:05:00-06', 'Fitness'),
    ('Rodillo de liberacion Nudo', 'Rodillo de espuma con relieve en cuadros para masaje de cuadriceps y espalda alta.', '2026-03-27 10:47:00-06', 'Fitness'),
    ('El camino de las nubes', 'Novela de viaje por el altiplano, ganadora del premio nacional.', '2026-05-20 09:00:00-06', 'Literatura'),
    ('Cuentos de la ceiba', 'Doce relatos breves sobre la memoria y el desarraigo.', '2026-04-01 10:23:00-06', 'Literatura'),
    ('La casa de los relojes detenidos', 'Novela sobre tres hermanas que heredan una relojeria y el silencio de su padre.', '2026-04-02 10:31:00-06', 'Literatura'),
    ('Cartas al puerto seco', 'Novela epistolar entre un aduanero y una traductora que nunca llegan a conocerse.', '2026-04-03 10:25:00-06', 'Literatura'),
    ('Nadie duerme en Tecpanal', 'Coral de un pueblo que pasa una noche entera esperando que baje el rio.', '2026-04-04 10:20:00-06', 'Literatura'),
    ('Antologia del ruido', 'Poemario reunido de veinte anios de trabajo, con notas del propio autor.', '2026-04-05 10:23:00-06', 'Literatura'),
    ('Bases de datos distribuidas', 'Consistencia, particionado y replicacion, con ejercicios resueltos.', '2026-04-06 10:52:00-06', 'Tecnicos'),
    ('Redes industriales y buses de campo', 'Topologias, temporizacion y diagnostico de fallas en Modbus, Profibus y CAN.', '2026-04-07 10:34:00-06', 'Tecnicos'),
    ('Calculo numerico con ejercicios resueltos', 'Metodos iterativos, interpolacion y error de redondeo, con 320 problemas resueltos.', '2026-04-08 10:45:00-06', 'Tecnicos'),
    ('Manual de instalaciones electricas residenciales', 'Calculo de cargas, calibres y protecciones para vivienda, con tablas desplegables.', '2026-04-09 10:03:00-06', 'Tecnicos'),
    ('Introduccion al modelado de sistemas embebidos', 'Maquinas de estado, planificacion en tiempo real y consumo, sobre microcontroladores de 32 bits.', '2026-04-10 10:07:00-06', 'Tecnicos'),
    ('Serum de niacinamida 10%', 'Serum ligero para textura y marcas, de uso nocturno.', '2026-04-11 10:30:00-06', 'Cuidado facial'),
    ('Protector solar mineral FPS 50', 'Filtro mineral sin fragancia, apto para piel sensible.', '2026-04-12 10:17:00-06', 'Cuidado facial'),
    ('Crema hidratante nocturna Alba', 'Crema densa de uso nocturno, se absorbe sin dejar la cara brillante.', '2026-04-13 10:50:00-06', 'Cuidado facial'),
    ('Limpiador en gel Verdo', 'Gel transparente que quita el exceso de grasa sin resecar la piel.', '2026-04-14 10:18:00-06', 'Cuidado facial'),
    ('Exfoliante enzimatico Papilo', 'Exfoliante sin granos: actua por enzimas y se enjuaga con agua tibia.', '2026-04-15 10:09:00-06', 'Cuidado facial'),
    ('Contorno de ojos Lumine', 'Contorno ligero para bolsas y lineas finas, con aplicador frio de ceramica.', '2026-04-16 10:27:00-06', 'Cuidado facial'),
    ('Eau de parfum Bruma', 'Salida citrica, fondo amaderado, doce horas de fijacion.', '2026-04-17 10:24:00-06', 'Fragancias'),
    ('Eau de toilette Salino', 'Salida de sal marina y salvia, con estela fresca de unas seis horas.', '2026-04-18 10:04:00-06', 'Fragancias'),
    ('Agua de colonia Amanecer Citrico', 'Colonia citrica de uso diario, ligera y sin fondo dulce.', '2026-04-19 10:57:00-06', 'Fragancias'),
    ('Bruma corporal Trebol Blanco', 'Bruma ligera para el cuerpo y la ropa, floral y de poca fijacion.', '2026-04-20 10:14:00-06', 'Fragancias'),
    ('Set descubrimiento Nocturno', 'Cuatro viales de 8 ml para probar la linea antes de comprar el frasco.', '2026-04-21 10:48:00-06', 'Fragancias')
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
    ('Laptop Bastion 16', '32 GB / 1 TB', NULL, '2026-01-05 10:22:00-06'),
    ('Laptop Bastion 16', '64 GB / 2 TB', NULL, '2026-01-05 10:22:00-06'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', NULL, '2026-01-06 10:32:00-06'),
    ('Laptop Lienzo 15', '16 GB / 512 GB', NULL, '2026-01-07 10:02:00-06'),
    ('Laptop Lienzo 15', '16 GB / 1 TB', NULL, '2026-01-07 10:02:00-06'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', NULL, '2026-01-07 10:02:00-06'),
    ('Laptop Cumbre 17 Gamer', '32 GB / 1 TB', NULL, '2026-01-08 10:38:00-06'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', NULL, '2026-01-08 10:38:00-06'),
    ('Laptop Vireo Air 12', '8 GB / 128 GB', NULL, '2026-01-09 10:34:00-06'),
    ('Laptop Ambar Campus 14', '8 GB / 256 GB', NULL, '2026-01-10 10:02:00-06'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', NULL, '2026-01-10 10:02:00-06'),
    ('Telefono Vela 7', '128 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '256 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '512 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Ceibo Lite', '64 GB', NULL, '2026-01-12 10:25:00-06'),
    ('Telefono Ceibo Lite', '128 GB', NULL, '2026-01-12 10:25:00-06'),
    ('Telefono Nautilo Pro', '256 GB', NULL, '2026-01-13 10:15:00-06'),
    ('Telefono Nautilo Pro', '512 GB', NULL, '2026-01-13 10:15:00-06'),
    ('Telefono Nautilo Pro', '1 TB', NULL, '2026-01-13 10:15:00-06'),
    ('Telefono Pedernal Rugged', '128 GB', NULL, '2026-01-14 10:25:00-06'),
    ('Telefono Pedernal Rugged', '256 GB', NULL, '2026-01-14 10:25:00-06'),
    ('Telefono Bruma Mini', '128 GB', NULL, '2026-01-15 10:48:00-06'),
    ('Telefono Cuarzo Duo', '32 GB', NULL, '2026-01-16 10:15:00-06'),
    ('Telefono Cuarzo Duo', '64 GB', NULL, '2026-01-16 10:15:00-06'),
    ('Audifonos Sereno ANC', 'Negro', NULL, '2026-01-17 10:05:00-06'),
    ('Audifonos Sereno ANC', 'Arena', NULL, '2026-01-17 10:05:00-06'),
    ('Audifonos Brisa Sport', 'Verde lima', NULL, '2026-01-18 10:04:00-06'),
    ('Audifonos Brisa Sport', 'Gris', NULL, '2026-01-18 10:04:00-06'),
    ('Audifonos Estudio 900', 'Cable 3 m', NULL, '2026-01-19 10:38:00-06'),
    ('Audifonos Colibri Micro TWS', 'Blanco perla', NULL, '2026-01-20 10:05:00-06'),
    ('Audifonos Colibri Micro TWS', 'Negro mate', NULL, '2026-01-20 10:05:00-06'),
    ('Audifonos Colibri Micro TWS', 'Verde menta', NULL, '2026-01-20 10:05:00-06'),
    ('Audifonos Marea Diadema Abierta', 'Cable 2 m', NULL, '2026-01-21 10:04:00-06'),
    ('Audifonos Marea Diadema Abierta', 'Cable 4 m', NULL, '2026-01-21 10:04:00-06'),
    ('Audifonos Duna Trabajo', 'Grafito', NULL, '2026-01-22 10:16:00-06'),
    ('Audifonos Duna Trabajo', 'Blanco hueso', NULL, '2026-01-22 10:16:00-06'),
    ('Audifonos Zumbo Cable', 'Cable 1.2 m', NULL, '2026-01-23 10:25:00-06'),
    ('Monitor Horizonte 27', '75 Hz', NULL, '2026-01-24 10:48:00-06'),
    ('Monitor Horizonte 27', '165 Hz', NULL, '2026-01-24 10:48:00-06'),
    ('Monitor Panorama 34', '100 Hz', NULL, '2026-01-25 10:56:00-06'),
    ('Monitor Vitral 24', '75 Hz', NULL, '2026-01-26 10:42:00-06'),
    ('Monitor Vitral 24', '100 Hz', NULL, '2026-01-26 10:42:00-06'),
    ('Monitor Cenit 32 4K', '60 Hz', NULL, '2026-01-27 10:27:00-06'),
    ('Monitor Vertice 27 Gamer', '144 Hz', NULL, '2026-01-28 10:20:00-06'),
    ('Monitor Vertice 27 Gamer', '180 Hz', NULL, '2026-01-28 10:20:00-06'),
    ('Monitor Vertice 27 Gamer', '240 Hz', NULL, '2026-01-28 10:20:00-06'),
    ('Monitor Nube 22', 'Negro', NULL, '2026-02-01 10:26:00-06'),
    ('Monitor Nube 22', 'Blanco', NULL, '2026-02-01 10:26:00-06'),
    ('Cafetera Alba Espresso', '1.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Cafetera Alba Espresso', '2.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Juego de ollas Fuego 5 piezas', 'Estandar', NULL, '2026-02-03 10:59:00-06'),
    ('Licuadora Torbellino 1200', '1.5 L', NULL, '2026-02-04 10:34:00-06'),
    ('Licuadora Torbellino 1200', '2 L', NULL, '2026-02-04 10:34:00-06'),
    ('Hervidor electrico Vapor 1.7', 'Acero', NULL, '2026-02-05 10:52:00-06'),
    ('Hervidor electrico Vapor 1.7', 'Negro mate', NULL, '2026-02-05 10:52:00-06'),
    ('Cacerola honda Comal 18', '16 cm', NULL, '2026-02-06 10:03:00-06'),
    ('Cacerola honda Comal 18', '18 cm', NULL, '2026-02-06 10:03:00-06'),
    ('Cacerola honda Comal 18', '20 cm', NULL, '2026-02-06 10:03:00-06'),
    ('Olla arrocera Grano 8 tazas', '1.5 L', NULL, '2026-02-07 10:45:00-06'),
    ('Olla arrocera Grano 8 tazas', '2.8 L', NULL, '2026-02-07 10:45:00-06'),
    ('Tabla de picar Cedro grande', 'Grande', NULL, '2026-02-08 10:16:00-06'),
    ('Escritorio Roble 120', 'Natural', NULL, '2026-02-09 10:57:00-06'),
    ('Escritorio Roble 120', 'Nogal', NULL, '2026-02-09 10:57:00-06'),
    ('Silla ergonomica Vertebra', 'Negra', NULL, '2026-02-10 10:26:00-06'),
    ('Silla ergonomica Vertebra', 'Gris', NULL, '2026-02-10 10:26:00-06'),
    ('Librero Hoja 5 niveles', '5 niveles roble', NULL, '2026-02-11 10:12:00-06'),
    ('Librero Hoja 5 niveles', '6 niveles nogal', NULL, '2026-02-11 10:12:00-06'),
    ('Mesa de centro Guijarro', 'Natural', NULL, '2026-02-12 10:08:00-06'),
    ('Silla de comedor Vara', 'Natural', NULL, '2026-02-13 10:38:00-06'),
    ('Silla de comedor Vara', 'Negra', NULL, '2026-02-13 10:38:00-06'),
    ('Silla de comedor Vara', 'Tapizada gris', NULL, '2026-02-13 10:38:00-06'),
    ('Comoda Sendero 4 gavetas', '4 gavetas', NULL, '2026-02-14 10:20:00-06'),
    ('Comoda Sendero 4 gavetas', '6 gavetas', NULL, '2026-02-14 10:20:00-06'),
    ('Lampara de escritorio Faro', 'Blanca', NULL, '2026-02-15 10:07:00-06'),
    ('Lampara de escritorio Faro', 'Negra', NULL, '2026-02-15 10:07:00-06'),
    ('Tira LED Aurora 5 m', 'Multicolor', NULL, '2026-02-16 10:30:00-06'),
    ('Lampara colgante Candela 40', 'Mimbre natural', NULL, '2026-02-17 10:42:00-06'),
    ('Lampara colgante Candela 40', 'Negro mate', NULL, '2026-02-17 10:42:00-06'),
    ('Lampara de pie Vigia 165', 'Negro', NULL, '2026-02-18 10:55:00-06'),
    ('Lampara de pie Vigia 165', 'Laton cepillado', NULL, '2026-02-18 10:55:00-06'),
    ('Lampara de pie Vigia 165', 'Nogal y laton', NULL, '2026-02-18 10:55:00-06'),
    ('Plafon LED Solaz 24', 'Blanco 24 W', NULL, '2026-02-19 10:59:00-06'),
    ('Farol solar de jardin Luciernaga', 'Negro mate', NULL, '2026-02-20 10:29:00-06'),
    ('Farol solar de jardin Luciernaga', 'Cobre envejecido', NULL, '2026-02-20 10:29:00-06'),
    ('Camisa de lino manga larga', 'S azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'M azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'L blanca', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa oxford clasica', 'M celeste', NULL, '2026-02-22 10:47:00-06'),
    ('Camisa oxford clasica', 'L celeste', NULL, '2026-02-22 10:47:00-06'),
    ('Camisa guayabera Xelaju', 'M blanca', NULL, '2026-02-23 10:01:00-06'),
    ('Camisa guayabera Xelaju', 'L hueso', NULL, '2026-02-23 10:01:00-06'),
    ('Camisa guayabera Xelaju', 'XL hueso', NULL, '2026-02-23 10:01:00-06'),
    ('Camisa de vestir Meridiano', 'M blanca', NULL, '2026-02-24 10:47:00-06'),
    ('Camisa de vestir Meridiano', 'L gris perla', NULL, '2026-02-24 10:47:00-06'),
    ('Camisa de mezclilla Remache', 'M azul indigo', NULL, '2026-02-25 10:02:00-06'),
    ('Camisa de mezclilla Remache', 'L azul claro', NULL, '2026-02-25 10:02:00-06'),
    ('Camisa polo pique Cardumen', 'M azul marino', NULL, '2026-02-26 10:34:00-06'),
    ('Pantalon chino resistente', '32 beige', NULL, '2026-02-27 10:30:00-06'),
    ('Pantalon chino resistente', '34 beige', NULL, '2026-02-27 10:30:00-06'),
    ('Pantalon chino resistente', '34 azul', NULL, '2026-02-27 10:30:00-06'),
    ('Pantalon de mezclilla Yunque', '32 indigo crudo', NULL, '2026-02-28 10:57:00-06'),
    ('Pantalon de mezclilla Yunque', '34 negro', NULL, '2026-02-28 10:57:00-06'),
    ('Pantalon cargo Vereda', '32 verde oliva', NULL, '2026-03-01 10:46:00-06'),
    ('Pantalon cargo Vereda', '34 arena', NULL, '2026-03-01 10:46:00-06'),
    ('Pantalon cargo Vereda', '36 negro', NULL, '2026-03-01 10:46:00-06'),
    ('Pantalon de vestir Consulado', '32 gris oxford', NULL, '2026-03-02 10:20:00-06'),
    ('Pantalon jogger Ocaso', 'M gris jaspe', NULL, '2026-03-03 10:57:00-06'),
    ('Pantalon jogger Ocaso', 'L negro', NULL, '2026-03-03 10:57:00-06'),
    ('Zapato de cuero Senda', '40 cafe', NULL, '2026-03-04 10:14:00-06'),
    ('Zapato de cuero Senda', '42 cafe', NULL, '2026-03-04 10:14:00-06'),
    ('Zapato de cuero Senda', '42 negro', NULL, '2026-03-04 10:14:00-06'),
    ('Bota impermeable Cumbre', '41', NULL, '2026-03-05 10:09:00-06'),
    ('Bota impermeable Cumbre', '43', NULL, '2026-03-05 10:09:00-06'),
    ('Tenis urbano Vereda 90', '39 blanco', NULL, '2026-03-06 10:37:00-06'),
    ('Tenis urbano Vereda 90', '41 blanco', NULL, '2026-03-06 10:37:00-06'),
    ('Tenis urbano Vereda 90', '43 gris', NULL, '2026-03-06 10:37:00-06'),
    ('Mocasin de gamuza Roble', '40 azul', NULL, '2026-03-07 10:45:00-06'),
    ('Mocasin de gamuza Roble', '42 arena', NULL, '2026-03-07 10:45:00-06'),
    ('Bota de trabajo Yunque S3', '40 negro', NULL, '2026-03-08 10:39:00-06'),
    ('Bota de trabajo Yunque S3', '42 negro', NULL, '2026-03-08 10:39:00-06'),
    ('Bota de trabajo Yunque S3', '44 miel', NULL, '2026-03-08 10:39:00-06'),
    ('Sandalia de cuero Litoral', '41 cafe', NULL, '2026-03-09 10:19:00-06'),
    ('Balon de futbol numero 5', 'Blanco', NULL, '2026-04-06 08:00:00-06'),
    ('Balon de futbol numero 5', 'Naranja', NULL, '2026-04-06 08:00:00-06'),
    ('Espinilleras Muralla', 'M', NULL, '2026-03-11 10:26:00-06'),
    ('Espinilleras Muralla', 'L', NULL, '2026-03-11 10:26:00-06'),
    ('Guantes de portero Zarpa 300', 'Talla 8', NULL, '2026-03-12 10:51:00-06'),
    ('Guantes de portero Zarpa 300', 'Talla 10', NULL, '2026-03-12 10:51:00-06'),
    ('Zapato de tacos Relampago FG', '40 negro', NULL, '2026-03-13 10:57:00-06'),
    ('Zapato de tacos Relampago FG', '42 negro', NULL, '2026-03-13 10:57:00-06'),
    ('Zapato de tacos Relampago FG', '42 rojo', NULL, '2026-03-13 10:57:00-06'),
    ('Red de porteria Trama 7 x 2', 'Par 7 x 2 m', NULL, '2026-03-14 10:14:00-06'),
    ('Uniforme de entrenamiento Cantera', 'M azul', NULL, '2026-03-15 10:07:00-06'),
    ('Uniforme de entrenamiento Cantera', 'L azul', NULL, '2026-03-15 10:07:00-06'),
    ('Uniforme de entrenamiento Cantera', 'L verde', NULL, '2026-03-15 10:07:00-06'),
    ('Casco de ruta Aerodino', 'M blanco', NULL, '2026-03-16 10:04:00-06'),
    ('Casco de ruta Aerodino', 'L negro', NULL, '2026-03-16 10:04:00-06'),
    ('Bomba de piso Piston', 'Estandar', NULL, '2026-03-17 10:22:00-06'),
    ('Guantes de ciclismo Palma Corta', 'S negro', NULL, '2026-03-18 10:15:00-06'),
    ('Guantes de ciclismo Palma Corta', 'M negro', NULL, '2026-03-18 10:15:00-06'),
    ('Guantes de ciclismo Palma Corta', 'L gris', NULL, '2026-03-18 10:15:00-06'),
    ('Sillin de ruta Vertebra SR-2', '143 mm', NULL, '2026-03-19 10:19:00-06'),
    ('Sillin de ruta Vertebra SR-2', '155 mm', NULL, '2026-03-19 10:19:00-06'),
    ('Maillot de ruta Peloton', 'M naranja', NULL, '2026-03-20 10:20:00-06'),
    ('Maillot de ruta Peloton', 'L naranja', NULL, '2026-03-20 10:20:00-06'),
    ('Maillot de ruta Peloton', 'L azul', NULL, '2026-03-20 10:20:00-06'),
    ('Candado plegable Cerrojo F8', 'Estandar', NULL, '2026-03-21 10:10:00-06'),
    ('Set de bandas elasticas', 'Set completo', NULL, '2026-03-22 10:04:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Verde', NULL, '2026-03-23 10:35:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Morado', NULL, '2026-03-23 10:35:00-06'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', NULL, '2026-03-24 10:18:00-06'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', NULL, '2026-03-24 10:18:00-06'),
    ('Pesa rusa Yunque', '12 kg', NULL, '2026-03-25 10:54:00-06'),
    ('Pesa rusa Yunque', '16 kg', NULL, '2026-03-25 10:54:00-06'),
    ('Pesa rusa Yunque', '20 kg', NULL, '2026-03-25 10:54:00-06'),
    ('Cuerda de salto Relampago', 'Cable de 3 m', NULL, '2026-03-26 10:05:00-06'),
    ('Rodillo de liberacion Nudo', '33 cm', NULL, '2026-03-27 10:47:00-06'),
    ('Rodillo de liberacion Nudo', '45 cm', NULL, '2026-03-27 10:47:00-06'),
    ('El camino de las nubes', 'Pasta blanda', NULL, '2026-05-20 09:00:00-06'),
    ('El camino de las nubes', 'Pasta dura', NULL, '2026-05-20 09:00:00-06'),
    ('Cuentos de la ceiba', 'Pasta blanda', NULL, '2026-04-01 10:23:00-06'),
    ('La casa de los relojes detenidos', 'Pasta blanda', NULL, '2026-04-02 10:31:00-06'),
    ('La casa de los relojes detenidos', 'Pasta dura', NULL, '2026-04-02 10:31:00-06'),
    ('Cartas al puerto seco', 'Digital', NULL, '2026-04-03 10:25:00-06'),
    ('Cartas al puerto seco', 'Pasta blanda', NULL, '2026-04-03 10:25:00-06'),
    ('Cartas al puerto seco', 'Pasta dura', NULL, '2026-04-03 10:25:00-06'),
    ('Nadie duerme en Tecpanal', 'Pasta dura', NULL, '2026-04-04 10:20:00-06'),
    ('Antologia del ruido', 'Pasta blanda', NULL, '2026-04-05 10:23:00-06'),
    ('Antologia del ruido', 'Edicion ilustrada', NULL, '2026-04-05 10:23:00-06'),
    ('Bases de datos distribuidas', 'Pasta dura', NULL, '2026-04-06 10:52:00-06'),
    ('Bases de datos distribuidas', 'Digital', NULL, '2026-04-06 10:52:00-06'),
    ('Redes industriales y buses de campo', 'Pasta blanda', NULL, '2026-04-07 10:34:00-06'),
    ('Redes industriales y buses de campo', 'Pasta dura', NULL, '2026-04-07 10:34:00-06'),
    ('Calculo numerico con ejercicios resueltos', 'Pasta blanda', NULL, '2026-04-08 10:45:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Pasta blanda', NULL, '2026-04-09 10:03:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Espiral', NULL, '2026-04-09 10:03:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Pasta dura', NULL, '2026-04-09 10:03:00-06'),
    ('Introduccion al modelado de sistemas embebidos', 'Pasta dura', NULL, '2026-04-10 10:07:00-06'),
    ('Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', NULL, '2026-04-10 10:07:00-06'),
    ('Serum de niacinamida 10%', '30 ml', NULL, '2026-04-11 10:30:00-06'),
    ('Serum de niacinamida 10%', '50 ml', NULL, '2026-04-11 10:30:00-06'),
    ('Protector solar mineral FPS 50', '50 ml', NULL, '2026-04-12 10:17:00-06'),
    ('Crema hidratante nocturna Alba', '50 ml', NULL, '2026-04-13 10:50:00-06'),
    ('Crema hidratante nocturna Alba', '100 ml', NULL, '2026-04-13 10:50:00-06'),
    ('Limpiador en gel Verdo', '150 ml', NULL, '2026-04-14 10:18:00-06'),
    ('Limpiador en gel Verdo', '250 ml', NULL, '2026-04-14 10:18:00-06'),
    ('Limpiador en gel Verdo', '400 ml', NULL, '2026-04-14 10:18:00-06'),
    ('Exfoliante enzimatico Papilo', '75 ml', NULL, '2026-04-15 10:09:00-06'),
    ('Contorno de ojos Lumine', '15 ml', NULL, '2026-04-16 10:27:00-06'),
    ('Contorno de ojos Lumine', '30 ml', NULL, '2026-04-16 10:27:00-06'),
    ('Eau de parfum Bruma', '50 ml', NULL, '2026-04-17 10:24:00-06'),
    ('Eau de parfum Bruma', '100 ml', NULL, '2026-04-17 10:24:00-06'),
    ('Eau de toilette Salino', '30 ml', NULL, '2026-04-18 10:04:00-06'),
    ('Eau de toilette Salino', '60 ml', NULL, '2026-04-18 10:04:00-06'),
    ('Eau de toilette Salino', '100 ml', NULL, '2026-04-18 10:04:00-06'),
    ('Agua de colonia Amanecer Citrico', '100 ml', NULL, '2026-04-19 10:57:00-06'),
    ('Agua de colonia Amanecer Citrico', '200 ml', NULL, '2026-04-19 10:57:00-06'),
    ('Bruma corporal Trebol Blanco', '200 ml', NULL, '2026-04-20 10:14:00-06'),
    ('Set descubrimiento Nocturno', 'Coleccion noche', NULL, '2026-04-21 10:48:00-06'),
    ('Set descubrimiento Nocturno', 'Coleccion dia', NULL, '2026-04-21 10:48:00-06')
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
    ('Laptop Bastion 16', 'Laptop Bastion 16', 'Estacion de trabajo de 16 pulgadas para render y compilacion.', 'Laptops', '2026-01-05 10:22:00-06'),
    ('Laptop Nimbo 13', 'Laptop Nimbo 13', 'Equipo de entrada para estudio y oficina, silencioso y sin ventilador.', 'Laptops', '2026-01-06 10:32:00-06'),
    ('Laptop Lienzo 15', 'Laptop Lienzo 15', 'Convertible de 15.6 pulgadas con bisagra de 360 grados y lapiz optico incluido.', 'Laptops', '2026-01-07 10:02:00-06'),
    ('Laptop Cumbre 17 Gamer', 'Laptop Cumbre 17 Gamer', 'Portatil de 17.3 pulgadas con refrigeracion de doble ventilador y teclado mecanico.', 'Laptops', '2026-01-08 10:38:00-06'),
    ('Laptop Vireo Air 12', 'Laptop Vireo Air 12', 'Netbook de 12.5 pulgadas para clases y navegacion, arranca en menos de diez segundos.', 'Laptops', '2026-01-09 10:34:00-06'),
    ('Laptop Ambar Campus 14', 'Laptop Ambar Campus 14', 'Chasis reforzado con bisagras probadas a diez mil aperturas, pensada para mochila.', 'Laptops', '2026-01-10 10:02:00-06'),
    ('Telefono Vela 7', 'Telefono Vela 7 Plus', 'Pantalla OLED de 6.4 pulgadas.', 'Telefonos', '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', 'Telefono Vela 7', 'Pantalla OLED de 6.4 pulgadas y camara principal de 50 MP.', 'Telefonos', '2026-03-24 14:00:00-06'),
    ('Telefono Ceibo Lite', 'Telefono Ceibo Lite', 'Bateria de dos dias y ranura para memoria expandible.', 'Telefonos', '2026-01-12 10:25:00-06'),
    ('Telefono Nautilo Pro', 'Telefono Nautilo Pro', 'Triple camara con teleobjetivo de tres aumentos y carga completa en treinta minutos.', 'Telefonos', '2026-01-13 10:15:00-06'),
    ('Telefono Pedernal Rugged', 'Telefono Pedernal Rugged', 'Carcasa con esquinas reforzadas y bateria de gran capacidad para trabajo de campo.', 'Telefonos', '2026-01-14 10:25:00-06'),
    ('Telefono Bruma Mini', 'Telefono Bruma Mini', 'Cuerpo compacto de 5.8 pulgadas que se maneja con una sola mano.', 'Telefonos', '2026-01-15 10:48:00-06'),
    ('Telefono Cuarzo Duo', 'Telefono Cuarzo Duo', 'Doble linea con dos ranuras SIM activas y radio FM sin auriculares.', 'Telefonos', '2026-01-16 10:15:00-06'),
    ('Audifonos Sereno ANC', 'Audifonos Sereno ANC', 'Diadema cerrada con cancelacion activa y estuche rigido.', 'Audifonos', '2026-01-17 10:05:00-06'),
    ('Audifonos Brisa Sport', 'Audifonos Brisa Sport', 'Intraurales con gancho de silicona, pensados para correr.', 'Audifonos', '2026-01-18 10:04:00-06'),
    ('Audifonos Estudio 900', 'Audifonos Estudio 900', 'Monitoreo de referencia con cable desmontable de 3 metros.', 'Audifonos', '2026-01-19 10:38:00-06'),
    ('Audifonos Colibri Micro TWS', 'Audifonos Colibri Micro TWS', 'Intraurales sin cable con estuche de carga del tamano de una caja de fosforos.', 'Audifonos', '2026-01-20 10:05:00-06'),
    ('Audifonos Marea Diadema Abierta', 'Audifonos Marea Diadema Abierta', 'Diadema de rejilla abierta con almohadillas de terciopelo reemplazables.', 'Audifonos', '2026-01-21 10:04:00-06'),
    ('Audifonos Duna Trabajo', 'Audifonos Duna Trabajo', 'Microfono de brazo abatible y base de carga de escritorio para llamadas largas.', 'Audifonos', '2026-01-22 10:16:00-06'),
    ('Audifonos Zumbo Cable', 'Audifonos Zumbo Cable', 'Intraurales con cable plano antienredos y control de una tecla.', 'Audifonos', '2026-01-23 10:25:00-06'),
    ('Monitor Horizonte 27', 'Monitor Horizonte 27', 'Panel IPS de 27 pulgadas con base ajustable en altura.', 'Monitores', '2026-01-24 10:48:00-06'),
    ('Monitor Panorama 34', 'Monitor Panorama 34', 'Ultrapanoramico curvo de 34 pulgadas, ideal para dos ventanas lado a lado.', 'Monitores', '2026-01-25 10:56:00-06'),
    ('Monitor Vitral 24', 'Monitor Vitral 24', 'Panel IPS de 23.8 pulgadas con entrada HDMI y DisplayPort, base fija.', 'Monitores', '2026-01-26 10:42:00-06'),
    ('Monitor Cenit 32 4K', 'Monitor Cenit 32 4K', 'Resolucion 4K en 31.5 pulgadas, con calibracion de fabrica y puerto USB-C de 65 W.', 'Monitores', '2026-01-27 10:27:00-06'),
    ('Monitor Vertice 27 Gamer', 'Monitor Vertice 27 Gamer', 'Panel de 27 pulgadas con sincronizacion adaptativa y tiempo de respuesta de 1 ms.', 'Monitores', '2026-01-28 10:20:00-06'),
    ('Monitor Nube 22', 'Monitor Nube 22', 'Monitor de 21.5 pulgadas para oficina, con altavoces integrados.', 'Monitores', '2026-02-01 10:26:00-06'),
    ('Cafetera Alba Espresso', 'Cafetera Alba Espresso', 'Cafetera de brazo con vaporizador.', 'Cocina', '2026-02-08 12:00:00-06'),
    ('Cafetera Alba Espresso', 'Cafetera Alba Espresso', 'Cafetera de brazo con vaporizador y bandeja recogegotas extraible.', 'Cocina', '2026-04-08 14:00:00-06'),
    ('Juego de ollas Fuego 5 piezas', 'Juego de ollas Fuego 5 piezas', 'Cinco piezas de acero tricapa con tapas de vidrio templado.', 'Cocina', '2026-02-03 10:59:00-06'),
    ('Licuadora Torbellino 1200', 'Licuadora Torbellino 1200', 'Vaso de vidrio y cuchillas de seis puntas para hielo.', 'Cocina', '2026-02-04 10:34:00-06'),
    ('Hervidor electrico Vapor 1.7', 'Hervidor electrico Vapor 1.7', 'Hervidor de 1.7 litros con apagado automatico y filtro antisarro extraible.', 'Cocina', '2026-02-05 10:52:00-06'),
    ('Cacerola honda Comal 18', 'Cacerola honda Comal 18', 'Cacerola de acero tricapa con tapa de vidrio templado y mango remachado.', 'Cocina', '2026-02-06 10:03:00-06'),
    ('Olla arrocera Grano 8 tazas', 'Olla arrocera Grano 8 tazas', 'Cocina hasta ocho tazas de arroz y pasa sola a mantener el calor.', 'Cocina', '2026-02-07 10:45:00-06'),
    ('Tabla de picar Cedro grande', 'Tabla de picar Cedro grande', 'Tabla de bambu de 40 por 28 cm con canal para jugos en las dos caras.', 'Cocina', '2026-02-08 10:16:00-06'),
    ('Escritorio Roble 120', 'Escritorio Roble 120', 'Tablero de 120 por 60 cm con pasacables y estructura de acero.', 'Muebles', '2026-02-09 10:57:00-06'),
    ('Silla ergonomica Vertebra', 'Silla ergonomica Vertebra', 'Respaldo de malla, soporte lumbar regulable y apoyabrazos 3D.', 'Muebles', '2026-02-10 10:26:00-06'),
    ('Librero Hoja 5 niveles', 'Librero Hoja 5 niveles', 'Cinco entrepanos de 80 cm de ancho, con anclaje de pared incluido.', 'Muebles', '2026-02-11 10:12:00-06'),
    ('Mesa de centro Guijarro', 'Mesa de centro Guijarro', 'Mesa baja de madera maciza de 100 por 55 cm, llega armada de fabrica.', 'Muebles', '2026-02-12 10:08:00-06'),
    ('Silla de comedor Vara', 'Silla de comedor Vara', 'Silla de madera de haya con respaldo de listones y asiento a 45 cm del piso.', 'Muebles', '2026-02-13 10:38:00-06'),
    ('Comoda Sendero 4 gavetas', 'Comoda Sendero 4 gavetas', 'Gavetas con correderas metalicas y tope antivuelco para fijar a la pared.', 'Muebles', '2026-02-14 10:20:00-06'),
    ('Lampara de escritorio Faro', 'Lampara de escritorio Faro', 'Brazo articulado con tres temperaturas de color y puerto USB.', 'Iluminacion', '2026-02-15 10:07:00-06'),
    ('Tira LED Aurora 5 m', 'Tira LED Aurora 5 m', 'Cinco metros regulables con control remoto y adhesivo 3M.', 'Iluminacion', '2026-02-16 10:30:00-06'),
    ('Lampara colgante Candela 40', 'Lampara colgante Candela 40', 'Pantalla tejida de mimbre de 40 cm de diametro con cable textil regulable.', 'Iluminacion', '2026-02-17 10:42:00-06'),
    ('Lampara de pie Vigia 165', 'Lampara de pie Vigia 165', 'Poste de 165 cm con pedal de encendido y difusor de tela orientable.', 'Iluminacion', '2026-02-18 10:55:00-06'),
    ('Plafon LED Solaz 24', 'Plafon LED Solaz 24', 'Plafon de superficie de 40 cm que se atornilla directo al techo, sin balastro.', 'Iluminacion', '2026-02-19 10:59:00-06'),
    ('Farol solar de jardin Luciernaga', 'Farol solar de jardin Luciernaga', 'Estaca para cesped con panel solar y sensor de anochecer, se clava sin cablear.', 'Iluminacion', '2026-02-20 10:29:00-06'),
    ('Camisa de lino manga larga', 'Camisa de lino', 'Camisa de lino de corte regular.', 'Camisas', '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'Camisa de lino', 'Lino lavado de corte regular con cuello italiano.', 'Camisas', '2026-03-04 11:30:00-06'),
    ('Camisa de lino manga larga', 'Camisa de lino manga larga', 'Lino lavado de corte regular con cuello italiano.', 'Camisas', '2026-05-04 14:00:00-06'),
    ('Camisa oxford clasica', 'Camisa oxford clasica', 'Oxford de algodon peinado, cuello con botones.', 'Camisas', '2026-02-22 10:47:00-06'),
    ('Camisa guayabera Xelaju', 'Camisa guayabera Xelaju', 'Guayabera de lino con cuatro bolsas y alforzas verticales al frente y a la espalda.', 'Camisas', '2026-02-23 10:01:00-06'),
    ('Camisa de vestir Meridiano', 'Camisa de vestir Meridiano', 'Popelina de algodon peinado con cuello semiingles y punos de gemelo opcional.', 'Camisas', '2026-02-24 10:47:00-06'),
    ('Camisa de mezclilla Remache', 'Camisa de mezclilla Remache', 'Mezclilla de 6 onzas con botones a presion y canesu doble en la espalda.', 'Camisas', '2026-02-25 10:02:00-06'),
    ('Camisa polo pique Cardumen', 'Camisa polo pique Cardumen', 'Pique de algodon con cuello acanalado y abertura de tres botones.', 'Camisas', '2026-02-26 10:34:00-06'),
    ('Pantalon chino resistente', 'Pantalon chino resistente', 'Sarga de algodon con elastano, corte recto.', 'Pantalones', '2026-02-27 10:30:00-06'),
    ('Pantalon de mezclilla Yunque', 'Pantalon de mezclilla Yunque', 'Mezclilla rigida de 13 onzas, cinco bolsas y remaches de cobre en los esfuerzos.', 'Pantalones', '2026-02-28 10:57:00-06'),
    ('Pantalon cargo Vereda', 'Pantalon cargo Vereda', 'Ripstop con seis bolsas, rodilla articulada y jareta en el tobillo.', 'Pantalones', '2026-03-01 10:46:00-06'),
    ('Pantalon de vestir Consulado', 'Pantalon de vestir Consulado', 'Lana fria de corte ajustado, con pretina interior antideslizante y bajo sin dobladillo.', 'Pantalones', '2026-03-02 10:20:00-06'),
    ('Pantalon jogger Ocaso', 'Pantalon jogger Ocaso', 'Felpa de algodon con cintura elastica, cordon plano y punos acanalados.', 'Pantalones', '2026-03-03 10:57:00-06'),
    ('Zapato de cuero Senda', 'Zapato de cuero Senda', 'Cuero vacuno con suela de goma cosida.', 'Zapatos', '2026-03-04 10:14:00-06'),
    ('Bota impermeable Cumbre', 'Bota impermeable Cumbre', 'Membrana impermeable y suela con agarre para roca mojada.', 'Zapatos', '2026-03-05 10:09:00-06'),
    ('Tenis urbano Vereda 90', 'Tenis urbano Vereda 90', 'Malla transpirable sobre suela de EVA inyectada, para caminar todo el dia.', 'Zapatos', '2026-03-06 10:37:00-06'),
    ('Mocasin de gamuza Roble', 'Mocasin de gamuza Roble', 'Gamuza sin forro con suela flexible de goma, se usa sin calcetin.', 'Zapatos', '2026-03-07 10:45:00-06'),
    ('Bota de trabajo Yunque S3', 'Bota de trabajo Yunque S3', 'Puntera de acero y plantilla antiperforacion, suela resistente a hidrocarburos.', 'Zapatos', '2026-03-08 10:39:00-06'),
    ('Sandalia de cuero Litoral', 'Sandalia de cuero Litoral', 'Tres tiras de cuero curtido con vegetales y hebilla de laton macizo.', 'Zapatos', '2026-03-09 10:19:00-06'),
    ('Balon de futbol numero 5', 'Balon de futbol numero 5', 'Costura termosellada, apto para cancha de grama sintetica.', 'Fitness', '2026-04-06 08:00:00-06'),
    ('Balon de futbol numero 5', 'Balon de futbol numero 5', 'Costura termosellada, apto para cancha de grama sintetica.', 'Futbol', '2026-06-06 14:00:00-06'),
    ('Espinilleras Muralla', 'Espinilleras Muralla', 'Placa rigida con espuma de alta densidad y mallas sujetadoras.', 'Futbol', '2026-03-11 10:26:00-06'),
    ('Guantes de portero Zarpa 300', 'Guantes de portero Zarpa 300', 'Latex de cuatro milimetros con corte negativo y correa elastica ancha.', 'Futbol', '2026-03-12 10:51:00-06'),
    ('Zapato de tacos Relampago FG', 'Zapato de tacos Relampago FG', 'Doce tacos conicos para grama natural firme y empeine de microfibra sin costuras.', 'Futbol', '2026-03-13 10:57:00-06'),
    ('Red de porteria Trama 7 x 2', 'Red de porteria Trama 7 x 2', 'Par de redes de malla trenzada para porteria reglamentaria, con ganchos incluidos.', 'Futbol', '2026-03-14 10:14:00-06'),
    ('Uniforme de entrenamiento Cantera', 'Uniforme de entrenamiento Cantera', 'Camiseta, pantaloneta y medias en tejido que seca rapido, sin numeracion.', 'Futbol', '2026-03-15 10:07:00-06'),
    ('Casco de ruta Aerodino', 'Casco de ruta Aerodino', 'Veintidos ventilaciones y ajuste micrometrico en la nuca.', 'Ciclismo', '2026-03-16 10:04:00-06'),
    ('Bomba de piso Piston', 'Bomba de piso Piston', 'Manometro analogico hasta 160 psi y cabezal para las dos valvulas.', 'Ciclismo', '2026-03-17 10:22:00-06'),
    ('Guantes de ciclismo Palma Corta', 'Guantes de ciclismo Palma Corta', 'Medio dedo con gel en la eminencia tenar y lengueta para quitarlos de un tiron.', 'Ciclismo', '2026-03-18 10:15:00-06'),
    ('Sillin de ruta Vertebra SR-2', 'Sillin de ruta Vertebra SR-2', 'Canal central aliviado y rieles de acero cromado compatibles con cualquier tija.', 'Ciclismo', '2026-03-19 10:19:00-06'),
    ('Maillot de ruta Peloton', 'Maillot de ruta Peloton', 'Cierre completo, tres bolsillos traseros y paneles de malla bajo los brazos.', 'Ciclismo', '2026-03-20 10:20:00-06'),
    ('Candado plegable Cerrojo F8', 'Candado plegable Cerrojo F8', 'Ocho barras de acero templado que se pliegan en una funda atornillable al cuadro.', 'Ciclismo', '2026-03-21 10:10:00-06'),
    ('Set de bandas elasticas', 'Set de bandas elasticas', 'Cinco bandas de latex con distinta resistencia y bolsa de malla.', 'Fitness', '2026-03-22 10:04:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Tapete de yoga Raiz 6 mm', 'Seis milimetros de TPE con superficie antideslizante en las dos caras.', 'Fitness', '2026-03-23 10:35:00-06'),
    ('Mancuernas ajustables Vertice 20 kg', 'Mancuernas ajustables Vertice 20 kg', 'Par de mancuernas con discos intercambiables de 1.25 a 5 kg y seguro de rosca.', 'Fitness', '2026-03-24 10:18:00-06'),
    ('Pesa rusa Yunque', 'Pesa rusa Yunque', 'Hierro fundido de una sola pieza con asa ancha para agarre a dos manos.', 'Fitness', '2026-03-25 10:54:00-06'),
    ('Cuerda de salto Relampago', 'Cuerda de salto Relampago', 'Cable de acero de tres metros con rodamientos, ajustable a la altura del usuario.', 'Fitness', '2026-03-26 10:05:00-06'),
    ('Rodillo de liberacion Nudo', 'Rodillo de liberacion Nudo', 'Rodillo de espuma con relieve en cuadros para masaje de cuadriceps y espalda alta.', 'Fitness', '2026-03-27 10:47:00-06'),
    ('El camino de las nubes', 'El camino de las nubes (primera edicion)', 'Novela de viaje por el altiplano, ganadora del premio nacional.', 'Literatura', '2026-05-20 09:00:00-06'),
    ('El camino de las nubes', 'El camino de las nubes', 'Novela de viaje por el altiplano, ganadora del premio nacional.', 'Literatura', '2026-07-20 14:00:00-06'),
    ('Cuentos de la ceiba', 'Cuentos de la ceiba', 'Doce relatos breves sobre la memoria y el desarraigo.', 'Literatura', '2026-04-01 10:23:00-06'),
    ('La casa de los relojes detenidos', 'La casa de los relojes detenidos', 'Novela sobre tres hermanas que heredan una relojeria y el silencio de su padre.', 'Literatura', '2026-04-02 10:31:00-06'),
    ('Cartas al puerto seco', 'Cartas al puerto seco', 'Novela epistolar entre un aduanero y una traductora que nunca llegan a conocerse.', 'Literatura', '2026-04-03 10:25:00-06'),
    ('Nadie duerme en Tecpanal', 'Nadie duerme en Tecpanal', 'Coral de un pueblo que pasa una noche entera esperando que baje el rio.', 'Literatura', '2026-04-04 10:20:00-06'),
    ('Antologia del ruido', 'Antologia del ruido', 'Poemario reunido de veinte anios de trabajo, con notas del propio autor.', 'Literatura', '2026-04-05 10:23:00-06'),
    ('Bases de datos distribuidas', 'Bases de datos distribuidas', 'Consistencia, particionado y replicacion, con ejercicios resueltos.', 'Tecnicos', '2026-04-06 10:52:00-06'),
    ('Redes industriales y buses de campo', 'Redes industriales y buses de campo', 'Topologias, temporizacion y diagnostico de fallas en Modbus, Profibus y CAN.', 'Tecnicos', '2026-04-07 10:34:00-06'),
    ('Calculo numerico con ejercicios resueltos', 'Calculo numerico con ejercicios resueltos', 'Metodos iterativos, interpolacion y error de redondeo, con 320 problemas resueltos.', 'Tecnicos', '2026-04-08 10:45:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Manual de instalaciones electricas residenciales', 'Calculo de cargas, calibres y protecciones para vivienda, con tablas desplegables.', 'Tecnicos', '2026-04-09 10:03:00-06'),
    ('Introduccion al modelado de sistemas embebidos', 'Introduccion al modelado de sistemas embebidos', 'Maquinas de estado, planificacion en tiempo real y consumo, sobre microcontroladores de 32 bits.', 'Tecnicos', '2026-04-10 10:07:00-06'),
    ('Serum de niacinamida 10%', 'Serum de niacinamida 10%', 'Serum ligero para textura y marcas, de uso nocturno.', 'Cuidado facial', '2026-04-11 10:30:00-06'),
    ('Protector solar mineral FPS 50', 'Protector solar mineral FPS 50', 'Filtro mineral sin fragancia, apto para piel sensible.', 'Cuidado facial', '2026-04-12 10:17:00-06'),
    ('Crema hidratante nocturna Alba', 'Crema hidratante nocturna Alba', 'Crema densa de uso nocturno, se absorbe sin dejar la cara brillante.', 'Cuidado facial', '2026-04-13 10:50:00-06'),
    ('Limpiador en gel Verdo', 'Limpiador en gel Verdo', 'Gel transparente que quita el exceso de grasa sin resecar la piel.', 'Cuidado facial', '2026-04-14 10:18:00-06'),
    ('Exfoliante enzimatico Papilo', 'Exfoliante enzimatico Papilo', 'Exfoliante sin granos: actua por enzimas y se enjuaga con agua tibia.', 'Cuidado facial', '2026-04-15 10:09:00-06'),
    ('Contorno de ojos Lumine', 'Contorno de ojos Lumine', 'Contorno ligero para bolsas y lineas finas, con aplicador frio de ceramica.', 'Cuidado facial', '2026-04-16 10:27:00-06'),
    ('Eau de parfum Bruma', 'Eau de parfum Bruma', 'Salida citrica, fondo amaderado, doce horas de fijacion.', 'Fragancias', '2026-04-17 10:24:00-06'),
    ('Eau de toilette Salino', 'Eau de toilette Salino', 'Salida de sal marina y salvia, con estela fresca de unas seis horas.', 'Fragancias', '2026-04-18 10:04:00-06'),
    ('Agua de colonia Amanecer Citrico', 'Agua de colonia Amanecer Citrico', 'Colonia citrica de uso diario, ligera y sin fondo dulce.', 'Fragancias', '2026-04-19 10:57:00-06'),
    ('Bruma corporal Trebol Blanco', 'Bruma corporal Trebol Blanco', 'Bruma ligera para el cuerpo y la ropa, floral y de poca fijacion.', 'Fragancias', '2026-04-20 10:14:00-06'),
    ('Set descubrimiento Nocturno', 'Set descubrimiento Nocturno', 'Cuatro viales de 8 ml para probar la linea antes de comprar el frasco.', 'Fragancias', '2026-04-21 10:48:00-06')
) AS v(clave, nombre, descripcion, hoja, fecha)
JOIN productos  p ON p.nombre = v.clave
JOIN categorias c ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;

INSERT INTO productos_variantes_historial (id_producto_variante, nombre_variante, descripcion, fecha_creacion)
SELECT pv.id_producto_variante, v.nombre_variante, v.descripcion, v.fecha::timestamptz
FROM (VALUES
    ('Laptop Aurora 14', '16 GB / 512 GB', '16 GB', NULL, '2026-01-04 10:52:00-06'),
    ('Laptop Aurora 14', '16 GB / 512 GB', '16 GB / 512 GB', NULL, '2026-03-04 14:00:00-06'),
    ('Laptop Aurora 14', '32 GB / 1 TB', '32 GB / 1 TB', NULL, '2026-01-04 10:52:00-06'),
    ('Laptop Bastion 16', '32 GB / 1 TB', '32 GB / 1 TB', NULL, '2026-01-05 10:22:00-06'),
    ('Laptop Bastion 16', '64 GB / 2 TB', '64 GB / 2 TB', NULL, '2026-01-05 10:22:00-06'),
    ('Laptop Nimbo 13', '8 GB / 256 GB', '8 GB / 256 GB', NULL, '2026-01-06 10:32:00-06'),
    ('Laptop Lienzo 15', '16 GB / 512 GB', '16 GB / 512 GB', NULL, '2026-01-07 10:02:00-06'),
    ('Laptop Lienzo 15', '16 GB / 1 TB', '16 GB / 1 TB', NULL, '2026-01-07 10:02:00-06'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', '32 GB / 1 TB', NULL, '2026-01-07 10:02:00-06'),
    ('Laptop Cumbre 17 Gamer', '32 GB / 1 TB', '32 GB / 1 TB', NULL, '2026-01-08 10:38:00-06'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', '64 GB / 2 TB', NULL, '2026-01-08 10:38:00-06'),
    ('Laptop Vireo Air 12', '8 GB / 128 GB', '8 GB / 128 GB', NULL, '2026-01-09 10:34:00-06'),
    ('Laptop Ambar Campus 14', '8 GB / 256 GB', '8 GB / 256 GB', NULL, '2026-01-10 10:02:00-06'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', '16 GB / 512 GB', NULL, '2026-01-10 10:02:00-06'),
    ('Telefono Vela 7', '128 GB', '128 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '256 GB', '256 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Vela 7', '512 GB', '512 GB', NULL, '2026-01-24 10:15:00-06'),
    ('Telefono Ceibo Lite', '64 GB', '64 GB', NULL, '2026-01-12 10:25:00-06'),
    ('Telefono Ceibo Lite', '128 GB', '128 GB', NULL, '2026-01-12 10:25:00-06'),
    ('Telefono Nautilo Pro', '256 GB', '256 GB', NULL, '2026-01-13 10:15:00-06'),
    ('Telefono Nautilo Pro', '512 GB', '512 GB', NULL, '2026-01-13 10:15:00-06'),
    ('Telefono Nautilo Pro', '1 TB', '1 TB', NULL, '2026-01-13 10:15:00-06'),
    ('Telefono Pedernal Rugged', '128 GB', '128 GB', NULL, '2026-01-14 10:25:00-06'),
    ('Telefono Pedernal Rugged', '256 GB', '256 GB', NULL, '2026-01-14 10:25:00-06'),
    ('Telefono Bruma Mini', '128 GB', '128 GB', NULL, '2026-01-15 10:48:00-06'),
    ('Telefono Cuarzo Duo', '32 GB', '32 GB', NULL, '2026-01-16 10:15:00-06'),
    ('Telefono Cuarzo Duo', '64 GB', '64 GB', NULL, '2026-01-16 10:15:00-06'),
    ('Audifonos Sereno ANC', 'Negro', 'Negro', NULL, '2026-01-17 10:05:00-06'),
    ('Audifonos Sereno ANC', 'Arena', 'Arena', NULL, '2026-01-17 10:05:00-06'),
    ('Audifonos Brisa Sport', 'Verde lima', 'Verde lima', NULL, '2026-01-18 10:04:00-06'),
    ('Audifonos Brisa Sport', 'Gris', 'Gris', NULL, '2026-01-18 10:04:00-06'),
    ('Audifonos Estudio 900', 'Cable 3 m', 'Cable 3 m', NULL, '2026-01-19 10:38:00-06'),
    ('Audifonos Colibri Micro TWS', 'Blanco perla', 'Blanco perla', NULL, '2026-01-20 10:05:00-06'),
    ('Audifonos Colibri Micro TWS', 'Negro mate', 'Negro mate', NULL, '2026-01-20 10:05:00-06'),
    ('Audifonos Colibri Micro TWS', 'Verde menta', 'Verde menta', NULL, '2026-01-20 10:05:00-06'),
    ('Audifonos Marea Diadema Abierta', 'Cable 2 m', 'Cable 2 m', NULL, '2026-01-21 10:04:00-06'),
    ('Audifonos Marea Diadema Abierta', 'Cable 4 m', 'Cable 4 m', NULL, '2026-01-21 10:04:00-06'),
    ('Audifonos Duna Trabajo', 'Grafito', 'Grafito', NULL, '2026-01-22 10:16:00-06'),
    ('Audifonos Duna Trabajo', 'Blanco hueso', 'Blanco hueso', NULL, '2026-01-22 10:16:00-06'),
    ('Audifonos Zumbo Cable', 'Cable 1.2 m', 'Cable 1.2 m', NULL, '2026-01-23 10:25:00-06'),
    ('Monitor Horizonte 27', '75 Hz', '75 Hz', NULL, '2026-01-24 10:48:00-06'),
    ('Monitor Horizonte 27', '165 Hz', '165 Hz', NULL, '2026-01-24 10:48:00-06'),
    ('Monitor Panorama 34', '100 Hz', '100 Hz', NULL, '2026-01-25 10:56:00-06'),
    ('Monitor Vitral 24', '75 Hz', '75 Hz', NULL, '2026-01-26 10:42:00-06'),
    ('Monitor Vitral 24', '100 Hz', '100 Hz', NULL, '2026-01-26 10:42:00-06'),
    ('Monitor Cenit 32 4K', '60 Hz', '60 Hz', NULL, '2026-01-27 10:27:00-06'),
    ('Monitor Vertice 27 Gamer', '144 Hz', '144 Hz', NULL, '2026-01-28 10:20:00-06'),
    ('Monitor Vertice 27 Gamer', '180 Hz', '180 Hz', NULL, '2026-01-28 10:20:00-06'),
    ('Monitor Vertice 27 Gamer', '240 Hz', '240 Hz', NULL, '2026-01-28 10:20:00-06'),
    ('Monitor Nube 22', 'Negro', 'Negro', NULL, '2026-02-01 10:26:00-06'),
    ('Monitor Nube 22', 'Blanco', 'Blanco', NULL, '2026-02-01 10:26:00-06'),
    ('Cafetera Alba Espresso', '1.5 L', '1.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Cafetera Alba Espresso', '2.5 L', '2.5 L', NULL, '2026-02-08 12:00:00-06'),
    ('Juego de ollas Fuego 5 piezas', 'Estandar', 'Estandar', NULL, '2026-02-03 10:59:00-06'),
    ('Licuadora Torbellino 1200', '1.5 L', '1.5 L', NULL, '2026-02-04 10:34:00-06'),
    ('Licuadora Torbellino 1200', '2 L', '2 L', NULL, '2026-02-04 10:34:00-06'),
    ('Hervidor electrico Vapor 1.7', 'Acero', 'Acero', NULL, '2026-02-05 10:52:00-06'),
    ('Hervidor electrico Vapor 1.7', 'Negro mate', 'Negro mate', NULL, '2026-02-05 10:52:00-06'),
    ('Cacerola honda Comal 18', '16 cm', '16 cm', NULL, '2026-02-06 10:03:00-06'),
    ('Cacerola honda Comal 18', '18 cm', '18 cm', NULL, '2026-02-06 10:03:00-06'),
    ('Cacerola honda Comal 18', '20 cm', '20 cm', NULL, '2026-02-06 10:03:00-06'),
    ('Olla arrocera Grano 8 tazas', '1.5 L', '1.5 L', NULL, '2026-02-07 10:45:00-06'),
    ('Olla arrocera Grano 8 tazas', '2.8 L', '2.8 L', NULL, '2026-02-07 10:45:00-06'),
    ('Tabla de picar Cedro grande', 'Grande', 'Grande', NULL, '2026-02-08 10:16:00-06'),
    ('Escritorio Roble 120', 'Natural', 'Natural', NULL, '2026-02-09 10:57:00-06'),
    ('Escritorio Roble 120', 'Nogal', 'Nogal', NULL, '2026-02-09 10:57:00-06'),
    ('Silla ergonomica Vertebra', 'Negra', 'Negra', NULL, '2026-02-10 10:26:00-06'),
    ('Silla ergonomica Vertebra', 'Gris', 'Gris', NULL, '2026-02-10 10:26:00-06'),
    ('Librero Hoja 5 niveles', '5 niveles roble', '5 niveles roble', NULL, '2026-02-11 10:12:00-06'),
    ('Librero Hoja 5 niveles', '6 niveles nogal', '6 niveles nogal', NULL, '2026-02-11 10:12:00-06'),
    ('Mesa de centro Guijarro', 'Natural', 'Natural', NULL, '2026-02-12 10:08:00-06'),
    ('Silla de comedor Vara', 'Natural', 'Natural', NULL, '2026-02-13 10:38:00-06'),
    ('Silla de comedor Vara', 'Negra', 'Negra', NULL, '2026-02-13 10:38:00-06'),
    ('Silla de comedor Vara', 'Tapizada gris', 'Tapizada gris', NULL, '2026-02-13 10:38:00-06'),
    ('Comoda Sendero 4 gavetas', '4 gavetas', '4 gavetas', NULL, '2026-02-14 10:20:00-06'),
    ('Comoda Sendero 4 gavetas', '6 gavetas', '6 gavetas', NULL, '2026-02-14 10:20:00-06'),
    ('Lampara de escritorio Faro', 'Blanca', 'Blanca', NULL, '2026-02-15 10:07:00-06'),
    ('Lampara de escritorio Faro', 'Negra', 'Negra', NULL, '2026-02-15 10:07:00-06'),
    ('Tira LED Aurora 5 m', 'Multicolor', 'Multicolor', NULL, '2026-02-16 10:30:00-06'),
    ('Lampara colgante Candela 40', 'Mimbre natural', 'Mimbre natural', NULL, '2026-02-17 10:42:00-06'),
    ('Lampara colgante Candela 40', 'Negro mate', 'Negro mate', NULL, '2026-02-17 10:42:00-06'),
    ('Lampara de pie Vigia 165', 'Negro', 'Negro', NULL, '2026-02-18 10:55:00-06'),
    ('Lampara de pie Vigia 165', 'Laton cepillado', 'Laton cepillado', NULL, '2026-02-18 10:55:00-06'),
    ('Lampara de pie Vigia 165', 'Nogal y laton', 'Nogal y laton', NULL, '2026-02-18 10:55:00-06'),
    ('Plafon LED Solaz 24', 'Blanco 24 W', 'Blanco 24 W', NULL, '2026-02-19 10:59:00-06'),
    ('Farol solar de jardin Luciernaga', 'Negro mate', 'Negro mate', NULL, '2026-02-20 10:29:00-06'),
    ('Farol solar de jardin Luciernaga', 'Cobre envejecido', 'Cobre envejecido', NULL, '2026-02-20 10:29:00-06'),
    ('Camisa de lino manga larga', 'S azul', 'S azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'M azul', 'Mediana azul', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa de lino manga larga', 'M azul', 'M azul', NULL, '2026-03-12 14:00:00-06'),
    ('Camisa de lino manga larga', 'L blanca', 'L blanca', NULL, '2026-01-12 09:00:00-06'),
    ('Camisa oxford clasica', 'M celeste', 'M celeste', NULL, '2026-02-22 10:47:00-06'),
    ('Camisa oxford clasica', 'L celeste', 'L celeste', NULL, '2026-02-22 10:47:00-06'),
    ('Camisa guayabera Xelaju', 'M blanca', 'M blanca', NULL, '2026-02-23 10:01:00-06'),
    ('Camisa guayabera Xelaju', 'L hueso', 'L hueso', NULL, '2026-02-23 10:01:00-06'),
    ('Camisa guayabera Xelaju', 'XL hueso', 'XL hueso', NULL, '2026-02-23 10:01:00-06'),
    ('Camisa de vestir Meridiano', 'M blanca', 'M blanca', NULL, '2026-02-24 10:47:00-06'),
    ('Camisa de vestir Meridiano', 'L gris perla', 'L gris perla', NULL, '2026-02-24 10:47:00-06'),
    ('Camisa de mezclilla Remache', 'M azul indigo', 'M azul indigo', NULL, '2026-02-25 10:02:00-06'),
    ('Camisa de mezclilla Remache', 'L azul claro', 'L azul claro', NULL, '2026-02-25 10:02:00-06'),
    ('Camisa polo pique Cardumen', 'M azul marino', 'M azul marino', NULL, '2026-02-26 10:34:00-06'),
    ('Pantalon chino resistente', '32 beige', '32 beige', NULL, '2026-02-27 10:30:00-06'),
    ('Pantalon chino resistente', '34 beige', '34 beige', NULL, '2026-02-27 10:30:00-06'),
    ('Pantalon chino resistente', '34 azul', '34 azul', NULL, '2026-02-27 10:30:00-06'),
    ('Pantalon de mezclilla Yunque', '32 indigo crudo', '32 indigo crudo', NULL, '2026-02-28 10:57:00-06'),
    ('Pantalon de mezclilla Yunque', '34 negro', '34 negro', NULL, '2026-02-28 10:57:00-06'),
    ('Pantalon cargo Vereda', '32 verde oliva', '32 verde oliva', NULL, '2026-03-01 10:46:00-06'),
    ('Pantalon cargo Vereda', '34 arena', '34 arena', NULL, '2026-03-01 10:46:00-06'),
    ('Pantalon cargo Vereda', '36 negro', '36 negro', NULL, '2026-03-01 10:46:00-06'),
    ('Pantalon de vestir Consulado', '32 gris oxford', '32 gris oxford', NULL, '2026-03-02 10:20:00-06'),
    ('Pantalon jogger Ocaso', 'M gris jaspe', 'M gris jaspe', NULL, '2026-03-03 10:57:00-06'),
    ('Pantalon jogger Ocaso', 'L negro', 'L negro', NULL, '2026-03-03 10:57:00-06'),
    ('Zapato de cuero Senda', '40 cafe', '40 cafe', NULL, '2026-03-04 10:14:00-06'),
    ('Zapato de cuero Senda', '42 cafe', '42 cafe', NULL, '2026-03-04 10:14:00-06'),
    ('Zapato de cuero Senda', '42 negro', '42 negro', NULL, '2026-03-04 10:14:00-06'),
    ('Bota impermeable Cumbre', '41', '41', NULL, '2026-03-05 10:09:00-06'),
    ('Bota impermeable Cumbre', '43', '43', NULL, '2026-03-05 10:09:00-06'),
    ('Tenis urbano Vereda 90', '39 blanco', '39 blanco', NULL, '2026-03-06 10:37:00-06'),
    ('Tenis urbano Vereda 90', '41 blanco', '41 blanco', NULL, '2026-03-06 10:37:00-06'),
    ('Tenis urbano Vereda 90', '43 gris', '43 gris', NULL, '2026-03-06 10:37:00-06'),
    ('Mocasin de gamuza Roble', '40 azul', '40 azul', NULL, '2026-03-07 10:45:00-06'),
    ('Mocasin de gamuza Roble', '42 arena', '42 arena', NULL, '2026-03-07 10:45:00-06'),
    ('Bota de trabajo Yunque S3', '40 negro', '40 negro', NULL, '2026-03-08 10:39:00-06'),
    ('Bota de trabajo Yunque S3', '42 negro', '42 negro', NULL, '2026-03-08 10:39:00-06'),
    ('Bota de trabajo Yunque S3', '44 miel', '44 miel', NULL, '2026-03-08 10:39:00-06'),
    ('Sandalia de cuero Litoral', '41 cafe', '41 cafe', NULL, '2026-03-09 10:19:00-06'),
    ('Balon de futbol numero 5', 'Blanco', 'Blanco', NULL, '2026-04-06 08:00:00-06'),
    ('Balon de futbol numero 5', 'Naranja', 'Naranja', NULL, '2026-04-06 08:00:00-06'),
    ('Espinilleras Muralla', 'M', 'M', NULL, '2026-03-11 10:26:00-06'),
    ('Espinilleras Muralla', 'L', 'L', NULL, '2026-03-11 10:26:00-06'),
    ('Guantes de portero Zarpa 300', 'Talla 8', 'Talla 8', NULL, '2026-03-12 10:51:00-06'),
    ('Guantes de portero Zarpa 300', 'Talla 10', 'Talla 10', NULL, '2026-03-12 10:51:00-06'),
    ('Zapato de tacos Relampago FG', '40 negro', '40 negro', NULL, '2026-03-13 10:57:00-06'),
    ('Zapato de tacos Relampago FG', '42 negro', '42 negro', NULL, '2026-03-13 10:57:00-06'),
    ('Zapato de tacos Relampago FG', '42 rojo', '42 rojo', NULL, '2026-03-13 10:57:00-06'),
    ('Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 'Par 7 x 2 m', NULL, '2026-03-14 10:14:00-06'),
    ('Uniforme de entrenamiento Cantera', 'M azul', 'M azul', NULL, '2026-03-15 10:07:00-06'),
    ('Uniforme de entrenamiento Cantera', 'L azul', 'L azul', NULL, '2026-03-15 10:07:00-06'),
    ('Uniforme de entrenamiento Cantera', 'L verde', 'L verde', NULL, '2026-03-15 10:07:00-06'),
    ('Casco de ruta Aerodino', 'M blanco', 'M blanco', NULL, '2026-03-16 10:04:00-06'),
    ('Casco de ruta Aerodino', 'L negro', 'L negro', NULL, '2026-03-16 10:04:00-06'),
    ('Bomba de piso Piston', 'Estandar', 'Estandar', NULL, '2026-03-17 10:22:00-06'),
    ('Guantes de ciclismo Palma Corta', 'S negro', 'S negro', NULL, '2026-03-18 10:15:00-06'),
    ('Guantes de ciclismo Palma Corta', 'M negro', 'M negro', NULL, '2026-03-18 10:15:00-06'),
    ('Guantes de ciclismo Palma Corta', 'L gris', 'L gris', NULL, '2026-03-18 10:15:00-06'),
    ('Sillin de ruta Vertebra SR-2', '143 mm', '143 mm', NULL, '2026-03-19 10:19:00-06'),
    ('Sillin de ruta Vertebra SR-2', '155 mm', '155 mm', NULL, '2026-03-19 10:19:00-06'),
    ('Maillot de ruta Peloton', 'M naranja', 'M naranja', NULL, '2026-03-20 10:20:00-06'),
    ('Maillot de ruta Peloton', 'L naranja', 'L naranja', NULL, '2026-03-20 10:20:00-06'),
    ('Maillot de ruta Peloton', 'L azul', 'L azul', NULL, '2026-03-20 10:20:00-06'),
    ('Candado plegable Cerrojo F8', 'Estandar', 'Estandar', NULL, '2026-03-21 10:10:00-06'),
    ('Set de bandas elasticas', 'Set completo', 'Set completo', NULL, '2026-03-22 10:04:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Verde', 'Verde', NULL, '2026-03-23 10:35:00-06'),
    ('Tapete de yoga Raiz 6 mm', 'Morado', 'Morado', NULL, '2026-03-23 10:35:00-06'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 'Par de 20 kg', NULL, '2026-03-24 10:18:00-06'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 'Par de 30 kg', NULL, '2026-03-24 10:18:00-06'),
    ('Pesa rusa Yunque', '12 kg', '12 kg', NULL, '2026-03-25 10:54:00-06'),
    ('Pesa rusa Yunque', '16 kg', '16 kg', NULL, '2026-03-25 10:54:00-06'),
    ('Pesa rusa Yunque', '20 kg', '20 kg', NULL, '2026-03-25 10:54:00-06'),
    ('Cuerda de salto Relampago', 'Cable de 3 m', 'Cable de 3 m', NULL, '2026-03-26 10:05:00-06'),
    ('Rodillo de liberacion Nudo', '33 cm', '33 cm', NULL, '2026-03-27 10:47:00-06'),
    ('Rodillo de liberacion Nudo', '45 cm', '45 cm', NULL, '2026-03-27 10:47:00-06'),
    ('El camino de las nubes', 'Pasta blanda', 'Pasta blanda', NULL, '2026-05-20 09:00:00-06'),
    ('El camino de las nubes', 'Pasta dura', 'Pasta dura', NULL, '2026-05-20 09:00:00-06'),
    ('Cuentos de la ceiba', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-01 10:23:00-06'),
    ('La casa de los relojes detenidos', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-02 10:31:00-06'),
    ('La casa de los relojes detenidos', 'Pasta dura', 'Pasta dura', NULL, '2026-04-02 10:31:00-06'),
    ('Cartas al puerto seco', 'Digital', 'Digital', NULL, '2026-04-03 10:25:00-06'),
    ('Cartas al puerto seco', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-03 10:25:00-06'),
    ('Cartas al puerto seco', 'Pasta dura', 'Pasta dura', NULL, '2026-04-03 10:25:00-06'),
    ('Nadie duerme en Tecpanal', 'Pasta dura', 'Pasta dura', NULL, '2026-04-04 10:20:00-06'),
    ('Antologia del ruido', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-05 10:23:00-06'),
    ('Antologia del ruido', 'Edicion ilustrada', 'Edicion ilustrada', NULL, '2026-04-05 10:23:00-06'),
    ('Bases de datos distribuidas', 'Pasta dura', 'Pasta dura', NULL, '2026-04-06 10:52:00-06'),
    ('Bases de datos distribuidas', 'Digital', 'Digital', NULL, '2026-04-06 10:52:00-06'),
    ('Redes industriales y buses de campo', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-07 10:34:00-06'),
    ('Redes industriales y buses de campo', 'Pasta dura', 'Pasta dura', NULL, '2026-04-07 10:34:00-06'),
    ('Calculo numerico con ejercicios resueltos', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-08 10:45:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Pasta blanda', 'Pasta blanda', NULL, '2026-04-09 10:03:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Espiral', 'Espiral', NULL, '2026-04-09 10:03:00-06'),
    ('Manual de instalaciones electricas residenciales', 'Pasta dura', 'Pasta dura', NULL, '2026-04-09 10:03:00-06'),
    ('Introduccion al modelado de sistemas embebidos', 'Pasta dura', 'Pasta dura', NULL, '2026-04-10 10:07:00-06'),
    ('Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 'Pasta dura con acceso digital', NULL, '2026-04-10 10:07:00-06'),
    ('Serum de niacinamida 10%', '30 ml', '30 ml', NULL, '2026-04-11 10:30:00-06'),
    ('Serum de niacinamida 10%', '50 ml', '50 ml', NULL, '2026-04-11 10:30:00-06'),
    ('Protector solar mineral FPS 50', '50 ml', '50 ml', NULL, '2026-04-12 10:17:00-06'),
    ('Crema hidratante nocturna Alba', '50 ml', '50 ml', NULL, '2026-04-13 10:50:00-06'),
    ('Crema hidratante nocturna Alba', '100 ml', '100 ml', NULL, '2026-04-13 10:50:00-06'),
    ('Limpiador en gel Verdo', '150 ml', '150 ml', NULL, '2026-04-14 10:18:00-06'),
    ('Limpiador en gel Verdo', '250 ml', '250 ml', NULL, '2026-04-14 10:18:00-06'),
    ('Limpiador en gel Verdo', '400 ml', '400 ml', NULL, '2026-04-14 10:18:00-06'),
    ('Exfoliante enzimatico Papilo', '75 ml', '75 ml', NULL, '2026-04-15 10:09:00-06'),
    ('Contorno de ojos Lumine', '15 ml', '15 ml', NULL, '2026-04-16 10:27:00-06'),
    ('Contorno de ojos Lumine', '30 ml', '30 ml', NULL, '2026-04-16 10:27:00-06'),
    ('Eau de parfum Bruma', '50 ml', '50 ml', NULL, '2026-04-17 10:24:00-06'),
    ('Eau de parfum Bruma', '100 ml', '100 ml', NULL, '2026-04-17 10:24:00-06'),
    ('Eau de toilette Salino', '30 ml', '30 ml', NULL, '2026-04-18 10:04:00-06'),
    ('Eau de toilette Salino', '60 ml', '60 ml', NULL, '2026-04-18 10:04:00-06'),
    ('Eau de toilette Salino', '100 ml', '100 ml', NULL, '2026-04-18 10:04:00-06'),
    ('Agua de colonia Amanecer Citrico', '100 ml', '100 ml', NULL, '2026-04-19 10:57:00-06'),
    ('Agua de colonia Amanecer Citrico', '200 ml', '200 ml', NULL, '2026-04-19 10:57:00-06'),
    ('Bruma corporal Trebol Blanco', '200 ml', '200 ml', NULL, '2026-04-20 10:14:00-06'),
    ('Set descubrimiento Nocturno', 'Coleccion noche', 'Coleccion noche', NULL, '2026-04-21 10:48:00-06'),
    ('Set descubrimiento Nocturno', 'Coleccion dia', 'Coleccion dia', NULL, '2026-04-21 10:48:00-06')
) AS v(producto, variante, nombre_variante, descripcion, fecha)
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante;

-- ============================================================
-- Los valores: 562 de producto y 448 de variante
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
    ('Laptop Lienzo 15', 'Marca', 'Lienzo'),
    ('Laptop Lienzo 15', 'Modelo', 'L15-Flex'),
    ('Laptop Lienzo 15', 'Pais de origen', 'Mexico'),
    ('Laptop Lienzo 15', 'Peso', '1.62'),
    ('Laptop Lienzo 15', 'Contenido del paquete', 'Laptop'),
    ('Laptop Lienzo 15', 'Contenido del paquete', 'Cargador de 65 W'),
    ('Laptop Lienzo 15', 'Contenido del paquete', 'Lapiz optico'),
    ('Laptop Cumbre 17 Gamer', 'Marca', 'Cumbre'),
    ('Laptop Cumbre 17 Gamer', 'Garantia', '24'),
    ('Laptop Cumbre 17 Gamer', 'Peso', '2.68'),
    ('Laptop Cumbre 17 Gamer', 'Duracion de la bateria', '5.5'),
    ('Laptop Cumbre 17 Gamer', 'Material principal', 'Aleacion de aluminio'),
    ('Laptop Cumbre 17 Gamer', 'Certificaciones', 'Energy Star'),
    ('Laptop Cumbre 17 Gamer', 'Certificaciones', 'RoHS'),
    ('Laptop Vireo Air 12', 'Marca', 'Vireo'),
    ('Laptop Vireo Air 12', 'Modelo', 'Air-12'),
    ('Laptop Vireo Air 12', 'Garantia', '12'),
    ('Laptop Vireo Air 12', 'Duracion de la bateria', '14'),
    ('Laptop Ambar Campus 14', 'Marca', 'Ambar'),
    ('Laptop Ambar Campus 14', 'Pais de origen', 'Taiwan'),
    ('Laptop Ambar Campus 14', 'Garantia', '18'),
    ('Laptop Ambar Campus 14', 'Material principal', 'Policarbonato reforzado'),
    ('Laptop Ambar Campus 14', 'Contenido del paquete', 'Laptop'),
    ('Laptop Ambar Campus 14', 'Contenido del paquete', 'Cargador'),
    ('Laptop Ambar Campus 14', 'Contenido del paquete', 'Funda de neopreno'),
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
    ('Telefono Nautilo Pro', 'Marca', 'Nautilo'),
    ('Telefono Nautilo Pro', 'Modelo', 'NP-9'),
    ('Telefono Nautilo Pro', 'Garantia', '24'),
    ('Telefono Nautilo Pro', 'Impermeable', 'true'),
    ('Telefono Nautilo Pro', 'Certificaciones', 'IP68'),
    ('Telefono Nautilo Pro', 'Certificaciones', 'CE'),
    ('Telefono Pedernal Rugged', 'Marca', 'Pedernal'),
    ('Telefono Pedernal Rugged', 'Modelo', 'R2'),
    ('Telefono Pedernal Rugged', 'Pais de origen', 'China'),
    ('Telefono Pedernal Rugged', 'Peso', '0.28'),
    ('Telefono Pedernal Rugged', 'Impermeable', 'true'),
    ('Telefono Pedernal Rugged', 'Duracion de la bateria', '72'),
    ('Telefono Bruma Mini', 'Marca', 'Bruma'),
    ('Telefono Bruma Mini', 'Garantia', '12'),
    ('Telefono Bruma Mini', 'Peso', '0.16'),
    ('Telefono Bruma Mini', 'Contenido del paquete', 'Telefono'),
    ('Telefono Bruma Mini', 'Contenido del paquete', 'Cable USB-C'),
    ('Telefono Bruma Mini', 'Contenido del paquete', 'Funda transparente'),
    ('Telefono Cuarzo Duo', 'Marca', 'Cuarzo'),
    ('Telefono Cuarzo Duo', 'Modelo', 'D2'),
    ('Telefono Cuarzo Duo', 'Pais de origen', 'Indonesia'),
    ('Telefono Cuarzo Duo', 'Garantia', '12'),
    ('Telefono Cuarzo Duo', 'Duracion de la bateria', '36'),
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
    ('Audifonos Colibri Micro TWS', 'Marca', 'Colibri'),
    ('Audifonos Colibri Micro TWS', 'Modelo', 'TWS-1'),
    ('Audifonos Colibri Micro TWS', 'Garantia', '12'),
    ('Audifonos Colibri Micro TWS', 'Inalambrico', 'true'),
    ('Audifonos Colibri Micro TWS', 'Duracion de la bateria', '28'),
    ('Audifonos Colibri Micro TWS', 'Peso', '0.045'),
    ('Audifonos Marea Diadema Abierta', 'Marca', 'Marea'),
    ('Audifonos Marea Diadema Abierta', 'Modelo', 'OA-70'),
    ('Audifonos Marea Diadema Abierta', 'Garantia', '24'),
    ('Audifonos Marea Diadema Abierta', 'Inalambrico', 'false'),
    ('Audifonos Marea Diadema Abierta', 'Peso', '0.34'),
    ('Audifonos Duna Trabajo', 'Marca', 'Duna'),
    ('Audifonos Duna Trabajo', 'Garantia', '24'),
    ('Audifonos Duna Trabajo', 'Inalambrico', 'true'),
    ('Audifonos Duna Trabajo', 'Duracion de la bateria', '45'),
    ('Audifonos Duna Trabajo', 'Contenido del paquete', 'Audifonos'),
    ('Audifonos Duna Trabajo', 'Contenido del paquete', 'Base de carga'),
    ('Audifonos Duna Trabajo', 'Contenido del paquete', 'Cable USB-C'),
    ('Audifonos Duna Trabajo', 'Contenido del paquete', 'Adaptador de avion'),
    ('Audifonos Zumbo Cable', 'Marca', 'Zumbo'),
    ('Audifonos Zumbo Cable', 'Modelo', 'C1'),
    ('Audifonos Zumbo Cable', 'Inalambrico', 'false'),
    ('Audifonos Zumbo Cable', 'Peso', '0.018'),
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
    ('Monitor Vitral 24', 'Marca', 'Vitral'),
    ('Monitor Vitral 24', 'Modelo', 'V24-IPS'),
    ('Monitor Vitral 24', 'Garantia', '24'),
    ('Monitor Vitral 24', 'Contenido del paquete', 'Monitor'),
    ('Monitor Vitral 24', 'Contenido del paquete', 'Base'),
    ('Monitor Vitral 24', 'Contenido del paquete', 'Cable HDMI'),
    ('Monitor Vitral 24', 'Contenido del paquete', 'Cable de poder'),
    ('Monitor Cenit 32 4K', 'Marca', 'Cenit'),
    ('Monitor Cenit 32 4K', 'Peso', '6.8'),
    ('Monitor Cenit 32 4K', 'Certificaciones', 'VESA DisplayHDR 400'),
    ('Monitor Cenit 32 4K', 'Certificaciones', 'Energy Star'),
    ('Monitor Cenit 32 4K', 'Material principal', 'Aluminio'),
    ('Monitor Vertice 27 Gamer', 'Marca', 'Vertice'),
    ('Monitor Vertice 27 Gamer', 'Modelo', 'VG27'),
    ('Monitor Vertice 27 Gamer', 'Garantia', '36'),
    ('Monitor Vertice 27 Gamer', 'Peso', '6.1'),
    ('Monitor Vertice 27 Gamer', 'Certificaciones', 'VESA AdaptiveSync Display'),
    ('Monitor Nube 22', 'Marca', 'Nube'),
    ('Monitor Nube 22', 'Modelo', 'N22'),
    ('Monitor Nube 22', 'Garantia', '12'),
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
    ('Hervidor electrico Vapor 1.7', 'Marca', 'Vapor'),
    ('Hervidor electrico Vapor 1.7', 'Material principal', 'Acero inoxidable'),
    ('Hervidor electrico Vapor 1.7', 'Potencia', '2000'),
    ('Hervidor electrico Vapor 1.7', 'Garantia', '12'),
    ('Hervidor electrico Vapor 1.7', 'Apto para lavavajillas', 'false'),
    ('Cacerola honda Comal 18', 'Marca', 'Comal'),
    ('Cacerola honda Comal 18', 'Material principal', 'Acero tricapa'),
    ('Cacerola honda Comal 18', 'Pais de origen', 'Italia'),
    ('Cacerola honda Comal 18', 'Garantia', '60'),
    ('Cacerola honda Comal 18', 'Peso', '1.35'),
    ('Cacerola honda Comal 18', 'Contenido del paquete', 'Cacerola'),
    ('Cacerola honda Comal 18', 'Contenido del paquete', 'Tapa de vidrio'),
    ('Olla arrocera Grano 8 tazas', 'Marca', 'Grano'),
    ('Olla arrocera Grano 8 tazas', 'Potencia', '700'),
    ('Olla arrocera Grano 8 tazas', 'Contenido del paquete', 'Olla arrocera'),
    ('Olla arrocera Grano 8 tazas', 'Contenido del paquete', 'Vaso medidor'),
    ('Olla arrocera Grano 8 tazas', 'Contenido del paquete', 'Paleta de servir'),
    ('Olla arrocera Grano 8 tazas', 'Contenido del paquete', 'Canasta vaporera'),
    ('Olla arrocera Grano 8 tazas', 'Apto para lavavajillas', 'true'),
    ('Tabla de picar Cedro grande', 'Marca', 'Cedro'),
    ('Tabla de picar Cedro grande', 'Material principal', 'Madera de bambu'),
    ('Tabla de picar Cedro grande', 'Apto para lavavajillas', 'false'),
    ('Tabla de picar Cedro grande', 'Peso', '1.4'),
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
    ('Librero Hoja 5 niveles', 'Marca', 'Hoja'),
    ('Librero Hoja 5 niveles', 'Modelo', 'L5'),
    ('Librero Hoja 5 niveles', 'Material principal', 'Aglomerado con chapa de roble'),
    ('Librero Hoja 5 niveles', 'Requiere ensamblaje', 'true'),
    ('Librero Hoja 5 niveles', 'Peso', '24'),
    ('Librero Hoja 5 niveles', 'Contenido del paquete', 'Paneles laterales'),
    ('Librero Hoja 5 niveles', 'Contenido del paquete', 'Entrepanos'),
    ('Librero Hoja 5 niveles', 'Contenido del paquete', 'Tornilleria'),
    ('Librero Hoja 5 niveles', 'Contenido del paquete', 'Llave allen'),
    ('Librero Hoja 5 niveles', 'Contenido del paquete', 'Anclaje de pared'),
    ('Mesa de centro Guijarro', 'Marca', 'Guijarro'),
    ('Mesa de centro Guijarro', 'Material principal', 'Madera de encino'),
    ('Mesa de centro Guijarro', 'Peso', '12.6'),
    ('Mesa de centro Guijarro', 'Pais de origen', 'Guatemala'),
    ('Mesa de centro Guijarro', 'Requiere ensamblaje', 'false'),
    ('Silla de comedor Vara', 'Marca', 'Vara'),
    ('Silla de comedor Vara', 'Modelo', 'C-02'),
    ('Silla de comedor Vara', 'Material principal', 'Madera de haya'),
    ('Silla de comedor Vara', 'Requiere ensamblaje', 'true'),
    ('Silla de comedor Vara', 'Garantia', '12'),
    ('Comoda Sendero 4 gavetas', 'Marca', 'Sendero'),
    ('Comoda Sendero 4 gavetas', 'Material principal', 'MDF laminado'),
    ('Comoda Sendero 4 gavetas', 'Peso', '31.5'),
    ('Comoda Sendero 4 gavetas', 'Requiere ensamblaje', 'true'),
    ('Comoda Sendero 4 gavetas', 'Garantia', '24'),
    ('Comoda Sendero 4 gavetas', 'Certificaciones', 'FSC Mix'),
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
    ('Lampara colgante Candela 40', 'Marca', 'Candela'),
    ('Lampara colgante Candela 40', 'Modelo', 'C40'),
    ('Lampara colgante Candela 40', 'Material principal', 'Mimbre natural'),
    ('Lampara colgante Candela 40', 'Potencia', '12'),
    ('Lampara colgante Candela 40', 'Peso', '1.35'),
    ('Lampara de pie Vigia 165', 'Marca', 'Vigia'),
    ('Lampara de pie Vigia 165', 'Modelo', 'P165'),
    ('Lampara de pie Vigia 165', 'Potencia', '18'),
    ('Lampara de pie Vigia 165', 'Garantia', '24'),
    ('Lampara de pie Vigia 165', 'Pais de origen', 'Polonia'),
    ('Lampara de pie Vigia 165', 'Peso', '4.6'),
    ('Plafon LED Solaz 24', 'Marca', 'Solaz'),
    ('Plafon LED Solaz 24', 'Potencia', '24'),
    ('Plafon LED Solaz 24', 'Garantia', '36'),
    ('Plafon LED Solaz 24', 'Certificaciones', 'CE'),
    ('Plafon LED Solaz 24', 'Certificaciones', 'RoHS'),
    ('Plafon LED Solaz 24', 'Certificaciones', 'Energy Star'),
    ('Plafon LED Solaz 24', 'Material principal', 'Acrilico opalino'),
    ('Farol solar de jardin Luciernaga', 'Marca', 'Luciernaga'),
    ('Farol solar de jardin Luciernaga', 'Modelo', 'Jardin 4'),
    ('Farol solar de jardin Luciernaga', 'Inalambrico', 'true'),
    ('Farol solar de jardin Luciernaga', 'Peso', '0.34'),
    ('Camisa de lino manga larga', 'Marca', 'Telar'),
    ('Camisa de lino manga larga', 'Material principal', 'Lino'),
    ('Camisa de lino manga larga', 'Pais de origen', 'Portugal'),
    ('Camisa oxford clasica', 'Marca', 'Telar'),
    ('Camisa oxford clasica', 'Material principal', 'Algodon'),
    ('Camisa oxford clasica', 'Origen del algodon', 'Peru'),
    ('Camisa oxford clasica', 'Certificaciones', 'OEKO-TEX Standard 100'),
    ('Camisa guayabera Xelaju', 'Marca', 'Xelaju'),
    ('Camisa guayabera Xelaju', 'Material principal', 'Lino'),
    ('Camisa guayabera Xelaju', 'Pais de origen', 'Guatemala'),
    ('Camisa guayabera Xelaju', 'Peso', '0.24'),
    ('Camisa de vestir Meridiano', 'Marca', 'Meridiano'),
    ('Camisa de vestir Meridiano', 'Modelo', 'MD-2'),
    ('Camisa de vestir Meridiano', 'Material principal', 'Algodon popelina'),
    ('Camisa de vestir Meridiano', 'Origen del algodon', 'Egipto'),
    ('Camisa de vestir Meridiano', 'Certificaciones', 'OEKO-TEX Standard 100'),
    ('Camisa de mezclilla Remache', 'Marca', 'Remache'),
    ('Camisa de mezclilla Remache', 'Modelo', 'R-14'),
    ('Camisa de mezclilla Remache', 'Material principal', 'Mezclilla de algodon'),
    ('Camisa de mezclilla Remache', 'Origen del algodon', 'Estados Unidos'),
    ('Camisa de mezclilla Remache', 'Pais de origen', 'Mexico'),
    ('Camisa de mezclilla Remache', 'Peso', '0.48'),
    ('Camisa polo pique Cardumen', 'Marca', 'Cardumen'),
    ('Camisa polo pique Cardumen', 'Material principal', 'Pique de algodon'),
    ('Camisa polo pique Cardumen', 'Origen del algodon', 'Peru'),
    ('Camisa polo pique Cardumen', 'Contenido del paquete', 'Camisa'),
    ('Camisa polo pique Cardumen', 'Contenido del paquete', 'Botones de repuesto'),
    ('Pantalon chino resistente', 'Marca', 'Rumbo'),
    ('Pantalon chino resistente', 'Material principal', 'Algodon y elastano'),
    ('Pantalon chino resistente', 'Pais de origen', 'Guatemala'),
    ('Pantalon de mezclilla Yunque', 'Marca', 'Yunque'),
    ('Pantalon de mezclilla Yunque', 'Modelo', 'Y-501'),
    ('Pantalon de mezclilla Yunque', 'Material principal', 'Mezclilla 13 oz'),
    ('Pantalon de mezclilla Yunque', 'Origen del algodon', 'Estados Unidos'),
    ('Pantalon de mezclilla Yunque', 'Peso', '0.72'),
    ('Pantalon cargo Vereda', 'Marca', 'Vereda'),
    ('Pantalon cargo Vereda', 'Material principal', 'Ripstop de algodon'),
    ('Pantalon cargo Vereda', 'Pais de origen', 'Vietnam'),
    ('Pantalon cargo Vereda', 'Peso', '0.58'),
    ('Pantalon de vestir Consulado', 'Marca', 'Consulado'),
    ('Pantalon de vestir Consulado', 'Modelo', 'CS-Slim'),
    ('Pantalon de vestir Consulado', 'Material principal', 'Lana fria'),
    ('Pantalon de vestir Consulado', 'Certificaciones', 'Woolmark'),
    ('Pantalon jogger Ocaso', 'Marca', 'Ocaso'),
    ('Pantalon jogger Ocaso', 'Material principal', 'Felpa de algodon'),
    ('Pantalon jogger Ocaso', 'Origen del algodon', 'India'),
    ('Zapato de cuero Senda', 'Marca', 'Senda'),
    ('Zapato de cuero Senda', 'Material principal', 'Cuero vacuno'),
    ('Zapato de cuero Senda', 'Pais de origen', 'Leon'),
    ('Zapato de cuero Senda', 'Peso', '0.82'),
    ('Bota impermeable Cumbre', 'Marca', 'Cumbre'),
    ('Bota impermeable Cumbre', 'Material principal', 'Nobuck'),
    ('Bota impermeable Cumbre', 'Impermeable', 'true'),
    ('Bota impermeable Cumbre', 'Garantia', '12'),
    ('Bota impermeable Cumbre', 'Peso', '1.15'),
    ('Tenis urbano Vereda 90', 'Marca', 'Vereda'),
    ('Tenis urbano Vereda 90', 'Modelo', 'V-90'),
    ('Tenis urbano Vereda 90', 'Material principal', 'Piel sintetica y malla'),
    ('Tenis urbano Vereda 90', 'Peso', '0.68'),
    ('Mocasin de gamuza Roble', 'Marca', 'Roble'),
    ('Mocasin de gamuza Roble', 'Material principal', 'Gamuza'),
    ('Mocasin de gamuza Roble', 'Pais de origen', 'Espana'),
    ('Mocasin de gamuza Roble', 'Garantia', '6'),
    ('Mocasin de gamuza Roble', 'Peso', '0.74'),
    ('Bota de trabajo Yunque S3', 'Marca', 'Yunque'),
    ('Bota de trabajo Yunque S3', 'Modelo', 'S3-Punta'),
    ('Bota de trabajo Yunque S3', 'Material principal', 'Cuero graso'),
    ('Bota de trabajo Yunque S3', 'Impermeable', 'true'),
    ('Bota de trabajo Yunque S3', 'Certificaciones', 'EN ISO 20345 S3'),
    ('Bota de trabajo Yunque S3', 'Certificaciones', 'ASTM F2413'),
    ('Bota de trabajo Yunque S3', 'Peso', '1.42'),
    ('Sandalia de cuero Litoral', 'Marca', 'Litoral'),
    ('Sandalia de cuero Litoral', 'Material principal', 'Cuero curtido vegetal'),
    ('Sandalia de cuero Litoral', 'Pais de origen', 'Guatemala'),
    ('Sandalia de cuero Litoral', 'Impermeable', 'false'),
    ('Balon de futbol numero 5', 'Marca', 'Portero'),
    ('Balon de futbol numero 5', 'Material principal', 'Poliuretano'),
    ('Balon de futbol numero 5', 'Certificaciones', 'FIFA Basic'),
    ('Balon de futbol numero 5', 'Peso', '0.43'),
    ('Espinilleras Muralla', 'Marca', 'Muralla'),
    ('Espinilleras Muralla', 'Material principal', 'Polipropileno'),
    ('Espinilleras Muralla', 'Peso', '0.16'),
    ('Guantes de portero Zarpa 300', 'Marca', 'Zarpa'),
    ('Guantes de portero Zarpa 300', 'Modelo', 'G300'),
    ('Guantes de portero Zarpa 300', 'Material principal', 'Latex y neopreno'),
    ('Guantes de portero Zarpa 300', 'Peso', '0.22'),
    ('Guantes de portero Zarpa 300', 'Contenido del paquete', 'Par de guantes'),
    ('Guantes de portero Zarpa 300', 'Contenido del paquete', 'Bolsa de malla'),
    ('Zapato de tacos Relampago FG', 'Marca', 'Relampago'),
    ('Zapato de tacos Relampago FG', 'Material principal', 'Microfibra'),
    ('Zapato de tacos Relampago FG', 'Peso', '0.24'),
    ('Zapato de tacos Relampago FG', 'Pais de origen', 'Vietnam'),
    ('Red de porteria Trama 7 x 2', 'Marca', 'Trama'),
    ('Red de porteria Trama 7 x 2', 'Modelo', 'R72'),
    ('Red de porteria Trama 7 x 2', 'Material principal', 'Polipropileno trenzado'),
    ('Red de porteria Trama 7 x 2', 'Peso', '4.6'),
    ('Red de porteria Trama 7 x 2', 'Garantia', '12'),
    ('Red de porteria Trama 7 x 2', 'Contenido del paquete', 'Dos redes'),
    ('Red de porteria Trama 7 x 2', 'Contenido del paquete', 'Cincuenta ganchos plasticos'),
    ('Red de porteria Trama 7 x 2', 'Contenido del paquete', 'Bolsa de transporte'),
    ('Uniforme de entrenamiento Cantera', 'Marca', 'Cantera'),
    ('Uniforme de entrenamiento Cantera', 'Material principal', 'Poliester reciclado'),
    ('Uniforme de entrenamiento Cantera', 'Certificaciones', 'OEKO-TEX Standard 100'),
    ('Uniforme de entrenamiento Cantera', 'Contenido del paquete', 'Camiseta'),
    ('Uniforme de entrenamiento Cantera', 'Contenido del paquete', 'Pantaloneta'),
    ('Uniforme de entrenamiento Cantera', 'Contenido del paquete', 'Par de medias'),
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
    ('Guantes de ciclismo Palma Corta', 'Marca', 'Palma'),
    ('Guantes de ciclismo Palma Corta', 'Material principal', 'Gamuza sintetica y lycra'),
    ('Guantes de ciclismo Palma Corta', 'Peso', '0.09'),
    ('Guantes de ciclismo Palma Corta', 'Pais de origen', 'Taiwan'),
    ('Sillin de ruta Vertebra SR-2', 'Marca', 'Vertebra'),
    ('Sillin de ruta Vertebra SR-2', 'Modelo', 'SR-2'),
    ('Sillin de ruta Vertebra SR-2', 'Material principal', 'Base de nailon y rieles de acero'),
    ('Sillin de ruta Vertebra SR-2', 'Garantia', '24'),
    ('Sillin de ruta Vertebra SR-2', 'Peso', '0.29'),
    ('Maillot de ruta Peloton', 'Marca', 'Peloton'),
    ('Maillot de ruta Peloton', 'Material principal', 'Poliester con paneles de malla'),
    ('Maillot de ruta Peloton', 'Pais de origen', 'Colombia'),
    ('Maillot de ruta Peloton', 'Peso', '0.16'),
    ('Maillot de ruta Peloton', 'Certificaciones', 'OEKO-TEX Standard 100'),
    ('Candado plegable Cerrojo F8', 'Marca', 'Cerrojo'),
    ('Candado plegable Cerrojo F8', 'Modelo', 'F8'),
    ('Candado plegable Cerrojo F8', 'Material principal', 'Acero templado'),
    ('Candado plegable Cerrojo F8', 'Garantia', '36'),
    ('Candado plegable Cerrojo F8', 'Peso', '1.05'),
    ('Candado plegable Cerrojo F8', 'Certificaciones', 'Sold Secure Silver'),
    ('Set de bandas elasticas', 'Marca', 'Tension'),
    ('Set de bandas elasticas', 'Material principal', 'Latex natural'),
    ('Set de bandas elasticas', 'Nivel de resistencia', 'Progresiva 5 a 25 kg'),
    ('Set de bandas elasticas', 'Contenido del paquete', '5 bandas'),
    ('Set de bandas elasticas', 'Contenido del paquete', 'Bolsa de malla'),
    ('Set de bandas elasticas', 'Contenido del paquete', 'Guia de ejercicios'),
    ('Tapete de yoga Raiz 6 mm', 'Marca', 'Raiz'),
    ('Tapete de yoga Raiz 6 mm', 'Material principal', 'TPE'),
    ('Tapete de yoga Raiz 6 mm', 'Peso', '1.1'),
    ('Mancuernas ajustables Vertice 20 kg', 'Marca', 'Vertice'),
    ('Mancuernas ajustables Vertice 20 kg', 'Modelo', 'AJ-20'),
    ('Mancuernas ajustables Vertice 20 kg', 'Material principal', 'Acero con recubrimiento de goma'),
    ('Mancuernas ajustables Vertice 20 kg', 'Peso', '20.4'),
    ('Mancuernas ajustables Vertice 20 kg', 'Contenido del paquete', '2 barras cortas'),
    ('Mancuernas ajustables Vertice 20 kg', 'Contenido del paquete', 'Discos de 1.25 a 5 kg'),
    ('Mancuernas ajustables Vertice 20 kg', 'Contenido del paquete', 'Llave de seguro'),
    ('Pesa rusa Yunque', 'Marca', 'Yunque'),
    ('Pesa rusa Yunque', 'Material principal', 'Hierro fundido con recubrimiento vinilico'),
    ('Pesa rusa Yunque', 'Pais de origen', 'Mexico'),
    ('Pesa rusa Yunque', 'Certificaciones', 'ISO 20957'),
    ('Cuerda de salto Relampago', 'Marca', 'Relampago'),
    ('Cuerda de salto Relampago', 'Material principal', 'Cable de acero forrado en PVC'),
    ('Cuerda de salto Relampago', 'Nivel de resistencia', 'Rodamiento rapido para doble salto'),
    ('Cuerda de salto Relampago', 'Peso', '0.24'),
    ('Rodillo de liberacion Nudo', 'Marca', 'Nudo'),
    ('Rodillo de liberacion Nudo', 'Modelo', 'R33'),
    ('Rodillo de liberacion Nudo', 'Material principal', 'EVA de alta densidad'),
    ('Rodillo de liberacion Nudo', 'Nivel de resistencia', 'Firme'),
    ('Rodillo de liberacion Nudo', 'Peso', '0.62'),
    ('Rodillo de liberacion Nudo', 'Contenido del paquete', 'Rodillo'),
    ('Rodillo de liberacion Nudo', 'Contenido del paquete', 'Poster de rutinas'),
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
    ('La casa de los relojes detenidos', 'Autor', 'Ines Marroquin'),
    ('La casa de los relojes detenidos', 'Editorial', 'Vagalume'),
    ('La casa de los relojes detenidos', 'Paginas', '344'),
    ('La casa de los relojes detenidos', 'Idioma', 'Espanol'),
    ('La casa de los relojes detenidos', 'Anio de publicacion', '2023'),
    ('La casa de los relojes detenidos', 'Peso', '0.48'),
    ('Cartas al puerto seco', 'Autor', 'Baltasar Quinones'),
    ('Cartas al puerto seco', 'Editorial', 'Sombrilla Roja'),
    ('Cartas al puerto seco', 'Paginas', '228'),
    ('Cartas al puerto seco', 'Anio de publicacion', '2021'),
    ('Nadie duerme en Tecpanal', 'Autor', 'Mariela Sandoval'),
    ('Nadie duerme en Tecpanal', 'Editorial', 'Tinta Nocturna'),
    ('Nadie duerme en Tecpanal', 'Paginas', '412'),
    ('Nadie duerme en Tecpanal', 'Idioma', 'Espanol'),
    ('Nadie duerme en Tecpanal', 'Pais de origen', 'Guatemala'),
    ('Nadie duerme en Tecpanal', 'Material principal', 'Papel bond ahuesado'),
    ('Antologia del ruido', 'Autor', 'Efrain Toledo'),
    ('Antologia del ruido', 'Editorial', 'Guacamayo'),
    ('Antologia del ruido', 'Paginas', '148'),
    ('Antologia del ruido', 'Anio de publicacion', '2025'),
    ('Antologia del ruido', 'Certificaciones', 'FSC Mixto'),
    ('Bases de datos distribuidas', 'Autor', 'H. Ortega'),
    ('Bases de datos distribuidas', 'Editorial', 'Tecnos'),
    ('Bases de datos distribuidas', 'Paginas', '540'),
    ('Bases de datos distribuidas', 'Idioma', 'Espanol'),
    ('Bases de datos distribuidas', 'Anio de publicacion', '2025'),
    ('Redes industriales y buses de campo', 'Autor', 'M. Zelaya'),
    ('Redes industriales y buses de campo', 'Editorial', 'Arista Tecnica'),
    ('Redes industriales y buses de campo', 'Paginas', '468'),
    ('Redes industriales y buses de campo', 'Idioma', 'Espanol'),
    ('Redes industriales y buses de campo', 'Anio de publicacion', '2024'),
    ('Redes industriales y buses de campo', 'Peso', '1.05'),
    ('Calculo numerico con ejercicios resueltos', 'Autor', 'L. Barrientos'),
    ('Calculo numerico con ejercicios resueltos', 'Editorial', 'Nodo Editorial'),
    ('Calculo numerico con ejercicios resueltos', 'Paginas', '612'),
    ('Calculo numerico con ejercicios resueltos', 'Anio de publicacion', '2023'),
    ('Manual de instalaciones electricas residenciales', 'Autor', 'C. Pineda'),
    ('Manual de instalaciones electricas residenciales', 'Editorial', 'Meridiano'),
    ('Manual de instalaciones electricas residenciales', 'Paginas', '288'),
    ('Manual de instalaciones electricas residenciales', 'Idioma', 'Espanol'),
    ('Manual de instalaciones electricas residenciales', 'Pais de origen', 'Colombia'),
    ('Manual de instalaciones electricas residenciales', 'Material principal', 'Papel offset de 90 g'),
    ('Introduccion al modelado de sistemas embebidos', 'Autor', 'R. Villagran'),
    ('Introduccion al modelado de sistemas embebidos', 'Editorial', 'Compendio Austral'),
    ('Introduccion al modelado de sistemas embebidos', 'Paginas', '524'),
    ('Introduccion al modelado de sistemas embebidos', 'Certificaciones', 'FSC Mixto'),
    ('Introduccion al modelado de sistemas embebidos', 'Peso', '1.18'),
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
    ('Crema hidratante nocturna Alba', 'Marca', 'Alba'),
    ('Crema hidratante nocturna Alba', 'Modelo', 'AN-50'),
    ('Crema hidratante nocturna Alba', 'Tipo de piel', 'Seca'),
    ('Crema hidratante nocturna Alba', 'Ingredientes destacados', 'Acido hialuronico'),
    ('Crema hidratante nocturna Alba', 'Ingredientes destacados', 'Manteca de karite'),
    ('Crema hidratante nocturna Alba', 'Peso', '0.12'),
    ('Limpiador en gel Verdo', 'Marca', 'Verdo'),
    ('Limpiador en gel Verdo', 'Tipo de piel', 'Grasa'),
    ('Limpiador en gel Verdo', 'Pais de origen', 'Mexico'),
    ('Limpiador en gel Verdo', 'Contenido del paquete', 'Frasco con dosificador'),
    ('Limpiador en gel Verdo', 'Contenido del paquete', 'Guia de uso'),
    ('Exfoliante enzimatico Papilo', 'Marca', 'Papilo'),
    ('Exfoliante enzimatico Papilo', 'Modelo', 'EZ-2'),
    ('Exfoliante enzimatico Papilo', 'Ingredientes destacados', 'Enzima de papaya'),
    ('Exfoliante enzimatico Papilo', 'Ingredientes destacados', 'Avena coloidal'),
    ('Exfoliante enzimatico Papilo', 'Certificaciones', 'No testeado en animales'),
    ('Exfoliante enzimatico Papilo', 'Certificaciones', 'Vegano'),
    ('Exfoliante enzimatico Papilo', 'Peso', '0.09'),
    ('Contorno de ojos Lumine', 'Marca', 'Lumine'),
    ('Contorno de ojos Lumine', 'Tipo de piel', 'Todo tipo'),
    ('Contorno de ojos Lumine', 'Pais de origen', 'Corea del Sur'),
    ('Contorno de ojos Lumine', 'Certificaciones', 'Dermatologicamente probado'),
    ('Contorno de ojos Lumine', 'Contenido del paquete', 'Frasco'),
    ('Contorno de ojos Lumine', 'Contenido del paquete', 'Aplicador de ceramica'),
    ('Contorno de ojos Lumine', 'Peso', '0.05'),
    ('Eau de parfum Bruma', 'Marca', 'Bruma'),
    ('Eau de parfum Bruma', 'Tipo de fragancia', 'Amaderada citrica'),
    ('Eau de parfum Bruma', 'Pais de origen', 'Francia'),
    ('Eau de parfum Bruma', 'Ingredientes destacados', 'Bergamota'),
    ('Eau de parfum Bruma', 'Ingredientes destacados', 'Cedro'),
    ('Eau de parfum Bruma', 'Ingredientes destacados', 'Vetiver'),
    ('Eau de toilette Salino', 'Marca', 'Salino'),
    ('Eau de toilette Salino', 'Tipo de fragancia', 'Acuatica fresca'),
    ('Eau de toilette Salino', 'Pais de origen', 'Espana'),
    ('Eau de toilette Salino', 'Ingredientes destacados', 'Sal marina'),
    ('Eau de toilette Salino', 'Ingredientes destacados', 'Salvia'),
    ('Eau de toilette Salino', 'Ingredientes destacados', 'Ambar blanco'),
    ('Agua de colonia Amanecer Citrico', 'Marca', 'Amanecer'),
    ('Agua de colonia Amanecer Citrico', 'Tipo de fragancia', 'Citrica fresca'),
    ('Agua de colonia Amanecer Citrico', 'Certificaciones', 'Vegano'),
    ('Agua de colonia Amanecer Citrico', 'Certificaciones', 'No testeado en animales'),
    ('Agua de colonia Amanecer Citrico', 'Contenido del paquete', 'Frasco'),
    ('Agua de colonia Amanecer Citrico', 'Contenido del paquete', 'Atomizador de repuesto'),
    ('Agua de colonia Amanecer Citrico', 'Peso', '0.34'),
    ('Bruma corporal Trebol Blanco', 'Marca', 'Trebol'),
    ('Bruma corporal Trebol Blanco', 'Tipo de fragancia', 'Floral verde'),
    ('Bruma corporal Trebol Blanco', 'Pais de origen', 'Guatemala'),
    ('Bruma corporal Trebol Blanco', 'Ingredientes destacados', 'Trebol'),
    ('Bruma corporal Trebol Blanco', 'Ingredientes destacados', 'Almizcle blanco'),
    ('Bruma corporal Trebol Blanco', 'Contenido del paquete', 'Frasco con atomizador'),
    ('Set descubrimiento Nocturno', 'Marca', 'Nocturno'),
    ('Set descubrimiento Nocturno', 'Tipo de fragancia', 'Oriental amaderada'),
    ('Set descubrimiento Nocturno', 'Certificaciones', 'Cruelty free'),
    ('Set descubrimiento Nocturno', 'Contenido del paquete', 'Cuatro viales de 8 ml'),
    ('Set descubrimiento Nocturno', 'Contenido del paquete', 'Tarjeta de notas olfativas'),
    ('Set descubrimiento Nocturno', 'Peso', '0.18'),
    ('Set descubrimiento Nocturno', 'Garantia', '6')
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
    ('Laptop Lienzo 15', '16 GB / 512 GB', 'Memoria RAM', '16'),
    ('Laptop Lienzo 15', '16 GB / 512 GB', 'Almacenamiento', '512'),
    ('Laptop Lienzo 15', '16 GB / 512 GB', 'Tamano de pantalla', '15.6'),
    ('Laptop Lienzo 15', '16 GB / 512 GB', 'Color', 'Plata perla'),
    ('Laptop Lienzo 15', '16 GB / 1 TB', 'Memoria RAM', '16'),
    ('Laptop Lienzo 15', '16 GB / 1 TB', 'Almacenamiento', '1024'),
    ('Laptop Lienzo 15', '16 GB / 1 TB', 'Tamano de pantalla', '15.6'),
    ('Laptop Lienzo 15', '16 GB / 1 TB', 'Color', 'Plata perla'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', 'Memoria RAM', '32'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', 'Almacenamiento', '1024'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', 'Tamano de pantalla', '15.6'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', 'Color', 'Azul acero'),
    ('Laptop Lienzo 15', '32 GB / 1 TB', 'Acabado', 'Satinado'),
    ('Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 'Memoria RAM', '32'),
    ('Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 'Almacenamiento', '1024'),
    ('Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 'Tamano de pantalla', '17.3'),
    ('Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 'Color', 'Negro obsidiana'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 'Memoria RAM', '64'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 'Almacenamiento', '2048'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 'Tamano de pantalla', '17.3'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 'Color', 'Negro obsidiana'),
    ('Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 'Acabado', 'Mate'),
    ('Laptop Vireo Air 12', '8 GB / 128 GB', 'Memoria RAM', '8'),
    ('Laptop Vireo Air 12', '8 GB / 128 GB', 'Almacenamiento', '128'),
    ('Laptop Vireo Air 12', '8 GB / 128 GB', 'Tamano de pantalla', '12.5'),
    ('Laptop Vireo Air 12', '8 GB / 128 GB', 'Color', 'Blanco hueso'),
    ('Laptop Ambar Campus 14', '8 GB / 256 GB', 'Memoria RAM', '8'),
    ('Laptop Ambar Campus 14', '8 GB / 256 GB', 'Almacenamiento', '256'),
    ('Laptop Ambar Campus 14', '8 GB / 256 GB', 'Tamano de pantalla', '14'),
    ('Laptop Ambar Campus 14', '8 GB / 256 GB', 'Color', 'Gris arena'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', 'Memoria RAM', '16'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', 'Almacenamiento', '512'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', 'Tamano de pantalla', '14'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', 'Color', 'Gris arena'),
    ('Laptop Ambar Campus 14', '16 GB / 512 GB', 'Acabado', 'Texturizado'),
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
    ('Telefono Nautilo Pro', '256 GB', 'Almacenamiento', '256'),
    ('Telefono Nautilo Pro', '256 GB', 'Memoria RAM', '12'),
    ('Telefono Nautilo Pro', '256 GB', 'Color', 'Titanio'),
    ('Telefono Nautilo Pro', '512 GB', 'Almacenamiento', '512'),
    ('Telefono Nautilo Pro', '512 GB', 'Memoria RAM', '12'),
    ('Telefono Nautilo Pro', '512 GB', 'Color', 'Titanio'),
    ('Telefono Nautilo Pro', '512 GB', 'Tamano de pantalla', '6.7'),
    ('Telefono Nautilo Pro', '1 TB', 'Almacenamiento', '1024'),
    ('Telefono Nautilo Pro', '1 TB', 'Memoria RAM', '16'),
    ('Telefono Nautilo Pro', '1 TB', 'Color', 'Negro volcan'),
    ('Telefono Pedernal Rugged', '128 GB', 'Almacenamiento', '128'),
    ('Telefono Pedernal Rugged', '128 GB', 'Color', 'Negro y naranja'),
    ('Telefono Pedernal Rugged', '128 GB', 'Tamano de pantalla', '6'),
    ('Telefono Pedernal Rugged', '256 GB', 'Almacenamiento', '256'),
    ('Telefono Pedernal Rugged', '256 GB', 'Color', 'Negro y verde'),
    ('Telefono Pedernal Rugged', '256 GB', 'Tamano de pantalla', '6'),
    ('Telefono Bruma Mini', '128 GB', 'Almacenamiento', '128'),
    ('Telefono Bruma Mini', '128 GB', 'Color', 'Lavanda'),
    ('Telefono Bruma Mini', '128 GB', 'Tamano de pantalla', '5.8'),
    ('Telefono Cuarzo Duo', '32 GB', 'Almacenamiento', '32'),
    ('Telefono Cuarzo Duo', '32 GB', 'Memoria RAM', '3'),
    ('Telefono Cuarzo Duo', '32 GB', 'Color', 'Negro'),
    ('Telefono Cuarzo Duo', '64 GB', 'Almacenamiento', '64'),
    ('Telefono Cuarzo Duo', '64 GB', 'Memoria RAM', '4'),
    ('Telefono Cuarzo Duo', '64 GB', 'Color', 'Azul cielo'),
    ('Audifonos Sereno ANC', 'Negro', 'Color', 'Negro'),
    ('Audifonos Sereno ANC', 'Negro', 'Acabado', 'Mate'),
    ('Audifonos Sereno ANC', 'Arena', 'Color', 'Arena'),
    ('Audifonos Sereno ANC', 'Arena', 'Acabado', 'Mate'),
    ('Audifonos Brisa Sport', 'Verde lima', 'Color', 'Verde lima'),
    ('Audifonos Brisa Sport', 'Gris', 'Color', 'Gris'),
    ('Audifonos Estudio 900', 'Cable 3 m', 'Color', 'Negro'),
    ('Audifonos Estudio 900', 'Cable 3 m', 'Longitud del cable', '3'),
    ('Audifonos Colibri Micro TWS', 'Blanco perla', 'Color', 'Blanco perla'),
    ('Audifonos Colibri Micro TWS', 'Blanco perla', 'Acabado', 'Brillante'),
    ('Audifonos Colibri Micro TWS', 'Negro mate', 'Color', 'Negro'),
    ('Audifonos Colibri Micro TWS', 'Negro mate', 'Acabado', 'Mate'),
    ('Audifonos Colibri Micro TWS', 'Verde menta', 'Color', 'Verde menta'),
    ('Audifonos Colibri Micro TWS', 'Verde menta', 'Acabado', 'Mate'),
    ('Audifonos Marea Diadema Abierta', 'Cable 2 m', 'Color', 'Nogal'),
    ('Audifonos Marea Diadema Abierta', 'Cable 2 m', 'Longitud del cable', '2'),
    ('Audifonos Marea Diadema Abierta', 'Cable 4 m', 'Color', 'Nogal'),
    ('Audifonos Marea Diadema Abierta', 'Cable 4 m', 'Longitud del cable', '4'),
    ('Audifonos Marea Diadema Abierta', 'Cable 4 m', 'Acabado', 'Madera pulida'),
    ('Audifonos Duna Trabajo', 'Grafito', 'Color', 'Grafito'),
    ('Audifonos Duna Trabajo', 'Grafito', 'Acabado', 'Mate'),
    ('Audifonos Duna Trabajo', 'Blanco hueso', 'Color', 'Blanco hueso'),
    ('Audifonos Duna Trabajo', 'Blanco hueso', 'Acabado', 'Mate'),
    ('Audifonos Zumbo Cable', 'Cable 1.2 m', 'Color', 'Negro'),
    ('Audifonos Zumbo Cable', 'Cable 1.2 m', 'Longitud del cable', '1.2'),
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
    ('Monitor Vitral 24', '75 Hz', 'Tamano de pantalla', '23.8'),
    ('Monitor Vitral 24', '75 Hz', 'Tasa de refresco', '75'),
    ('Monitor Vitral 24', '75 Hz', 'Color', 'Negro'),
    ('Monitor Vitral 24', '100 Hz', 'Tamano de pantalla', '23.8'),
    ('Monitor Vitral 24', '100 Hz', 'Tasa de refresco', '100'),
    ('Monitor Vitral 24', '100 Hz', 'Color', 'Negro'),
    ('Monitor Vitral 24', '100 Hz', 'Acabado', 'Antirreflejo'),
    ('Monitor Cenit 32 4K', '60 Hz', 'Tamano de pantalla', '31.5'),
    ('Monitor Cenit 32 4K', '60 Hz', 'Tasa de refresco', '60'),
    ('Monitor Cenit 32 4K', '60 Hz', 'Color', 'Plata'),
    ('Monitor Cenit 32 4K', '60 Hz', 'Acabado', 'Mate'),
    ('Monitor Vertice 27 Gamer', '144 Hz', 'Tamano de pantalla', '27'),
    ('Monitor Vertice 27 Gamer', '144 Hz', 'Tasa de refresco', '144'),
    ('Monitor Vertice 27 Gamer', '144 Hz', 'Color', 'Negro'),
    ('Monitor Vertice 27 Gamer', '180 Hz', 'Tamano de pantalla', '27'),
    ('Monitor Vertice 27 Gamer', '180 Hz', 'Tasa de refresco', '180'),
    ('Monitor Vertice 27 Gamer', '180 Hz', 'Color', 'Negro'),
    ('Monitor Vertice 27 Gamer', '240 Hz', 'Tamano de pantalla', '27'),
    ('Monitor Vertice 27 Gamer', '240 Hz', 'Tasa de refresco', '240'),
    ('Monitor Vertice 27 Gamer', '240 Hz', 'Color', 'Blanco'),
    ('Monitor Vertice 27 Gamer', '240 Hz', 'Acabado', 'Mate'),
    ('Monitor Nube 22', 'Negro', 'Tamano de pantalla', '21.5'),
    ('Monitor Nube 22', 'Negro', 'Tasa de refresco', '75'),
    ('Monitor Nube 22', 'Negro', 'Color', 'Negro'),
    ('Monitor Nube 22', 'Blanco', 'Tamano de pantalla', '21.5'),
    ('Monitor Nube 22', 'Blanco', 'Tasa de refresco', '75'),
    ('Monitor Nube 22', 'Blanco', 'Color', 'Blanco'),
    ('Monitor Nube 22', 'Blanco', 'Acabado', 'Brillante'),
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
    ('Hervidor electrico Vapor 1.7', 'Acero', 'Capacidad', '1.7'),
    ('Hervidor electrico Vapor 1.7', 'Acero', 'Color', 'Acero'),
    ('Hervidor electrico Vapor 1.7', 'Acero', 'Acabado', 'Cepillado'),
    ('Hervidor electrico Vapor 1.7', 'Negro mate', 'Capacidad', '1.7'),
    ('Hervidor electrico Vapor 1.7', 'Negro mate', 'Color', 'Negro'),
    ('Hervidor electrico Vapor 1.7', 'Negro mate', 'Acabado', 'Mate'),
    ('Cacerola honda Comal 18', '16 cm', 'Capacidad', '1.6'),
    ('Cacerola honda Comal 18', '16 cm', 'Color', 'Acero'),
    ('Cacerola honda Comal 18', '16 cm', 'Acabado', 'Pulido'),
    ('Cacerola honda Comal 18', '18 cm', 'Capacidad', '2.3'),
    ('Cacerola honda Comal 18', '18 cm', 'Color', 'Acero'),
    ('Cacerola honda Comal 18', '18 cm', 'Acabado', 'Pulido'),
    ('Cacerola honda Comal 18', '20 cm', 'Capacidad', '3.1'),
    ('Cacerola honda Comal 18', '20 cm', 'Color', 'Acero'),
    ('Olla arrocera Grano 8 tazas', '1.5 L', 'Capacidad', '1.5'),
    ('Olla arrocera Grano 8 tazas', '1.5 L', 'Color', 'Blanco'),
    ('Olla arrocera Grano 8 tazas', '2.8 L', 'Capacidad', '2.8'),
    ('Olla arrocera Grano 8 tazas', '2.8 L', 'Color', 'Blanco'),
    ('Olla arrocera Grano 8 tazas', '2.8 L', 'Acabado', 'Mate'),
    ('Tabla de picar Cedro grande', 'Grande', 'Color', 'Miel'),
    ('Tabla de picar Cedro grande', 'Grande', 'Acabado', 'Aceitado'),
    ('Escritorio Roble 120', 'Natural', 'Color', 'Natural'),
    ('Escritorio Roble 120', 'Natural', 'Acabado', 'Barnizado'),
    ('Escritorio Roble 120', 'Nogal', 'Color', 'Nogal'),
    ('Escritorio Roble 120', 'Nogal', 'Acabado', 'Barnizado'),
    ('Silla ergonomica Vertebra', 'Negra', 'Color', 'Negro'),
    ('Silla ergonomica Vertebra', 'Gris', 'Color', 'Gris'),
    ('Librero Hoja 5 niveles', '5 niveles roble', 'Color', 'Roble claro'),
    ('Librero Hoja 5 niveles', '5 niveles roble', 'Acabado', 'Melamina mate'),
    ('Librero Hoja 5 niveles', '6 niveles nogal', 'Color', 'Nogal'),
    ('Librero Hoja 5 niveles', '6 niveles nogal', 'Acabado', 'Melamina mate'),
    ('Librero Hoja 5 niveles', '6 niveles nogal', 'Talla', 'Alto'),
    ('Mesa de centro Guijarro', 'Natural', 'Color', 'Natural'),
    ('Mesa de centro Guijarro', 'Natural', 'Acabado', 'Aceite mate'),
    ('Silla de comedor Vara', 'Natural', 'Color', 'Natural'),
    ('Silla de comedor Vara', 'Natural', 'Acabado', 'Barnizado'),
    ('Silla de comedor Vara', 'Negra', 'Color', 'Negro'),
    ('Silla de comedor Vara', 'Negra', 'Acabado', 'Laca mate'),
    ('Silla de comedor Vara', 'Tapizada gris', 'Color', 'Gris'),
    ('Silla de comedor Vara', 'Tapizada gris', 'Acabado', 'Tapizado'),
    ('Comoda Sendero 4 gavetas', '4 gavetas', 'Color', 'Blanco'),
    ('Comoda Sendero 4 gavetas', '4 gavetas', 'Acabado', 'Mate'),
    ('Comoda Sendero 4 gavetas', '6 gavetas', 'Color', 'Blanco'),
    ('Comoda Sendero 4 gavetas', '6 gavetas', 'Acabado', 'Mate'),
    ('Comoda Sendero 4 gavetas', '6 gavetas', 'Talla', 'Ancha'),
    ('Lampara de escritorio Faro', 'Blanca', 'Color', 'Blanco'),
    ('Lampara de escritorio Faro', 'Blanca', 'Longitud del cable', '1.8'),
    ('Lampara de escritorio Faro', 'Negra', 'Color', 'Negro'),
    ('Lampara de escritorio Faro', 'Negra', 'Longitud del cable', '1.8'),
    ('Tira LED Aurora 5 m', 'Multicolor', 'Color', 'Multicolor'),
    ('Tira LED Aurora 5 m', 'Multicolor', 'Longitud del cable', '5'),
    ('Lampara colgante Candela 40', 'Mimbre natural', 'Color', 'Beige'),
    ('Lampara colgante Candela 40', 'Mimbre natural', 'Longitud del cable', '1.2'),
    ('Lampara colgante Candela 40', 'Negro mate', 'Color', 'Negro'),
    ('Lampara colgante Candela 40', 'Negro mate', 'Acabado', 'Mate'),
    ('Lampara colgante Candela 40', 'Negro mate', 'Longitud del cable', '1.2'),
    ('Lampara de pie Vigia 165', 'Negro', 'Color', 'Negro'),
    ('Lampara de pie Vigia 165', 'Negro', 'Longitud del cable', '2'),
    ('Lampara de pie Vigia 165', 'Laton cepillado', 'Color', 'Laton'),
    ('Lampara de pie Vigia 165', 'Laton cepillado', 'Acabado', 'Cepillado'),
    ('Lampara de pie Vigia 165', 'Laton cepillado', 'Longitud del cable', '2'),
    ('Lampara de pie Vigia 165', 'Nogal y laton', 'Color', 'Nogal'),
    ('Lampara de pie Vigia 165', 'Nogal y laton', 'Acabado', 'Barnizado'),
    ('Lampara de pie Vigia 165', 'Nogal y laton', 'Longitud del cable', '2.5'),
    ('Plafon LED Solaz 24', 'Blanco 24 W', 'Color', 'Blanco'),
    ('Plafon LED Solaz 24', 'Blanco 24 W', 'Acabado', 'Satinado'),
    ('Farol solar de jardin Luciernaga', 'Negro mate', 'Color', 'Negro'),
    ('Farol solar de jardin Luciernaga', 'Negro mate', 'Acabado', 'Mate'),
    ('Farol solar de jardin Luciernaga', 'Cobre envejecido', 'Color', 'Cobre'),
    ('Farol solar de jardin Luciernaga', 'Cobre envejecido', 'Acabado', 'Envejecido'),
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
    ('Camisa guayabera Xelaju', 'M blanca', 'Talla', 'M'),
    ('Camisa guayabera Xelaju', 'M blanca', 'Color', 'Blanco'),
    ('Camisa guayabera Xelaju', 'L hueso', 'Talla', 'L'),
    ('Camisa guayabera Xelaju', 'L hueso', 'Color', 'Hueso'),
    ('Camisa guayabera Xelaju', 'XL hueso', 'Talla', 'XL'),
    ('Camisa guayabera Xelaju', 'XL hueso', 'Color', 'Hueso'),
    ('Camisa guayabera Xelaju', 'XL hueso', 'Acabado', 'Prelavado'),
    ('Camisa de vestir Meridiano', 'M blanca', 'Talla', 'M'),
    ('Camisa de vestir Meridiano', 'M blanca', 'Color', 'Blanco'),
    ('Camisa de vestir Meridiano', 'M blanca', 'Acabado', 'Antiarrugas'),
    ('Camisa de vestir Meridiano', 'L gris perla', 'Talla', 'L'),
    ('Camisa de vestir Meridiano', 'L gris perla', 'Color', 'Gris perla'),
    ('Camisa de vestir Meridiano', 'L gris perla', 'Acabado', 'Antiarrugas'),
    ('Camisa de mezclilla Remache', 'M azul indigo', 'Talla', 'M'),
    ('Camisa de mezclilla Remache', 'M azul indigo', 'Color', 'Azul indigo'),
    ('Camisa de mezclilla Remache', 'L azul claro', 'Talla', 'L'),
    ('Camisa de mezclilla Remache', 'L azul claro', 'Color', 'Azul claro'),
    ('Camisa de mezclilla Remache', 'L azul claro', 'Acabado', 'Lavado a la piedra'),
    ('Camisa polo pique Cardumen', 'M azul marino', 'Talla', 'M'),
    ('Camisa polo pique Cardumen', 'M azul marino', 'Color', 'Azul marino'),
    ('Camisa polo pique Cardumen', 'M azul marino', 'Acabado', 'Prelavado'),
    ('Pantalon chino resistente', '32 beige', 'Talla', '32'),
    ('Pantalon chino resistente', '32 beige', 'Color', 'Beige'),
    ('Pantalon chino resistente', '34 beige', 'Talla', '34'),
    ('Pantalon chino resistente', '34 beige', 'Color', 'Beige'),
    ('Pantalon chino resistente', '34 azul', 'Talla', '34'),
    ('Pantalon chino resistente', '34 azul', 'Color', 'Azul marino'),
    ('Pantalon de mezclilla Yunque', '32 indigo crudo', 'Talla', '32'),
    ('Pantalon de mezclilla Yunque', '32 indigo crudo', 'Color', 'Indigo crudo'),
    ('Pantalon de mezclilla Yunque', '34 negro', 'Talla', '34'),
    ('Pantalon de mezclilla Yunque', '34 negro', 'Color', 'Negro'),
    ('Pantalon de mezclilla Yunque', '34 negro', 'Acabado', 'Lavado a la piedra'),
    ('Pantalon cargo Vereda', '32 verde oliva', 'Talla', '32'),
    ('Pantalon cargo Vereda', '32 verde oliva', 'Color', 'Verde oliva'),
    ('Pantalon cargo Vereda', '34 arena', 'Talla', '34'),
    ('Pantalon cargo Vereda', '34 arena', 'Color', 'Arena'),
    ('Pantalon cargo Vereda', '36 negro', 'Talla', '36'),
    ('Pantalon cargo Vereda', '36 negro', 'Color', 'Negro'),
    ('Pantalon cargo Vereda', '36 negro', 'Acabado', 'Repelente al agua'),
    ('Pantalon de vestir Consulado', '32 gris oxford', 'Talla', '32'),
    ('Pantalon de vestir Consulado', '32 gris oxford', 'Color', 'Gris oxford'),
    ('Pantalon de vestir Consulado', '32 gris oxford', 'Acabado', 'Planchado permanente'),
    ('Pantalon jogger Ocaso', 'M gris jaspe', 'Talla', 'M'),
    ('Pantalon jogger Ocaso', 'M gris jaspe', 'Color', 'Gris jaspe'),
    ('Pantalon jogger Ocaso', 'L negro', 'Talla', 'L'),
    ('Pantalon jogger Ocaso', 'L negro', 'Color', 'Negro'),
    ('Pantalon jogger Ocaso', 'L negro', 'Acabado', 'Perchado interior'),
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
    ('Tenis urbano Vereda 90', '39 blanco', 'Numero de calzado', '39'),
    ('Tenis urbano Vereda 90', '39 blanco', 'Color', 'Blanco'),
    ('Tenis urbano Vereda 90', '41 blanco', 'Numero de calzado', '41'),
    ('Tenis urbano Vereda 90', '41 blanco', 'Color', 'Blanco'),
    ('Tenis urbano Vereda 90', '43 gris', 'Numero de calzado', '43'),
    ('Tenis urbano Vereda 90', '43 gris', 'Color', 'Gris'),
    ('Tenis urbano Vereda 90', '43 gris', 'Acabado', 'Mate'),
    ('Mocasin de gamuza Roble', '40 azul', 'Numero de calzado', '40'),
    ('Mocasin de gamuza Roble', '40 azul', 'Color', 'Azul marino'),
    ('Mocasin de gamuza Roble', '42 arena', 'Numero de calzado', '42'),
    ('Mocasin de gamuza Roble', '42 arena', 'Color', 'Arena'),
    ('Mocasin de gamuza Roble', '42 arena', 'Acabado', 'Cepillado'),
    ('Bota de trabajo Yunque S3', '40 negro', 'Numero de calzado', '40'),
    ('Bota de trabajo Yunque S3', '40 negro', 'Color', 'Negro'),
    ('Bota de trabajo Yunque S3', '42 negro', 'Numero de calzado', '42'),
    ('Bota de trabajo Yunque S3', '42 negro', 'Color', 'Negro'),
    ('Bota de trabajo Yunque S3', '44 miel', 'Numero de calzado', '44'),
    ('Bota de trabajo Yunque S3', '44 miel', 'Color', 'Miel'),
    ('Bota de trabajo Yunque S3', '44 miel', 'Acabado', 'Engrasado'),
    ('Sandalia de cuero Litoral', '41 cafe', 'Numero de calzado', '41'),
    ('Sandalia de cuero Litoral', '41 cafe', 'Color', 'Cafe'),
    ('Balon de futbol numero 5', 'Blanco', 'Talla', '5'),
    ('Balon de futbol numero 5', 'Blanco', 'Color', 'Blanco'),
    ('Balon de futbol numero 5', 'Naranja', 'Talla', '5'),
    ('Balon de futbol numero 5', 'Naranja', 'Color', 'Naranja'),
    ('Espinilleras Muralla', 'M', 'Talla', 'M'),
    ('Espinilleras Muralla', 'M', 'Color', 'Negro'),
    ('Espinilleras Muralla', 'L', 'Talla', 'L'),
    ('Espinilleras Muralla', 'L', 'Color', 'Negro'),
    ('Guantes de portero Zarpa 300', 'Talla 8', 'Talla', '8'),
    ('Guantes de portero Zarpa 300', 'Talla 8', 'Color', 'Negro'),
    ('Guantes de portero Zarpa 300', 'Talla 10', 'Talla', '10'),
    ('Guantes de portero Zarpa 300', 'Talla 10', 'Color', 'Amarillo'),
    ('Zapato de tacos Relampago FG', '40 negro', 'Talla', '40'),
    ('Zapato de tacos Relampago FG', '40 negro', 'Color', 'Negro'),
    ('Zapato de tacos Relampago FG', '42 negro', 'Talla', '42'),
    ('Zapato de tacos Relampago FG', '42 negro', 'Color', 'Negro'),
    ('Zapato de tacos Relampago FG', '42 rojo', 'Talla', '42'),
    ('Zapato de tacos Relampago FG', '42 rojo', 'Color', 'Rojo'),
    ('Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 'Color', 'Blanco'),
    ('Uniforme de entrenamiento Cantera', 'M azul', 'Talla', 'M'),
    ('Uniforme de entrenamiento Cantera', 'M azul', 'Color', 'Azul'),
    ('Uniforme de entrenamiento Cantera', 'L azul', 'Talla', 'L'),
    ('Uniforme de entrenamiento Cantera', 'L azul', 'Color', 'Azul'),
    ('Uniforme de entrenamiento Cantera', 'L verde', 'Talla', 'L'),
    ('Uniforme de entrenamiento Cantera', 'L verde', 'Color', 'Verde'),
    ('Casco de ruta Aerodino', 'M blanco', 'Talla', 'M'),
    ('Casco de ruta Aerodino', 'M blanco', 'Color', 'Blanco'),
    ('Casco de ruta Aerodino', 'L negro', 'Talla', 'L'),
    ('Casco de ruta Aerodino', 'L negro', 'Color', 'Negro'),
    ('Casco de ruta Aerodino', 'L negro', 'Acabado', 'Mate'),
    ('Bomba de piso Piston', 'Estandar', 'Color', 'Negro'),
    ('Guantes de ciclismo Palma Corta', 'S negro', 'Talla', 'S'),
    ('Guantes de ciclismo Palma Corta', 'S negro', 'Color', 'Negro'),
    ('Guantes de ciclismo Palma Corta', 'M negro', 'Talla', 'M'),
    ('Guantes de ciclismo Palma Corta', 'M negro', 'Color', 'Negro'),
    ('Guantes de ciclismo Palma Corta', 'L gris', 'Talla', 'L'),
    ('Guantes de ciclismo Palma Corta', 'L gris', 'Color', 'Gris'),
    ('Sillin de ruta Vertebra SR-2', '143 mm', 'Talla', '143 mm'),
    ('Sillin de ruta Vertebra SR-2', '143 mm', 'Color', 'Negro'),
    ('Sillin de ruta Vertebra SR-2', '155 mm', 'Talla', '155 mm'),
    ('Sillin de ruta Vertebra SR-2', '155 mm', 'Color', 'Negro'),
    ('Sillin de ruta Vertebra SR-2', '155 mm', 'Acabado', 'Mate'),
    ('Maillot de ruta Peloton', 'M naranja', 'Talla', 'M'),
    ('Maillot de ruta Peloton', 'M naranja', 'Color', 'Naranja'),
    ('Maillot de ruta Peloton', 'L naranja', 'Talla', 'L'),
    ('Maillot de ruta Peloton', 'L naranja', 'Color', 'Naranja'),
    ('Maillot de ruta Peloton', 'L azul', 'Talla', 'L'),
    ('Maillot de ruta Peloton', 'L azul', 'Color', 'Azul'),
    ('Maillot de ruta Peloton', 'L azul', 'Acabado', 'Mate'),
    ('Candado plegable Cerrojo F8', 'Estandar', 'Color', 'Negro'),
    ('Candado plegable Cerrojo F8', 'Estandar', 'Acabado', 'Mate'),
    ('Set de bandas elasticas', 'Set completo', 'Color', 'Multicolor'),
    ('Tapete de yoga Raiz 6 mm', 'Verde', 'Color', 'Verde'),
    ('Tapete de yoga Raiz 6 mm', 'Morado', 'Color', 'Morado'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 'Color', 'Negro'),
    ('Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 'Color', 'Negro'),
    ('Pesa rusa Yunque', '12 kg', 'Talla', '12 kg'),
    ('Pesa rusa Yunque', '12 kg', 'Color', 'Negro mate'),
    ('Pesa rusa Yunque', '16 kg', 'Talla', '16 kg'),
    ('Pesa rusa Yunque', '16 kg', 'Color', 'Negro mate'),
    ('Pesa rusa Yunque', '20 kg', 'Talla', '20 kg'),
    ('Pesa rusa Yunque', '20 kg', 'Color', 'Azul'),
    ('Cuerda de salto Relampago', 'Cable de 3 m', 'Color', 'Negro y rojo'),
    ('Rodillo de liberacion Nudo', '33 cm', 'Talla', '33 cm'),
    ('Rodillo de liberacion Nudo', '33 cm', 'Color', 'Gris'),
    ('Rodillo de liberacion Nudo', '45 cm', 'Talla', '45 cm'),
    ('Rodillo de liberacion Nudo', '45 cm', 'Color', 'Naranja'),
    ('El camino de las nubes', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('El camino de las nubes', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Cuentos de la ceiba', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('La casa de los relojes detenidos', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('La casa de los relojes detenidos', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('La casa de los relojes detenidos', 'Pasta dura', 'Color', 'Azul indigo'),
    ('Cartas al puerto seco', 'Digital', 'Formato', 'EPUB'),
    ('Cartas al puerto seco', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('Cartas al puerto seco', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Cartas al puerto seco', 'Pasta dura', 'Color', 'Verde musgo'),
    ('Nadie duerme en Tecpanal', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Nadie duerme en Tecpanal', 'Pasta dura', 'Color', 'Negro'),
    ('Antologia del ruido', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('Antologia del ruido', 'Pasta blanda', 'Color', 'Crema'),
    ('Antologia del ruido', 'Edicion ilustrada', 'Formato', 'Pasta dura'),
    ('Antologia del ruido', 'Edicion ilustrada', 'Color', 'Rojo'),
    ('Bases de datos distribuidas', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Bases de datos distribuidas', 'Digital', 'Formato', 'PDF con DRM'),
    ('Redes industriales y buses de campo', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('Redes industriales y buses de campo', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Calculo numerico con ejercicios resueltos', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('Manual de instalaciones electricas residenciales', 'Pasta blanda', 'Formato', 'Pasta blanda'),
    ('Manual de instalaciones electricas residenciales', 'Espiral', 'Formato', 'Espiral'),
    ('Manual de instalaciones electricas residenciales', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Introduccion al modelado de sistemas embebidos', 'Pasta dura', 'Formato', 'Pasta dura'),
    ('Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 'Formato', 'Pasta dura con codigo de acceso'),
    ('Serum de niacinamida 10%', '30 ml', 'Volumen', '30'),
    ('Serum de niacinamida 10%', '50 ml', 'Volumen', '50'),
    ('Protector solar mineral FPS 50', '50 ml', 'Volumen', '50'),
    ('Crema hidratante nocturna Alba', '50 ml', 'Volumen', '50'),
    ('Crema hidratante nocturna Alba', '100 ml', 'Volumen', '100'),
    ('Limpiador en gel Verdo', '150 ml', 'Volumen', '150'),
    ('Limpiador en gel Verdo', '250 ml', 'Volumen', '250'),
    ('Limpiador en gel Verdo', '400 ml', 'Volumen', '400'),
    ('Limpiador en gel Verdo', '400 ml', 'Color', 'Frasco ambar'),
    ('Exfoliante enzimatico Papilo', '75 ml', 'Volumen', '75'),
    ('Contorno de ojos Lumine', '15 ml', 'Volumen', '15'),
    ('Contorno de ojos Lumine', '30 ml', 'Volumen', '30'),
    ('Eau de parfum Bruma', '50 ml', 'Volumen', '50'),
    ('Eau de parfum Bruma', '100 ml', 'Volumen', '100'),
    ('Eau de toilette Salino', '30 ml', 'Volumen', '30'),
    ('Eau de toilette Salino', '60 ml', 'Volumen', '60'),
    ('Eau de toilette Salino', '100 ml', 'Volumen', '100'),
    ('Eau de toilette Salino', '100 ml', 'Color', 'Vidrio azul'),
    ('Agua de colonia Amanecer Citrico', '100 ml', 'Volumen', '100'),
    ('Agua de colonia Amanecer Citrico', '100 ml', 'Color', 'Vidrio ambar'),
    ('Agua de colonia Amanecer Citrico', '200 ml', 'Volumen', '200'),
    ('Agua de colonia Amanecer Citrico', '200 ml', 'Color', 'Vidrio ambar'),
    ('Bruma corporal Trebol Blanco', '200 ml', 'Volumen', '200'),
    ('Set descubrimiento Nocturno', 'Coleccion noche', 'Color', 'Estuche negro'),
    ('Set descubrimiento Nocturno', 'Coleccion dia', 'Color', 'Estuche marfil')
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
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/37/Schenker_VIA14_Laptop_asv2021-01.jpg/960px-Schenker_VIA14_Laptop_asv2021-01.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/Lenovo_G500s_laptop-2903.jpg/960px-Lenovo_G500s_laptop-2903.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/53/Asus_x21_ultrabook.jpg/960px-Asus_x21_ultrabook.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/2-in-1_laptop.jpeg/960px-2-in-1_laptop.jpeg'),
    ('https://upload.wikimedia.org/wikipedia/commons/e/ef/Dell.._Laptop.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/Laptop%2C_Small_notebook%2C_Netbook%2C_Rostov-on-Don%2C_Russia.jpg/960px-Laptop%2C_Small_notebook%2C_Netbook%2C_Rostov-on-Don%2C_Russia.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png/960px-Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/68/HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg/960px-HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg/960px-T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/96/Smartphone_being_charged.jpg/960px-Smartphone_being_charged.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/38/EMOBILE_LTE_phone_in_Japan.jpg/960px-EMOBILE_LTE_phone_in_Japan.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg/960px-Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/73/Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg/960px-Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a6/Studio_Headphones.jpg/960px-Studio_Headphones.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Beige_Earphones.jpg/960px-Beige_Earphones.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/6/63/Headphones_on_white_background.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Headphones_1.jpg/960px-Headphones_1.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1d/Earphones_BW_2011-12-10_15-49-08.JPG/960px-Earphones_BW_2011-12-10_15-49-08.JPG'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Dell_Professional_P2212H-9899.jpg/960px-Dell_Professional_P2212H-9899.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e4/Monitor_ultrawide_21_9.jpg/960px-Monitor_ultrawide_21_9.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Computer_monitor.jpg/960px-Computer_monitor.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f3/Computer_monitor_screen_image_simulated.jpg/960px-Computer_monitor_screen_image_simulated.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/NEC_MONITOR_E2206XG.jpg/960px-NEC_MONITOR_E2206XG.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7f/A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg/960px-A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/13/All-Clad_Copper_Core_pots.jpeg/960px-All-Clad_Copper_Core_pots.jpeg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/BL807_Red-4_in_1.jpg/960px-BL807_Red-4_in_1.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/51/HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg/960px-HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/65/Hahn_16cm_Saucepan.jpg/960px-Hahn_16cm_Saucepan.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/62/Zojirushi_Rice_Cooker_NP-RG05.jpg/960px-Zojirushi_Rice_Cooker_NP-RG05.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/48/Cutting_Board.jpg/960px-Cutting_Board.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/Bureau_table_%28desk%29_MET_DP-14204-114.jpg/960px-Bureau_table_%28desk%29_MET_DP-14204-114.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Prototype_ergonomic_office_chair%2C_V%26A_London.jpg/960px-Prototype_ergonomic_office_chair%2C_V%26A_London.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Bookcase_MET_240710.jpg/960px-Bookcase_MET_240710.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/a/a0/Carleson_Solid_Wood_Coffee_Table_In_Provincial_Tea_%28264060733%29.jpeg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e3/Wooden_Dining_Chair.jpg/960px-Wooden_Dining_Chair.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/59/A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg/960px-A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/bf/Desktop-lamp-2_hg.jpg/960px-Desktop-lamp-2_hg.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Light_blue_LED_strip.jpg/960px-Light_blue_LED_strip.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Geometric_white_pendant_lamp_chandelier.jpg/960px-Geometric_white_pendant_lamp_chandelier.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Floor_lamp_1_2016-07-06.jpg/960px-Floor_lamp_1_2016-07-06.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/4/45/Led_wohnraumleuchte.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/ad/Solar_garden_light.jpg/960px-Solar_garden_light.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Button_down_dress_shirts_for_men.jpg/960px-Button_down_dress_shirts_for_men.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg/960px-Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/9/9d/Guayabera_de_Lino_Keten.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Camisade_pu%C3%B1o_doble.jpg/960px-Camisade_pu%C3%B1o_doble.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/e/ec/Man_wearing_blue_denim_shirt_with_rolled_sleeves%2C_tan_chinos_1.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/d1/Various_colors_of_polo_shirt_at_JCPenney.jpg/960px-Various_colors_of_polo_shirt_at_JCPenney.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Chino_pants.jpg/960px-Chino_pants.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d2/Jeans_for_men.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Cargo_pants_001.jpg/960px-Cargo_pants_001.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/f/fb/Trousers.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/c/c3/Sweatpants.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Mens_brown_derby_leather_shoes.jpg/960px-Mens_brown_derby_leather_shoes.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/29/Hiking_shoes_Lowa.jpg/960px-Hiking_shoes_Lowa.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/43/Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg/960px-Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Handmade_Lake_Blue_Loafers_Shoe.jpg/960px-Handmade_Lake_Blue_Loafers_Shoe.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Leather_sandals.jpg/960px-Leather_sandals.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/Ball_white_black.jpg/960px-Ball_white_black.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/0/0e/Shinpads.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Guanti_da_portiere.jpg/960px-Guanti_da_portiere.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e1/Football_boots_%283293104040%29.jpg/960px-Football_boots_%283293104040%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/9c/Football_goal_net.jpg/960px-Football_goal_net.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Football_kit_01.jpg/960px-Football_kit_01.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/81/Bicycle_Helmet_0085_Transparent.png/960px-Bicycle_Helmet_0085_Transparent.png'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/SKS_Rennkompressor_Standpumpe.jpg/960px-SKS_Rennkompressor_Standpumpe.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d0/Bicycle_glove.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/25/Road_bike_saddle1.jpg/960px-Road_bike_saddle1.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/020230923_cycling_jerseys_for_men.jpg/960px-020230923_cycling_jerseys_for_men.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Folding_bike_lock.jpg/960px-Folding_bike_lock.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Grid_Layout_of_Blue_Barry%27s_Exercise_Mats_and_Resistance_Bands.jpg/960px-Grid_Layout_of_Blue_Barry%27s_Exercise_Mats_and_Resistance_Bands.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Yoga_mat.jpg/960px-Yoga_mat.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Aluminium_Dumbbell.jpg/960px-Aluminium_Dumbbell.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Competition_kettlebell_16_kilo.jpg/960px-Competition_kettlebell_16_kilo.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8b/Exercise_equipment_%28rubber_ball%2C_light-weight_dumbbells%2C_jump_rope%29.jpg/960px-Exercise_equipment_%28rubber_ball%2C_light-weight_dumbbells%2C_jump_rope%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/Hartschaumrolle.jpg/960px-Hartschaumrolle.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Aufgeschlagenes_Buch_--_2020_--_4204.jpg/960px-Aufgeschlagenes_Buch_--_2020_--_4204.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Old_Books_01.JPG/960px-Old_Books_01.JPG'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6c/Books_in_stack_with_lamps_%28Unsplash%29.jpg/960px-Books_in_stack_with_lamps_%28Unsplash%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1c/Old_books_%28Unsplash%29.jpg/960px-Old_books_%28Unsplash%29.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/dc/Old_Books_04.JPG/960px-Old_Books_04.JPG'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg/960px-Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c6/The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg/960px-The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8c/Reference_books_on_shelf_01.jpg/960px-Reference_books_on_shelf_01.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/af/Reference_books_on_shelf_02.jpg/960px-Reference_books_on_shelf_02.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Nuevos_libros_de_texto_gratuitos.jpg/960px-Nuevos_libros_de_texto_gratuitos.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg/960px-Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/9/94/2_oz_-_60_ml_Amber_Glass_Boston_Round_Bottles_with_Gold_Metal_and_Glass_Droppers.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/bd/LRP_sunscreen_bottle.jpg/960px-LRP_sunscreen_bottle.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Day_cream_02.jpg/960px-Day_cream_02.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/27/Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG/960px-Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Exfoliating_face_scrub.jpg/960px-Exfoliating_face_scrub.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/f/fc/Under_eye_cream.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/ef/MOI_Fragrances_Bottle.jpg/960px-MOI_Fragrances_Bottle.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/79/Perfume_glass_bottle.jpg/960px-Perfume_glass_bottle.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a1/Czech_Glass_Perfume_Bottle-2.jpg/960px-Czech_Glass_Perfume_Bottle-2.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/db/Bottles_of_Eau_de_Toilette.jpg/960px-Bottles_of_Eau_de_Toilette.jpg'),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Perfume_set_from_Sovjetunio_cca_1965.jpg/960px-Perfume_set_from_Sovjetunio_cca_1965.jpg');

INSERT INTO imagen_producto_producto (id_imagen_producto, id_producto_variante, numero_orden)
SELECT im.id_imagen_producto, pv.id_producto_variante, v.orden
FROM (VALUES
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/37/Schenker_VIA14_Laptop_asv2021-01.jpg/960px-Schenker_VIA14_Laptop_asv2021-01.jpg', 'Laptop Aurora 14', '16 GB / 512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/37/Schenker_VIA14_Laptop_asv2021-01.jpg/960px-Schenker_VIA14_Laptop_asv2021-01.jpg', 'Laptop Aurora 14', '32 GB / 1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/Lenovo_G500s_laptop-2903.jpg/960px-Lenovo_G500s_laptop-2903.jpg', 'Laptop Bastion 16', '32 GB / 1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/Lenovo_G500s_laptop-2903.jpg/960px-Lenovo_G500s_laptop-2903.jpg', 'Laptop Bastion 16', '64 GB / 2 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/53/Asus_x21_ultrabook.jpg/960px-Asus_x21_ultrabook.jpg', 'Laptop Nimbo 13', '8 GB / 256 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/2-in-1_laptop.jpeg/960px-2-in-1_laptop.jpeg', 'Laptop Lienzo 15', '16 GB / 512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/2-in-1_laptop.jpeg/960px-2-in-1_laptop.jpeg', 'Laptop Lienzo 15', '16 GB / 1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ce/2-in-1_laptop.jpeg/960px-2-in-1_laptop.jpeg', 'Laptop Lienzo 15', '32 GB / 1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/e/ef/Dell.._Laptop.jpg', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/e/ef/Dell.._Laptop.jpg', 'Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1b/Laptop%2C_Small_notebook%2C_Netbook%2C_Rostov-on-Don%2C_Russia.jpg/960px-Laptop%2C_Small_notebook%2C_Netbook%2C_Rostov-on-Don%2C_Russia.jpg', 'Laptop Vireo Air 12', '8 GB / 128 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png/960px-Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a9/Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png/960px-Laptop_der_Marke_exone_go_20240203_HOF06886_RAW-Export_000276.png', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg', 'Telefono Vela 7', '128 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg', 'Telefono Vela 7', '256 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/78/Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_back_face.jpg', 'Telefono Vela 7', '512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/68/HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg/960px-HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg', 'Telefono Ceibo Lite', '64 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/68/HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg/960px-HMD_Nokia_5.1_Plus_Blue_%28front_and_rear%29.jpg', 'Telefono Ceibo Lite', '128 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg/960px-T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg', 'Telefono Nautilo Pro', '256 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg/960px-T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg', 'Telefono Nautilo Pro', '512 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg/960px-T%E2%80%93Phone_5G_and_T%E2%80%93Phone_5G_Pro_from_Polish_distribution.jpg', 'Telefono Nautilo Pro', '1 TB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg', 'Telefono Pedernal Rugged', '128 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg/960px-Blackview_A60_Smartphone_Android_mobile_phone_front_face_lock_screen.jpg', 'Telefono Pedernal Rugged', '256 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/96/Smartphone_being_charged.jpg/960px-Smartphone_being_charged.jpg', 'Telefono Bruma Mini', '128 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/38/EMOBILE_LTE_phone_in_Japan.jpg/960px-EMOBILE_LTE_phone_in_Japan.jpg', 'Telefono Cuarzo Duo', '32 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/38/EMOBILE_LTE_phone_in_Japan.jpg/960px-EMOBILE_LTE_phone_in_Japan.jpg', 'Telefono Cuarzo Duo', '64 GB', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg/960px-Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg', 'Audifonos Sereno ANC', 'Negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/0a/Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg/960px-Bose_QuietComfort_25_Acoustic_Noise_Cancelling_Headphones_with_Carry_Case.jpg', 'Audifonos Sereno ANC', 'Arena', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/73/Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg/960px-Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg', 'Audifonos Brisa Sport', 'Verde lima', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/73/Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg/960px-Yamaha_TW-E3A_Earbuds_Customize%2C_Japan%3B_April_2021_%2801%29.jpg', 'Audifonos Brisa Sport', 'Gris', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a6/Studio_Headphones.jpg/960px-Studio_Headphones.jpg', 'Audifonos Estudio 900', 'Cable 3 m', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Beige_Earphones.jpg/960px-Beige_Earphones.jpg', 'Audifonos Colibri Micro TWS', 'Blanco perla', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Beige_Earphones.jpg/960px-Beige_Earphones.jpg', 'Audifonos Colibri Micro TWS', 'Negro mate', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Beige_Earphones.jpg/960px-Beige_Earphones.jpg', 'Audifonos Colibri Micro TWS', 'Verde menta', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/6/63/Headphones_on_white_background.jpg', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/6/63/Headphones_on_white_background.jpg', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Headphones_1.jpg/960px-Headphones_1.jpg', 'Audifonos Duna Trabajo', 'Grafito', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Headphones_1.jpg/960px-Headphones_1.jpg', 'Audifonos Duna Trabajo', 'Blanco hueso', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1d/Earphones_BW_2011-12-10_15-49-08.JPG/960px-Earphones_BW_2011-12-10_15-49-08.JPG', 'Audifonos Zumbo Cable', 'Cable 1.2 m', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Dell_Professional_P2212H-9899.jpg/960px-Dell_Professional_P2212H-9899.jpg', 'Monitor Horizonte 27', '75 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/64/Dell_Professional_P2212H-9899.jpg/960px-Dell_Professional_P2212H-9899.jpg', 'Monitor Horizonte 27', '165 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e4/Monitor_ultrawide_21_9.jpg/960px-Monitor_ultrawide_21_9.jpg', 'Monitor Panorama 34', '100 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Computer_monitor.jpg/960px-Computer_monitor.jpg', 'Monitor Vitral 24', '75 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Computer_monitor.jpg/960px-Computer_monitor.jpg', 'Monitor Vitral 24', '100 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f3/Computer_monitor_screen_image_simulated.jpg/960px-Computer_monitor_screen_image_simulated.jpg', 'Monitor Cenit 32 4K', '60 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png', 'Monitor Vertice 27 Gamer', '144 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png', 'Monitor Vertice 27 Gamer', '180 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png/960px-EIZO_Foris_FG2421_VGA_computer_monitor_displaying_test_pattern.png', 'Monitor Vertice 27 Gamer', '240 Hz', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/NEC_MONITOR_E2206XG.jpg/960px-NEC_MONITOR_E2206XG.jpg', 'Monitor Nube 22', 'Negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/NEC_MONITOR_E2206XG.jpg/960px-NEC_MONITOR_E2206XG.jpg', 'Monitor Nube 22', 'Blanco', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7f/A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg/960px-A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg', 'Cafetera Alba Espresso', '1.5 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7f/A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg/960px-A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg', 'Cafetera Alba Espresso', '2.5 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/13/All-Clad_Copper_Core_pots.jpeg/960px-All-Clad_Copper_Core_pots.jpeg', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/BL807_Red-4_in_1.jpg/960px-BL807_Red-4_in_1.jpg', 'Licuadora Torbellino 1200', '1.5 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b7/BL807_Red-4_in_1.jpg/960px-BL807_Red-4_in_1.jpg', 'Licuadora Torbellino 1200', '2 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/51/HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg/960px-HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg', 'Hervidor electrico Vapor 1.7', 'Acero', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/51/HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg/960px-HK_goods_made_in_China_%E5%B0%8F%E7%B1%B3_Xiaomi_%E9%9B%BB%E7%86%B1%E6%B0%B4%E7%93%B6_Mi_electric_product_white_%E6%B0%B4%E7%85%B2_Kettle_June_2021_SS2_03.jpg', 'Hervidor electrico Vapor 1.7', 'Negro mate', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/65/Hahn_16cm_Saucepan.jpg/960px-Hahn_16cm_Saucepan.jpg', 'Cacerola honda Comal 18', '16 cm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/65/Hahn_16cm_Saucepan.jpg/960px-Hahn_16cm_Saucepan.jpg', 'Cacerola honda Comal 18', '18 cm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/65/Hahn_16cm_Saucepan.jpg/960px-Hahn_16cm_Saucepan.jpg', 'Cacerola honda Comal 18', '20 cm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/62/Zojirushi_Rice_Cooker_NP-RG05.jpg/960px-Zojirushi_Rice_Cooker_NP-RG05.jpg', 'Olla arrocera Grano 8 tazas', '1.5 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/62/Zojirushi_Rice_Cooker_NP-RG05.jpg/960px-Zojirushi_Rice_Cooker_NP-RG05.jpg', 'Olla arrocera Grano 8 tazas', '2.8 L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/48/Cutting_Board.jpg/960px-Cutting_Board.jpg', 'Tabla de picar Cedro grande', 'Grande', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/Bureau_table_%28desk%29_MET_DP-14204-114.jpg/960px-Bureau_table_%28desk%29_MET_DP-14204-114.jpg', 'Escritorio Roble 120', 'Natural', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/34/Bureau_table_%28desk%29_MET_DP-14204-114.jpg/960px-Bureau_table_%28desk%29_MET_DP-14204-114.jpg', 'Escritorio Roble 120', 'Nogal', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Prototype_ergonomic_office_chair%2C_V%26A_London.jpg/960px-Prototype_ergonomic_office_chair%2C_V%26A_London.jpg', 'Silla ergonomica Vertebra', 'Negra', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8a/Prototype_ergonomic_office_chair%2C_V%26A_London.jpg/960px-Prototype_ergonomic_office_chair%2C_V%26A_London.jpg', 'Silla ergonomica Vertebra', 'Gris', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Bookcase_MET_240710.jpg/960px-Bookcase_MET_240710.jpg', 'Librero Hoja 5 niveles', '5 niveles roble', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/Bookcase_MET_240710.jpg/960px-Bookcase_MET_240710.jpg', 'Librero Hoja 5 niveles', '6 niveles nogal', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/a/a0/Carleson_Solid_Wood_Coffee_Table_In_Provincial_Tea_%28264060733%29.jpeg', 'Mesa de centro Guijarro', 'Natural', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e3/Wooden_Dining_Chair.jpg/960px-Wooden_Dining_Chair.jpg', 'Silla de comedor Vara', 'Natural', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e3/Wooden_Dining_Chair.jpg/960px-Wooden_Dining_Chair.jpg', 'Silla de comedor Vara', 'Negra', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e3/Wooden_Dining_Chair.jpg/960px-Wooden_Dining_Chair.jpg', 'Silla de comedor Vara', 'Tapizada gris', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/59/A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg/960px-A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg', 'Comoda Sendero 4 gavetas', '4 gavetas', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/59/A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg/960px-A_pine_chest_of_drawers_with_bun_feet._%28c7f76543-8a3b-4a42-aead-480edaf72163%29.jpg', 'Comoda Sendero 4 gavetas', '6 gavetas', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/bf/Desktop-lamp-2_hg.jpg/960px-Desktop-lamp-2_hg.jpg', 'Lampara de escritorio Faro', 'Blanca', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/bf/Desktop-lamp-2_hg.jpg/960px-Desktop-lamp-2_hg.jpg', 'Lampara de escritorio Faro', 'Negra', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Light_blue_LED_strip.jpg/960px-Light_blue_LED_strip.jpg', 'Tira LED Aurora 5 m', 'Multicolor', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Geometric_white_pendant_lamp_chandelier.jpg/960px-Geometric_white_pendant_lamp_chandelier.jpg', 'Lampara colgante Candela 40', 'Mimbre natural', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Geometric_white_pendant_lamp_chandelier.jpg/960px-Geometric_white_pendant_lamp_chandelier.jpg', 'Lampara colgante Candela 40', 'Negro mate', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Floor_lamp_1_2016-07-06.jpg/960px-Floor_lamp_1_2016-07-06.jpg', 'Lampara de pie Vigia 165', 'Negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Floor_lamp_1_2016-07-06.jpg/960px-Floor_lamp_1_2016-07-06.jpg', 'Lampara de pie Vigia 165', 'Laton cepillado', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/Floor_lamp_1_2016-07-06.jpg/960px-Floor_lamp_1_2016-07-06.jpg', 'Lampara de pie Vigia 165', 'Nogal y laton', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/4/45/Led_wohnraumleuchte.jpg', 'Plafon LED Solaz 24', 'Blanco 24 W', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/ad/Solar_garden_light.jpg/960px-Solar_garden_light.jpg', 'Farol solar de jardin Luciernaga', 'Negro mate', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/ad/Solar_garden_light.jpg/960px-Solar_garden_light.jpg', 'Farol solar de jardin Luciernaga', 'Cobre envejecido', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Button_down_dress_shirts_for_men.jpg/960px-Button_down_dress_shirts_for_men.jpg', 'Camisa de lino manga larga', 'S azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Button_down_dress_shirts_for_men.jpg/960px-Button_down_dress_shirts_for_men.jpg', 'Camisa de lino manga larga', 'M azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Button_down_dress_shirts_for_men.jpg/960px-Button_down_dress_shirts_for_men.jpg', 'Camisa de lino manga larga', 'L blanca', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg/960px-Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg', 'Camisa oxford clasica', 'M celeste', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/58/Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg/960px-Banana_Republic_Button-Down_Shirt_1_2019-03-21.jpg', 'Camisa oxford clasica', 'L celeste', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/9/9d/Guayabera_de_Lino_Keten.jpg', 'Camisa guayabera Xelaju', 'M blanca', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/9/9d/Guayabera_de_Lino_Keten.jpg', 'Camisa guayabera Xelaju', 'L hueso', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/9/9d/Guayabera_de_Lino_Keten.jpg', 'Camisa guayabera Xelaju', 'XL hueso', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Camisade_pu%C3%B1o_doble.jpg/960px-Camisade_pu%C3%B1o_doble.jpg', 'Camisa de vestir Meridiano', 'M blanca', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Camisade_pu%C3%B1o_doble.jpg/960px-Camisade_pu%C3%B1o_doble.jpg', 'Camisa de vestir Meridiano', 'L gris perla', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/e/ec/Man_wearing_blue_denim_shirt_with_rolled_sleeves%2C_tan_chinos_1.jpg', 'Camisa de mezclilla Remache', 'M azul indigo', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/e/ec/Man_wearing_blue_denim_shirt_with_rolled_sleeves%2C_tan_chinos_1.jpg', 'Camisa de mezclilla Remache', 'L azul claro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/d1/Various_colors_of_polo_shirt_at_JCPenney.jpg/960px-Various_colors_of_polo_shirt_at_JCPenney.jpg', 'Camisa polo pique Cardumen', 'M azul marino', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Chino_pants.jpg/960px-Chino_pants.jpg', 'Pantalon chino resistente', '32 beige', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Chino_pants.jpg/960px-Chino_pants.jpg', 'Pantalon chino resistente', '34 beige', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/3/3e/Chino_pants.jpg/960px-Chino_pants.jpg', 'Pantalon chino resistente', '34 azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d2/Jeans_for_men.jpg', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d2/Jeans_for_men.jpg', 'Pantalon de mezclilla Yunque', '34 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Cargo_pants_001.jpg/960px-Cargo_pants_001.jpg', 'Pantalon cargo Vereda', '32 verde oliva', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Cargo_pants_001.jpg/960px-Cargo_pants_001.jpg', 'Pantalon cargo Vereda', '34 arena', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/cd/Cargo_pants_001.jpg/960px-Cargo_pants_001.jpg', 'Pantalon cargo Vereda', '36 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/f/fb/Trousers.jpg', 'Pantalon de vestir Consulado', '32 gris oxford', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/c/c3/Sweatpants.jpg', 'Pantalon jogger Ocaso', 'M gris jaspe', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/c/c3/Sweatpants.jpg', 'Pantalon jogger Ocaso', 'L negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Mens_brown_derby_leather_shoes.jpg/960px-Mens_brown_derby_leather_shoes.jpg', 'Zapato de cuero Senda', '40 cafe', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Mens_brown_derby_leather_shoes.jpg/960px-Mens_brown_derby_leather_shoes.jpg', 'Zapato de cuero Senda', '42 cafe', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Mens_brown_derby_leather_shoes.jpg/960px-Mens_brown_derby_leather_shoes.jpg', 'Zapato de cuero Senda', '42 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/29/Hiking_shoes_Lowa.jpg/960px-Hiking_shoes_Lowa.jpg', 'Bota impermeable Cumbre', '41', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/29/Hiking_shoes_Lowa.jpg/960px-Hiking_shoes_Lowa.jpg', 'Bota impermeable Cumbre', '43', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/43/Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg/960px-Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg', 'Tenis urbano Vereda 90', '39 blanco', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/43/Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg/960px-Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg', 'Tenis urbano Vereda 90', '41 blanco', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/43/Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg/960px-Professional_Sneakers_-_Sneakers_for_hostesses%2C_pilots_and_other_professionals._Comfortable_sneakers_produced_in_leather_inside_and_outside.jpg', 'Tenis urbano Vereda 90', '43 gris', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Handmade_Lake_Blue_Loafers_Shoe.jpg/960px-Handmade_Lake_Blue_Loafers_Shoe.jpg', 'Mocasin de gamuza Roble', '40 azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/04/Handmade_Lake_Blue_Loafers_Shoe.jpg/960px-Handmade_Lake_Blue_Loafers_Shoe.jpg', 'Mocasin de gamuza Roble', '42 arena', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg', 'Bota de trabajo Yunque S3', '40 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg', 'Bota de trabajo Yunque S3', '42 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Leather_boots_men%27s.jpg/960px-Leather_boots_men%27s.jpg', 'Bota de trabajo Yunque S3', '44 miel', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Leather_sandals.jpg/960px-Leather_sandals.jpg', 'Sandalia de cuero Litoral', '41 cafe', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/Ball_white_black.jpg/960px-Ball_white_black.jpg', 'Balon de futbol numero 5', 'Blanco', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f0/Ball_white_black.jpg/960px-Ball_white_black.jpg', 'Balon de futbol numero 5', 'Naranja', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/0/0e/Shinpads.jpg', 'Espinilleras Muralla', 'M', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/0/0e/Shinpads.jpg', 'Espinilleras Muralla', 'L', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Guanti_da_portiere.jpg/960px-Guanti_da_portiere.jpg', 'Guantes de portero Zarpa 300', 'Talla 8', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Guanti_da_portiere.jpg/960px-Guanti_da_portiere.jpg', 'Guantes de portero Zarpa 300', 'Talla 10', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e1/Football_boots_%283293104040%29.jpg/960px-Football_boots_%283293104040%29.jpg', 'Zapato de tacos Relampago FG', '40 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e1/Football_boots_%283293104040%29.jpg/960px-Football_boots_%283293104040%29.jpg', 'Zapato de tacos Relampago FG', '42 negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e1/Football_boots_%283293104040%29.jpg/960px-Football_boots_%283293104040%29.jpg', 'Zapato de tacos Relampago FG', '42 rojo', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/9c/Football_goal_net.jpg/960px-Football_goal_net.jpg', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Football_kit_01.jpg/960px-Football_kit_01.jpg', 'Uniforme de entrenamiento Cantera', 'M azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Football_kit_01.jpg/960px-Football_kit_01.jpg', 'Uniforme de entrenamiento Cantera', 'L azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Football_kit_01.jpg/960px-Football_kit_01.jpg', 'Uniforme de entrenamiento Cantera', 'L verde', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/81/Bicycle_Helmet_0085_Transparent.png/960px-Bicycle_Helmet_0085_Transparent.png', 'Casco de ruta Aerodino', 'M blanco', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/81/Bicycle_Helmet_0085_Transparent.png/960px-Bicycle_Helmet_0085_Transparent.png', 'Casco de ruta Aerodino', 'L negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/SKS_Rennkompressor_Standpumpe.jpg/960px-SKS_Rennkompressor_Standpumpe.jpg', 'Bomba de piso Piston', 'Estandar', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d0/Bicycle_glove.jpg', 'Guantes de ciclismo Palma Corta', 'S negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d0/Bicycle_glove.jpg', 'Guantes de ciclismo Palma Corta', 'M negro', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/d/d0/Bicycle_glove.jpg', 'Guantes de ciclismo Palma Corta', 'L gris', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/25/Road_bike_saddle1.jpg/960px-Road_bike_saddle1.jpg', 'Sillin de ruta Vertebra SR-2', '143 mm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/25/Road_bike_saddle1.jpg/960px-Road_bike_saddle1.jpg', 'Sillin de ruta Vertebra SR-2', '155 mm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/020230923_cycling_jerseys_for_men.jpg/960px-020230923_cycling_jerseys_for_men.jpg', 'Maillot de ruta Peloton', 'M naranja', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/020230923_cycling_jerseys_for_men.jpg/960px-020230923_cycling_jerseys_for_men.jpg', 'Maillot de ruta Peloton', 'L naranja', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c0/020230923_cycling_jerseys_for_men.jpg/960px-020230923_cycling_jerseys_for_men.jpg', 'Maillot de ruta Peloton', 'L azul', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/e8/Folding_bike_lock.jpg/960px-Folding_bike_lock.jpg', 'Candado plegable Cerrojo F8', 'Estandar', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Grid_Layout_of_Blue_Barry%27s_Exercise_Mats_and_Resistance_Bands.jpg/960px-Grid_Layout_of_Blue_Barry%27s_Exercise_Mats_and_Resistance_Bands.jpg', 'Set de bandas elasticas', 'Set completo', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Yoga_mat.jpg/960px-Yoga_mat.jpg', 'Tapete de yoga Raiz 6 mm', 'Verde', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Yoga_mat.jpg/960px-Yoga_mat.jpg', 'Tapete de yoga Raiz 6 mm', 'Morado', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Aluminium_Dumbbell.jpg/960px-Aluminium_Dumbbell.jpg', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/40/Aluminium_Dumbbell.jpg/960px-Aluminium_Dumbbell.jpg', 'Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Competition_kettlebell_16_kilo.jpg/960px-Competition_kettlebell_16_kilo.jpg', 'Pesa rusa Yunque', '12 kg', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Competition_kettlebell_16_kilo.jpg/960px-Competition_kettlebell_16_kilo.jpg', 'Pesa rusa Yunque', '16 kg', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/14/Competition_kettlebell_16_kilo.jpg/960px-Competition_kettlebell_16_kilo.jpg', 'Pesa rusa Yunque', '20 kg', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8b/Exercise_equipment_%28rubber_ball%2C_light-weight_dumbbells%2C_jump_rope%29.jpg/960px-Exercise_equipment_%28rubber_ball%2C_light-weight_dumbbells%2C_jump_rope%29.jpg', 'Cuerda de salto Relampago', 'Cable de 3 m', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/Hartschaumrolle.jpg/960px-Hartschaumrolle.jpg', 'Rodillo de liberacion Nudo', '33 cm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/4/41/Hartschaumrolle.jpg/960px-Hartschaumrolle.jpg', 'Rodillo de liberacion Nudo', '45 cm', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Aufgeschlagenes_Buch_--_2020_--_4204.jpg/960px-Aufgeschlagenes_Buch_--_2020_--_4204.jpg', 'El camino de las nubes', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/f/f9/Aufgeschlagenes_Buch_--_2020_--_4204.jpg/960px-Aufgeschlagenes_Buch_--_2020_--_4204.jpg', 'El camino de las nubes', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/ca/Old_Books_01.JPG/960px-Old_Books_01.JPG', 'Cuentos de la ceiba', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6c/Books_in_stack_with_lamps_%28Unsplash%29.jpg/960px-Books_in_stack_with_lamps_%28Unsplash%29.jpg', 'La casa de los relojes detenidos', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/6/6c/Books_in_stack_with_lamps_%28Unsplash%29.jpg/960px-Books_in_stack_with_lamps_%28Unsplash%29.jpg', 'La casa de los relojes detenidos', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1c/Old_books_%28Unsplash%29.jpg/960px-Old_books_%28Unsplash%29.jpg', 'Cartas al puerto seco', 'Digital', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1c/Old_books_%28Unsplash%29.jpg/960px-Old_books_%28Unsplash%29.jpg', 'Cartas al puerto seco', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/1/1c/Old_books_%28Unsplash%29.jpg/960px-Old_books_%28Unsplash%29.jpg', 'Cartas al puerto seco', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/dc/Old_Books_04.JPG/960px-Old_Books_04.JPG', 'Nadie duerme en Tecpanal', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg/960px-Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg', 'Antologia del ruido', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/5/54/Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg/960px-Books_in_a_stack_%28a_stack_of_books%29_-_Flickr_-_austinevan.jpg', 'Antologia del ruido', 'Edicion ilustrada', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c6/The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg/960px-The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg', 'Bases de datos distribuidas', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c6/The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg/960px-The_Art_of_Computer_Programming_%28vol._1-4B%29-2805.jpg', 'Bases de datos distribuidas', 'Digital', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8c/Reference_books_on_shelf_01.jpg/960px-Reference_books_on_shelf_01.jpg', 'Redes industriales y buses de campo', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/8c/Reference_books_on_shelf_01.jpg/960px-Reference_books_on_shelf_01.jpg', 'Redes industriales y buses de campo', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/af/Reference_books_on_shelf_02.jpg/960px-Reference_books_on_shelf_02.jpg', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Nuevos_libros_de_texto_gratuitos.jpg/960px-Nuevos_libros_de_texto_gratuitos.jpg', 'Manual de instalaciones electricas residenciales', 'Pasta blanda', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Nuevos_libros_de_texto_gratuitos.jpg/960px-Nuevos_libros_de_texto_gratuitos.jpg', 'Manual de instalaciones electricas residenciales', 'Espiral', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/c/c4/Nuevos_libros_de_texto_gratuitos.jpg/960px-Nuevos_libros_de_texto_gratuitos.jpg', 'Manual de instalaciones electricas residenciales', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg/960px-Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/7d/Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg/960px-Books_on_shelf_for_the_reference_section_of_kwara_state_Library_board.jpg', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/9/94/2_oz_-_60_ml_Amber_Glass_Boston_Round_Bottles_with_Gold_Metal_and_Glass_Droppers.jpg', 'Serum de niacinamida 10%', '30 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/9/94/2_oz_-_60_ml_Amber_Glass_Boston_Round_Bottles_with_Gold_Metal_and_Glass_Droppers.jpg', 'Serum de niacinamida 10%', '50 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/b/bd/LRP_sunscreen_bottle.jpg/960px-LRP_sunscreen_bottle.jpg', 'Protector solar mineral FPS 50', '50 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Day_cream_02.jpg/960px-Day_cream_02.jpg', 'Crema hidratante nocturna Alba', '50 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Day_cream_02.jpg/960px-Day_cream_02.jpg', 'Crema hidratante nocturna Alba', '100 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/27/Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG/960px-Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG', 'Limpiador en gel Verdo', '150 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/27/Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG/960px-Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG', 'Limpiador en gel Verdo', '250 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/2/27/Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG/960px-Moisturex_containers_25g%2C_100g_bottles_and_150g_pump.JPG', 'Limpiador en gel Verdo', '400 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/8/83/Exfoliating_face_scrub.jpg/960px-Exfoliating_face_scrub.jpg', 'Exfoliante enzimatico Papilo', '75 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/f/fc/Under_eye_cream.jpg', 'Contorno de ojos Lumine', '15 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/f/fc/Under_eye_cream.jpg', 'Contorno de ojos Lumine', '30 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/ef/MOI_Fragrances_Bottle.jpg/960px-MOI_Fragrances_Bottle.jpg', 'Eau de parfum Bruma', '50 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/e/ef/MOI_Fragrances_Bottle.jpg/960px-MOI_Fragrances_Bottle.jpg', 'Eau de parfum Bruma', '100 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/79/Perfume_glass_bottle.jpg/960px-Perfume_glass_bottle.jpg', 'Eau de toilette Salino', '30 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/79/Perfume_glass_bottle.jpg/960px-Perfume_glass_bottle.jpg', 'Eau de toilette Salino', '60 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/7/79/Perfume_glass_bottle.jpg/960px-Perfume_glass_bottle.jpg', 'Eau de toilette Salino', '100 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a1/Czech_Glass_Perfume_Bottle-2.jpg/960px-Czech_Glass_Perfume_Bottle-2.jpg', 'Agua de colonia Amanecer Citrico', '100 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/a/a1/Czech_Glass_Perfume_Bottle-2.jpg/960px-Czech_Glass_Perfume_Bottle-2.jpg', 'Agua de colonia Amanecer Citrico', '200 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/d/db/Bottles_of_Eau_de_Toilette.jpg/960px-Bottles_of_Eau_de_Toilette.jpg', 'Bruma corporal Trebol Blanco', '200 ml', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Perfume_set_from_Sovjetunio_cca_1965.jpg/960px-Perfume_set_from_Sovjetunio_cca_1965.jpg', 'Set descubrimiento Nocturno', 'Coleccion noche', 1),
    ('https://upload.wikimedia.org/wikipedia/commons/thumb/9/91/Perfume_set_from_Sovjetunio_cca_1965.jpg/960px-Perfume_set_from_Sovjetunio_cca_1965.jpg', 'Set descubrimiento Nocturno', 'Coleccion dia', 1)
) AS v(url, producto, variante, orden)
JOIN imagen_producto     im ON im.imagen_producto_url = v.url
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante;

-- ============================================================
-- Las ofertas: 552 sobre 202 variantes
-- ============================================================
-- Aqui vive el precio y el stock. Una fila por vendedor y variante, que es
-- lo que garantiza el UNIQUE del 005.
--
-- Apunta al catalogo por los ids de MongoDB y sin llave foranea, igual que
-- pedido_producto: una sola forma de identificar una variante en todo el
-- sistema. Aqui se resuelven contra productos_variantes porque el conjunto
-- de datos se escribe antes de que exista el documento, y son el mismo id.
--
-- La tienda tiene oferta de todas: por eso ningun producto se queda sin
-- precio que ensenar. Los otros cuatro entran a veces si y a veces no, con
-- una semilla fija, asi que hay variantes con un solo precio y otras con
-- cinco. Alguna sale pausada o en cero a proposito: si todas estuvieran
-- activas y con stock, la pantalla nunca ensenaria los casos que si van a
-- pasar de verdad.

INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, stock, id_estado_oferta, fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)
SELECT p.id_producto, pv.id_producto_variante, u.id_usuario, v.precio, v.stock, eo.id_estado_oferta, v.fecha::timestamptz, v.fecha::timestamptz, v.fecha::timestamptz,
       CASE WHEN v.correo = 'tienda@mesh.com' THEN NULL ELSE ut.id_usuario END
FROM (VALUES
    ('tienda@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6200.00, 35, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6228.00, 15, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 5947.00, 17, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6296.00, 23, 'activa', '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8804.00, 12, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8939.00, 25, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8577.00, 22, 'activa', '2026-01-04 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8256.00, 3, 'activa', '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9400.00, 26, 'activa', '2026-01-05 10:22:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9606.00, 8, 'activa', '2026-01-05 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 14570.00, 5, 'activa', '2026-01-05 10:22:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 15515.00, 23, 'activa', '2026-01-05 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 4100.00, 39, 'activa', '2026-01-06 10:32:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 3779.00, 23, 'activa', '2026-01-06 10:32:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 512 GB', 5400.00, 33, 'activa', '2026-01-07 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 1 TB', 6426.00, 0, 'activa', '2026-01-07 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Lienzo 15', '16 GB / 1 TB', 6594.00, 21, 'activa', '2026-01-07 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 7884.00, 24, 'activa', '2026-01-07 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 7255.00, 13, 'activa', '2026-01-07 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 8307.00, 21, 'activa', '2026-01-07 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 11800.00, 6, 'activa', '2026-01-08 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 10958.00, 1, 'activa', '2026-01-08 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 12415.00, 11, 'activa', '2026-01-08 10:38:00-06'),
    ('tienda@mesh.com', 'Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 16284.00, 20, 'activa', '2026-01-08 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 15932.00, 5, 'activa', '2026-01-08 10:38:00-06'),
    ('tienda@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3450.00, 26, 'activa', '2026-01-09 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3176.00, 12, 'activa', '2026-01-09 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3221.00, 21, 'activa', '2026-01-09 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3529.00, 18, 'activa', '2026-01-09 10:34:00-06'),
    ('tienda@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4750.00, 34, 'activa', '2026-01-10 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4562.00, 18, 'activa', '2026-01-10 10:02:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4641.00, 16, 'activa', '2026-01-10 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6033.00, 11, 'activa', '2026-01-10 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6000.00, 24, 'activa', '2026-01-10 10:02:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 5643.00, 4, 'activa', '2026-01-10 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6098.00, 14, 'activa', '2026-01-10 10:02:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '128 GB', 5300.00, 4, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Vela 7', '128 GB', 4957.00, 7, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Vela 7', '128 GB', 5461.00, 2, 'activa', '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '256 GB', 6254.00, 31, 'activa', '2026-01-24 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '256 GB', 6691.00, 24, 'activa', '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '512 GB', 7208.00, 24, 'activa', '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1850.00, 0, 'activa', '2026-01-12 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1918.00, 10, 'activa', '2026-01-12 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1849.00, 8, 'activa', '2026-01-12 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1985.00, 10, 'activa', '2026-01-12 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1931.00, 19, 'activa', '2026-01-12 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2257.00, 29, 'activa', '2026-01-12 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2120.00, 23, 'activa', '2026-01-12 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2301.00, 23, 'pausada', '2026-01-12 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2246.00, 11, 'activa', '2026-01-12 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '256 GB', 7200.00, 23, 'activa', '2026-01-13 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Nautilo Pro', '256 GB', 7358.00, 8, 'pausada', '2026-01-13 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '512 GB', 8712.00, 11, 'activa', '2026-01-13 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Nautilo Pro', '512 GB', 8999.00, 21, 'activa', '2026-01-13 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '1 TB', 10656.00, 25, 'activa', '2026-01-13 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Nautilo Pro', '1 TB', 11052.00, 18, 'activa', '2026-01-13 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Pedernal Rugged', '128 GB', 3900.00, 29, 'activa', '2026-01-14 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Pedernal Rugged', '128 GB', 3877.00, 22, 'activa', '2026-01-14 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Pedernal Rugged', '256 GB', 4524.00, 29, 'activa', '2026-01-14 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Pedernal Rugged', '256 GB', 4537.00, 2, 'activa', '2026-01-14 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Bruma Mini', '128 GB', 2600.00, 13, 'activa', '2026-01-15 10:48:00-06'),
    ('tienda@mesh.com', 'Telefono Cuarzo Duo', '32 GB', 1450.00, 0, 'activa', '2026-01-16 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Cuarzo Duo', '32 GB', 1550.00, 1, 'activa', '2026-01-16 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Cuarzo Duo', '32 GB', 1387.00, 1, 'activa', '2026-01-16 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Cuarzo Duo', '64 GB', 1798.00, 26, 'activa', '2026-01-16 10:15:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1450.00, 27, 'activa', '2026-01-17 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1418.00, 10, 'activa', '2026-01-17 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Arena', 1450.00, 40, 'activa', '2026-01-17 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Sereno ANC', 'Arena', 1484.00, 0, 'activa', '2026-01-17 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 620.00, 20, 'activa', '2026-01-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 659.00, 10, 'pausada', '2026-01-18 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 574.00, 14, 'activa', '2026-01-18 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 621.00, 21, 'activa', '2026-01-18 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Gris', 620.00, 0, 'activa', '2026-01-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 651.00, 7, 'activa', '2026-01-18 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Brisa Sport', 'Gris', 640.00, 8, 'activa', '2026-01-18 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2100.00, 0, 'activa', '2026-01-19 10:38:00-06'),
    ('tienda@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla', 980.00, 33, 'activa', '2026-01-20 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla', 903.00, 23, 'activa', '2026-01-20 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla', 915.00, 3, 'activa', '2026-01-20 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Colibri Micro TWS', 'Negro mate', 1039.00, 36, 'activa', '2026-01-20 10:05:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Colibri Micro TWS', 'Negro mate', 1028.00, 11, 'activa', '2026-01-20 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Colibri Micro TWS', 'Verde menta', 1068.00, 27, 'activa', '2026-01-20 10:05:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Colibri Micro TWS', 'Verde menta', 1059.00, 0, 'activa', '2026-01-20 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Colibri Micro TWS', 'Verde menta', 1139.00, 17, 'activa', '2026-01-20 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3400.00, 36, 'activa', '2026-01-21 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3508.00, 5, 'activa', '2026-01-21 10:04:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3458.00, 1, 'activa', '2026-01-21 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3458.00, 19, 'activa', '2026-01-21 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 3808.00, 10, 'activa', '2026-01-21 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 3521.00, 0, 'activa', '2026-01-21 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 3953.00, 3, 'activa', '2026-01-21 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1750.00, 34, 'activa', '2026-01-22 10:16:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1722.00, 13, 'activa', '2026-01-22 10:16:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1801.00, 0, 'activa', '2026-01-22 10:16:00-06'),
    ('tienda@mesh.com', 'Audifonos Duna Trabajo', 'Blanco hueso', 1873.00, 0, 'activa', '2026-01-22 10:16:00-06'),
    ('tienda@mesh.com', 'Audifonos Zumbo Cable', 'Cable 1.2 m', 210.00, 0, 'activa', '2026-01-23 10:25:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2750.00, 4, 'activa', '2026-01-24 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2960.00, 0, 'activa', '2026-01-24 10:48:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2537.00, 2, 'activa', '2026-01-24 10:48:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3658.00, 4, 'activa', '2026-01-24 10:48:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3475.00, 1, 'activa', '2026-01-24 10:48:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3467.00, 1, 'activa', '2026-01-24 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3465.00, 2, 'activa', '2026-01-24 10:48:00-06'),
    ('tienda@mesh.com', 'Monitor Panorama 34', '100 Hz', 5900.00, 34, 'activa', '2026-01-25 10:56:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Panorama 34', '100 Hz', 5902.00, 14, 'activa', '2026-01-25 10:56:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Panorama 34', '100 Hz', 6289.00, 24, 'activa', '2026-01-25 10:56:00-06'),
    ('tienda@mesh.com', 'Monitor Vitral 24', '75 Hz', 1650.00, 31, 'activa', '2026-01-26 10:42:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Vitral 24', '75 Hz', 1645.00, 0, 'activa', '2026-01-26 10:42:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vitral 24', '75 Hz', 1705.00, 0, 'activa', '2026-01-26 10:42:00-06'),
    ('tienda@mesh.com', 'Monitor Vitral 24', '100 Hz', 1947.00, 3, 'activa', '2026-01-26 10:42:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Vitral 24', '100 Hz', 1981.00, 5, 'activa', '2026-01-26 10:42:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vitral 24', '100 Hz', 1846.00, 11, 'activa', '2026-01-26 10:42:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Vitral 24', '100 Hz', 1811.00, 10, 'activa', '2026-01-26 10:42:00-06'),
    ('tienda@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4300.00, 32, 'activa', '2026-01-27 10:27:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4044.00, 19, 'activa', '2026-01-27 10:27:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4500.00, 6, 'activa', '2026-01-27 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4107.00, 14, 'activa', '2026-01-27 10:27:00-06'),
    ('tienda@mesh.com', 'Monitor Vertice 27 Gamer', '144 Hz', 3450.00, 23, 'activa', '2026-01-28 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '144 Hz', 3645.00, 1, 'activa', '2026-01-28 10:20:00-06'),
    ('tienda@mesh.com', 'Monitor Vertice 27 Gamer', '180 Hz', 4002.00, 28, 'activa', '2026-01-28 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '180 Hz', 3986.00, 1, 'activa', '2026-01-28 10:20:00-06'),
    ('tienda@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 5106.00, 0, 'activa', '2026-01-28 10:20:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 5340.00, 21, 'activa', '2026-01-28 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 4715.00, 10, 'activa', '2026-01-28 10:20:00-06'),
    ('tienda@mesh.com', 'Monitor Nube 22', 'Negro', 1180.00, 36, 'activa', '2026-02-01 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Nube 22', 'Negro', 1096.00, 17, 'activa', '2026-02-01 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Nube 22', 'Negro', 1251.00, 13, 'activa', '2026-02-01 10:26:00-06'),
    ('tienda@mesh.com', 'Monitor Nube 22', 'Blanco', 1251.00, 7, 'activa', '2026-02-01 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Nube 22', 'Blanco', 1284.00, 2, 'pausada', '2026-02-01 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Nube 22', 'Blanco', 1173.00, 25, 'activa', '2026-02-01 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Nube 22', 'Blanco', 1290.00, 17, 'activa', '2026-02-01 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Nube 22', 'Blanco', 1190.00, 21, 'activa', '2026-02-01 10:26:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1980.00, 25, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1892.00, 23, 'activa', '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2455.00, 22, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2311.00, 14, 'activa', '2026-02-08 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2641.00, 8, 'activa', '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1240.00, 0, 'activa', '2026-02-03 10:59:00-06'),
    ('ventas.sur@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1162.00, 20, 'activa', '2026-02-03 10:59:00-06'),
    ('ventas.oriente@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1270.00, 0, 'activa', '2026-02-03 10:59:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 890.00, 9, 'activa', '2026-02-04 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 922.00, 24, 'activa', '2026-02-04 10:34:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1023.00, 26, 'activa', '2026-02-04 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 998.00, 12, 'pausada', '2026-02-04 10:34:00-06'),
    ('tienda@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 385.00, 32, 'activa', '2026-02-05 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 377.00, 7, 'activa', '2026-02-05 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 383.00, 18, 'activa', '2026-02-05 10:52:00-06'),
    ('tienda@mesh.com', 'Hervidor electrico Vapor 1.7', 'Negro mate', 416.00, 9, 'activa', '2026-02-05 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Hervidor electrico Vapor 1.7', 'Negro mate', 389.00, 25, 'activa', '2026-02-05 10:52:00-06'),
    ('tienda@mesh.com', 'Cacerola honda Comal 18', '16 cm', 420.00, 30, 'activa', '2026-02-06 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Cacerola honda Comal 18', '16 cm', 394.00, 25, 'pausada', '2026-02-06 10:03:00-06'),
    ('ventas.poniente@mesh.com', 'Cacerola honda Comal 18', '16 cm', 390.00, 5, 'pausada', '2026-02-06 10:03:00-06'),
    ('tienda@mesh.com', 'Cacerola honda Comal 18', '18 cm', 512.00, 28, 'activa', '2026-02-06 10:03:00-06'),
    ('tienda@mesh.com', 'Cacerola honda Comal 18', '20 cm', 609.00, 15, 'activa', '2026-02-06 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Cacerola honda Comal 18', '20 cm', 602.00, 16, 'activa', '2026-02-06 10:03:00-06'),
    ('ventas.poniente@mesh.com', 'Cacerola honda Comal 18', '20 cm', 612.00, 11, 'activa', '2026-02-06 10:03:00-06'),
    ('tienda@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 540.00, 4, 'activa', '2026-02-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 498.00, 11, 'activa', '2026-02-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 576.00, 4, 'activa', '2026-02-07 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 568.00, 11, 'activa', '2026-02-07 10:45:00-06'),
    ('tienda@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 702.00, 29, 'activa', '2026-02-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 697.00, 5, 'activa', '2026-02-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 665.00, 3, 'activa', '2026-02-07 10:45:00-06'),
    ('ventas.poniente@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 651.00, 22, 'activa', '2026-02-07 10:45:00-06'),
    ('tienda@mesh.com', 'Tabla de picar Cedro grande', 'Grande', 195.00, 14, 'activa', '2026-02-08 10:16:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Natural', 2350.00, 37, 'activa', '2026-02-09 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Natural', 2261.00, 0, 'activa', '2026-02-09 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Escritorio Roble 120', 'Natural', 2166.00, 25, 'activa', '2026-02-09 10:57:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Nogal', 2350.00, 12, 'activa', '2026-02-09 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Escritorio Roble 120', 'Nogal', 2304.00, 24, 'activa', '2026-02-09 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Nogal', 2463.00, 14, 'pausada', '2026-02-09 10:57:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3100.00, 20, 'activa', '2026-02-10 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3079.00, 1, 'activa', '2026-02-10 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3344.00, 6, 'pausada', '2026-02-10 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 2971.00, 5, 'activa', '2026-02-10 10:26:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3100.00, 4, 'activa', '2026-02-10 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3046.00, 1, 'activa', '2026-02-10 10:26:00-06'),
    ('tienda@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1450.00, 29, 'activa', '2026-02-11 10:12:00-06'),
    ('ventas.norte@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1542.00, 17, 'activa', '2026-02-11 10:12:00-06'),
    ('ventas.oriente@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1454.00, 8, 'activa', '2026-02-11 10:12:00-06'),
    ('ventas.poniente@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1470.00, 0, 'activa', '2026-02-11 10:12:00-06'),
    ('tienda@mesh.com', 'Librero Hoja 5 niveles', '6 niveles nogal', 1798.00, 34, 'activa', '2026-02-11 10:12:00-06'),
    ('ventas.oriente@mesh.com', 'Librero Hoja 5 niveles', '6 niveles nogal', 1743.00, 17, 'activa', '2026-02-11 10:12:00-06'),
    ('tienda@mesh.com', 'Mesa de centro Guijarro', 'Natural', 980.00, 29, 'activa', '2026-02-12 10:08:00-06'),
    ('ventas.norte@mesh.com', 'Mesa de centro Guijarro', 'Natural', 942.00, 0, 'activa', '2026-02-12 10:08:00-06'),
    ('ventas.oriente@mesh.com', 'Mesa de centro Guijarro', 'Natural', 992.00, 13, 'activa', '2026-02-12 10:08:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Natural', 420.00, 33, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Silla de comedor Vara', 'Natural', 412.00, 12, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Silla de comedor Vara', 'Natural', 400.00, 4, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Natural', 421.00, 19, 'activa', '2026-02-13 10:38:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Negra', 462.00, 37, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Silla de comedor Vara', 'Negra', 486.00, 12, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Silla de comedor Vara', 'Negra', 459.00, 20, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Silla de comedor Vara', 'Negra', 439.00, 10, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Negra', 462.00, 12, 'activa', '2026-02-13 10:38:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 567.00, 32, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 560.00, 0, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 577.00, 11, 'activa', '2026-02-13 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 560.00, 10, 'activa', '2026-02-13 10:38:00-06'),
    ('tienda@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1890.00, 23, 'activa', '2026-02-14 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1816.00, 6, 'activa', '2026-02-14 10:20:00-06'),
    ('tienda@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas', 2608.00, 31, 'activa', '2026-02-14 10:20:00-06'),
    ('ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas', 2697.00, 23, 'activa', '2026-02-14 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas', 2696.00, 1, 'activa', '2026-02-14 10:20:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 480.00, 5, 'activa', '2026-02-15 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 488.00, 0, 'activa', '2026-02-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 461.00, 1, 'activa', '2026-02-15 10:07:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 506.00, 24, 'activa', '2026-02-15 10:07:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra', 480.00, 32, 'activa', '2026-02-15 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de escritorio Faro', 'Negra', 488.00, 5, 'activa', '2026-02-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de escritorio Faro', 'Negra', 472.00, 21, 'activa', '2026-02-15 10:07:00-06'),
    ('tienda@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 320.00, 39, 'activa', '2026-02-16 10:30:00-06'),
    ('ventas.poniente@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 338.00, 13, 'activa', '2026-02-16 10:30:00-06'),
    ('tienda@mesh.com', 'Lampara colgante Candela 40', 'Mimbre natural', 760.00, 0, 'activa', '2026-02-17 10:42:00-06'),
    ('ventas.sur@mesh.com', 'Lampara colgante Candela 40', 'Mimbre natural', 780.00, 24, 'activa', '2026-02-17 10:42:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara colgante Candela 40', 'Mimbre natural', 798.00, 4, 'activa', '2026-02-17 10:42:00-06'),
    ('tienda@mesh.com', 'Lampara colgante Candela 40', 'Negro mate', 874.00, 25, 'activa', '2026-02-17 10:42:00-06'),
    ('ventas.norte@mesh.com', 'Lampara colgante Candela 40', 'Negro mate', 844.00, 23, 'pausada', '2026-02-17 10:42:00-06'),
    ('tienda@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1150.00, 29, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1167.00, 13, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1102.00, 20, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1219.00, 19, 'activa', '2026-02-18 10:55:00-06'),
    ('tienda@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1357.00, 19, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1307.00, 16, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1455.00, 5, 'pausada', '2026-02-18 10:55:00-06'),
    ('tienda@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1553.00, 19, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1552.00, 6, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1535.00, 0, 'activa', '2026-02-18 10:55:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1507.00, 13, 'activa', '2026-02-18 10:55:00-06'),
    ('tienda@mesh.com', 'Plafon LED Solaz 24', 'Blanco 24 W', 540.00, 29, 'activa', '2026-02-19 10:59:00-06'),
    ('ventas.poniente@mesh.com', 'Plafon LED Solaz 24', 'Blanco 24 W', 563.00, 12, 'activa', '2026-02-19 10:59:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Negro mate', 215.00, 33, 'activa', '2026-02-20 10:29:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Cobre envejecido', 262.00, 31, 'activa', '2026-02-20 10:29:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'S azul', 340.00, 0, 'activa', '2026-01-12 09:00:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de lino manga larga', 'S azul', 344.00, 4, 'activa', '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'M azul', 340.00, 8, 'activa', '2026-01-12 09:00:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de lino manga larga', 'M azul', 355.00, 22, 'activa', '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'L blanca', 340.00, 0, 'activa', '2026-01-12 09:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de lino manga larga', 'L blanca', 323.00, 1, 'activa', '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'M celeste', 290.00, 39, 'activa', '2026-02-22 10:47:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa oxford clasica', 'M celeste', 295.00, 13, 'activa', '2026-02-22 10:47:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa oxford clasica', 'M celeste', 297.00, 24, 'activa', '2026-02-22 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'L celeste', 290.00, 28, 'activa', '2026-02-22 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 395.00, 26, 'activa', '2026-02-23 10:01:00-06'),
    ('ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 399.00, 15, 'activa', '2026-02-23 10:01:00-06'),
    ('ventas.sur@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 379.00, 1, 'activa', '2026-02-23 10:01:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 378.00, 24, 'activa', '2026-02-23 10:01:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'L hueso', 419.00, 21, 'activa', '2026-02-23 10:01:00-06'),
    ('ventas.sur@mesh.com', 'Camisa guayabera Xelaju', 'L hueso', 430.00, 21, 'pausada', '2026-02-23 10:01:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso', 442.00, 4, 'activa', '2026-02-23 10:01:00-06'),
    ('ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso', 449.00, 16, 'activa', '2026-02-23 10:01:00-06'),
    ('tienda@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 315.00, 36, 'activa', '2026-02-24 10:47:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 297.00, 0, 'activa', '2026-02-24 10:47:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 306.00, 13, 'activa', '2026-02-24 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa de vestir Meridiano', 'L gris perla', 340.00, 19, 'activa', '2026-02-24 10:47:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de vestir Meridiano', 'L gris perla', 331.00, 1, 'activa', '2026-02-24 10:47:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de vestir Meridiano', 'L gris perla', 316.00, 6, 'activa', '2026-02-24 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 430.00, 25, 'activa', '2026-02-25 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 427.00, 10, 'activa', '2026-02-25 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 457.00, 8, 'pausada', '2026-02-25 10:02:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 409.00, 3, 'activa', '2026-02-25 10:02:00-06'),
    ('tienda@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro', 469.00, 4, 'activa', '2026-02-25 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro', 445.00, 17, 'activa', '2026-02-25 10:02:00-06'),
    ('tienda@mesh.com', 'Camisa polo pique Cardumen', 'M azul marino', 245.00, 32, 'activa', '2026-02-26 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Camisa polo pique Cardumen', 'M azul marino', 228.00, 5, 'activa', '2026-02-26 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa polo pique Cardumen', 'M azul marino', 261.00, 21, 'activa', '2026-02-26 10:34:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 420.00, 17, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '32 beige', 441.00, 15, 'activa', '2026-02-27 10:30:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 beige', 420.00, 4, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon chino resistente', '34 beige', 446.00, 18, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 beige', 440.00, 24, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.oriente@mesh.com', 'Pantalon chino resistente', '34 beige', 399.00, 19, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon chino resistente', '34 beige', 445.00, 11, 'pausada', '2026-02-27 10:30:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 azul', 420.00, 16, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon chino resistente', '34 azul', 426.00, 20, 'activa', '2026-02-27 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 azul', 413.00, 23, 'activa', '2026-02-27 10:30:00-06'),
    ('tienda@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 520.00, 13, 'activa', '2026-02-28 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 524.00, 18, 'activa', '2026-02-28 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 504.00, 9, 'activa', '2026-02-28 10:57:00-06'),
    ('tienda@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 556.00, 0, 'activa', '2026-02-28 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 527.00, 12, 'pausada', '2026-02-28 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 567.00, 13, 'activa', '2026-02-28 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 576.00, 18, 'activa', '2026-02-28 10:57:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva', 480.00, 0, 'activa', '2026-03-01 10:46:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva', 483.00, 11, 'activa', '2026-03-01 10:46:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '34 arena', 509.00, 40, 'activa', '2026-03-01 10:46:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon cargo Vereda', '34 arena', 548.00, 10, 'activa', '2026-03-01 10:46:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '36 negro', 538.00, 21, 'activa', '2026-03-01 10:46:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon cargo Vereda', '36 negro', 504.00, 18, 'activa', '2026-03-01 10:46:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon cargo Vereda', '36 negro', 568.00, 15, 'activa', '2026-03-01 10:46:00-06'),
    ('tienda@mesh.com', 'Pantalon de vestir Consulado', '32 gris oxford', 610.00, 21, 'activa', '2026-03-02 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Pantalon de vestir Consulado', '32 gris oxford', 563.00, 16, 'activa', '2026-03-02 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de vestir Consulado', '32 gris oxford', 637.00, 18, 'activa', '2026-03-02 10:20:00-06'),
    ('tienda@mesh.com', 'Pantalon jogger Ocaso', 'M gris jaspe', 285.00, 37, 'activa', '2026-03-03 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon jogger Ocaso', 'M gris jaspe', 268.00, 10, 'activa', '2026-03-03 10:57:00-06'),
    ('tienda@mesh.com', 'Pantalon jogger Ocaso', 'L negro', 308.00, 22, 'activa', '2026-03-03 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon jogger Ocaso', 'L negro', 310.00, 18, 'activa', '2026-03-03 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon jogger Ocaso', 'L negro', 330.00, 17, 'activa', '2026-03-03 10:57:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '40 cafe', 780.00, 0, 'activa', '2026-03-04 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '40 cafe', 749.00, 3, 'activa', '2026-03-04 10:14:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '40 cafe', 806.00, 18, 'activa', '2026-03-04 10:14:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 cafe', 780.00, 11, 'activa', '2026-03-04 10:14:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '42 cafe', 735.00, 18, 'activa', '2026-03-04 10:14:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 negro', 780.00, 30, 'activa', '2026-03-04 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '42 negro', 729.00, 16, 'activa', '2026-03-04 10:14:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 negro', 789.00, 20, 'activa', '2026-03-04 10:14:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '42 negro', 822.00, 11, 'activa', '2026-03-04 10:14:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '41', 1150.00, 10, 'activa', '2026-03-05 10:09:00-06'),
    ('ventas.norte@mesh.com', 'Bota impermeable Cumbre', '41', 1164.00, 8, 'activa', '2026-03-05 10:09:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '43', 1150.00, 20, 'activa', '2026-03-05 10:09:00-06'),
    ('ventas.norte@mesh.com', 'Bota impermeable Cumbre', '43', 1205.00, 24, 'activa', '2026-03-05 10:09:00-06'),
    ('ventas.sur@mesh.com', 'Bota impermeable Cumbre', '43', 1131.00, 7, 'activa', '2026-03-05 10:09:00-06'),
    ('ventas.poniente@mesh.com', 'Bota impermeable Cumbre', '43', 1200.00, 15, 'activa', '2026-03-05 10:09:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 650.00, 6, 'activa', '2026-03-06 10:37:00-06'),
    ('ventas.oriente@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 657.00, 22, 'activa', '2026-03-06 10:37:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 683.00, 30, 'activa', '2026-03-06 10:37:00-06'),
    ('ventas.norte@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 642.00, 5, 'activa', '2026-03-06 10:37:00-06'),
    ('ventas.sur@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 632.00, 25, 'activa', '2026-03-06 10:37:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '43 gris', 702.00, 13, 'activa', '2026-03-06 10:37:00-06'),
    ('ventas.norte@mesh.com', 'Tenis urbano Vereda 90', '43 gris', 731.00, 3, 'activa', '2026-03-06 10:37:00-06'),
    ('ventas.oriente@mesh.com', 'Tenis urbano Vereda 90', '43 gris', 649.00, 0, 'activa', '2026-03-06 10:37:00-06'),
    ('tienda@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 890.00, 0, 'activa', '2026-03-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 884.00, 4, 'activa', '2026-03-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 906.00, 21, 'activa', '2026-03-07 10:45:00-06'),
    ('tienda@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 961.00, 37, 'activa', '2026-03-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 909.00, 11, 'activa', '2026-03-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 892.00, 1, 'activa', '2026-03-07 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 993.00, 1, 'activa', '2026-03-07 10:45:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '40 negro', 1320.00, 33, 'activa', '2026-03-08 10:39:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '42 negro', 1399.00, 31, 'activa', '2026-03-08 10:39:00-06'),
    ('ventas.oriente@mesh.com', 'Bota de trabajo Yunque S3', '42 negro', 1446.00, 21, 'activa', '2026-03-08 10:39:00-06'),
    ('ventas.poniente@mesh.com', 'Bota de trabajo Yunque S3', '42 negro', 1427.00, 18, 'activa', '2026-03-08 10:39:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1465.00, 3, 'activa', '2026-03-08 10:39:00-06'),
    ('ventas.norte@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1535.00, 1, 'activa', '2026-03-08 10:39:00-06'),
    ('ventas.sur@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1467.00, 1, 'activa', '2026-03-08 10:39:00-06'),
    ('ventas.poniente@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1474.00, 10, 'activa', '2026-03-08 10:39:00-06'),
    ('tienda@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 410.00, 20, 'activa', '2026-03-09 10:19:00-06'),
    ('ventas.sur@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 382.00, 18, 'activa', '2026-03-09 10:19:00-06'),
    ('ventas.oriente@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 387.00, 18, 'activa', '2026-03-09 10:19:00-06'),
    ('ventas.poniente@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 416.00, 19, 'activa', '2026-03-09 10:19:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 260.00, 15, 'activa', '2026-04-06 08:00:00-06'),
    ('ventas.norte@mesh.com', 'Balon de futbol numero 5', 'Blanco', 257.00, 17, 'activa', '2026-04-06 08:00:00-06'),
    ('ventas.oriente@mesh.com', 'Balon de futbol numero 5', 'Blanco', 261.00, 21, 'activa', '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Naranja', 260.00, 0, 'activa', '2026-04-06 08:00:00-06'),
    ('ventas.poniente@mesh.com', 'Balon de futbol numero 5', 'Naranja', 250.00, 13, 'pausada', '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'M', 145.00, 23, 'activa', '2026-03-11 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'M', 134.00, 6, 'activa', '2026-03-11 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'M', 139.00, 17, 'activa', '2026-03-11 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Espinilleras Muralla', 'M', 138.00, 19, 'activa', '2026-03-11 10:26:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'L', 145.00, 26, 'activa', '2026-03-11 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'L', 156.00, 18, 'activa', '2026-03-11 10:26:00-06'),
    ('tienda@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 385.00, 20, 'activa', '2026-03-12 10:51:00-06'),
    ('ventas.norte@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 399.00, 12, 'pausada', '2026-03-12 10:51:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 381.00, 12, 'activa', '2026-03-12 10:51:00-06'),
    ('ventas.oriente@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 373.00, 19, 'activa', '2026-03-12 10:51:00-06'),
    ('tienda@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 10', 412.00, 0, 'activa', '2026-03-12 10:51:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 10', 402.00, 16, 'activa', '2026-03-12 10:51:00-06'),
    ('tienda@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 690.00, 0, 'activa', '2026-03-13 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 734.00, 4, 'activa', '2026-03-13 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 735.00, 11, 'pausada', '2026-03-13 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 739.00, 9, 'activa', '2026-03-13 10:57:00-06'),
    ('tienda@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 725.00, 9, 'activa', '2026-03-13 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 702.00, 1, 'activa', '2026-03-13 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 762.00, 3, 'activa', '2026-03-13 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 694.00, 13, 'activa', '2026-03-13 10:57:00-06'),
    ('tienda@mesh.com', 'Zapato de tacos Relampago FG', '42 rojo', 752.00, 8, 'activa', '2026-03-13 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '42 rojo', 768.00, 0, 'activa', '2026-03-13 10:57:00-06'),
    ('tienda@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 940.00, 0, 'activa', '2026-03-14 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 901.00, 23, 'activa', '2026-03-14 10:14:00-06'),
    ('ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 992.00, 25, 'activa', '2026-03-14 10:14:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'M azul', 275.00, 9, 'activa', '2026-03-15 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Uniforme de entrenamiento Cantera', 'M azul', 281.00, 2, 'activa', '2026-03-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Uniforme de entrenamiento Cantera', 'M azul', 290.00, 20, 'activa', '2026-03-15 10:07:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'L azul', 292.00, 26, 'activa', '2026-03-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Uniforme de entrenamiento Cantera', 'L azul', 298.00, 2, 'activa', '2026-03-15 10:07:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 292.00, 6, 'activa', '2026-03-15 10:07:00-06'),
    ('ventas.oriente@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 311.00, 0, 'activa', '2026-03-15 10:07:00-06'),
    ('ventas.poniente@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 312.00, 24, 'activa', '2026-03-15 10:07:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 690.00, 0, 'activa', '2026-03-16 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 725.00, 23, 'activa', '2026-03-16 10:04:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'L negro', 690.00, 27, 'activa', '2026-03-16 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Casco de ruta Aerodino', 'L negro', 692.00, 9, 'activa', '2026-03-16 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Casco de ruta Aerodino', 'L negro', 733.00, 18, 'activa', '2026-03-16 10:04:00-06'),
    ('tienda@mesh.com', 'Bomba de piso Piston', 'Estandar', 310.00, 31, 'activa', '2026-03-17 10:22:00-06'),
    ('ventas.sur@mesh.com', 'Bomba de piso Piston', 'Estandar', 311.00, 13, 'activa', '2026-03-17 10:22:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'S negro', 210.00, 38, 'activa', '2026-03-18 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Guantes de ciclismo Palma Corta', 'S negro', 206.00, 6, 'activa', '2026-03-18 10:15:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 221.00, 10, 'activa', '2026-03-18 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 234.00, 15, 'activa', '2026-03-18 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 212.00, 21, 'activa', '2026-03-18 10:15:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 221.00, 13, 'activa', '2026-03-18 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 219.00, 25, 'activa', '2026-03-18 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 226.00, 9, 'activa', '2026-03-18 10:15:00-06'),
    ('tienda@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 540.00, 17, 'activa', '2026-03-19 10:19:00-06'),
    ('ventas.sur@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 525.00, 18, 'activa', '2026-03-19 10:19:00-06'),
    ('tienda@mesh.com', 'Sillin de ruta Vertebra SR-2', '155 mm', 583.00, 28, 'activa', '2026-03-19 10:19:00-06'),
    ('ventas.poniente@mesh.com', 'Sillin de ruta Vertebra SR-2', '155 mm', 618.00, 17, 'activa', '2026-03-19 10:19:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'M naranja', 460.00, 31, 'activa', '2026-03-20 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Maillot de ruta Peloton', 'M naranja', 425.00, 1, 'activa', '2026-03-20 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Maillot de ruta Peloton', 'M naranja', 466.00, 9, 'activa', '2026-03-20 10:20:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 488.00, 17, 'activa', '2026-03-20 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 474.00, 22, 'activa', '2026-03-20 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 457.00, 11, 'activa', '2026-03-20 10:20:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'L azul', 488.00, 32, 'activa', '2026-03-20 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Maillot de ruta Peloton', 'L azul', 493.00, 4, 'activa', '2026-03-20 10:20:00-06'),
    ('tienda@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 630.00, 38, 'activa', '2026-03-21 10:10:00-06'),
    ('ventas.norte@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 604.00, 7, 'activa', '2026-03-21 10:10:00-06'),
    ('ventas.oriente@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 653.00, 20, 'activa', '2026-03-21 10:10:00-06'),
    ('ventas.poniente@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 632.00, 7, 'activa', '2026-03-21 10:10:00-06'),
    ('tienda@mesh.com', 'Set de bandas elasticas', 'Set completo', 195.00, 20, 'activa', '2026-03-22 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Set de bandas elasticas', 'Set completo', 191.00, 21, 'activa', '2026-03-22 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Set de bandas elasticas', 'Set completo', 188.00, 14, 'pausada', '2026-03-22 10:04:00-06'),
    ('ventas.oriente@mesh.com', 'Set de bandas elasticas', 'Set completo', 199.00, 1, 'activa', '2026-03-22 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Set de bandas elasticas', 'Set completo', 193.00, 24, 'activa', '2026-03-22 10:04:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 380.00, 5, 'activa', '2026-03-23 10:35:00-06'),
    ('ventas.norte@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 371.00, 23, 'activa', '2026-03-23 10:35:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 380.00, 17, 'activa', '2026-03-23 10:35:00-06'),
    ('ventas.poniente@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 373.00, 1, 'activa', '2026-03-23 10:35:00-06'),
    ('tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1180.00, 22, 'activa', '2026-03-24 10:18:00-06'),
    ('ventas.norte@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1256.00, 20, 'activa', '2026-03-24 10:18:00-06'),
    ('tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 1628.00, 17, 'activa', '2026-03-24 10:18:00-06'),
    ('ventas.poniente@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 1673.00, 9, 'activa', '2026-03-24 10:18:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '12 kg', 430.00, 18, 'activa', '2026-03-25 10:54:00-06'),
    ('ventas.poniente@mesh.com', 'Pesa rusa Yunque', '12 kg', 426.00, 12, 'activa', '2026-03-25 10:54:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '16 kg', 550.00, 26, 'activa', '2026-03-25 10:54:00-06'),
    ('ventas.norte@mesh.com', 'Pesa rusa Yunque', '16 kg', 577.00, 13, 'activa', '2026-03-25 10:54:00-06'),
    ('ventas.sur@mesh.com', 'Pesa rusa Yunque', '16 kg', 538.00, 19, 'activa', '2026-03-25 10:54:00-06'),
    ('ventas.oriente@mesh.com', 'Pesa rusa Yunque', '16 kg', 591.00, 23, 'activa', '2026-03-25 10:54:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '20 kg', 667.00, 33, 'activa', '2026-03-25 10:54:00-06'),
    ('ventas.poniente@mesh.com', 'Pesa rusa Yunque', '20 kg', 665.00, 24, 'activa', '2026-03-25 10:54:00-06'),
    ('tienda@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 125.00, 35, 'activa', '2026-03-26 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 122.00, 9, 'activa', '2026-03-26 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 120.00, 0, 'activa', '2026-03-26 10:05:00-06'),
    ('tienda@mesh.com', 'Rodillo de liberacion Nudo', '33 cm', 210.00, 33, 'activa', '2026-03-27 10:47:00-06'),
    ('ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '33 cm', 214.00, 24, 'activa', '2026-03-27 10:47:00-06'),
    ('tienda@mesh.com', 'Rodillo de liberacion Nudo', '45 cm', 273.00, 4, 'activa', '2026-03-27 10:47:00-06'),
    ('ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '45 cm', 295.00, 11, 'activa', '2026-03-27 10:47:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta blanda', 180.00, 4, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta blanda', 169.00, 0, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta blanda', 183.00, 16, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta blanda', 175.00, 23, 'activa', '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta dura', 279.00, 16, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta dura', 274.00, 1, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta dura', 280.00, 14, 'activa', '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta dura', 301.00, 20, 'activa', '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 145.00, 26, 'activa', '2026-04-01 10:23:00-06'),
    ('ventas.sur@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 153.00, 12, 'activa', '2026-04-01 10:23:00-06'),
    ('tienda@mesh.com', 'La casa de los relojes detenidos', 'Pasta blanda', 195.00, 26, 'activa', '2026-04-02 10:31:00-06'),
    ('ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 'Pasta blanda', 204.00, 8, 'activa', '2026-04-02 10:31:00-06'),
    ('tienda@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 289.00, 16, 'activa', '2026-04-02 10:31:00-06'),
    ('ventas.norte@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 303.00, 7, 'activa', '2026-04-02 10:31:00-06'),
    ('ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 310.00, 23, 'activa', '2026-04-02 10:31:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Digital', 95.00, 0, 'activa', '2026-04-03 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Cartas al puerto seco', 'Digital', 99.00, 6, 'pausada', '2026-04-03 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Cartas al puerto seco', 'Digital', 96.00, 7, 'activa', '2026-04-03 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Cartas al puerto seco', 'Digital', 88.00, 25, 'activa', '2026-04-03 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Cartas al puerto seco', 'Digital', 94.00, 14, 'activa', '2026-04-03 10:25:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Pasta blanda', 135.00, 32, 'activa', '2026-04-03 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Cartas al puerto seco', 'Pasta blanda', 140.00, 12, 'activa', '2026-04-03 10:25:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Pasta dura', 179.00, 30, 'activa', '2026-04-03 10:25:00-06'),
    ('tienda@mesh.com', 'Nadie duerme en Tecpanal', 'Pasta dura', 210.00, 21, 'activa', '2026-04-04 10:20:00-06'),
    ('ventas.sur@mesh.com', 'Nadie duerme en Tecpanal', 'Pasta dura', 219.00, 17, 'activa', '2026-04-04 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Nadie duerme en Tecpanal', 'Pasta dura', 195.00, 0, 'activa', '2026-04-04 10:20:00-06'),
    ('tienda@mesh.com', 'Antologia del ruido', 'Pasta blanda', 135.00, 31, 'activa', '2026-04-05 10:23:00-06'),
    ('ventas.norte@mesh.com', 'Antologia del ruido', 'Pasta blanda', 132.00, 22, 'activa', '2026-04-05 10:23:00-06'),
    ('ventas.sur@mesh.com', 'Antologia del ruido', 'Pasta blanda', 133.00, 0, 'activa', '2026-04-05 10:23:00-06'),
    ('tienda@mesh.com', 'Antologia del ruido', 'Edicion ilustrada', 219.00, 33, 'activa', '2026-04-05 10:23:00-06'),
    ('ventas.sur@mesh.com', 'Antologia del ruido', 'Edicion ilustrada', 208.00, 9, 'activa', '2026-04-05 10:23:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 620.00, 26, 'activa', '2026-04-06 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 608.00, 19, 'pausada', '2026-04-06 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 615.00, 16, 'activa', '2026-04-06 10:52:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Digital', 341.00, 25, 'activa', '2026-04-06 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Bases de datos distribuidas', 'Digital', 325.00, 13, 'activa', '2026-04-06 10:52:00-06'),
    ('tienda@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 580.00, 24, 'activa', '2026-04-07 10:34:00-06'),
    ('ventas.norte@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 562.00, 18, 'activa', '2026-04-07 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 587.00, 2, 'activa', '2026-04-07 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 569.00, 18, 'activa', '2026-04-07 10:34:00-06'),
    ('tienda@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 777.00, 16, 'activa', '2026-04-07 10:34:00-06'),
    ('ventas.norte@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 733.00, 16, 'activa', '2026-04-07 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 785.00, 1, 'activa', '2026-04-07 10:34:00-06'),
    ('tienda@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 495.00, 18, 'activa', '2026-04-08 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 514.00, 5, 'activa', '2026-04-08 10:45:00-06'),
    ('ventas.poniente@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 509.00, 1, 'activa', '2026-04-08 10:45:00-06'),
    ('tienda@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta blanda', 340.00, 38, 'activa', '2026-04-09 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta blanda', 322.00, 17, 'activa', '2026-04-09 10:03:00-06'),
    ('tienda@mesh.com', 'Manual de instalaciones electricas residenciales', 'Espiral', 401.00, 0, 'activa', '2026-04-09 10:03:00-06'),
    ('ventas.oriente@mesh.com', 'Manual de instalaciones electricas residenciales', 'Espiral', 377.00, 0, 'activa', '2026-04-09 10:03:00-06'),
    ('tienda@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta dura', 527.00, 6, 'activa', '2026-04-09 10:03:00-06'),
    ('tienda@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura', 650.00, 13, 'activa', '2026-04-10 10:07:00-06'),
    ('ventas.oriente@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura', 667.00, 16, 'activa', '2026-04-10 10:07:00-06'),
    ('tienda@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 793.00, 18, 'activa', '2026-04-10 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 813.00, 10, 'pausada', '2026-04-10 10:07:00-06'),
    ('ventas.oriente@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 793.00, 7, 'activa', '2026-04-10 10:07:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '30 ml', 210.00, 30, 'activa', '2026-04-11 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Serum de niacinamida 10%', '30 ml', 212.00, 15, 'activa', '2026-04-11 10:30:00-06'),
    ('ventas.oriente@mesh.com', 'Serum de niacinamida 10%', '30 ml', 226.00, 23, 'activa', '2026-04-11 10:30:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '50 ml', 311.00, 19, 'activa', '2026-04-11 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Serum de niacinamida 10%', '50 ml', 324.00, 8, 'activa', '2026-04-11 10:30:00-06'),
    ('ventas.oriente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 289.00, 0, 'activa', '2026-04-11 10:30:00-06'),
    ('ventas.poniente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 328.00, 5, 'activa', '2026-04-11 10:30:00-06'),
    ('tienda@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 265.00, 19, 'activa', '2026-04-12 10:17:00-06'),
    ('ventas.sur@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 255.00, 17, 'activa', '2026-04-12 10:17:00-06'),
    ('tienda@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 320.00, 31, 'activa', '2026-04-13 10:50:00-06'),
    ('ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 307.00, 11, 'activa', '2026-04-13 10:50:00-06'),
    ('ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 346.00, 17, 'activa', '2026-04-13 10:50:00-06'),
    ('tienda@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 496.00, 11, 'activa', '2026-04-13 10:50:00-06'),
    ('ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 518.00, 5, 'activa', '2026-04-13 10:50:00-06'),
    ('ventas.sur@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 498.00, 7, 'activa', '2026-04-13 10:50:00-06'),
    ('ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 500.00, 23, 'activa', '2026-04-13 10:50:00-06'),
    ('ventas.poniente@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 529.00, 24, 'activa', '2026-04-13 10:50:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '150 ml', 145.00, 14, 'activa', '2026-04-14 10:18:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '250 ml', 196.00, 7, 'activa', '2026-04-14 10:18:00-06'),
    ('ventas.oriente@mesh.com', 'Limpiador en gel Verdo', '250 ml', 202.00, 3, 'pausada', '2026-04-14 10:18:00-06'),
    ('ventas.poniente@mesh.com', 'Limpiador en gel Verdo', '250 ml', 209.00, 16, 'activa', '2026-04-14 10:18:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '400 ml', 249.00, 25, 'activa', '2026-04-14 10:18:00-06'),
    ('ventas.norte@mesh.com', 'Limpiador en gel Verdo', '400 ml', 249.00, 8, 'activa', '2026-04-14 10:18:00-06'),
    ('ventas.sur@mesh.com', 'Limpiador en gel Verdo', '400 ml', 264.00, 23, 'activa', '2026-04-14 10:18:00-06'),
    ('ventas.oriente@mesh.com', 'Limpiador en gel Verdo', '400 ml', 268.00, 13, 'activa', '2026-04-14 10:18:00-06'),
    ('ventas.poniente@mesh.com', 'Limpiador en gel Verdo', '400 ml', 235.00, 0, 'activa', '2026-04-14 10:18:00-06'),
    ('tienda@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 235.00, 9, 'activa', '2026-04-15 10:09:00-06'),
    ('ventas.norte@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 234.00, 18, 'activa', '2026-04-15 10:09:00-06'),
    ('ventas.poniente@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 246.00, 16, 'activa', '2026-04-15 10:09:00-06'),
    ('tienda@mesh.com', 'Contorno de ojos Lumine', '15 ml', 280.00, 22, 'activa', '2026-04-16 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Contorno de ojos Lumine', '15 ml', 293.00, 8, 'activa', '2026-04-16 10:27:00-06'),
    ('tienda@mesh.com', 'Contorno de ojos Lumine', '30 ml', 406.00, 37, 'activa', '2026-04-16 10:27:00-06'),
    ('ventas.norte@mesh.com', 'Contorno de ojos Lumine', '30 ml', 410.00, 18, 'activa', '2026-04-16 10:27:00-06'),
    ('ventas.poniente@mesh.com', 'Contorno de ojos Lumine', '30 ml', 423.00, 2, 'activa', '2026-04-16 10:27:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '50 ml', 720.00, 14, 'activa', '2026-04-17 10:24:00-06'),
    ('ventas.oriente@mesh.com', 'Eau de parfum Bruma', '50 ml', 761.00, 15, 'activa', '2026-04-17 10:24:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '100 ml', 1166.00, 14, 'activa', '2026-04-17 10:24:00-06'),
    ('ventas.norte@mesh.com', 'Eau de parfum Bruma', '100 ml', 1081.00, 24, 'activa', '2026-04-17 10:24:00-06'),
    ('ventas.sur@mesh.com', 'Eau de parfum Bruma', '100 ml', 1232.00, 15, 'activa', '2026-04-17 10:24:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '30 ml', 480.00, 21, 'activa', '2026-04-18 10:04:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '60 ml', 710.00, 0, 'activa', '2026-04-18 10:04:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '100 ml', 888.00, 30, 'activa', '2026-04-18 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Eau de toilette Salino', '100 ml', 896.00, 14, 'activa', '2026-04-18 10:04:00-06'),
    ('tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 290.00, 28, 'activa', '2026-04-19 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 297.00, 18, 'activa', '2026-04-19 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 298.00, 16, 'activa', '2026-04-19 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 296.00, 4, 'activa', '2026-04-19 10:57:00-06'),
    ('tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 487.00, 27, 'activa', '2026-04-19 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 456.00, 11, 'activa', '2026-04-19 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 489.00, 0, 'activa', '2026-04-19 10:57:00-06'),
    ('tienda@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 165.00, 17, 'activa', '2026-04-20 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 161.00, 2, 'activa', '2026-04-20 10:14:00-06'),
    ('ventas.poniente@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 159.00, 16, 'activa', '2026-04-20 10:14:00-06'),
    ('tienda@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 390.00, 3, 'activa', '2026-04-21 10:48:00-06'),
    ('ventas.norte@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 385.00, 18, 'activa', '2026-04-21 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 378.00, 20, 'activa', '2026-04-21 10:48:00-06'),
    ('tienda@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion dia', 437.00, 12, 'activa', '2026-04-21 10:48:00-06')
) AS v(correo, producto, variante, precio, stock, estado, fecha)
JOIN usuarios            u  ON u.correo_electronico = v.correo
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
JOIN estado_oferta       eo ON eo.estado_oferta_nombre = v.estado
JOIN usuarios            ut ON ut.correo_electronico = 'tienda@mesh.com';

-- ============================================================
-- El historial de precio: 762 filas
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
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6228.00, '2026-01-04 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 5947.00, '2026-01-04 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6296.00, '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8804.00, '2026-01-04 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8939.00, '2026-01-04 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8577.00, '2026-01-04 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8256.00, '2026-01-04 10:52:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9400.00, '2026-01-05 10:22:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 9606.00, '2026-01-05 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 14570.00, '2026-01-05 10:22:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB', 15515.00, '2026-01-05 10:22:00-06'),
    ('tienda@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 4100.00, '2026-01-06 10:32:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Nimbo 13', '8 GB / 256 GB', 3779.00, '2026-01-06 10:32:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 512 GB', 5400.00, '2026-01-07 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 1 TB', 6426.00, '2026-01-07 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Lienzo 15', '16 GB / 1 TB', 6594.00, '2026-01-07 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 7884.00, '2026-01-07 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 7255.00, '2026-01-07 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 8307.00, '2026-01-07 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 11800.00, '2026-01-08 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 10958.00, '2026-01-08 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB', 12415.00, '2026-01-08 10:38:00-06'),
    ('tienda@mesh.com', 'Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 16284.00, '2026-01-08 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Cumbre 17 Gamer', '64 GB / 2 TB', 15932.00, '2026-01-08 10:38:00-06'),
    ('tienda@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3450.00, '2026-01-09 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3176.00, '2026-01-09 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3221.00, '2026-01-09 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3529.00, '2026-01-09 10:34:00-06'),
    ('tienda@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4750.00, '2026-01-10 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4562.00, '2026-01-10 10:02:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4641.00, '2026-01-10 10:02:00-06'),
    ('tienda@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6033.00, '2026-01-10 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6000.00, '2026-01-10 10:02:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 5643.00, '2026-01-10 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6098.00, '2026-01-10 10:02:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '128 GB', 5300.00, '2026-01-24 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Vela 7', '128 GB', 4957.00, '2026-01-24 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Vela 7', '128 GB', 5461.00, '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '256 GB', 6254.00, '2026-01-24 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Vela 7', '256 GB', 6691.00, '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '512 GB', 7208.00, '2026-01-24 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1850.00, '2026-01-12 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1918.00, '2026-01-12 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1849.00, '2026-01-12 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1985.00, '2026-01-12 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '64 GB', 1931.00, '2026-01-12 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2257.00, '2026-01-12 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2120.00, '2026-01-12 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2301.00, '2026-01-12 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2246.00, '2026-01-12 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '256 GB', 7200.00, '2026-01-13 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Nautilo Pro', '256 GB', 7358.00, '2026-01-13 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '512 GB', 8712.00, '2026-01-13 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Nautilo Pro', '512 GB', 8999.00, '2026-01-13 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '1 TB', 10656.00, '2026-01-13 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Nautilo Pro', '1 TB', 11052.00, '2026-01-13 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Pedernal Rugged', '128 GB', 3900.00, '2026-01-14 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Pedernal Rugged', '128 GB', 3877.00, '2026-01-14 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Pedernal Rugged', '256 GB', 4524.00, '2026-01-14 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Pedernal Rugged', '256 GB', 4537.00, '2026-01-14 10:25:00-06'),
    ('tienda@mesh.com', 'Telefono Bruma Mini', '128 GB', 2600.00, '2026-01-15 10:48:00-06'),
    ('tienda@mesh.com', 'Telefono Cuarzo Duo', '32 GB', 1450.00, '2026-01-16 10:15:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Cuarzo Duo', '32 GB', 1550.00, '2026-01-16 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Cuarzo Duo', '32 GB', 1387.00, '2026-01-16 10:15:00-06'),
    ('tienda@mesh.com', 'Telefono Cuarzo Duo', '64 GB', 1798.00, '2026-01-16 10:15:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1450.00, '2026-01-17 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Sereno ANC', 'Negro', 1418.00, '2026-01-17 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Arena', 1450.00, '2026-01-17 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Sereno ANC', 'Arena', 1484.00, '2026-01-17 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 620.00, '2026-01-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 659.00, '2026-01-18 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 574.00, '2026-01-18 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 621.00, '2026-01-18 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Brisa Sport', 'Gris', 620.00, '2026-01-18 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 651.00, '2026-01-18 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Brisa Sport', 'Gris', 640.00, '2026-01-18 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Estudio 900', 'Cable 3 m', 2100.00, '2026-01-19 10:38:00-06'),
    ('tienda@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla', 980.00, '2026-01-20 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla', 903.00, '2026-01-20 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla', 915.00, '2026-01-20 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Colibri Micro TWS', 'Negro mate', 1039.00, '2026-01-20 10:05:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Colibri Micro TWS', 'Negro mate', 1028.00, '2026-01-20 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Colibri Micro TWS', 'Verde menta', 1068.00, '2026-01-20 10:05:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Colibri Micro TWS', 'Verde menta', 1059.00, '2026-01-20 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Colibri Micro TWS', 'Verde menta', 1139.00, '2026-01-20 10:05:00-06'),
    ('tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3400.00, '2026-01-21 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3508.00, '2026-01-21 10:04:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3458.00, '2026-01-21 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3458.00, '2026-01-21 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 3808.00, '2026-01-21 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 3521.00, '2026-01-21 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 4 m', 3953.00, '2026-01-21 10:04:00-06'),
    ('tienda@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1750.00, '2026-01-22 10:16:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1722.00, '2026-01-22 10:16:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1801.00, '2026-01-22 10:16:00-06'),
    ('tienda@mesh.com', 'Audifonos Duna Trabajo', 'Blanco hueso', 1873.00, '2026-01-22 10:16:00-06'),
    ('tienda@mesh.com', 'Audifonos Zumbo Cable', 'Cable 1.2 m', 210.00, '2026-01-23 10:25:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2750.00, '2026-01-24 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2960.00, '2026-01-24 10:48:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Horizonte 27', '75 Hz', 2537.00, '2026-01-24 10:48:00-06'),
    ('tienda@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3658.00, '2026-01-24 10:48:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3475.00, '2026-01-24 10:48:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3467.00, '2026-01-24 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Horizonte 27', '165 Hz', 3465.00, '2026-01-24 10:48:00-06'),
    ('tienda@mesh.com', 'Monitor Panorama 34', '100 Hz', 5900.00, '2026-01-25 10:56:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Panorama 34', '100 Hz', 5902.00, '2026-01-25 10:56:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Panorama 34', '100 Hz', 6289.00, '2026-01-25 10:56:00-06'),
    ('tienda@mesh.com', 'Monitor Vitral 24', '75 Hz', 1650.00, '2026-01-26 10:42:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Vitral 24', '75 Hz', 1645.00, '2026-01-26 10:42:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vitral 24', '75 Hz', 1705.00, '2026-01-26 10:42:00-06'),
    ('tienda@mesh.com', 'Monitor Vitral 24', '100 Hz', 1947.00, '2026-01-26 10:42:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Vitral 24', '100 Hz', 1981.00, '2026-01-26 10:42:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vitral 24', '100 Hz', 1846.00, '2026-01-26 10:42:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Vitral 24', '100 Hz', 1811.00, '2026-01-26 10:42:00-06'),
    ('tienda@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4300.00, '2026-01-27 10:27:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4044.00, '2026-01-27 10:27:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4500.00, '2026-01-27 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Cenit 32 4K', '60 Hz', 4107.00, '2026-01-27 10:27:00-06'),
    ('tienda@mesh.com', 'Monitor Vertice 27 Gamer', '144 Hz', 3450.00, '2026-01-28 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '144 Hz', 3645.00, '2026-01-28 10:20:00-06'),
    ('tienda@mesh.com', 'Monitor Vertice 27 Gamer', '180 Hz', 4002.00, '2026-01-28 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '180 Hz', 3986.00, '2026-01-28 10:20:00-06'),
    ('tienda@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 5106.00, '2026-01-28 10:20:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 5340.00, '2026-01-28 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 4715.00, '2026-01-28 10:20:00-06'),
    ('tienda@mesh.com', 'Monitor Nube 22', 'Negro', 1180.00, '2026-02-01 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Nube 22', 'Negro', 1096.00, '2026-02-01 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Nube 22', 'Negro', 1251.00, '2026-02-01 10:26:00-06'),
    ('tienda@mesh.com', 'Monitor Nube 22', 'Blanco', 1251.00, '2026-02-01 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Nube 22', 'Blanco', 1284.00, '2026-02-01 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Nube 22', 'Blanco', 1173.00, '2026-02-01 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Nube 22', 'Blanco', 1290.00, '2026-02-01 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Nube 22', 'Blanco', 1190.00, '2026-02-01 10:26:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1980.00, '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '1.5 L', 1892.00, '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2455.00, '2026-02-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2311.00, '2026-02-08 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2641.00, '2026-02-08 12:00:00-06'),
    ('tienda@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1240.00, '2026-02-03 10:59:00-06'),
    ('ventas.sur@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1162.00, '2026-02-03 10:59:00-06'),
    ('ventas.oriente@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1270.00, '2026-02-03 10:59:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 890.00, '2026-02-04 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 922.00, '2026-02-04 10:34:00-06'),
    ('tienda@mesh.com', 'Licuadora Torbellino 1200', '2 L', 1023.00, '2026-02-04 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Licuadora Torbellino 1200', '2 L', 998.00, '2026-02-04 10:34:00-06'),
    ('tienda@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 385.00, '2026-02-05 10:52:00-06'),
    ('ventas.sur@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 377.00, '2026-02-05 10:52:00-06'),
    ('ventas.poniente@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 383.00, '2026-02-05 10:52:00-06'),
    ('tienda@mesh.com', 'Hervidor electrico Vapor 1.7', 'Negro mate', 416.00, '2026-02-05 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Hervidor electrico Vapor 1.7', 'Negro mate', 389.00, '2026-02-05 10:52:00-06'),
    ('tienda@mesh.com', 'Cacerola honda Comal 18', '16 cm', 420.00, '2026-02-06 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Cacerola honda Comal 18', '16 cm', 394.00, '2026-02-06 10:03:00-06'),
    ('ventas.poniente@mesh.com', 'Cacerola honda Comal 18', '16 cm', 390.00, '2026-02-06 10:03:00-06'),
    ('tienda@mesh.com', 'Cacerola honda Comal 18', '18 cm', 512.00, '2026-02-06 10:03:00-06'),
    ('tienda@mesh.com', 'Cacerola honda Comal 18', '20 cm', 609.00, '2026-02-06 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Cacerola honda Comal 18', '20 cm', 602.00, '2026-02-06 10:03:00-06'),
    ('ventas.poniente@mesh.com', 'Cacerola honda Comal 18', '20 cm', 612.00, '2026-02-06 10:03:00-06'),
    ('tienda@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 540.00, '2026-02-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 498.00, '2026-02-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 576.00, '2026-02-07 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 568.00, '2026-02-07 10:45:00-06'),
    ('tienda@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 702.00, '2026-02-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 697.00, '2026-02-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 665.00, '2026-02-07 10:45:00-06'),
    ('ventas.poniente@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 651.00, '2026-02-07 10:45:00-06'),
    ('tienda@mesh.com', 'Tabla de picar Cedro grande', 'Grande', 195.00, '2026-02-08 10:16:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Natural', 2350.00, '2026-02-09 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Natural', 2261.00, '2026-02-09 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Escritorio Roble 120', 'Natural', 2166.00, '2026-02-09 10:57:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Nogal', 2350.00, '2026-02-09 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Escritorio Roble 120', 'Nogal', 2304.00, '2026-02-09 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Escritorio Roble 120', 'Nogal', 2463.00, '2026-02-09 10:57:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3100.00, '2026-02-10 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3079.00, '2026-02-10 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3344.00, '2026-02-10 10:26:00-06'),
    ('ventas.oriente@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 2971.00, '2026-02-10 10:26:00-06'),
    ('tienda@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3100.00, '2026-02-10 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Silla ergonomica Vertebra', 'Gris', 3046.00, '2026-02-10 10:26:00-06'),
    ('tienda@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1450.00, '2026-02-11 10:12:00-06'),
    ('ventas.norte@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1542.00, '2026-02-11 10:12:00-06'),
    ('ventas.oriente@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1454.00, '2026-02-11 10:12:00-06'),
    ('ventas.poniente@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1470.00, '2026-02-11 10:12:00-06'),
    ('tienda@mesh.com', 'Librero Hoja 5 niveles', '6 niveles nogal', 1798.00, '2026-02-11 10:12:00-06'),
    ('ventas.oriente@mesh.com', 'Librero Hoja 5 niveles', '6 niveles nogal', 1743.00, '2026-02-11 10:12:00-06'),
    ('tienda@mesh.com', 'Mesa de centro Guijarro', 'Natural', 980.00, '2026-02-12 10:08:00-06'),
    ('ventas.norte@mesh.com', 'Mesa de centro Guijarro', 'Natural', 942.00, '2026-02-12 10:08:00-06'),
    ('ventas.oriente@mesh.com', 'Mesa de centro Guijarro', 'Natural', 992.00, '2026-02-12 10:08:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Natural', 420.00, '2026-02-13 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Silla de comedor Vara', 'Natural', 412.00, '2026-02-13 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Silla de comedor Vara', 'Natural', 400.00, '2026-02-13 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Natural', 421.00, '2026-02-13 10:38:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Negra', 462.00, '2026-02-13 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Silla de comedor Vara', 'Negra', 486.00, '2026-02-13 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Silla de comedor Vara', 'Negra', 459.00, '2026-02-13 10:38:00-06'),
    ('ventas.oriente@mesh.com', 'Silla de comedor Vara', 'Negra', 439.00, '2026-02-13 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Negra', 462.00, '2026-02-13 10:38:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 567.00, '2026-02-13 10:38:00-06'),
    ('ventas.norte@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 560.00, '2026-02-13 10:38:00-06'),
    ('ventas.sur@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 577.00, '2026-02-13 10:38:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 560.00, '2026-02-13 10:38:00-06'),
    ('tienda@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1890.00, '2026-02-14 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1816.00, '2026-02-14 10:20:00-06'),
    ('tienda@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas', 2608.00, '2026-02-14 10:20:00-06'),
    ('ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas', 2697.00, '2026-02-14 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas', 2696.00, '2026-02-14 10:20:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 480.00, '2026-02-15 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 488.00, '2026-02-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 461.00, '2026-02-15 10:07:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 506.00, '2026-02-15 10:07:00-06'),
    ('tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra', 480.00, '2026-02-15 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de escritorio Faro', 'Negra', 488.00, '2026-02-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de escritorio Faro', 'Negra', 472.00, '2026-02-15 10:07:00-06'),
    ('tienda@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 320.00, '2026-02-16 10:30:00-06'),
    ('ventas.poniente@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 338.00, '2026-02-16 10:30:00-06'),
    ('tienda@mesh.com', 'Lampara colgante Candela 40', 'Mimbre natural', 760.00, '2026-02-17 10:42:00-06'),
    ('ventas.sur@mesh.com', 'Lampara colgante Candela 40', 'Mimbre natural', 780.00, '2026-02-17 10:42:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara colgante Candela 40', 'Mimbre natural', 798.00, '2026-02-17 10:42:00-06'),
    ('tienda@mesh.com', 'Lampara colgante Candela 40', 'Negro mate', 874.00, '2026-02-17 10:42:00-06'),
    ('ventas.norte@mesh.com', 'Lampara colgante Candela 40', 'Negro mate', 844.00, '2026-02-17 10:42:00-06'),
    ('tienda@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1150.00, '2026-02-18 10:55:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1167.00, '2026-02-18 10:55:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1102.00, '2026-02-18 10:55:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1219.00, '2026-02-18 10:55:00-06'),
    ('tienda@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1357.00, '2026-02-18 10:55:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1307.00, '2026-02-18 10:55:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1455.00, '2026-02-18 10:55:00-06'),
    ('tienda@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1553.00, '2026-02-18 10:55:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1552.00, '2026-02-18 10:55:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1535.00, '2026-02-18 10:55:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton', 1507.00, '2026-02-18 10:55:00-06'),
    ('tienda@mesh.com', 'Plafon LED Solaz 24', 'Blanco 24 W', 540.00, '2026-02-19 10:59:00-06'),
    ('ventas.poniente@mesh.com', 'Plafon LED Solaz 24', 'Blanco 24 W', 563.00, '2026-02-19 10:59:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Negro mate', 215.00, '2026-02-20 10:29:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Cobre envejecido', 262.00, '2026-02-20 10:29:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'S azul', 340.00, '2026-01-12 09:00:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de lino manga larga', 'S azul', 344.00, '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'M azul', 340.00, '2026-01-12 09:00:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de lino manga larga', 'M azul', 355.00, '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'L blanca', 340.00, '2026-01-12 09:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de lino manga larga', 'L blanca', 323.00, '2026-01-12 09:00:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'M celeste', 290.00, '2026-02-22 10:47:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa oxford clasica', 'M celeste', 295.00, '2026-02-22 10:47:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa oxford clasica', 'M celeste', 297.00, '2026-02-22 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'L celeste', 290.00, '2026-02-22 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 395.00, '2026-02-23 10:01:00-06'),
    ('ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 399.00, '2026-02-23 10:01:00-06'),
    ('ventas.sur@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 379.00, '2026-02-23 10:01:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa guayabera Xelaju', 'M blanca', 378.00, '2026-02-23 10:01:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'L hueso', 419.00, '2026-02-23 10:01:00-06'),
    ('ventas.sur@mesh.com', 'Camisa guayabera Xelaju', 'L hueso', 430.00, '2026-02-23 10:01:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso', 442.00, '2026-02-23 10:01:00-06'),
    ('ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso', 449.00, '2026-02-23 10:01:00-06'),
    ('tienda@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 315.00, '2026-02-24 10:47:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 297.00, '2026-02-24 10:47:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 306.00, '2026-02-24 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa de vestir Meridiano', 'L gris perla', 340.00, '2026-02-24 10:47:00-06'),
    ('ventas.sur@mesh.com', 'Camisa de vestir Meridiano', 'L gris perla', 331.00, '2026-02-24 10:47:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de vestir Meridiano', 'L gris perla', 316.00, '2026-02-24 10:47:00-06'),
    ('tienda@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 430.00, '2026-02-25 10:02:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 427.00, '2026-02-25 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 457.00, '2026-02-25 10:02:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 409.00, '2026-02-25 10:02:00-06'),
    ('tienda@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro', 469.00, '2026-02-25 10:02:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro', 445.00, '2026-02-25 10:02:00-06'),
    ('tienda@mesh.com', 'Camisa polo pique Cardumen', 'M azul marino', 245.00, '2026-02-26 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Camisa polo pique Cardumen', 'M azul marino', 228.00, '2026-02-26 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa polo pique Cardumen', 'M azul marino', 261.00, '2026-02-26 10:34:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 420.00, '2026-02-27 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '32 beige', 441.00, '2026-02-27 10:30:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 beige', 420.00, '2026-02-27 10:30:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon chino resistente', '34 beige', 446.00, '2026-02-27 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 beige', 440.00, '2026-02-27 10:30:00-06'),
    ('ventas.oriente@mesh.com', 'Pantalon chino resistente', '34 beige', 399.00, '2026-02-27 10:30:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon chino resistente', '34 beige', 445.00, '2026-02-27 10:30:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '34 azul', 420.00, '2026-02-27 10:30:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon chino resistente', '34 azul', 426.00, '2026-02-27 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 azul', 413.00, '2026-02-27 10:30:00-06'),
    ('tienda@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 520.00, '2026-02-28 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 524.00, '2026-02-28 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 504.00, '2026-02-28 10:57:00-06'),
    ('tienda@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 556.00, '2026-02-28 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 527.00, '2026-02-28 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 567.00, '2026-02-28 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro', 576.00, '2026-02-28 10:57:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva', 480.00, '2026-03-01 10:46:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva', 483.00, '2026-03-01 10:46:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '34 arena', 509.00, '2026-03-01 10:46:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon cargo Vereda', '34 arena', 548.00, '2026-03-01 10:46:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '36 negro', 538.00, '2026-03-01 10:46:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon cargo Vereda', '36 negro', 504.00, '2026-03-01 10:46:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon cargo Vereda', '36 negro', 568.00, '2026-03-01 10:46:00-06'),
    ('tienda@mesh.com', 'Pantalon de vestir Consulado', '32 gris oxford', 610.00, '2026-03-02 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Pantalon de vestir Consulado', '32 gris oxford', 563.00, '2026-03-02 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de vestir Consulado', '32 gris oxford', 637.00, '2026-03-02 10:20:00-06'),
    ('tienda@mesh.com', 'Pantalon jogger Ocaso', 'M gris jaspe', 285.00, '2026-03-03 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon jogger Ocaso', 'M gris jaspe', 268.00, '2026-03-03 10:57:00-06'),
    ('tienda@mesh.com', 'Pantalon jogger Ocaso', 'L negro', 308.00, '2026-03-03 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Pantalon jogger Ocaso', 'L negro', 310.00, '2026-03-03 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon jogger Ocaso', 'L negro', 330.00, '2026-03-03 10:57:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '40 cafe', 780.00, '2026-03-04 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '40 cafe', 749.00, '2026-03-04 10:14:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '40 cafe', 806.00, '2026-03-04 10:14:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 cafe', 780.00, '2026-03-04 10:14:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '42 cafe', 735.00, '2026-03-04 10:14:00-06'),
    ('tienda@mesh.com', 'Zapato de cuero Senda', '42 negro', 780.00, '2026-03-04 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '42 negro', 729.00, '2026-03-04 10:14:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 negro', 789.00, '2026-03-04 10:14:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de cuero Senda', '42 negro', 822.00, '2026-03-04 10:14:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '41', 1150.00, '2026-03-05 10:09:00-06'),
    ('ventas.norte@mesh.com', 'Bota impermeable Cumbre', '41', 1164.00, '2026-03-05 10:09:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '43', 1150.00, '2026-03-05 10:09:00-06'),
    ('ventas.norte@mesh.com', 'Bota impermeable Cumbre', '43', 1205.00, '2026-03-05 10:09:00-06'),
    ('ventas.sur@mesh.com', 'Bota impermeable Cumbre', '43', 1131.00, '2026-03-05 10:09:00-06'),
    ('ventas.poniente@mesh.com', 'Bota impermeable Cumbre', '43', 1200.00, '2026-03-05 10:09:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 650.00, '2026-03-06 10:37:00-06'),
    ('ventas.oriente@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 657.00, '2026-03-06 10:37:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 683.00, '2026-03-06 10:37:00-06'),
    ('ventas.norte@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 642.00, '2026-03-06 10:37:00-06'),
    ('ventas.sur@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 632.00, '2026-03-06 10:37:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '43 gris', 702.00, '2026-03-06 10:37:00-06'),
    ('ventas.norte@mesh.com', 'Tenis urbano Vereda 90', '43 gris', 731.00, '2026-03-06 10:37:00-06'),
    ('ventas.oriente@mesh.com', 'Tenis urbano Vereda 90', '43 gris', 649.00, '2026-03-06 10:37:00-06'),
    ('tienda@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 890.00, '2026-03-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 884.00, '2026-03-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 906.00, '2026-03-07 10:45:00-06'),
    ('tienda@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 961.00, '2026-03-07 10:45:00-06'),
    ('ventas.norte@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 909.00, '2026-03-07 10:45:00-06'),
    ('ventas.sur@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 892.00, '2026-03-07 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 993.00, '2026-03-07 10:45:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '40 negro', 1320.00, '2026-03-08 10:39:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '42 negro', 1399.00, '2026-03-08 10:39:00-06'),
    ('ventas.oriente@mesh.com', 'Bota de trabajo Yunque S3', '42 negro', 1446.00, '2026-03-08 10:39:00-06'),
    ('ventas.poniente@mesh.com', 'Bota de trabajo Yunque S3', '42 negro', 1427.00, '2026-03-08 10:39:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1465.00, '2026-03-08 10:39:00-06'),
    ('ventas.norte@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1535.00, '2026-03-08 10:39:00-06'),
    ('ventas.sur@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1467.00, '2026-03-08 10:39:00-06'),
    ('ventas.poniente@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1474.00, '2026-03-08 10:39:00-06'),
    ('tienda@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 410.00, '2026-03-09 10:19:00-06'),
    ('ventas.sur@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 382.00, '2026-03-09 10:19:00-06'),
    ('ventas.oriente@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 387.00, '2026-03-09 10:19:00-06'),
    ('ventas.poniente@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 416.00, '2026-03-09 10:19:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 260.00, '2026-04-06 08:00:00-06'),
    ('ventas.norte@mesh.com', 'Balon de futbol numero 5', 'Blanco', 257.00, '2026-04-06 08:00:00-06'),
    ('ventas.oriente@mesh.com', 'Balon de futbol numero 5', 'Blanco', 261.00, '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Naranja', 260.00, '2026-04-06 08:00:00-06'),
    ('ventas.poniente@mesh.com', 'Balon de futbol numero 5', 'Naranja', 250.00, '2026-04-06 08:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'M', 145.00, '2026-03-11 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'M', 134.00, '2026-03-11 10:26:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'M', 139.00, '2026-03-11 10:26:00-06'),
    ('ventas.poniente@mesh.com', 'Espinilleras Muralla', 'M', 138.00, '2026-03-11 10:26:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'L', 145.00, '2026-03-11 10:26:00-06'),
    ('ventas.norte@mesh.com', 'Espinilleras Muralla', 'L', 156.00, '2026-03-11 10:26:00-06'),
    ('tienda@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 385.00, '2026-03-12 10:51:00-06'),
    ('ventas.norte@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 399.00, '2026-03-12 10:51:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 381.00, '2026-03-12 10:51:00-06'),
    ('ventas.oriente@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 373.00, '2026-03-12 10:51:00-06'),
    ('tienda@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 10', 412.00, '2026-03-12 10:51:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 10', 402.00, '2026-03-12 10:51:00-06'),
    ('tienda@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 690.00, '2026-03-13 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 734.00, '2026-03-13 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 735.00, '2026-03-13 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 739.00, '2026-03-13 10:57:00-06'),
    ('tienda@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 725.00, '2026-03-13 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 702.00, '2026-03-13 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 762.00, '2026-03-13 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 694.00, '2026-03-13 10:57:00-06'),
    ('tienda@mesh.com', 'Zapato de tacos Relampago FG', '42 rojo', 752.00, '2026-03-13 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '42 rojo', 768.00, '2026-03-13 10:57:00-06'),
    ('tienda@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 940.00, '2026-03-14 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 901.00, '2026-03-14 10:14:00-06'),
    ('ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m', 992.00, '2026-03-14 10:14:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'M azul', 275.00, '2026-03-15 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Uniforme de entrenamiento Cantera', 'M azul', 281.00, '2026-03-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Uniforme de entrenamiento Cantera', 'M azul', 290.00, '2026-03-15 10:07:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'L azul', 292.00, '2026-03-15 10:07:00-06'),
    ('ventas.sur@mesh.com', 'Uniforme de entrenamiento Cantera', 'L azul', 298.00, '2026-03-15 10:07:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 292.00, '2026-03-15 10:07:00-06'),
    ('ventas.oriente@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 311.00, '2026-03-15 10:07:00-06'),
    ('ventas.poniente@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 312.00, '2026-03-15 10:07:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 690.00, '2026-03-16 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Casco de ruta Aerodino', 'M blanco', 725.00, '2026-03-16 10:04:00-06'),
    ('tienda@mesh.com', 'Casco de ruta Aerodino', 'L negro', 690.00, '2026-03-16 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Casco de ruta Aerodino', 'L negro', 692.00, '2026-03-16 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Casco de ruta Aerodino', 'L negro', 733.00, '2026-03-16 10:04:00-06'),
    ('tienda@mesh.com', 'Bomba de piso Piston', 'Estandar', 310.00, '2026-03-17 10:22:00-06'),
    ('ventas.sur@mesh.com', 'Bomba de piso Piston', 'Estandar', 311.00, '2026-03-17 10:22:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'S negro', 210.00, '2026-03-18 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Guantes de ciclismo Palma Corta', 'S negro', 206.00, '2026-03-18 10:15:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 221.00, '2026-03-18 10:15:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 234.00, '2026-03-18 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 212.00, '2026-03-18 10:15:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 221.00, '2026-03-18 10:15:00-06'),
    ('ventas.oriente@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 219.00, '2026-03-18 10:15:00-06'),
    ('ventas.poniente@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 226.00, '2026-03-18 10:15:00-06'),
    ('tienda@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 540.00, '2026-03-19 10:19:00-06'),
    ('ventas.sur@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 525.00, '2026-03-19 10:19:00-06'),
    ('tienda@mesh.com', 'Sillin de ruta Vertebra SR-2', '155 mm', 583.00, '2026-03-19 10:19:00-06'),
    ('ventas.poniente@mesh.com', 'Sillin de ruta Vertebra SR-2', '155 mm', 618.00, '2026-03-19 10:19:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'M naranja', 460.00, '2026-03-20 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Maillot de ruta Peloton', 'M naranja', 425.00, '2026-03-20 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Maillot de ruta Peloton', 'M naranja', 466.00, '2026-03-20 10:20:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 488.00, '2026-03-20 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 474.00, '2026-03-20 10:20:00-06'),
    ('ventas.poniente@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 457.00, '2026-03-20 10:20:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'L azul', 488.00, '2026-03-20 10:20:00-06'),
    ('ventas.norte@mesh.com', 'Maillot de ruta Peloton', 'L azul', 493.00, '2026-03-20 10:20:00-06'),
    ('tienda@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 630.00, '2026-03-21 10:10:00-06'),
    ('ventas.norte@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 604.00, '2026-03-21 10:10:00-06'),
    ('ventas.oriente@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 653.00, '2026-03-21 10:10:00-06'),
    ('ventas.poniente@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar', 632.00, '2026-03-21 10:10:00-06'),
    ('tienda@mesh.com', 'Set de bandas elasticas', 'Set completo', 195.00, '2026-03-22 10:04:00-06'),
    ('ventas.norte@mesh.com', 'Set de bandas elasticas', 'Set completo', 191.00, '2026-03-22 10:04:00-06'),
    ('ventas.sur@mesh.com', 'Set de bandas elasticas', 'Set completo', 188.00, '2026-03-22 10:04:00-06'),
    ('ventas.oriente@mesh.com', 'Set de bandas elasticas', 'Set completo', 199.00, '2026-03-22 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Set de bandas elasticas', 'Set completo', 193.00, '2026-03-22 10:04:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 380.00, '2026-03-23 10:35:00-06'),
    ('ventas.norte@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Verde', 371.00, '2026-03-23 10:35:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 380.00, '2026-03-23 10:35:00-06'),
    ('ventas.poniente@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 373.00, '2026-03-23 10:35:00-06'),
    ('tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1180.00, '2026-03-24 10:18:00-06'),
    ('ventas.norte@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1256.00, '2026-03-24 10:18:00-06'),
    ('tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 1628.00, '2026-03-24 10:18:00-06'),
    ('ventas.poniente@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg', 1673.00, '2026-03-24 10:18:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '12 kg', 430.00, '2026-03-25 10:54:00-06'),
    ('ventas.poniente@mesh.com', 'Pesa rusa Yunque', '12 kg', 426.00, '2026-03-25 10:54:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '16 kg', 550.00, '2026-03-25 10:54:00-06'),
    ('ventas.norte@mesh.com', 'Pesa rusa Yunque', '16 kg', 577.00, '2026-03-25 10:54:00-06'),
    ('ventas.sur@mesh.com', 'Pesa rusa Yunque', '16 kg', 538.00, '2026-03-25 10:54:00-06'),
    ('ventas.oriente@mesh.com', 'Pesa rusa Yunque', '16 kg', 591.00, '2026-03-25 10:54:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '20 kg', 667.00, '2026-03-25 10:54:00-06'),
    ('ventas.poniente@mesh.com', 'Pesa rusa Yunque', '20 kg', 665.00, '2026-03-25 10:54:00-06'),
    ('tienda@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 125.00, '2026-03-26 10:05:00-06'),
    ('ventas.sur@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 122.00, '2026-03-26 10:05:00-06'),
    ('ventas.poniente@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 120.00, '2026-03-26 10:05:00-06'),
    ('tienda@mesh.com', 'Rodillo de liberacion Nudo', '33 cm', 210.00, '2026-03-27 10:47:00-06'),
    ('ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '33 cm', 214.00, '2026-03-27 10:47:00-06'),
    ('tienda@mesh.com', 'Rodillo de liberacion Nudo', '45 cm', 273.00, '2026-03-27 10:47:00-06'),
    ('ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '45 cm', 295.00, '2026-03-27 10:47:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta blanda', 180.00, '2026-05-20 09:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta blanda', 169.00, '2026-05-20 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta blanda', 183.00, '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta blanda', 175.00, '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta dura', 279.00, '2026-05-20 09:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta dura', 274.00, '2026-05-20 09:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta dura', 280.00, '2026-05-20 09:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta dura', 301.00, '2026-05-20 09:00:00-06'),
    ('tienda@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 145.00, '2026-04-01 10:23:00-06'),
    ('ventas.sur@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda', 153.00, '2026-04-01 10:23:00-06'),
    ('tienda@mesh.com', 'La casa de los relojes detenidos', 'Pasta blanda', 195.00, '2026-04-02 10:31:00-06'),
    ('ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 'Pasta blanda', 204.00, '2026-04-02 10:31:00-06'),
    ('tienda@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 289.00, '2026-04-02 10:31:00-06'),
    ('ventas.norte@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 303.00, '2026-04-02 10:31:00-06'),
    ('ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 310.00, '2026-04-02 10:31:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Digital', 95.00, '2026-04-03 10:25:00-06'),
    ('ventas.norte@mesh.com', 'Cartas al puerto seco', 'Digital', 99.00, '2026-04-03 10:25:00-06'),
    ('ventas.sur@mesh.com', 'Cartas al puerto seco', 'Digital', 96.00, '2026-04-03 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Cartas al puerto seco', 'Digital', 88.00, '2026-04-03 10:25:00-06'),
    ('ventas.poniente@mesh.com', 'Cartas al puerto seco', 'Digital', 94.00, '2026-04-03 10:25:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Pasta blanda', 135.00, '2026-04-03 10:25:00-06'),
    ('ventas.oriente@mesh.com', 'Cartas al puerto seco', 'Pasta blanda', 140.00, '2026-04-03 10:25:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Pasta dura', 179.00, '2026-04-03 10:25:00-06'),
    ('tienda@mesh.com', 'Nadie duerme en Tecpanal', 'Pasta dura', 210.00, '2026-04-04 10:20:00-06'),
    ('ventas.sur@mesh.com', 'Nadie duerme en Tecpanal', 'Pasta dura', 219.00, '2026-04-04 10:20:00-06'),
    ('ventas.oriente@mesh.com', 'Nadie duerme en Tecpanal', 'Pasta dura', 195.00, '2026-04-04 10:20:00-06'),
    ('tienda@mesh.com', 'Antologia del ruido', 'Pasta blanda', 135.00, '2026-04-05 10:23:00-06'),
    ('ventas.norte@mesh.com', 'Antologia del ruido', 'Pasta blanda', 132.00, '2026-04-05 10:23:00-06'),
    ('ventas.sur@mesh.com', 'Antologia del ruido', 'Pasta blanda', 133.00, '2026-04-05 10:23:00-06'),
    ('tienda@mesh.com', 'Antologia del ruido', 'Edicion ilustrada', 219.00, '2026-04-05 10:23:00-06'),
    ('ventas.sur@mesh.com', 'Antologia del ruido', 'Edicion ilustrada', 208.00, '2026-04-05 10:23:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 620.00, '2026-04-06 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 608.00, '2026-04-06 10:52:00-06'),
    ('ventas.oriente@mesh.com', 'Bases de datos distribuidas', 'Pasta dura', 615.00, '2026-04-06 10:52:00-06'),
    ('tienda@mesh.com', 'Bases de datos distribuidas', 'Digital', 341.00, '2026-04-06 10:52:00-06'),
    ('ventas.norte@mesh.com', 'Bases de datos distribuidas', 'Digital', 325.00, '2026-04-06 10:52:00-06'),
    ('tienda@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 580.00, '2026-04-07 10:34:00-06'),
    ('ventas.norte@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 562.00, '2026-04-07 10:34:00-06'),
    ('ventas.sur@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 587.00, '2026-04-07 10:34:00-06'),
    ('ventas.poniente@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 569.00, '2026-04-07 10:34:00-06'),
    ('tienda@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 777.00, '2026-04-07 10:34:00-06'),
    ('ventas.norte@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 733.00, '2026-04-07 10:34:00-06'),
    ('ventas.oriente@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 785.00, '2026-04-07 10:34:00-06'),
    ('tienda@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 495.00, '2026-04-08 10:45:00-06'),
    ('ventas.oriente@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 514.00, '2026-04-08 10:45:00-06'),
    ('ventas.poniente@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 509.00, '2026-04-08 10:45:00-06'),
    ('tienda@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta blanda', 340.00, '2026-04-09 10:03:00-06'),
    ('ventas.sur@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta blanda', 322.00, '2026-04-09 10:03:00-06'),
    ('tienda@mesh.com', 'Manual de instalaciones electricas residenciales', 'Espiral', 401.00, '2026-04-09 10:03:00-06'),
    ('ventas.oriente@mesh.com', 'Manual de instalaciones electricas residenciales', 'Espiral', 377.00, '2026-04-09 10:03:00-06'),
    ('tienda@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta dura', 527.00, '2026-04-09 10:03:00-06'),
    ('tienda@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura', 650.00, '2026-04-10 10:07:00-06'),
    ('ventas.oriente@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura', 667.00, '2026-04-10 10:07:00-06'),
    ('tienda@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 793.00, '2026-04-10 10:07:00-06'),
    ('ventas.norte@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 813.00, '2026-04-10 10:07:00-06'),
    ('ventas.oriente@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 793.00, '2026-04-10 10:07:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '30 ml', 210.00, '2026-04-11 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Serum de niacinamida 10%', '30 ml', 212.00, '2026-04-11 10:30:00-06'),
    ('ventas.oriente@mesh.com', 'Serum de niacinamida 10%', '30 ml', 226.00, '2026-04-11 10:30:00-06'),
    ('tienda@mesh.com', 'Serum de niacinamida 10%', '50 ml', 311.00, '2026-04-11 10:30:00-06'),
    ('ventas.sur@mesh.com', 'Serum de niacinamida 10%', '50 ml', 324.00, '2026-04-11 10:30:00-06'),
    ('ventas.oriente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 289.00, '2026-04-11 10:30:00-06'),
    ('ventas.poniente@mesh.com', 'Serum de niacinamida 10%', '50 ml', 328.00, '2026-04-11 10:30:00-06'),
    ('tienda@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 265.00, '2026-04-12 10:17:00-06'),
    ('ventas.sur@mesh.com', 'Protector solar mineral FPS 50', '50 ml', 255.00, '2026-04-12 10:17:00-06'),
    ('tienda@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 320.00, '2026-04-13 10:50:00-06'),
    ('ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 307.00, '2026-04-13 10:50:00-06'),
    ('ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 346.00, '2026-04-13 10:50:00-06'),
    ('tienda@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 496.00, '2026-04-13 10:50:00-06'),
    ('ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 518.00, '2026-04-13 10:50:00-06'),
    ('ventas.sur@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 498.00, '2026-04-13 10:50:00-06'),
    ('ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 500.00, '2026-04-13 10:50:00-06'),
    ('ventas.poniente@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 529.00, '2026-04-13 10:50:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '150 ml', 145.00, '2026-04-14 10:18:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '250 ml', 196.00, '2026-04-14 10:18:00-06'),
    ('ventas.oriente@mesh.com', 'Limpiador en gel Verdo', '250 ml', 202.00, '2026-04-14 10:18:00-06'),
    ('ventas.poniente@mesh.com', 'Limpiador en gel Verdo', '250 ml', 209.00, '2026-04-14 10:18:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '400 ml', 249.00, '2026-04-14 10:18:00-06'),
    ('ventas.norte@mesh.com', 'Limpiador en gel Verdo', '400 ml', 249.00, '2026-04-14 10:18:00-06'),
    ('ventas.sur@mesh.com', 'Limpiador en gel Verdo', '400 ml', 264.00, '2026-04-14 10:18:00-06'),
    ('ventas.oriente@mesh.com', 'Limpiador en gel Verdo', '400 ml', 268.00, '2026-04-14 10:18:00-06'),
    ('ventas.poniente@mesh.com', 'Limpiador en gel Verdo', '400 ml', 235.00, '2026-04-14 10:18:00-06'),
    ('tienda@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 235.00, '2026-04-15 10:09:00-06'),
    ('ventas.norte@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 234.00, '2026-04-15 10:09:00-06'),
    ('ventas.poniente@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 246.00, '2026-04-15 10:09:00-06'),
    ('tienda@mesh.com', 'Contorno de ojos Lumine', '15 ml', 280.00, '2026-04-16 10:27:00-06'),
    ('ventas.oriente@mesh.com', 'Contorno de ojos Lumine', '15 ml', 293.00, '2026-04-16 10:27:00-06'),
    ('tienda@mesh.com', 'Contorno de ojos Lumine', '30 ml', 406.00, '2026-04-16 10:27:00-06'),
    ('ventas.norte@mesh.com', 'Contorno de ojos Lumine', '30 ml', 410.00, '2026-04-16 10:27:00-06'),
    ('ventas.poniente@mesh.com', 'Contorno de ojos Lumine', '30 ml', 423.00, '2026-04-16 10:27:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '50 ml', 720.00, '2026-04-17 10:24:00-06'),
    ('ventas.oriente@mesh.com', 'Eau de parfum Bruma', '50 ml', 761.00, '2026-04-17 10:24:00-06'),
    ('tienda@mesh.com', 'Eau de parfum Bruma', '100 ml', 1166.00, '2026-04-17 10:24:00-06'),
    ('ventas.norte@mesh.com', 'Eau de parfum Bruma', '100 ml', 1081.00, '2026-04-17 10:24:00-06'),
    ('ventas.sur@mesh.com', 'Eau de parfum Bruma', '100 ml', 1232.00, '2026-04-17 10:24:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '30 ml', 480.00, '2026-04-18 10:04:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '60 ml', 710.00, '2026-04-18 10:04:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '100 ml', 888.00, '2026-04-18 10:04:00-06'),
    ('ventas.poniente@mesh.com', 'Eau de toilette Salino', '100 ml', 896.00, '2026-04-18 10:04:00-06'),
    ('tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 290.00, '2026-04-19 10:57:00-06'),
    ('ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 297.00, '2026-04-19 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 298.00, '2026-04-19 10:57:00-06'),
    ('ventas.poniente@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 296.00, '2026-04-19 10:57:00-06'),
    ('tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 487.00, '2026-04-19 10:57:00-06'),
    ('ventas.sur@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 456.00, '2026-04-19 10:57:00-06'),
    ('ventas.oriente@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 489.00, '2026-04-19 10:57:00-06'),
    ('tienda@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 165.00, '2026-04-20 10:14:00-06'),
    ('ventas.norte@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 161.00, '2026-04-20 10:14:00-06'),
    ('ventas.poniente@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 159.00, '2026-04-20 10:14:00-06'),
    ('tienda@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 390.00, '2026-04-21 10:48:00-06'),
    ('ventas.norte@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 385.00, '2026-04-21 10:48:00-06'),
    ('ventas.oriente@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 378.00, '2026-04-21 10:48:00-06'),
    ('tienda@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion dia', 437.00, '2026-04-21 10:48:00-06'),
    ('tienda@mesh.com', 'Laptop Aurora 14', '16 GB / 512 GB', 6627.00, '2026-03-02 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8114.00, '2026-03-06 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 8998.00, '2026-03-24 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB', 9897.00, '2026-05-12 12:00:00-06'),
    ('tienda@mesh.com', 'Laptop Bastion 16', '32 GB / 1 TB', 10052.00, '2026-03-01 12:00:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 1 TB', 5744.00, '2026-03-20 12:00:00-06'),
    ('tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 1 TB', 6053.00, '2026-05-12 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 6509.00, '2026-03-10 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 9043.00, '2026-03-03 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Lienzo 15', '32 GB / 1 TB', 9503.00, '2026-05-07 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3598.00, '2026-03-19 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3845.00, '2026-05-23 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 3734.00, '2026-03-08 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '8 GB / 256 GB', 4269.00, '2026-03-26 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6543.00, '2026-03-03 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 5840.00, '2026-05-01 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 5551.00, '2026-03-17 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Laptop Ambar Campus 14', '16 GB / 512 GB', 6263.00, '2026-05-16 12:00:00-06'),
    ('tienda@mesh.com', 'Telefono Vela 7', '256 GB', 5692.00, '2026-03-17 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2201.00, '2026-03-07 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Telefono Ceibo Lite', '128 GB', 2362.00, '2026-05-14 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Telefono Nautilo Pro', '256 GB', 7933.00, '2026-03-16 12:00:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '512 GB', 9562.00, '2026-03-03 12:00:00-06'),
    ('tienda@mesh.com', 'Telefono Nautilo Pro', '512 GB', 8560.00, '2026-05-13 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Nautilo Pro', '1 TB', 11793.00, '2026-03-17 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Telefono Nautilo Pro', '1 TB', 13268.00, '2026-05-05 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 736.00, '2026-03-12 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Verde lima', 680.00, '2026-05-13 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 687.00, '2026-03-18 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Audifonos Brisa Sport', 'Gris', 644.00, '2026-05-05 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Brisa Sport', 'Gris', 606.00, '2026-03-25 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Audifonos Brisa Sport', 'Gris', 652.00, '2026-05-17 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Colibri Micro TWS', 'Negro mate', 1131.00, '2026-03-10 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m', 3140.00, '2026-03-04 12:00:00-06'),
    ('tienda@mesh.com', 'Audifonos Duna Trabajo', 'Grafito', 1556.00, '2026-03-15 12:00:00-06'),
    ('tienda@mesh.com', 'Audifonos Zumbo Cable', 'Cable 1.2 m', 232.00, '2026-03-01 12:00:00-06'),
    ('tienda@mesh.com', 'Audifonos Zumbo Cable', 'Cable 1.2 m', 210.00, '2026-05-16 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Monitor Panorama 34', '100 Hz', 6312.00, '2026-03-07 12:00:00-06'),
    ('tienda@mesh.com', 'Monitor Vitral 24', '100 Hz', 2149.00, '2026-03-25 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '144 Hz', 3384.00, '2026-03-11 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '144 Hz', 3672.00, '2026-05-27 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '180 Hz', 4161.00, '2026-03-20 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Monitor Vertice 27 Gamer', '180 Hz', 3805.00, '2026-05-21 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz', 4507.00, '2026-03-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Monitor Nube 22', 'Blanco', 1268.00, '2026-04-06 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Cafetera Alba Espresso', '2.5 L', 2944.00, '2026-04-05 12:00:00-06'),
    ('tienda@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1080.00, '2026-04-23 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Juego de ollas Fuego 5 piezas', 'Estandar', 1112.00, '2026-04-02 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 822.00, '2026-04-04 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Licuadora Torbellino 1200', '1.5 L', 772.00, '2026-06-26 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Hervidor electrico Vapor 1.7', 'Negro mate', 367.00, '2026-04-12 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Hervidor electrico Vapor 1.7', 'Negro mate', 401.00, '2026-06-22 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L', 547.00, '2026-04-19 12:00:00-06'),
    ('tienda@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 750.00, '2026-04-17 12:00:00-06'),
    ('tienda@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L', 800.00, '2026-06-03 12:00:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Nogal', 2121.00, '2026-04-18 12:00:00-06'),
    ('tienda@mesh.com', 'Escritorio Roble 120', 'Nogal', 1893.00, '2026-06-06 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3555.00, '2026-04-14 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Silla ergonomica Vertebra', 'Negra', 3721.00, '2026-06-03 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1710.00, '2026-04-19 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Librero Hoja 5 niveles', '5 niveles roble', 1591.00, '2026-06-09 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Mesa de centro Guijarro', 'Natural', 861.00, '2026-04-12 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Mesa de centro Guijarro', 'Natural', 1086.00, '2026-04-17 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Mesa de centro Guijarro', 'Natural', 1161.00, '2026-06-10 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Natural', 387.00, '2026-04-06 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Natural', 370.00, '2026-06-03 12:00:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Negra', 513.00, '2026-04-15 12:00:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Negra', 456.00, '2026-06-24 12:00:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 500.00, '2026-04-13 12:00:00-06'),
    ('tienda@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 475.00, '2026-06-18 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Tapizada gris', 498.00, '2026-04-06 12:00:00-06'),
    ('tienda@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1713.00, '2026-04-15 12:00:00-06'),
    ('tienda@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1920.00, '2026-06-19 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Comoda Sendero 4 gavetas', '4 gavetas', 1645.00, '2026-04-14 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 483.00, '2026-04-08 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de escritorio Faro', 'Blanca', 482.00, '2026-04-07 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 308.00, '2026-04-20 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Tira LED Aurora 5 m', 'Multicolor', 323.00, '2026-06-23 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1220.00, '2026-04-09 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1114.00, '2026-06-13 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1154.00, '2026-04-16 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Lampara de pie Vigia 165', 'Negro', 1269.00, '2026-06-26 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Laton cepillado', 1579.00, '2026-04-14 12:00:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Negro mate', 191.00, '2026-04-04 12:00:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Negro mate', 203.00, '2026-06-16 12:00:00-06'),
    ('tienda@mesh.com', 'Farol solar de jardin Luciernaga', 'Cobre envejecido', 251.00, '2026-04-06 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'S azul', 358.00, '2026-03-02 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa de lino manga larga', 'S azul', 327.00, '2026-05-22 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa oxford clasica', 'M celeste', 327.00, '2026-04-25 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa oxford clasica', 'M celeste', 330.00, '2026-04-18 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Camisa oxford clasica', 'M celeste', 314.00, '2026-06-23 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso', 479.00, '2026-04-21 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso', 431.00, '2026-06-15 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 331.00, '2026-04-12 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de vestir Meridiano', 'M blanca', 316.00, '2026-06-02 12:00:00-06'),
    ('tienda@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 456.00, '2026-04-02 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 404.00, '2026-04-15 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Camisa de mezclilla Remache', 'M azul indigo', 448.00, '2026-06-14 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro', 502.00, '2026-04-26 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro', 528.00, '2026-06-20 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon chino resistente', '32 beige', 372.00, '2026-04-10 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '32 beige', 485.00, '2026-04-20 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon chino resistente', '34 azul', 384.00, '2026-04-16 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 500.00, '2026-04-23 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 441.00, '2026-04-24 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '32 indigo crudo', 492.00, '2026-06-08 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva', 530.00, '2026-05-13 12:00:00-06'),
    ('tienda@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva', 596.00, '2026-07-03 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Zapato de cuero Senda', '42 negro', 645.00, '2026-05-17 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de cuero Senda', '42 negro', 707.00, '2026-05-26 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Bota impermeable Cumbre', '41', 1073.00, '2026-05-16 12:00:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '43', 1213.00, '2026-05-16 12:00:00-06'),
    ('tienda@mesh.com', 'Bota impermeable Cumbre', '43', 1303.00, '2026-07-02 12:00:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 592.00, '2026-05-02 12:00:00-06'),
    ('tienda@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 531.00, '2026-07-17 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Tenis urbano Vereda 90', '39 blanco', 725.00, '2026-05-01 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Tenis urbano Vereda 90', '41 blanco', 578.00, '2026-05-06 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 977.00, '2026-05-15 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 821.00, '2026-05-03 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Mocasin de gamuza Roble', '40 azul', 903.00, '2026-07-02 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 949.00, '2026-05-27 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Mocasin de gamuza Roble', '42 arena', 1041.00, '2026-07-04 12:00:00-06'),
    ('tienda@mesh.com', 'Bota de trabajo Yunque S3', '40 negro', 1471.00, '2026-05-06 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Bota de trabajo Yunque S3', '44 miel', 1620.00, '2026-05-20 12:00:00-06'),
    ('tienda@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 438.00, '2026-05-09 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 464.00, '2026-05-02 12:00:00-06'),
    ('tienda@mesh.com', 'Balon de futbol numero 5', 'Blanco', 228.00, '2026-06-19 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Balon de futbol numero 5', 'Naranja', 264.00, '2026-06-24 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'M', 129.00, '2026-05-03 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Espinilleras Muralla', 'M', 139.00, '2026-07-12 12:00:00-06'),
    ('tienda@mesh.com', 'Espinilleras Muralla', 'L', 156.00, '2026-05-12 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de portero Zarpa 300', 'Talla 8', 333.00, '2026-05-04 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '40 negro', 667.00, '2026-05-18 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 618.00, '2026-05-25 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Zapato de tacos Relampago FG', '42 negro', 567.00, '2026-07-10 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Zapato de tacos Relampago FG', '42 rojo', 851.00, '2026-05-21 12:00:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 276.00, '2026-05-04 12:00:00-06'),
    ('tienda@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde', 241.00, '2026-07-27 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 222.00, '2026-05-14 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Guantes de ciclismo Palma Corta', 'M negro', 213.00, '2026-07-23 12:00:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 211.00, '2026-05-12 12:00:00-06'),
    ('tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'L gris', 187.00, '2026-07-26 12:00:00-06'),
    ('tienda@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 501.00, '2026-05-16 12:00:00-06'),
    ('tienda@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 441.00, '2026-07-25 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Sillin de ruta Vertebra SR-2', '143 mm', 477.00, '2026-05-17 12:00:00-06'),
    ('tienda@mesh.com', 'Maillot de ruta Peloton', 'L naranja', 452.00, '2026-05-27 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Set de bandas elasticas', 'Set completo', 197.00, '2026-05-19 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Set de bandas elasticas', 'Set completo', 208.00, '2026-05-16 12:00:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 406.00, '2026-05-07 12:00:00-06'),
    ('tienda@mesh.com', 'Tapete de yoga Raiz 6 mm', 'Morado', 365.00, '2026-07-09 12:00:00-06'),
    ('tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1049.00, '2026-05-11 12:00:00-06'),
    ('tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg', 1145.00, '2026-07-16 12:00:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '12 kg', 474.00, '2026-05-19 12:00:00-06'),
    ('tienda@mesh.com', 'Pesa rusa Yunque', '12 kg', 437.00, '2026-07-16 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Pesa rusa Yunque', '16 kg', 517.00, '2026-05-10 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Pesa rusa Yunque', '16 kg', 528.00, '2026-05-21 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Pesa rusa Yunque', '16 kg', 570.00, '2026-07-26 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Pesa rusa Yunque', '20 kg', 692.00, '2026-05-22 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 111.00, '2026-05-14 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 118.00, '2026-07-05 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 131.00, '2026-05-07 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 148.00, '2026-07-09 12:00:00-06'),
    ('tienda@mesh.com', 'Rodillo de liberacion Nudo', '33 cm', 185.00, '2026-05-05 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '33 cm', 194.00, '2026-05-02 12:00:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta dura', 253.00, '2026-07-09 12:00:00-06'),
    ('tienda@mesh.com', 'El camino de las nubes', 'Pasta dura', 273.00, '2026-08-21 12:00:00-06'),
    ('ventas.sur@mesh.com', 'El camino de las nubes', 'Pasta dura', 243.00, '2026-07-23 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta dura', 256.00, '2026-07-01 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'El camino de las nubes', 'Pasta dura', 242.00, '2026-08-18 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta dura', 335.00, '2026-07-14 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'El camino de las nubes', 'Pasta dura', 305.00, '2026-08-15 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 'Pasta dura', 279.00, '2026-06-17 12:00:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Digital', 106.00, '2026-06-10 12:00:00-06'),
    ('tienda@mesh.com', 'Cartas al puerto seco', 'Digital', 92.00, '2026-08-06 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cartas al puerto seco', 'Digital', 103.00, '2026-06-08 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Cartas al puerto seco', 'Digital', 93.00, '2026-08-18 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Antologia del ruido', 'Edicion ilustrada', 190.00, '2026-06-22 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Bases de datos distribuidas', 'Digital', 289.00, '2026-06-20 12:00:00-06'),
    ('ventas.sur@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 649.00, '2026-06-17 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Redes industriales y buses de campo', 'Pasta blanda', 536.00, '2026-06-25 12:00:00-06'),
    ('tienda@mesh.com', 'Redes industriales y buses de campo', 'Pasta dura', 692.00, '2026-06-13 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 569.00, '2026-06-23 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Calculo numerico con ejercicios resueltos', 'Pasta blanda', 519.00, '2026-08-27 12:00:00-06'),
    ('tienda@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura', 623.00, '2026-06-06 12:00:00-06'),
    ('tienda@mesh.com', 'Introduccion al modelado de sistemas embebidos', 'Pasta dura con acceso digital', 895.00, '2026-06-26 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 343.00, '2026-06-16 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 383.00, '2026-06-24 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 414.00, '2026-08-14 12:00:00-06'),
    ('tienda@mesh.com', 'Crema hidratante nocturna Alba', '100 ml', 466.00, '2026-06-04 12:00:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '150 ml', 155.00, '2026-06-21 12:00:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '150 ml', 136.00, '2026-08-03 12:00:00-06'),
    ('tienda@mesh.com', 'Limpiador en gel Verdo', '250 ml', 187.00, '2026-06-23 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Limpiador en gel Verdo', '250 ml', 195.00, '2026-06-08 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 262.00, '2026-06-25 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Exfoliante enzimatico Papilo', '75 ml', 296.00, '2026-08-21 12:00:00-06'),
    ('tienda@mesh.com', 'Contorno de ojos Lumine', '15 ml', 266.00, '2026-06-17 12:00:00-06'),
    ('ventas.oriente@mesh.com', 'Contorno de ojos Lumine', '15 ml', 277.00, '2026-06-06 12:00:00-06'),
    ('tienda@mesh.com', 'Contorno de ojos Lumine', '30 ml', 431.00, '2026-06-14 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Contorno de ojos Lumine', '30 ml', 377.00, '2026-06-10 12:00:00-06'),
    ('ventas.norte@mesh.com', 'Contorno de ojos Lumine', '30 ml', 417.00, '2026-08-14 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Contorno de ojos Lumine', '30 ml', 384.00, '2026-06-10 12:00:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '60 ml', 664.00, '2026-06-15 12:00:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '60 ml', 702.00, '2026-08-17 12:00:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '100 ml', 825.00, '2026-06-06 12:00:00-06'),
    ('tienda@mesh.com', 'Eau de toilette Salino', '100 ml', 720.00, '2026-08-22 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 311.00, '2026-06-08 12:00:00-06'),
    ('ventas.poniente@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml', 274.00, '2026-08-08 12:00:00-06'),
    ('tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 452.00, '2026-06-24 12:00:00-06'),
    ('tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '200 ml', 504.00, '2026-08-01 12:00:00-06'),
    ('tienda@mesh.com', 'Bruma corporal Trebol Blanco', '200 ml', 183.00, '2026-06-03 12:00:00-06')
) AS v(correo, producto, variante, precio, fecha)
JOIN usuarios            u  ON u.correo_electronico = v.correo
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
JOIN oferta              o  ON o.id_producto_mongo = p.id_producto
                            AND o.id_producto_variante_mongo = pv.id_producto_variante
                            AND o.id_usuario = u.id_usuario;

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
--
-- Estos dos son los del camino de tres llamadas -- crear_pedido,
-- agregar_linea, comprar_pedido -- y se quedan justamente por eso: son los
-- unicos que lo recorren. Las compras que respaldan las resenas van mas
-- abajo y usan comprar_carrito, que es el camino de una sola.

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
        JOIN productos_variantes pv ON pv.id_producto = o.id_producto_mongo
                                     AND pv.id_producto_variante = o.id_producto_variante_mongo
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
    JOIN productos_variantes pv ON pv.id_producto = o.id_producto_mongo
                                 AND pv.id_producto_variante = o.id_producto_variante_mongo
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
-- Las compras que respaldan las resenas: 8 pedidos, 94 lineas
-- ============================================================
-- El backend solo deja calificar a un vendedor al que se le compro y se le
-- pago ESE producto. Sin estas compras, las resenas de mas abajo serian
-- filas que el propio sistema no habria dejado escribir, y el boton de
-- "Escribir una resena" no apareceria en ninguna ficha.
--
-- Se compra con comprar_carrito() -- la de la 012 -- y no con INSERT: ella
-- compone crear_pedido, agregar_linea y comprar_pedido, congela el
-- id_precio_historial correcto y arma el nombre del vendedor desde la base.
-- Un INSERT a mano tendria que copiar las tres reglas y quedaria libre de
-- desviarse de ellas sin que nada avise.
--
-- LAS FECHAS, que es la parte que muerde: crear_pedido no recibe fecha y
-- pedido.fecha_creacion es DEFAULT now(), asi que la compra saldria HOY y la
-- resena en abril. Resenada antes de comprada, sin que nada falle. Por eso
-- se compra primero y despues se corrigen las tres fechas que la compra
-- escribio con now(): la del pedido, la del pago y la del kardex. Se puede
-- hacer con un UPDATE pelado porque ninguna de las tres tablas tiene
-- trigger encima.

DO $compras$
DECLARE
    v_grupo    record;
    v_usuario  bigint;
    v_dir      bigint;
    v_pedido   bigint;
BEGIN
    -- Las lineas llegan sueltas y se agrupan aqui en el arreglo que pide
    -- comprar_carrito. El id_oferta se resuelve en este mismo SELECT, contra
    -- correo y nombre: ningun id va escrito.
    FOR v_grupo IN
        SELECT t.comprador, t.fecha, t.metodo,
               jsonb_agg(jsonb_build_object(
                   'id_oferta',            o.id_oferta,
                   'cantidad',             1,
                   'id_producto',          p.id_producto,
                   'id_producto_variante', pv.id_producto_variante,
                   'nombre_producto',      p.nombre,
                   'nombre_variante',      pv.nombre_variante
               ) ORDER BY o.id_oferta) AS lineas
        FROM (VALUES
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Escritorio Roble 120', 'Natural'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Silla de comedor Vara', 'Negra'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Lampara de escritorio Faro', 'Negra'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Cacerola honda Comal 18', '16 cm'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 'Negro'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.sur@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Escritorio Roble 120', 'Nogal'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Cafetera Alba Espresso', '1.5 L'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Camisa de mezclilla Remache', 'L azul claro'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.sur@mesh.com', 'Cacerola honda Comal 18', '20 cm'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Pantalon chino resistente', '34 azul'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Olla arrocera Grano 8 tazas', '2.8 L'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton'),
            ('compradora.norte@mesh.com', '2026-02-28 18:00:00-06', 'tarjeta', 'ventas.oriente@mesh.com', 'Silla ergonomica Vertebra', 'Negra'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Monitor Panorama 34', '100 Hz'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', '100 Hz'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Camisa de lino manga larga', 'M azul'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Monitor Cenit 32 4K', '60 Hz'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'ventas.sur@mesh.com', 'Audifonos Colibri Micro TWS', 'Blanco perla'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Laptop Lienzo 15', '16 GB / 512 GB'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Telefono Ceibo Lite', '128 GB'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', '100 Hz'),
            ('compradora.norte@mesh.com', '2026-01-28 18:00:00-06', 'transferencia', 'ventas.poniente@mesh.com', 'Audifonos Marea Diadema Abierta', 'Cable 2 m'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', '100 Hz'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'ventas.poniente@mesh.com', 'Laptop Cumbre 17 Gamer', '32 GB / 1 TB'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Laptop Aurora 14', '32 GB / 1 TB'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Laptop Bastion 16', '64 GB / 2 TB'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', '240 Hz'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'ventas.sur@mesh.com', 'Monitor Vitral 24', '100 Hz'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Monitor Panorama 34', '100 Hz'),
            ('comprador.sur@mesh.com', '2026-01-28 18:00:00-06', 'efectivo contra entrega', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', '100 Hz'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 'Pasta blanda'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', '100 ml'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', '100 ml'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Serum de niacinamida 10%', '50 ml'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.oriente@mesh.com', 'Eau de parfum Bruma', '50 ml'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', 'Blanco'),
            ('compradora.norte@mesh.com', '2026-04-28 18:00:00-06', 'tarjeta', 'ventas.sur@mesh.com', 'Serum de niacinamida 10%', '30 ml'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Zapato de tacos Relampago FG', '40 negro'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 30 kg'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.poniente@mesh.com', 'Uniforme de entrenamiento Cantera', 'L verde'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Casco de ruta Aerodino', 'L negro'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Espinilleras Muralla', 'M'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Bota de trabajo Yunque S3', '42 negro'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.sur@mesh.com', 'Casco de ruta Aerodino', 'M blanco'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.poniente@mesh.com', 'Pantalon cargo Vereda', '32 verde oliva'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Pesa rusa Yunque', '20 kg'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '45 cm'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Pantalon jogger Ocaso', 'L negro'),
            ('comprador.sur@mesh.com', '2026-03-28 18:00:00-06', 'transferencia', 'ventas.poniente@mesh.com', 'Bota de trabajo Yunque S3', '42 negro'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', '34 negro'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 'Nogal y laton'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 'XL hueso'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.sur@mesh.com', 'Olla arrocera Grano 8 tazas', '1.5 L'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Camisa oxford clasica', 'L celeste'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Silla de comedor Vara', 'Natural'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Lampara de pie Vigia 165', 'Negro'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.sur@mesh.com', 'Silla de comedor Vara', 'Negra'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Escritorio Roble 120', 'Natural'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', '6 gavetas'),
            ('comprador.sur@mesh.com', '2026-02-28 18:00:00-06', 'efectivo contra entrega', 'ventas.poniente@mesh.com', 'Plafon LED Solaz 24', 'Blanco 24 W'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', '45 cm'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Pantalon cargo Vereda', '36 negro'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 'S negro'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Pantalon jogger Ocaso', 'M gris jaspe'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Zapato de tacos Relampago FG', '42 negro'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'tienda@mesh.com', 'Candado plegable Cerrojo F8', 'Estandar'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Par de 20 kg'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 'Par 7 x 2 m'),
            ('compradora.norte@mesh.com', '2026-03-28 18:00:00-06', 'tarjeta', 'ventas.poniente@mesh.com', 'Maillot de ruta Peloton', 'L naranja'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.oriente@mesh.com', 'Eau de parfum Bruma', '50 ml'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', 'Blanco'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'La casa de los relojes detenidos', 'Pasta blanda'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.oriente@mesh.com', 'Bases de datos distribuidas', 'Pasta dura'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Balon de futbol numero 5', 'Blanco'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Limpiador en gel Verdo', '400 ml'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.sur@mesh.com', 'Manual de instalaciones electricas residenciales', 'Pasta blanda'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.sur@mesh.com', 'Eau de parfum Bruma', '100 ml'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.oriente@mesh.com', 'Limpiador en gel Verdo', '400 ml'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', '100 ml'),
            ('comprador.sur@mesh.com', '2026-04-28 18:00:00-06', 'transferencia', 'tienda@mesh.com', 'Cuentos de la ceiba', 'Pasta blanda')
        ) AS t(comprador, fecha, metodo, vendedor, producto, variante)
        JOIN usuarios            uv ON uv.correo_electronico = t.vendedor
        JOIN productos           p  ON p.nombre = t.producto
        JOIN productos_variantes pv ON pv.id_producto = p.id_producto
                                    AND pv.nombre_variante = t.variante
        JOIN oferta              o  ON o.id_producto_mongo = p.id_producto
                                    AND o.id_producto_variante_mongo = pv.id_producto_variante
                                    AND o.id_usuario = uv.id_usuario
        GROUP BY t.comprador, t.fecha, t.metodo
        ORDER BY t.comprador, t.fecha
    LOOP
        SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir
        FROM usuarios u
        JOIN direcciones d          ON d.id_usuario = u.id_usuario
        JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
        WHERE u.correo_electronico = v_grupo.comprador
        LIMIT 1;

        CONTINUE WHEN v_usuario IS NULL OR v_dir IS NULL;
        -- Guardado por la fecha, igual que la resena se guarda por su llave:
        -- un pedido de verdad nace con now() y nunca cae en un 28 a las seis
        -- en punto, asi que esa fecha reconoce a los sembrados sin hacer
        -- falta una tabla de control.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM pedido
            WHERE id_usuario = v_usuario
              AND fecha_creacion = v_grupo.fecha::timestamptz);

        -- El id del pedido viene DENTRO del jsonb que devuelve: quien llama
        -- no lo conocia, lo creo ella. Y el metodo va casteado porque sale de
        -- un VALUES sin tipos y la funcion lo pide varchar.
        v_pedido := (comprar_carrito(v_usuario, v_dir, v_grupo.lineas, v_grupo.metodo::varchar)->>'id_pedido')::bigint;

        UPDATE pedido           SET fecha_creacion    = v_grupo.fecha::timestamptz WHERE id_pedido = v_pedido;
        UPDATE pago             SET fecha_cancelacion = v_grupo.fecha::timestamptz WHERE id_pedido = v_pedido;
        UPDATE stock_movimiento SET fecha_movimiento  = v_grupo.fecha::timestamptz WHERE id_pedido = v_pedido;
    END LOOP;
END
$compras$;

-- ============================================================
-- La parte social: 86 resenas, 28 respuestas, 62 votos
-- ============================================================
-- Tablas de la migracion 011.
--
-- Van en un bloque plpgsql y no en tres INSERT sueltos por una razon: la
-- resena necesita el id del comentario que acaba de nacer, y ese id no se
-- puede escribir a mano ni adivinar. El bloque lo recibe del RETURNING y lo
-- usa en la linea siguiente.
--
-- Todo se busca por correo y por nombre de producto, nunca por id: la regla
-- de migrations/README.md.
--
-- Y todo esta guardado con NOT EXISTS, porque arrancar.ps1 vuelve a correr
-- este archivo en cada arranque: sin eso, la segunda corrida chocaria con
-- el UNIQUE de resena y tumbaria la carga entera.

DO $social$
DECLARE
    v_fila        record;
    v_autor       bigint;
    v_vendedor    bigint;
    v_producto    bigint;
    v_comentario  bigint;
    v_raiz        bigint;
BEGIN
    -- ---------- Las resenas, con su comentario raiz
    FOR v_fila IN
        SELECT * FROM (VALUES
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Escritorio Roble 120', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-03-02 14:45:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Monitor Panorama 34', 1, 'Pesimo. El producto venia golpeado y no me quisieron responder.', '2026-02-22 09:01:00-06'),
            ('comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-02-05 21:38:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', 3, 'El producto esta bien, el envio fue lento.', '2026-02-03 13:35:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-05-21 10:28:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-05-09 17:21:00-06'),
            ('comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-04-01 12:42:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-04-15 19:11:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-05-12 11:06:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-04-17 09:28:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Eau de parfum Bruma', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-05-01 19:25:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-05-16 13:25:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-04-22 15:13:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', 5, 'Segunda vez que le compro y las dos veces sin un problema.', '2026-06-15 16:07:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-06-02 16:30:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 4, 'Bien en general, aunque tardo en contestar un mensaje.', '2026-03-17 17:58:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Zapato de tacos Relampago FG', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-05-27 08:09:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'La casa de los relojes detenidos', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-06-26 18:14:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Laptop Aurora 14', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-02-27 20:39:00-06'),
            ('comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Laptop Cumbre 17 Gamer', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-02-26 14:50:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Olla arrocera Grano 8 tazas', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-04-01 09:08:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 5, 'Segunda vez que le compro y las dos veces sin un problema.', '2026-04-27 18:19:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Pantalon cargo Vereda', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-05-06 14:51:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Camisa oxford clasica', 3, 'El producto esta bien, el envio fue lento.', '2026-04-18 19:26:00-06'),
            ('comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Uniforme de entrenamiento Cantera', 4, 'Bien en general, aunque tardo en contestar un mensaje.', '2026-05-22 09:57:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Camisa de lino manga larga', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-03-24 13:13:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Laptop Aurora 14', 4, 'Contento con la compra. El empaque podria ser mejor.', '2026-02-11 16:55:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Silla de comedor Vara', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-04-26 12:19:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Bases de datos distribuidas', 5, 'Segunda vez que le compro y las dos veces sin un problema.', '2026-06-09 09:55:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Lampara de escritorio Faro', 4, 'Contento con la compra. El empaque podria ser mejor.', '2026-03-15 08:35:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Agua de colonia Amanecer Citrico', 4, 'Buen producto y buen precio. Tardo un dia mas de lo que decia, nada grave.', '2026-06-17 12:43:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Cuerda de salto Relampago', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-05-15 12:21:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Cacerola honda Comal 18', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-04-03 08:16:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Guantes de ciclismo Palma Corta', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-05-21 20:55:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Casco de ruta Aerodino', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-05-06 20:11:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Silla de comedor Vara', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-03-01 21:29:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Espinilleras Muralla', 3, 'Cumple, pero por ese precio esperaba un poco mas.', '2026-04-28 10:50:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Lampara de pie Vigia 165', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-04-04 18:09:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Monitor Cenit 32 4K', 3, 'Regular. Tuve que escribir dos veces para que me dieran la guia.', '2026-03-21 18:21:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Bota de trabajo Yunque S3', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-04-19 10:29:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Hervidor electrico Vapor 1.7', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-04-02 08:30:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Audifonos Colibri Micro TWS', 5, 'Llego en dos dias y bien empacado. El vendedor aviso cuando lo despacho.', '2026-02-15 19:11:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Escritorio Roble 120', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-03-01 08:56:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Casco de ruta Aerodino', 5, 'Segunda vez que le compro y las dos veces sin un problema.', '2026-05-26 15:47:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Balon de futbol numero 5', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-06-09 12:36:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Limpiador en gel Verdo', 2, 'Mal empacado, llego con la caja abierta.', '2026-05-15 17:58:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Cafetera Alba Espresso', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-04-02 08:06:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Camisa de mezclilla Remache', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-03-27 09:19:00-06'),
            ('comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon cargo Vereda', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-04-23 21:58:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Cacerola honda Comal 18', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-03-11 15:50:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Pantalon chino resistente', 4, 'Bien en general, aunque tardo en contestar un mensaje.', '2026-03-15 09:55:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Manual de instalaciones electricas residenciales', 5, 'Segunda vez que le compro y las dos veces sin un problema.', '2026-05-12 12:54:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-02-05 10:54:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Eau de parfum Bruma', 4, 'Bien en general, aunque tardo en contestar un mensaje.', '2026-06-03 14:17:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Laptop Lienzo 15', 3, 'Regular. Tuve que escribir dos veces para que me dieran la guia.', '2026-02-25 09:13:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Crema hidratante nocturna Alba', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-05-17 14:54:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Lampara de pie Vigia 165', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-03-10 12:00:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Pantalon jogger Ocaso', 5, 'Llego en dos dias y bien empacado. El vendedor aviso cuando lo despacho.', '2026-04-26 18:05:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Laptop Bastion 16', 1, 'Pesimo. El producto venia golpeado y no me quisieron responder.', '2026-02-22 15:44:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Pesa rusa Yunque', 3, 'Regular. Tuve que escribir dos veces para que me dieran la guia.', '2026-04-23 14:10:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-05-14 14:25:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Zapato de tacos Relampago FG', 5, 'Llego en dos dias y bien empacado. El vendedor aviso cuando lo despacho.', '2026-05-02 10:28:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Serum de niacinamida 10%', 4, 'Bien en general, aunque tardo en contestar un mensaje.', '2026-05-03 13:33:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Telefono Ceibo Lite', 5, 'Segunda vez que le compro y las dos veces sin un problema.', '2026-03-16 18:42:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Olla arrocera Grano 8 tazas', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-04-09 12:08:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Candado plegable Cerrojo F8', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-04-15 10:36:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Candado plegable Cerrojo F8', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-04-19 11:14:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-04-08 10:48:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-02-26 14:11:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Silla de comedor Vara', 4, 'Cumple con lo que ofrece. Habria estado bueno que avisaran del envio.', '2026-03-18 20:17:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Monitor Vitral 24', 4, 'Buen producto y buen precio. Tardo un dia mas de lo que decia, nada grave.', '2026-02-15 18:27:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Limpiador en gel Verdo', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-05-03 11:00:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Escritorio Roble 120', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-04-27 18:57:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Monitor Panorama 34', 5, 'Llego en dos dias y bien empacado. El vendedor aviso cuando lo despacho.', '2026-02-16 20:11:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', 3, 'Cumple, pero por ese precio esperaba un poco mas.', '2026-03-02 13:09:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', 5, 'Llego en dos dias y bien empacado. El vendedor aviso cuando lo despacho.', '2026-02-07 11:26:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-05-21 10:00:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-05-22 09:03:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-04-02 10:19:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', 4, 'Contento con la compra. El empaque podria ser mejor.', '2026-04-20 08:20:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', 5, 'Entrega puntual y el producto viene con todo lo que dice.', '2026-04-06 13:36:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', 5, 'Muy buena atencion, respondio las dudas antes de que yo pagara.', '2026-04-06 09:56:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Eau de parfum Bruma', 5, 'Todo perfecto. Tal cual la descripcion y sin un rayon.', '2026-06-09 09:09:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 4, 'Todo bien. La caja venia un poco golpeada pero el contenido intacto.', '2026-04-11 20:16:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 4, 'Contento con la compra. El empaque podria ser mejor.', '2026-04-08 08:09:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', 5, 'Excelente. Lo recomiendo sin pensarlo.', '2026-06-05 21:54:00-06')
        ) AS t(autor, vendedor, producto, nota, texto, fecha)
    LOOP
        SELECT id_usuario  INTO v_autor     FROM usuarios  WHERE correo_electronico = v_fila.autor;
        SELECT id_usuario  INTO v_vendedor  FROM usuarios  WHERE correo_electronico = v_fila.vendedor;
        SELECT id_producto INTO v_producto  FROM productos WHERE nombre = v_fila.producto;

        CONTINUE WHEN v_autor IS NULL OR v_vendedor IS NULL OR v_producto IS NULL;
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM resena
            WHERE id_usuario = v_autor
              AND id_usuario_vendedor = v_vendedor
              AND id_producto_mongo = v_producto);

        INSERT INTO comentario (id_usuario, comentario, fecha_publicacion)
        VALUES (v_autor, v_fila.texto, v_fila.fecha::timestamptz)
        RETURNING id_comentario INTO v_comentario;

        INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario)
        VALUES (v_autor, v_vendedor, v_producto, v_fila.nota, v_comentario);
    END LOOP;

    -- ---------- Las respuestas del vendedor, colgando de la raiz
    FOR v_fila IN
        SELECT * FROM (VALUES
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Monitor Panorama 34', 'Le agradecemos el comentario. Seguimos mejorando el empaque.', '2026-02-22 11:01:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', 'Le agradecemos el comentario. Seguimos mejorando el empaque.', '2026-02-03 14:35:00-06'),
            ('comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', 'Que bueno que le sirvio. Estamos para servirle.', '2026-04-01 14:42:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-04-17 11:28:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-05-16 14:25:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Mancuernas ajustables Vertice 20 kg', 'Lamentamos la demora, tuvimos problemas con la mensajeria esa semana.', '2026-04-27 20:19:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Lampara de escritorio Faro', 'Le agradecemos el comentario. Seguimos mejorando el empaque.', '2026-03-15 10:35:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Silla de comedor Vara', 'Que bueno que le sirvio. Estamos para servirle.', '2026-03-01 22:29:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Bota de trabajo Yunque S3', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-04-19 11:29:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Casco de ruta Aerodino', 'Tiene razon, ya cambiamos de empresa de envio por eso mismo.', '2026-05-26 17:47:00-06'),
            ('comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Balon de futbol numero 5', 'Que bueno que le sirvio. Estamos para servirle.', '2026-06-09 14:36:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Cafetera Alba Espresso', 'Tiene razon, ya cambiamos de empresa de envio por eso mismo.', '2026-04-02 09:06:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Manual de instalaciones electricas residenciales', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-05-12 13:54:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-02-05 11:54:00-06'),
            ('compradora.norte@mesh.com', 'tienda@mesh.com', 'Laptop Lienzo 15', 'Le agradecemos el comentario. Seguimos mejorando el empaque.', '2026-02-25 10:13:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Laptop Bastion 16', 'Gracias por la compra, cualquier cosa nos escribe.', '2026-02-22 16:44:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Crema hidratante nocturna Alba', 'Tiene razon, ya cambiamos de empresa de envio por eso mismo.', '2026-05-14 16:25:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', 'Le agradecemos el comentario. Seguimos mejorando el empaque.', '2026-02-26 16:11:00-06'),
            ('comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Silla de comedor Vara', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-03-18 21:17:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Limpiador en gel Verdo', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-05-03 12:00:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Monitor Panorama 34', 'Gracias por avisarnos. Escribanos y lo resolvemos.', '2026-02-16 21:11:00-06'),
            ('compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', 'Tiene razon, ya cambiamos de empresa de envio por eso mismo.', '2026-03-02 15:09:00-06'),
            ('comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', 'Que bueno que le sirvio. Estamos para servirle.', '2026-02-07 13:26:00-06'),
            ('compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 'Gracias por la compra, cualquier cosa nos escribe.', '2026-05-22 10:03:00-06'),
            ('comprador.sur@mesh.com', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', 'Tiene razon, ya cambiamos de empresa de envio por eso mismo.', '2026-04-06 11:56:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Eau de parfum Bruma', 'Gracias por la compra, cualquier cosa nos escribe.', '2026-06-09 10:09:00-06'),
            ('compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Red de porteria Trama 7 x 2', 'Gracias por la compra, cualquier cosa nos escribe.', '2026-04-11 21:16:00-06'),
            ('compradora.norte@mesh.com', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', 'Le agradecemos el comentario. Seguimos mejorando el empaque.', '2026-06-05 23:54:00-06')
        ) AS t(autor, vendedor, producto, texto, fecha)
    LOOP
        SELECT id_usuario  INTO v_autor     FROM usuarios  WHERE correo_electronico = v_fila.autor;
        SELECT id_usuario  INTO v_vendedor  FROM usuarios  WHERE correo_electronico = v_fila.vendedor;
        SELECT id_producto INTO v_producto  FROM productos WHERE nombre = v_fila.producto;

        SELECT id_comentario INTO v_raiz FROM resena
        WHERE id_usuario = v_autor
          AND id_usuario_vendedor = v_vendedor
          AND id_producto_mongo = v_producto;

        CONTINUE WHEN v_raiz IS NULL;
        -- Ya contestada: se reconoce por el padre y el autor, no hay que
        -- guardar nada aparte.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM comentario
            WHERE id_comentario_padre = v_raiz AND id_usuario = v_vendedor);

        INSERT INTO comentario (id_usuario, id_comentario_padre, comentario, fecha_publicacion)
        VALUES (v_vendedor, v_raiz, v_fila.texto, v_fila.fecha::timestamptz);
    END LOOP;

    -- ---------- Los votos. El trigger de la 011 recalcula los contadores
    FOR v_fila IN
        SELECT * FROM (VALUES
            ('ventas.oriente@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Monitor Panorama 34', 1),
            ('ventas.sur@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Monitor Panorama 34', 1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', -1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Red de porteria Trama 7 x 2', 1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon de mezclilla Yunque', 1),
            ('ventas.norte@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', -1),
            ('ventas.sur@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Comoda Sendero 4 gavetas', -1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', -1),
            ('ventas.sur@mesh.com', 'comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Balon de futbol numero 5', 1),
            ('ventas.norte@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'La casa de los relojes detenidos', -1),
            ('ventas.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'La casa de los relojes detenidos', 1),
            ('comprador.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'La casa de los relojes detenidos', -1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 1),
            ('ventas.sur@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Camisa guayabera Xelaju', 1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Zapato de tacos Relampago FG', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Zapato de tacos Relampago FG', 1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'La casa de los relojes detenidos', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'La casa de los relojes detenidos', 1),
            ('ventas.sur@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'La casa de los relojes detenidos', 1),
            ('ventas.poniente@mesh.com', 'compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Laptop Aurora 14', 1),
            ('comprador.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Laptop Aurora 14', 1),
            ('ventas.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.norte@mesh.com', 'Laptop Aurora 14', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Laptop Cumbre 17 Gamer', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Laptop Cumbre 17 Gamer', -1),
            ('ventas.norte@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Camisa de lino manga larga', -1),
            ('ventas.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Silla de comedor Vara', -1),
            ('comprador.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Silla de comedor Vara', 1),
            ('ventas.sur@mesh.com', 'comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Bases de datos distribuidas', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Bases de datos distribuidas', 1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Bases de datos distribuidas', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'Bota de trabajo Yunque S3', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Casco de ruta Aerodino', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Casco de ruta Aerodino', 1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Balon de futbol numero 5', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Balon de futbol numero 5', 1),
            ('ventas.poniente@mesh.com', 'comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon cargo Vereda', 1),
            ('ventas.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.poniente@mesh.com', 'Pantalon cargo Vereda', 1),
            ('ventas.oriente@mesh.com', 'compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Cacerola honda Comal 18', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Manual de instalaciones electricas residenciales', 1),
            ('comprador.sur@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 1),
            ('ventas.oriente@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Audifonos Marea Diadema Abierta', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'Lampara de pie Vigia 165', -1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'Lampara de pie Vigia 165', 1),
            ('ventas.norte@mesh.com', 'compradora.norte@mesh.com', 'tienda@mesh.com', 'Pantalon jogger Ocaso', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'tienda@mesh.com', 'Laptop Bastion 16', 1),
            ('comprador.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Zapato de tacos Relampago FG', -1),
            ('ventas.norte@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Zapato de tacos Relampago FG', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Candado plegable Cerrojo F8', 1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', 1),
            ('ventas.sur@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Monitor Vertice 27 Gamer', 1),
            ('ventas.poniente@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', -1),
            ('comprador.sur@mesh.com', 'compradora.norte@mesh.com', 'ventas.poniente@mesh.com', 'Monitor Vitral 24', -1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'ventas.oriente@mesh.com', 'Monitor Panorama 34', 1),
            ('ventas.oriente@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', -1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Agua de colonia Amanecer Citrico', 1),
            ('ventas.sur@mesh.com', 'comprador.sur@mesh.com', 'ventas.sur@mesh.com', 'Comoda Sendero 4 gavetas', 1),
            ('compradora.norte@mesh.com', 'comprador.sur@mesh.com', 'ventas.norte@mesh.com', 'Rodillo de liberacion Nudo', 1),
            ('ventas.norte@mesh.com', 'compradora.norte@mesh.com', 'ventas.sur@mesh.com', 'Lampara de pie Vigia 165', 1)
        ) AS t(votante, autor, vendedor, producto, valor)
    LOOP
        SELECT id_usuario  INTO v_autor     FROM usuarios  WHERE correo_electronico = v_fila.autor;
        SELECT id_usuario  INTO v_vendedor  FROM usuarios  WHERE correo_electronico = v_fila.vendedor;
        SELECT id_producto INTO v_producto  FROM productos WHERE nombre = v_fila.producto;

        SELECT id_comentario INTO v_raiz FROM resena
        WHERE id_usuario = v_autor
          AND id_usuario_vendedor = v_vendedor
          AND id_producto_mongo = v_producto;

        CONTINUE WHEN v_raiz IS NULL;

        INSERT INTO likes (id_usuario, id_comentario, valor)
        SELECT u.id_usuario, v_raiz, v_fila.valor
        FROM usuarios u WHERE u.correo_electronico = v_fila.votante
        ON CONFLICT (id_usuario, id_comentario) DO NOTHING;
    END LOOP;
END
$social$;

-- ============================================================
-- El anillo de fraude: 3 cuentas, 4 ofertas, 3 pedidos, 4 resenas
-- ============================================================
-- Tres cuentas de la misma casa, dadas de alta la misma noche, que se
-- venden barato entre si para poder calificarse con cinco estrellas la
-- misma tarde. Es lo que hace que el panel de fraude
-- (GET /admin/fraude/anillos) encuentre algo con los datos de verdad, sin
-- que nadie tenga que acordarse de sembrar nada en Neo4j: el ETL lo lleva
-- al grafo como lleva cualquier otra resena.
--
-- SE RECONOCEN POR EL CORREO: anillo.*@mesh.com, y ese prefijo es
-- constante a proposito. Es lo unico que hace falta saber para sacarlas.
--
-- Y no se pueden limitar a escribir resenas. El backend solo deja calificar
-- a quien se le compro y se le pago, y las comprobaciones 10 y 11 de mas
-- abajo lo vigilan: si el anillo no se compra a si mismo, la migracion se
-- cae entera. Por eso cada cuenta publica ofertas propias sobre productos
-- del catalogo compartido y se compra una unidad barata antes de resenar.
-- Es lo que hace un anillo de verdad: la venta no es el negocio.
--
-- El orden de las fechas es lo unico que sostiene esas dos comprobaciones,
-- y va en una sola direccion:
--
--     alta (02-mar) -> oferta (04-mar) -> compra (06-mar) -> resena (08-mar)

-- Las tres cuentas. Van en su propio INSERT y no con las otras ocho porque
-- llevan fecha_creacion escrita: las de arriba nacen con now() y aqui hace
-- falta una noche del pasado, la misma para las tres. "Creadas el mismo
-- dia" es una de las frases que redacta el panel.
--
-- Mismas dos guardias que el INSERT de las otras cuentas, y por lo mismo:
-- usuarios tiene DOS restricciones unicas y quien ya se registro con ese
-- nombre de usuario revienta un ON CONFLICT sobre el correo.
INSERT INTO usuarios (correo_electronico, usuario, nombre, apellido, contrasena_hash, fecha_creacion, id_rol_usuario, id_estado_usuario)
SELECT v.correo, v.usuario, v.nombre, v.apellido, '1a2b3c4d5e6f708192a3b4c5d6e7f809:c4e9716408f8b9c89b81a1aca9e935ba936c2ab5c6451aca6c413cff51048b6a023ffeaf8088a0e5a0ec610bfdff9ca8c26807cd1cf24955f9dd3a2999fe83e5', v.alta::timestamptz, r.id_rol_usuario, e.id_estado_usuario
FROM (VALUES
    ('anillo.uno@mesh.com', 'anillo_uno', 'Kevin', 'Batres', '2026-03-02 20:40:00-06'),
    ('anillo.dos@mesh.com', 'anillo_dos', 'Dulce', 'Batres', '2026-03-02 20:51:00-06'),
    ('anillo.tres@mesh.com', 'anillo_tres', 'Erick', 'Batres', '2026-03-02 21:03:00-06')
) AS v(correo, usuario, nombre, apellido, alta)
JOIN rol_usuario    r ON r.rol_usuario_nombre    = 'vendedor'
JOIN estado_usuario e ON e.estado_usuario_nombre = 'activo'
WHERE NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.correo_electronico = v.correo)
  AND NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.usuario            = v.usuario);

-- La casa, escrita de tres formas distintas. Es la mitad de la senal: tal
-- cual estan son tres direcciones diferentes, y lo que las junta en UN solo
-- nodo :Direccion es la normalizacion del ETL (minusculas, sin tildes,
-- espacios colapsados), que es la identidad del nodo y no un filtro de la
-- consulta.
--
-- Y llevan calle. Sin ella la clave normalizada termina en barra y junta a
-- todo el que declaro esa ciudad, asi que A.4 exige d.tiene_calle: una
-- direccion sin calle no identifica una casa. Un anillo sin calle no se
-- veria, y con razon.
INSERT INTO direcciones (id_usuario, pais, departamento, ciudad, direccion_exacta, codigo_postal, fecha_creacion, id_estado_direccion)
SELECT u.id_usuario, 'Guatemala', 'Guatemala', 'Guatemala', v.calle, '01011', v.alta::timestamptz, ed.id_estado_direccion
FROM (VALUES
    ('anillo.uno@mesh.com', 'Callejon del Manzano 4, Casa B', '2026-03-02 20:40:00-06'),
    ('anillo.dos@mesh.com', 'Callejon del Manzano 4,  casa b', '2026-03-02 20:51:00-06'),
    ('anillo.tres@mesh.com', 'Callejon  del Manzano 4, Casa B', '2026-03-02 21:03:00-06')
) AS v(correo, calle, alta)
JOIN usuarios u ON u.correo_electronico = v.correo
JOIN estado_direccion ed ON ed.estado_direccion_nombre = 'activa'
WHERE NOT EXISTS (SELECT 1 FROM direcciones d WHERE d.id_usuario = u.id_usuario);

-- Su primera version en el historial: es a donde apunta el pedido, no a
-- direcciones. Sin esta fila crear_pedido no tiene que darle, y las compras
-- de mas abajo no existirian.
INSERT INTO direccion_historial (id_direccion, pais, departamento, ciudad, direccion_exacta, codigo_postal, fecha_creacion)
SELECT d.id_direccion, d.pais, d.departamento, d.ciudad, d.direccion_exacta, d.codigo_postal, d.fecha_creacion
FROM direcciones d
JOIN usuarios u ON u.id_usuario = d.id_usuario
WHERE u.correo_electronico IN ('anillo.uno@mesh.com', 'anillo.dos@mesh.com', 'anillo.tres@mesh.com')
  AND NOT EXISTS (SELECT 1 FROM direccion_historial h WHERE h.id_direccion = d.id_direccion);

-- Las ofertas del anillo. Un usuario nuevo no tiene nada que vender, y sin
-- vender no le pueden comprar, y sin compra no puede haber resena: esta es
-- la pieza que hace posible todo lo de abajo.
--
-- Los productos son del catalogo COMPARTIDO -- no son "del anillo", nadie
-- es dueno de un producto -- y son los tres mas baratos que hay. Es lo que
-- haria el anillo: su costo real es lo que pierde en cada compra cruzada.
-- Encima ofertan a la cuarta parte del precio de la tienda.
--
-- anillo_uno y anillo_dos publican EL MISMO producto (Cartas al puerto seco), y no es un
-- descuido: es lo que hace posible el par mutuo sobre el mismo articulo que
-- busca A.2. Nadie intercambia consigo mismo la misma cosa.
--
-- Nacen 'activa' y con fecha_aprobacion y aprobador puestos, como cualquier
-- oferta que no es de la tienda: a 'activa' no se llega sin el visto bueno,
-- y las comprobaciones 4, 5 y 6 tumban la migracion si falta. Que la tienda
-- las haya aprobado es parte del retrato -- la revision mira una oferta, no
-- una red de cuentas, y por eso el anillo pasa.
INSERT INTO oferta (id_producto_mongo, id_producto_variante_mongo, id_usuario, precio, stock, id_estado_oferta, fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)
SELECT p.id_producto, pv.id_producto_variante, u.id_usuario, v.precio, v.stock, eo.id_estado_oferta,
       v.fecha::timestamptz, v.fecha::timestamptz, v.fecha::timestamptz, ut.id_usuario
FROM (VALUES
    ('anillo.dos@mesh.com', 'Cartas al puerto seco', 'Digital', 24.00, 5, '2026-03-04 09:00:00-06'),
    ('anillo.uno@mesh.com', 'Cartas al puerto seco', 'Digital', 24.00, 5, '2026-03-04 09:00:00-06'),
    ('anillo.tres@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m', 31.00, 5, '2026-03-04 09:00:00-06'),
    ('anillo.uno@mesh.com', 'Antologia del ruido', 'Pasta blanda', 34.00, 5, '2026-03-04 09:00:00-06')
) AS v(correo, producto, variante, precio, stock, fecha)
JOIN usuarios            u  ON u.correo_electronico = v.correo
JOIN productos           p  ON p.nombre = v.producto
JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
JOIN estado_oferta       eo ON eo.estado_oferta_nombre = 'activa'
JOIN usuarios            ut ON ut.correo_electronico = 'tienda@mesh.com'
WHERE NOT EXISTS (
    SELECT 1 FROM oferta o
    WHERE o.id_usuario = u.id_usuario
      AND o.id_producto_mongo = p.id_producto
      AND o.id_producto_variante_mongo = pv.id_producto_variante);

-- El nacimiento de su precio y el kardex que explica su stock. Las dos
-- filas salen DERIVADAS de la oferta que se acaba de escribir, no de una
-- lista aparte: escritas dos veces podrian discrepar, y las comprobaciones
-- 1 y 2 de mas abajo se caen justo por eso.
--
-- Hacen falta a mano porque el trigger que las escribiria sigue apagado
-- desde el principio del archivo -- pondria now() y aqui todo es de marzo.
INSERT INTO precio_historial (id_oferta, precio, id_usuario_modifico, fecha_creacion)
SELECT o.id_oferta, o.precio, o.id_usuario, o.fecha_creacion
FROM oferta o
JOIN usuarios u ON u.id_usuario = o.id_usuario
WHERE u.correo_electronico IN ('anillo.uno@mesh.com', 'anillo.dos@mesh.com', 'anillo.tres@mesh.com')
  AND NOT EXISTS (SELECT 1 FROM precio_historial ph WHERE ph.id_oferta = o.id_oferta);

INSERT INTO stock_movimiento (id_oferta, id_motivo_movimiento, id_usuario_modifico, id_pedido, cantidad, stock_resultante, fecha_movimiento)
SELECT o.id_oferta, m.id_motivo_movimiento, o.id_usuario, NULL, o.stock, o.stock, o.fecha_creacion
FROM oferta o
JOIN usuarios u ON u.id_usuario = o.id_usuario
JOIN motivo_movimiento m ON m.motivo_nombre = 'reposicion'
WHERE u.correo_electronico IN ('anillo.uno@mesh.com', 'anillo.dos@mesh.com', 'anillo.tres@mesh.com')
  AND o.stock > 0
  AND NOT EXISTS (SELECT 1 FROM stock_movimiento sm WHERE sm.id_oferta = o.id_oferta);

-- Las compras cruzadas: el permiso para resenar.
--
-- Mismo camino que las compras que respaldan las otras resenas
-- -- comprar_carrito() de la 012 y despues corregir las tres fechas que
-- escribio con now() -- y por lo mismo: ella congela el id_precio_historial
-- correcto y arma el nombre del vendedor desde la base. Un INSERT a mano
-- tendria que copiar esas reglas y quedaria libre de desviarse.
--
-- Una unidad por linea. El anillo no quiere inventario, quiere el recibo.
-- Y el pedido de anillo_dos lleva dos lineas de dos vendedores distintos sin
-- que haya que armarlo aparte: sale de agrupar por comprador.
DO $anillo_compras$
DECLARE
    v_grupo    record;
    v_usuario  bigint;
    v_dir      bigint;
    v_pedido   bigint;
BEGIN
    FOR v_grupo IN
        SELECT t.comprador, t.fecha, t.metodo,
               jsonb_agg(jsonb_build_object(
                   'id_oferta',            o.id_oferta,
                   'cantidad',             1,
                   'id_producto',          p.id_producto,
                   'id_producto_variante', pv.id_producto_variante,
                   'nombre_producto',      p.nombre,
                   'nombre_variante',      pv.nombre_variante
               ) ORDER BY o.id_oferta) AS lineas
        FROM (VALUES
            ('anillo.uno@mesh.com', '2026-03-06 17:40:00-06', 'tarjeta', 'anillo.dos@mesh.com', 'Cartas al puerto seco', 'Digital'),
            ('anillo.dos@mesh.com', '2026-03-06 17:55:00-06', 'transferencia', 'anillo.uno@mesh.com', 'Cartas al puerto seco', 'Digital'),
            ('anillo.dos@mesh.com', '2026-03-06 17:55:00-06', 'transferencia', 'anillo.tres@mesh.com', 'Cuerda de salto Relampago', 'Cable de 3 m'),
            ('anillo.tres@mesh.com', '2026-03-06 18:10:00-06', 'efectivo contra entrega', 'anillo.uno@mesh.com', 'Antologia del ruido', 'Pasta blanda')
        ) AS t(comprador, fecha, metodo, vendedor, producto, variante)
        JOIN usuarios            uv ON uv.correo_electronico = t.vendedor
        JOIN productos           p  ON p.nombre = t.producto
        JOIN productos_variantes pv ON pv.id_producto = p.id_producto
                                    AND pv.nombre_variante = t.variante
        JOIN oferta              o  ON o.id_producto_mongo = p.id_producto
                                    AND o.id_producto_variante_mongo = pv.id_producto_variante
                                    AND o.id_usuario = uv.id_usuario
        GROUP BY t.comprador, t.fecha, t.metodo
        ORDER BY t.comprador, t.fecha
    LOOP
        SELECT u.id_usuario, dh.id_direccion_historial INTO v_usuario, v_dir
        FROM usuarios u
        JOIN direcciones d          ON d.id_usuario = u.id_usuario
        JOIN direccion_historial dh ON dh.id_direccion = d.id_direccion
        WHERE u.correo_electronico = v_grupo.comprador
        LIMIT 1;

        CONTINUE WHEN v_usuario IS NULL OR v_dir IS NULL;
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM pedido
            WHERE id_usuario = v_usuario
              AND fecha_creacion = v_grupo.fecha::timestamptz);

        v_pedido := (comprar_carrito(v_usuario, v_dir, v_grupo.lineas, v_grupo.metodo::varchar)->>'id_pedido')::bigint;

        UPDATE pedido           SET fecha_creacion    = v_grupo.fecha::timestamptz WHERE id_pedido = v_pedido;
        UPDATE pago             SET fecha_cancelacion = v_grupo.fecha::timestamptz WHERE id_pedido = v_pedido;
        UPDATE stock_movimiento SET fecha_movimiento  = v_grupo.fecha::timestamptz WHERE id_pedido = v_pedido;
    END LOOP;
END
$anillo_compras$;

-- Y las resenas, que son el producto del anillo.
--
-- Las cuatro con la nota maxima y todas de la misma tarde: cuatro horas y
-- media de punta a punta, muy dentro de las 72 horas que el servicio llama
-- rafaga. El texto es identico en las cuatro, y eso tambien es senal --
-- cuatro cuentas que escriben palabra por palabra lo mismo no son cuatro
-- personas.
--
-- El circulo se cierra: anillo_uno califica a anillo_dos, anillo_dos a anillo_tres y
-- anillo_tres a anillo_uno. Ninguna se califica a si misma -- la 011 lo
-- prohibe con un CHECK -- pero el circulo consigue el mismo efecto repartido
-- entre tres, y ninguna de estas cuatro filas, mirada sola, se ve rara.
--
-- Y las dos primeras van en los DOS sentidos sobre el mismo producto, que
-- es la frase literal del enunciado de la entrega.
--
-- Mismo bloque plpgsql que las otras resenas, y por lo mismo: la resena
-- necesita el id del comentario que acaba de nacer, y ese id no se puede
-- escribir a mano ni adivinar.
DO $anillo_resenas$
DECLARE
    v_fila        record;
    v_autor       bigint;
    v_vendedor    bigint;
    v_producto    bigint;
    v_comentario  bigint;
BEGIN
    FOR v_fila IN
        SELECT * FROM (VALUES
            ('anillo.uno@mesh.com', 'anillo.dos@mesh.com', 'Cartas al puerto seco', 5, 'Excelente vendedor, todo llego perfecto y en tiempo. Lo recomiendo.', '2026-03-08 09:12:00-06'),
            ('anillo.dos@mesh.com', 'anillo.uno@mesh.com', 'Cartas al puerto seco', 5, 'Excelente vendedor, todo llego perfecto y en tiempo. Lo recomiendo.', '2026-03-08 10:41:00-06'),
            ('anillo.dos@mesh.com', 'anillo.tres@mesh.com', 'Cuerda de salto Relampago', 5, 'Excelente vendedor, todo llego perfecto y en tiempo. Lo recomiendo.', '2026-03-08 12:05:00-06'),
            ('anillo.tres@mesh.com', 'anillo.uno@mesh.com', 'Antologia del ruido', 5, 'Excelente vendedor, todo llego perfecto y en tiempo. Lo recomiendo.', '2026-03-08 13:37:00-06')
        ) AS t(autor, vendedor, producto, nota, texto, fecha)
    LOOP
        SELECT id_usuario  INTO v_autor     FROM usuarios  WHERE correo_electronico = v_fila.autor;
        SELECT id_usuario  INTO v_vendedor  FROM usuarios  WHERE correo_electronico = v_fila.vendedor;
        SELECT id_producto INTO v_producto  FROM productos WHERE nombre = v_fila.producto;

        CONTINUE WHEN v_autor IS NULL OR v_vendedor IS NULL OR v_producto IS NULL;
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM resena
            WHERE id_usuario = v_autor
              AND id_usuario_vendedor = v_vendedor
              AND id_producto_mongo = v_producto);

        INSERT INTO comentario (id_usuario, comentario, fecha_publicacion)
        VALUES (v_autor, v_fila.texto, v_fila.fecha::timestamptz)
        RETURNING id_comentario INTO v_comentario;

        INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo, calificacion, id_comentario)
        VALUES (v_autor, v_vendedor, v_producto, v_fila.nota, v_comentario);
    END LOOP;
END
$anillo_resenas$;

-- ============================================================
-- Descuentos: 13 ofertas de la tienda
-- ============================================================
-- oferta.precio NO se toca: sigue siendo el de lista, y el precio con
-- descuento se calcula en cada consulta (ver 020_descuentos_oferta.sql).
-- Cada descuento deja su fila en precio_historial con el mismo precio y el
-- %, que es lo que haria el trigger si estuviera encendido. Se escribe a
-- mano por lo mismo que el resto del historial: la fecha.
--
-- La fecha va despues de cualquier otro precio del conjunto (el ultimo
-- cambio cae en agosto), asi que la fila del descuento es la vigente.
--
-- La guardia: solo se pone donde no hay ninguno. Si el vendedor ya puso o
-- cambio el suyo, se respeta el de el.

WITH puestos AS (
    UPDATE oferta o
    SET porcentaje_descuento = v.porcentaje
    FROM (VALUES
        ('tienda@mesh.com', 'Laptop Vireo Air 12', '8 GB / 128 GB', 10.00),
        ('tienda@mesh.com', 'Audifonos Sereno ANC', 'Negro', 15.00),
        ('tienda@mesh.com', 'Monitor Panorama 34', '100 Hz', 20.00),
        ('tienda@mesh.com', 'Hervidor electrico Vapor 1.7', 'Acero', 25.00),
        ('tienda@mesh.com', 'Silla de comedor Vara', 'Natural', 30.00),
        ('tienda@mesh.com', 'Camisa de lino manga larga', 'M azul', 10.00),
        ('tienda@mesh.com', 'Pantalon cargo Vereda', '34 arena', 15.00),
        ('tienda@mesh.com', 'Sandalia de cuero Litoral', '41 cafe', 20.00),
        ('tienda@mesh.com', 'Bomba de piso Piston', 'Estandar', 25.00),
        ('tienda@mesh.com', 'Pesa rusa Yunque', '12 kg', 30.00),
        ('tienda@mesh.com', 'Antologia del ruido', 'Pasta blanda', 10.00),
        ('tienda@mesh.com', 'Crema hidratante nocturna Alba', '50 ml', 15.00),
        ('tienda@mesh.com', 'Set descubrimiento Nocturno', 'Coleccion noche', 20.00)
    ) AS v(correo, producto, variante, porcentaje)
    JOIN usuarios            u  ON u.correo_electronico = v.correo
    JOIN productos           p  ON p.nombre = v.producto
    JOIN productos_variantes pv ON pv.id_producto = p.id_producto AND pv.nombre_variante = v.variante
    WHERE o.id_producto_mongo = p.id_producto
      AND o.id_producto_variante_mongo = pv.id_producto_variante
      AND o.id_usuario = u.id_usuario
      AND o.porcentaje_descuento IS NULL
    RETURNING o.id_oferta, o.precio, o.porcentaje_descuento, o.id_usuario
)
INSERT INTO precio_historial (id_oferta, precio, porcentaje_descuento, id_usuario_modifico, fecha_creacion)
SELECT id_oferta, precio, porcentaje_descuento, id_usuario, '2026-09-01 09:00:00-06'::timestamptz
FROM puestos;

-- ============================================================
-- El trigger vuelve, y el conjunto se comprueba a si mismo
-- ============================================================
-- Un conjunto de datos que no se verifica es un conjunto de datos que
-- miente en silencio. Estas trece comprobaciones fallan la migracion entera
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
        WHERE o.id_producto_mongo = pv.id_producto
          AND o.id_producto_variante_mongo = pv.id_producto_variante
          AND u.correo_electronico = 'tienda@mesh.com'
    );

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% variantes no tienen oferta de la tienda', v_mal;
    END IF;

    -- 4. Ninguna oferta que circula esta sin aprobar. A 'activa' y a
    --    'pausada' no se llega sin el visto bueno de la tienda, asi que una
    --    de esas con fecha_aprobacion en NULL es un estado imposible.
    --    Esta comprobacion existe porque la base NO lo puede impedir sola:
    --    un CHECK no admite subconsultas y meter el id del estado a mano
    --    dentro de la restriccion esta prohibido (migrations/README.md).
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
    WHERE eo.estado_oferta_nombre IN ('activa', 'pausada')
      AND o.fecha_aprobacion IS NULL;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas circulan sin fecha de aprobacion', v_mal;
    END IF;

    -- 5. Y la reciproca: una oferta 'pendiente' o 'rechazada' NO puede tener
    --    fecha de aprobacion. A 'rechazada' solo se llega desde 'pendiente'
    --    (el backend rechaza revisar cualquier otro estado), y el rechazo no
    --    toca la fecha, asi que las dos comparten la misma invariante.
    --
    --    Esta mitad importa mas de lo que parece: la fecha de aprobacion es
    --    el candado que impide que un vendedor active su propia oferta, asi
    --    que una fila sin aprobar pero CON fecha es una que se puede publicar
    --    sola, saltandose la revision.
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
    WHERE eo.estado_oferta_nombre IN ('pendiente', 'rechazada')
      AND o.fecha_aprobacion IS NOT NULL;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas sin aprobar ya traen fecha de aprobacion', v_mal;
    END IF;

    -- 6. Nadie aprobo una oferta que no esta aprobada. Al reves SI se puede
    --    (la tienda nace aprobada y sin revisor), asi que solo se comprueba
    --    esta mitad: si hay aprobador, tiene que haber fecha.
    SELECT count(*) INTO v_mal
    FROM oferta
    WHERE id_usuario_aprobo IS NOT NULL
      AND fecha_aprobacion IS NULL;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas tienen aprobador pero no fecha de aprobacion', v_mal;
    END IF;

    -- 7. Toda direccion tiene calle, en la fila viva y en su historial. Sin
    --    ella no se entrega un pedido, y el backend la exige al crear una
    --    nueva: los datos de prueba no pueden ser los unicos que se saltan
    --    la regla.
    --    Se cuentan DIRECCIONES distintas, no filas: una direccion sin calle
    --    arrastra tambien su fila de historial, y sumar las dos tablas
    --    reportaria el doble. Quien lea "2" saldria a buscar dos direcciones
    --    rotas cuando solo hay una.
    SELECT count(*) INTO v_mal
    FROM direcciones d
    WHERE d.direccion_exacta IS NULL
       OR EXISTS (SELECT 1 FROM direccion_historial h
                   WHERE h.id_direccion = d.id_direccion
                     AND h.direccion_exacta IS NULL);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% direcciones se quedaron sin calle', v_mal;
    END IF;

    -- 8. Toda resena cuelga de un comentario RAIZ, nunca de una respuesta.
    --    Es la invariante que la 011 NO puede exigir con un CHECK, porque un
    --    CHECK no ve otra fila. Y es la que mas barato se rompe: si una
    --    resena apunta a una respuesta, el hilo se dibuja dentro de si mismo
    --    y la base no se queja jamas.
    SELECT count(*) INTO v_mal
    FROM resena r
    JOIN comentario c ON c.id_comentario = r.id_comentario
    WHERE c.id_comentario_padre IS NOT NULL;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% resenas cuelgan de una respuesta en vez de una raiz', v_mal;
    END IF;

    -- 9. Los contadores de cada comentario dicen lo mismo que la tabla likes.
    --    cantidad_likes y cantidad_dislikes son una COPIA derivada, y una
    --    copia sin quien la vigile se desvia en silencio. El trigger de la
    --    011 la mantiene; esto comprueba que el trigger de verdad corrio, que
    --    no es lo mismo que suponer que existe.
    --    Se cuentan valor = 1 y valor = -1 explicitamente, igual que el
    --    trigger: si el candado contara de otra forma, aprobaria o fallaria
    --    midiendo algo distinto de lo que vigila.
    SELECT count(*) INTO v_mal
    FROM comentario c
    WHERE c.cantidad_likes <> (SELECT count(*) FROM likes l
                                WHERE l.id_comentario = c.id_comentario AND l.valor = 1)
       OR c.cantidad_dislikes <> (SELECT count(*) FROM likes l
                                   WHERE l.id_comentario = c.id_comentario AND l.valor = -1);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% comentarios tienen los contadores desincronizados de likes', v_mal;
    END IF;

    -- 10. Toda resena tiene detras una compra pagada A ESE VENDEDOR.
    --     Es la regla que el backend exige para dejar calificar, y hasta
    --     ahora nada la vigilaba de este lado: 84 de las 86 resenas
    --     sembradas no la cumplian, o sea que eran filas que el propio
    --     sistema no habria dejado escribir.
    --
    --     Los JOIN son LOS MISMOS que exigirCompraPagada() en
    --     backend/src/services/resenas/resenas.service.ts, y eso incluye las
    --     dos condiciones que es facil dejarse: que la oferta comprada sea
    --     DEL vendedor calificado -- se llega por
    --     pedido_producto -> precio_historial -> oferta -- y que el pedido no
    --     este cancelado. Un candado que comprueba algo distinto de lo que
    --     el sistema exige es peor que no tenerlo: aprueba en verde datos
    --     que la aplicacion despues rechaza.
    SELECT count(*) INTO v_mal
    FROM resena r
    WHERE NOT EXISTS (
        SELECT 1
          FROM pedido pe
          JOIN pago             pg  ON pg.id_pedido          = pe.id_pedido
          JOIN estado_pago      epa ON epa.id_estado_pago    = pg.id_estado_pago
          JOIN estado_pedido    epe ON epe.id_estado_pedido  = pe.id_estado_pedido
          JOIN pedido_producto  pp  ON pp.id_pedido          = pe.id_pedido
          JOIN precio_historial ph  ON ph.id_precio_historial = pp.id_precio_historial
          JOIN oferta           o   ON o.id_oferta           = ph.id_oferta
         WHERE pe.id_usuario = r.id_usuario
           AND o.id_usuario  = r.id_usuario_vendedor
           AND pp.id_producto_mongo = r.id_producto_mongo
           AND epa.estado_pago_nombre    = 'pagado'
           AND epe.estado_pedido_nombre <> 'cancelado');

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% resenas no tienen detras una compra pagada a ese vendedor', v_mal;
    END IF;

    -- 11. Y ninguna esta fechada ANTES de la compra que la habilita. La 10
    --     sola no lo ve: una resena de marzo con su compra en mayo la pasa
    --     entera, porque la fila existe. El calendario es lo unico que la
    --     desmiente, y nadie mira el calendario hasta que alguien ordena el
    --     historial de una cuenta y ve la resena antes que el pedido.
    --     La fecha de la resena vive en su comentario raiz, no en resena.
    SELECT count(*) INTO v_mal
    FROM resena r
    JOIN comentario c ON c.id_comentario = r.id_comentario
    WHERE NOT EXISTS (
        SELECT 1
          FROM pedido pe
          JOIN pago             pg  ON pg.id_pedido          = pe.id_pedido
          JOIN estado_pago      epa ON epa.id_estado_pago    = pg.id_estado_pago
          JOIN estado_pedido    epe ON epe.id_estado_pedido  = pe.id_estado_pedido
          JOIN pedido_producto  pp  ON pp.id_pedido          = pe.id_pedido
          JOIN precio_historial ph  ON ph.id_precio_historial = pp.id_precio_historial
          JOIN oferta           o   ON o.id_oferta           = ph.id_oferta
         WHERE pe.id_usuario = r.id_usuario
           AND o.id_usuario  = r.id_usuario_vendedor
           AND pp.id_producto_mongo = r.id_producto_mongo
           AND epa.estado_pago_nombre    = 'pagado'
           AND epe.estado_pedido_nombre <> 'cancelado'
           AND pe.fecha_creacion < c.fecha_publicacion);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% resenas estan fechadas antes de la compra que las habilita', v_mal;
    END IF;

    -- 12. Y queda al menos un circulo cerrado de calificaciones: A califica
    --     a B, B a C y C a A. Es la unica comprobacion de este bloque que
    --     falla con CERO en vez de con mas de cero, y esta escrita al reves
    --     a proposito: lo que hay que impedir aqui no es un dato torcido,
    --     es una AUSENCIA.
    --
    --     El panel de fraude llevaba semanas devolviendo "anillos: []" con
    --     los datos sembrados, y eso no se veia como un fallo: se veia como
    --     una tienda sana. Si alguien toca el anillo de arriba y el circulo
    --     deja de cerrar, el panel vuelve a salir vacio y otra vez nadie se
    --     entera. Un cero legitimo que se calla es justo lo que hay que
    --     poner a gritar.
    --
    --     Se cuenta el triangulo y no las cuentas anillo.*@mesh.com: lo que
    --     el panel necesita es la FIGURA, y el dia que el circulo lo cierren
    --     otras cuentas esta comprobacion sigue diciendo la verdad.
    --
    --     Lo que NO se comprueba aqui es la casa compartida, y hay que
    --     decirlo: normalizar la direccion es cosa de clave_direccion() en
    --     etl/extraer_grafo.sql, y copiarla aqui dejaria dos textos que se
    --     desincronizan sin avisar -- el fallo que este proyecto ya pago
    --     antes. La comprobacion 7 garantiza que la calle existe, que es la
    --     mitad que si depende de este archivo.
    --
    --     El filtro descarta el caso degenerado del par mutuo (A califica a
    --     B y B a A), que con tres JOIN se veria como un triangulo de dos
    --     cuentas. La otra mitad la impide el CHECK de la 011: nadie se
    --     califica a si mismo.
    SELECT count(*) INTO v_mal
    FROM resena a
    JOIN resena b ON b.id_usuario          = a.id_usuario_vendedor
    JOIN resena c ON c.id_usuario          = b.id_usuario_vendedor
                 AND c.id_usuario_vendedor = a.id_usuario
    WHERE a.id_usuario <> b.id_usuario_vendedor;

    IF v_mal = 0 THEN
        RAISE EXCEPTION 'No quedo ni un circulo cerrado de calificaciones: el panel de fraude vuelve a salir vacio';
    END IF;

    -- 13. El descuento de cada oferta es el de la ultima fila de su
    --     historial, igual que el precio en la 2. Si la fila del descuento
    --     no quedara como la vigente, comprar_pedido() cobraria el precio
    --     de lista mientras la ficha ensena el rebajado. IS DISTINCT FROM
    --     y no <>, porque "sin descuento" es NULL de los dos lados.
    SELECT count(*) INTO v_mal
    FROM oferta o
    JOIN LATERAL (
        SELECT porcentaje_descuento FROM precio_historial ph
        WHERE ph.id_oferta = o.id_oferta
        ORDER BY ph.fecha_creacion DESC, ph.id_precio_historial DESC LIMIT 1
    ) ultimo ON true
    WHERE o.porcentaje_descuento IS DISTINCT FROM ultimo.porcentaje_descuento;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas tienen un descuento distinto al de la ultima fila de su historial', v_mal;
    END IF;

    RAISE NOTICE 'Conjunto de datos verificado: kardex, precios, descuentos, ofertas de la tienda, aprobaciones, direcciones, las compras que respaldan las resenas, la parte social y el circulo del anillo cuadran';
END
$verificar$;

COMMIT;
