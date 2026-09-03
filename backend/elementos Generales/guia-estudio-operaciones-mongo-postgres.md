# Guía de estudio — creación/edición de productos, ofertas y toda operación que cruza Mongo y PostgreSQL

> Complemento de `guia-estudio-backend.md`, pero enfocado SOLO en lo que
> te van a preguntar más: **dónde se crean y se editan productos, dónde
> viven las ofertas, y cada endpoint que toca las dos bases a la vez**.
> Cada fila dice archivo, función y líneas (contra el estado actual del
> repo — si moviste código, confirmá abriendo el archivo).
>
> Los cuatro archivos que hay que tener abiertos:
> - `src/services/vendedores/productos.service.ts` — crear/editar/proponer/revisar **productos** (casi todo Mongo)
> - `src/services/vendedores/ofertas.service.ts` — crear/editar/revisar **ofertas** (Postgres + recálculo a Mongo)
> - `src/services/productos/productos.service.ts` — catálogo público, ficha, **`recalcularCamposCalculados`**, historial
> - `src/services/compradores/pedidos.service.ts` + `src/services/carrito/carrito.service.ts` — **compra** (las dos bases + Redis)

---

## 0. El modelo mental (30 segundos)

- **El `_id` de `productos` en Mongo ES el `id_producto` (bigserial) de Postgres.** No es `ObjectId`. Ese número es el único puente.
- **Postgres = fuente de verdad.** Ahí viven las ofertas (`oferta`: precio + stock + estado por vendedor), `precio_historial`, `stock_movimiento`, pedidos, pagos, propuestas.
- **Mongo = vista de lectura del catálogo.** Nombre, descripción, categoría, variantes, imágenes, características. Más **cinco números calculados** (`precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total`, `total_ofertas`) que son **copias** de lo que dice Postgres.
- **La tabla `oferta` guarda `id_producto_mongo` e `id_producto_variante_mongo` como `bigint` SIN llave foránea.** No hay JOIN entre motores: el backend resuelve el vínculo en dos consultas.
- Regla de oro de todo endpoint mixto: **Postgres dice qué/cuánto/de quién; Mongo pone el nombre/imagen/estado de variante; las consultas a Mongo van siempre en lote (`$in`), nunca una por fila.**

---

## 1. Creación de productos

| Endpoint | Función | Postgres | Mongo | Notas |
|---|---|---|---|---|
| `POST /vendedor/productos` | `ProductosVendedorService.crear` (`vendedores/productos.service.ts:116‑202`) | **nada** (solo *lee* la categoría de Mongo) | `insertOne` producto + `insertOne` evento nº1 | Solo `tienda@mesh.com` o un admin (`exigirTiendaOAdmin`, `:784`). Nace estado `borrador`. |
| `POST /vendedor/productos/propuestas` | `ProductosVendedorService.proponer` (`:229‑327`) | `INSERT propuesta_producto (id_usuario, id_producto_mongo)` | `insertOne` producto (estado `en_revision`) + evento nº1 | Cualquier vendedor. **Mongo primero, Postgres después.** |

**Por qué el producto NO toca Postgres al crearse:** desde el giro
multi‑vendedor, las migraciones de `productos` en Postgres fueron solo
para el ETL de datos de prueba. Un producto nuevo vive únicamente en
Mongo.

**IDs sin bigserial** (`vendedores/productos.service.ts`):
- `siguienteIdProducto()` (`:878‑887`): `find().sort({_id:-1}).limit(1)` → `+1`.
- `siguienteIdVariante()` (`:893‑904`): **agregación** `$unwind: '$variantes'` + `$group … $max` → `+1`. El id de variante es **global**, no reinicia por producto.
- Riesgo aceptado: dos creaciones en el mismo instante chocan y una falla; se recupera reintentando.

**`construirVariantes()`** (`:917‑1022`): arma cada variante embebida. En
la creación `variantesExistentes` es `null` (nada que emparejar). Valida
nombre, descripción, imágenes y características contra la categoría.

**El evento de creación** (`crearEventoCreacion`, `:1025‑1040`): `_id =
"<idProducto>-1"`, `numero: 1`, `operacion: 'creacion'`, `datos` = copia
completa del producto (event sourcing).

### La compensación de `proponer()` (importante para la defensa)

Las dos escrituras (Mongo y Postgres) están en **bases distintas y no hay
transacción entre ellas**. Orden y recuperación:

1. Se escribe el producto en Mongo (`en_revision`, invisible por la lista blanca) + su evento.
2. `INSERT INTO propuesta_producto` en Postgres.
3. Si el paso 2 falla → **`deshacerProductoMongo()`** (`:335‑348`): `deleteOne` del producto + `deleteMany` de sus eventos.
4. Si ni la compensación funciona: queda un producto `en_revision` sin proponente — invisible por la lista blanca, se registra en el log y sigue el error original.

Por qué Mongo primero: el `_id` único de Mongo ya serializa dos
propuestas que compiten por el mismo id (la segunda falla al insertar el
documento y ni llega a Postgres).

---

## 2. Modificación de productos

| Endpoint | Función | Postgres | Mongo | Consistencia |
|---|---|---|---|---|
| `PATCH /vendedor/productos/:id` | `ProductosVendedorService.editar` (`vendedores/productos.service.ts:1075‑1279`) | **nada** | `updateOne` `$set`/`$unset` + `insertOne` evento de modificación | Solo Mongo. `exigirTiendaOAdmin` va **antes que la validación del id** (el 404 disfrazado gana a cualquier 400). |
| `PATCH /vendedor/productos/:id/revision` | `ProductosVendedorService.revisarPropuesta` (`:526‑624`) | `BEGIN` → `SELECT … FOR UPDATE` sobre `propuesta_producto` → `UPDATE` (aprobar) o `INSERT rechazo_producto` → `COMMIT` | `updateOne` estado + `insertOne` evento — **dentro** de la transacción de Postgres | Si Postgres falla → `ROLLBACK` + `compensarRevisionMongo()` (`:740‑767`) |
| `PATCH /vendedor/productos/:id/reenviar` | `ProductosVendedorService.reenviarPropuesta` (`:638‑706`) | `BEGIN` → `SELECT … FOR UPDATE` sobre `propuesta_producto` → `COMMIT` (no escribe nada) | `updateOne` estado `rechazado`→`en_revision` + evento | La transacción existe **solo para serializar** el cambio de estado contra una revisión simultánea |

**`editar()` — puntos que suelen preguntar:**
- Cada campo es independiente: `null`/ausente = no se toca. Para las dos listas de características, un array (aunque sea vacío) reemplaza la lista completa (`$set` si trae elementos, `$unset` si viene vacía, `:1236‑1251`); `null` = no tocarla.
- `variantes` **nunca borra una variante por omisión**: las que el producto ya tenía y no vienen en el array se conservan tal cual (`construirVariantes`, `:1002‑1019`).
- Una variante del array con `id_producto_variante` que coincide con una existente **conserva ese id, su fecha de nacimiento, su estado real y los cinco campos calculados** (`:968‑997`) — esta ruta no toca ofertas, así que no le corresponde reiniciar esos números.
- Candado del flujo de propuesta (`:1150‑1154`): un producto `en_revision` o `rechazado` da **409** por esta ruta — solo se mueve por `/revision` o `/reenviar`, que dejan constancia en `propuesta_producto`.
- Si cambia la categoría, se revalidan las características que ya existían (producto y variantes no reemplazadas) contra la categoría nueva; si alguna ya no encaja → rechaza toda la edición.

**Por qué Mongo se escribe DENTRO de la transacción de Postgres en
`revisarPropuesta` / `reenviarPropuesta`:** el estado del producto vive
en Mongo, no en Postgres. El `SELECT … FOR UPDATE` sobre la fila de
`propuesta_producto` es lo que serializa dos revisiones simultáneas. Se
escribe primero Mongo (estado + evento), después Postgres; si Postgres
falla se hace `ROLLBACK` y **`compensarRevisionMongo()`** borra el evento
y devuelve el estado anterior. Si la compensación tampoco funciona: se
registra y sigue el error original.

---

## 3. Ofertas (precio y stock por vendedor) — aquí SIEMPRE cruzan las dos bases

Las ofertas viven **solo en PostgreSQL** (`migrations/005_ofertas.sql`,
tabla `oferta`). El catálogo (nombre del producto/variante) vive en
Mongo. Toda ruta de ofertas hace: **Postgres para el dato real → Mongo
(en lote, `$in`) para ponerle nombre → `recalcularCamposCalculados` al
final si algo cambió**.

| Endpoint | Función | Postgres | Mongo | Al final |
|---|---|---|---|---|
| `POST /vendedor/ofertas` | `OfertasVendedorService.crear` (`vendedores/ofertas.service.ts:243‑358`) | `INSERT oferta` (estado `activa` si es la tienda/admin, `pendiente` si es otro vendedor) + `SELECT reponer_stock(...)` si viene `stock_inicial > 0` | `findOne` producto **visible** + validar que la variante existe | `recalcularCamposCalculados([idProducto])` |
| `PATCH /vendedor/ofertas/:id` | `OfertasVendedorService.editar` (`:400‑497`) | `BEGIN` → `UPDATE oferta` (precio/estado) + `SELECT reponer_stock` → `COMMIT` | `find` (en lote) para armar el DTO (nombre/imagen) | `recalcularCamposCalculados([idProductoMongo])` |
| `PATCH /vendedor/ofertas/:id/revision` | `OfertasVendedorService.revisar` (`:527‑622`) | `BEGIN` → `SELECT … FOR UPDATE` **sin JOIN** → `UPDATE oferta` (+ `INSERT rechazo_oferta` si rechaza) → `COMMIT` | `find` al final para el DTO | `recalcularCamposCalculados([idProductoMongo])` |
| `GET /vendedor/ofertas` | `OfertasVendedorService.listarPropias` (`:696‑738`) | `SELECT oferta … WHERE id_usuario` | 1 `find({_id:{$in:[…]}})` con todos los productos distintos | — |
| `GET /vendedor/ofertas/producto/:idProducto` | `OfertasVendedorService.obtenerConMisOfertas` (`:754‑811`) | `SELECT oferta … WHERE id_usuario AND id_producto_mongo` | `findOne` del producto completo | Devuelve el producto con `mi_oferta` embebida en cada variante |
| `GET /vendedor/ofertas/pendientes` | `OfertasVendedorService.listarPendientes` (`:870‑927`) | `SELECT oferta JOIN estado_oferta JOIN usuarios WHERE estado = 'pendiente'` | 1 `find` con `$in` | Cola de revisión (más antigua primero) |

**`crear()` — el detalle del stock inicial (`:321‑336`):** la oferta nace
con `stock = 0`. Si viene `stock_inicial > 0` NO se mete en el `INSERT`:
se repone aparte con `reponer_stock(id_oferta, cantidad, 'reposicion',
id_usuario)` para que el kardex (`stock_movimiento`) explique también
esas unidades. El stock se repone aunque la oferta esté `pendiente` — el
kardex es independiente del estado.

**`editar()` — por qué el `UPDATE` y el `reponer_stock` van en UNA
transacción (`:445‑490`):** si el ajuste de stock revienta (por ejemplo,
dejaría el stock en negativo → `RAISE EXCEPTION`, SQLSTATE `23514`), el
`ROLLBACK` deshace también el cambio de precio/estado. Nunca queda un
precio nuevo guardado mientras el ajuste que vino junto con él falló.
- `ajuste_stock` positivo → `reponer_stock(..., 'reposicion', ...)`; negativo → `reponer_stock(Math.abs(...), 'ajuste', ...)`.
- Re‑envío tras rechazo sin recrear la oferta: una oferta que **nunca fue aprobada** (`fecha_aprobacion` NULL) no puede autoactivarse ni pausarse (409); cualquier edición de precio/stock la deja/devuelve a `pendiente` (`:433‑443`).

**`revisar()` — por qué `SELECT … FOR UPDATE` SIN JOIN a `estado_oferta`
(`:546‑576`, comentario `:516‑522`):** con el JOIN, cuando la otra
transacción cambia `id_estado_oferta` y hace commit, el `EvalPlanQual` de
Postgres re‑evalúa la fila contra la versión vieja de `estado_oferta` y
la descarta → el perdedor de la carrera recibiría un **404** en vez del
**409** correcto. El nombre del estado se resuelve en una segunda
consulta, ya con la fila bloqueada.

**Admin actúa como la tienda (`resolverIdEfectivo`, `:147‑155`):** un
admin que crea/edita/lista ofertas lo hace **bajo la cuenta de
`tienda@mesh.com`**, no bajo su propio id. Pero en `revisar()`,
`id_usuario_aprobo` guarda el id del **token real** (el admin queda como
el admin, no sustituido).

---

## 4. `recalcularCamposCalculados()` — el puente Postgres → Mongo

`ProductosService.recalcularCamposCalculados()` / `recalcularUnProducto()`
— `productos/productos.service.ts:509‑634`.

**Hay que llamarlo después de CUALQUIER cosa que cambie una oferta:**
crear/editar/revisar oferta, comprar pedido, comprar carrito, cancelar
pedido.

Qué hace:
1. Una consulta a Postgres (`:518‑551`) que agrupa las ofertas por variante (`GROUP BY o.id_producto_variante_mongo`) y calcula con `CASE WHEN` + `SUM`/`MIN`/`MAX`/`COUNT(DISTINCT …)`:
   - `precio_tienda` = `MAX(CASE WHEN id_usuario = tienda …)` — el precio de la oferta de la tienda.
   - `precio_desde` = `MIN` del precio entre **todas** las ofertas activas (el más barato que se puede *pagar*).
   - `stock_tienda` / `stock_total` = `SUM` del stock de ofertas activas (solo la tienda / todos).
   - `total_ofertas` = `COUNT(DISTINCT id_usuario)` de ofertas activas.
2. Un `updateOne` a Mongo con `$set` + `arrayFilters` (`:600‑622`) para escribir esos números en la raíz y en cada variante. El precio de la raíz = mínimo de los precios de tienda de las variantes; los stock de la raíz = suma sobre variantes.

**Detalle clave para la defensa (`:623‑633`):** si el recálculo falla,
**NO se deshace la venta**. La compra ya está confirmada en Postgres (la
verdad). Que la tarjeta del catálogo muestre un número viejo un rato es
mala UI, no un dato incorrecto. Se registra el error y se sigue.

La tienda se identifica **por correo** (`CORREO_TIENDA` en
`src/helpers/constantes.ts`), nunca por un id fijo.

---

## 5. La compra — el caso donde entran las TRES/CUATRO bases

### 5.1 Pedido (flujo con detalle previo)

| Endpoint | Función | Postgres | Mongo | Redis |
|---|---|---|---|---|
| `POST /comprador/pedidos` | `PedidosCompradorService.crear` (`compradores/pedidos.service.ts:72`) | `SELECT crear_pedido(id_usuario, id_direccion_historial)` | — | — |
| `POST /comprador/pedidos/:id/detalles` | `.agregarLinea` (`:213‑269`) | `resolverOferta` (par de ids Mongo, consulta directa a `oferta`, `:710‑737`) + `SELECT agregar_linea($1, $2::jsonb)` | `obtenerPublico` (nombre del producto + validar que la variante esté `activa`) | — |
| `POST /comprador/pedidos/:id/comprar` | `.comprarPedido` (`:557‑626`) | `BEGIN` → `revisarCambiosAntesDeComprar` (`SELECT … FOR UPDATE OF o`, `:769‑839`) → `SELECT comprar_pedido($1, $2)` → `COMMIT` | `obtenerEstadosVariante` (`$in`, estado de cada variante) | — |
| `POST /comprador/pedidos/:id/cancelar` | `.cancelarPedido` (`:636‑666`) | `SELECT cancelar_pedido($1)` | — | — |

Después de comprar/cancelar: `recalcularCamposCalculados(idsProducto)`
con los productos que la función SQL devuelve en `compra.stock` /
`cancelacion.stock`.

**`agregarLinea()` — por qué el backend resuelve el nombre pero NO manda
el precio:** `agregar_linea()` (función SQL) busca la fila vigente de
`precio_historial` y guarda su `id` (`id_precio_historial`), no el
precio. Así el backend **no puede cobrar un precio no publicado**, y si
el vendedor sube el precio después, el pedido conserva el que se mostró.
El nombre del vendedor tampoco se manda: lo pone la función, leyéndolo de
`usuarios`.

**`comprarPedido()` — por qué el chequeo y la compra van en UNA
transacción con `FOR UPDATE OF o` (`:539‑549`):** sin esto había una
ventana angosta — `revisarCambiosAntesDeComprar` y `comprar_pedido()`
eran dos consultas sueltas, y entre una y otra alguien podía
pausar/retirar la oferta (`PATCH /vendedor/ofertas/:id`) sin que
`comprar_pedido()` (que solo revisa stock, nunca estado) se enterara. Con
el bloqueo tomado desde el chequeo, ese PATCH se queda esperando.

**`revisarCambiosAntesDeComprar()` (`:769‑839`) — la única consulta que
mezcla ambos mundos en el mismo `for`:**
- Bloqueante: oferta ya no `activa`, variante desactivada (esto sale de Mongo, `obtenerEstadosVariante`), o `stock < cantidad`.
- Aviso (no bloquea): `precio_actual !== precio_congelado` — lo que se cobra sigue siendo el congelado, pero se informa. Sin `confirmar_cambios: true` la respuesta sale con `comprado: false` y la lista de avisos, sin tocar nada.
- La comparación de precios es **texto contra texto** (dos `numeric(12,2)` formateados igual), no números de JS: exacto, sin redondeo binario.

### 5.2 Carrito (Redis + Postgres + Mongo)

`src/services/carrito/carrito.service.ts`. Estructura en Redis:
`mesh:carrito:<id_usuario>` = HASH `{ <id_oferta>: cantidad }`, TTL 24 h
de inactividad.

| Endpoint | Función | Redis | Postgres | Mongo |
|---|---|---|---|---|
| `GET /carrito` | `verCarrito` (`:137‑224`) | `HGETALL` + `EXPIRE` (renueva TTL) | `consultarOfertas` — `SELECT oferta … WHERE id_oferta = ANY($1)` + estado + vendedor (`:467`) | `consultarProductos` — 1 `find` con projection de todos los productos distintos (`:490`) |
| `PUT /carrito/lineas/:idOferta` | `definirCantidad` (`:232‑250`) | `HSET` + `EXPIRE` | — | — |
| `DELETE /carrito/lineas/:idOferta` | `quitarLinea` (`:257`) | `HDEL` | — | — |
| `POST /carrito/comprar` | `comprarCarrito` (`:315‑391`) | (vía `verCarrito`) luego `DEL` | `SELECT comprar_carrito($1,$2,$3::jsonb,$4)` — crea pedido + todas las líneas + compra **en 1 transacción** | (vía `verCarrito`) |

**`PUT`/`DELETE` de líneas = Redis puro**, cero consultas a Postgres o
Mongo: el carrito guarda solo la intención (`Map<id_oferta, cantidad>`).
Nombre, precio, stock, imagen NO se guardan — una copia se desactualiza
en segundos.

**`comprarCarrito()` orden:** `verCarrito` (valida y enriquece) → si algo
no se puede comprar → 409 con la lista, sin tocar nada → resolver
`id_direccion_historial` + mock de tarjeta → `SELECT comprar_carrito(...)`
→ `DEL` carrito → `recalcularCamposCalculados`. El pre‑chequeo de
disponibilidad es para dar buen mensaje; la verdad la vuelve a validar
`comprar_carrito()` con `FOR UPDATE`. Si el recálculo falla, la compra
NO se deshace (mismo criterio que `comprarPedido`).

---

## 6. Historial / reconstrucción por fecha

| Endpoint | Función | De dónde sale |
|---|---|---|
| `GET /productos/:id/historial?fecha=` | `ProductosService.reconstruirEnFecha` (`productos/productos.service.ts:298‑367`) | **Solo Mongo**: agregación sobre `productos_eventos` (`$match` + `$sort` + `$group $push` + `$reduce`/`$mergeObjects`). Todo el trabajo lo hace Mongo, no se traen los eventos a Node. |
| `GET /productos/ofertas/:id/historial?fecha=` | `ProductosService.reconstruirOfertaEnFecha` (`:396‑449`) | **Solo Postgres**: dos `SELECT … ORDER BY fecha DESC LIMIT 1` en paralelo (`Promise.all`) contra `precio_historial` y `stock_movimiento`. |
| `GET /vendedor/productos/:id/historial` | `ProductosVendedorService.obtenerHistorialPropio` (`:1464‑1471`) | Solo agrega el chequeo "tienda o admin" y delega en `reconstruirEnFecha`. |

- Fecha límite: medianoche del día siguiente en **zona Guatemala (‑06:00)**, no UTC (`:321‑322`).
- **Limitación que hay que mencionar:** las características no tienen historial en el relacional, así que reconstruir a una fecha pasada devuelve las características **de HOY** (el ETL solo conoce las de hoy y las repite en todas las fotos).
- En `reconstruirOfertaEnFecha`: que no aparezca ninguna fila de `precio_historial` = la oferta no existía en esa fecha (el trigger `oferta_registrar_precio` siempre escribe una al nacer). Que no aparezca fila de `stock_movimiento` = stock 0 (una oferta sin stock inicial no escribe ninguna hasta la primera reposición).

---

## 7. Consistencia entre bases sin transacciones distribuidas (no hay 2PC)

| Técnica | Dónde | Cómo |
|---|---|---|
| **Orden Mongo → Postgres + compensación** | `proponer()` (`vendedores/productos.service.ts:229‑327`, `deshacerProductoMongo` `:335‑348`) | Escribe el producto en Mongo, luego la fila en Postgres; si Postgres falla, borra el documento y sus eventos. |
| **Escritura en Mongo DENTRO de una transacción Postgres** | `revisarPropuesta()` / `reenviarPropuesta()` (`:526‑624`, `:638‑706`) | `updateOne` a Mongo entre `BEGIN` y `COMMIT`; si algo falla → `ROLLBACK` + `compensarRevisionMongo()` (`:740‑767`). |
| **`SELECT … FOR UPDATE` para serializar** | `comprarPedido` (`FOR UPDATE OF o`, `compradores/pedidos.service.ts:794`), `revisar` de ofertas (`FOR UPDATE` **sin JOIN**, `vendedores/ofertas.service.ts:557`), `revisarPropuesta` (sobre `propuesta_producto`) | El bloqueo va desde el chequeo hasta el `COMMIT`, para que nadie cambie la fila en la ventana entre validar y escribir. |
| **Precio congelado** | `agregar_linea()` (función SQL) — llamada desde `pedidos.service.ts:258` y dentro de `comprar_carrito` | Guarda `id_precio_historial`, no el precio. El backend no puede cobrar un precio no publicado. |
| **Recálculo best‑effort** | `recalcularCamposCalculados` tras cada cambio de oferta/compra | Si falla, NO se deshace la venta: Postgres es la verdad, la tarjeta miente un rato. |

---

## 8. Las funciones almacenadas de Postgres que el backend SOLO llama (no modifica)

`migrations/007_flujo_pedido.sql`, `012_comprar_carrito.sql`,
`005_ofertas.sql`. El backend las usa tal cual.

| Función | Llamada desde | Qué hace |
|---|---|---|
| `crear_pedido(id_usuario, id_direccion_historial)` | `pedidos.service.ts:72` (aprox.) | Abre un pedido vacío `pendiente`. |
| `agregar_linea(id_pedido, linea jsonb)` | `pedidos.service.ts:258` | Agrega/suma una línea; **congela el precio** (`id_precio_historial`). |
| `restar_linea` / `quitar_linea` | `pedidos.service.ts:296`, `:343` (aprox.) | −N unidades / quitar la línea. |
| `comprar_pedido(id_pedido, metodo_pago)` | `pedidos.service.ts:599` | Descuenta stock (`stock_movimiento` motivo `venta`), crea `pago`, pasa a `comprado`. Devuelve el stock resultante de cada oferta. |
| `cancelar_pedido(id_pedido)` | `pedidos.service.ts:649` | Si estaba comprado, devuelve unidades (motivo `devolucion`); si `pendiente`, no toca stock. |
| `reponer_stock(id_oferta, cantidad, motivo, id_usuario)` | `ofertas.service.ts:326`, `:473` | Kardex; solo motivos `reposicion` / `ajuste` (nunca `venta`/`devolucion`). |
| `comprar_carrito(id_usuario, id_dir_hist, lineas jsonb, metodo)` | `carrito.service.ts:364` | Crea pedido + todas las líneas + lo compra, en **una sola transacción**. |

**Triggers que hay que conocer de nombre:** `oferta_registrar_precio`
(`005_ofertas.sql`) escribe la fila de `precio_historial` sola cuando
cambia `oferta.precio` — la aplicación no tiene que acordarse.

**El "kardex" de stock:** el stock es **aditivo**, nunca `UPDATE stock =
X`. Vive en `stock_movimiento`: `cantidad` siempre positiva, el signo lo
pone `motivo_movimiento` (`reposicion`/`devolucion` suman,
`venta`/`ajuste` restan). `oferta.stock` es un cache que las funciones
SQL mantienen. Retirar una oferta = poner estado `retirada`, **nunca un
DELETE** (la cadena `pedido_producto → precio_historial → oferta` tiene
tres `ON DELETE RESTRICT` seguidos).

---

## 9. Códigos SQLSTATE que el backend traduce a errores de negocio

`src/helpers/manejar-error-db.ts`. Las funciones almacenadas usan `RAISE
EXCEPTION` con estos códigos como forma de comunicar reglas de negocio:

| Código | Significa | Ejemplo en este proyecto |
|---|---|---|
| `23505` unique_violation | UNIQUE roto | `oferta` duplicada: `UNIQUE(id_usuario, id_producto_mongo, id_producto_variante_mongo)` → 409 "Ya tenés una oferta sobre esta variante" (`ofertas.service.ts:1001‑1009`). También el `UNIQUE(id_producto_mongo)` de `propuesta_producto`. |
| `23514` check_violation | CHECK roto / `RAISE` de una función | `reponer_stock` con motivo inválido o stock que quedaría negativo (`ofertas.service.ts:1084‑1094`). |
| `23503` foreign_key_violation | FK rota | (usuarios/direcciones; las ofertas ya no tienen FK contra el catálogo) |

---

## 10. Guion de 10 minutos (qué abrir mientras hablás)

1. **`src/database/mongo.ts`** (20 líneas) + el concepto del `_id` compartido.
2. **`vendedores/productos.service.ts` `crear()` `:116`** — creación 100% Mongo, IDs `max+1`, evento nº1.
3. **`vendedores/productos.service.ts` `proponer()` `:229`** — Mongo → Postgres + `deshacerProductoMongo`. La compensación manual.
4. **`vendedores/productos.service.ts` `revisarPropuesta()` `:526`** — Mongo dentro de la transacción de Postgres + `FOR UPDATE` + `compensarRevisionMongo`.
5. **`vendedores/ofertas.service.ts` `crear()` `:243` y `editar()` `:400`** — Postgres es la verdad de la oferta, Mongo pone el nombre, `reponer_stock` para el kardex, transacción precio+stock, `recalcularCamposCalculados` al final.
6. **`vendedores/ofertas.service.ts` `revisar()` `:527`** — `FOR UPDATE` **sin JOIN** y por qué (EvalPlanQual → 404 vs 409).
7. **`productos/productos.service.ts` `recalcularCamposCalculados()` `:509`** — el puente Postgres→Mongo, best‑effort, los cinco números son copias.
8. **`compradores/pedidos.service.ts` `comprarPedido()` `:557`** + `revisarCambiosAntesDeComprar` `:769` — transacción Postgres + `FOR UPDATE OF o` + consulta a Mongo en lote + precio congelado + recálculo. El caso completo.
9. **`carrito/carrito.service.ts` `verCarrito()` `:137`** — Redis + Postgres + Mongo en una vista; `PUT`/`DELETE` = Redis puro.

### Preguntas probables

- *¿Por qué el catálogo en Mongo y las ofertas en Postgres?* → El catálogo: esquema flexible por categoría, historial reconstruible, lectura optimizada (una tarjeta se pinta con una sola lectura). Las ofertas: no es tamaño, es **tasa de cambio** — precio/stock/estado cambian en cada venta; sostenerlos en dos bases duplica el riesgo de inconsistencia, y Mongo reescribiría el documento entero en cada compra.
- *¿Cómo mantienen Mongo consistente con Postgres?* → Los cinco números calculados son copias que se recalculan (`recalcularCamposCalculados`) tras cada cambio de oferta; si el recálculo falla no se deshace la venta.
- *¿Transacciones entre bases?* → No hay 2PC. Orden + compensación manual (`deshacerProductoMongo`, `compensarRevisionMongo`), `FOR UPDATE` para serializar, y precio congelado por `id_precio_historial`.
- *¿Qué pasa si un producto se crea en Mongo pero falla Postgres al proponerlo?* → `deshacerProductoMongo` borra el documento y sus eventos; si eso también falla, queda `en_revision` invisible por la lista blanca y se registra.
- *¿Por qué un producto nuevo no toca Postgres?* → Desde el giro multi‑vendedor el producto no es de nadie; solo la oferta (que sí es de Postgres) lo es. Las migraciones de `productos` en Postgres solo sirvieron para el ETL de datos de prueba.
