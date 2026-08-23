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

    -- Las caracteristicas van como arreglo de {nombre, valor, unidad} y no
    -- como un objeto de nombre a valor: dos productos de la misma categoria no
    -- traen las mismas llaves, y un objeto obligaria a preguntar por cada una.
    --
    -- La unidad sale de la definicion, no del valor: en el relacional se dice
    -- una vez que la RAM se mide en GB y aqui se copia a cada entrada, para
    -- que quien lea el documento no tenga que ir a buscarla.
    --
    -- EL VALOR SALE CON SU TIPO, no como texto. En PostgreSQL la columna es
    -- text para los cuatro tipos a la vez, porque una sola tabla no puede
    -- tener una columna por tipo; pero eso es una atadura de SQL y Mongo no la
    -- hereda. Se convierte aqui, una vez al escribir, y no en cada consulta:
    -- asi "Nucleos" se puede comparar y sumar como numero de verdad.
    --
    -- Y una caracteristica de tipo lista sale como UNA entrada con un array
    -- adentro, no como cinco entradas repetidas. Las filas repetidas son como
    -- vive en el relacional por la 1FN; un documento si puede guardar varios
    -- valores en un campo. De ahi el GROUP BY.
    --
    -- El orden del arreglo es el orden, y se ordena por id_caracteristica, que
    -- es estable.
    'caracteristicas_adicionales', (
        SELECT coalesce(jsonb_agg(x.entrada ORDER BY x.orden), '[]'::jsonb)
        FROM (
            SELECT ca.id_caracteristica AS orden,
                   jsonb_build_object(
                       'nombre', ca.nombre,
                       'valor',  CASE td.tipo_dato
                           WHEN 'lista'    THEN jsonb_agg(to_jsonb(pc.valor)
                                                ORDER BY pc.id_producto_caracteristica)
                           WHEN 'entero'   THEN to_jsonb((array_agg(pc.valor))[1]::bigint)
                           WHEN 'decimal'  THEN to_jsonb((array_agg(pc.valor))[1]::numeric)
                           WHEN 'booleano' THEN to_jsonb((array_agg(pc.valor))[1]::boolean)
                           ELSE                 to_jsonb((array_agg(pc.valor))[1])
                       END,
                       'unidad', ca.unidad
                   ) AS entrada
            FROM producto_caracteristica pc
            JOIN caracteristica ca ON ca.id_caracteristica = pc.id_caracteristica
            JOIN tipo_dato      td ON td.id_tipo_dato      = ca.id_tipo_dato
            WHERE pc.id_producto = p.id_producto
            GROUP BY ca.id_caracteristica, ca.nombre, ca.unidad, td.tipo_dato
        ) x
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

                   -- Cuantas unidades quedan. Va aqui porque el catalogo se lee
                   -- de Mongo: sin esto, ensenar "agotado" o filtrar por
                   -- disponible obligaria a una consulta a PostgreSQL por cada
                   -- producto de la pagina.
                   --
                   -- Es una COPIA, nunca la verdad. Quien decide si alcanza es
                   -- PostgreSQL dentro de la transaccion de la compra; si se
                   -- decidiera con este numero, dos personas comprarian la
                   -- ultima unidad. Aqui sirve para pintar, no para vender.
                   --
                   -- Una variante sin fila de inventario todavia no tiene
                   -- mercaderia: sale en 0, no en nulo.
                   'stock', (
                       SELECT coalesce(inv.stock, 0)
                       FROM inventario inv
                       WHERE inv.id_producto_mongo          = p.id_producto
                         AND inv.id_producto_variante_mongo = pv.id_producto_variante
                   ),
                   'descripcion',          pv.descripcion,
                   'fecha_creacion',       pv.fecha_creacion,
                   'estado',               ev.estado_variante_nombre,
                   -- Lo mismo para la variante, contra su propia tabla de
                   -- definiciones y con las mismas dos reglas: el valor con su
                   -- tipo, y una lista en una sola entrada.
                   'caracteristicas_adicionales', (
                       SELECT coalesce(jsonb_agg(y.entrada ORDER BY y.orden), '[]'::jsonb)
                       FROM (
                           SELECT cv.id_caracteristica AS orden,
                                  jsonb_build_object(
                                      'nombre', cv.nombre,
                                      'valor',  CASE tdv.tipo_dato
                                          WHEN 'lista'    THEN jsonb_agg(to_jsonb(pvc.valor)
                                               ORDER BY pvc.id_producto_variante_caracteristica_variante)
                                          WHEN 'entero'   THEN to_jsonb((array_agg(pvc.valor))[1]::bigint)
                                          WHEN 'decimal'  THEN to_jsonb((array_agg(pvc.valor))[1]::numeric)
                                          WHEN 'booleano' THEN to_jsonb((array_agg(pvc.valor))[1]::boolean)
                                          ELSE                 to_jsonb((array_agg(pvc.valor))[1])
                                      END,
                                      'unidad', cv.unidad
                                  ) AS entrada
                           FROM producto_variante_caracteristica_variante pvc
                           JOIN caracteristica_variante cv
                                ON cv.id_caracteristica = pvc.id_caracteristica_variante
                           JOIN tipo_dato tdv ON tdv.id_tipo_dato = cv.id_tipo_dato
                           WHERE pvc.id_producto_variante = pv.id_producto_variante
                           GROUP BY cv.id_caracteristica, cv.nombre, cv.unidad, tdv.tipo_dato
                       ) y
                   ),
                   'imagenes', (
                       SELECT coalesce(jsonb_agg(ip.imagen_producto_url
                                       ORDER BY ipv.numero_orden), '[]'::jsonb)
                       FROM imagen_producto_producto ipv
                       JOIN imagen_producto ip
                            ON ip.id_imagen_producto = ipv.id_imagen_producto
                       WHERE ipv.id_producto_variante = pv.id_producto_variante
                   )
               )
               ORDER BY pv.id_producto_variante), '[]'::jsonb)
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
