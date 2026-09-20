# Guía de estudio del backend — para la presentación

> Objetivo de este documento: darte el mapa exacto de **qué archivo, qué
> función y qué líneas** repasar para poder explicar el backend en la
> entrega. Está ordenado de lo general a lo específico. Todo lo que dice
> "líneas X–Y" es contra el estado actual del repo; si moviste código,
> confírmalo abriendo el archivo.
>
> Lenguaje del backend: **NestJS + Fastify** (TypeScript). No usa ningún ORM:
> todo es SQL a mano (`pg`), driver oficial de Mongo (`mongodb`), `ioredis` y
> `neo4j-driver`.

---

## 0. Panorama: 4 motores de base de datos, cada uno con su trabajo

| Motor | Archivo de conexión | Qué guarda | Por qué ahí |
|---|---|---|---|
| **PostgreSQL** | `src/database/postgres.ts` | Usuarios, roles, direcciones (+ historial), **ofertas** (precio + stock por vendedor), `precio_historial`, `stock_movimiento`, pedidos, pagos, reseñas/comentarios/likes, propuestas y rechazos | Datos con integridad referencial fuerte y transacciones. Es la **fuente de verdad**. |
| **MongoDB** | `src/database/mongo.ts` | Catálogo: colección `productos` (con variantes, imágenes y características **embebidas**), `productos_eventos` (historial event-sourcing), `categorias` (la "paleta" de características) | Documento flexible, características que varían por categoría, historial reconstruible por fecha. |
| **Redis** | `src/database/redis.ts` | El **carrito de compra** (`mesh:carrito:<id_usuario>`, un HASH `{id_oferta: cantidad}` con TTL 24 h) | Estructura efímera, expira sola por inactividad, no necesita integridad. |
| **Neo4j** | `src/database/neo4j.ts` | Proyección de las reseñas como grafo, para **detección de anillos de fraude** | Consultas de caminos/ciclos que en SQL serían self-joins recursivos carísimos. |

**Frase clave para la defensa:** *"Cada base hace lo que sabe hacer mejor.
Postgres es la fuente de verdad transaccional; Mongo es una vista del
catálogo optimizada para lectura; Redis es estado efímero; Neo4j es una
proyección de solo lectura para analítica de grafos."*

### El puente entre Postgres y Mongo: el `_id` compartido

- El `_id` de un documento `productos` en Mongo **es** el `id_producto`
  (bigserial) de Postgres. No es un `ObjectId`. `mongo/001_productos.js`
  líneas 6–9 lo explican.
- La tabla `oferta` en Postgres guarda `id_producto_mongo` e
  `id_producto_variante_mongo` como `bigint` **sin llave foránea** (igual que
  `pedido_producto`). Ese par de números es el único vínculo entre las dos
  bases; se resuelve en el backend, nunca con un JOIN entre motores (no
  existe tal cosa).

### Cómo se conecta cada base (repaso rápido de los 4 archivos)

- **`postgres.ts`**: un `Pool` de `pg` (conexiones reutilizadas). El
  `pool.on('error')` (líneas 32–34) es obligatorio: en Node un evento
  `error` sin listener mata el proceso.
- **`mongo.ts`** (20 líneas, léelo entero): construye la URI
  `mongodb://user:pass@host:port/?authSource=admin`, exporta `mongoClient` y
  `mongoDb`. El cliente es *lazy*: no conecta hasta la primera consulta.
- **`redis.ts`**: cliente `ioredis` con `commandTimeout: 10000` — así "Redis
  caído" se vuelve un 503 rápido y no una petición colgada. `redis.on('error')`
  por el mismo motivo que Postgres.
- **`neo4j.ts`**: driver Bolt (puerto 7687). `consultarGrafo()` (líneas
  48–61) abre una sesión en **modo READ**, corre el Cypher y la cierra. El
  backend **nunca escribe** al grafo.

### Manejo de errores por motor (helpers)

`src/helpers/manejar-error-*.ts` — cada uno clasifica el error de su motor:
error de conexión → `ErrorConexion` (→ HTTP 503); lo demás se relanza (→ 500).
`manejar-error-db.ts` (Postgres) además traduce códigos SQLSTATE
(`23505` unique, `23503` FK, `23514` check) que las funciones almacenadas
usan como errores de negocio.

---

## 1. MongoDB a fondo

### 1.1 Las colecciones y su forma

Modelos TypeScript: `src/models/producto.ts` y `src/models/producto-evento.ts`
(léelos enteros, son cortos y están muy comentados).

- **`productos`** (`models/producto.ts:83–116`): raíz con `nombre`,
  `descripcion`, `estado`, `categoria` embebida, y **cinco números
  calculados** (`precio_tienda`, `precio_desde`, `stock_tienda`,
  `stock_total`, `total_ofertas`) que también se repiten dentro de cada
  variante. Los precios son `Decimal128`, **no** `number` (para no perder
  centavos). `variantes[]` embebido, cada una con `imagenes[]`,
  `caracteristicas_adicionales[]` y `caracteristicas_personalizadas[]`
  (arrays de `{nombre, valor, unidad}`).
- **`productos_eventos`** (`models/producto-evento.ts`): event sourcing. El
  evento `numero: 1` es `operacion: 'creacion'` y lleva `datos` (copia
  completa); los siguientes son `operacion: 'modificacion'` y llevan
  `cambios` (solo lo que cambió, pero cada campo completo, nunca un diff
  parcial). `_id` es el string `"<id_producto>-<numero>"`.
- **`categorias`**: qué características ofrece cada categoría, con tipo y
  unidad. No lleva valores. Es lo que arma el formulario de publicar.

**Los 5 números calculados son COPIAS**, no la verdad. La verdad (precio,
stock, estado real de cada oferta) vive en la tabla `oferta` de Postgres.
Cada vez que cambia una oferta hay que recalcularlos → ver §2.2.

### 1.2 Los índices de Mongo — dónde se crean y qué consulta los usa

**Se crean en `mongo/001_productos.js`** (carpeta `mongo/` en la raíz del
repo, NO en el backend). Ese archivo dice explícitamente que los índices
"salieron de MEDIR, no de suponer" (líneas ~80–95): se probaron 3 y solo 2
del catálogo se ganaron el puesto (uno, `catalogo_disponibilidad`, se quitó
porque "examinaba casi todo para devolver casi todo").

| Índice | Definición | Consulta del backend que lo usa (archivo:línea) |
|---|---|---|
| **`catalogo_categoria`** | `{ 'categoria.id_categoria': 1, estado: 1, _id: 1 }` | `ProductosService.listar()` y `.construirFiltro()` — `productos.service.ts:105–131` y `:685–687`. Filtra por categoría (igualdad) + estado (igualdad, lista blanca `'activo'`) y ordena por `_id` ascendente (paginación por cursor). El `_id` va **al final** para que salga ya ordenado del índice sin `sort` en memoria. |
| **`catalogo_precio`** | `{ estado: 1, precio_desde: 1 }` | Filtro de rango de precio en `construirFiltro()` — `productos.service.ts:702–705`. Va sobre `precio_desde` (el más barato que se puede *pagar*), no sobre `precio_tienda`. Aquí `_id` **no** puede ir al final: detrás de un rango un índice ya no ordena, se paga un sort en memoria. |
| **`eventos_por_producto_fecha`** | `{ id_producto: 1, fecha: 1 }` | `ProductosService.reconstruirEnFecha()` — pipeline en `productos.service.ts:324–354`, el `$match: { id_producto, fecha: { $lt: fechaLimite } }` + `$sort: { numero: 1 }`. El compuesto sirve para filtrar por producto y recorrer por fecha a la vez. |
| **`categorias_por_nombre`** | `{ nombre: 1 }` | `CategoriasService.listarValidas()` (`vendedores/categorias.service.ts:28–47`, `.sort({ nombre: 1 })`) y la búsqueda de categoría del formulario de publicar. |

> Para la defensa: sabé decir **por qué el orden de las claves importa** en
> `catalogo_categoria` (igualdad → igualdad → orden) y por qué en
> `catalogo_precio` el rango rompe la posibilidad de ordenar por índice.

### 1.3 Operaciones "especiales" de Mongo que usa el backend

Todo esto está en `src/services/productos/productos.service.ts` salvo donde
se indique.

1. **Paginación por cursor** (`listar()`, líneas 105–131): `find(filtro)`
   `.sort({ _id: 1 })` `.limit(n)`; el cursor de la siguiente tanda es el
   `_id` del último documento (`filtro._id = { $gt: despuesDe }`). Sin
   `skip`, escala a scroll infinito.

2. **Proyección con notación de punto sobre subdocumentos de un array**
   (`obtenerEstadosVariante()`, líneas 242–272):
   `projection: { _id: 1, 'variantes.id_producto_variante': 1, 'variantes.estado': 1 }`
   — trae solo esos dos campos de cada variante. Se usa `$in` para pedir
   **todos** los productos de un pedido en **una sola consulta**
   (`_id: { $in: idsUnicos }`), nunca una consulta por línea. Mismo patrón
   en `carrito.service.ts:490–514` y `ofertas.service.ts:977–999`.

3. **`$regex` insensible a mayúsculas Y a tildes** — la joyita.
   - Búsqueda simple del catálogo público: `filtro.nombre = { $regex: escaparRegex(nombre), $options: 'i' }` (`productos.service.ts:672`).
   - Búsqueda "flexible" (panel de tienda): `construirRegexNombreFlexible()`
     en `src/helpers/validaciones-productos.ts:236–262`. Tres pasos:
     (1) escapa metacaracteres de regex; (2) al **texto buscado** le quita
     las tildes con `normalize('NFD')` + borrar el bloque Unicode
     `̀-ͯ` (Combining Diacritical Marks); (3) expande cada vocal a
     una clase de caracteres con todas sus variantes acentuadas
     (`a → [aàáâäAÀÁÂÄ]`). La `ñ` se trata aparte (se parte el string por
     `ñ`) porque `NFD` la descompondría en `n` + tilde y "año" ≠ "ano".
     Comentario largo en las líneas 210–235 y 236–249.

4. **`$elemMatch` para filtrar dentro de un array de subdocumentos**
   (`construirFiltrosDinamicos()`, `productos.service.ts:807–849`): cualquier
   query param que no sea uno de los fijos (lista `CLAVES_RESERVADAS`,
   líneas 66–82) se interpreta como filtro de característica. Se busca en las
   **4 ubicaciones** (`caracteristicas_adicionales` / `_personalizadas`, del
   producto y de la variante) con un `$or`, y dentro de cada una un
   `$elemMatch: { nombre, valor }` — el `$elemMatch` obliga a que `nombre` y
   `valor` sean **del mismo elemento** del array, no de dos distintos.
   - Operadores universales por prefijo: `min_ram=8`, `max_ram=16`,
     `contiene_color=roj` → `interpretarFiltroCaracteristica()`
     (`validaciones-productos.ts:162–188`) los traduce a `$gte` / `$lte` /
     `$regex`. Si el operador no calza con el tipo guardado, simplemente no
     hace match (no es error).
   - Nota de seguridad (comentario en `productos.service.ts:798–806`): la
     clave del query param nunca arma un nombre de campo; siempre entra como
     **valor** dentro de llaves fijas, así que un `$` en el input se compara
     como texto literal.

5. **Comparar dinero como `Decimal128`, no como `number`**
   (`construirRangoDecimal()`, `productos.service.ts:765–780`):
   `rango.$gte = Decimal128.fromString(min)`. Comparar `Decimal128` contra un
   `double` de JS obliga a Mongo a convertir y puede perder centavos en el
   borde del rango.

6. **Lista blanca de estado con `$in: []`** (`construirFiltro()`, líneas
   680–684): la búsqueda pública SOLO muestra `estado: 'activo'`. Si el
   cliente pide `?estado=` con otro valor, se pone `{ $in: [] }` — el idiom
   de Mongo para "nunca hace match" — y devuelve lista vacía, nunca un error.

7. **`updateOne` con `$set` + `$unset` + `arrayFilters`**
   (`recalcularUnProducto()`, `productos.service.ts:600–622`, y
   `ProductosVendedorService.editar()`, `vendedores/productos.service.ts:1211–1265`):
   `arrayFilters: [{ 'v0.id_producto_variante': 123 }, ...]` permite
   actualizar un campo dentro de un elemento concreto de un array embebido
   (`'variantes.$[v0].precio_tienda'`). `$unset` se usa para borrar
   `caracteristicas_adicionales` cuando llega un array vacío.

8. **`findOne` / `insertOne` / `deleteOne` / `deleteMany` sin transacción**:
   Mongo no está configurado como replica set, así que las escrituras van una
   detrás de otra. Cuando hay dos bases involucradas se usa **compensación
   manual** (ver `deshacerProductoMongo` y `compensarRevisionMongo` en
   `vendedores/productos.service.ts:335–348` y `740–767`).

9. **IDs calculados como "máximo + 1"** (no hay bigserial en Mongo):
   - `siguienteIdProducto()` (`vendedores/productos.service.ts:878–887`):
     `find().sort({ _id: -1 }).limit(1)`.
   - `siguienteIdVariante()` (líneas 893–904): **agregación**
     `[{ $unwind: '$variantes' }, { $group: { _id: null, maximo: { $max: '$variantes.id_producto_variante' } } }]`.

### 1.4 El framework de agregación de Mongo — los 3 pipelines del backend

Solo hay tres lugares que usan `.aggregate()`. Estudialos uno por uno.

**A) `$facet` + `$count` — paginación con total en una sola consulta**
`ProductosService.listarPaginado()` — `productos.service.ts:141–182`.
```js
[
  { $match: filtro },
  { $facet: {
      productos: [ { $sort: { _id: 1 } }, { $skip: saltar }, { $limit: limite } ],
      total:     [ { $count: 'total' } ],
  } },
]
```
`$facet` corre **varias sub-pipelines sobre la misma entrada** (la misma
foto del `$match`): así la tanda y el conteo no pueden ver estados distintos,
que es lo que pasaría con dos consultas sueltas. Mismo patrón en
`ProductosVendedorService.listarPropiosPaginado()`
(`vendedores/productos.service.ts:1385–1404`), pero ordenado por
`fecha_creacion: -1`.

**B) `$group` + `$push` + `$reduce` + `$mergeObjects` — reconstruir un
producto a una fecha (event sourcing)**
`ProductosService.reconstruirEnFecha()` — `productos.service.ts:324–354`.
```js
[
  { $match: { id_producto, fecha: { $lt: fechaLimite } } },   // usa eventos_por_producto_fecha
  { $sort:  { numero: 1 } },
  { $group: { _id: '$id_producto',
              eventos: { $push: { datos: '$datos', cambios: '$cambios' } } } },
  { $project: { _id: 0, producto: {
      $reduce: {
        input: '$eventos',
        initialValue: {},
        in: { $mergeObjects: [ '$$value',
                               { $ifNull: ['$$this.datos', {}] },
                               { $ifNull: ['$$this.cambios', {}] } ] },
      } } } },
]
```
Traducción para explicarlo: *ordeno los eventos hasta esa fecha, los junto en
un array, y con `$reduce` los fusiono uno encima del otro (`$mergeObjects`);
como cada evento trae el estado completo de lo que cambió, fusionarlos en
orden reconstruye el documento tal como estaba ese día*. **Todo el trabajo
lo hace Mongo**, no se traen los eventos a Node. `$ifNull` cubre que la
creación tenga `datos` y no `cambios` y viceversa.
- La fecha límite es medianoche del día siguiente en **zona Guatemala
  (-06:00)**, no UTC (líneas 321–322).
- Limitación conocida que hay que mencionar: las **características** no tienen
  historial en el relacional, así que reconstruir a una fecha pasada
  devuelve las características de HOY (comentario en `mongo/001_productos.js`
  y `etl/cargar.js`).

**C) `$unwind` + `$group` + `$max`** — ya citado en §1.3 punto 9
(`siguienteIdVariante`).

### 1.5 La reconstrucción del lado económico NO usa Mongo

`ProductosService.reconstruirOfertaEnFecha()` — `productos.service.ts:396–449`.
El precio y stock históricos de una oferta viven en Postgres
(`precio_historial`, `stock_movimiento`), así que esto son dos `SELECT ... 
ORDER BY fecha DESC LIMIT 1` contra Postgres, en paralelo (`Promise.all`).
Sirve para reconstruir un pedido viejo: `GET /productos/:id/historial` da el
producto como se veía, `GET /productos/ofertas/:id/historial` da el
precio/stock de la oferta comprada.

---

## 2. Las rutas que usan Postgres **y** Mongo juntos (lo más importante)

Este es el corazón de la arquitectura políglota. En **todas**, el patrón es:
**Postgres dice la verdad (qué, cuánto, de quién), Mongo pone el nombre / la
imagen / el estado de la variante**, y las consultas a Mongo son siempre
**en lote** (`$in`), nunca una por fila.

### 2.1 Tabla resumen

| Endpoint | Servicio:función | Postgres | Mongo | Orden / consistencia |
|---|---|---|---|---|
| `GET /productos/:id` | `ProductosService.obtenerPublico` (`productos.service.ts:197–226`) | ofertas reales: `oferta` JOIN `usuarios` JOIN `estado_oferta` WHERE activa ORDER BY precio (`obtenerOfertasReales`, 459–494) | `findOne({_id, estado:'activo'})` | Mongo primero (404 disfrazado si oculto), luego ofertas |
| `GET /productos` y `/paginacion` | `ProductosService.listar` / `listarPaginado` | — | find / aggregate `$facet` | Solo Mongo; los 5 números calculados ya están embebidos |
| `POST /vendedor/ofertas` | `OfertasVendedorService.crear` (`vendedores/ofertas.service.ts:243–358`) | `INSERT oferta` + `SELECT reponer_stock(...)` si hay stock inicial | `findOne` producto visible + variante (validar que existe) | Mongo valida → Postgres inserta → `recalcularCamposCalculados([idProducto])` |
| `PATCH /vendedor/ofertas/:id` | `OfertasVendedorService.editar` (400–497) | `BEGIN` → `UPDATE oferta` (precio/estado) + `SELECT reponer_stock` → `COMMIT` | `findOne` para armar el DTO (nombre/imagen) | Transacción Postgres; al final `recalcularCamposCalculados` |
| `PATCH /vendedor/ofertas/:id/revision` | `OfertasVendedorService.revisar` (527–622) | `BEGIN` → `SELECT ... FOR UPDATE` (sin JOIN) → `UPDATE oferta` (+`INSERT rechazo_oferta`) → `COMMIT` | `findOne` al final para el DTO | `FOR UPDATE` serializa dos revisiones; luego `recalcularCamposCalculados` |
| `GET /vendedor/ofertas` y `/producto/:id` | `OfertasVendedorService.listarPropias` / `obtenerConMisOfertas` | `SELECT oferta ... WHERE id_usuario` | 1 `find({_id:{$in:[...]}})` con todos los productos | 2 consultas totales, nunca 1 por oferta |
| `POST /vendedor/productos` | `ProductosVendedorService.crear` (`vendedores/productos.service.ts:116–202`) | — (solo lee categoría de Mongo) | `insertOne` producto + `insertOne` evento 1 | Solo Mongo. IDs = max+1 |
| `POST /vendedor/productos/propuestas` | `ProductosVendedorService.proponer` (229–327) | `INSERT propuesta_producto` | `insertOne` producto (`en_revision`) + evento | **Mongo primero**; si Postgres falla → `deshacerProductoMongo` (compensación) |
| `PATCH /vendedor/productos/:id/revision` | `ProductosVendedorService.revisarPropuesta` (526–624) | `BEGIN` → `SELECT ... FOR UPDATE` sobre `propuesta_producto` → `UPDATE`/`INSERT rechazo_producto` → `COMMIT` | `updateOne` estado + `insertOne` evento modificación | Mongo se escribe dentro de la tx; si Postgres falla → `ROLLBACK` + `compensarRevisionMongo` |
| `POST /comprador/pedidos/:id/detalles` | `PedidosCompradorService.agregarLinea` (`compradores/pedidos.service.ts:213–269`) | `resolverOferta` (par de ids Mongo) + `SELECT agregar_linea($1,$2::jsonb)` | `obtenerPublico` (nombre producto + validar variante activa) | Backend resuelve nombre; la función SQL **congela el precio** (guarda `id_precio_historial`) |
| `POST /comprador/pedidos/:id/comprar` | `PedidosCompradorService.comprarPedido` (557–626) | `BEGIN` → `revisarCambiosAntesDeComprar` (`SELECT ... FOR UPDATE OF o`) → `SELECT comprar_pedido()` → `COMMIT` | `obtenerEstadosVariante` (`$in`, estado de cada variante) | 1 consulta a Mongo para todas las líneas; luego `recalcularCamposCalculados` |
| `POST /comprador/pedidos/:id/cancelar` | `.cancelarPedido` (636–666) | `SELECT cancelar_pedido()` (devuelve stock si estaba comprado) | — | Si hubo movimiento → `recalcularCamposCalculados` |
| `GET /carrito` | `CarritoService.verCarrito` (`carrito/carrito.service.ts:137–224`) | `SELECT oferta` de todas las líneas (`= ANY($1)`) + estado + vendedor | 1 `find` con projection de todos los productos | Redis (HGETALL) + 1 Postgres + 1 Mongo. Renueva TTL |
| `PUT/DELETE /carrito/lineas/:idOferta` | `.definirCantidad` / `.quitarLinea` | — | — | **Redis puro** (HSET/HDEL + EXPIRE). Cero consultas a Postgres |
| `POST /carrito/comprar` | `CarritoService.comprarCarrito` (315–391) | `SELECT comprar_carrito($1,$2,$3::jsonb,$4)` (crea pedido + líneas + compra en 1 transacción) | (vía `verCarrito`) | `verCarrito` valida → SQL compra → `DEL` carrito → `recalcularCamposCalculados` |
| `GET /productos/:id/resenas` | `ResenasService.listarDeProducto` (`resenas/resenas.service.ts:92–179`) | Todo: `resena` JOIN `comentario` JOIN `usuarios`; respuestas; votos; `puede_calificar` | — (usa `id_producto_mongo` como número, sin consultar Mongo) | Solo Postgres |
| `POST /resenas` | `ResenasService.crear` (261–314) | CTE: `INSERT comentario` → `INSERT resena` en una sentencia | — | Regla de negocio: solo si compró+pagó a ese vendedor (`exigirCompraPagada`) |
| `GET /admin/reportes/*` | `AdminReportesService` | Solo agregación Postgres | — | — |
| `GET /admin/fraude/anillos` | `FraudeService.analizar` | — | — | Solo Neo4j |

### 2.2 `recalcularCamposCalculados()` — el que mantiene Mongo al día

`ProductosService.recalcularCamposCalculados()` / `recalcularUnProducto()` —
`productos.service.ts:509–634`. **Hay que llamarlo después de CUALQUIER cosa
que cambie una oferta**: crear/editar/revisar oferta, comprar, cancelar.

Qué hace: una consulta a Postgres que agrupa las ofertas por variante
(`GROUP BY o.id_producto_variante_mongo`) y calcula con `CASE WHEN` +
`SUM` / `MIN` / `MAX` / `COUNT(DISTINCT ...)`:
- `precio_tienda` = precio de la oferta de la tienda (`MAX(CASE WHEN id_usuario = tienda ...)`)
- `precio_desde` = `MIN` del precio entre todas las ofertas activas
- `stock_tienda`, `stock_total` = `SUM` de stock (solo activas)
- `total_ofertas` = `COUNT(DISTINCT id_usuario)` de ofertas activas

Luego un `updateOne` a Mongo con `$set` + `arrayFilters` para escribir esos
números en la raíz y en cada variante (líneas 600–622). El precio de la raíz
= el mínimo de los precios de tienda de las variantes; los stock de la raíz =
la suma sobre variantes.

**Detalle para la defensa** (líneas 623–633): si el recálculo falla, **NO se
deshace la venta**. La compra ya está confirmada en Postgres (la verdad).
Que la tarjeta del catálogo muestre un número viejo un rato es mala UI, no un
dato incorrecto. Se registra el error y se sigue.

La tienda se identifica **por correo** (`CORREO_TIENDA` en
`src/helpers/constantes.ts`), nunca por un id fijo.

### 2.3 Consistencia entre bases sin transacciones distribuidas

No hay 2-phase commit. Las técnicas que sí se usan, con ejemplos:

1. **Orden Mongo → Postgres + compensación**: `proponer()` escribe el
   producto en Mongo, luego la fila en Postgres; si Postgres falla,
   `deshacerProductoMongo()` borra el documento y sus eventos
   (`vendedores/productos.service.ts:308–324` y `335–348`).
2. **Escritura en Mongo dentro de una transacción Postgres**:
   `revisarPropuesta()` hace `updateOne` a Mongo entre el `BEGIN` y el
   `COMMIT`; si algo después falla → `ROLLBACK` de Postgres +
   `compensarRevisionMongo()` (borra el evento, revierte el estado).
3. **`SELECT ... FOR UPDATE` para serializar**: `comprarPedido()` bloquea las
   filas de `oferta` (`FOR UPDATE OF o` en `revisarCambiosAntesDeComprar`,
   `compradores/pedidos.service.ts:769–796`) desde el chequeo hasta el
   `comprar_pedido()`, para que nadie pause/retire la oferta en la ventana
   entre validar y comprar. `revisar()` de ofertas hace `FOR UPDATE`
   **sin JOIN** a `estado_oferta` a propósito (comentario en
   `vendedores/ofertas.service.ts:516–522`): con el JOIN, el `EvalPlanQual`
   de Postgres le daría un 404 al perdedor de la carrera en vez de un 409.
4. **Precio congelado**: `agregar_linea()` (función SQL) busca la fila
   vigente de `precio_historial` y guarda su `id`, no el precio. Así el
   backend no puede cobrar un precio no publicado, y si el vendedor sube el
   precio, el pedido conserva el que se mostró.

### 2.4 Las funciones almacenadas de Postgres que el backend invoca

**El backend NO las modifica, solo las llama** (`migrations/007_flujo_pedido.sql`,
`012_comprar_carrito.sql`). Sabé qué hace cada una:

| Función | Llamada desde | Qué hace |
|---|---|---|
| `crear_pedido(id_usuario, id_direccion_historial)` | `pedidos.service.ts:80` | Abre un pedido vacío `pendiente` |
| `agregar_linea(id_pedido, linea jsonb)` | `pedidos.service.ts:258` | Agrega/suma una línea; **congela el precio** (guarda `id_precio_historial`) |
| `restar_linea` / `quitar_linea` | `pedidos.service.ts:296`, `343` | −N unidades / quitar la línea |
| `cambiar_direccion_pedido` | `pedidos.service.ts:119` | Solo si el pedido está `pendiente` |
| `comprar_pedido(id_pedido, metodo_pago)` | `pedidos.service.ts:599` | Descuenta stock (`stock_movimiento` motivo `venta`), crea `pago`, pasa a `comprado`. Devuelve el stock resultante de cada oferta |
| `cancelar_pedido(id_pedido)` | `pedidos.service.ts:649` | Si estaba comprado, devuelve unidades (motivo `devolucion`); si `pendiente`, no toca stock |
| `reponer_stock(id_oferta, cantidad, motivo, id_usuario)` | `ofertas.service.ts:326`, `473` | Kardex; solo motivos `reposicion` / `ajuste` |
| `comprar_carrito(id_usuario, id_dir_hist, lineas jsonb, metodo)` | `carrito.service.ts:364` | Crea pedido + todas las líneas + lo compra, **en una sola transacción** |

**Triggers relevantes** (los conocés de nombre): `oferta_registrar_precio` /
`trg_oferta_registrar_precio` (005_ofertas.sql) escribe la fila de
`precio_historial` sola cuando cambia `oferta.precio`; `trg_likes_recontar`
(011_resenas.sql) recuenta `comentario.cantidad_likes` / `cantidad_dislikes`.

### 2.5 El "kardex" de stock

El stock es **aditivo**, nunca un `UPDATE stock = X`. Vive en
`stock_movimiento`: `cantidad` siempre positiva, el signo lo pone
`motivo_movimiento` (`reposicion`/`devolucion` suman, `venta`/`ajuste`
restan). El `oferta.stock` es un cache que las funciones SQL mantienen.
Retirar una oferta = poner estado `retirada`, **nunca un DELETE** (la cadena
`pedido_producto → precio_historial → oferta` tiene 3 `ON DELETE RESTRICT`
seguidos: de ahí sale el precio cobrado y quién vendió).

---

## 3. Redis — el carrito

`src/services/carrito/carrito.service.ts` (léelo entero, 1081 líneas, la
cabecera 78–121 es una mini-clase). Controlador: `carrito/carrito.controller.ts`.

- **Estructura**: `mesh:carrito:<id_usuario>` = HASH `{ <id_oferta>: cantidad }`.
  El carrito es literalmente un `Map<id_oferta, cantidad>` — solo la
  intención. Nombre, precio, stock, imagen NO se guardan (viven en `oferta` y
  `productos`, cambian, una copia se desactualiza en segundos).
- **Comandos usados**: `HSET`, `HDEL`, `HGETALL`, `EXPIRE`, `DEL`. TTL =
  `60*60*24` s de **inactividad** (se renueva `EXPIRE` en cada toque, incluso
  al mirar el carrito).
- **Nace y muere solo**: el primer `HSET` sobre una clave inexistente la
  crea; un HASH sin campos deja de existir; TTL / `DEL` tras checkout /
  `DELETE /carrito` lo borran. No hay ruta "crear carrito".
- **`PUT`/`DELETE` de líneas = Redis puro**, sin tocar Postgres. `GET /carrito`
  y `POST /carrito/comprar` sí resuelven contra las otras dos bases.
- **Dos dispositivos de la misma cuenta comparten carrito** sin hacer nada
  (la clave es el `id_usuario` del token).
- Chequeo de disponibilidad: `evaluarDisponibilidad()` (líneas 444–465) —
  oferta no activa / variante no activa / agotado / stock insuficiente /
  oferta inexistente. Es un pre-chequeo para dar buen mensaje; la verdad la
  vuelve a validar `comprar_carrito()` con `FOR UPDATE`.

---

## 4. Neo4j — detección de anillos de fraude en reseñas

`src/services/fraude/fraude.service.ts` (léelo entero — las 4 consultas
Cypher están al final, líneas 502–595). Ruta: `GET /admin/fraude/anillos`.
Esquema del grafo: `neo4j/001_esquema.cypher` (raíz del repo).

- **El grafo es una PROYECCIÓN de solo lectura** de la tabla `resena`. Lo
  carga el ETL `etl/cargar_grafo.sh`; el backend **solo consulta** (sesión
  en modo `READ`).
- **Modelo** (3 relaciones):
  `(:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)`,
  `(:Resena)-[:SOBRE]->(:Producto)`, `(:Usuario)-[:VIVE_EN]->(:Direccion)`.
- **4 consultas** (`conLimiteDeTiempo` + `Promise.all`, límite 15 s):
  | # | Constante | Qué detecta |
  |---|---|---|
  | A.1 | `CYPHER_GRUPOS_CICLICOS` | Camino cerrado `ESCRIBIO\|CALIFICA_A *4..8` (2–4 cuentas). 2 → `mutuo`, 3+ → `ciclo`. Ancla en la cuenta de menor id para no contar cada rotación |
  | A.2 | `CYPHER_PARES_MISMO_PRODUCTO` | Par que se califica en ambos sentidos sobre el **mismo producto** → `reiterado` |
  | A.4 | `CYPHER_MISMA_DIRECCION` | Cuentas distintas en el mismo nodo `:Direccion` **con calle** (`d.tiene_calle`) → `direccion` |
  | — | `CYPHER_CONTEO` | Tamaño del grafo (denominador de `analizado`) |
- **Cypher que hay que saber leer**: `MATCH camino = (inicio)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)`
  (path de longitud variable), `nodes(camino)`, `WITH ... WHERE ALL(...)`,
  `reduce(...)` para deduplicar, `collect(DISTINCT ...)`, list comprehensions
  `[x IN lista | { ... }]`, `head([ (r)-[:SOBRE]->(p) | p.nombre ])`.
- **Ninguna consulta PRUEBA fraude**: señalan un grupo para que un humano lo
  mire. Contra los datos sembrados devuelven **vacío** y eso es correcto (no
  hay anillos reales). El arnés `neo4j/correr_fraude.sh` siembra un anillo
  falso para demostrar que las consultas sirven.
- **Índices/constraints del grafo** (`neo4j/001_esquema.cypher`):
  - `CONSTRAINT` de unicidad en `Usuario.id`, `Resena.id`, `Producto.id`
    (mismos ids que Postgres) y `Direccion.clave` (texto normalizado, no id —
    porque dos cuentas en la misma casa son 2 filas en `direcciones` pero
    deben caer en 1 nodo). Las constraints **son obligatorias**: el ETL carga
    con `MERGE`, y `MERGE` sin índice no garantiza unicidad en corridas
    concurrentes.
  - `INDEX` en `Usuario.correo` y `Producto.nombre` — los únicos puntos de
    entrada "a mano" (la regla dice: ningún id se teclea).
  - `INDEX` en `Resena.fecha` — para la consulta de ráfagas (A.3, aún no
    usada en el backend).
  - Neo4j community **no** tiene constraints de existencia ni de tipo: "toda
    reseña tiene calificación 1–5" lo garantiza el `CHECK` de Postgres, no el
    grafo. Es el precio de que el grafo sea una proyección.

---

## 5. Rutas de "salud" de cada base (útiles para la demo de arranque)

- `GET /db` → `BaseDatosService` → `SELECT version()` de Postgres.
- `GET /db/documental` → `base-datos-documental.service.ts` →
  `mongoDb.command({ buildInfo: 1 })`. A propósito **no** consulta ninguna
  colección: solo interesa si responde.
- `GET /db/clave-valor` → `base-datos-clave-valor.service.ts` → `redis.ping()`
  + `redis.info('server')` (versión y modo).
- `GET /db/grafo` → `base-datos-grafo.service.ts` → `getServerInfo()` +
  `MATCH (n) RETURN count(n)` (el conteo no es adorno: un grafo vacío
  significa "conecta pero el ETL no cargó nada").

---

## 6. El ETL (contexto — vive en la raíz del repo, no en el backend)

`etl/` carga Mongo desde Postgres. `etl/cargar.js` (cabecera líneas 1–60):

- Escribe `productos`, `productos_eventos`, `categorias`. `_id` determinista
  → correrlo dos veces **actualiza, no duplica**.
- **NO copia**: el precio (ahora es de cada oferta), ni las ofertas (tasa de
  cambio alta → riesgo de inconsistencia en dos bases). Solo viajan los 5
  números agregados por producto/variante.
- El ETL traduce el historial de Postgres (snapshots) a eventos de Mongo:
  rehace los eventos derivados enteros en cada corrida (`replaceOne` del 1 al
  n, `deleteMany` de lo que pase). Los eventos que crea **la aplicación**
  (desde el panel) viven por encima del tope del ETL y no se tocan — salvo si
  la tienda edita un producto que vino del ETL (ese evento nuevo lo puede
  pisar una corrida de `arrancar.ps1 -Etl`).
- El grafo se carga aparte con `etl/cargar_grafo.sh` +
  `etl/extraer_grafo.sql` (normaliza la dirección: minúsculas, sin tildes,
  espacios colapsados).

---

## 7. Guion de repaso de 10 minutos (qué abrir mientras hablás)

1. **`src/database/mongo.ts`** (20 líneas) — cómo conecta.
2. **`mongo/001_productos.js`** — los 4 índices y el argumento "se midió, no
   se supuso". Explicá el orden de claves de `catalogo_categoria`.
3. **`src/services/productos/productos.service.ts`**:
   - `listar()` :105 — paginación por cursor + índice.
   - `listarPaginado()` :150 — `$facet` + `$count`.
   - `reconstruirEnFecha()` :324 — `$group`/`$reduce`/`$mergeObjects` (event sourcing).
   - `construirFiltro()` :641 y `construirFiltrosDinamicos()` :807 —
     `$regex` con tildes, `$elemMatch`, `Decimal128`, lista blanca `$in:[]`.
   - `recalcularCamposCalculados()` :509 — el puente Postgres→Mongo.
4. **`src/services/compradores/pedidos.service.ts`** `comprarPedido()` :557 —
   transacción Postgres + `FOR UPDATE OF o` + consulta a Mongo en lote +
   recálculo. El caso completo de "las dos bases en una operación".
5. **`src/services/carrito/carrito.service.ts`** cabecera :71 +
   `verCarrito()` :137 — Redis + Postgres + Mongo en una vista.
6. **`src/services/fraude/fraude.service.ts`** :502–595 — las consultas Cypher
   y por qué un grafo para esto.
7. **`neo4j/001_esquema.cypher`** — por qué las constraints son obligatorias
   con `MERGE`.

### Preguntas que probablemente te hagan

- *¿Por qué el catálogo en Mongo y no en Postgres?* → características que
  varían por categoría (esquema flexible), historial reconstruible, lectura
  optimizada con documento embebido (una tarjeta se pinta con una sola
  lectura, sin JOINs).
- *¿Por qué las ofertas NO están en Mongo?* → no es tamaño, es **tasa de
  cambio**: precio/stock/estado cambian en cada venta; sostenerlos en dos
  bases duplica el riesgo de inconsistencia. Además Mongo reescribe el
  documento entero en cada update → comprar una camisa reescribiría su
  catálogo completo y dos vendedores pelearían por el mismo documento.
- *¿Cómo mantienen Mongo consistente con Postgres?* → los 5 números son
  copias que se recalculan (`recalcularCamposCalculados`) tras cada cambio de
  oferta; si el recálculo falla no se deshace la venta (Postgres es la
  verdad, la tarjeta miente un rato).
- *¿Qué pasa si Mongo/Redis/Neo4j se caen?* → timeouts cortos → HTTP 503
  aislado, no cuelga el backend (los `.on('error')` y `commandTimeout`).
- *¿Transacciones entre bases?* → no hay 2PC; se usa orden + compensación
  manual, `FOR UPDATE` para serializar, y precio congelado por
  `id_precio_historial`.
