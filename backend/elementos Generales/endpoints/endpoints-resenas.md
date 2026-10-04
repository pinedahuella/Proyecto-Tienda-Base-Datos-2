# Endpoints de reseñas

La parte social de la Entrega 2: reseñas de un vendedor sobre un producto,
con su conversación (respuestas) y sus votos. Las tres tablas viven en
PostgreSQL desde `migrations/011_resenas.sql` (`resena`, `comentario`,
`likes`).

> **Estado (2026-08-29): 7 rutas hechas y probadas.** Las cinco del bloque 1
> de `BACKEND-PENDIENTE.md` (`GET /productos/:id/resenas`, `POST /resenas`,
> `POST /resenas/:id/respuestas`, `PUT`/`DELETE /comentarios/:id/voto` — 29 +
> 40 comprobaciones) más dos consultas de estado que pidió el equipo:
> `GET /productos/:id/comprado` y `GET /productos/:id/resenado`.
> Dos diferencias deliberadas con `BACKEND-PENDIENTE.md`, ambas del equipo:
> 1. `POST /resenas` **exige haber comprado** el producto a ese vendedor
>    (ver "La regla del equipo").
> 2. **A una reseña puede responder cualquiera** con sesión, no solo el
>    vendedor calificado (ver `POST /resenas/:id/respuestas`).

Código: `src/controllers/resenas/resenas.controller.ts` +
`src/services/resenas/resenas.service.ts`. Pantalla que las consume:
`frontend/src/lib/Resenas.svelte`.

---

## El modelo, en cuatro frases

- **La reseña es de un VENDEDOR sobre un PRODUCTO**, no del producto solo:
  el catálogo es compartido y un producto no es de nadie, así que se
  califica a quien te lo vendió. Cada reseña dice `id_usuario` (quién
  califica) e `id_usuario_vendedor` (a quién).
- **El texto no está en `resena`**: está en su comentario **raíz**
  (`comentario` con `id_comentario_padre` NULL). `resena.id_comentario` lo
  apunta. Las respuestas cuelgan de esa raíz.
- **Los votos van contra `id_comentario`**, no contra `id_resena` — así la
  misma tabla `likes` sirve para votar una reseña y para votar una
  respuesta. Los contadores `cantidad_likes` / `cantidad_dislikes` los
  mantiene el trigger `trg_likes_recontar`; el backend solo los lee.
- **Una reseña por (comprador, vendedor, producto)** — lo garantiza el
  `UNIQUE` de la tabla.
- **El árbol de comentarios está en UN solo nivel, por ahora.** El esquema
  (`comentario.id_comentario_padre` apuntando a `comentario`) permite
  recursión, pero la única ruta para responder es
  `POST /resenas/:id/respuestas`, que cuelga la respuesta **siempre** de la
  raíz de esa reseña. No hay ruta para responder a un `id_comentario`
  cualquiera, así que una respuesta nunca puede tener hijos: el "padre no
  tiene padre" queda garantizado por diseño, sin un `CHECK`. Si algún día
  se quiere anidar más, se agrega `POST /comentarios/:id/respuestas` y ahí
  sí hará falta limitar la profundidad.

---

## La regla del equipo: hay que haber comprado

> **Esto NO es del enunciado.** `BACKEND-PENDIENTE.md` y la cabecera de
> `migrations/011_resenas.sql` dicen explícitamente que la reseña **no**
> exige compra ("la reseña sin compra es la señal de fraude más fuerte que
> existe"). El equipo decidió, de todos modos, exigir compra **por ahora**;
> si el profesor no la quiere, se quita cambiando dos consultas del
> servicio (`exigirCompraPagada` y `consultarPuedeCalificar`), nada más.

`POST /resenas` solo deja calificar a un vendedor de un producto si el
usuario **le compró ese producto y lo pagó**: existe un `pedido` suyo con
`pago` en estado `pagado` y `pedido` en estado distinto de `cancelado`, con
una línea de ese producto cuya oferta es de ese vendedor. La cadena que se
recorre es la misma de la factura:
`pedido_producto.id_precio_historial → precio_historial.id_oferta →
oferta.id_usuario`.

La lista `puede_calificar` del `GET` aplica la misma regla, para que el
formulario solo ofrezca vendedores que el `POST` va a aceptar.

**Tensión conocida:** con esta regla, las 86 reseñas sembradas **no** se
podrían crear por la API (no todas tienen compra detrás). Es a propósito —
la semilla retrata un catálogo ya poblado — y solo afecta a reseñas nuevas.

---

## GET /productos/:id/resenas

**Pública**, sin sesión. `:id` es el `id_producto_mongo`. Devuelve todas las
reseñas del producto, de la más nueva a la más vieja
(`comentario.fecha_publicacion DESC`), con su vendedor, su autor, sus
respuestas y un resumen.

**Si viene una cookie de sesión válida** (el controlador la resuelve a mano,
sin guard), cada `voto` trae `mio` (lo que votó esa cuenta) y
`puede_calificar` sale con los vendedores calificables. Sin sesión, `mio`
es siempre `null` y `puede_calificar` es `[]`. No se comprueba que la
cuenta siga activa: en una ruta pública de solo lectura, la sesión solo
agrega esos dos datos.

```
GET /productos/35/resenas
```

### 200

```json
{
  "ok": true,
  "mensaje": "Resenas obtenidas",
  "payload": {
    "resenas": [
      {
        "id_resena": 40,
        "id_comentario": 130,
        "calificacion": 5,
        "comentario": "Llego en dos dias y bien empacado.",
        "fecha_publicacion": "2026-04-18T16:02:00.000Z",
        "autor_usuario": "compradora_norte",
        "autor_correo": "compradora.norte@mesh.com",
        "vendedor_usuario": "ventas_norte",
        "vendedor_correo": "ventas.norte@mesh.com",
        "vendedor_nombre": "Carlos Ramirez",
        "voto": { "mio": 1, "a_favor": 3, "en_contra": 0 },
        "respuestas": [
          {
            "id_comentario": 131,
            "autor_usuario": "ventas_norte",
            "autor_correo": "ventas.norte@mesh.com",
            "comentario": "Gracias por la compra.",
            "fecha_publicacion": "2026-04-18T18:02:00.000Z",
            "voto": { "mio": null, "a_favor": 0, "en_contra": 0 }
          }
        ]
      }
    ],
    "resumen": {
      "total": 4,
      "promedio": 4.25,
      "reparto": { "1": 0, "2": 1, "3": 0, "4": 1, "5": 2 }
    },
    "puede_calificar": [
      { "correo": "ventas.sur@mesh.com", "usuario": "ventas_sur", "nombre": "Lucia Morales" }
    ]
  }
}
```

- **`voto.mio`** — `1`, `-1` o `null` (lo que votó quien pide; sin sesión
  siempre `null`). `a_favor` / `en_contra` son `cantidad_likes` /
  `cantidad_dislikes` del comentario.
- **`resumen.reparto`** — las cinco claves `"1"` a `"5"` **siempre
  presentes**, aunque valgan 0. `promedio` va con 2 decimales; `0` si no
  hay reseñas.
- **`puede_calificar`** — los vendedores de este producto que la cuenta le
  compró (pago `pagado`, pedido no `cancelado`), no es ella misma, y
  todavía no ha calificado. `[]` sin sesión.
- `id_resena` / `id_comentario` salen como número (los `_id` de Mongo y los
  `bigserial` de estas tablas caben en un number de JS sin problema a esta
  escala).

Un producto sin reseñas devuelve `resenas: []`, `resumen.total: 0`,
`resumen.promedio: 0`, `reparto` todo en 0 — no un 404.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

`:id` no es un número.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudieron obtener las resenas", "payload": null }
```

---

## GET /productos/:id/comprado

**Pide sesión.** Respuesta corta: ¿la cuenta logueada **compró y pagó** este
producto alguna vez? Un `pedido` suyo con `pago` en estado `pagado` y
`pedido` en estado distinto de `cancelado` que incluya una línea de ese
producto.

**No mira el vendedor** — es "lo compré" a secas. (La regla de `POST
/resenas` sí exige que la compra sea a *ese* vendedor; ésta no.)

```
GET /productos/1/comprado
```

### 200

```json
{
  "ok": true,
  "mensaje": "Ya compraste este producto",
  "payload": { "comprado": true }
}
```

`mensaje` es `"Ya compraste este producto"` o `"Todavia no has comprado
este producto"` según el booleano.

### 400 / 401

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

---

## GET /productos/:id/resenado

**Pide sesión.** ¿La cuenta logueada **ya reseñó** este producto? True si
tiene al menos una fila en `resena` para ese `id_producto_mongo`, sea cual
sea el vendedor (se puede reseñar el mismo producto a varios vendedores).

```
GET /productos/35/resenado
```

### 200

```json
{
  "ok": true,
  "mensaje": "Ya resenaste este producto",
  "payload": { "resenado": true }
}
```

### 400 / 401

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

> Las dos son independientes: se puede haber **comprado sin reseñar**
> (`comprado: true`, `resenado: false`) o **reseñado sin comprar** — la
> reseña no exige compra en la base; la exige `POST /resenas`, y sólo desde
> que se puso esa regla. Probado en vivo con `compradora_norte`: compró el
> producto 1 (no lo reseñó) y reseñó el 35 (no lo compró).

---

## POST /resenas

**Pide sesión** (`SesionGuard`, sin `@Roles`: calificar no es de un rol,
cualquiera con sesión puede — igual que comprar). Escribe una reseña: el
comentario raíz con el texto y, apuntándolo, la fila de `resena`. Los dos
`INSERT` van en **una sola sentencia** (un CTE), que PostgreSQL ejecuta de
forma atómica.

**Efecto sobre el catálogo en Mongo.** Desde el 2026-10-01 la petición ya no
recalcula nada en Mongo: el trigger `trg_resena_al_producto` anota el
producto en `evento_producto` en la misma transacción y el worker
(`EventoProductoSyncService`, cada 5 s) recalcula `resenas_promedio` y
`resenas_total` en el documento del producto (lo mismo que corre cuando
cambia una oferta). Son campos calculados que usan la tarjeta del
catálogo y los filtros `resenas_promedio_min/max` y `resenas_total_min/max`
de `GET /productos` — **no** la fuente de verdad: la nota media autoritativa
la calcula en vivo `GET /productos/:id/resenas` (`resumen.promedio`) desde
PostgreSQL. Si ese recálculo fallara, la reseña igual queda publicada (está
en PostgreSQL); la copia de Mongo se pone al día en el siguiente cambio o
corrida del ETL. `resenas_promedio`/`resenas_total` no son editables por
ninguna ruta de producto y no generan evento de modificación, así que
reconstruir el producto a una fecha pasada devuelve `0`, no la nota de ese
día (igual que `precio_tienda`).

```
POST /resenas
```

```json
{
  "id_producto": 1,
  "correo_vendedor": "ventas.oriente@mesh.com",
  "calificacion": 5,
  "comentario": "Todo perfecto, llego rapido."
}
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `id_producto` | Sí | El `_id` de Mongo. Entero > 0. Mismo mensaje que en las rutas de ofertas y productos |
| `correo_vendedor` | Sí | Correo de una cuenta real. Se recorta |
| `calificacion` | Sí | Entero de 1 a 5 |
| `comentario` | Sí | Texto de **40 a 350 caracteres**, contados después de recortar. Se guarda recortado |

> **Cambio 2026-10-04:** el texto de una **reseña** ahora debe tener de **40 a
> 350 caracteres** (antes: hasta 250, sin mínimo). El mínimo existe porque las
> señales de fraude por texto solo analizan reseñas largas; el máximo sube
> a 350 para que quepan más reseñas en ese rango. Se cuenta **después de
> recortar**: 38 letras con espacios alrededor dan `400`. La **respuesta**
> (`POST /resenas/:id/respuestas`) tiene el mismo máximo de 350 pero **sin
> mínimo** (1 carácter basta), porque "Gracias por tu compra" es una respuesta
> normal y no lleva estrellas. Son dos funciones en
> `helpers/validaciones-resena.ts`: `validarComentarioResena` (reseña) y
> `validarRespuestaResena` (respuesta); el máximo y el mensaje de "muy largo"
> son idénticos. Los comentarios que ya existen no se tocan, aunque midan menos
> de 40. Nota 2026-10-02 de abajo = el cambio anterior.
>
> **Cambio 2026-10-02:** el límite del texto bajó de 2000 a **250 caracteres**
> (antes: `El comentario no puede tener mas de 2000 caracteres`). Se cuenta
> **después de recortar** los espacios de los extremos: 250 letras con espacios
> alrededor pasan, 251 letras dan `400`. Es la misma función
> (`validarComentarioResena`) para `POST /resenas` y
> `POST /resenas/:id/respuestas`, así que el límite y el mensaje son idénticos
> en las dos rutas. Los comentarios que ya existían no se tocan (el más largo
> de la base local tiene 74 caracteres).

### 201

```json
{
  "ok": true,
  "mensaje": "Tu resena se publico",
  "payload": { "id_resena": 87, "id_comentario": 132 }
}
```

`payload` trae los dos ids nuevos. El frontend no los usa (recarga la lista
con `GET` después), pero sirven para depurar.

### 400

```json
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El correo del vendedor es obligatorio", "payload": null }
{ "ok": false, "mensaje": "La calificacion debe ser un numero entero de 1 a 5", "payload": null }
{ "ok": false, "mensaje": "El comentario es obligatorio y no puede estar vacio", "payload": null }
{ "ok": false, "mensaje": "El comentario debe tener al menos 40 caracteres", "payload": null }
{ "ok": false, "mensaje": "El comentario no puede tener mas de 350 caracteres", "payload": null }
{ "ok": false, "mensaje": "No puedes calificarte a ti mismo", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un vendedor con ese correo", "payload": null }
```

`correo_vendedor` no es de ninguna cuenta.

### 409

```json
{ "ok": false, "mensaje": "Ya calificaste a este vendedor por este producto", "payload": null }
{ "ok": false, "mensaje": "Solo puedes calificar a un vendedor de un producto que le compraste y pagaste", "payload": null }
```

El primero lo levanta el `UNIQUE (id_usuario, id_usuario_vendedor,
id_producto_mongo)` de la tabla. El segundo es **la regla del equipo** (ver
arriba): no hay un pedido pagado de ese producto a ese vendedor.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo publicar la resena", "payload": null }
```

---

## POST /resenas/:id/respuestas

**Pide sesión** (sin `@Roles`). `:id` es el **`id_resena`**. Escribe un
`comentario` que cuelga del **comentario raíz** de esa reseña
(`id_comentario_padre = resena.id_comentario`).

> **A una reseña puede responder cualquiera con sesión.**
> `BACKEND-PENDIENTE.md` decía "solo el vendedor calificado puede contestar
> (403 a los demás)"; el equipo decidió abrirlo. No hay comprobación de
> dueño ni de rol. El frontend igual solo muestra el botón "Responder" al
> vendedor calificado, pero eso es cosa de la pantalla, no del permiso.

Como `:id` es la reseña y la respuesta cuelga siempre de su raíz, **el
árbol se queda en un nivel**: no hay forma de responder a una respuesta
(ver "El modelo").

```
POST /resenas/61/respuestas
```

```json
{ "comentario": "Gracias por la reseña, saludos." }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `comentario` | Sí | Texto no vacío, hasta **350** caracteres, **sin mínimo** (desde 2026-10-04 la reseña tiene mínimo de 40 y la respuesta no). Se guarda recortado |

### 201

```json
{
  "ok": true,
  "mensaje": "Tu respuesta se publico",
  "payload": { "id_comentario": 123 }
}
```

### 400 / 401

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El comentario es obligatorio y no puede estar vacio", "payload": null }
{ "ok": false, "mensaje": "El comentario no puede tener mas de 350 caracteres", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una resena con ese id", "payload": null }
```

El `INSERT ... SELECT ... FROM resena WHERE id_resena = $` no encuentra la
reseña y no inserta nada.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo publicar la respuesta", "payload": null }
```

---

## PUT /comentarios/:id/voto

**Pide sesión** (sin `@Roles`). `:id` es el **`id_comentario`** — sirve
igual para el comentario raíz de una reseña que para una respuesta. Pone o
cambia el voto de la cuenta. Cambiar de opinión es el **mismo PUT** (un
`UPSERT` sobre la llave `(id_usuario, id_comentario)` de `likes`), no una
fila nueva. Los contadores `cantidad_likes` / `cantidad_dislikes` los
recuenta el trigger `trg_likes_recontar`; la respuesta los devuelve ya al
día.

```
PUT /comentarios/123/voto
```

```json
{ "valor": 1 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `valor` | Sí | Exactamente `1` (a favor) o `-1` (en contra). La columna `likes.valor` no tiene `CHECK` (decisión del equipo en la 011); lo amarra esta validación, y el trigger solo cuenta `= 1` y `= -1` |

### 200

```json
{
  "ok": true,
  "mensaje": "Voto registrado",
  "payload": { "a_favor": 3, "en_contra": 1, "mio": 1 }
}
```

`a_favor` / `en_contra` son los contadores del comentario tras el voto;
`mio` es lo que quedó votando esta cuenta.

### 400 / 401

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El valor del voto debe ser 1 (a favor) o -1 (en contra)", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un comentario con ese id", "payload": null }
```

Lo levanta la llave foránea `likes.id_comentario` (código `23503`).

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo registrar el voto", "payload": null }
```

---

## DELETE /comentarios/:id/voto

**Pide sesión** (sin `@Roles`). Quita el voto de la cuenta sobre ese
comentario. Sin cuerpo. **Idempotente**: si la cuenta no había votado,
responde 200 igual (con `mio: null`).

```
DELETE /comentarios/123/voto
```

### 200

```json
{
  "ok": true,
  "mensaje": "Voto quitado",
  "payload": { "a_favor": 2, "en_contra": 1, "mio": null }
}
```

### 400 / 401

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un comentario con ese id", "payload": null }
```

Solo se comprueba (con una consulta extra) cuando el `DELETE` no borró
nada: así se distingue "no había voto" (200) de "el comentario no existe"
(404).

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo quitar el voto", "payload": null }
```

---

## Lo que NO se hizo (y por qué)

- **Responder a una respuesta** (comentarios anidados más de un nivel) — no
  hay ruta `POST /comentarios/:id/respuestas`. Por ahora todo cuelga de la
  raíz de la reseña. Ver "El modelo".
- **El chequeo "el vendedor tiene una oferta activa del producto"** que
  pedía `BACKEND-PENDIENTE.md` — **no hace falta**: la regla del equipo
  ("le compraste y pagaste") ya implica que ese vendedor te vendió ese
  producto. Si algún día se quita la regla de compra, hay que volver a
  poner ese chequeo.
- **Verificar cuenta activa en el `GET`** — la ruta es pública y de solo
  lectura; una sesión suspendida como mucho vería resaltados sus votos
  viejos. No vale la consulta extra.
- **Limitar respuestas o votos por cuenta / por tiempo** (anti-spam) — no
  se pidió. Cualquiera puede responder muchas veces a la misma reseña.

---

## Pruebas — contra la base real (2026-08-29)

Scripts fuera del repo, con teardown que deja `resena` / `comentario` /
`likes` en 86 / 115 / 46 (los conteos de la semilla) y los contadores del
trigger en su valor original.

### `GET /productos/:id/resenas` y `POST /resenas` — 29/29

**`GET /productos/:id/resenas`:**

| Caso | Resultado |
|---|---|
| Sin sesión, producto con reseñas | 200; `puede_calificar: []`; `voto.mio: null` en todo; `reparto` con las 5 claves; `respuestas` anidadas presentes |
| Producto sin reseñas | 200; `resenas: []`, `total: 0`, `promedio: 0` |
| `:id` no numérico | 400 |
| Con sesión (`compradora_norte`), producto 1 | `puede_calificar` = `ventas_oriente` + `ventas_sur` (le compró ambos, pagó); `ventas_poniente` **no** aparece (no le compró) |

**`POST /resenas`:**

| Caso | Resultado |
|---|---|
| `compradora_norte` califica a `ventas_oriente` por prod 1 (le compró) | 201; la fila queda con calificación + texto en el comentario raíz |
| La misma otra vez | 409 "Ya calificaste a este vendedor por este producto" |
| Califica a `ventas_poniente` (no le compró) | 409 "Solo puedes calificar a un vendedor de un producto que le compraste y pagaste" |
| Sin sesión | 401 |
| `calificacion` 0 / 6, comentario en blanco | 400 |
| `correo_vendedor` inexistente | 404 |
| Calificarse a sí mismo | 400 "No puedes calificarte a ti mismo" |
| Tras publicar: `GET` como `compradora_norte` | `ventas_oriente` sale de `puede_calificar`, `ventas_sur` sigue, `resumen.total` = 1 |

**Recálculo de `resenas_promedio` / `resenas_total` en Mongo (6/6, 2026-09-02):**

| Caso | Resultado |
|---|---|
| Producto 67 (ya tenía 4 reseñas, media 3.50) — se dispara un recálculo (PATCH no-op a una oferta de la tienda) | El documento de Mongo pasa a `resenas_promedio: 3.5`, `resenas_total: 4` |
| Producto 1 (0 reseñas) — `compradora_norte` publica una reseña de 5 a `ventas_oriente` | Mongo: `resenas_promedio: 5`, `resenas_total: 1` |
| La misma cuenta publica una 2ª reseña de 2 a `ventas_sur` (mismo producto, otro vendedor) | Mongo: `resenas_promedio: 3.5`, `resenas_total: 2` — y `GET /productos/1/resenas` `resumen` (cálculo en vivo) da lo mismo |
| Teardown: se borran las 2 reseñas de prueba + un recálculo | Mongo vuelve a `resenas_promedio: 0`, `resenas_total: 0`; `resena` queda en 86 filas |

> Nota para la migración del compañero: hoy **ningún** documento de
> `productos` trae `resenas_promedio` / `resenas_total` (los tests los
> escriben y los borran). La migración / el ETL tiene que agregar los dos
> campos a cada producto, calculados desde `resena`
> (`ROUND(AVG(calificacion), 2)` y `COUNT(*)` por `id_producto_mongo`, `0`
> cuando no hay ninguna). El backend ya sabe mantenerlos al día a partir de
> ahí.

### `POST /resenas/:id/respuestas`, `PUT`/`DELETE /comentarios/:id/voto` — 40/40

**Respuestas:**

| Caso | Resultado |
|---|---|
| `comprador_sur` responde a una reseña | 201; el comentario cuelga de la raíz de la reseña, y esa raíz **no** tiene padre (un nivel) |
| `compradora_norte` (no es el vendedor) responde a la misma reseña | 201 — cualquiera puede |
| El vendedor calificado responde | 201 (sigue siendo cualquiera) |
| `id_resena` inexistente / id no numérico / comentario en blanco / sin sesión | 404 / 400 / 400 / 401 |
| Tras responder: `GET /productos/:id/resenas` | la respuesta nueva aparece anidada |

**Votos:**

| Caso | Resultado |
|---|---|
| `comprador_sur` vota `+1` en un comentario | 200; `mio: 1`, `a_favor: 1`, 1 fila en `likes`, `cantidad_likes` subió (trigger) |
| El mismo vota `-1` (cambia de opinión) | 200; `mio: -1`, `a_favor: 0`, `en_contra: 1`, **sigue 1 fila** en `likes` (UPSERT) |
| Otro usuario vota `+1` en el mismo comentario | `a_favor: 1`, `en_contra: 1` |
| Votar sobre una **respuesta** (comentario con padre) | 200 — los votos van contra cualquier `id_comentario` |
| Votar sobre la **raíz** de una reseña que ya tenía un voto de la semilla | 200; `a_favor` = base + 1 (el voto sembrado se conserva) |
| `valor` 0 / 2 / no numérico / comentario inexistente / sin sesión | 400 / 400 / 400 / 404 / 401 |
| `DELETE` el voto propio | 200; `mio: null`, contador baja, la fila de `likes` se borra |
| `DELETE` otra vez (ya no había) | 200 — idempotente |
| `DELETE` sobre comentario inexistente / sin sesión | 404 / 401 |

Teardown verificado: `comentario` y `likes` vuelven a 115 / 46 y la suma de
`cantidad_likes + cantidad_dislikes` de toda la tabla vuelve a 46 (el
trigger recuenta al borrar los votos de prueba).
