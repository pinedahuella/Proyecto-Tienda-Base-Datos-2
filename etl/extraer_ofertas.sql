-- extraer_ofertas.sql
-- Saca las ofertas: quien vende que variante, a como y con cuantas unidades.
--
-- Una linea por oferta, igual que extraer.sql. Se corre con "psql -qtAX".
--
-- Es la coleccion que NO se embebe dentro del producto, y conviene tener claro
-- por que, porque es exactamente la decision que pide la Entrega 1:
--
--   Frecuencia de acceso conjunto  partida. La LISTA del catalogo solo
--       necesita un precio, y ese va embebido en el producto como
--       precio_tienda. La lista completa de vendedores solo hace falta al
--       abrir la ficha, que es una pantalla y no cuarenta tarjetas.
--
--   Volumen  no es el problema. Un documento de Mongo aguanta 16 MB y ningun
--       producto va a tener tantos vendedores.
--
--   Tasa de cambio  AQUI se decide. El stock cambia en CADA venta, y Mongo
--       reescribe el documento entero en cada actualizacion. Si las ofertas
--       vivieran dentro del producto, comprar una camisa reescribiria el
--       documento completo de la camisa (sus variantes, sus caracteristicas,
--       sus imagenes), y dos vendedores vendiendo a la vez pelearian por el
--       mismo documento. Ademas la Entrega 2 pide justamente vender unidades
--       limitadas bajo concurrencia: meter el contador dentro del documento
--       mas leido del sistema es la forma equivocada para ese reto.
--
-- El vendedor SI va embebido dentro de la oferta, y por lo contrario: son
-- cuatro campos, se leen siempre con ella ("Vendido por Carlos Ramirez") y
-- casi nunca cambian. La misma pregunta, contestada al reves porque el caso es
-- distinto.

SET TIME ZONE 'UTC';

WITH tienda AS (
    SELECT id_usuario FROM usuarios WHERE correo_electronico = 'tienda@mesh.com'
)

SELECT jsonb_build_object(
    'id_oferta',            o.id_oferta,

    -- Los dos ids del catalogo. Con ellos se llega al documento del producto,
    -- que vive en la otra coleccion.
    'id_producto',          pv.id_producto,
    'id_producto_variante', o.id_producto_variante,

    -- Copiados para poder listar "mis ofertas" en el panel del vendedor sin
    -- ir al documento del producto por cada fila.
    'nombre_producto',      p.nombre,
    'nombre_variante',      pv.nombre_variante,

    'vendedor', jsonb_build_object(
        'id_usuario', u.id_usuario,
        'usuario',    u.usuario,
        'nombre',     u.nombre,
        'apellido',   u.apellido
    ),

    -- Si es la oferta de la pagina. Se calcula aqui y no se deduce alla, para
    -- que la regla "el primer precio es el de la tienda" viva en un solo
    -- sitio: esta consulta y la de arriba.
    'es_tienda',  (o.id_usuario = (SELECT id_usuario FROM tienda)),

    'precio',     o.precio::text,
    'stock',      o.stock,
    'estado',     eo.estado_oferta_nombre,

    'fecha_creacion',      o.fecha_creacion,
    'fecha_actualizacion', o.fecha_actualizacion
)
FROM oferta o
JOIN productos_variantes pv ON pv.id_producto_variante = o.id_producto_variante
JOIN productos           p  ON p.id_producto           = pv.id_producto
JOIN usuarios            u  ON u.id_usuario            = o.id_usuario
JOIN estado_oferta       eo ON eo.id_estado_oferta     = o.id_estado_oferta
ORDER BY o.id_oferta;
