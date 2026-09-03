-- ============================================================
-- ofertas_mongo.sql -- las ofertas de los productos que nacieron en Mongo
-- ============================================================
-- La segunda mitad de `mongo/lote/generar_lote_mongo.js`. Aquel crea los
-- documentos en MongoDB; este les da precio y stock de verdad, que viven aqui.
--
--
-- POR QUE LAS OFERTAS NO PUEDEN VIVIR EN MONGO
-- ============================================================
-- Es el ADR-2 y esta medido: el descuento de stock tiene que ser atomico para
-- no vender dos veces la ultima unidad, y eso lo sostiene un
-- SELECT ... FOR UPDATE de PostgreSQL. El documento de Mongo lleva cinco
-- numeros AGREGADOS (precio_tienda, precio_desde, stock_tienda, stock_total,
-- total_ofertas) para que la tarjeta del catalogo no tenga que preguntar por
-- cada producto de la pagina, pero esos son una COPIA para pintar. La verdad
-- de cuanto queda esta aqui.
--
--
-- POR QUE LOS PRECIOS LLEGAN EN UN ARCHIVO Y NO SE SORTEAN AQUI
-- ============================================================
-- Porque el documento de Mongo ya los lleva escritos. Si este archivo los
-- volviera a sortear harian falta dos implementaciones del mismo azar -- una en
-- JavaScript y otra en SQL -- que tienen que dar exactamente lo mismo, para
-- siempre. El dia que una cambie, el documento diria un precio y la oferta
-- otro, y nadie lo notaria hasta que alguien comparara la tarjeta con la ficha.
--
-- Un dato compartido no se puede desincronizar. Dos algoritmos si. Por eso el
-- generador de Mongo sortea una vez, lo escribe en un csv, y aqui se LEE.
--
--
-- COMO SE CORRE
-- ============================================================
-- El csv tiene que estar dentro del contenedor de PostgreSQL. Lo pone ahi
-- `arrancar.ps1 -ProductosMongo`, que lo saca de mesh-mongo y lo mete en
-- mesh-postgres con dos `docker cp`.
--
--   docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> \
--       -v ON_ERROR_STOP=1 \
--       -v csv=/tmp/mesh-lote-mongo.csv \
--       -f /migrations/lote/ofertas_mongo.sql
--
--
-- LO QUE ESTE ARCHIVO NO HACE
-- ============================================================
-- NO crea filas en `productos` ni en `productos_variantes`. Y no es un olvido:
-- es la diferencia entera entre los dos generadores. Estos productos viven solo
-- en Mongo, igual que los que publica un vendedor desde el panel, y `oferta`
-- los apunta por `id_producto_mongo` SIN llave foranea, que es justo para lo
-- que esa columna se llama asi.
--
-- Crear la fila en PostgreSQL los volveria del otro tipo, y ademas el ETL
-- empezaria a reescribir su documento y les pisaria lo que este lote les puso.


BEGIN;


-- ============================================================
-- Leer el csv
-- ============================================================
-- Tabla temporal con ON COMMIT DROP: si algo falla, no queda rastro.
CREATE TEMP TABLE lote_ofertas (
    id_producto  bigint,
    id_variante  bigint,
    correo       text,
    precio       numeric(12,2),
    stock        integer
) ON COMMIT DROP;

-- La ruta va FIJA y no en una variable de psql, y no es pereza: `\copy` es un
-- metacomando del cliente y NO expande `:'variable'` en la posicion del
-- archivo. Con `-v csv=...` el nombre llegaba vacio y el error era
-- "error: :: No such file or directory", que no dice en absoluto que el
-- problema sea la sustitucion.
--
-- El nombre fijo tampoco es un invento: es la misma convencion que ya usa el
-- ETL con /tmp/mesh-productos.json y /tmp/mesh-categorias.json.
\copy lote_ofertas FROM '/tmp/mesh-lote-mongo.csv' WITH (FORMAT csv)


-- ============================================================
-- Comprobar antes de escribir
-- ============================================================
DO $antes$
DECLARE
    v_filas     bigint;
    v_correos   bigint;
    v_choque    bigint;
BEGIN
    SELECT count(*) INTO v_filas FROM lote_ofertas;
    IF v_filas = 0 THEN
        RAISE EXCEPTION 'El csv no trajo ninguna fila'
            USING HINT = 'Corre antes mongo/lote/generar_lote_mongo.js, que es quien lo escribe.';
    END IF;

    -- Todo correo del csv tiene que existir. Si no, el INSERT de abajo
    -- simplemente no insertaria esas filas y el lote saldria corto sin decir
    -- por que: un JOIN que no encuentra no es un error, es cero filas.
    SELECT count(*) INTO v_correos
    FROM (SELECT DISTINCT correo FROM lote_ofertas) c
    WHERE NOT EXISTS (SELECT 1 FROM usuarios u WHERE u.correo_electronico = c.correo);

    IF v_correos > 0 THEN
        RAISE EXCEPTION '% correos del csv no existen en usuarios', v_correos
            USING HINT = 'El generador usa los correos del conjunto de datos. '
                         'Si la base no es la de la semilla, no coinciden.';
    END IF;

    -- Ninguno de estos productos puede tener fila en PostgreSQL. Si la tuviera,
    -- el ETL lo trataria como suyo y le reescribiria el documento, borrando lo
    -- que el lote de Mongo le puso. Es la comprobacion que distingue este
    -- generador del otro.
    SELECT count(*) INTO v_choque
    FROM productos p
    WHERE p.id_producto IN (SELECT DISTINCT id_producto FROM lote_ofertas);

    IF v_choque > 0 THEN
        RAISE EXCEPTION '% de esos id_producto YA existen en la tabla productos', v_choque
            USING HINT = 'Estos productos tienen que vivir solo en Mongo. Que exista '
                         'la fila aqui significa que el generador numero sobre un '
                         'rango que PostgreSQL ya habia usado.';
    END IF;

    -- Y ninguna oferta repetida: `oferta` tiene UNIQUE sobre
    -- (id_usuario, id_producto_mongo, id_producto_variante_mongo), asi que
    -- correr esto dos veces con el mismo csv chocaria. Vale mas decirlo aqui
    -- que dejar que lo diga la llave.
    SELECT count(*) INTO v_choque
    FROM lote_ofertas lo
    JOIN usuarios u ON u.correo_electronico = lo.correo
    JOIN oferta o ON o.id_usuario = u.id_usuario
                 AND o.id_producto_mongo = lo.id_producto
                 AND o.id_producto_variante_mongo = lo.id_variante;

    IF v_choque > 0 THEN
        RAISE EXCEPTION '% de esas ofertas ya existen', v_choque
            USING HINT = 'Este csv ya se aplico. Si querias otro lote, genera otro '
                         'con una semilla distinta.';
    END IF;

    RAISE NOTICE 'A crear: % ofertas sobre % productos de Mongo',
                 v_filas, (SELECT count(DISTINCT id_producto) FROM lote_ofertas);
END
$antes$;


-- ============================================================
-- Las ofertas
-- ============================================================
-- Ningun id se escribe a mano: el vendedor se resuelve por correo, que es la
-- regla de migrations/README.md.
--
-- fecha_aprobacion va puesta en todas porque todas nacen `activa`, y a ese
-- estado no se llega sin el visto bueno de la tienda. Una oferta activa con la
-- aprobacion en NULL es un estado que no puede existir, y las comprobaciones 4
-- y 5 del conjunto de datos lo exigen.
--
-- id_usuario_aprobo distingue los dos caminos de nacimiento: NULL para la
-- tienda (nace aprobada, no consta revisor) y el id de la tienda para los
-- demas (pasaron por la cola).
--
-- El trigger trg_oferta_registrar_precio se deja ENCENDIDO: escribe la fila de
-- nacimiento de precio_historial con now(), que es lo correcto porque estas
-- ofertas nacen hoy. Escribirla ademas a mano dejaria DOS filas de nacimiento
-- con el mismo precio y la misma fecha, y el historial mentiria sin que
-- ninguna comprobacion lo viera.
INSERT INTO oferta (
    id_producto_mongo, id_producto_variante_mongo, id_usuario,
    precio, stock, id_estado_oferta,
    fecha_creacion, fecha_actualizacion, fecha_aprobacion, id_usuario_aprobo)
SELECT lo.id_producto, lo.id_variante, u.id_usuario,
       lo.precio, lo.stock, eo.id_estado_oferta,
       now(), now(), now(),
       CASE WHEN lo.correo = 'tienda@mesh.com' THEN NULL ELSE ut.id_usuario END
FROM lote_ofertas lo
JOIN usuarios      u  ON u.correo_electronico = lo.correo
JOIN estado_oferta eo ON eo.estado_oferta_nombre = 'activa'
JOIN usuarios      ut ON ut.correo_electronico = 'tienda@mesh.com';


-- ============================================================
-- El kardex
-- ============================================================
-- Una fila de apertura por oferta con stock, derivada de la propia fila recien
-- escrita y no de una lista aparte. Sin ella, la comprobacion 1 del conjunto de
-- datos ("N ofertas tienen un stock que su kardex no explica") se pone roja la
-- PROXIMA vez que alguien recargue desde cero, no ahora, que es lo peor que
-- puede pasar.
--
-- Solo con stock > 0 porque stock_movimiento tiene CHECK (cantidad > 0).
INSERT INTO stock_movimiento (
    id_oferta, id_motivo_movimiento, id_usuario_modifico,
    cantidad, stock_resultante, fecha_movimiento)
SELECT o.id_oferta, mm.id_motivo_movimiento, o.id_usuario,
       o.stock, o.stock, o.fecha_creacion
FROM oferta o
JOIN motivo_movimiento mm ON mm.motivo_nombre = 'reposicion'
WHERE o.stock > 0
  AND o.id_producto_mongo IN (SELECT DISTINCT id_producto FROM lote_ofertas)
  AND NOT EXISTS (SELECT 1 FROM stock_movimiento sm WHERE sm.id_oferta = o.id_oferta);


-- ============================================================
-- Comprobarse a si mismo
-- ============================================================
DO $verificar$
DECLARE
    v_esperadas bigint;
    v_creadas   bigint;
    v_mal       bigint;
BEGIN
    SELECT count(*) INTO v_esperadas FROM lote_ofertas;

    SELECT count(*) INTO v_creadas
    FROM oferta o
    WHERE o.id_producto_mongo IN (SELECT DISTINCT id_producto FROM lote_ofertas);

    IF v_creadas <> v_esperadas THEN
        RAISE EXCEPTION 'Se esperaban % ofertas y hay %', v_esperadas, v_creadas;
    END IF;

    -- 1. El precio guardado es EXACTAMENTE el del csv. Esta es la comprobacion
    --    que hace que el documento de Mongo y la oferta digan lo mismo, que es
    --    la razon entera de pasar los precios por archivo.
    SELECT count(*) INTO v_mal
    FROM lote_ofertas lo
    JOIN usuarios u ON u.correo_electronico = lo.correo
    JOIN oferta o ON o.id_usuario = u.id_usuario
                 AND o.id_producto_mongo = lo.id_producto
                 AND o.id_producto_variante_mongo = lo.id_variante
    WHERE o.precio <> lo.precio OR o.stock <> lo.stock;

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas quedaron con un precio o un stock distinto al del csv', v_mal;
    END IF;

    -- 2. El stock cuadra con el kardex.
    SELECT count(*) INTO v_mal
    FROM oferta o
    LEFT JOIN (
        SELECT sm.id_oferta, sum(sm.cantidad * mm.valor) AS saldo
        FROM stock_movimiento sm
        JOIN motivo_movimiento mm ON mm.id_motivo_movimiento = sm.id_motivo_movimiento
        GROUP BY sm.id_oferta
    ) k ON k.id_oferta = o.id_oferta
    WHERE o.id_producto_mongo IN (SELECT DISTINCT id_producto FROM lote_ofertas)
      AND o.stock <> coalesce(k.saldo, 0);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas nuevas tienen un stock que su kardex no explica', v_mal;
    END IF;

    -- 3. El trigger de precio_historial corrio. No se da por hecho que exista:
    --    se comprueba que el precio de la oferta sea el ultimo de su historial,
    --    que es como se demuestra que de verdad se ejecuto.
    SELECT count(*) INTO v_mal
    FROM oferta o
    WHERE o.id_producto_mongo IN (SELECT DISTINCT id_producto FROM lote_ofertas)
      AND NOT EXISTS (
          SELECT 1 FROM precio_historial ph
          WHERE ph.id_oferta = o.id_oferta AND ph.precio = o.precio);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% ofertas nuevas no tienen su precio en precio_historial', v_mal;
    END IF;

    -- 4. Y siguen sin fila en `productos`, que es lo que las hace de Mongo.
    SELECT count(*) INTO v_mal
    FROM productos p
    WHERE p.id_producto IN (SELECT DISTINCT id_producto FROM lote_ofertas);

    IF v_mal > 0 THEN
        RAISE EXCEPTION '% de esos productos aparecieron en la tabla productos', v_mal;
    END IF;

    RAISE NOTICE 'Ofertas verificadas. % ofertas sobre % productos que viven solo en MongoDB.',
                 v_creadas, (SELECT count(DISTINCT id_producto) FROM lote_ofertas);
END
$verificar$;


COMMIT;
