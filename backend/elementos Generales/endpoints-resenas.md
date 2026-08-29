# Endpoints de reseñas

La parte social de la Entrega 2: reseñas de un vendedor sobre un producto,
con su conversación (respuestas) y sus votos. Las tres tablas viven en
PostgreSQL desde `migrations/011_resenas.sql` (`resena`, `comentario`,
`likes`).

> **Estado (2026-08-29):** hechas y probadas `GET /productos/:id/resenas` y
> `POST /resenas` (29 comprobaciones, 0 fallos — ver "Pruebas" abajo).
> **Pendientes** del bloque 1 de `BACKEND-PENDIENTE.md`, para más adelante:
> `POST /resenas/:id/respuestas`, `PUT /comentarios/:id/voto`,
> `DELETE /comentarios/:id/voto`. El `GET` ya devuelve `respuestas` y `voto`
> para que la pantalla los muestre; lo que falta son las rutas para
> **escribir** una respuesta o un voto.

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

## POST /resenas

**Pide sesión** (`SesionGuard`, sin `@Roles`: calificar no es de un rol,
cualquiera con sesión puede — igual que comprar). Escribe una reseña: el
comentario raíz con el texto y, apuntándolo, la fila de `resena`. Los dos
`INSERT` van en **una sola sentencia** (un CTE), que PostgreSQL ejecuta de
forma atómica.

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
| `comentario` | Sí | Texto no vacío, hasta 2000 caracteres. Se guarda recortado |

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
{ "ok": false, "mensaje": "El comentario no puede tener mas de 2000 caracteres", "payload": null }
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

## Lo que NO se hizo (y por qué)

- **`POST /resenas/:id/respuestas`, `PUT`/`DELETE /comentarios/:id/voto`** —
  bloque 1 de `BACKEND-PENDIENTE.md`, para más adelante. El `GET` ya sirve
  `respuestas` y `voto` (leídos de las tablas y los contadores del
  trigger); falta solo escribirlos.
- **El chequeo "el vendedor tiene una oferta activa del producto"** que
  pedía `BACKEND-PENDIENTE.md` — **no hace falta**: la regla del equipo
  ("le compraste y pagaste") ya implica que ese vendedor te vendió ese
  producto. Si algún día se quita la regla de compra, hay que volver a
  poner ese chequeo.
- **Verificar cuenta activa en el `GET`** — la ruta es pública y de solo
  lectura; una sesión suspendida como mucho vería resaltados sus votos
  viejos. No vale la consulta extra.

---

## Pruebas — 29/29 contra la base real (2026-08-29)

Script fuera del repo, con teardown que deja `resena` y `comentario` en 86 /
115 (los conteos de la semilla).

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
