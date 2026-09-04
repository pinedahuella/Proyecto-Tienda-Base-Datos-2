# Endpoints de comprador

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
admin también podría probarla. Por eso ninguna ruta de aquí lleva
`@Roles(...)`, solo `@UseGuards(SesionGuard)`.

El flujo de pedido vive en PostgreSQL, en ocho funciones
(`migrations/007_flujo_pedido.sql`, explicadas en `docs/base-de-datos.md`):
`crear_pedido`, `agregar_linea`, `restar_linea`, `quitar_linea`,
`cambiar_direccion_pedido`, `comprar_pedido`, `cancelar_pedido` y
`reponer_stock` (esta última es del panel del vendedor, no de aquí). Las
siete primeras ya tienen ruta.

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

---

## POST /comprador/pedidos

Abre un pedido vacío, en estado `pendiente`. No agrega ninguna línea
todavía y no toca stock — `crear_pedido` en PostgreSQL nunca lo toca.

```json
{ "id_direccion": 1 }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_direccion` | Sí | El id normal de una dirección propia (el que devuelve `GET /direccion-usuario`) — no el `id_direccion_historial` |

**`id_usuario` nunca viene en el cuerpo.** Sale del token de sesión, igual
que en el resto del proyecto: nadie puede crear un pedido a nombre de otro
usuario pasando su id.

### De `id_direccion` a `id_direccion_historial`

La función de PostgreSQL `crear_pedido(id_usuario, id_direccion_historial)`
no recibe el `id_direccion` normal — recibe la **versión congelada** de esa
dirección en `direccion_historial`, para que el pedido siempre diga a dónde
se mandó de verdad, así la persona edite su dirección después. Esta ruta
resuelve internamente cuál es la versión más reciente antes de llamar a la
función, y esa misma consulta ya exige que la dirección sea del usuario
logueado — **una dirección ajena da el mismo 404 que una que no existe**.

### 201

```json
{
  "ok": true,
  "mensaje": "Pedido creado correctamente",
  "payload": { "id_pedido": "8" }
}
```

`id_pedido` sale como texto: es un `bigserial` de PostgreSQL, y el driver
`pg` entrega los `bigint` como `string` para no perder precisión.

### 400

```json
{ "ok": false, "mensaje": "El id_direccion es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo crear el pedido", "payload": null }
```

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
        "puede_resenar": true,
        "ya_reseno": false
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

**`puede_resenar` / `ya_reseno` (agregados el 4 de septiembre de 2026)** —
para que la pantalla del pedido pueda ofrecer el botón "Reseñar" por línea
sin pegarle aparte a `GET /resenas/productos/:id/comprado` y
`.../resenado`:

- `puede_resenar`: `true` si esta línea cumple la regla de
  `POST /resenas` — el pedido está pagado (`pago.estado_pago = 'pagado'`) y
  no está `cancelado`. Es la misma condición que ya exige
  `ResenasService.exigirCompraPagada` al publicar la reseña; se calcula acá
  con los mismos JOINs, no una versión distinta.
- `ya_reseno`: `true` si esta cuenta ya reseñó **este producto a este
  vendedor** — el trío `(id_usuario, id_usuario_vendedor,
  id_producto_mongo)`, el mismo que protege el `UNIQUE` de `resena`. Es más
  preciso que `GET /resenas/productos/:id/resenado` (que solo mira el
  producto, sin importar el vendedor): un mismo producto comprado a dos
  vendedores distintos puede tener `ya_reseno: true` en una línea y `false`
  en la otra.

El frontend muestra "Reseñar" cuando `puede_resenar && !ya_reseno`.

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

**`puede_resenar`/`ya_reseno` probado en vivo el 4 de septiembre de 2026**
contra un pedido pagado real (dos líneas del mismo producto, vendido por
dos vendedores distintos): las dos líneas nacen `puede_resenar: true,
ya_reseno: false`; tras publicar una reseña para una de las dos, esa línea
pasa a `ya_reseno: true` y la otra (mismo producto, otro vendedor) se
queda en `false` — confirma que compara el trío completo, no solo el
producto. Simulando el pedido `cancelado` y, aparte, el pago en
`pendiente`, las dos líneas caen a `puede_resenar: false`. Sin regresión
en el resto del payload.

---

## PATCH /comprador/pedidos/:id

Cambia a qué dirección apunta un pedido, llamando a
`cambiar_direccion_pedido(id_pedido, id_direccion_historial)`. **Solo
mientras el pedido sigue `pendiente`** — mismo criterio que agregar/quitar
una línea: una vez `comprado`, `id_direccion_historial` ya es la versión
que regía cuando se pagó, y cambiarla después reescribiría a dónde se dijo
que se mandó de verdad.

Mismo `id_direccion` que `POST /comprador/pedidos` (no
`id_direccion_historial`): el backend resuelve internamente cuál es la
versión más reciente en `direccion_historial`, exigiendo de paso que esa
dirección sea de quien está logueado — una dirección ajena o inexistente
da el mismo 404. Un pedido ajeno también da el mismo 404 que uno que no
existe.

```
PATCH /comprador/pedidos/14
{ "id_direccion": 4 }
```

### 200

```json
{
  "ok": true,
  "mensaje": "Direccion actualizada correctamente",
  "payload": { "id_pedido": 14, "id_direccion": 4 }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El id_direccion es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe una direccion con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido 14 esta comprado y ya no se puede cambiar", "payload": null }
```

### 401 / 503 / 500

Mismos casos que las demás rutas.

---

## POST /comprador/pedidos/:id/detalles

Agrega una **oferta** al pedido — o, si esa oferta ya estaba en el pedido,
**le suma la cantidad** a la línea existente (nunca crea una segunda línea
para la misma oferta). Una oferta por llamada, no admite lote.

```json
{ "id_oferta": 12, "cantidad": 2 }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_oferta` | Sí | Entero mayor a 0 — el `id_oferta` de PostgreSQL, tal como lo devuelve la lista `ofertas` de `GET /productos/:id` |
| `cantidad` | Sí | Entero mayor a 0 — la que se agrega **esta vez**, no la total |

Solo sobre un pedido propio: `id_pedido` (`:id` en la URL) tiene que ser de
quien está logueado, y da el mismo 404 que uno inexistente si no lo es.

### `id_producto`, `id_producto_variante`, los nombres y el precio: los resuelve el backend

El cliente **solo manda `id_oferta` y `cantidad`**. El backend hace el
resto por su cuenta, sin confiar en nada más que mande el cliente:

1. busca la oferta en PostgreSQL para sacar el par de ids del catálogo en
   Mongo (`id_producto_mongo`, `id_producto_variante_mongo`) — una oferta
   inexistente da 404;
2. con esos ids, pide el producto público a Mongo (mismo mecanismo que
   `GET /productos/:id`, incluyendo que un producto `borrador`/`inactivo`
   da el mismo 404 que uno inexistente) para sacar `nombre_producto` y
   `nombre_variante`. **Una variante `inactiva` da el mismo 404** que una
   que no existe — no se puede agregar al carrito en ninguno de los dos
   casos, aunque el producto en sí esté `activo`;
3. llama a `agregar_linea(id_pedido, linea_jsonb)`, que congela el precio
   ahí mismo (guarda el id de la fila vigente de `precio_historial`) y
   pone el nombre del vendedor leyéndolo de `usuarios` — nunca del
   parámetro.

Así, si el vendedor sube el precio después, esta línea conserva el que se
le mostró a quien compró, y nadie puede mandar un nombre o un precio
falso.

### El stock se comprueba, no se descuenta ni se reserva

`agregar_linea` mira el stock real de la oferta y avisa si no alcanza,
pero no descuenta ni aparta nada — es un aviso temprano, no una garantía.
Si dos personas meten la última unidad de la misma oferta en su pedido, se
la lleva la primera que compre (`POST /comprador/pedidos/:id/comprar`): la
segunda recibirá "no hay suficiente stock" al intentar comprar, aunque al
agregar la línea sí le haya alcanzado. Que **otro** vendedor tenga stock de
la misma variante no estorba: son ofertas distintas.

```
POST /comprador/pedidos/3/detalles
{ "id_oferta": 2, "cantidad": 2 }
-> primera vez: cantidad: 2

POST /comprador/pedidos/3/detalles
{ "id_oferta": 2, "cantidad": 1 }
-> misma oferta otra vez: cantidad: 3 (sumada, sigue siendo una sola linea)
```

### 201

```json
{
  "ok": true,
  "mensaje": "Producto agregado al pedido",
  "payload": {
    "id_pedido": 3,
    "id_pedido_producto": 4,
    "id_oferta": 2,
    "id_usuario_vendedor": 6,
    "cantidad": 2,
    "stock_disponible": 14
  }
}
```

`cantidad` es la **acumulada** (lo que ya tenía esa línea, más lo que se
acaba de agregar), no la de esta llamada sola. Los ids de este payload en
particular salen como `Number`, no como `string` — a diferencia del resto
de la API: es lo único que devuelve un `jsonb` de PostgreSQL en vez de una
fila normal, y JSON no distingue un `bigint` de un `number`.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El id_oferta es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La cantidad es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe una variante con ese id en este producto", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido <id> esta <estado> y ya no se puede cambiar", "payload": null }
{ "ok": false, "mensaje": "La oferta <id> esta <estado> y no se puede comprar", "payload": null }
{ "ok": false, "mensaje": "No hay suficiente stock de \"<nombre_variante>\": quedan <n> y el pedido pide <n>", "payload": null }
```

Estos mensajes salen tal cual los levanta `agregar_linea` en PostgreSQL —
ya son claros y seguros de mostrar, así que el backend no los reescribe.
"El pedido pide" es la cantidad **acumulada** que quedaría, no solo la de
esta llamada.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo agregar el producto al pedido", "payload": null }
```

---

## PATCH /comprador/pedidos/:id/detalles

El "-1" de la ruta anterior: **resta** cantidad de una oferta que ya está
en el pedido, llamando a `restar_linea(id_pedido, id_oferta, cantidad)`.
Mismo cuerpo que `POST /comprador/pedidos/:id/detalles` (`id_oferta` +
`cantidad`), pero resta en vez de sumar.

**Si la resta deja la cantidad en 0 o menos, la línea se borra entera**
— incluso si `cantidad` pide restar más de lo que había: no es un error,
simplemente la quita del pedido (`eliminada: true` en la respuesta, sin
`id_pedido_producto`). No hace falta pedir
`DELETE .../detalles/:idDetalle` aparte para ese caso.

Solo mientras el pedido sigue `pendiente` — mismo criterio que las demás
rutas que modifican un pedido. Una oferta que no está en el pedido, o un
pedido que ya no admite cambios, dan 409. Un pedido ajeno da el mismo 404
de siempre.

```
PATCH /comprador/pedidos/15/detalles
{ "id_oferta": 3, "cantidad": 1 }
```

### 200 (queda con cantidad > 0)

```json
{
  "ok": true,
  "mensaje": "Cantidad actualizada",
  "payload": {
    "id_pedido": 15,
    "id_pedido_producto": 16,
    "id_oferta": 3,
    "cantidad": 2,
    "eliminada": false
  }
}
```

### 200 (la resta la borro)

```json
{
  "ok": true,
  "mensaje": "Producto quitado del pedido",
  "payload": { "id_pedido": 15, "id_oferta": 3, "cantidad": 0, "eliminada": true }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El id_oferta es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "La cantidad es obligatoria y debe ser un numero entero mayor a 0", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido 15 esta comprado y ya no se puede cambiar", "payload": null }
{ "ok": false, "mensaje": "La oferta 6 no esta en el pedido 15", "payload": null }
```

### 401 / 503 / 500

Mismos casos que las demás rutas (el 500 es
`"No se pudo actualizar la cantidad"`).

---

## DELETE /comprador/pedidos/:id/detalles/:idDetalle

Saca una línea del pedido por completo — nunca la deja con cantidad `0`:
la función de PostgreSQL `quitar_linea` simplemente borra la fila.

`idDetalle` es el id propio de la línea
(`pedido_producto.id_pedido_producto`), no el `id_oferta` — se resuelve a
la oferta internamente (vía `precio_historial`), en la misma consulta que
comprueba que la línea sea de un pedido propio: un detalle ajeno, o de un
pedido ajeno, da el mismo 404 que uno que no existe.

```
DELETE /comprador/pedidos/3/detalles/4
```

### 200

```json
{ "ok": true, "mensaje": "Producto quitado del pedido", "payload": null }
```

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
{ "ok": false, "mensaje": "No existe un detalle con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido <id> esta <estado> y ya no se puede cambiar", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo quitar el producto del pedido", "payload": null }
```

---

## POST /comprador/pedidos/:id/comprar

Confirma la compra: llama a `comprar_pedido(id_pedido, metodo_pago)`, que
descuenta el stock de cada oferta, registra el pago (nace `pagado` de una
vez, sin importar el método — simplificación de la primera entrega, ver
`docs/base-de-datos.md`) y pasa el pedido a `comprado`. Todo o nada — si
algo falla, no se descuenta ni se cobra nada.

```json
{ "metodo_pago": "tarjeta", "tarjeta": { "numero": "4242424242424242", "vencimiento": "12/28", "cvv": "123", "titular": "Ana Lopez" } }
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `metodo_pago` | Sí | Uno de `GET /comprador/pedidos/metodos-pago` (`tarjeta`, `transferencia`, `efectivo contra entrega`) |
| `tarjeta` | Solo si `metodo_pago` es `"tarjeta"` | Ver la sección de abajo |
| `confirmar_cambios` | No | Ver "Antes de cobrar" |

Solo sobre un pedido propio, mismo criterio de siempre.

### El mock de tarjeta

**No es una pasarela de pago de verdad.** No se cobra nada, y **no se
guarda ningún dato de la tarjeta en ninguna tabla** — no existe ni una
columna para eso en `pago` (`migrations/006_pedidos.sql`). Solo sirve para
que, si `metodo_pago` es `"tarjeta"`, el flujo "haga algo" antes de llamar
a `comprar_pedido()`: valida la forma de la tarjeta y decide si el cobro
simulado pasa.

```json
{
  "numero": "4242424242424242",
  "vencimiento": "12/28",
  "cvv": "123",
  "titular": "Ana Lopez"
}
```

| Campo | Regla |
| --- | --- |
| `numero` | 13 a 19 dígitos (espacios y guiones se ignoran) y tiene que pasar el algoritmo de Luhn |
| `vencimiento` | Formato `MM/AA`, y no puede ya haber pasado |
| `cvv` | 3 o 4 dígitos |
| `titular` | Texto no vacío |

Si el formato es válido, el "cobro" pasa **salvo** que el número sea uno
de estos cinco (los mismos números de prueba que publica Stripe para su
sandbox — https://docs.stripe.com/testing — de mentira, no son tarjetas de
nadie):

| Número | Qué simula |
| --- | --- |
| `4242424242424242` | Aprobada (cualquier otro número con formato válido también) |
| `4000000000000002` | Rechazada, sin motivo especifico |
| `4000000000009995` | Fondos insuficientes |
| `4000000000000069` | Tarjeta vencida (además del chequeo de `vencimiento`) |
| `4000000000000127` | CVV incorrecto |
| `4100000000000019` | Tarjeta reportada como robada |

Un problema de **formato** (número mal armado, Luhn inválido, CVV con
letras) da **400**. Un formato válido pero rechazado da **402** — el
mismo código que usan las pasarelas de verdad para "el cobro no pasó".

### Antes de cobrar: se revisa que la oferta siga como estaba

Justo antes de llamar a `comprar_pedido()`, cada línea del pedido se
compara contra su oferta **tal como está hoy**:

- **La oferta ya no está activa** (la pausaron o la retiraron), **la
  variante del catálogo se desactivó** desde que se agregó al carrito
  (se trata igual que si el producto entero estuviera oculto — mismo
  criterio que al agregar la línea), o **ya no hay stock suficiente** →
  rechaza con **409**, siempre, pase lo que pase. Ninguna bandera lo
  salta.
- **El precio de hoy ya no es el que quedó congelado** en la línea → esto
  **no bloquea** (lo que se va a cobrar sigue siendo el precio congelado,
  nunca el de hoy), pero la persona merece saberlo antes de pagar: la
  respuesta sale con `comprado: false` y la lista de lo que cambió, **sin
  tocar nada** — ni el stock, ni el pago, ni el estado del pedido.
  Reenviando la misma petición con `"confirmar_cambios": true` la compra
  sigue adelante, cobrando el precio congelado de todos modos.

### 201 — compra realizada

```json
{
  "ok": true,
  "mensaje": "Compra realizada correctamente",
  "payload": {
    "comprado": true,
    "id_pedido": 3,
    "total": "8058.00",
    "stock": [
      { "id_oferta": 2, "id_usuario": 6, "id_producto": 1, "id_producto_variante": 1, "stock": 12 }
    ]
  }
}
```

`stock` trae el saldo resultante de cada oferta tocada — se usa para
recalcular en el momento `precio_tienda`/`stock_tienda`/`stock_total`/
`total_ofertas` de cada producto afectado en Mongo (son copias, no la
verdad; ver `endpoints-productos.md`). Si esa actualización de Mongo
fallara por su cuenta, la compra ya quedó hecha en PostgreSQL de todas
formas — no se deshace.

### 201 — hay que confirmar un cambio de precio primero

```json
{
  "ok": true,
  "mensaje": "Hay cambios que revisar antes de comprar",
  "payload": {
    "comprado": false,
    "avisos": [
      {
        "id_pedido_producto": 5,
        "nombre_producto": "Laptop Aurora 14",
        "nombre_variante": "32 GB / 1 TB",
        "precio_congelado": "8984.00",
        "precio_actual": "9500.00"
      }
    ]
  }
}
```

`ok` sigue en `true`: la petición en sí no falló, es información para
decidir. El frontend debería mostrarle esto a la persona y, si quiere
seguir de todas formas, repetir la petición con `confirmar_cambios: true`.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El metodo_pago es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El metodo de pago es tarjeta: hace falta el objeto \"tarjeta\" con numero, vencimiento, cvv y titular", "payload": null }
{ "ok": false, "mensaje": "El numero de tarjeta debe tener entre 13 y 19 digitos", "payload": null }
{ "ok": false, "mensaje": "El numero de tarjeta no es valido", "payload": null }
{ "ok": false, "mensaje": "El vencimiento debe tener el formato MM/AA", "payload": null }
{ "ok": false, "mensaje": "El CVV debe tener 3 o 4 digitos", "payload": null }
{ "ok": false, "mensaje": "El titular de la tarjeta es obligatorio", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 402

```json
{ "ok": false, "mensaje": "La tarjeta esta vencida", "payload": null }
{ "ok": false, "mensaje": "Fondos insuficientes", "payload": null }
{ "ok": false, "mensaje": "El codigo de seguridad (CVV) es incorrecto", "payload": null }
{ "ok": false, "mensaje": "La tarjeta fue reportada como robada", "payload": null }
{ "ok": false, "mensaje": "La tarjeta fue rechazada", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un pedido con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El pedido <id> ya esta <estado>", "payload": null }
{ "ok": false, "mensaje": "El pedido <id> no tiene ninguna linea", "payload": null }
{ "ok": false, "mensaje": "El metodo de pago \"<metodo_pago>\" no existe", "payload": null }
{ "ok": false, "mensaje": "La oferta de \"<nombre_variante>\" ya no esta disponible (<estado>)", "payload": null }
{ "ok": false, "mensaje": "La variante \"<nombre_variante>\" ya no esta disponible", "payload": null }
{ "ok": false, "mensaje": "No hay suficiente stock de \"<nombre_variante>\": quedan <n> y el pedido pide <n>", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo completar la compra", "payload": null }
```

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
que devolver. Igual que en `comprar`, cada oferta tocada dispara un
recálculo de los cuatro números copiados del producto en Mongo.

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
