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
  explorador de filas crudas, ver la seccion dedicada mas abajo.

Código: `src/controllers/eventos.controller.ts` +
`src/services/eventos/eventos.service.ts` (escritura);
`src/controllers/admin/admin-eventos.controller.ts` +
`src/services/admin/admin-eventos.service.ts` (lectura). Cliente nuevo:
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
los resultados y antes de responder. Fire-and-forget, sin `await`.

**Solo la ruta PÚBLICA** (`GET /buscador/productos`), nunca
`GET /buscador/productos/admin`: las búsquedas de un admin revisando el
catálogo no son parte del embudo de un comprador real.

**`sesion` viaja como query param nuevo, opcional:**
`GET /buscador/productos?nombre=...&sesion=...`. Si no viene (o viene
vacío), el evento simplemente **se salta en silencio** -- la búsqueda
responde igual, `sesion` nunca bloquea ni rechaza nada. `id_usuario` sale
de `idUsuarioDeCookieOpcional()` (el mismo helper que usa `vista`, ahora
compartido en `helpers/sesion-opcional.ts`).

`termino` es el propio `query.nombre` (`''` si no vino), `resultados` es
`resultados.length` de lo que ya se iba a devolver -- ningún cálculo
extra.

### Pruebas -- hechas el 2026-09-18

Contra el servidor y las bases reales.

| Caso | Resultado |
|---|---|
| `GET /buscador/productos?nombre=laptop` (sin `sesion`) | `200` normal; **ningún evento** en `busqueda_realizada` |
| Igual, con `sesion=sesion-buscador-1`, anónimo | `200`; fila con `termino: laptop`, `resultados: 11`, `id_usuario: NULL` |
| Igual, con sesión real de `comprador_sur` | `200`; fila con `id_usuario: 3` |
| `docker stop mesh-clickhouse`, otra búsqueda con `sesion` | `200` en **0.143 s** -- no bloqueó nada; el evento se perdió de verdad, confirmado tras reiniciar |

`npx tsc --noEmit` y `eslint` limpios. Filas de prueba dejadas en la base
local.

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

`id_usuario` opcional, de la cookie si hay una válida (nunca del cuerpo) --
mismo `idUsuarioDeCookieOpcional()` compartido.

### 202

```json
{ "ok": true, "mensaje": "Clic de busqueda registrado", "payload": null }
```

### 400

```json
{ "ok": false, "mensaje": "El termino es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La posicion es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La sesion es obligatoria", "payload": null }
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

---

# GET /admin/eventos/* -- explorador de las seis tablas

Seis rutas de solo lectura, una por tabla, para que un admin pueda mirar
las filas crudas sin entrar a `clickhouse-client` a mano:

- `GET /admin/eventos/vista`
- `GET /admin/eventos/carrito`
- `GET /admin/eventos/compra`
- `GET /admin/eventos/devolucion`
- `GET /admin/eventos/busqueda`
- `GET /admin/eventos/busqueda-clic`

**Nunca agrupan ni calculan tendencias** ("los 10 productos más vistos",
etc.) -- son las filas tal cual quedaron guardadas, en una ventana de
tiempo. Si algún día hace falta un panel de tendencias de verdad, es una
pieza aparte, no esta.

Código: `src/controllers/admin/admin-eventos.controller.ts` +
`src/services/admin/admin-eventos.service.ts`. Nuevo:
`helpers/manejar-error-clickhouse.ts` (mismo patrón que
`manejar-error-elastic.ts`: distingue un error que sí devolvió el
servidor de ClickHouse -- `ClickHouseError`, se relanza tal cual, 500 --
de uno que ni siquiera logró conectarse -- `ErrorConexion`, 503).

**Solo admin** (`SesionGuard` + `@Roles(ID_ROL_ADMIN)`, en la clase) -- no
la tienda, mismo criterio que el resto de paneles.

**Los mismos tres query params en las seis rutas:**

| Param | Obligatorio | Qué es |
|---|---|---|
| `dias` | no | Cuántos días hacia atrás mirar. Defecto `7`, tope `365` (el mismo horizonte que el `TTL` de las tablas) -- un valor fuera de rango se recorta, no rechaza la petición |
| `limite` | no | Cuántas filas como máximo. Defecto `20`, tope `200`, mismo criterio de recorte |
| `orden` | no | `recientes` (defecto, `ORDER BY fecha DESC`) o `antiguos` (`ASC`) |

```
GET /admin/eventos/vista?dias=7&limite=20&orden=recientes
```

**La consulta es la misma en las seis, solo cambia la tabla:**

```sql
SELECT * FROM <tabla>
 WHERE fecha >= now() - INTERVAL {dias:UInt32} DAY
 ORDER BY fecha <ASC|DESC>
 LIMIT {limite:UInt32}
```

`dias` y `limite` van por `query_params` de ClickHouse (bind seguro, no
interpolación); `orden` se interpola directo porque `validarOrdenEvento`
ya lo fija a uno de dos literales (`ASC`/`DESC`), nunca texto libre del
cliente. El nombre de tabla tampoco viene del cliente -- cada ruta lo fija
a una constante en el propio código.

### 200 (ejemplo con `GET /admin/eventos/carrito`)

```json
{
  "ok": true,
  "mensaje": "Eventos de carrito obtenidos",
  "payload": [
    {
      "fecha": "2026-09-18 17:12:27.958",
      "id_producto": "12",
      "id_oferta": "5",
      "id_usuario": "3",
      "cantidad": 2,
      "ip": "::ffff:127.0.0.1",
      "lote": "real"
    }
  ]
}
```

La forma de cada fila depende de la tabla -- son las mismas columnas
documentadas arriba para cada evento, sin transformar nada.

### 400

```json
{ "ok": false, "mensaje": "dias debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El limite debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "orden debe ser uno de: recientes, antiguos", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto de paneles de admin: sin sesión → `401`;
sesión válida pero no admin (comprador, vendedor, o **la tienda**) → `403`.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con ClickHouse", "payload": null }
```

## Pruebas -- hechas el 2026-09-18

Contra el servidor y ClickHouse reales, con sesión real de `admin_mesh`.

| Caso | Resultado |
|---|---|
| Sin sesión | `401` |
| Sesión de `comprador_sur` (rol comprador) | `403` |
| `GET /admin/eventos/vista` sin params | `200`, las filas reales de prueba de esta misma sesión, más recientes primero |
| Las otras cinco rutas (`carrito`, `compra`, `devolucion`, `busqueda`, `busqueda-clic`), sin params | `200` en las seis, cada una con sus columnas correctas |
| `orden=antiguos` | `200`, la fila más vieja primero (orden invertido, confirmado) |
| `dias=0` | `400` "dias debe ser un numero entero mayor a 0" |
| `orden=lateral` | `400` con los dos valores válidos |
| `limite=999` | `200` (se recorta a 200 en silencio, no rechaza) |
| Fila sembrada a mano con `fecha = now() - INTERVAL 10 DAY`, consultada con `dias=5` | **no aparece** -- confirma que el filtro de ventana excluye de verdad, no es solo un `LIMIT` |
| La misma fila, consultada con `dias=15` | **sí aparece** -- confirma que la ventana también incluye cuando corresponde |

Fila de prueba de la ventana de días borrada al terminar (`ALTER TABLE ...
DELETE`, la única forma de borrar en `MergeTree`). `npx tsc --noEmit` y
`eslint` limpios. Sin errores en el log del servidor durante toda la
ronda.

## Lo que sigue

Ninguno -- las seis piezas del plan
(`plan pendiente/eventos-clickhouse.md`) ya están construidas y probadas.
Lo que queda es del lado del compañero: formalizar el esquema en
`clickhouse/001_esquema.sql` y decidir sobre generadores de datos
sembrados -- ver ese documento, sección "Lo que sigue".
