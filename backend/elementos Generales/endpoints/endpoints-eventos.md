# Endpoints de eventos (ClickHouse)

Rutas y ganchos internos que alimentan las seis tablas de eventos de
producto/buscador en ClickHouse, mas el explorador de admin que las lee
-- ver `elementos Generales/plan pendiente/eventos-clickhouse.md` para el
diseño completo (por que estas tablas, sus columnas, y lo que le toca al
companero). Las seis piezas del plan ya estan construidas:

- **Escritura** -- tres rutas POST publicas (`vista`, `carrito`,
  `busqueda-clic`) y tres registros SIN ruta HTTP propia (`compra_producto`,
  `devolucion_producto`, `busqueda_realizada` -- enganchados directo al
  codigo que ya existe).
- **Lectura** -- `GET /admin/eventos/*` (seis rutas, solo admin): el
  ranking de tendencias de cada tabla, ver la seccion dedicada mas abajo.

Código: `src/controllers/eventos.controller.ts` +
`src/services/eventos/eventos.service.ts` (escritura);
`src/controllers/admin/admin-tendencias.controller.ts` +
`src/services/admin/admin-tendencias.service.ts` (lectura). Cliente nuevo:
`src/database/clickhouse.ts` (mismo patron que `elastic.ts`: HTTP, sin
socket persistente). Helper compartido:
`src/helpers/sesion-opcional.ts` (`idUsuarioDeCookieOpcional`) -- extraido
de `vista` para reusarlo tambien en `busqueda_realizada` y `busqueda-clic`.

Todo el lado de **escritura** es fire-and-forget: nunca retrasa ni tumba
la respuesta al cliente ni la operacion real que la origina
(`EventosService` nunca lanza, mismo criterio que `LogService` y
`FraudeLoginService.registrarIntento`). Las tres rutas POST llaman al
servicio SIN `await` y responden `202` de inmediato; los tres registros
sin ruta (`compra_producto`, `devolucion_producto`, `busqueda_realizada`)
hacen lo mismo desde dentro del código que ya corría (el checkout, la
cancelación, el buscador). El lado de **lectura** (`GET /admin/eventos/*`)
es una consulta normal, sin nada fire-and-forget -- si ClickHouse está
caído, responde `503` como cualquier otra ruta.

---

## POST /eventos/vista

**Pública, sin `SesionGuard`**: la ficha de un producto se puede ver sin
cuenta, y exigir sesión aquí dejaría fuera la mayoría del tráfico que se
quiere medir.

```
POST /eventos/vista
Content-Type: application/json

{ "id_producto": 12, "sesion": "sesion-generada-en-el-navegador", "origen": "catalogo" }
```

| Campo | Obligatorio | Qué es |
|---|---|---|
| `id_producto` | sí | El producto visto. Valida con `validarIdProducto` de `validaciones-inventario.ts` -- mismo campo, mismo mensaje que el resto del proyecto |
| `sesion` | sí | La genera el NAVEGADOR (no el backend), string no vacío. Distingue visitantes anónimos entre sí -- ver `eventos-clickhouse.md` para el porqué |
| `origen` | sí | Uno de `catalogo`, `buscador`, `enlace_directo` |

**`id_usuario` NO viene en el cuerpo.** El controlador lo saca de la
cookie de sesión SI hay una válida (`NOMBRE_COOKIE_TOKEN` +
`verificarToken`, igual que `SesionGuard`, pero sin exigirla: sin cookie,
con cookie vencida, o con un token inválido, simplemente queda `null` --
nunca `401`, esta ruta es pública). Confiar en un `id_usuario` que mandara
el cliente en el cuerpo dejaría que cualquiera reporte vistas a nombre de
otra cuenta.

`ip` sale de `request.ip` (Fastify). `fecha` y `lote` los pone el propio
código: `fecha` es el momento en que el backend recibe la petición
(formateada en la zona horaria del SERVIDOR de ClickHouse,
`America/Guatemala` -- ver el porqué en el comentario de
`formatoFechaClickHouse` en `eventos.service.ts`), `lote` siempre
`'real'` -- si esta ruta lo escribió, no es un dato inventado.

**`request.ip` depende de `trustProxy: 'loopback'` en `main.ts`**
(agregado el 2026-09-19, antes faltaba): sin eso, cualquier petición que
pase por un proxy que corre en la misma máquina (el proxy `/api` de Vite
en desarrollo, o un túnel para entrar desde el celular) llegaba con
`request.ip = 127.0.0.1` sin importar quién visitaba de verdad, porque
Fastify no confiaba en el header `X-Forwarded-For` que trae la IP real.
Con `'loopback'`, Fastify SÍ confía en ese header, pero solo cuando quien
se conectó directo es 127.0.0.1/::1 -- una IP pública cualquiera no puede
falsificarlo. Probado en vivo: una petición con
`X-Forwarded-For: 200.150.10.55` quedó guardada con esa IP real, y una
sin el header siguió guardando `127.0.0.1` normal.

### 202

```json
{ "ok": true, "mensaje": "Vista registrada", "payload": null }
```

`payload` siempre `null`: como es fire-and-forget, el controlador no sabe
(ni le importa) si la escritura en ClickHouse ya terminó cuando responde.

### 400

```json
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La sesion es obligatoria", "payload": null }
{ "ok": false, "mensaje": "El origen debe ser uno de: catalogo, buscador, enlace_directo", "payload": null }
```

Estos tres SÍ se validan antes de intentar escribir nada -- una petición
mal formada no llega ni a intentar el `INSERT`.

## Pruebas -- hechas el 2026-09-18

Contra el servidor y ClickHouse reales (`mesh-clickhouse`), `npm run
start:dev`. Un bug real se encontró y se corrigió en el camino: la primera
version mandaba `fecha` como numero (segundos desde epoch, pensado como
"a prueba de zona horaria"), y ClickHouse via HTTP/JSONEachRow lo rechaza
para `DateTime64` -- un intento con milisegundos como entero tampoco
sirvió, se interpretó mal SIN dar error. Se corrigió armando un string
`"AAAA-MM-DD HH:MM:SS.mmm"` en la zona horaria del servidor
(`Intl.DateTimeFormat` con `timeZone: 'America/Guatemala'`), verificado con
`INSERT`s manuales directos contra ClickHouse antes de aplicarlo al
servicio.

| Caso | Resultado |
|---|---|
| Vista anónima (sin cookie), origen `catalogo` | `202`, fila en ClickHouse con `id_usuario: NULL`, `lote: real` |
| Vista con sesión real (login de `comprador_sur`), origen `buscador` | `202`, fila con `id_usuario: 3` |
| Vista con una cookie con token inválido (basura, no un JWT) | `202`, fila con `id_usuario: NULL` -- no tumbó nada, quedó anónima |
| `id_producto` no numérico | `400` con el mensaje de `validarIdProducto` |
| `origen` fuera de la lista | `400` con los tres valores válidos |
| `sesion` vacía | `400` "La sesion es obligatoria" |

`npx tsc --noEmit` limpio. Las tres filas de prueba (`id_producto` 12, 30 y
50) se dejaron a propósito en la base local -- el usuario pidió verlas,
no se borraron.

---

## POST /eventos/carrito

**Exige sesión** (`@UseGuards(SesionGuard)`) -- a diferencia de `vista`,
el carrito SIEMPRE requiere cuenta en este proyecto (no hay carrito de
invitado, ver memoria `carrito-redis`), así que no hace falta el mecanismo
de "cookie opcional" ni distinguir visitantes anónimos.

```
POST /eventos/carrito
Content-Type: application/json
Cookie: mesh_token=...

{ "id_producto": 12, "id_oferta": 5, "cantidad": 2 }
```

| Campo | Obligatorio | Qué es |
|---|---|---|
| `id_producto` | sí | Reusa `validarIdProducto` de `validaciones-inventario.ts` -- mismo campo, mismo mensaje que `vista` |
| `id_oferta` | sí | Reusa `validarIdOferta` de `validaciones-pedido.ts` (el mismo validador que usa `POST /comprador/pedidos/:id/detalles`) |
| `cantidad` | sí | Reusa `validarCantidadMovimiento` de `validaciones-inventario.ts` -- entero mayor a 0 |

**`id_usuario` sale de `@UsuarioActual()`, nunca del cuerpo ni de una
cookie leída a mano** -- a diferencia de `vista`, aquí SÍ hay `SesionGuard`
protegiendo la ruta, así que el id ya viene verificado antes de llegar al
controlador.

**Por qué se guardan `id_producto` E `id_oferta` juntos (sin normalizar):**
decisión explícita del usuario -- el carrito real opera por oferta
(vendedor + variante), pero la pregunta que más importa de este evento es
"qué tan seguido se agrega ESTE PRODUCTO al carrito" (para saber qué se
vende más), no "qué tan seguido se elige ESTA oferta". Por eso
`ORDER BY (id_producto, fecha)` -- igual que `vista_producto` -- y
`id_oferta` viaja como columna normal, consultable pero sin liderar el
orden físico.

**Por qué NO lleva `sesion` ni `origen`:** `sesion` no hace falta porque
`id_usuario` siempre está (no hay caso anónimo que distinguir). `origen`
se descartó a propósito: no hay un equivalente claro a "por dónde llegaste
a la ficha" para la acción de agregar al carrito.

**Por qué SÍ se queda `ip`, aunque `id_usuario` ya identifique a quien
actuó:** no es "por estándar" -- es para una pregunta futura ya anticipada
(cruzar fraude de login por IP con patrones de carrito entre varias
cuentas, la misma idea de correlación que se habló para el módulo de
anillos de fraude). Sin esa pregunta concreta, no se habría agregado.

### 202

```json
{ "ok": true, "mensaje": "Evento de carrito registrado", "payload": null }
```

### 400

```json
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El id_oferta es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La cantidad es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

Sin cookie, o cookie vencida/inválida -- a diferencia de `vista`, aquí SÍ
es un error: no hay caso anónimo válido para este evento.

## Pruebas -- hechas el 2026-09-18

Contra el servidor y ClickHouse reales, sesión real de `comprador_sur`.

| Caso | Resultado |
|---|---|
| Sin cookie de sesión | `401` "No hay sesion activa" |
| Con sesión real, `id_producto`/`id_oferta`/`cantidad` válidos | `202`, fila en ClickHouse con `id_usuario: 3` (el id real de la sesión, no algo que mandó el cuerpo) |
| `id_oferta` no numérico | `400` con el mensaje de `validarIdOferta` |
| `cantidad: 0` | `400` "La cantidad es obligatoria y debe ser un numero entero mayor a 0" |
| `id_producto` ausente del cuerpo | `400` con el mensaje de `validarIdProducto` |

`npx tsc --noEmit` limpio, sin warnings ni errores en el log del servidor
durante la ronda. La fila de prueba (`id_producto: 12`, `id_oferta: 5`,
`id_usuario: 3`) se dejó en la base local, igual que las de `vista`.

---

## Registro de `compra_producto` -- SIN ruta HTTP

A diferencia de `vista` y `carrito`, esto **no es un endpoint**: no hay
`POST /eventos/compra`. Decisión explícita del usuario, después de discutir
si convenía un worker (como `GrafoSyncService` para reseñas→Neo4j, o
`EventosAutenticacionSyncService` para logueos→Elasticsearch) -- se
descartó porque esos workers existen para proteger datos de los que
depende una decisión real (un panel de fraude, un índice de búsqueda); una
compra perdida en ClickHouse por una caída puntual no tiene ese riesgo, la
venta de verdad ya quedó segura en PostgreSQL sin depender de esto. Y a
diferencia de una vista o un agregado al carrito (acciones de interfaz que
el backend no puede saber que pasaron si el frontend no avisa), una compra
el backend **ya la sabe con certeza** -- no hace falta pedírsela a nadie.

**Dónde vive:** `CarritoService.ejecutarCompraCarrito()`
(`src/services/carrito/carrito.service.ts`), justo después de
`comprar_carrito()` de PostgreSQL confirma el pedido y de `this.vaciar(idUsuario)`.
Llama a `EventosService.registrarCompra()` con `void` (fire-and-forget, sin
`await`) -- una fila POR LÍNEA del pedido, todas en un solo `INSERT`
(ClickHouse prefiere lotes a filas sueltas).

**`ip` tuvo que viajar un nivel más:** `CarritoService` es un servicio, no
un controlador, así que no tenía acceso a `request.ip` directamente. Se
agregó `ip: string` como tercer parámetro de `comprarCarrito()` (y de
`ejecutarCompraCarrito()`), que `CarritoController.comprar()` ahora recibe
con `@Req()` y pasa hacia abajo -- único cambio de firma en código ya
existente que hizo falta.

`compra_producto` usa `ReplacingMergeTree` (por `id_pedido`): protege
contra un reintento de este mismo fire-and-forget si algún día lo hubiera
-- hoy no se reintenta, pero la tabla ya viene preparada.

### Pruebas -- hechas el 2026-09-18

Contra el servidor y las bases reales, con **compras de verdad** (no
simuladas): login real de `comprador_sur`, `PUT /carrito/lineas/:idOferta`
+ `POST /carrito/comprar` con `metodo_pago: "efectivo contra entrega"`.

| Caso | Resultado |
|---|---|
| Compra real (oferta 7, cantidad 1) con ClickHouse arriba | Pedido 20 creado en Postgres; fila en `compra_producto` con `id_producto: 1`, `id_oferta: 7`, `id_usuario: 3`, `cantidad: 1`, `id_pedido: 20` -- todo correcto |
| `docker stop mesh-clickhouse`, luego otra compra real (oferta 4) | Pedido 21 creado en Postgres **normal, en 0.126 s** (medido con `time curl`) -- no bloqueó nada. El evento del pedido 21 **se perdió de verdad**: `SELECT count(*) FROM compra_producto WHERE id_pedido = 21` → `0`, confirmado después de reiniciar ClickHouse. Es el comportamiento esperado y aceptado, no un bug |
| `docker start mesh-clickhouse`, luego otra compra real (oferta 3) | Pedido 22 creado normal, y esta vez SÍ quedó su fila en `compra_producto` -- confirma que el sistema se recupera solo, sin ninguna intervención |

`npx tsc --noEmit` y `eslint` limpios sobre los archivos tocados
(`carrito.controller.ts`, `carrito.service.ts`, `eventos.service.ts`). Las
tres filas de prueba (pedidos 20 y 22 -- el 21 nunca llegó, a propósito) se
dejaron en la base local.

---

## Registro de `devolucion_producto` -- SIN ruta HTTP

Mismo mecanismo exacto que `compra_producto` (mismo razonamiento sobre por
qué no es un worker, ver la sección de arriba): fire-and-forget, sin
`await`, enganchado directo en
`PedidosCompradorService.cancelarPedido()` (`src/services/compradores/pedidos.service.ts`),
llamado desde `POST /comprador/pedidos/:id/cancelar`.

**Solo se registra si el pedido SÍ estaba comprado** (`cancelacion.stock.length > 0`,
el mismo chequeo que ya usaba esta función para decidir si hay que
recalcular los campos calculados de Mongo). Un pedido cancelado estando
`pendiente` nunca tocó stock -- nunca fue una "compra" en el embudo, así
que cancelarlo no es una devolución que valga la pena medir.

**Las columnas quedan idénticas a `compra_producto`** (`fecha`,
`id_producto`, `id_oferta`, `id_usuario`, `cantidad`, `id_pedido`, `ip`,
`lote`) -- se evaluó agregar un campo `motivo`, pero se descartó al
verificar contra la base real: `motivo_movimiento` de PostgreSQL solo
tiene un valor relevante aquí (`devolucion`, genérico, "vuelven las
unidades de un pedido cancelado"), sin ninguna variante más específica que
capturar. Una columna con un solo valor posible no aporta nada.

**De dónde sale `cantidad` (que `cancelar_pedido()` no devuelve):** el
`stock` que devuelve la función solo trae el stock resultante por oferta,
no cuántas unidades se devolvieron. Se agregó una consulta chica a
`pedido_producto` (join con `precio_historial` para sacar `id_oferta`)
por el `id_pedido`, que sí trae `cantidad` -- se ejecuta contra Postgres,
nunca contra ClickHouse, así que no se ve afectada si ClickHouse está
caído.

**`ip` viajó un nivel más**, igual que con `carrito`: se agregó como
tercer parámetro de `cancelarPedido()`, que
`PedidosCompradorController.cancelar()` ahora recibe con `@Req()`.

### Pruebas -- hechas el 2026-09-18

Contra el servidor y las bases reales, con **cancelaciones de verdad** (no
simuladas): compras reales vía `/carrito/comprar`, canceladas vía
`POST /comprador/pedidos/:id/cancelar`.

| Caso | Resultado |
|---|---|
| Cancelar un pedido `pendiente` (creado con `POST /comprador/pedidos`, nunca comprado) | `200`, `stock: []`, **ningún evento** en `devolucion_producto` -- confirmado con `count(*) = 0` |
| Cancelar un pedido real `comprado` (pedido 22), ClickHouse arriba | `200`; fila en `devolucion_producto` con `id_producto: 1`, `id_oferta: 3`, `id_usuario: 3`, `cantidad: 1`, `id_pedido: 22` -- todo correcto |
| `docker stop mesh-clickhouse`, cancelar otro pedido real comprado (pedido 24) | `200` en **0.088 s** (medido con `time curl`) -- no bloqueó nada. El evento del pedido 24 se perdió de verdad, confirmado con `count(*) = 0` tras reiniciar ClickHouse |
| `docker start mesh-clickhouse`, cancelar otro pedido real comprado (pedido 25) | `200`, y esta vez SÍ quedó su fila -- confirma la recuperación automática |

`npx tsc --noEmit` y `eslint` limpios sobre los archivos tocados
(`pedidos.controller.ts`, `pedidos.service.ts`, `eventos.service.ts`). Las
filas de prueba (pedidos 22 y 25 -- el 24 nunca llegó, a propósito) se
dejaron en la base local, igual que con `compra_producto`.

---

## Registro de `busqueda_realizada` -- SIN ruta HTTP

Mismo razonamiento que `compra_producto`/`devolucion_producto`, pero por
una razón distinta: el backend **ya corrió la búsqueda** al procesar
`GET /buscador/productos` -- no hace falta que el frontend avise algo que
el backend ya sabe con certeza (a diferencia de `vista`, donde el backend
no tiene forma de saber que alguien está *viendo* una ficha solo por haber
servido un `GET` anterior, posiblemente cacheado).

**Dónde vive:** `BuscadorProductosController.buscar()`
(`src/controllers/buscador/productos.controller.ts`), después de obtener
los resultados y antes de responder. Fire-and-forget, sin `await`. **Desde
el 2026-09-26, también** `BuscadorFacetadoController.buscar()`
(`GET /buscador/productos/facetado`, ver `endpoints-buscador.md`) -- mismo
patrón, mismo método de `EventosService`, con las cuatro columnas nuevas
de abajo.

**Nunca** desde `GET /buscador/productos/admin`: las búsquedas de un admin
revisando el catálogo no son parte del embudo de un comprador real.

**`sesion` viaja como query param, opcional**, en las dos rutas que
registran este evento. Si no viene (o viene vacío), el evento simplemente
**se salta en silencio** -- la búsqueda responde igual, `sesion` nunca
bloquea ni rechaza nada. `id_usuario` sale de `idUsuarioDeCookieOpcional()`
(el mismo helper que usa `vista`, compartido en
`helpers/sesion-opcional.ts`).

`termino` es el propio `query.nombre` (`''` si no vino), `resultados` es
`resultados.length` de lo que ya se iba a devolver -- ningún cálculo
extra.

**Columnas nuevas (agregadas 2026-09-26, Entrega final -- el buscador
facetado, `elementos Generales/plan pendiente/buscador-facetado-clickhouse.md`):**

| Columna | Tipo | La llena `GET /buscador/productos` (simple) | La llena `.../facetado` |
|---|---|---|---|
| `facetada` | `UInt8` | siempre `0` | `1` |
| `categorias` | `Array(UInt32)` | siempre `[]` | los `id_categoria` de `?categoria=7,9` |
| `precios` | `Array(String)` | siempre `[]` | las claves de `?precio=250-500,...` |
| `calificaciones` | `Array(String)` | siempre `[]` | las claves de `?calificacion=4-o-mas,...` |
| `disponible` | `UInt8` | siempre `0` | `1` si se mandó `?disponible=...` (cualquier valor no vacío) |

Se guarda lo que el CLIENTE eligió (los valores crudos de la query), no lo
que el backend resolvió para armar el filtro real de Elasticsearch --
`BuscadorFacetadoController` reusa `separarPorComas()` (exportada de
`BuscadorFacetadoService`), no vuelve a parsear nada.

### Pruebas -- hechas el 2026-09-18 (búsqueda simple)

Contra el servidor y las bases reales.

| Caso | Resultado |
|---|---|
| `GET /buscador/productos?nombre=laptop` (sin `sesion`) | `200` normal; **ningún evento** en `busqueda_realizada` |
| Igual, con `sesion=sesion-buscador-1`, anónimo | `200`; fila con `termino: laptop`, `resultados: 11`, `id_usuario: NULL` |
| Igual, con sesión real de `comprador_sur` | `200`; fila con `id_usuario: 3` |
| `docker stop mesh-clickhouse`, otra búsqueda con `sesion` | `200` en **0.143 s** -- no bloqueó nada; el evento se perdió de verdad, confirmado tras reiniciar |

`npx tsc --noEmit` y `eslint` limpios. Filas de prueba dejadas en la base
local.

### Pruebas -- hechas el 2026-09-26 (columnas nuevas, las dos rutas)

Contra el servidor y ClickHouse reales.

| Caso | Resultado |
|---|---|
| `GET /buscador/productos/facetado?nombre=laptop&categoria=7,8&precio=1000-3000,desde-3000&calificacion=4-o-mas&disponible=si&sesion=...` | fila con `facetada: 1`, `categorias: [7,8]`, `precios: ['1000-3000','desde-3000']`, `calificaciones: ['4-o-mas']`, `disponible: 1` |
| `GET /buscador/productos/facetado?nombre=telefono` (sin `sesion`) | ninguna fila -- igual que la búsqueda simple |
| `GET /buscador/productos?nombre=laptop&sesion=...` (regresión, la ruta simple) | fila con `facetada: 0` y las cuatro columnas nuevas vacías/`0` -- confirma que ampliar la firma de `registrarBusqueda()` no le cambió el comportamiento a la ruta vieja |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: las tres filas de prueba (`sesion LIKE 'prueba-%'`) borradas con
`ALTER TABLE busqueda_realizada DELETE WHERE ...`.

---

## POST /eventos/busqueda-clic

**Pública, sin `SesionGuard`** -- mismo criterio que `vista`: buscar y
hacer clic en un resultado no exige cuenta. A diferencia de
`busqueda_realizada`, este SÍ necesita ruta propia: hacer clic es una
interacción de interfaz que el backend no puede saber por su cuenta.

```
POST /eventos/busqueda-clic
Content-Type: application/json

{ "termino": "laptop", "id_producto": 5, "posicion": 1, "sesion": "sesion-generada-en-el-navegador" }
```

| Campo | Obligatorio | Qué es |
|---|---|---|
| `termino` | sí | El texto que se buscó -- string no vacío (`validarTerminoEvento`) |
| `id_producto` | sí | Sobre cuál resultado se hizo clic -- reusa `validarIdProducto` |
| `posicion` | sí | En qué lugar de la lista estaba (1-based) -- entero mayor a 0 (`validarPosicionEvento`) |
| `sesion` | sí | Igual que en `vista`/`busqueda_realizada` |
| `facetada` | no | `boolean`. Si el clic vino de un resultado facetado (`GET /buscador/productos/facetado`) |
| `categorias` | no | Arreglo de enteros -- los `id_categoria` que estaban elegidos en ese momento |
| `precios` | no | Arreglo de texto -- las claves de rango elegidas |
| `calificaciones` | no | Arreglo de texto -- las claves de calificación elegidas |
| `disponible` | no | `boolean` -- si el filtro de disponibilidad estaba activo |

Los cinco campos de faceta son **opcionales, agregados 2026-09-26**
(Entrega final, `plan pendiente/buscador-facetado-clickhouse.md`): el
backend no puede saber por su cuenta qué facetas estaban activas en la
pantalla donde se hizo clic -- si el frontend no las manda, quedan en su
default (`false`/`[]`), igual que un clic desde la búsqueda simple.

`id_usuario` opcional, de la cookie si hay una válida (nunca del cuerpo) --
mismo `idUsuarioDeCookieOpcional()` compartido.

### 202

```json
{ "termino": "laptop", "id_producto": 5, "posicion": 1, "sesion": "...", "facetada": true, "categorias": [7], "precios": ["desde-3000"], "calificaciones": ["4-o-mas"], "disponible": true }
```
```json
{ "ok": true, "mensaje": "Clic de busqueda registrado", "payload": null }
```

### 400

```json
{ "ok": false, "mensaje": "El termino es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La posicion es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La sesion es obligatoria", "payload": null }
{ "ok": false, "mensaje": "facetada debe ser verdadero o falso", "payload": null }
{ "ok": false, "mensaje": "categorias debe ser un arreglo de numeros enteros", "payload": null }
{ "ok": false, "mensaje": "precios debe ser un arreglo de texto", "payload": null }
{ "ok": false, "mensaje": "disponible debe ser verdadero o falso", "payload": null }
```

### Pruebas -- hechas el 2026-09-18

| Caso | Resultado |
|---|---|
| Sin `sesion` | `400` "La sesion es obligatoria" |
| Anónimo, con `sesion` | `202`; fila con `id_usuario: NULL` |
| Con sesión real de `comprador_sur` | `202`; fila con `id_usuario: 3` |
| `posicion: 0` | `400` con el mensaje de `validarPosicionEvento` |
| `termino: ""` | `400` "El termino es obligatorio" |
| `docker stop mesh-clickhouse`, otro clic válido | `202` en **0.099 s** -- no bloqueó nada; el evento se perdió de verdad, confirmado tras reiniciar |

`npx tsc --noEmit` y `eslint` limpios. Filas de prueba dejadas en la base
local.

### Pruebas -- hechas el 2026-09-26 (los cinco campos de faceta)

| Caso | Resultado |
|---|---|
| Con las cinco facetas (`facetada: true, categorias: [7], precios: ["desde-3000"], calificaciones: ["4-o-mas"], disponible: true`) | `202`; fila con esos valores exactos |
| Sin ninguna de las cinco (cliente viejo) | `202`; fila con `facetada: 0` y arreglos vacíos -- confirma que un frontend que todavía no manda estos campos sigue funcionando igual |
| `categorias: ["siete"]` (texto en vez de número) | `400` "categorias debe ser un arreglo de numeros enteros" |
| `disponible: "si"` (texto en vez de boolean) | `400` "disponible debe ser verdadero o falso" |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: las dos filas de prueba (`sesion LIKE 'prueba-%'`) borradas con
`ALTER TABLE busqueda_clic DELETE WHERE ...`.

---

# GET /admin/eventos/* -- ranking de tendencias por tabla

Seis rutas de solo lectura, una por tabla, que agregan y ordenan --
**reemplazan** una version anterior (2026-09-18, misma noche) que
devolvia filas crudas ordenadas por fecha, sin agrupar nada. Esa version
se borro por completo (`AdminEventosController`/`AdminEventosService`,
`dto/consultar-eventos.ts`, `models/evento-clickhouse.ts`) porque, en
palabras del usuario, "no servian de nada literalmente" -- un admin no
gana nada mirando eventos sueltos ordenados por fecha, la pregunta real
siempre es "cual es el mas/menos [lo que sea] en los ultimos N dias".

- `GET /admin/eventos/vista`
- `GET /admin/eventos/carrito`
- `GET /admin/eventos/compra`
- `GET /admin/eventos/devolucion`
- `GET /admin/eventos/busqueda`
- `GET /admin/eventos/busqueda-clic`

Código: `src/controllers/admin/admin-tendencias.controller.ts` +
`src/services/admin/admin-tendencias.service.ts`. Nuevos:
`dto/consultar-tendencias.ts`, `models/tendencia-evento.ts`
(`TendenciaProducto`/`TendenciaTermino`). Reusa
`helpers/manejar-error-clickhouse.ts` (sin cambios) y
`helpers/validaciones-eventos.ts` (`validarDiasEvento`/`validarLimiteEvento`
sin cambios; `validarOrdenEvento` se borro y se reemplazo por
`validarDireccionEvento`).

**Solo admin** (`SesionGuard` + `PermisoGuard` con `@Permiso('tendencias.ver')`, en
la clase, y en `rol_permiso` ese permiso solo lo tiene el admin) -- no
la tienda, mismo criterio que el resto de paneles.

## La metrica NO es la misma en las seis tablas

Decision explicita del usuario (2026-09-18), segun que tan facil es
repetir la accion sin que el numero se infle:

- **`vista`, `carrito`** -- se cuentan **personas distintas**, no eventos
  totales: ver una ficha o agregar algo al carrito es una accion de bajo
  esfuerzo que "casi cualquiera puede hacer" varias veces, asi que lo que
  importa es a cuanta gente distinta le intereso. `vista_producto` cuenta
  `sesion` distinta (puede ser anonima); `carrito_producto` **no tiene
  columna `sesion`** en el esquema real (el carrito siempre exige cuenta),
  asi que ahi se cuenta `id_usuario` distinto -- misma idea, columna
  distinta porque la tabla es distinta.
- **`compra`, `devolucion`** -- conteo **normal**, `sum(cantidad)`, igual
  que `MasVendidosSyncService`: completar una compra no es trivial ni
  repetible sin friccion, asi que cada unidad vendida o devuelta cuenta
  por lo que es, sin dividir por persona.
- **`busqueda`, `busqueda-clic`** -- `sesion` distinta, pero agrupado por
  **`termino`**, no por producto: la pregunta es que tan buscado (o
  cliqueado) esta un termino, no un producto puntual. `busqueda-clic`
  podria haberse agrupado por `id_producto` en vez de `termino` (la fila
  trae los dos) -- se eligio `termino` a pedido explicito del usuario.

## Los mismos tres query params en las seis rutas

| Param | Obligatorio | Qué es |
|---|---|---|
| `dias` | no | **N**: cuántos días hacia atrás mirar. Defecto `7`, tope `365` -- un valor fuera de rango se recorta, no rechaza la petición |
| `limite` | no | **M**: cuántos resultados del ranking traer como máximo. Defecto `20`, tope `200`, mismo criterio de recorte |
| `direccion` | no | `positivo` (defecto) -- los primeros M, de mayor a menor métrica. `negativo` -- los últimos M, de menor a mayor |

```
GET /admin/eventos/compra?dias=30&limite=5&direccion=positivo
GET /admin/eventos/vista?dias=7&direccion=negativo
```

**La consulta comparte forma en las seis, solo cambian la tabla, la
columna de agrupación y la métrica** (`AdminTendenciasService.consultarRanking`):

```sql
SELECT <id_producto|termino> AS clave, <metrica> AS total
  FROM <tabla>
 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
   AND lote = 'real'
 GROUP BY <id_producto|termino>
 ORDER BY total <DESC|ASC>
 LIMIT {limite:UInt32}
```

**`AND lote = 'real'` es fijo, sin ningún parámetro para pedir lo
contrario** (agregado el 2026-09-19, antes faltaba): las seis rutas nunca
mezclan con datos sembrados por un script (`lote = 'generado-<semilla>'`)
-- decisión explícita del usuario, "las métricas en todo lugar son sobre
solo los reales, simple". Mismo criterio en `MasVendidosSyncService`.
Probado en vivo: una fila sembrada a mano (`lote: 'generado-prueba-lote'`)
con `cantidad: 999` en un producto ficticio no apareció en ningún
ranking, ni en estas seis rutas ni en `GET /productos/mas-vendidos`.

`dias` y `limite` van por `query_params` de ClickHouse (bind seguro);
`direccion` se interpola directo porque `validarDireccionEvento` ya la
fija a uno de dos literales (`ASC`/`DESC`), nunca texto libre del
cliente. Tabla, columna de agrupación y métrica tampoco vienen del
cliente -- cada ruta los fija a constantes en el propio código.

`total` sale como STRING de ClickHouse en las cuatro consultas
(`count(DISTINCT ...)` y `sum(cantidad)` promueven a `UInt64`, igual que
`id_producto` en `models/evento-clickhouse.ts` de antes) -- se convierte
a `number` en el servicio antes de responder, nunca llega crudo al
cliente.

## Las cuatro que agrupan por producto: segunda consulta a MongoDB

`vista`, `carrito`, `compra` y `devolucion` devuelven `id_producto`, y con
esos ids el servicio pide el detalle real a MongoDB (`$in`, reordenado
para que coincida con el ranking -- Mongo no respeta el orden de la lista
de ids). **A diferencia de `GET /productos/mas-vendidos` (pública), aquí
NO se filtra por `estado`**: un admin explorando tendencias necesita ver
un producto inactivo, en revisión o ya borrado también, no solo lo que un
comprador vería. Un id sin documento en Mongo sale con `producto: null`,
nunca se descarta -- el total sigue siendo un dato válido aunque el
producto ya no exista.

### 200 (ejemplo con `GET /admin/eventos/compra`)

```json
{
  "ok": true,
  "mensaje": "Tendencia de compras obtenida",
  "payload": [
    { "total": 4, "producto": { "_id": 1, "nombre": "Laptop Ambar Campus 14", "...": "..." } }
  ]
}
```

## Las dos que agrupan por término: sin segunda consulta

`busqueda` y `busqueda-clic` devuelven el `termino` tal cual -- no hay
ningún "producto" al que pedirle nombre para un texto de búsqueda, así
que no hacen ninguna consulta a Mongo.

### 200 (ejemplo con `GET /admin/eventos/busqueda`)

```json
{
  "ok": true,
  "mensaje": "Tendencia de busquedas obtenida",
  "payload": [
    { "termino": "laptop", "total": 2 }
  ]
}
```

### 400

```json
{ "ok": false, "mensaje": "dias debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El limite debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "direccion debe ser uno de: positivo, negativo", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto de paneles de admin: sin sesión → `401`;
sesión válida pero no admin (comprador, vendedor, o **la tienda**) → `403`.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con ClickHouse", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

## Pruebas -- hechas el 2026-09-18

Contra el servidor, ClickHouse y MongoDB reales, con sesión real de
`admin_mesh`.

| Caso | Resultado |
|---|---|
| Sin sesión | `401` "No hay sesion activa" |
| Sesión de `comprador_sur` (rol comprador) | `403` "No tienes permiso para hacer esto" |
| Las seis rutas, sin params, con datos reales | `200` en las seis: `vista`/`carrito` con el producto correcto y `total` correcto; `compra`/`devolucion` con el producto y la suma correcta; `busqueda`/`busqueda-clic` con `termino: "laptop"` y su conteo |
| `dias=0` | `400` "dias debe ser un numero entero mayor a 0" |
| `limite=0` | `400` "El limite debe ser un numero entero mayor a 0" |
| `direccion=lateral` | `400` con los dos valores válidos |
| **`carrito`, prueba de aislamiento**: 5 filas insertadas a mano (`lote: generado-prueba-distinct`) para un `id_producto` ficticio, 3 de un `id_usuario` y 2 de otro | `total: 2` -- confirma que es `COUNT(DISTINCT id_usuario)` de verdad, no `COUNT(*)` (que habría dado 5) |
| **`compra`, prueba de aislamiento**: 2 filas insertadas a mano (`lote: generado-prueba-suma`) con `cantidad` 5 y 3 | `total: 8` -- confirma que es `SUM(cantidad)` de verdad, no `COUNT(*)` (que habría dado 2) |
| Producto del ranking sin documento en Mongo (el `id_producto` ficticio de la prueba de aislamiento) | `producto: null`, la fila no se descarta |
| `direccion=positivo` vs `direccion=negativo` | orden confirmado por consulta directa a ClickHouse (con un solo producto en la ventana no se aprecia diferencia en pantalla, pero el `ORDER BY total ASC/DESC` se verificó aparte) |

Las filas de prueba de aislamiento se borraron al terminar (`ALTER TABLE
... DELETE ... SETTINGS mutations_sync = 1`). `npx tsc --noEmit` y
`eslint` limpios. Sin errores en el log del servidor durante toda la
ronda.

## GET /admin/eventos/tendencias | embudo | busquedas-sin-respuesta (agregado 2026-09-25)

Tres consultas nuevas, más específicas que el ranking genérico de arriba --
son las consultas T1/T2/T3 de la propuesta del compañero
(`docs/fraude-entrega3/03-consultas-clickhouse.md`), traducidas tal cual al
driver de Node. **Controller y servicio SEPARADOS**
(`AdminTendenciasAvanzadasController`/`Service`, pedido explícito del
usuario) del `AdminTendenciasController`/`Service` de arriba, aunque
comparten el mismo prefijo de ruta (`/admin/eventos`) y el mismo criterio
de autorización (solo admin).

`GET /admin/eventos/tendencias` es, además, la ruta exacta que el profesor
pidió el 2026-09-06 (directiva verbal, ver memoria `estado-backend-tienda`)
y que nunca se había construido -- se reemplazó en su momento por el
explorador genérico de arriba. Con esto queda cerrada.

Los umbrales de cada consulta (mínimo de vistas, conversión máxima, etc.)
quedan **fijos** en el servicio -- los mismos valores ya probados por el
compañero en `clickhouse/consultas/parametros.txt` -- sin exponerlos como
query param, para no complicar la ruta con parámetros que nadie pidió
ajustar. Solo `dias_recientes`/`dias_base` (tendencias) o `dias_ventana`
(embudo, búsquedas) y `limite` son configurables.

### `GET /admin/eventos/tendencias` (T1 -- en ascenso)

Productos cuyo promedio diario de vistas de los últimos `dias_recientes`
(defecto 7) supera al de los `dias_base` (defecto 21) anteriores, leyendo
el resumen `vistas_por_producto_dia` (la vista materializada que ya
existía) con `countMergeIf`/`uniqMergeIf`. `veces` es cuánto creció;
`vistas_por_persona` va al lado para no confundir una tendencia real con
un producto inflado a punta de vistas (ver F1, todavía sin conectar).

```json
GET /admin/eventos/tendencias
{ "ok": true, "mensaje": "Productos en ascenso obtenidos", "payload": [
  { "por_dia_ahora": 3.6, "por_dia_antes": 0, "veces": 4.57, "vistas_por_persona": 8.3, "producto": { "...": "..." } }
] }
```

### `GET /admin/eventos/embudo` (T2)

Por producto, sesiones/carrito/pedidos/unidades/devueltas de los últimos
`dias_ventana` (defecto 30) días -- **solo los que tienen un problema**:
`mucho_interes_poca_compra` (≥20 sesiones, conversión ≤2%) o
`devolucion_alta` (≥30% de lo vendido vuelve). Pregunta que PostgreSQL no
puede contestar: no guarda los carritos que no terminaron ni las vistas.
`FINAL` en `compra_producto`/`devolucion_producto` (`ReplacingMergeTree`).

### `GET /admin/eventos/busquedas-sin-respuesta` (T3)

Términos buscados (≥3 sesiones distintas) con un problema:
`no_tenemos` (siempre 0 resultados) o `no_convence` (hay resultados,
nadie hizo clic). El término se compara en minúsculas y sin espacios en
las puntas. Sin segunda consulta a Mongo -- el término ya es todo el dato.

### 401 / 403 / 503

Mismo comportamiento que el resto de este archivo (arriba).

### Probado en vivo el 25 de septiembre de 2026

Contra el servidor y las bases reales (Postgres, ClickHouse, MongoDB,
Redis), con sesión real de `admin_mesh`.

| Caso | Resultado |
|---|---|
| Las tres rutas, sin datos sembrados | `tendencias` y `busquedas-sin-respuesta`: `[]` (el dataset real tiene muy pocos eventos -- 63 vistas, 42 búsquedas -- consistente con lo que ya había medido el compañero); `embudo`: 2 productos reales con `devolucion_alta`, con el detalle de Mongo bien resuelto |
| **T1, aislado**: producto ficticio con 25 vistas en 3 sesiones distintas dentro de los últimos 7 días, 0 en los 21 anteriores | aparece con `por_dia_ahora: 3.6`, `veces: 4.57`, `vistas_por_persona: 8.3` -- los tres calculados a mano y verificados contra la fórmula |
| Control: producto ficticio con solo 5 vistas recientes (bajo el mínimo de 20) | no aparece -- confirma el `HAVING` |
| **T2, aislado**: producto ficticio con 20 sesiones y 0 pedidos | aparece con `diagnostico: "mucho_interes_poca_compra"` -- caso que los datos reales no habían disparado |
| Control: producto ficticio con 20 sesiones y 1 pedido (conversión 5% > el máximo de 2%) | no aparece |
| **T3, aislado**: término con 3 sesiones y 0 resultados siempre | `diagnostico: "no_tenemos"` |
| Término con 3 sesiones, resultados pero sin clics | `diagnostico: "no_convence"` |
| Control: término con 3 sesiones, resultados y 1 clic | no aparece |
| ClickHouse real caído (`docker stop`) | `503` "No se pudo conectar con ClickHouse", sin tumbar el resto de la app |
| ClickHouse recuperado | la siguiente consulta responde `200` normal |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

**Encontrado durante las pruebas, no un bug de las consultas:** al limpiar
los datos sembrados de T2 (`vista_producto`), se me olvidó borrar también
lo que esos mismos `INSERT` habían alimentado en
`vistas_por_producto_dia` (la vista materializada de T1 se alimenta de
`vista_producto` automáticamente) -- dos productos ficticios de T2
aparecieron después como falsos positivos en `tendencias`. Corregido
borrando también de la tabla derivada. Queda anotado: sembrar en
`vista_producto` para cualquier prueba futura obliga a limpiar TAMBIÉN
`vistas_por_producto_dia`, no solo la tabla base.

Teardown completo: todas las filas sembradas (`vista_producto`,
`vistas_por_producto_dia`, `compra_producto`, `busqueda_realizada`,
`busqueda_clic`) borradas con `ALTER TABLE ... DELETE`, confirmado con un
barrido final por los cuatro ids/términos de prueba -- cero residuos.

## GET /admin/eventos/busquedas-sin-resultados (agregado 2026-10-16)

**Lo más buscado que no encontró nada**, con las formas de escribir lo mismo
juntas: demanda que la tienda no cubre. Solo admin, en vivo contra ClickHouse
como el resto de este panel (sin worker ni Redis: es una ruta de admin, con
parámetros, y la agregación tarda milisegundos).
`AdminBusquedasSinResultadosService`, en `AdminTendenciasController`.

Es la versión completa del caso `no_tenemos` de `busquedas-sin-respuesta`
(T3, arriba), que compara el término solo en minúsculas y sin espacios en las
puntas. T3 sigue sirviendo para `no_convence` (hay resultados, nadie hace clic).

| Query param | Qué hace |
|---|---|
| `dias` | Cuántos días hacia atrás. Defecto 7, tope 365 (mismo validador que el ranking) |
| `limite` | Cuántos grupos. Defecto 20, tope 200 |

Qué cuenta: `resultados = 0`, `lote = 'real'`, **sin filtros puestos**
(categoría, precio, calificación, disponible: con un filtro el cero puede ser
culpa del filtro). Las búsquedas del facetado sin filtros sí cuentan: son las que
usa el frontend. Métrica: **sesiones distintas**, como las demás tendencias de
búsqueda.

Cómo se juntan:

1. **`termino_normalizado`**, columna `MATERIALIZED` nueva de
   `busqueda_realizada` (minúsculas, sin tildes, sin espacios de más; la calcula
   ClickHouse en cada `INSERT`, el backend sigue mandando solo `termino`). Ver
   `plan pendiente/busquedas-sin-resultados.sql`. El `termino` original no se
   pierde: sale en `como_lo_escribieron`.
2. **Errores de tecleo** con `editDistanceUTF8` entre los 300 términos más
   buscados: 0 cambios si la palabra más corta tiene hasta 4 letras ("tv" y "tb"
   son cosas distintas), 1 hasta 8, 2 desde 9. Cada término se une al **más
   buscado** que tenga cerca, sin encadenar.
3. Las sesiones de cada grupo se cuentan otra vez en ClickHouse: quien buscó dos
   formas del mismo grupo cuenta una vez.

```json
GET /admin/eventos/busquedas-sin-resultados?dias=30
{ "ok": true, "mensaje": "Busquedas sin resultados obtenidas", "payload": [
  { "termino": "audifonos inalambricos", "sesiones": 6,
    "terminos_agrupados": ["audifonos inalambricos", "audifnos inalambricos"],
    "como_lo_escribieron": ["Audífonos inalámbricos", "audifonos  inalambricos", "AUDIFONOS INALAMBRICOS", "audifnos inalambricos"],
    "ultima_busqueda": "2026-10-14T22:10:03Z" }
] }
```

**400** `dias`/`limite` inválidos. **401/403** sin sesión o sin ser admin.
**503** si ClickHouse no responde.

### Probado el 2026-10-16

Con búsquedas fantasma insertadas en ClickHouse (sesiones `zzfantasma-*`, borradas
al terminar):

| Caso | Resultado |
|---|---|
| "Audífonos inalámbricos" escrito de 5 formas (5 sesiones) + "audifnos inalambricos" (2 sesiones, una de ellas también buscó la otra) | un grupo, **6 sesiones**, con las formas originales en `como_lo_escribieron` |
| "freidora de aire" repetida 3 veces por la misma sesión + 3 sesiones más + "freidora de aires" | un grupo, 5 sesiones |
| "silla gamer" (3) + "sillas gamer" (1) | un grupo, 4 |
| "tv" (3) y "tb" (1) | dos grupos: palabras cortas no se juntan |
| Con resultados / con filtro de categoría / de hace 60 días / de otro `lote` | fuera (la de 60 días aparece con `dias=90`) |
| Orden, `limite=2`, `dias=0` y `dias=abc` | bien / 2 / `400` / `400` |
| Por HTTP: tres búsquedas reales por `GET /buscador/productos/facetado` ("Qzxwvy Pérez" ×2, "qzxwvy perez") y la ruta con sesión de admin | la columna se llena sola en el `INSERT` del backend; un grupo "qzxwvy perez", 3 sesiones, con las dos formas escritas; `200` |
| Sin sesión | `401` |

## GET /admin/eventos/categorias-mas-buscadas | precios-mas-buscados | calificaciones-mas-buscadas (agregado 2026-09-26)

Tres rutas más, mismo `AdminTendenciasController`/`Service` de arriba,
mismos tres query params (`dias`, `limite`, `direccion`) y misma
autorización -- pero **no** rankean `busqueda_realizada` agrupada por
`termino` como las seis originales: rankean las **facetas elegidas** en
`GET /buscador/productos/facetado`
(`plan pendiente/buscador-facetado-clickhouse.md`). `disponible` queda
fuera -- es un sí/no, no tiene un "top N" que rankear.

La diferencia técnica con las seis de arriba: `categorias`/`precios`/
`calificaciones` son columnas `Array(...)`, no un valor simple por fila --
una sola búsqueda puede elegir varias (`?categoria=7,9`). La consulta usa
`ARRAY JOIN` para desenrollar el arreglo en una fila por valor antes de
agrupar (`rankingPorFaceta()`, servicio separado del `rankingPorTermino()`/
`rankingPorProducto()` de las otras seis). Una búsqueda sin esa faceta
elegida tiene el arreglo vacío, y `ARRAY JOIN` sobre un arreglo vacío no
produce ninguna fila -- queda fuera del conteo solo, sin necesidad de
filtrar por `facetada`.

```json
GET /admin/eventos/categorias-mas-buscadas?dias=7&limite=10
{ "ok": true, "mensaje": "Tendencia de categorias mas buscadas obtenida", "payload": [
  { "termino": "7", "total": 3 },
  { "termino": "8", "total": 2 }
] }
```

El campo se llama `termino` (mismo `TendenciaTermino` que las rutas
hermanas, para mantener el shape idéntico) aunque acá no sea un texto
buscado: es el id de categoría o la clave del rango elegido, según la
ruta.

### 401 / 403 / 503

Mismo comportamiento que el resto de este archivo.

### Probado en vivo el 2026-09-26

Contra el servidor, Elasticsearch y ClickHouse reales, con sesión real de
`admin_mesh`. Se sembraron seis búsquedas facetadas reales (vía
`GET /buscador/productos/facetado`, no `INSERT` directo) con facetas
conocidas: categoría 7 dos veces más una vez dentro de una búsqueda con
`categoria=7,8`; categoría 8 una vez más esa misma búsqueda combinada;
precio `250-500` dos veces; calificación `3-o-mas` una vez.

| Caso | Resultado |
|---|---|
| Sin sesión | `401` "No hay sesion activa" |
| Con sesión de `mesh_tienda` (no admin) | `403` "No tienes permiso para hacer esto" |
| `categorias-mas-buscadas` | `[{ "termino": "7", "total": 3 }, { "termino": "8", "total": 2 }]` -- exacto, cuenta sesiones DISTINTAS, no búsquedas |
| `precios-mas-buscados` | `[{ "termino": "250-500", "total": 2 }, { "termino": "desde-3000", "total": 1 }, { "termino": "1000-3000", "total": 1 }]` |
| `calificaciones-mas-buscadas` | `[{ "termino": "4-o-mas", "total": 1 }, { "termino": "3-o-mas", "total": 1 }]` |
| `precios-mas-buscados?direccion=negativo` | mismo conjunto, orden invertido (los de `total: 1` primero, `250-500` al final) |
| `categorias-mas-buscadas?dias=abc` | `400` "dias debe ser un numero entero mayor a 0" |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: las seis filas de prueba (`sesion LIKE 'prueba-%'`) borradas de
`busqueda_realizada` con `ALTER TABLE ... DELETE`, confirmado que los
conteos volvieron a su base (5 filas).

## Lo que sigue

Del plan original de eventos (`plan pendiente/eventos-clickhouse.md`) y su
ranking de tendencias, ninguno de este lado -- las seis piezas y el
ranking están construidos y probados. Lo que queda es del lado del
compañero: formalizar el esquema en `clickhouse/001_esquema.sql` y decidir
sobre generadores de datos sembrados -- ver ese documento, sección "Lo que
sigue".

Del buscador facetado (`plan pendiente/buscador-facetado-clickhouse.md`),
tambien nada de este lado -- las cinco columnas nuevas, el registro desde
las dos rutas de búsqueda, `POST /eventos/busqueda-clic` con sus cinco
campos opcionales, y las tres rutas de ranking de facetas, todo construido
y probado en vivo. Le queda al compañero: sumar las mismas
`ALTER TABLE ADD COLUMN` a `clickhouse/001_esquema.sql` (hoy solo existen
aplicadas a mano en la base LOCAL de este entorno) -- ver ese documento
para el `.sql` de referencia exacto.
