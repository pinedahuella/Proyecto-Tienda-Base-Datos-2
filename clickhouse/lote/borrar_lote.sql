-- borrar_lote.sql
-- Deshace un lote de generar_vistas.sql. Borra por la marca `lote` y por nada
-- mas.
--
--   export MSYS_NO_PATHCONV=1
--
--   docker exec -i mesh-clickhouse clickhouse-client \
--       --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
--       --database "$CLICKHOUSE_DB" \
--       --param_semilla=42 \
--       --multiquery < clickhouse/lote/borrar_lote.sql
--
-- Un solo parametro, la semilla, y de ahi sale la marca 'generado-<semilla>'.
--
--
-- EL BORRADO SON DOS MITADES, Y ESTA ES LA PARTE QUE HAY QUE LEER
-- ============================================================
-- `vistas_por_producto_dia` NO se vacia al borrar de `vista_producto`. Esto es
-- lo mas facil de olvidar de todo el directorio y no da ningun error.
--
-- El motivo esta en lo que una vista materializada de ClickHouse es. No es una
-- consulta que se vuelve a calcular cuando alguien la mira, y tampoco es una
-- copia que se sincroniza. Es un DISPARADOR SOBRE LA INSERCION. Cada vez que
-- entra un bloque de filas en `vista_producto`, la vista lo agrega y escribe el
-- resultado en la tabla del resumen. Mira lo que ENTRA, una vez, y nunca vuelve
-- a mirar la tabla de origen.
--
-- Asi que un DELETE sobre `vista_producto` no le llega. Las filas del resumen
-- se quedan enteras, con sus 832 estados de agregacion intactos, apuntando a
-- vistas que ya no existen en ningun sitio.
--
-- Y lo peor es como se ve eso. La tabla cruda queda limpia, con lo cual quien
-- compruebe con  SELECT count() FROM vista_producto  se lleva un cero y da el
-- borrado por hecho. El panel, que lee del resumen porque para eso existe el
-- resumen, sigue ensenando el producto inflado y la tendencia de un lote que
-- alguien cree haber borrado hace una semana. Los dos numeros son ciertos y se
-- contradicen, y no hay ningun mensaje que lo explique.
--
-- Por eso este archivo borra de las DOS, y por eso el PASO 3 vuelve a contarlas
-- las dos y falla si alguna quedo con filas.
--
--
-- POR QUE ALTER TABLE ... DELETE Y NO DELETE FROM
-- ============================================================
-- ClickHouse tiene desde hace unas versiones el DELETE FROM ligero, que marca
-- las filas como borradas con una mascara y las esconde al leer. Aqui se usa el
-- otro, la mutacion, que reescribe las partes de disco sin esas filas.
--
-- La razon es `vistas_por_producto_dia`, que es AggregatingMergeTree y guarda
-- estados de agregacion en vez de numeros. Sobre esa clase de tabla lo que se
-- quiere es que la parte se reescriba de verdad, y no que quede una mascara
-- encima de unos estados que despues se van a fusionar con los que entren
-- luego. La mutacion es mas cara y es la que deja el disco como si el lote no
-- hubiera existido.
--
--
-- Y POR QUE mutations_sync = 2, QUE ES LA TRAMPA DE VERDAD
-- ============================================================
-- Una mutacion en ClickHouse es ASINCRONA por defecto. El ALTER vuelve en
-- milisegundos con todo bien, la mutacion se queda encolada en
-- `system.mutations`, y las filas siguen ahi mientras tanto.
--
-- Sin ese ajuste, un script que borre y vuelva a sembrar en la misma corrida se
-- estrella contra la guardia de generar_vistas.sql diciendo que la semilla ya
-- existe, porque el borrado todavia no ha pasado. Y quien mire por su cuenta
-- vera las filas irse solas medio minuto despues, que es la clase de cosa que
-- hace desconfiar de la base entera.
--
-- Con mutations_sync = 2 el ALTER no vuelve hasta que la mutacion esta aplicada
-- en todas las replicas. Aqui hay una sola replica y bastaria con el 1, pero se
-- pone el 2 porque no cuesta nada hoy y es lo correcto el dia que haya dos.
--
--
-- TAMPOCO AQUI HAY TRANSACCION
-- ============================================================
-- Son cuatro mutaciones seguidas y no hay forma de agruparlas. Si el
-- contenedor se cae entre la segunda y la tercera, quedan dos tablas limpias y
-- dos con las filas del lote.
--
-- Eso no es grave y conviene saber por que. Este archivo es IDEMPOTENTE, o sea
-- que volver a correrlo con la misma semilla termina el trabajo sin quejarse.
-- Borrar algo que ya no esta borra cero filas y sale bien. Es al reves que
-- generar_vistas.sql, que necesita una guardia justamente porque repetirlo si
-- cambia el resultado.
--
--
-- LO QUE ESTE ARCHIVO NO PUEDE BORRAR
-- ============================================================
-- Nada que lleve  lote = 'real'. El WHERE de las cuatro mutaciones compara
-- contra 'generado-<semilla>', que nunca puede valer 'real' porque la semilla
-- entra tipada como UInt64 y el prefijo esta escrito en el archivo.
--
-- Eso importa porque las vistas de producto son el unico dato de las cuatro
-- tablas que NO se puede reconstruir. `evento_login` y `evento_registro` son
-- copias de PostgreSQL y se vuelven a copiar. Un clic en una ficha no se deriva
-- de nada y no esta guardado en ninguna otra parte, asi que borrarlo por
-- descuido es perderlo.
--
--
-- PARA BORRAR TODO LO GENERADO DE UNA VEZ
-- ============================================================
-- Este archivo borra UN lote nombrado, que es una peticion concreta. Barrer
-- todo lo generado no cabe en el parametro y se hace a mano, sabiendo lo que se
-- hace, con las mismas cuatro mutaciones cambiando la comparacion por
--
--   WHERE lote != 'real'
--
-- Se escribe asi y no con un LIKE 'generado-%' a proposito. Lo que hay que
-- proteger es lo real, y una marca nueva que alguien invente manana y que no
-- empiece por 'generado-' se quedaria dentro con el LIKE y fuera con esto.


-- ============================================================
-- PASO 1 -- que hay antes, contado
-- ============================================================
-- Se imprime primero para que quede el antes y el despues en la misma salida.
-- Un borrado que solo dice "hecho" no deja forma de saber si borro cuatro mil
-- filas o ninguna, y las dos cosas terminan igual de bien.

SELECT 'Antes de borrar' AS titulo FORMAT PrettyCompact;

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT tabla, filas
FROM
(
    SELECT 'vista_producto'          AS tabla, count() AS filas FROM vista_producto          WHERE lote = marca
    UNION ALL
    SELECT 'evento_login'            AS tabla, count() AS filas FROM evento_login            WHERE lote = marca
    UNION ALL
    SELECT 'evento_registro'         AS tabla, count() AS filas FROM evento_registro         WHERE lote = marca
    UNION ALL
    SELECT 'vistas_por_producto_dia' AS tabla, count() AS filas FROM vistas_por_producto_dia WHERE lote = marca
    UNION ALL
    SELECT 'carrito_producto' AS tabla, count() AS filas FROM carrito_producto WHERE lote = marca
    UNION ALL
    SELECT 'compra_producto' AS tabla, count() AS filas FROM compra_producto WHERE lote = marca
    UNION ALL
    SELECT 'devolucion_producto' AS tabla, count() AS filas FROM devolucion_producto WHERE lote = marca
    UNION ALL
    SELECT 'busqueda_realizada' AS tabla, count() AS filas FROM busqueda_realizada WHERE lote = marca
    UNION ALL
    SELECT 'busqueda_clic' AS tabla, count() AS filas FROM busqueda_clic WHERE lote = marca
)
ORDER BY tabla
FORMAT PrettyCompact;


-- ============================================================
-- PASO 2 -- las cuatro mutaciones
-- ============================================================
-- Las cuatro comparan por igualdad contra la marca completa. `lote` esta en el
-- ORDER BY de `vistas_por_producto_dia` y en ninguna de las otras tres, asi que
-- alli la mutacion sabe exactamente que partes tocar y en las otras tiene que
-- leerlas todas. Con los tamanos de este proyecto eso da igual, y decirlo aqui
-- ahorra que alguien lo descubra midiendo el dia que la tabla sea grande.
--
-- La primera es la cruda y la segunda es su resumen. Van pegadas y en ese
-- orden a proposito, para que se lean como lo que son, las dos mitades de un
-- solo borrado.

ALTER TABLE vista_producto
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE vistas_por_producto_dia
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE evento_login
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE evento_registro
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE carrito_producto
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE compra_producto
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE devolucion_producto
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE busqueda_realizada
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;

ALTER TABLE busqueda_clic
    DELETE WHERE lote = concat('generado-', toString({semilla:UInt64}))
    SETTINGS mutations_sync = 2;


-- ============================================================
-- PASO 3 -- el recuento, y falla si quedo algo
-- ============================================================
-- No se da por bueno el borrado porque las mutaciones no protestaran. Se cuenta
-- otra vez, y si queda una sola fila de la marca el archivo muere diciendolo.
--
-- Esta comprobacion vigila sobre todo la mitad del resumen. Un dia que alguien
-- quite la segunda mutacion por creerla redundante, esto lo dice en voz alta en
-- la misma corrida, en vez de que se descubra semanas despues mirando un panel
-- que ensena un producto inflado que ya nadie sembro.

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT throwIf(
    (SELECT count() FROM vista_producto          WHERE lote = marca) +
    (SELECT count() FROM vistas_por_producto_dia WHERE lote = marca) +
    (SELECT count() FROM evento_login            WHERE lote = marca) +
    (SELECT count() FROM evento_registro         WHERE lote = marca) +
    (SELECT count() FROM carrito_producto WHERE lote = marca) +
    (SELECT count() FROM compra_producto WHERE lote = marca) +
    (SELECT count() FROM devolucion_producto WHERE lote = marca) +
    (SELECT count() FROM busqueda_realizada WHERE lote = marca) +
    (SELECT count() FROM busqueda_clic WHERE lote = marca) > 0,
    concat('Quedaron filas del lote generado-', toString({semilla:UInt64}), ' despues de borrar. ',
           'Mira system.mutations en la base mesh_eventos, que ahi esta la que no termino')
)
FORMAT Null;

SELECT 'Despues de borrar' AS titulo FORMAT PrettyCompact;

WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT tabla, filas
FROM
(
    SELECT 'vista_producto'          AS tabla, count() AS filas FROM vista_producto          WHERE lote = marca
    UNION ALL
    SELECT 'evento_login'            AS tabla, count() AS filas FROM evento_login            WHERE lote = marca
    UNION ALL
    SELECT 'evento_registro'         AS tabla, count() AS filas FROM evento_registro         WHERE lote = marca
    UNION ALL
    SELECT 'vistas_por_producto_dia' AS tabla, count() AS filas FROM vistas_por_producto_dia WHERE lote = marca
    UNION ALL
    SELECT 'carrito_producto' AS tabla, count() AS filas FROM carrito_producto WHERE lote = marca
    UNION ALL
    SELECT 'compra_producto' AS tabla, count() AS filas FROM compra_producto WHERE lote = marca
    UNION ALL
    SELECT 'devolucion_producto' AS tabla, count() AS filas FROM devolucion_producto WHERE lote = marca
    UNION ALL
    SELECT 'busqueda_realizada' AS tabla, count() AS filas FROM busqueda_realizada WHERE lote = marca
    UNION ALL
    SELECT 'busqueda_clic' AS tabla, count() AS filas FROM busqueda_clic WHERE lote = marca
)
ORDER BY tabla
FORMAT PrettyCompact;

-- Y lo que queda en las cuatro tablas, del lote que sea. Sirve para ver de un
-- golpe que no se llevo por delante nada marcado como 'real' ni el lote de otra
-- semilla que alguien tuviera montado para una demostracion.

SELECT 'Lo que queda en la base, por marca' AS titulo FORMAT PrettyCompact;

SELECT lote, tabla, filas
FROM
(
    SELECT lote, 'vista_producto'          AS tabla, count() AS filas FROM vista_producto          GROUP BY lote
    UNION ALL
    SELECT lote, 'evento_login'            AS tabla, count() AS filas FROM evento_login            GROUP BY lote
    UNION ALL
    SELECT lote, 'evento_registro'         AS tabla, count() AS filas FROM evento_registro         GROUP BY lote
    UNION ALL
    SELECT lote, 'vistas_por_producto_dia' AS tabla, count() AS filas FROM vistas_por_producto_dia GROUP BY lote
    UNION ALL
    SELECT lote, 'carrito_producto'        AS tabla, count() AS filas FROM carrito_producto        GROUP BY lote
    UNION ALL
    SELECT lote, 'compra_producto'         AS tabla, count() AS filas FROM compra_producto         GROUP BY lote
    UNION ALL
    SELECT lote, 'devolucion_producto'     AS tabla, count() AS filas FROM devolucion_producto     GROUP BY lote
    UNION ALL
    SELECT lote, 'busqueda_realizada'      AS tabla, count() AS filas FROM busqueda_realizada      GROUP BY lote
    UNION ALL
    SELECT lote, 'busqueda_clic'           AS tabla, count() AS filas FROM busqueda_clic           GROUP BY lote
)
ORDER BY lote, tabla
FORMAT PrettyCompact;
