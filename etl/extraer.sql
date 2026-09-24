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


-- ============================================================
-- Lo que cambio al volverse multi-vendedor
-- ============================================================
-- El producto ya NO trae vendedor ni precio ni stock, porque dejaron de ser
-- suyos: son de cada oferta, y las ofertas viven en su propia coleccion.
--
-- Lo unico que se queda embebido de las ofertas son cinco numeros calculados
-- y una bandera:
--
--   precio_tienda   el precio de la tienda, que es el que se ensena en la
--                   pagina. Lo pidio el profesor: el primero siempre es el de
--                   la pagina.
--   precio_desde    el mas barato al que se ofrece, de cualquier vendedor
--                   activo. Es el que usa el FILTRO de precio del buscador:
--                   la tarjeta ensena uno y se puede pagar otro. No mira el
--                   stock: de la disponibilidad se encargan los de abajo.
--   stock_tienda    unidades que tiene la tienda
--   stock_total     unidades entre TODOS los vendedores activos
--   total_ofertas   cuantos vendedores distintos la tienen activa
--   hay_descuento   true si alguna oferta activa, de cualquier vendedor, tiene
--                   un descuento puesto. Es lo que pinta la etiqueta de
--                   "con descuento" en la tarjeta sin traer las ofertas.
--
-- LOS DOS PRECIOS YA VAN CON EL DESCUENTO APLICADO. oferta.precio es el precio
-- de LISTA y oferta.porcentaje_descuento el % (NULL si no hay). El precio que
-- se paga no se guarda en ningun lado: se calcula en cada consulta con
--
--   ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2)
--
-- que es LA MISMA expresion que arma el backend en
-- backend/src/helpers/precio-descuento.ts (expresionPrecioFinal). Tiene que
-- ser la misma letra por letra: el backend recalcula estos campos en cada
-- venta (ProductosService.recalcularCamposCalculados) y este archivo en cada
-- arranque, y si las dos cuentas difirieran en un centavo el precio de la
-- tarjeta cambiaria segun quien escribio el documento la ultima vez. Sin
-- descuento da el precio de lista tal cual, con sus dos decimales.
--
-- Los tres primeros van tambien dentro de cada variante. En el padre son
-- SUMAS de sus variantes: la tarjeta del catalogo ensena un producto, no una
-- variante. hay_descuento tambien va en cada variante, y el del padre es true
-- si alguna de sus variantes lo tiene.
--
-- Se embeben porque la LISTA del catalogo los necesita en cada tarjeta, y sin
-- ellos habria que consultar la coleccion de ofertas una vez por producto de
-- la pagina. Las ofertas completas no: cambian en cada venta, y meterlas aqui
-- obligaria a reescribir el documento entero del producto cada vez que alguien
-- compra. Ver el apartado de embeber o referenciar en docs/base-de-datos.md.
--
-- Son una COPIA y hay que recalcularlas: si un vendedor cambia su precio, pone
-- o quita un descuento o se queda sin unidades, los seis quedan viejos hasta
-- la proxima corrida del ETL o hasta que el backend los actualice.

-- Las fechas salen con la zona del cliente. Fijandola aqui, el mismo producto
-- extraido desde dos maquinas da el mismo texto, y las comparaciones que hace
-- el ETL para detectar cambios no dependen de quien lo corrio.
SET TIME ZONE 'UTC';

-- El dinero sale como texto, no como numero. JSON solo tiene el numero de
-- punto flotante, que redondea; el ETL lo vuelve decimal al escribirlo en
-- Mongo. De paso, comparar texto es exacto: no hay forma de que dos precios
-- iguales parezcan distintos por el ultimo decimal.


-- Quien es la tienda. Es la unica regla de negocio que esta consulta necesita
-- saber, y va aqui arriba para que se vea de una: la cuenta con este correo
-- es la de la pagina, y su precio es el que se ensena.
WITH tienda AS (
    SELECT id_usuario FROM usuarios WHERE correo_electronico = 'tienda@mesh.com'
),
activa AS (
    SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'activa'
)

SELECT jsonb_build_object(

    -- El estado vivo del producto. Es lo que se ve en el catalogo.
    'id_producto',    p.id_producto,
    'nombre',         p.nombre,
    'descripcion',    p.descripcion,
    'fecha_creacion', p.fecha_creacion,
    'estado',         ep.estado_producto_nombre,

    -- La categoria se embebe porque se lee junto con el producto y es pocos
    -- campos. Del padre solo interesa el nombre, para poder ensenar
    -- "Electronica > Laptops" sin una segunda consulta.
    --
    -- Ya no lleva porcentaje_comision: la comision salio del alcance.
    'categoria', jsonb_build_object(
        'id_categoria',    c.id_categoria,
        'nombre',          c.nombre,
        'categoria_padre', cp.nombre
    ),

    -- El precio de la pagina: el de la tienda. Si el producto tiene varias
    -- variantes, el menor de los suyos, que es el que va en la tarjeta. Con el
    -- descuento de la tienda aplicado, si tiene uno.
    'precio_tienda', (
        SELECT min(ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2))::text
        FROM oferta o
        JOIN productos_variantes pv2 ON pv2.id_producto        = o.id_producto_mongo
                                    AND pv2.id_producto_variante = o.id_producto_variante_mongo
        WHERE pv2.id_producto = p.id_producto
          AND o.id_usuario = (SELECT id_usuario FROM tienda)
    ),

    -- El precio mas barato al que se ofrece, de cualquier vendedor activo.
    --
    -- Va aparte de precio_tienda y no lo reemplaza, porque contestan dos
    -- preguntas distintas. La tarjeta ENSENA precio_tienda, que es la regla del
    -- profesor. Pero el filtro de precio del buscador tiene que usar este: si
    -- alguien busca "hasta Q4000" y la tienda pide 4100 mientras otro vendedor
    -- lo tiene en 3856, el producto SI le sirve y no puede quedar fuera.
    --
    -- NO lleva la condicion de tener unidades, y es a proposito: si la
    -- llevara, un rango de precio estaria filtrando ademas por
    -- disponibilidad sin que nadie lo pida, y para eso ya estan stock_total y
    -- stock_tienda. Cada filtro contesta UNA pregunta y se combinan; mezclarlos
    -- deja al buscador escondiendo resultados por un motivo que no se ve.
    --
    -- El minimo se toma DESPUES de aplicar el descuento de cada oferta: la mas
    -- barata es la que de verdad se paga menos, no la de precio de lista mas
    -- bajo.
    --
    -- Sale NULL solo cuando el producto no tiene ninguna oferta activa.
    'precio_desde', (
        SELECT min(ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2))::text
        FROM oferta o
        WHERE o.id_producto_mongo = p.id_producto
          AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
    ),

    -- Las existencias, SUMADAS sobre todas las variantes del producto. Son
    -- campos del padre a proposito: la tarjeta del catalogo ensena un producto,
    -- no una variante, y sin ellos no se puede filtrar por disponibilidad sin
    -- consultar la coleccion de ofertas una vez por tarjeta.
    --
    -- Las dos cuentan SOLO ofertas activas, porque las dos significan lo mismo:
    -- unidades que se pueden comprar hoy. Una oferta pausada tiene stock y no
    -- se puede comprar; contarla haria que el filtro "disponible" mintiera.
    'stock_tienda', (
        SELECT coalesce(sum(o.stock), 0)
        FROM oferta o
        JOIN productos_variantes pv2 ON pv2.id_producto        = o.id_producto_mongo
                                    AND pv2.id_producto_variante = o.id_producto_variante_mongo
        WHERE pv2.id_producto = p.id_producto
          AND o.id_usuario = (SELECT id_usuario FROM tienda)
          AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
    ),

    'stock_total', (
        SELECT coalesce(sum(o.stock), 0)
        FROM oferta o
        JOIN productos_variantes pv2 ON pv2.id_producto        = o.id_producto_mongo
                                    AND pv2.id_producto_variante = o.id_producto_variante_mongo
        WHERE pv2.id_producto = p.id_producto
          AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
    ),

    -- Cuantos vendedores distintos lo tienen activo. Cuenta vendedores y no
    -- filas: uno que oferte tres variantes del mismo producto es un vendedor,
    -- no tres.
    'total_ofertas', (
        SELECT count(DISTINCT o.id_usuario)
        FROM oferta o
        JOIN productos_variantes pv2 ON pv2.id_producto        = o.id_producto_mongo
                                    AND pv2.id_producto_variante = o.id_producto_variante_mongo
        WHERE pv2.id_producto = p.id_producto
          AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
    ),

    -- Si alguna oferta activa del producto tiene descuento. Mismo bool_or que
    -- el backend, con la misma condicion (activa y con porcentaje puesto), y
    -- sin mirar el stock ni quien vende: una oferta de otro vendedor con
    -- descuento tambien cuenta. En el backend el de la raiz es "alguna
    -- variante lo tiene"; aqui se pregunta de una sobre todas las ofertas del
    -- producto, que da lo mismo.
    --
    -- bool_or sobre cero filas da NULL, no false. El coalesce lo deja en
    -- false: un producto sin ofertas no tiene descuento, y el campo es un
    -- booleano, no uno de tres valores.
    'hay_descuento', (
        SELECT coalesce(bool_or(o.porcentaje_descuento IS NOT NULL), false)
        FROM oferta o
        WHERE o.id_producto_mongo = p.id_producto
          AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
    ),

    -- La nota del producto y cuantas resenas la sostienen. Son el SEXTO y el
    -- SEPTIMO numero derivado que se embebe, y van pegados al grupo de los
    -- cinco de arriba porque son de la misma clase: valores que la LISTA del
    -- catalogo necesita en cada tarjeta y que, sin ellos, obligarian a
    -- preguntar una vez por producto de la pagina.
    --
    -- Les vale entera la advertencia que la cabecera ya dejo escrita para los
    -- cinco primeros: son una COPIA y quedan viejos hasta la proxima corrida
    -- del ETL. Una resena escrita hace un minuto no mueve esta nota. No es un
    -- defecto de la consulta, es el precio de tenerla embebida.
    --
    -- VAN COMO NUMERO Y NO COMO TEXTO, que es la unica diferencia con los cinco
    -- de arriba. El dinero sale con ::text porque el punto flotante de JSON
    -- redondea y porque comparar texto es exacto; ninguno de los dos motivos
    -- aplica aqui. Una nota de 1 a 5 con dos decimales cabe exacta en un
    -- double, asi que no hay precision que perder. Y sobre todo hay algo que
    -- ganar: estos dos campos existen para FILTRAR y ORDENAR. Si
    -- resenas_promedio fuera texto, un "de 4 estrellas para arriba" y un orden
    -- por nota en Mongo compararian una cadena contra un numero, y eso no da
    -- error: devuelve el resultado equivocado en silencio, que es peor. Por eso
    -- tampoco entran en CAMPOS_DECIMALES de etl/cargar.js, que es la lista
    -- blanca de lo que se convierte a NumberDecimal al escribir en Mongo: esa
    -- lista es solo para el dinero, y dejar estos dos fuera es la decision, no
    -- un olvido.
    --
    -- POR QUE SON DOS CAMPOS Y NO UNO. El 0 de resenas_promedio NO es una nota,
    -- es la ausencia de notas. resena.calificacion es smallint CHECK BETWEEN 1
    -- AND 5, asi que un promedio de verdad nunca puede dar 0 y ese 0 solo puede
    -- significar que nadie califico el producto. Se elige 0 y no null para
    -- decir lo mismo que ya devuelve el backend en su resumen de resenas, y no
    -- dos cosas distintas segun a quien se le pregunte. La consecuencia hay que
    -- tenerla presente al consultar: quien filtre por nota minima tiene que
    -- exigir ademas resenas_total mayor que 0, o los productos sin ninguna
    -- resena se le cuelan por DEBAJO de los de una estrella en vez de quedarse
    -- fuera.
    --
    -- QUE ESTA PROMEDIANDO, que no es obvio. La resena es de un VENDEDOR sobre
    -- un PRODUCTO, no del producto solo; esta explicado en la cabecera de
    -- migrations/011_resenas.sql. Este promedio, entonces, MEZCLA vendedores:
    -- una queja de envio de uno le baja la nota al producto entero. Esta
    -- decidido asi a proposito y ya quedo escrito en el apartado QUE SE ESTA
    -- CALIFICANDO de la cabecera de frontend/src/lib/Resenas.svelte (se busca
    -- por ese titulo y no por numero de linea, que se corre en cuanto alguien
    -- edite el archivo). Amazon separa la nota del producto de la del
    -- vendedor; aqui van juntas.
    --
    -- DOS SUBCONSULTAS Y NO UNA SOLA CON DOS AGREGADOS porque
    -- jsonb_build_object necesita un escalar por valor, y porque el archivo
    -- entero esta escrito con una subconsulta escalar por clave: ese es el
    -- patron y es lo que lo deja leerse de corrido. Lo que cuesta son dos
    -- recorridos del mismo indice idx_resena_producto sobre id_producto_mongo,
    -- que es barato; partirlo en un LATERAL para ahorrar uno romperia el patron
    -- del archivo a cambio de un ahorro que nadie midio.
    --
    -- EL REDONDEO NO COINCIDE SIEMPRE CON EL DEL BACKEND, y conviene decirlo de
    -- frente. armarResumen, en
    -- backend/src/services/resenas/resenas.service.ts, calcula el promedio en
    -- JavaScript con Math.round((suma / total) * 100) / 100 sobre un double;
    -- aqui se calcula con round(avg(...), 2) sobre numeric.
    --
    -- EL MECANISMO, que es lo que no caduca. Los dos coinciden salvo en el
    -- empate exacto de medio centesimo, y ni siquiera en todos: solo cuando el
    -- double no logra representar ese empate. El producto suma/total*100 cae
    -- entonces una pizca POR DEBAJO del .5, y Math.round baja; el numeric no
    -- pierde nada, ve el empate entero y round sube. Cuando el double si cae
    -- justo en el .5, los dos suben y dan el mismo numero.
    --
    -- Esto no es una cifra de la base ni depende de cuantas resenas haya hoy:
    -- es aritmetica, y se comprueba entera en dos comandos que no tocan datos.
    -- Con 40 resenas que sumen 169 -- nueve de cinco estrellas y treinta y una
    -- de cuatro -- el promedio exacto es 4.225, y los dos motores discrepan:
    --
    --   node -e "console.log(Math.round((169/40)*100)/100)"          -> 4.22
    --   psql -U meme -d mesh -qtAX -c "SELECT round(169::numeric/40, 2)"
    --                                                                -> 4.23
    --
    -- El culpable se ve pidiendole a node el paso de en medio: (169/40)*100 no
    -- da 422.5 sino 422.49999999999994, y de ahi el 4.22.
    --
    -- Y NO PASA EN TODOS LOS EMPATES, que es la parte util: con 40 resenas que
    -- sumen 121 los dos dicen 3.03. O sea que no se puede confiar ni en que
    -- coincidan ni en que difieran, y por eso no se usa uno para verificar al
    -- otro. Con las mismas 40 resenas si divergen las sumas 41, 51, 87, 97,
    -- 169, 179, 189 y 199, comprobadas con los dos comandos de arriba
    -- cambiando el 169.
    --
    -- No se fuerza a que coincidan; lo que se reparte es quien manda para que.
    -- El numero que se le ENSENA a la persona sale del backend en vivo,
    -- calculado sobre las resenas de ese momento; este de aqui es el que se usa
    -- para FILTRAR y ORDENAR el catalogo. No son la misma verdad y no tienen
    -- por que serlo.
    'resenas_promedio', (
        SELECT coalesce(round(avg(r.calificacion), 2), 0)
        FROM resena r
        WHERE r.id_producto_mongo = p.id_producto
    ),
    'resenas_total', (
        SELECT count(*)
        FROM resena r
        WHERE r.id_producto_mongo = p.id_producto
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
    -- hereda. Se convierte aqui, una vez al escribir, y no en cada consulta.
    --
    -- Y una caracteristica de tipo lista sale como UNA entrada con un array
    -- adentro, no como cinco entradas repetidas. Las filas repetidas son como
    -- vive en el relacional por la 1FN; un documento si puede guardar varios
    -- valores en un campo. De ahi el GROUP BY.
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
    --
    -- Ya no traen precio ni stock. Traen los dos calculados, por el mismo
    -- motivo que el producto: la ficha ensena un precio por variante antes de
    -- que nadie despliegue la lista de vendedores.
    'variantes', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'id_producto_variante', pv.id_producto_variante,
                   'nombre_variante',      pv.nombre_variante,
                   'descripcion',          pv.descripcion,
                   'fecha_creacion',       pv.fecha_creacion,
                   'estado',               ev.estado_variante_nombre,

                   'precio_tienda', (
                       SELECT ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2)::text
                       FROM oferta o
                       WHERE o.id_producto_mongo          = p.id_producto
                         AND o.id_producto_variante_mongo = pv.id_producto_variante
                         AND o.id_usuario = (SELECT id_usuario FROM tienda)
                   ),
                   -- Lo mismo por variante. Aqui stock_tienda NO es una suma:
                   -- el UNIQUE de oferta garantiza que la tienda tiene a lo
                   -- sumo una por variante.
                   'precio_desde', (
                       SELECT min(ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2))::text
                       FROM oferta o
                       WHERE o.id_producto_mongo          = p.id_producto
                         AND o.id_producto_variante_mongo = pv.id_producto_variante
                         AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                   ),
                   'stock_tienda', coalesce((
                       SELECT o.stock FROM oferta o
                       WHERE o.id_producto_mongo          = p.id_producto
                         AND o.id_producto_variante_mongo = pv.id_producto_variante
                         AND o.id_usuario = (SELECT id_usuario FROM tienda)
                         AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                   ), 0),
                   'stock_total', (
                       SELECT coalesce(sum(o.stock), 0) FROM oferta o
                       WHERE o.id_producto_mongo          = p.id_producto
                         AND o.id_producto_variante_mongo = pv.id_producto_variante
                         AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                   ),
                   'total_ofertas', (
                       SELECT count(*) FROM oferta o
                       WHERE o.id_producto_mongo          = p.id_producto
                         AND o.id_producto_variante_mongo = pv.id_producto_variante
                         AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                   ),
                   'hay_descuento', (
                       SELECT coalesce(bool_or(o.porcentaje_descuento IS NOT NULL), false)
                       FROM oferta o
                       WHERE o.id_producto_mongo          = p.id_producto
                         AND o.id_producto_variante_mongo = pv.id_producto_variante
                         AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                   ),

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

    -- Los dos historiales van crudos y por separado, ordenados por fecha. Aqui
    -- no se mezclan: cada uno corre por su cuenta y con fechas distintas, y
    -- juntarlos es justo el trabajo de cargar.js. Se llaman "fecha" y no
    -- "fecha_creacion" para no confundir la fecha desde la que rige una
    -- version con la fecha en que nacio el producto.
    --
    -- El historial de la CATEGORIA ya no existe: era la tabla que guardaba la
    -- comision del dia de la venta. En su lugar, cada fila del historial del
    -- producto dice en que categoria estaba ese dia, que ademas arregla un
    -- hueco viejo: antes, mover un producto de categoria reescribia su pasado.
    'historial_producto', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'nombre',      ph.nombre,
                   'descripcion', ph.descripcion,
                   'categoria',   jsonb_build_object(
                       'id_categoria', hc.id_categoria,
                       'nombre',       hc.nombre
                   ),
                   'fecha',       ph.fecha_creacion
               ) ORDER BY ph.fecha_creacion), '[]'::jsonb)
        FROM productos_historial ph
        JOIN categorias hc ON hc.id_categoria = ph.id_categoria
        WHERE ph.id_producto = p.id_producto
    ),

    -- Sin precio: el precio dejo de ser del catalogo. Lo que queda es como se
    -- llamaba y que decia la presentacion ese dia.
    'historial_variantes', (
        SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'id_producto_variante', vh.id_producto_variante,
                   'nombre_variante',      vh.nombre_variante,
                   'descripcion',          vh.descripcion,
                   'fecha',                vh.fecha_creacion
               ) ORDER BY vh.fecha_creacion), '[]'::jsonb)
        FROM productos_variantes_historial vh
        JOIN productos_variantes pvh
             ON pvh.id_producto_variante = vh.id_producto_variante
        WHERE pvh.id_producto = p.id_producto
    )
)
FROM productos p
JOIN estado_producto ep ON ep.id_estado_producto = p.id_estado_producto
JOIN categorias      c  ON c.id_categoria        = p.id_categoria
-- LEFT por precaucion: hoy el trigger del 003 impide que un producto cuelgue
-- de una raiz, pero un LEFT no cuesta nada y evita que un dato raro haga
-- desaparecer el producto entero de la extraccion sin decir por que.
LEFT JOIN categorias cp ON cp.id_categoria       = c.id_categoria_padre
ORDER BY p.id_producto;
