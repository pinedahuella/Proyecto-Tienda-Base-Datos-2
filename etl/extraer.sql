-- extraer.sql
-- Saca de PostgreSQL, en JSON, todo lo que Mongo necesita de cada producto.
--
-- Devuelve una linea por producto. No un arreglo: asi el archivo se puede leer
-- de a poco y una linea larga no arrastra a las demas. Se corre con
-- "psql -qtAX", que no imprime ni encabezado ni conteo de filas, y lo que sale
-- por pantalla es JSON puro.
--
-- El JSON lo arma PostgreSQL, no un programa de por medio. Es lo unico que
-- hace falta para no depender de ningun paquete instalado en la maquina.
--
-- Se usa jsonb y no json porque json conserva el texto tal cual se escribio y
-- mete saltos de linea entre los elementos de un jsonb_agg. Con jsonb la
-- salida siempre es compacta, y una linea es un producto de verdad.

-- Las fechas salen con la zona del cliente. Fijandola aqui, el mismo producto
-- extraido desde dos maquinas da el mismo texto, y las comparaciones que hace
-- el ETL para detectar cambios no dependen de quien lo corrio.
SET TIME ZONE 'UTC';

-- El dinero (precio y porcentaje_comision) sale como texto, no como numero.
-- JSON solo tiene el numero de punto flotante, que redondea; el ETL lo vuelve
-- decimal al escribirlo en Mongo. De paso, comparar texto es exacto: no hay
-- forma de que dos precios iguales parezcan distintos por el ultimo decimal.

SELECT jsonb_build_object(

    -- El estado vivo del producto. Es lo que se ve en el catalogo.
    'id_producto',    p.id_producto,
    'nombre',         p.nombre,
    'descripcion',    p.descripcion,
    'fecha_creacion', p.fecha_creacion,
    'estado',         ep.estado_producto_nombre,

    -- El vendedor va embebido y ademas referenciado por id_usuario. Se embebe
    -- porque la ficha del producto siempre lo ensena y son cuatro campos que
    -- casi nunca cambian; el id queda para volver a PostgreSQL, que sigue
    -- siendo el dueno de las cuentas.
    'vendedor', jsonb_build_object(
        'id_usuario', u.id_usuario,
        'usuario',    u.usuario,
        'nombre',     u.nombre,
        'apellido',   u.apellido
    ),

    -- La categoria se embebe por lo mismo: se lee junto con el producto y es
    -- pocos campos. Del padre solo interesa el nombre, para poder
    -- ensenar "Ropa > Ropa de hombre" sin una segunda consulta.
    'categoria', jsonb_build_object(
        'id_categoria',        c.id_categoria,
        'nombre',              c.nombre,
        'porcentaje_comision', c.porcentaje_comision::text,
        'categoria_padre',     cp.nombre
    ),

    -- Las variantes son parte del producto: no se consultan solas y son pocas.
    -- Las imagenes van dentro de su variante porque cuelgan de ella, no del
    -- producto, y numero_orden se gasta al ordenarlas: en un arreglo la
    -- posicion ya es el orden.
    'variantes', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'id_producto_variante', pv.id_producto_variante,
                   'nombre_variante',      pv.nombre_variante,
                   'precio',               pv.precio::text,
                   'descripcion',          pv.descripcion,
                   'fecha_creacion',       pv.fecha_creacion,
                   'estado',               ev.estado_variante_nombre,
                   'imagenes', (
                       SELECT coalesce(jsonb_agg(ip.imagen_producto_url
                                       ORDER BY ipv.numero_orden), '[]'::jsonb)
                       FROM imagen_producto_producto ipv
                       JOIN imagen_producto ip
                            ON ip.id_imagen_producto = ipv.id_imagen_producto
                       WHERE ipv.id_producto_variante = pv.id_producto_variante
                   )
               ) ORDER BY pv.id_producto_variante), '[]'::jsonb)
        FROM productos_variantes pv
        -- La llave del catalogo es id_estado_variante y la foranea que la
        -- apunta se llama id_estado_variantes, en plural. Asi esta en el
        -- diagrama; no es un error de tipeo de esta consulta.
        JOIN estado_variantes ev
             ON ev.id_estado_variante = pv.id_estado_variantes
        WHERE pv.id_producto = p.id_producto
    ),

    -- Los tres historiales van crudos y por separado, ordenados por fecha.
    -- Aqui no se mezclan: cada uno corre por su cuenta y con fechas distintas,
    -- y juntarlos es justo el trabajo de cargar.js. Se llaman "fecha" y no
    -- "fecha_creacion" para no confundir la fecha desde la que rige una
    -- version con la fecha en que nacio el producto.
    'historial_producto', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'nombre',      ph.nombre,
                   'descripcion', ph.descripcion,
                   'fecha',       ph.fecha_creacion
               ) ORDER BY ph.fecha_creacion), '[]'::jsonb)
        FROM productos_historial ph
        WHERE ph.id_producto = p.id_producto
    ),

    'historial_variantes', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'id_producto_variante', vh.id_producto_variante,
                   'nombre_variante',      vh.nombre_variante,
                   'precio',               vh.precio::text,
                   'descripcion',          vh.descripcion,
                   'fecha',                vh.fecha_creacion
               ) ORDER BY vh.fecha_creacion), '[]'::jsonb)
        FROM productos_variantes_historial vh
        JOIN productos_variantes pvh
             ON pvh.id_producto_variante = vh.id_producto_variante
        WHERE pvh.id_producto = p.id_producto
    ),

    'historial_categoria', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'nombre',              ch.nombre,
                   'porcentaje_comision', ch.porcentaje_comision::text,
                   'fecha',               ch.fecha_creacion
               ) ORDER BY ch.fecha_creacion), '[]'::jsonb)
        FROM categorias_historial ch
        WHERE ch.id_categoria = p.id_categoria
    )
)
FROM productos p
JOIN usuarios        u  ON u.id_usuario         = p.id_usuario
JOIN estado_producto ep ON ep.id_estado_producto = p.id_estado_producto
JOIN categorias      c  ON c.id_categoria       = p.id_categoria
-- LEFT: una categoria raiz no tiene padre y su producto tiene que salir igual
LEFT JOIN categorias cp ON cp.id_categoria      = c.id_categoria_padre
ORDER BY p.id_producto;
