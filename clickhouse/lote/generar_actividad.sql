-- generar_actividad.sql
-- Siembra el resto del EMBUDO de eventos en ClickHouse, deterministico por
-- semilla, encima de las vistas que ya sembro generar_vistas.sql con esa misma
-- semilla:
--
--   vista_producto  (ya sembrada)
--        |  una de cada seis, si quien miro tenia cuenta
--        v
--   carrito_producto
--        |  una de cada tres
--        v
--   compra_producto
--        |  una de cada ocho, dias despues
--        v
--   devolucion_producto
--
--   vista con origen 'buscador'  ->  busqueda_clic   ->  busqueda_realizada
--   mas busquedas que no terminan en clic, y algunas que no encuentran nada
--
-- Por que existe. Hasta el 2026-09-18 las seis tablas de eventos estaban asi:
-- busqueda_realizada y busqueda_clic en CERO, compra y devolucion con las dos
-- filas que dejo alguien probando, carrito con cuatro. Dos de los seis rankings
-- de tendencias no ensenaban nada y los otros cuatro casi nada, y la demo
-- arrancaba vacia. Un panel contra una tabla vacia no se puede ensenar.
--
-- Y una trampa que estas tablas tenian y que este archivo arregla: las vistas
-- que sembro generar_vistas.sql llevan fecha de cuando se corrio (las de la
-- semilla 42, del 24 de agosto al 6 de septiembre), y los rankings miran los
-- ULTIMOS 7 DIAS por defecto. Con datos de hace dos semanas la tabla tenia 3882
-- filas y la pantalla salia vacia. Todo lo de aqui sale de las vistas, asi que
-- hereda su fecha: la ventana del lote la decide cuando se siembran las vistas,
-- y para una demo hay que sembrarlas el mismo dia. Ver clickhouse/lote/README.md.
--
--
-- LO QUE HEREDA DE generar_vistas.sql, SIN CAMBIAR NADA
-- ============================================================
--   * TODA fila lleva lote = 'generado-<semilla>'. 'real' queda para lo que manda
--     el portal y para lo que trae etl/cargar_compras.sh desde PostgreSQL.
--   * cityHash64 y no rand(): la misma semilla dibuja el mismo sorteo.
--   * Ninguna fila a nombre de una cuenta real. Las cuentas salen de las vistas,
--     que ya viven en los ids altisimos (1000000 y 2000000 en adelante).
--   * Productos del 1 al 100, todos con ficha que carga.
--   * CLICKHOUSE NO TIENE TRANSACCION: toda guardia corre ANTES del primer
--     INSERT, y hay UN SOLO INSERT por tabla (los de busqueda_realizada van
--     unidos con UNION ALL).
--
--
-- LO QUE NO ES REAL Y HAY QUE DECIRLO
-- ============================================================
--   id_oferta   vale lo mismo que id_producto. No apunta a ninguna oferta de
--               PostgreSQL: los generados no compraron nada de verdad. Ningun
--               ranking lo mira, pero quien lo lea que no lo cruce contra `oferta`.
--   id_pedido   entre 3000000000 y 3999999999, muy por encima de cualquier pedido
--               real, por la misma razon que las cuentas.
--   terminos    salen de una lista fija por rango de productos, aproximada al
--               catalogo. Un termino y un producto que coinciden son coherentes;
--               que el producto 12 sea de verdad un "celular" no esta comprobado
--               para cada uno de los cien.
--
--
-- Como se corre
-- ============================================================
--   export MSYS_NO_PATHCONV=1
--   docker exec -i mesh-clickhouse clickhouse-client \
--       --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
--       --database "$CLICKHOUSE_DB" --param_semilla=42 \
--       --multiquery < clickhouse/lote/generar_actividad.sql
--
--   --database SIEMPRE: sin ella el cliente entra a `default`, donde las tablas
--   tambien existen, el INSERT sale bien y el backend no ve una fila.
--
-- Solo lleva --param_semilla: el volumen lo decide el de las vistas. arrancar.ps1
-- lo corre solo despues de -Vistas. Se deshace con borrar_lote.sql, la misma
-- semilla, que ahora borra las nueve tablas.


-- ============================================================
-- PASO 0 -- LA GUARDIA, y corre antes de tocar nada
-- ============================================================
-- Dos cosas la pueden detener, y las dos son un error de quien la corre:
--
--   1. No hay vistas de esa semilla. Sin ellas no hay de donde derivar el
--      embudo, y el archivo entero correria y no escribiria ni una fila, en
--      silencio.
--   2. Ya hay actividad de esa semilla. Correrlo dos veces DUPLICA el lote, igual
--      que generar_vistas.sql: el sorteo es el mismo y las filas se suman.
SELECT throwIf(
    count() = 0,
    concat('No hay vistas con lote generado-', toString({semilla:UInt64}),
           '. Siembra primero con  arrancar.ps1 -Vistas <n> -Semilla ', toString({semilla:UInt64}))
) AS hay_vistas
FROM vista_producto
WHERE lote = concat('generado-', toString({semilla:UInt64}));

SELECT throwIf(
    count() > 0,
    -- El mensaje tiene que ser una CONSTANTE: throwIf rechaza uno que dependa de
    -- las filas (Code 44, "must be constant"), asi que aqui no se puede decir
    -- cuantas hay. Solo entra el parametro, que si es constante.
    concat('Ya hay actividad generada con la semilla ', toString({semilla:UInt64}),
           '. Borrala con  arrancar.ps1 -BorrarVistas ',
           toString({semilla:UInt64}), '  y vuelve a sembrar.')
) AS ya_sembrada
FROM
(
    SELECT 1 FROM carrito_producto    WHERE lote = concat('generado-', toString({semilla:UInt64}))
    UNION ALL
    SELECT 1 FROM compra_producto     WHERE lote = concat('generado-', toString({semilla:UInt64}))
    UNION ALL
    SELECT 1 FROM devolucion_producto WHERE lote = concat('generado-', toString({semilla:UInt64}))
    UNION ALL
    SELECT 1 FROM busqueda_realizada  WHERE lote = concat('generado-', toString({semilla:UInt64}))
    UNION ALL
    SELECT 1 FROM busqueda_clic       WHERE lote = concat('generado-', toString({semilla:UInt64}))
);


-- ============================================================
-- PASO 1 -- carrito_producto
-- ============================================================
-- Una vista de cada seis, y solo las de quien tenia cuenta: el carrito la exige,
-- y por eso la tabla no tiene columna `sesion`. Cae entre 1 y 30 minutos despues
-- de mirar, con 1 a 3 unidades.
--
-- Si la hora que sale es futura, la fila se descarta y no se corrige: una
-- vista de hace dos minutos no puede haber terminado en un carrito de dentro de
-- veinte.
INSERT INTO carrito_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, ip, lote)
WITH
    {semilla:UInt64} AS semilla,
    concat('generado-', toString(semilla)) AS marca,
    toUnixTimestamp64Milli(fecha) AS t
SELECT
    fecha + toIntervalSecond(60 + cityHash64(semilla, 'carrito-hora', sesion, id_producto, t) % 1740) AS f,
    id_producto,
    id_producto AS id_oferta,
    assumeNotNull(id_usuario) AS usuario,
    toUInt32(1 + cityHash64(semilla, 'carrito-cantidad', sesion, id_producto, t) % 3) AS cantidad,
    ip,
    marca
FROM vista_producto
WHERE lote = marca
  AND id_usuario IS NOT NULL
  AND cityHash64(semilla, 'carrito-elige', sesion, id_producto, t) % 6 = 0
  AND f <= now64(3);


-- ============================================================
-- PASO 2 -- compra_producto
-- ============================================================
-- Una de cada tres carritos termina en compra, entre 5 minutos y 2 horas
-- despues, con la misma cantidad. Sale de las filas de carrito de ESTA semilla,
-- que acaban de escribirse, y por eso el embudo es coherente: no hay compra sin
-- carrito ni carrito sin vista.
INSERT INTO compra_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip, lote)
WITH
    {semilla:UInt64} AS semilla,
    concat('generado-', toString(semilla)) AS marca,
    toUnixTimestamp64Milli(fecha) AS t
SELECT
    fecha + toIntervalSecond(300 + cityHash64(semilla, 'compra-hora', id_usuario, id_producto, t) % 6900) AS f,
    id_producto,
    id_oferta,
    id_usuario,
    cantidad,
    toUInt64(3000000000 + cityHash64(semilla, 'pedido', id_usuario, id_producto, t) % 1000000000) AS id_pedido,
    ip,
    marca
FROM carrito_producto
WHERE lote = marca
  AND cityHash64(semilla, 'compra-elige', id_usuario, id_producto, t) % 3 = 0
  AND f <= now64(3);


-- ============================================================
-- PASO 3 -- devolucion_producto
-- ============================================================
-- Una de cada ocho compras, entre 1 y 3 dias despues, con el MISMO id_pedido que
-- la compra de la que sale. Solo se escribe cuando el pedido "estaba comprado",
-- que aqui es por construccion: sale de compra_producto.
INSERT INTO devolucion_producto (fecha, id_producto, id_oferta, id_usuario, cantidad, id_pedido, ip, lote)
WITH
    {semilla:UInt64} AS semilla,
    concat('generado-', toString(semilla)) AS marca
SELECT
    fecha + toIntervalSecond(86400 + cityHash64(semilla, 'devolucion-hora', id_pedido) % 172800) AS f,
    id_producto,
    id_oferta,
    id_usuario,
    cantidad,
    id_pedido,
    ip,
    marca
FROM compra_producto
WHERE lote = marca
  AND cityHash64(semilla, 'devolucion-elige', id_pedido) % 8 = 0
  AND f <= now64(3);


-- ============================================================
-- PASO 4 -- busqueda_clic
-- ============================================================
-- Cada vista que llego DESDE el buscador (origen 'buscador') es un clic sobre un
-- resultado. El clic cae un par de segundos antes de la vista, y su termino sale
-- del rango del producto. La posicion esta cargada hacia el principio, como en
-- cualquier buscador: casi todos los clics son sobre los primeros resultados.
--
-- Los terminos, por rango de id_producto. Aproximados al catalogo, no exactos:
-- ver la cabecera.
INSERT INTO busqueda_clic (fecha, termino, id_producto, posicion, id_usuario, sesion, lote)
WITH
    {semilla:UInt64} AS semilla,
    concat('generado-', toString(semilla)) AS marca,
    toUnixTimestamp64Milli(fecha) AS t,
    multiIf(id_producto <= 9, 1,  id_producto <= 13, 2,  id_producto <= 20, 3,
            id_producto <= 26, 4, id_producto <= 33, 5,  id_producto <= 39, 6,
            id_producto <= 45, 7, id_producto <= 51, 8,  id_producto <= 56, 9,
            id_producto <= 62, 10, id_producto <= 68, 11, 12) AS banda,
    [
        ['laptop', 'computadora', 'notebook'],
        ['telefono', 'celular', 'smartphone'],
        ['audifonos', 'audifonos bluetooth', 'auriculares'],
        ['monitor', 'pantalla', 'monitor gamer'],
        ['cafetera', 'licuadora', 'olla', 'cocina'],
        ['silla', 'mesa', 'escritorio', 'muebles'],
        ['lampara', 'luz led', 'iluminacion'],
        ['camisa', 'camisa de vestir', 'polo'],
        ['pantalon', 'jeans', 'pantalon de vestir'],
        ['zapatos', 'botas', 'sandalias'],
        ['futbol', 'balon', 'guantes de portero'],
        ['libro', 'perfume', 'serum', 'pesas', 'bicicleta']
    ] AS vocabulario,
    vocabulario[banda] AS terminos
SELECT
    fecha - toIntervalSecond(2) AS f,
    terminos[1 + cityHash64(semilla, 'termino', sesion, id_producto, t) % length(terminos)] AS termino,
    id_producto,
    toUInt16(least(10, 1 + floor(pow((cityHash64(semilla, 'posicion', sesion, id_producto, t) % 1000) / 1000., 2) * 10))) AS posicion,
    id_usuario,
    sesion,
    marca
FROM vista_producto
WHERE lote = marca
  AND origen = 'buscador';


-- ============================================================
-- PASO 5 -- busqueda_realizada
-- ============================================================
-- Tres cosas en UN SOLO INSERT (regla 2 de la cabecera de generar_vistas.sql):
--
--   a. la busqueda de cada clic, unos segundos antes que el. Sin esta, habria
--      clics sobre terminos que nadie busco, que es imposible;
--   b. busquedas que NO terminan en clic (una de cada tres vistas de cualquier
--      origen), con el termino del producto que la misma sesion miro despues;
--   c. busquedas que no encuentran nada: terminos de cosas que el catalogo no
--      tiene. Son las que mas le sirven a quien mire el panel, porque son lo que
--      la gente busca y no puede comprar.
INSERT INTO busqueda_realizada (fecha, termino, resultados, id_usuario, sesion, lote)
WITH
    {semilla:UInt64} AS semilla,
    concat('generado-', toString(semilla)) AS marca,
    ['tablet', 'consola', 'smartwatch', 'dron', 'refrigeradora', 'bicicleta electrica', 'camara'] AS sin_catalogo
SELECT f, termino, resultados, id_usuario, sesion, marca
FROM
(
    -- a. las de los clics
    SELECT
        fecha - toIntervalSecond(4 + cityHash64(semilla, 'busca-antes', sesion, termino, toUnixTimestamp64Milli(fecha)) % 40) AS f,
        termino,
        toUInt32(3 + cityHash64(semilla, 'busca-resultados', termino) % 57) AS resultados,
        id_usuario,
        sesion
    FROM busqueda_clic
    WHERE lote = marca

    UNION ALL

    -- b. las que no terminan en clic
    WITH
        -- Los mismos rangos y terminos del paso 4. Se repiten aqui porque un WITH no
        -- cruza de una sentencia a otra, y si un dia se cambia una lista hay que
        -- cambiarla en los dos sitios. Y va DENTRO de esta rama y no arriba: un alias
        -- que usa una columna (id_producto) no se puede resolver desde una subconsulta
        -- (Code 1, "correlated column"), y solo esta rama lo necesita.
        multiIf(id_producto <= 9, 1,  id_producto <= 13, 2,  id_producto <= 20, 3,
                id_producto <= 26, 4, id_producto <= 33, 5,  id_producto <= 39, 6,
                id_producto <= 45, 7, id_producto <= 51, 8,  id_producto <= 56, 9,
                id_producto <= 62, 10, id_producto <= 68, 11, 12) AS banda,
        [
            ['laptop', 'computadora', 'notebook'],
            ['telefono', 'celular', 'smartphone'],
            ['audifonos', 'audifonos bluetooth', 'auriculares'],
            ['monitor', 'pantalla', 'monitor gamer'],
            ['cafetera', 'licuadora', 'olla', 'cocina'],
            ['silla', 'mesa', 'escritorio', 'muebles'],
            ['lampara', 'luz led', 'iluminacion'],
            ['camisa', 'camisa de vestir', 'polo'],
            ['pantalon', 'jeans', 'pantalon de vestir'],
            ['zapatos', 'botas', 'sandalias'],
            ['futbol', 'balon', 'guantes de portero'],
            ['libro', 'perfume', 'serum', 'pesas', 'bicicleta']
        ] AS vocabulario,
        vocabulario[banda] AS lista_del_producto,
        lista_del_producto[1 + cityHash64(semilla, 'sinclic-termino', sesion, id_producto) % length(lista_del_producto)] AS termino_sin_clic
    SELECT
        fecha - toIntervalSecond(30 + cityHash64(semilla, 'sinclic-antes', sesion, id_producto, toUnixTimestamp64Milli(fecha)) % 240) AS f,
        termino_sin_clic AS termino,
        toUInt32(2 + cityHash64(semilla, 'sinclic-resultados', termino_sin_clic) % 60) AS resultados,
        id_usuario,
        sesion
    FROM vista_producto
    WHERE lote = marca
      AND origen != 'buscador'
      AND cityHash64(semilla, 'sinclic-elige', sesion, id_producto, toUnixTimestamp64Milli(fecha)) % 3 = 0

    UNION ALL

    -- c. las que no encuentran nada
    SELECT
        fecha - toIntervalSecond(10 + cityHash64(semilla, 'nada-antes', sesion, toUnixTimestamp64Milli(fecha)) % 120) AS f,
        sin_catalogo[1 + cityHash64(semilla, 'nada-termino', sesion, toUnixTimestamp64Milli(fecha)) % length(sin_catalogo)] AS termino,
        toUInt32(0) AS resultados,
        id_usuario,
        sesion
    FROM vista_producto
    WHERE lote = marca
      AND cityHash64(semilla, 'nada-elige', sesion, id_producto, toUnixTimestamp64Milli(fecha)) % 25 = 0
);


-- ============================================================
-- PASO 6 -- el resumen, contado contra las tablas vivas
-- ============================================================
-- Lo que se ve al final es lo que quedo escrito, leido de las tablas y no de lo
-- que el archivo cree haber hecho, con el rango de fechas de cada tabla.
WITH concat('generado-', toString({semilla:UInt64})) AS marca
SELECT tabla, filas, desde, hasta
FROM
(
    SELECT 'vista_producto'       AS tabla, count() AS filas, min(fecha) AS desde, max(fecha) AS hasta FROM vista_producto       WHERE lote = marca
    UNION ALL
    SELECT 'carrito_producto'     AS tabla, count() AS filas, min(fecha) AS desde, max(fecha) AS hasta FROM carrito_producto     WHERE lote = marca
    UNION ALL
    SELECT 'compra_producto'      AS tabla, count() AS filas, min(fecha) AS desde, max(fecha) AS hasta FROM compra_producto      WHERE lote = marca
    UNION ALL
    SELECT 'devolucion_producto'  AS tabla, count() AS filas, min(fecha) AS desde, max(fecha) AS hasta FROM devolucion_producto  WHERE lote = marca
    UNION ALL
    SELECT 'busqueda_realizada'   AS tabla, count() AS filas, min(fecha) AS desde, max(fecha) AS hasta FROM busqueda_realizada   WHERE lote = marca
    UNION ALL
    SELECT 'busqueda_clic'        AS tabla, count() AS filas, min(fecha) AS desde, max(fecha) AS hasta FROM busqueda_clic        WHERE lote = marca
)
ORDER BY tabla
FORMAT PrettyCompact;
