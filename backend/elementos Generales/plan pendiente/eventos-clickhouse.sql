-- ============================================================
-- ClickHouse -- estructuras PROVISIONALES para trabajar el backend
-- ============================================================
--
-- Referencia para `backend/`, NO el esquema real. El esquema real vive en
-- `clickhouse/001_esquema.sql` (raiz del repo, del companero) -- este
-- archivo es idempotente y se re-corre en cada arranque, asi que si algun
-- dia se vuelve a levantar el stack sin tocar nada, estas tablas se
-- reemplazan por las que el defina ahi.
--
-- 2026-09-18: se borraron las 5 estructuras que habia antes en la base
-- LOCAL (`vista_producto`, `evento_login`, `evento_registro`,
-- `vistas_por_producto_dia` + su vista materializada) para reconstruir
-- desde cero con los seis tipos de evento que el backend necesita para el
-- embudo de producto y el buscador. Ver `eventos-clickhouse.md` en este
-- mismo folder para el porque de cada tabla y lo que le queda al companero.
--
-- Mismas convenciones que el esquema real: ORDER BY segun la pregunta
-- principal de la tabla, columna `lote` (`real` | `generado-<semilla>`)
-- para no mezclar datos medidos con datos sembrados, y TTL de 12 meses
-- porque un evento de hace mas de un ano no le sirve a nadie.
--
-- `evento_login`/`evento_registro` NO se recrean aqui: son del ETL del
-- companero (congelado, pendiente de repuntar a Mongo) y no son parte de
-- lo que el backend emite. Las reconstruye el cuando retome ese ETL.


-- ============================================================
-- vista_producto -- el clic en la ficha (igual al esquema real)
-- ============================================================
CREATE TABLE IF NOT EXISTS vista_producto
(
    fecha        DateTime64(3),
    id_producto  UInt64,
    id_usuario   Nullable(UInt64),
    sesion       String,
    ip           IPv6,
    origen       LowCardinality(String),
    lote         LowCardinality(String) DEFAULT 'real'
)
ENGINE = MergeTree
ORDER BY (id_producto, fecha)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- carrito_producto -- se agrego el producto al carrito
-- ============================================================
--
-- Pregunta: "cuantas veces se agrega este producto al carrito", para medir
-- el embudo vista -> carrito -> compra. El carrito EN SI sigue viviendo en
-- Redis (el HASH mutable de `carrito-redis`) -- esto es solo el evento
-- puntual de la accion, nunca se actualiza despues de nacer.
--
-- Sin `sesion` ni `origen`: el carrito SIEMPRE exige cuenta en este
-- proyecto (no hay carrito de invitado), asi que no hace falta distinguir
-- visitantes anonimos, y no hay un equivalente claro a "por donde llegaste"
-- para la accion de agregar.
--
-- `id_producto` E `id_oferta` van juntos, sin normalizar: el carrito real
-- opera por oferta (vendedor + variante), pero la pregunta que mas importa
-- ("que producto se vende mas") es de producto, no de oferta -- por eso
-- lidera el `ORDER BY` `id_producto`, e `id_oferta` viaja como columna
-- consultable pero sin liderar el orden fisico (decision explicita del
-- usuario, 2026-09-18).
--
-- `ip` se queda, no "por estandar" sino por una pregunta ya anticipada:
-- cruzar fraude de login (por IP) con patrones de carrito entre varias
-- cuentas -- la misma idea de correlacion que se hablo para anillos de
-- fraude en Neo4j.
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
-- PostgreSQL (`GET /admin/reportes/ventas`), exacta y transaccional. Esta
-- tabla es solo para medir TASA de conversion (que tan seguido una vista
-- termina en compra), nunca para calcular un monto.
--
-- `ReplacingMergeTree` por `id_pedido`: si el evento se reintenta (es
-- fire-and-forget desde el backend), la fila repetida se colapsa sola en
-- vez de contar la compra dos veces. `id_producto` E `id_oferta` van
-- juntos, mismo criterio que `carrito_producto` -- ver ese bloque.
--
-- CONSTRUIDA el 2026-09-18, SIN ruta HTTP: el evento se dispara directo
-- desde `CarritoService.ejecutarCompraCarrito()` (fire-and-forget, sin
-- `await`), justo tras `comprar_carrito()` de Postgres -- decision
-- explicita de NO usar un worker con outbox (a diferencia de reseñas
-- ->Neo4j o logueos->Elasticsearch): esos protegen datos de los que
-- depende una decision real, una compra perdida en ClickHouse no tiene
-- ese riesgo. Probado en vivo con ClickHouse caido a mitad de una compra
-- real: el pedido se completo normal (0.126s), el evento de ese pedido se
-- perdio de verdad -- comportamiento aceptado, no un bug.
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
ORDER BY (id_producto, fecha, id_pedido)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- devolucion_producto -- linea de un pedido devuelto o cancelado
-- ============================================================
--
-- IDENTICA a `compra_producto` en columnas -- se evaluo un campo `motivo`
-- (`motivo_movimiento` del lado de Postgres) y se descarto: solo tiene un
-- valor relevante aqui (`devolucion`, generico, "vuelven las unidades de
-- un pedido cancelado"), sin ninguna variante mas especifica que capturar
-- -- una columna con un solo valor posible no aporta nada.
--
-- CONSTRUIDA el 2026-09-18, SIN ruta HTTP, mismo patron exacto que
-- `compra_producto` (ver ese bloque para el porque de no usar un worker).
-- Enganchada en `PedidosCompradorService.cancelarPedido()`, SOLO cuando
-- el pedido si estaba `comprado` (`cancelacion.stock.length > 0`) -- uno
-- `pendiente` nunca fue una compra en el embudo. `cantidad` (que
-- `cancelar_pedido()` no devuelve) sale de una consulta chica a
-- `pedido_producto` + `precio_historial` por `id_pedido`. Probada en vivo
-- con los mismos cuatro casos que `compra_producto`, incluida la caida de
-- ClickHouse a mitad de una cancelacion real.
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
ORDER BY (id_producto, fecha, id_pedido)
TTL toDateTime(fecha) + INTERVAL 12 MONTH;


-- ============================================================
-- busqueda_realizada -- un termino buscado en el buscador
-- ============================================================
--
-- Pregunta: "que tan seguido se busca este termino, y cuantos resultados
-- dio" -- para detectar busquedas sin resultado y tendencias. Publica, sin
-- sesion obligatoria (mismo criterio que `vista_producto`: `id_usuario`
-- nullable + `sesion` para distinguir visitantes anonimos).
--
-- CONSTRUIDA el 2026-09-18, SIN ruta HTTP -- a diferencia de
-- `vista_producto`, el backend YA corre la busqueda al procesar
-- `GET /buscador/productos` (la ruta PUBLICA, nunca `/admin`), asi que no
-- hace falta que el frontend avise nada (mismo razonamiento que
-- `compra_producto`, no el de `vista`). `sesion` viaja como query param
-- OPCIONAL en ese `GET`: si no viene, el evento se salta en silencio, sin
-- bloquear ni rechazar la busqueda de nadie.
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


-- ============================================================
-- busqueda_clic -- clic sobre un resultado de busqueda
-- ============================================================
--
-- Pregunta: "la gente hace clic en el primer resultado o baja hasta el
-- quinto" -- mide relevancia. Junto con `busqueda_realizada` arma el par
-- impresion/clic clasico (CTR por termino y por posicion).
--
-- CONSTRUIDA el 2026-09-18, CON ruta HTTP (`POST /eventos/busqueda-clic`,
-- publica, mismo patron que `vista_producto`) -- a diferencia de
-- `busqueda_realizada`, hacer clic es una interaccion pura de interfaz
-- que el backend no puede saber por su cuenta.
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
