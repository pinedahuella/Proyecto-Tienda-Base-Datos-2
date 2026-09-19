# Eventos de producto y buscador en ClickHouse (reconstruccion provisional)

> **Estado (2026-09-18, actualizado la misma noche): las SEIS piezas del
> plan quedaron construidas y probadas.** `POST /eventos/vista`,
> `POST /eventos/carrito`, `POST /eventos/busqueda-clic`, y el registro de
> `compra_producto`, `devolucion_producto` y `busqueda_realizada` (los
> tres sin ruta HTTP propia, ver mas abajo y `endpoints-eventos.md`). No
> queda ningun emisor pendiente de este plan.
>
> **Extra, pedido despues de cerrar las seis piezas: `GET /admin/eventos/*`**
> -- seis rutas de solo lectura (una por tabla), solo admin, que devuelven
> filas CRUDAS en una ventana de dias hacia atras (`dias`/`limite`/`orden`
> como query params). NO agrupan ni calculan tendencias -- eso seria un
> panel aparte, no construido. Ver `endpoints-eventos.md`, seccion
> "GET /admin/eventos/*", para el contrato completo y las pruebas.
>
> **`carrito_producto` cambio de diseño respecto al primer borrador de este
> documento** (mas abajo, sin actualizar todavia en el cuerpo): ahora lleva
> tambien `id_oferta` (no solo `id_producto`) e `ip`, sin `sesion` ni
> `origen`. El detalle completo del porque esta en `endpoints-eventos.md` y
> en los comentarios de `eventos-clickhouse.sql`. Tambien cambio el PLAN de
> "enganchado a `CarritoService`": se construyo como ruta propia
> (`POST /eventos/carrito`), que el FRONTEND llama al agregar algo al
> carrito -- igual que `vista`, no un hook automatico del lado del backend.
>
> **`compra_producto`, al reves: SI quedo "enganchado" al backend, sin
> ninguna ruta HTTP propia** -- se discutio explicitamente si convenia un
> worker con outbox (como el de reseñas->Neo4j o logueos->Elasticsearch) y
> se descarto: esos workers protegen datos de los que depende una decision
> real, una compra perdida en ClickHouse no tiene ese riesgo (la venta ya
> quedo segura en Postgres). El registro vive directo en
> `CarritoService.ejecutarCompraCarrito()`, fire-and-forget, sin `await`.
> Probado en vivo INCLUSO con ClickHouse caido a la mitad de una compra
> real: el pedido se completo normal en 0.126s, el evento de ESE pedido se
> perdio de verdad (sin cola, sin reintento -- a proposito), y el siguiente
> pedido con ClickHouse ya recuperado volvio a quedar registrado solo.
>
> **`devolucion_producto` termino IDENTICA a `compra_producto`** (mismas
> ocho columnas, mismo `ReplacingMergeTree`) -- se evaluo agregar un
> campo `motivo`, pero se descarto al verificar contra la base real:
> `motivo_movimiento` de PostgreSQL solo tiene un valor relevante aqui
> (`devolucion`, generico), sin ninguna variante mas especifica. El
> `cantidad` que la funcion `cancelar_pedido()` no devuelve se saca con
> una consulta chica a `pedido_producto` + `precio_historial` por
> `id_pedido` (contra Postgres, no ClickHouse -- no se ve afectada si
> ClickHouse esta caido). Solo se registra si el pedido SI estaba
> `comprado` (`stock.length > 0`): uno `pendiente` nunca fue una compra en
> el embudo. Probado en vivo con los mismos cuatro casos que
> `compra_producto`, incluida la caida de ClickHouse a mitad de una
> cancelacion real.
>
> **`busqueda_realizada` y `busqueda_clic` NO comparten el mismo mecanismo**,
> a pesar de sonar parecidas: `busqueda_realizada` termino "enganchada" sin
> ruta HTTP (mismo razonamiento que `compra_producto` -- el backend ya
> corrio la busqueda al procesar `GET /buscador/productos`, no hace falta
> que el frontend avise nada), mientras que `busqueda_clic` SI es una ruta
> POST propia (mismo razonamiento que `vista` -- un clic es una interaccion
> de interfaz que el backend no puede saber por su cuenta). El `sesion`
> de `busqueda_realizada` viaja como query param OPCIONAL en el `GET` --
> si no viene, el evento se salta en silencio, nunca bloquea la busqueda.
> Se extrajo un helper compartido, `helpers/sesion-opcional.ts`
> (`idUsuarioDeCookieOpcional`), reusado por `vista`, `busqueda_realizada`
> y `busqueda_clic`.
>
> **Ojo con el estado REAL de la base local**, que se movio varias veces
> esta misma sesion y no coincide del todo con lo que dice el resto de
> este documento mas abajo: se crearon las 6 tablas del diseño original, se
> borraron TODAS otra vez (a peticion del usuario, para empezar una sesion
> de aprendizaje de ClickHouse desde cero), y se volvieron a crear, una por
> una y ya con el diseño final, las SEIS tablas -- todas con datos reales
> de prueba (compras, cancelaciones y busquedas reales de verdad, no
> simuladas). Confirmar con `SHOW TABLES FROM mesh_eventos` antes de
> asumir el estado exacto.

## Contexto

Sesion de conversacion (no de codigo) sobre que tanto provecho se le esta
sacando a cada base del proyecto. Para ClickHouse la conclusion fue: la
unica tabla que de verdad nace ahi (`vista_producto`) sigue sin ningun
emisor real (`POST /eventos/vista` nunca se construyo, ver
`estado-backend-tienda`), y el resto de eventos utiles del comprador
(carrito, compra, devolucion, busqueda) no se estaban capturando en
ninguna parte pensada para analitica de agregado.

Se decidio ampliar a seis tipos de evento, cubriendo el embudo completo
del comprador y el buscador:

```
vista_producto -> carrito_producto -> compra_producto -> (a veces) devolucion_producto
busqueda_realizada -> busqueda_clic
```

**Decision explicita del usuario: empezar borrando todo lo que habia en la
base LOCAL** (`vista_producto`, `evento_login`, `evento_registro`,
`vistas_por_producto_dia` + su vista materializada) para reconstruir desde
cero con las seis tablas de este plan, en vez de ir agregando sobre lo que
ya habia. Se aplico directo contra el contenedor `mesh-clickhouse`
(`docker exec`), no contra ningun archivo -- `clickhouse/001_esquema.sql`
(el real, del companero) no se tocо.

## Por que estas seis y no otras

Mismo criterio ya usado para decidir que entra en ClickHouse: evento
**inmutable** (nunca se actualiza despues de creado), **alto volumen**, y
consultado casi siempre **en agregado** (tendencia, tasa de conversion),
nunca "dame ese registro exacto". Bajo ese filtro:

- **`vista_producto`** -- se mantiene identica al esquema real (ver
  `eventos-clickhouse.sql`, mismas columnas y `ORDER BY`). Es la unica que
  ya estaba aprobada; no se redisenó.
- **`carrito_producto`** -- el evento puntual de "se agrego este producto
  al carrito", distinto del carrito EN SI (que sigue siendo el HASH
  mutable de Redis, ver memoria `carrito-redis`). Sin esto no hay forma de
  medir cuantas vistas realmente pasan a carrito. Diseño final (cerrado en
  conversacion antes de construir): lleva `id_producto` E `id_oferta`
  juntos, sin normalizar -- el carrito real opera por oferta, pero la
  pregunta que importa es de producto ("que se vende mas"), asi que
  `id_producto` lidera el `ORDER BY` e `id_oferta` viaja como columna
  consultable aparte. Sin `sesion` ni `origen` (el carrito siempre exige
  cuenta, no hay caso anonimo que distinguir, y no hay un "de donde
  llegaste" equivalente para agregar). `ip` se queda, no por convencion
  sino por una pregunta ya anticipada: cruzar fraude de login por IP con
  patrones de carrito entre varias cuentas.
- **`compra_producto`** / **`devolucion_producto`** -- copias analiticas de
  una linea de pedido pagada o devuelta, IDENTICAS entre si en columnas:
  `fecha`, `id_producto`, `id_oferta`, `id_usuario`, `cantidad`,
  `id_pedido`, `ip`, `lote`. **No reemplazan el reporte de ventas de
  Postgres** (`GET /admin/reportes/ventas`), que sigue siendo la fuente
  exacta y transaccional del dinero -- esto es solo para medir TASA de
  conversion y de devolucion, nunca para calcular un monto. Llevan
  `id_pedido` para poder rastrear el pedido origen en Postgres si hace
  falta, y usan `ReplacingMergeTree` (con `id_pedido` en el `ORDER BY`)
  por si el evento se reintenta (es fire-and-forget desde el backend,
  igual que `LogService`). Se evaluo un campo `motivo` para
  `devolucion_producto` y se descarto: `motivo_movimiento` de PostgreSQL
  solo tiene un valor relevante aqui (`devolucion`, generico), sin ninguna
  variante mas especifica que capturar.
- **`busqueda_realizada`** / **`busqueda_clic`** -- termino buscado +
  cuantos resultados dio, y si hubo clic sobre cual resultado y en que
  posicion. Juntas arman el par impresion/clic clasico (CTR por termino).
  A pesar de sonar parecidas, NO comparten mecanismo:
  `busqueda_realizada` queda enganchada sin ruta HTTP (el backend ya
  corrio la busqueda, mismo razonamiento que `compra_producto`);
  `busqueda_clic` si es una ruta POST propia (un clic es interfaz pura,
  mismo razonamiento que `vista`).

**Quedaron fuera a proposito: `evento_login` / `evento_registro`.** No son
parte de lo que el backend va a emitir con este plan -- son del ETL del
companero, que quedo congelado desde que los eventos de autenticacion se
movieron a Mongo (`cambio_propuestas/2026-09-10_0906-eventos-autenticacion-mongo.md`).
Recrearlas aqui hubiera dado una falsa sensacion de que ese ETL ya esta al
dia. Las reconstruye el companero cuando retome ese trabajo.

## Lo que sigue

Del lado de `backend/` -- rutas que emiten cada evento, mismo patron
fire-and-forget de `LogService`/`FraudeLoginService.registrarIntento`
(nunca deben retrasar ni tumbar la respuesta real al usuario). **Las seis
quedaron HECHAS** -- lista de abajo, con fecha, solo por trazabilidad de
cuando y como se construyo cada una:

1. ~~`POST /eventos/vista`~~ -- **HECHO y probado en vivo el 2026-09-18**,
   ver `endpoints-eventos.md`. Publica, `202`, fire-and-forget,
   `id_usuario` opcional (de la cookie si hay una valida, nunca del
   cuerpo). Bug real encontrado y corregido en el camino: `DateTime64` por
   HTTP/JSONEachRow necesita un string `AAAA-MM-DD HH:MM:SS.mmm` en la
   zona horaria del SERVIDOR (`America/Guatemala`), no un timestamp
   numerico -- un numero se rechaza o, peor, se interpreta mal sin avisar.
2. ~~Emisor de `carrito_producto`~~ -- **HECHO y probado en vivo el
   2026-09-18**, ver `endpoints-eventos.md`. No quedo "enganchado a
   `CarritoService`" como decia el plan original: se construyo como ruta
   propia (`POST /eventos/carrito`), que el frontend llama al agregar algo
   al carrito -- igual que `vista`, no un hook automatico del backend.
   Exige sesion (`SesionGuard`), `id_usuario` sale de `@UsuarioActual()`.
3. ~~Emisor de `compra_producto`~~ -- **HECHO y probado en vivo el
   2026-09-18**, ver `endpoints-eventos.md`, incluida la prueba con
   ClickHouse caido a mitad de una compra real. Enganchado directo en
   `CarritoService.ejecutarCompraCarrito()` -- SIN ruta HTTP, decision
   explicita tras descartar un worker con outbox (ver arriba). `ip` se
   agrego como parametro nuevo de `comprarCarrito()`/`ejecutarCompraCarrito()`,
   pasado desde `CarritoController.comprar()` con `@Req()`.
3b. ~~Emisor de `devolucion_producto`~~ -- **HECHO y probado en vivo el
   2026-09-18**, mismo patron exacto que `compra_producto` (ver
   `endpoints-eventos.md`). Enganchado en
   `PedidosCompradorService.cancelarPedido()`, solo cuando
   `cancelacion.stock.length > 0`. `cantidad` (que `cancelar_pedido()` no
   devuelve) sale de una consulta chica a `pedido_producto` +
   `precio_historial` por `id_pedido`. `ip` se agrego igual que en
   `comprarCarrito()`, como parametro nuevo pasado desde
   `PedidosCompradorController.cancelar()` con `@Req()`.
4. ~~Emisor de `busqueda_realizada`~~ -- **HECHO y probado en vivo el
   2026-09-18**, ver `endpoints-eventos.md`. SIN ruta HTTP, enganchado en
   `BuscadorProductosController.buscar()` (`GET /buscador/productos`, la
   ruta PUBLICA -- nunca `/admin`). `sesion` viaja como query param nuevo
   OPCIONAL: sin el, el evento se salta en silencio, nunca bloquea la
   busqueda. `termino`/`resultados` salen de lo que la propia busqueda ya
   iba a devolver, sin ningun calculo extra.
5. ~~Emisor de `busqueda_clic`~~ -- **HECHO y probado en vivo el
   2026-09-18**, ver `endpoints-eventos.md`. `POST /eventos/busqueda-clic`,
   publica, mismo patron que `vista`. Dos validaciones nuevas
   (`validarTerminoEvento`, `validarPosicionEvento`) en
   `helpers/validaciones-eventos.ts`.
6. ~~Decidir SI hace falta un cliente ClickHouse nuevo~~ -- **HECHO**:
   `src/database/clickhouse.ts`, con `@clickhouse/client@1.23.1` (la
   oficial), mismo patron que `elastic.ts` (HTTP, sin socket
   persistente). Variables `CLICKHOUSE_*` agregadas a `.env`/`.env.example`.
7. ~~`GET /admin/eventos/*`~~ -- **HECHO y probado en vivo el 2026-09-18**,
   ver `endpoints-eventos.md`. Extra, pedido despues de cerrar las seis
   piezas de arriba: seis rutas de solo lectura (una por tabla), solo
   admin, filas crudas en una ventana de `dias` hacia atras con `limite` y
   `orden`. Nuevo `helpers/manejar-error-clickhouse.ts` (mismo patron que
   `manejar-error-elastic.ts`).

Del lado del companero (fuera de `backend/`):

1. Formalizar estas seis tablas en `clickhouse/001_esquema.sql` (el
   archivo real, idempotente, que se corre en cada arranque) -- hoy solo
   existen en la base LOCAL de este entorno, aplicadas a mano.
   `eventos-clickhouse.sql` en este mismo folder es la referencia exacta
   de columnas/tipos/`ORDER BY` a copiar.
2. Decidir si `carrito_producto`/`compra_producto`/`devolucion_producto`
   necesitan tambien un generador de datos sembrados
   (`clickhouse/lote/generar_*.sql`, mismo patron que ya existe para
   `vista_producto`) para poder demostrar tendencias sin depender de
   trafico real.
3. `evento_login`/`evento_registro` -- repuntar su ETL a Mongo cuando
   retome ese trabajo (independiente de este plan).
4. Vistas materializadas de agregado (tipo `vistas_por_producto_dia`) para
   `carrito_producto`/`compra_producto` -- no se crearon todavia porque
   no hay ningun panel/endpoint que las necesite hoy; se agregan cuando
   se sepa exactamente que pregunta van a contestar (mismo criterio que ya
   se uso para la original).
