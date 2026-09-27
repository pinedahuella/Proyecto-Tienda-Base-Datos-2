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
-- carrito_producto -- se agrego el producto al carrito
-- ============================================================
--
-- El carrito EN SI sigue viviendo en Redis (el HASH mutable de
-- redis/inventario_limitado.lua y compania) -- esto es solo el evento
-- puntual de la accion, que nunca se actualiza despues de nacer. Sin el no
-- hay forma de medir el embudo completo: cuantas vistas de verdad pasan a
-- carrito, y de esas cuantas terminan en compra.
--
-- `id_producto` E `id_oferta` van juntos, sin normalizar: el carrito real
-- opera por oferta (vendedor + variante), pero la pregunta que mas importa
-- es de producto ("que se vende mas"), no de oferta -- por eso el orden
-- fisico lidera con `id_producto` y `id_oferta` viaja como columna
-- consultable aparte.
--
-- Sin `sesion` ni `origen`, a diferencia de `vista_producto`: el carrito
-- SIEMPRE exige cuenta en este proyecto (no hay carrito de invitado), asi
-- que no hay visitante anonimo que distinguir, y no hay un "por donde
-- llegaste" equivalente para la accion de agregar.
--
-- `ip` se queda aunque `id_usuario` ya identifique a quien actuo -- no por
-- costumbre, sino por una pregunta ya anticipada: cruzar el fraude de login
-- por IP con patrones de carrito repartidos entre varias cuentas, la misma
-- idea de correlacion que ya usan los anillos de fraude en Neo4j.
CREATE TABLE IF NOT EXISTS carrito_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_oferta    UInt64,
    id_usuario   UInt64,
    cantidad     UInt32,
    ip           IPv6,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (id_producto, fecha)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- compra_producto -- linea de un pedido ya pagado
-- ============================================================
--
-- COPIA analitica, no la fuente de ganancias -- esa sigue siendo
-- PostgreSQL (GET /admin/reportes/ventas), exacta y transaccional. Esta
-- tabla es solo para medir TASA de conversion (que tan seguido una vista
-- termina en compra), nunca para calcular un monto.
--
-- Se escribe fire-and-forget desde el backend (sin worker con outbox, a
-- diferencia de resenas->Neo4j o logueos->Elasticsearch: una compra que se
-- pierde aqui por una caida puntual no arriesga nada, porque la venta de
-- verdad ya quedo segura en PostgreSQL sin depender de esto). Por eso
-- ReplacingMergeTree por id_pedido: si el evento se reintenta algun dia, la
-- fila repetida se colapsa sola en vez de contar la compra dos veces.
-- EL ORDER BY LLEVA id_oferta, Y SIN EL SE PERDIAN UNIDADES (2026-09-18).
-- ReplacingMergeTree colapsa las filas con la misma clave de ordenacion. Con
-- (id_producto, fecha, id_pedido) dos ofertas DEL MISMO PRODUCTO en el MISMO
-- pedido -- comprarle el mismo articulo a dos vendedores -- comparten clave (la
-- fecha es la misma) y una se lleva a la otra. Medido: el pedido 121 tenia tres
-- lineas de venta en PostgreSQL (ofertas 5, 46 y 51, las dos ultimas del producto
-- 11) y aqui quedaban dos. sum(cantidad), que es la metrica de compra y de
-- devolucion en los rankings, salia corta. Una tabla que ya existe no cambia de
-- clave con este CREATE: para las bases hechas antes esta clickhouse/
-- reparar_orden_compras.sh, que arrancar.ps1 corre solo.
CREATE TABLE IF NOT EXISTS compra_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_oferta    UInt64,
    id_usuario   UInt64,
    cantidad     UInt32,
    id_pedido    UInt64,
    ip           IPv6,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = ReplacingMergeTree
ORDER BY (id_producto, fecha, id_pedido, id_oferta)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- devolucion_producto -- linea de un pedido devuelto o cancelado
-- ============================================================
--
-- IDENTICA a compra_producto en columnas. Se evaluo agregar un campo
-- `motivo` (el motivo_movimiento de PostgreSQL) y se descarto: aqui solo
-- tiene un valor relevante (devolucion, generico), sin ninguna variante mas
-- especifica que capturar -- una columna con un solo valor posible no
-- aporta nada.
--
-- Solo se escribe cuando el pedido SI estaba comprado (tenia stock que
-- devolver): uno pendiente nunca fue una compra en el embudo, asi que
-- cancelarlo no es una devolucion que valga la pena medir.
CREATE TABLE IF NOT EXISTS devolucion_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_oferta    UInt64,
    id_usuario   UInt64,
    cantidad     UInt32,
    id_pedido    UInt64,
    ip           IPv6,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = ReplacingMergeTree
ORDER BY (id_producto, fecha, id_pedido, id_oferta)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- busqueda_realizada -- un termino buscado en el buscador
-- ============================================================
--
-- Pregunta: que tan seguido se busca este termino, y cuantos resultados
-- dio -- para detectar busquedas sin resultado y tendencias de busqueda.
-- Publica y sin sesion obligatoria, mismo criterio que vista_producto:
-- id_usuario nullable mas sesion para distinguir visitantes anonimos entre
-- si.
--
-- Se escribe SIN que el navegador tenga que avisar nada aparte: el backend
-- ya corrio la busqueda al procesar GET /buscador/productos (la ruta
-- publica, nunca /admin), asi que sesion viaja como parametro OPCIONAL de
-- esa misma peticion -- si no viene, el evento se salta en silencio, nunca
-- bloquea ni rechaza la busqueda de nadie.
CREATE TABLE IF NOT EXISTS busqueda_realizada
(
    fecha        DateTime64(3),
    termino      String,
    resultados   UInt32,
    id_usuario   Nullable(UInt64),
    sesion       String,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (termino, fecha)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;

-- Las facetas elegidas (GET /buscador/productos/facetado, desde el
-- 2026-09-26). Se guardan tal como las mando el cliente: `categoria=7,9`
-- queda [7,9] y `precio=250-500` queda ['250-500']. Con DEFAULT, asi que las
-- filas viejas y las de la busqueda simple quedan en facetada = 0.
--
-- Van en ALTER y no dentro del CREATE porque este archivo se reaplica en cada
-- arranque sobre un volumen que ya tiene la tabla, y ahi el CREATE IF NOT
-- EXISTS no hace nada. Sin estas columnas el backend no falla al buscar,
-- pero el INSERT del evento si, en silencio, y la tendencia de facetas del
-- admin se cae entera. Referencia de Jose David en
-- backend/elementos Generales/plan pendiente/buscador-facetado-clickhouse.sql
ALTER TABLE busqueda_realizada
    ADD COLUMN IF NOT EXISTS facetada       UInt8         DEFAULT 0,
    ADD COLUMN IF NOT EXISTS categorias     Array(UInt32) DEFAULT [],
    ADD COLUMN IF NOT EXISTS precios        Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS calificaciones Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS disponible     UInt8         DEFAULT 0;


-- ============================================================
-- busqueda_clic -- clic sobre un resultado de busqueda
-- ============================================================
--
-- Pregunta: la gente hace clic en el primer resultado o baja hasta el
-- quinto -- mide relevancia. Junto con busqueda_realizada arma el par
-- impresion/clic clasico (CTR por termino y por posicion).
--
-- A diferencia de busqueda_realizada, esta SI necesita que el navegador
-- avise: hacer clic es una interaccion pura de interfaz que el backend no
-- puede saber por su cuenta solo por haber contestado la busqueda.
CREATE TABLE IF NOT EXISTS busqueda_clic
(
    fecha        DateTime64(3),
    termino      String,
    id_producto  UInt64,
    posicion     UInt16,
    id_usuario   Nullable(UInt64),
    sesion       String,
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (termino, fecha)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;

-- Las facetas que estaban puestas en /buscar al hacer clic. Mismo criterio
-- que en busqueda_realizada, arriba.
ALTER TABLE busqueda_clic
    ADD COLUMN IF NOT EXISTS facetada       UInt8         DEFAULT 0,
    ADD COLUMN IF NOT EXISTS categorias     Array(UInt32) DEFAULT [],
    ADD COLUMN IF NOT EXISTS precios        Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS calificaciones Array(String) DEFAULT [],
    ADD COLUMN IF NOT EXISTS disponible     UInt8         DEFAULT 0;


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
