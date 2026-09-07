-- ============================================================
-- ClickHouse -- el esquema de eventos
-- ============================================================
--
-- Es IDEMPOTENTE: todo va con IF NOT EXISTS, asi que correrlo dos veces no
-- rompe nada y no borra nada. arrancar.ps1 lo corre en cada arranque.
--
-- Una regla que aqui no es opcional: en ClickHouse la tabla se disena por su
-- ORDER BY. No es un indice que se agrega despues, es el ORDEN FISICO en el
-- que quedan escritos los datos en disco, y es lo que decide si una consulta
-- lee tres bloques o lee la tabla entera. Por eso cada tabla de abajo dice
-- cual es su pregunta antes de decir sus columnas.
--
-- Y lo que NO hay que hacer, que es el reflejo que trae quien viene de
-- Cassandra: una tabla nueva por cada pregunta nueva. Aqui no hace falta.
-- Se guarda el evento crudo UNA vez y las preguntas se hacen despues con SQL.


-- ============================================================
-- vista_producto -- el clic en la ficha
-- ============================================================
--
-- Es el UNICO evento que nace aqui. Los otros dos son copias de PostgreSQL,
-- pero este hoy no se guarda en ninguna parte, y sin el no hay forma de saber
-- que producto se esta calentando ANTES de que se venda. El sistema solo
-- guarda el final de la historia, que es la compra.
--
-- Su pregunta es "que le paso a ESTE producto a lo largo del tiempo", asi que
-- el orden es (id_producto, fecha). Una consulta por producto lee un tramo
-- seguido del disco en vez de saltar por toda la tabla.
CREATE TABLE IF NOT EXISTS vista_producto
(
    fecha        DateTime64(3),

    id_producto  UInt64,

    -- Nullable a proposito: la ficha es publica y se puede mirar sin cuenta.
    -- Un 0 para decir "sin sesion" seria un id de usuario que no existe, y
    -- tarde o temprano alguien lo cuenta como una persona.
    id_usuario   Nullable(UInt64),

    -- Distingue visitas de la misma persona sin sesion iniciada. Es lo que
    -- separa "cien personas miraron esto" de "una persona lo miro cien veces",
    -- que para tendencia y para fraude no son ni parecido.
    sesion       String,

    -- IPv6 aunque casi todo vaya a llegar en IPv4. Es el mismo criterio del
    -- tipo `inet` de PostgreSQL, que acepta las dos: ClickHouse guarda una
    -- IPv4 dentro de una IPv6 sin perder nada y evita tener dos columnas.
    ip           IPv6,

    -- LowCardinality porque son un punado de valores repetidos millones de
    -- veces (catalogo, buscador, enlace directo). ClickHouse los guarda como
    -- un numero contra un diccionario, y ahi es donde el columnar se paga solo.
    origen       LowCardinality(String),

    -- DE DONDE SALIO ESTA FILA, y no es un adorno: hoy casi todo lo que hay
    -- aqui esta GENERADO, porque el portal todavia no manda vistas. Una tabla
    -- de eventos donde no se distingue lo medido de lo inventado no se puede
    -- ensenar a nadie, y en un panel de fraude es peor: acusa a cuentas de la
    -- semilla por un patron que dibujo un generador.
    --
    -- Es el mismo marcador que ya usan los otros dos generadores del proyecto,
    -- la L de migrations/lote y la M de mongo/lote.
    --
    --   real      lo mando el portal
    --   generado  lo sembro clickhouse/lote
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (id_producto, fecha)
-- Los clics de hace mas de un ano no le sirven a nadie y se borran solos, sin
-- que nadie tenga que acordarse de correr una limpieza. Es de las pocas cosas
-- que una base de eventos hace y una relacional no.
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- evento_login -- copia de log_login
-- ============================================================
--
-- COPIA, no mudanza. La verdad se queda en PostgreSQL, donde `log_login`
-- tiene una llave foranea contra `usuarios` con ON DELETE RESTRICT. Sacar la
-- tabla de ahi es perder esa integridad y quedarse con ids sueltos que pueden
-- apuntar a cuentas que ya no existen.
--
-- Su pregunta NO es "que hizo este usuario", que eso ya lo contesta
-- PostgreSQL con su indice. Es "cuantas cuentas distintas salen de esta misma
-- IP", que es la senal de fraude que el grafo no puede ver: el grafo sabe que
-- dos cuentas se califican entre si, pero no sabe que las dos entran desde la
-- misma casa a la misma hora. Por eso el orden es (ip, fecha).
CREATE TABLE IF NOT EXISTS evento_login
(
    fecha         DateTime64(3),
    id_usuario    UInt64,
    ip            IPv6,

    -- login o logout, tal como lo distingue `tipo_login` en PostgreSQL.
    tipo          LowCardinality(String),

    -- Mismo marcador que en vista_producto. Aqui casi todo SI es real: sale de
    -- log_login. Lo generado son las IP de mentira que hacen falta para poder
    -- probar el analisis, porque los 317 logueos de verdad comparten UNA sola
    -- IP (127.0.0.1, todo desarrollo local) y contra eso no se puede medir
    -- nada: las doce cuentas darian anillo de fraude por construccion.
    lote          LowCardinality(String) DEFAULT 'real',

    -- De donde salio la fila de PostgreSQL. Sirve para reanudar la copia sin
    -- repetir, y para poder senalar la fila original cuando algo no cuadre.
    id_log_login  UInt64
)
ENGINE = ReplacingMergeTree
-- ReplacingMergeTree y no MergeTree: si la copia se corre dos veces sobre el
-- mismo tramo, la fila repetida se colapsa sola por su id en vez de contarse
-- dos veces. Un evento contado doble convierte una entrada normal en una
-- rafaga que no existio.
ORDER BY (ip, fecha, id_log_login);


-- ============================================================
-- evento_registro -- copia de log_registro
-- ============================================================
--
-- La misma copia y por el mismo motivo, pero contesta otra cosa: cuantas
-- CUENTAS se crearon desde una misma IP. Diez cuentas nacidas la misma tarde
-- detras de la misma IP es la forma mas barata que hay de destapar un anillo,
-- y se ve antes de que esas cuentas escriban una sola resena.
CREATE TABLE IF NOT EXISTS evento_registro
(
    fecha            DateTime64(3),
    id_usuario       UInt64,
    ip               IPv6,
    id_log_registro  UInt64,
    lote             LowCardinality(String) DEFAULT 'real'
)
ENGINE = ReplacingMergeTree
ORDER BY (ip, fecha, id_log_registro);


-- ============================================================
-- vistas_por_producto_dia -- el resumen que se mantiene solo
-- ============================================================
--
-- Esto es lo que en Cassandra habria que precalcular a mano con un proceso
-- aparte, y aqui lo hace la base. Es una vista materializada: cada vez que
-- entra una fila en `vista_producto`, ClickHouse actualiza este resumen en el
-- mismo momento. No hay ETL, no hay worker, no hay cola que se quede vieja.
--
-- Y ojo con lo que NO es: no es una copia de la tabla de arriba. La tabla
-- cruda se sigue pudiendo consultar para cualquier pregunta que a nadie se le
-- haya ocurrido todavia. Esto solo hace barata la que ya sabemos que se hace
-- todos los dias.
CREATE TABLE IF NOT EXISTS vistas_por_producto_dia
(
    dia          Date,
    id_producto  UInt64,

    -- El marcador SUBE hasta el resumen, y tiene que subir. Si se agregara sin
    -- el, lo generado y lo real quedarian sumados en la misma celda y ya no
    -- habria forma de separarlos aguas abajo: el panel leeria un solo numero
    -- sin saber que parte se invento un script. Que este en la clave cuesta
    -- una columna y salva la unica pregunta que de verdad importa contestar
    -- cuando alguien mire el panel, que es "esto es medido o es de mentira".
    lote         LowCardinality(String),

    vistas       AggregateFunction(count, UInt64),

    -- Personas distintas, no visitas. Un producto con 500 vistas de 3 sesiones
    -- no esta de moda, esta siendo inflado.
    sesiones     AggregateFunction(uniq, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (dia, id_producto, lote);

CREATE MATERIALIZED VIEW IF NOT EXISTS vistas_por_producto_dia_mv
TO vistas_por_producto_dia
AS
SELECT
    toDate(fecha)      AS dia,
    id_producto,
    lote,
    countState()       AS vistas,
    uniqState(sesion)  AS sesiones
FROM vista_producto
GROUP BY dia, id_producto, lote;
