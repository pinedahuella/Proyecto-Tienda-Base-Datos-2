# Endpoints de comprador

> **2026-11-07 (migracion 051).** `GET /comprador/pedidos` suma
> `cancelado_por_tienda` (true si lo cancelo la tienda). `POST
> /comprador/pedidos/:id/cancelar` sigue cancelando solo lo `comprado`: un
> pedido `enviado` o `entregado` contesta **409**, porque ya solo lo cancela la
> tienda (`POST /admin/pedidos/:id/cancelar`, en [endpoints.md](endpoints.md)).
> Por dentro ahora llama a `cancelar_pedido_por()` y queda anotado en
> `pedido_cambio_estado`.

Este archivo documenta solo las rutas de `/comprador/*`. Las demás rutas del
backend están en [endpoints.md](endpoints.md) (usuario, perfil, direcciones,
admin), [endpoints-productos.md](endpoints-productos.md) (el catálogo
público) y [endpoints-vendedores.md](endpoints-vendedores.md) (el panel del
vendedor).

**Todas las rutas de aquí requieren la cookie `mesh_token`, pero ninguna
exige un rol en particular.** A diferencia de `/vendedor/*` (solo
`id_rol_usuario` 2) o `/admin/*` (solo 3), comprar no es un privilegio de
un rol: cualquiera con sesión activa puede hacerlo, sea comprador (1),
vendedor (2) o admin (3) — un vendedor también compra en la tienda, y un
admin también podría probarla. Por eso las rutas de aquí llevan
`@UseGuards(SesionGuard, PermisoGuard)` con permisos que los tres roles tienen en
`rol_permiso` (`pedidos.ver`, `pedidos.cancelar` y `avisos.usar`, migracion 050).

El flujo de pedido vive en PostgreSQL, en ocho funciones
(`migrations/007_flujo_pedido.sql`, explicadas en `docs/base-de-datos.md`):
`crear_pedido`, `agregar_linea`, `restar_linea`, `quitar_linea`,
`cambiar_direccion_pedido`, `comprar_pedido`, `cancelar_pedido` y
`reponer_stock` (esta última es del panel del vendedor, no de aquí). Desde el
2026-10-17 las usa el carrito: el pedido `pendiente` de cada cuenta es su
carrito, y `POST /carrito/comprar` lo compra con `cambiar_direccion_pedido` y
`comprar_pedido`. Aquí solo quedan las rutas de leer y de cancelar.

**Ninguna de las funciones comprueba de quién es el pedido** — eso lo hace
el backend antes de llamar a cada una, en una consulta aparte: un pedido
ajeno siempre da el mismo 404 que uno que no existe, nunca un 403 ni un
mensaje que confirme que el pedido existe pero es de otra persona.

**Modelo multi-vendedor.** Se compra una **oferta**, no un producto o una
variante directamente: la misma variante la puede vender media docena de
personas, cada una a su precio y con su propio stock (ver
`docs/base-de-datos.md`). El precio se congela al agregar la oferta al
carrito (`agregar_linea` guarda el id de la fila vigente de
`precio_historial`, que nunca se actualiza), así que subir el precio
después no cambia lo que va a pagar quien ya la tenía en su carrito.

> **2026-10-17:** las rutas que armaban un pedido a mano se quitaron (ver
> "Rutas quitadas el 2026-10-17", abajo). Quedan las de leer y cancelar.
---

## Rutas quitadas el 2026-10-17

Desde el cambio "Redis nunca es la verdad" (ver
`plan pendiente/carrito-postgres-verdad.md` y `endpoints-carrito.md`), el pedido
`pendiente` de cada cuenta **es su carrito**: se arma con `/carrito` y se compra
con `POST /carrito/comprar`. Estas seis rutas armaban un pedido a mano por
fuera del carrito, ninguna pantalla las usaba (revisado en el frontend: el
`modo="pedido"` de `Checkout.svelte` nunca se usa) y lo dejaban desincronizado,
asi que se quitaron. Ahora dan **404**:

| Ruta quitada | Lo que se usa en su lugar |
|---|---|
| `POST /comprador/pedidos` | el carrito nace con el primer `PUT /carrito/lineas/:idOferta` |
| `POST /comprador/pedidos/:id/detalles` | `PUT /carrito/lineas/:idOferta` |
| `PATCH /comprador/pedidos/:id/detalles` | `PUT /carrito/lineas/:idOferta` (cantidad absoluta) |
| `DELETE /comprador/pedidos/:id/detalles/:idDetalle` | `DELETE /carrito/lineas/:idOferta` |
| `PATCH /comprador/pedidos/:id` (direccion) | `id_direccion` en `POST /carrito/comprar` |
| `POST /comprador/pedidos/:id/comprar` | `POST /carrito/comprar` |

Las funciones de PostgreSQL de `migrations/007` siguen ahi; el checkout usa
`comprar_pedido()` y `cambiar_direccion_pedido()`.

**El pendiente no es un pedido todavia:** `GET /comprador/pedidos` no lo lista,
`GET /comprador/pedidos/:id` del pendiente da 404, y
`POST /comprador/pedidos/:id/cancelar` del pendiente da **409** ("Ese pedido es
tu carrito: para vaciarlo usa DELETE /carrito").

---

## GET /comprador/pedidos

Todos los pedidos propios, **resumidos** — no el detalle completo (para
eso está `GET /comprador/pedidos/:id`) y no un historial de eventos. Del
más nuevo al más viejo.

```
GET /comprador/pedidos
```

### 200

```json
{
  "ok": true,
  "mensaje": "Pedidos obtenidos",
  "payload": [
    {
      "id_pedido": "3",
      "fecha_creacion": "2026-08-25T15:16:43.986Z",
      "id_estado_pedido": 1,
      "estado_pedido_nombre": "pendiente",
      "total": "8058.00",
      "cantidad_lineas": 1,
      "metodo_pago": null,
      "estado_pago": null,
      "fecha_cancelacion": null
    },
    {
      "id_pedido": "1",
      "fecha_creacion": "2026-08-25T13:38:51.071Z",
      "id_estado_pedido": 2,
      "estado_pedido_nombre": "comprado",
      "total": "7885.00",
      "cantidad_lineas": 2,
      "metodo_pago": "tarjeta",
      "estado_pago": "pagado",
      "fecha_cancelacion": "2026-08-25T13:39:02.410Z"
    }
  ]
}
```

`total` es la suma de `precio_historial.precio * cantidad` de cada línea
(el precio **congelado** de cada una, no el de hoy) — `"0.00"` si el
pedido todavía no tiene ninguna línea.

**`metodo_pago`, `estado_pago` y `fecha_cancelacion` salen del pago del
pedido** (tabla `Pago`, una sola fila por pedido). Los tres salen `null`
mientras el pedido sigue `pendiente`: todavía no existe el pago, ese nace
recién al comprar (`comprar_pedido()`). Para la primera entrega,
`comprar_pedido()` registra todo pago como `pagado` de una vez (con
`fecha_cancelacion` = el momento de la compra), sin importar el método —
es una simplificación a propósito, no el diseño final; ver
`docs/base-de-datos.md`.

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener los pedidos", "payload": null }
```

---

## GET /comprador/pedidos/metodos-pago

El catálogo (cerrado, tres valores) de formas de pago, para armar el
selector del checkout sin tenerlas escritas a mano en el frontend. Pública
para cualquiera con sesión, sin más.

```
GET /comprador/pedidos/metodos-pago
```

### 200

```json
{
  "ok": true,
  "mensaje": "Metodos de pago obtenidos",
  "payload": [
    { "id_metodo_pago": 1, "metodo_nombre": "tarjeta" },
    { "id_metodo_pago": 2, "metodo_nombre": "transferencia" },
    { "id_metodo_pago": 3, "metodo_nombre": "efectivo contra entrega" }
  ]
}
```

`metodo_nombre` es exactamente lo que hay que mandar en `metodo_pago` de
`POST /comprador/pedidos/:id/comprar` — no el id.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener los metodos de pago", "payload": null }
```

---

## GET /comprador/pedidos/:id

Trae un pedido propio completo de un solo golpe: el pedido, la versión de
la dirección que regía al crearlo, y sus líneas (una lista vacía si
todavía no tiene ninguna). Consulta rápida, no un historial — sale todo de
PostgreSQL sin tocar Mongo.

Solo sobre un pedido propio: `:id` tiene que ser de quien está logueado,
mismo criterio de siempre — un pedido ajeno da el mismo 404 que uno que no
existe.

```
GET /comprador/pedidos/3
```

### 200

```json
{
  "ok": true,
  "mensaje": "Pedido obtenido correctamente",
  "payload": {
    "pedido": {
      "id_pedido": "3",
      "fecha_creacion": "2026-08-25T15:16:43.986Z",
      "id_usuario": "7",
      "id_direccion_historial": "2",
      "id_estado_pedido": 2,
      "estado_pedido_nombre": "comprado"
    },
    "direccion": {
      "id_direccion_historial": "2",
      "id_direccion": "2",
      "pais": "Guatemala",
      "departamento": "Guatemala",
      "ciudad": "Guatemala",
      "direccion_exacta": "6a. Avenida 9-18, Zona 1, Edificio El Centro, Nivel 3",
      "codigo_postal": "01010",
      "fecha_creacion": "2026-08-25T13:38:51.071Z"
    },
    "detalles": [
      {
        "id_pedido_producto": "4",
        "id_pedido": "3",
        "id_precio_historial": "2",
        "id_producto_mongo": "1",
        "id_producto_variante_mongo": "1",
        "cantidad": 2,
        "nombre_producto": "Laptop Nimbo 13",
        "nombre_variante": "8 GB / 256 GB",
        "nombre_vendedor": "Lucia Morales",
        "precio_unitario": "4029.00",
        "id_oferta": "2",
        "id_usuario_vendedor": "6",
        "id_resena": null,
        "puede_resenar": true
      }
    ]
  }
}
```

`direccion` es la fila de `direccion_historial` (la versión congelada al
crear el pedido), no la dirección vigente hoy.

**Modelo multi-vendedor.** Cada línea ya no copia el precio directo: sale
de un JOIN contra `precio_historial` y `oferta`
(`pedido_producto.id_precio_historial -> precio_historial.precio`, y
`precio_historial.id_oferta -> oferta.id_usuario` para saber quién vendió).
`nombre_vendedor` sí sigue copiado en la línea (como `nombre_producto` y
`nombre_variante`): esos tres cambian con el tiempo y no se pueden deducir
del estado de hoy, a diferencia del precio.

**`id_resena` / `puede_resenar` (agregados el 4 de septiembre de 2026)** —
para que la pantalla del pedido pueda ofrecer el botón "Reseñar" por línea
sin pegarle aparte a `GET /resenas/productos/:id/comprado` y
`.../resenado`. Nombre y forma exactos los fija
`docs/BACKEND-PENDIENTE.md` (bloque 5) — el frontend ya está escrito
contra estos dos campos:

- `id_resena`: el id de la reseña si esta cuenta ya reseñó **este producto
  a este vendedor** — el trío `(id_usuario, id_usuario_vendedor,
  id_producto_mongo)`, el mismo que protege el `UNIQUE` de `resena` — o
  `null` si todavía no. Es más preciso que
  `GET /resenas/productos/:id/resenado` (que solo mira el producto, sin
  importar el vendedor): un mismo producto comprado a dos vendedores
  distintos puede tener `id_resena` en una línea y `null` en la otra.
- `puede_resenar`: `true` solo si se cumplen las **cuatro** condiciones a
  la vez — el pedido está pagado (`pago.estado_pago = 'pagado'`) y no está
  `cancelado` (misma condición que `ResenasService.exigirCompraPagada`,
  calculada acá con los mismos JOINs, no una versión distinta), esta línea
  todavía no tiene `id_resena`, y **el vendedor de la línea no sos vos
  mismo** — la tabla `resena` tiene `CHECK (id_usuario <>
  id_usuario_vendedor)`, así que sin esta última condición el botón
  aparecería para una compra a uno mismo y el `POST /resenas` reventaría.

El frontend muestra "Reseñar" cuando `puede_resenar` es `true` (ya
descarta por su cuenta el caso de `id_resena` no nulo).

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener el pedido", "payload": null }
```

**`id_resena`/`puede_resenar` probado en vivo el 4 de septiembre de 2026**
contra un pedido pagado real (dos líneas del mismo producto, vendido por
dos vendedores distintos): las dos líneas nacen `id_resena: null,
puede_resenar: true`; tras publicar una reseña real para una de las dos
(`POST /resenas`), esa línea pasa a `id_resena: 117` (el id real que
devolvió el `POST`) y `puede_resenar: false`, mientras la otra línea
(mismo producto, otro vendedor) se queda en `id_resena: null,
puede_resenar: true` — confirma que compara el trío completo, no solo el
producto, y que el id que se guarda es el real, no un booleano inventado.
Simulando el pedido `cancelado` y, aparte, el pago en `pendiente`, las dos
líneas caen a `puede_resenar: false` (con `id_resena` sin cambiar). Sin
regresión en el resto del payload.

**Corrección del 4 de septiembre de 2026, mismo día:** la primera versión
de este campo usaba `ya_reseno` (booleano) en vez de `id_resena`, y
`puede_resenar` no descartaba el caso de reseñarse a uno mismo — no
coincidía con el contrato ya fijado en `docs/BACKEND-PENDIENTE.md`, contra
el que el frontend ya está escrito. Se corrigió antes de que nadie lo
consumiera; ver `cambio_propuestas/2026-09-04_0810-...md`.

---

## POST /comprador/pedidos/:id/cancelar

Cancela un pedido propio, llamando a `cancelar_pedido(id_pedido)`.

- Si estaba **pendiente**: no toca el stock, porque nunca se descontó.
- Si estaba **comprado**: devuelve las unidades a cada oferta con un
  movimiento de `devolucion` (el libro mayor no se corrige borrando, se
  compensa con la entrada contraria) y pasa el pago a `reembolsado`.
- Si ya estaba `cancelado`, o está `enviado`/`entregado`, se rechaza — no
  se cancela desde aquí.

No recibe cuerpo.

```
POST /comprador/pedidos/3/cancelar
```

### 201

```json
{
  "ok": true,
  "mensaje": "Pedido cancelado correctamente",
  "payload": {
    "id_pedido": 3,
    "estado_previo": "comprado",
    "stock": [
      { "id_oferta": 2, "id_usuario": 6, "id_producto": 1, "id_producto_variante": 1, "stock": 14 }
    ]
  }
}
```

`stock` sale vacío (`[]`) si el pedido estaba `pendiente`: no hubo nada
que devolver. Igual que en `comprar`, cada oferta tocada deja el producto en
`evento_producto` y el worker recalcula en Mongo los cuatro números copiados
(no se recalculan en la petición).

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido <id> ya estaba cancelado", "payload": null }
{ "ok": false, "mensaje": "El pedido <id> ya esta <enviado|entregado> y no se cancela desde aqui", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo cancelar el pedido", "payload": null }
```

---

## Seguimientos de ofertas: "avísame" (agregado 2026-10-17)

Cinco rutas en `/comprador/seguimientos`. El comprador pide que le avisen:

- **`busqueda`**: buscó algo, no lo encontró, y quiere saber cuándo llegue, con
  o sin un precio máximo.
- **`baja_precio`**: está viendo una variante y quiere saber cuándo baje de
  precio, solo en la oferta de la tienda (`solo_tienda: true`) o en la de
  cualquier vendedor.

Cada seguimiento se guarda en PostgreSQL (`seguimiento_oferta`) y, mientras no
se cumple, como una consulta en el **percolator** de Elasticsearch
(`mesh_seguimientos`). Cada oferta que indexa el worker de ofertas se pasa por
ahí. La primera que coincide genera **un solo aviso**
(`aviso_seguimiento_oferta`), el seguimiento queda cumplido y sale del
percolator, así que no se dispara dos veces. Si dos ofertas coinciden en el
mismo lote, el aviso lleva la más barata. Ver
`plan pendiente/seguimiento-ofertas.md`.

Una oferta solo cumple un seguimiento si se puede comprar: activa, con stock,
con la variante y el vendedor activos. Solo avisa cuando una oferta **cambia**
(llega, cambia de precio, de stock o de estado): una que ya cumplía y no se
mueve no dispara nada.

`SesionGuard` + `PermisoGuard` con `@Permiso('avisos.usar')`, que tienen los tres
roles (igual que `/comprador/pedidos`). Cada quien ve
y toca solo lo suyo: lo ajeno responde el mismo 404 que lo que no existe.

## POST /comprador/seguimientos

```json
{ "tipo": "busqueda", "texto": "audifonos brisa verde", "precio_maximo": "500.00" }
```

```json
{ "tipo": "baja_precio", "id_producto": 7, "id_producto_variante": 1, "solo_tienda": true, "precio_referencia": "6000.00" }
```

| Campo | Tipo | Regla |
|---|---|---|
| `tipo` | `busqueda` / `baja_precio` | obligatorio |
| `texto` | texto | `busqueda`: obligatorio, hasta 100 caracteres. Deben aparecer **todas** sus palabras (difuso, sin tildes) entre el nombre del producto y el de la variante |
| `precio_maximo` | texto, hasta 2 decimales, > 0 | `busqueda`: opcional. El precio final no debe pasarlo |
| `id_producto`, `id_producto_variante` | enteros > 0 | `baja_precio`: obligatorios (mismos validadores que `POST /vendedor/ofertas`). La variante debe existir (si no, 404) |
| `solo_tienda` | booleano | `baja_precio`: opcional, `false` por defecto |
| `precio_referencia` | texto, hasta 2 decimales, > 0 | `baja_precio`: opcional. Avisa cuando una oferta quede **por debajo**. Sin él, se toma el precio final más bajo de ese momento entre las ofertas activas con stock (solo de la tienda si `solo_tienda`). Si no hay ninguna, 400 |

Un campo del otro tipo (por ejemplo `texto` con `baja_precio`) da 400, en vez de
ignorarse en silencio.

### 200

```json
{
  "ok": true,
  "mensaje": "Te avisaremos cuando se cumpla",
  "payload": {
    "id_seguimiento": "5",
    "tipo": "baja_precio",
    "texto": null,
    "precio_maximo": null,
    "id_producto": "7",
    "id_producto_variante": "1",
    "nombre_producto": "Laptop Aurora 14",
    "nombre_variante": "16 GB / 512 GB",
    "precio_referencia": "5947.00",
    "solo_tienda": false,
    "fecha_creacion": "2026-10-17T14:37:05.120Z",
    "fecha_cumplido": null,
    "id_aviso": null
  }
}
```

### 400 / 404 / 409 / 503 / 500

- **400**: las reglas de la tabla; `No hay ofertas activas de esa variante: indica precio_referencia`.
- **404**: `No existe esa variante del producto`.
- **409**: `Ya sigues esa busqueda` / `Ya sigues el precio de esa variante` (ya hay uno vivo igual; uno cumplido no cuenta), o `Ya tienes 20 seguimientos activos`.
- **503**: PostgreSQL o Elasticsearch no responden (no queda nada a medias: si Elasticsearch falla, se hace ROLLBACK).

## GET /comprador/seguimientos

`?estado=activos` (los que esperan) o `?estado=cumplidos`. Sin él, todos, del más
nuevo al más viejo. Cada uno con la forma del 200 de arriba; un cumplido trae
`fecha_cumplido` e `id_aviso`. Otro `estado` → 400.

## DELETE /comprador/seguimientos/:id

Borra un seguimiento propio, vivo o cumplido (su aviso se va con él). Uno vivo
sale también del percolator. `200 Seguimiento borrado`; ajeno o inexistente →
404; id no numérico → 400.

## GET /comprador/seguimientos/avisos

`?no_leidos=true` para ver solo los no leídos. Los 50 más nuevos, más el total
de no leídos. La oferta viene **como está ahora**; `precio_final_aviso` es el
precio que tenía cuando avisó.

```json
{
  "ok": true,
  "mensaje": "Avisos obtenidos",
  "payload": {
    "avisos": [
      {
        "id_aviso": "2",
        "leido": false,
        "fecha_aviso": "2026-10-17T14:36:44.861Z",
        "fecha_leida": null,
        "precio_final_aviso": "6627.00",
        "seguimiento": {
          "id_seguimiento": "3",
          "tipo": "baja_precio",
          "texto": null,
          "precio_maximo": null,
          "precio_referencia": "99999.00",
          "solo_tienda": true
        },
        "oferta": {
          "id_oferta": "36",
          "id_producto": "7",
          "id_producto_variante": "1",
          "nombre_producto": "Laptop Aurora 14",
          "nombre_variante": "16 GB / 512 GB",
          "vendedor_usuario": "mesh_tienda",
          "precio_final": "6627.00",
          "stock": 34,
          "estado": "activa"
        }
      }
    ],
    "total_no_leidos": 2
  }
}
```

## PATCH /comprador/seguimientos/avisos/:id

```json
{ "leido": true }
```

`true` lo marca como leído (guarda la fecha; volver a marcarlo no la cambia);
`false` lo deja como no leído otra vez. `leido` que no sea booleano → 400; ajeno o
inexistente → 404.

### Probado en vivo (ligero) -- 2026-10-17

Con `comprador.sur@mesh.com`, tocando ofertas a mano en PostgreSQL. Al final se
dejaron como estaban y se borraron los seguimientos de prueba.

| Caso | Resultado |
|---|---|
| `busqueda` "audifonos brisa verde" hasta Q5000; se activa la oferta 93 (Audífonos Brisa Sport, Verde lima, Q680) | aviso con la oferta 93 en menos de 7 s |
| `busqueda` "telefono nautilo" hasta Q1; se activa la oferta 50 | no avisa (precio) |
| `baja_precio` 7/1, `solo_tienda`, referencia Q99999; se toca la oferta 35 (`ventas_norte`) | no avisa (no es de la tienda) |
| lo mismo; se toca la 36 (tienda) **dos veces** | **un solo** aviso, con la 36; el seguimiento sale del percolator |
| `baja_precio` 7/1 sin referencia | toma Q5947.00, el precio final más bajo de ese momento |
| la misma búsqueda dos veces / sin `tipo` / `texto` con `baja_precio` / variante 999 | 409 / 400 / 400 / 404 |
| marcar leído, no leído, `leido: "si"` | 200 / 200 / 400 |
| otro comprador marca o borra lo ajeno | 404 / 404 |
| borrar los 4 seguimientos | el percolator queda en 0 y sus avisos se van con ellos |

Falta la prueba a fondo: seguimientos de un producto que se crea nuevo,
Elasticsearch caído al crear o al percolar, y una baja de precio real (aquí se
usó una referencia alta para no dejar historial de precios).
