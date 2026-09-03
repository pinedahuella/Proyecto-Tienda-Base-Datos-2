# Endpoints de vendedor

Este archivo documenta solo las rutas de `/vendedor/*`. Las demás rutas del
backend están en [endpoints.md](endpoints.md) (usuario, perfil, direcciones,
admin), [endpoints-productos.md](endpoints-productos.md) (el catálogo
público) y [endpoints-compradores.md](endpoints-compradores.md) (comprar,
sin exigir un rol en particular).

Todas las rutas de aquí requieren la cookie `mesh_token`. Hay **tres niveles**
de restricción, y no son lo mismo:

1. **Por rol** (`id_rol_usuario`, lo revisa el guard `@Roles` antes de entrar
   al controlador): un rol sin permiso recibe 403, igual que en `/admin/*`.
   Desde el 25 de agosto de 2026, tanto `/vendedor/productos` como
   `/vendedor/ofertas` aceptan **vendedor (2) o admin (3)** — antes solo
   dejaban pasar vendedor.
2. **Por cuenta especifica** (solo dentro de `/vendedor/productos`, lo revisa
   `exigirTiendaOAdmin()` a mano, por correo o por rol contra la base en cada
   petición, nunca por el token): no es un 403 — ver la nota mas abajo de por
   qué.
3. **Por identidad efectiva** (solo dentro de `/vendedor/ofertas`, lo
   resuelve `OfertasVendedorService.resolverIdEfectivo()`): no es una
   restricción que bloquee nada, es una **sustitución** — cuando quien
   llama es admin, toda la operación se hace usando el `id_usuario` de la
   cuenta de la tienda en vez del propio. Ver la nota de más abajo,
   "Ofertas creadas por un admin caen bajo la cuenta de la tienda".

| Ruta | Rol exigido | Cuenta exigida |
| --- | --- | --- |
| `GET /vendedor/categorias` | vendedor **o** admin (2 o 3) | cualquiera |
| `GET /vendedor/categorias/:id` | vendedor **o** admin (2 o 3) | cualquiera |
| `GET /vendedor/productos` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/productos/paginado` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/productos/:id` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/productos/:id/historial` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `POST /vendedor/productos` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `POST /vendedor/productos/propuestas` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin — el producto nace `en_revision` |
| `GET /vendedor/productos/propuestas` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin — solo las **suyas** |
| `GET /vendedor/productos/propuestas/sin-aprobar` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/productos/propuestas/todas` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/productos/propuestas/:id/rechazos` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** (cualquiera), o el vendedor que la propuso (solo la suya) |
| `PATCH /vendedor/productos/:id/revision` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `PATCH /vendedor/productos/:id/reenviar` | vendedor **o** admin (2 o 3) | solo el vendedor que **propuso** esa propuesta |
| `PATCH /vendedor/productos/:id` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/ofertas` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin |
| `GET /vendedor/ofertas/pendientes` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/ofertas/:id/rechazos` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** (cualquier oferta), o el vendedor dueño (solo la suya) |
| `GET /vendedor/ofertas/producto/:idProducto` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin |
| `POST /vendedor/ofertas` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin |
| `PATCH /vendedor/ofertas/:id` | vendedor **o** admin (2 o 3) | cualquier vendedor, pero solo sobre **su propia** oferta; un admin, sobre cualquier oferta **de la tienda** |
| `PATCH /vendedor/ofertas/:id/revision` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |

**`/vendedor/productos` es el panel de administración del catálogo
completo, no "mis productos".** Con el giro a multi-vendedor, un producto
dejó de pertenecer a quien lo crea — el catálogo (`productos`/`variantes`
en Mongo) es compartido, y por decisión explícita con el profesor **solo
la cuenta de la tienda, o cualquier cuenta con rol admin, lo administra**
(`cambios-multivendedor.md`, sección 9; la apertura a admin se agregó el
25 de agosto de 2026, a pedido del equipo). Las cinco rutas de arriba
llaman a `ProductosVendedorService.exigirTiendaOAdmin()`, que deja pasar
si el correo del usuario logueado es `tienda@mesh.com` **o** si su
`id_rol_usuario` es 3 (admin) — cualquier otro vendedor recibe el **mismo
404** que si el recurso no existiera (`"No existe un producto con ese
id"` en las rutas con `:id`; en `GET /vendedor/productos`, que no lleva
ningún id, ese mismo mensaje sale igual, reutilizado tal cual). Es a
propósito, para no revelar que la restricción existe — el mismo patrón
que ya usa el resto de la API para "un recurso ajeno da el mismo 404 que
uno inexistente" — solo que aquí no hay ningún dueño de por medio, es una
cuenta fija (o un rol fijo).

Un producto o una variante creados o editados por un admin **no quedan
marcados de ninguna forma especial**: el documento de Mongo no tiene (ni
tuvo nunca, desde el giro multi-vendedor) un campo de dueño, así que sale
idéntico sin importar si lo tocó la tienda o un admin — no hay nada que
"caiga bajo la cuenta de la tienda", porque el catálogo ya no le
pertenece a nadie.

**Lo que sí es de cualquier vendedor (o admin) es la oferta**: publicar (y
editar) un precio y un stock propios sobre una variante del catálogo que
ya existe. Es la respuesta real a "¿cuáles son mis productos?" para un
vendedor que no es la tienda — no hay tal cosa como "productos propios",
pero `GET /vendedor/ofertas` da la lista de productos sobre los que sí
tiene algo (una oferta), en cualquier estado. Vive en PostgreSQL (tabla
`oferta`), el catálogo sigue en Mongo.

**Ofertas creadas por un admin caen bajo la cuenta de la tienda, no bajo
la del admin** (decisión explícita del equipo, 25 de agosto de 2026). A
diferencia de `/vendedor/productos`, aquí no hay ningún 404 que bloquee a
un admin — lo que hay es una **sustitución de identidad**, en
`OfertasVendedorService.resolverIdEfectivo()`: apenas entra una petición
de las cuatro rutas de esta sección (`GET /vendedor/ofertas`,
`GET /vendedor/ofertas/producto/:idProducto`, `POST /vendedor/ofertas`,
`PATCH /vendedor/ofertas/:id`) con `id_rol_usuario` 3 (admin), el
`id_usuario` del token se cambia por el `id_usuario` real de
`tienda@mesh.com` **antes** de tocar cualquier otra cosa — el resto del
servicio ni se entera de que quien llamó fue un admin. En la práctica:

- `POST /vendedor/ofertas` con sesión de admin crea la oferta con
  `oferta.id_usuario` = el de la tienda, no el del admin. Esa oferta sale
  marcada `es_tienda: true` en la ficha pública del producto y alimenta
  `precio_tienda`/`stock_tienda`, exactamente como si la hubiera creado
  la propia cuenta de la tienda.
- `GET /vendedor/ofertas` con sesión de admin lista las ofertas **de la
  tienda**, no las del admin (no debería existir ninguna oferta bajo el
  id propio de un admin, porque `crear()` nunca la deja nacer ahí).
- `PATCH /vendedor/ofertas/:id` con sesión de admin puede editar
  **cualquier oferta de la tienda**, con el mismo chequeo de dueño de
  siempre (`obtenerFilaPropia`) — pero sigue sin poder tocar la oferta de
  un vendedor que no es la tienda, el 404 genérico de siempre.
- Si la propia cuenta de la tienda (`tienda@mesh.com`, rol vendedor, no
  admin) usa estas rutas, no cambia nada: `resolverIdEfectivo()` no hace
  sustitución si `id_rol_usuario` no es 3.

**`POST`/`PATCH /vendedor/productos` ya están rediseñadas contra el modelo
multi-vendedor**: ya no piden ni guardan `precio` ni `stock_inicial` por
variante (eso es de la oferta, ver `/vendedor/ofertas` más abajo). Las
cinco rutas viejas de `/inventario` (que hablaban de una tabla `inventario`
que ya no existe en PostgreSQL) se borraron por completo — el stock ahora
se maneja siempre a través de la oferta (`POST /vendedor/ofertas` y
`PATCH /vendedor/ofertas/:id`, con `ajuste_stock`).

---

## GET /vendedor/categorias

Las categorías en las que de verdad se puede publicar un producto: las que
**no son raíz** (su `categoria_padre` no es `null`). Pensada para armar el
selector de categoría al crear un producto — trae solo lo mínimo, no el
menú de características (para eso está `GET /vendedor/categorias/:id`).
Ordenadas alfabéticamente por `nombre`.

### 200

```json
{
  "ok": true,
  "mensaje": "Categorias obtenidas",
  "payload": [
    { "id_categoria": 16, "nombre": "Audifonos", "categoria_padre": "Audio" },
    { "id_categoria": 15, "nombre": "Audio", "categoria_padre": "Electronica" },
    { "id_categoria": 3, "nombre": "Camisas", "categoria_padre": "Ropa de hombre" }
  ]
}
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener las categorias", "payload": null }
```

---

## GET /vendedor/categorias/:id

Una categoría completa, con el menú entero de características que ofrece
—tanto las de producto (`caracteristicas`) como las de variante
(`caracteristicas_variante`)—, cada una con su `tipo_dato` y su `unidad`.
Es lo que arma el formulario de crear un producto en esa categoría: qué
campos mostrar y de qué tipo es cada uno.

Solo categorías válidas (no raíz): pedir una raíz (`Ropa`, `Electronica`,
etc.) da el mismo 404 que un id que no existe, porque en ninguna de las dos
se puede publicar.

```
GET /vendedor/categorias/3
```

### 200

```json
{
  "ok": true,
  "mensaje": "Categoria obtenida",
  "payload": {
    "id_categoria": 3,
    "nombre": "Camisas",
    "categoria_padre": "Ropa de hombre",
    "porcentaje_comision": { "$numberDecimal": "12.00" },
    "fecha_creacion": { "$date": "2026-01-05T16:10:00.000Z" },
    "caracteristicas": [
      { "nombre": "Marca", "unidad": null, "tipo_dato": "texto" },
      { "nombre": "Duracion de la garantia", "unidad": "meses", "tipo_dato": "entero" }
    ],
    "caracteristicas_variante": [
      { "nombre": "Color", "unidad": null, "tipo_dato": "texto" },
      { "nombre": "Talla", "unidad": null, "tipo_dato": "texto" }
    ]
  }
}
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

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una categoria con ese id", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener la categoria", "payload": null }
```

---

## POST /vendedor/productos

**Solo `tienda@mesh.com` o una cuenta con rol admin** (ver
`helpers/constantes.ts`, `CORREO_TIENDA`, y `ProductosVendedorService.exigirTiendaOAdmin`)
— no cualquier vendedor, ni siquiera con `id_rol_usuario` 2: en el modelo
multi-vendedor el catálogo es compartido, y si cualquiera pudiera crear
productos dos vendedores acabarían duplicando el mismo artículo. Cualquier
otro vendedor recibe el mismo 404 genérico que "no existe" — nunca 403, ni
confirmación de que la ruta existe. Crea un producto **con al menos una
variante**.

**Sin precio ni stock: eso es de la oferta, no del catálogo.** Publicar un
producto (por esta ruta) no crea ninguna oferta — nace sin nadie que lo
venda todavía. Para que alguien pueda comprarlo hace falta un segundo paso,
aparte: `POST /vendedor/ofertas` (ver la sección "Las ofertas: modelo
multi-vendedor" más abajo), que es donde de verdad se ponen el precio y el
stock inicial — y ahí sí, cualquier vendedor o admin, incluida la tienda.

Nace siempre en estado `borrador` (por eso `GET /productos` y
`GET /productos/paginacion` nunca lo muestran hasta que alguien lo publique
— ver [endpoints-productos.md](endpoints-productos.md)). Las variantes
nacen siempre `activa`.

**El `_id` del producto y el `id_producto_variante` de cada variante se
calculan como "el máximo que ya existe, más 1"**, sin colección de
contadores ni transacción — más simple, a cambio de un riesgo aceptado y
bajo: si dos vendedores crean un producto en el mismo instante exacto,
uno de los dos podría fallar por id duplicado (recuperable reintentando).
El producto y su primer evento se escriben uno después del otro, sin
transacción (Mongo no está en modo replica set).

### Cuerpo de la petición

```json
{
  "id_categoria": 3,
  "nombre": "Camisa de lino manga larga",
  "descripcion": "Camisa de lino de corte regular",
  "caracteristicas_adicionales": [
    { "nombre": "Marca", "valor": "MarcaTest" },
    { "nombre": "Garantia", "valor": true },
    { "nombre": "Duracion de la garantia", "valor": 12 },
    { "nombre": "Materiales principales", "valor": ["Algodon", "Lino"] }
  ],
  "caracteristicas_personalizadas": [
    { "nombre": "Lote de prueba", "valor": "L001" }
  ],
  "variantes": [
    {
      "nombre_variante": "M azul",
      "descripcion": "Talla M, color azul",
      "imagenes": ["https://..."],
      "caracteristicas_adicionales": [
        { "nombre": "Color", "valor": "Azul" },
        { "nombre": "Talla", "valor": "M" }
      ],
      "caracteristicas_personalizadas": [
        { "nombre": "Nota interna", "valor": 42 }
      ]
    }
  ]
}
```

| Campo | Obligatorio | Qué es |
| --- | --- | --- |
| `id_categoria` | Sí | Debe ser una categoría válida (no raíz) |
| `nombre` | Sí | Hasta 200 caracteres |
| `descripcion` | No | Acepta null |
| `caracteristicas_adicionales` | No | Del catálogo de la categoría — ver abajo |
| `caracteristicas_personalizadas` | No | Libres — ver abajo |
| `variantes` | Sí, al menos 1 | Cada una con `nombre_variante` y `descripcion` obligatorios |
| `variantes[].imagenes` | No | Array de URLs, vacío si no viene |

Si el cuerpo trae `precio` o `stock_inicial` en alguna variante (formato
viejo, de antes del giro multi-vendedor), **se ignoran en silencio** — no
rechazan la petición, pero tampoco se guardan en ningún lado. Para poner
precio y stock hay que crear una oferta aparte, ver
`POST /vendedor/ofertas` más abajo.

### Características del catálogo (`caracteristicas_adicionales`)

Solo `nombre` y `valor` — **nunca `unidad`**: el backend la rellena solo,
tomándola de la definición de la categoría (`GET /vendedor/categorias/:id`
para saber qué ofrece y de qué tipo es cada una). Cada `nombre` tiene que
ser una de las que esa categoría ofrece (`caracteristicas` para el
producto, `caracteristicas_variante` para cada variante), sin repetirse
dentro del mismo producto o variante, y el `valor` tiene que cumplir su
`tipo_dato`:

| `tipo_dato` | `valor` esperado |
| --- | --- |
| `texto` | Texto no vacío |
| `entero` | `Number` entero |
| `decimal` | `Number` |
| `booleano` | `true` / `false` |
| `lista` | Array de texto, con al menos un elemento |

### Características personalizadas (`caracteristicas_personalizadas`)

No salen de ningún catálogo — el nombre lo inventa el vendedor. Solo se
valida que el formato sea razonable: nombre no vacío (hasta 100
caracteres) y sin repetirse, valor suelto (texto, número o
verdadero/falso), nunca un array ni un objeto. Siempre se guardan con
`unidad: null`.

### 201

```json
{
  "ok": true,
  "mensaje": "Producto creado correctamente",
  "payload": {
    "_id": 51,
    "nombre": "Camisa de lino manga larga",
    "descripcion": "Camisa de lino de corte regular",
    "fecha_creacion": { "$date": "2026-08-23T01:19:20.964Z" },
    "estado": "borrador",
    "categoria": {
      "id_categoria": 3,
      "nombre": "Camisas",
      "categoria_padre": "Ropa de hombre"
    },
    "precio_tienda": null,
    "precio_desde": null,
    "stock_tienda": 0,
    "stock_total": 0,
    "total_ofertas": 0,
    "variantes": [
      {
        "id_producto_variante": 93,
        "nombre_variante": "M azul",
        "descripcion": "Talla M, color azul",
        "fecha_creacion": { "$date": "2026-08-23T01:19:20.964Z" },
        "estado": "activa",
        "imagenes": ["https://..."],
        "precio_tienda": null,
        "precio_desde": null,
        "stock_tienda": 0,
        "stock_total": 0,
        "total_ofertas": 0,
        "caracteristicas_adicionales": [
          { "nombre": "Color", "valor": "Azul", "unidad": null },
          { "nombre": "Talla", "valor": "M", "unidad": null }
        ],
        "caracteristicas_personalizadas": [
          { "nombre": "Nota interna", "valor": 42, "unidad": null }
        ]
      }
    ],
    "caracteristicas_adicionales": [
      { "nombre": "Marca", "valor": "MarcaTest", "unidad": null },
      { "nombre": "Garantia", "valor": true, "unidad": null },
      { "nombre": "Duracion de la garantia", "valor": 12, "unidad": "meses" },
      { "nombre": "Materiales principales", "valor": ["Algodon", "Lino"], "unidad": null }
    ],
    "caracteristicas_personalizadas": [
      { "nombre": "Lote de prueba", "valor": "L001", "unidad": null }
    ]
  }
}
```

Los cinco campos calculados (`precio_tienda`, `precio_desde`, `stock_tienda`,
`stock_total`, `total_ofertas`) nacen siempre en `null`/`0`, a nivel del
producto y de cada variante: todavía no existe ninguna oferta. Se activan
recién cuando alguien crea una oferta sobre esta variante (`POST
/vendedor/ofertas`).

También se crea, en `productos_eventos`, el primer evento
(`_id: "51-1"`, `numero: 1`, `operacion: "creacion"`) con `datos` siendo la
copia completa del producto recién creado (sin `_id`, ese ya va en
`id_producto`).

Probado en vivo el 25 de agosto de 2026: crear un producto sin
`precio`/`stock_inicial` (201, los cinco campos en `null`/`0`), crear otro
mandándolos igual a propósito (formato viejo) y confirmar que no rechaza
la petición ni los guarda en ningún lado, y verificado directo en Mongo
que el evento de `productos_eventos` tampoco los tiene.

### 400

```json
{ "ok": false, "mensaje": "El nombre del producto es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre del producto no puede tener mas de 200 caracteres", "payload": null }
{ "ok": false, "mensaje": "El id de la categoria no es valido", "payload": null }
{ "ok": false, "mensaje": "La categoria no existe o no es valida para publicar", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos una variante", "payload": null }
{ "ok": false, "mensaje": "El nombre de la variante es obligatorio", "payload": null }
{ "ok": false, "mensaje": "La descripcion de la variante es obligatoria", "payload": null }
{ "ok": false, "mensaje": "imagenes debe ser una lista de URLs de texto", "payload": null }
{ "ok": false, "mensaje": "Cada caracteristica necesita un nombre", "payload": null }
{ "ok": false, "mensaje": "La caracteristica \"<nombre>\" viene repetida", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" no es una caracteristica de esta categoria", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser texto", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser un numero entero", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser un numero", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser verdadero o falso", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" debe ser una lista de texto con al menos un elemento", "payload": null }
{ "ok": false, "mensaje": "Cada caracteristica personalizada necesita un nombre valido", "payload": null }
{ "ok": false, "mensaje": "La caracteristica personalizada \"<nombre>\" viene repetida", "payload": null }
{ "ok": false, "mensaje": "El valor de \"<nombre>\" debe ser texto, numero o verdadero/falso", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

Cuando el token no tiene rol vendedor ni admin (por ejemplo, un comprador).

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Cuando el token sí es de un vendedor, pero no es la cuenta de la tienda —
mismo mensaje genérico que un id que no existe, para no confirmarle a un
vendedor cualquiera que la ruta funciona.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo crear el producto", "payload": null }
```

---

## POST /vendedor/productos/propuestas

**Cualquier vendedor** (o admin) **propone** un producto nuevo para el
catálogo. A diferencia de `POST /vendedor/productos` (solo la tienda o un
admin, nace `borrador`):

- **No exige ser la tienda ni admin.** El guard de la clase ya deja fuera a
  los compradores (403); dentro, cualquier rol vendedor o admin puede
  proponer.
- El producto nace en Mongo con estado **`en_revision`**, que **no
  circula**: `GET /productos`, la ficha pública y `POST /vendedor/ofertas`
  filtran por `activo` (lista blanca), así que queda oculto hasta que un
  admin o la tienda lo apruebe. Sí aparece en `GET /vendedor/productos/paginado`
  (el panel de la tienda muestra todos los estados).
- Además del documento de Mongo y su evento de creación (igual que
  `POST /vendedor/productos`), escribe una fila en **`propuesta_producto`**
  de PostgreSQL: `id_usuario` = quien propone, `id_producto_mongo` = el
  `_id` recién generado, `fecha_aprobacion` y `comentario_aprobacion` en
  NULL. Esa fila es la que sabe quién propuso y llevará la aprobación.

**El cuerpo es idéntico al de `POST /vendedor/productos`** (`id_categoria`,
`nombre`, `descripcion?`, `caracteristicas_adicionales?`,
`caracteristicas_personalizadas?`, `variantes` con al menos una) y se
valida igual, con los mismos mensajes. Sin precio ni stock: eso es de la
oferta. El vendedor crea su oferta a mano con `POST /vendedor/ofertas`
**después** de que se apruebe.

Las dos escrituras (Mongo y Postgres) son en bases distintas y no hay
transacción entre ellas. El orden es Mongo primero; si el `INSERT` en
`propuesta_producto` falla, se deshace la escritura de Mongo
(`deshacerProductoMongo`) para no dejar un producto `en_revision` sin
proponente.

### 201

```json
{
  "ok": true,
  "mensaje": "Propuesta de producto enviada a revision",
  "payload": {
    "_id": 103,
    "nombre": "Audifonos Ronda Pro",
    "descripcion": "...",
    "fecha_creacion": "2026-08-29T04:11:02.331Z",
    "estado": "en_revision",
    "categoria": { "id_categoria": 9, "nombre": "Audifonos", "categoria_padre": "Electronica" },
    "precio_tienda": null,
    "precio_desde": null,
    "stock_tienda": 0,
    "stock_total": 0,
    "total_ofertas": 0,
    "variantes": [ ... ]
  }
}
```

Misma forma que `POST /vendedor/productos`, con `estado: "en_revision"`.

### 400

Mismos mensajes que `POST /vendedor/productos`
(`Debes enviar al menos una variante`, `El id de la categoria no es
valido`, `La categoria no existe o no es valida para publicar`, nombre y
características, etc.). Una validación fallida **no escribe nada** ni en
Mongo ni en `propuesta_producto`.

### 401 / 403

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

403 solo para un comprador (rol 1). Un vendedor o un admin siempre pasan.

### 409

```json
{ "ok": false, "mensaje": "No se pudo registrar la propuesta. Volve a intentarlo.", "payload": null }
```

Choque de `id_producto_mongo` en `propuesta_producto` (dos propuestas
simultáneas por el mismo id). El producto de Mongo ya se deshizo; reintentar
resuelve.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo enviar la propuesta", "payload": null }
```

Probado en vivo el 29 de agosto de 2026 (41 comprobaciones): el producto
nace `en_revision` en Mongo con su evento de creación; la fila de
`propuesta_producto` sale con el `id_usuario` correcto y el resto NULL; el
producto no aparece en el buscador ni en la ficha ni se le puede crear una
oferta (404), pero sí en `/vendedor/productos/paginado`; un comprador → 403,
sin sesión → 401, un admin también puede proponer; las validaciones dan los
mismos 400 que `POST /vendedor/productos` sin escribir nada; y forzando un
choque de id se confirmó que el producto de Mongo se deshace y la respuesta
es 409.

---

## GET /vendedor/productos/propuestas

Las propuestas del **vendedor logueado** — las que él propuso, más recientes
primero. El `WHERE` exige `propuesta_producto.id_usuario`, así que **no hay
forma de ver las de otro vendedor**. Cualquier vendedor o admin ve las
suyas (sin `exigirTiendaOAdmin`).

Cada propuesta trae:

- `id_propuesta_producto`, `id_producto` (el `_id` en Mongo),
  `fecha_propuesta`, `fecha_aprobacion` (NULL si no está aprobada),
  `comentario_aprobacion` (la nota de quien aprobó, NULL si no).
- `producto`: el documento completo del producto desde Mongo (con su
  `estado` actual — `en_revision` / `rechazado` / `activo`). `null` solo si
  el documento no se encontró (no debería pasar).
- `rechazos`: el historial, del más reciente al más viejo. `[]` si nunca se
  rechazó.
- **Sin** `vendedor` (ya sé que soy yo).

Dos consultas a Postgres (`propuesta_producto`, `rechazo_producto` con un
`= ANY`) y una a Mongo (`$in`), sin importar cuántas propuestas haya.

### 200

```json
{
  "ok": true,
  "mensaje": "Propuestas obtenidas",
  "payload": [
    {
      "id_propuesta_producto": "7",
      "id_producto": 104,
      "fecha_propuesta": "2026-08-29T05:10:11.004Z",
      "fecha_aprobacion": null,
      "comentario_aprobacion": null,
      "producto": { "_id": 104, "nombre": "...", "estado": "rechazado", "categoria": { ... }, "variantes": [ ... ], ... },
      "rechazos": [
        { "id_rechazo_producto": "3", "razon_rechazo": "La categoria no corresponde", "fecha_rechazo": "2026-08-20T15:00:00.000Z" }
      ]
    }
  ]
}
```

`[]` si el vendedor no ha propuesto nada.

### 401 / 403

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

403 solo para un comprador.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudieron obtener las propuestas", "payload": null }
```

---

## GET /vendedor/productos/propuestas/sin-aprobar

Todas las propuestas que **no han sido aprobadas** todavía
(`fecha_aprobacion IS NULL`) — las `en_revision` esperando y las
`rechazado` que el vendedor no ha vuelto a enviar. De **cualquier
vendedor**, la más antigua primero (cola de trabajo). **Solo
`tienda@mesh.com` o un admin** — un vendedor cualquiera recibe el **mismo
404 genérico** que oculta que la ruta existe.

Misma forma que `GET /vendedor/productos/propuestas`, **más el
`vendedor`** que propuso cada una:

```json
"vendedor": { "id_usuario": "4", "usuario": "ventas_norte", "nombre": "Carlos", "apellido": "Ramirez" }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Un vendedor que no es la tienda ni admin — mismo mensaje reutilizado.

### 401 / 403 / 503 / 500

Como las demás.

---

## GET /vendedor/productos/propuestas/todas

Todas las propuestas, **en cualquier estado**, más recientes primero. De
cualquier vendedor. **Solo `tienda@mesh.com` o un admin** (404 disfrazado
para el resto). Misma forma que `/sin-aprobar` (con `vendedor`); aquí sí
salen las aprobadas, con su `fecha_aprobacion` y `comentario_aprobacion`.

Probado en vivo el 29 de agosto de 2026 (39 comprobaciones, los tres GET):
"las mías" está acotado por `id_usuario` (ventas_norte no ve las de
ventas_sur ni al revés) y no trae `vendedor`; `/sin-aprobar` trae P1 y P2
(no la aprobada P3) con el `vendedor` correcto y orden ascendente;
`/todas` trae las tres con orden descendente; un vendedor normal recibe
404 en las dos de tienda/admin y el comprador 403; el `producto` embebido
es el documento completo de Mongo; y con dos rechazos sobre una propuesta
salen del más reciente al más viejo.

---

## GET /vendedor/productos/propuestas/:id/rechazos

El historial de rechazos de **una** propuesta. `:id` es el `_id` del
producto en Mongo.

- **La tienda o un admin** la ven de **cualquier** propuesta.
- **El vendedor** que la propuso, solo de **la suya**.
- Cualquier otro caso, o una propuesta que no existe → **404 genérico**
  (`"No existe una propuesta para ese producto"`).
- Una propuesta que nunca fue rechazada → `[]`, no 404.

```json
{
  "ok": true,
  "mensaje": "Rechazos de la propuesta obtenidos",
  "payload": [
    { "id_rechazo_producto": "5", "razon_rechazo": "Segundo intento, foto mala", "fecha_rechazo": "2026-08-25T21:00:00.000Z" },
    { "id_rechazo_producto": "3", "razon_rechazo": "La categoria esta mal", "fecha_rechazo": "2026-08-20T15:00:00.000Z" }
  ]
}
```

### 400 / 401 / 403 / 404 / 503 / 500

Como el resto. 400 solo por `:id` con formato inválido.

Probado en vivo el 29 de agosto de 2026 (36 comprobaciones, con el GET de
rechazos de oferta): el vendedor ve los de su propia propuesta (ordenados,
`[]` si no hay), y 404 en una ajena; la tienda y un admin ven los de
cualquiera; producto inexistente o normal (sin propuesta) → 404; `id`
inválido → 400; comprador → 403; sin sesión → 401.

---

## PATCH /vendedor/productos/:id/revision

**La tienda o un admin** aprueba una propuesta `en_revision` (pasa a
`activo` y ya circula) o la **rechaza** con un motivo (pasa a `rechazado`;
se guarda una fila en `rechazo_producto`). `:id` es el `_id` del producto
en Mongo.

**Solo `tienda@mesh.com` o un admin** — un vendedor cualquiera, **incluido
el que propuso**, recibe el **mismo 404 genérico**. La comprobación de
permiso va antes de validar el id o el cuerpo.

La propuesta tiene que estar en estado **`en_revision`**; cualquier otro
estado → 409 (una `rechazado` hay que reenviarla primero;
`PATCH .../:id/reenviar`). Un producto normal del catálogo (sin fila en
`propuesta_producto`) → 404.

Como el estado del producto vive en Mongo, la sincronización es un
`SELECT ... FOR UPDATE` sobre la fila de `propuesta_producto`: dos
revisiones a la vez sobre la misma propuesta se serializan ahí (y
`reenviar` toma el mismo lock). Se escribe primero Mongo (estado + un
evento de modificación en `productos_eventos`) y luego Postgres; si
Postgres falla, se hace ROLLBACK y se revierte Mongo.

```json
{ "decision": "aprobar" }
{ "decision": "aprobar", "comentario": "Buen aporte al catalogo" }
{ "decision": "rechazar", "razon": "La categoria no corresponde" }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `decision` | Sí | `"aprobar"` o `"rechazar"` |
| `razon` | Solo si `decision` es `"rechazar"` | Texto no vacío. Se guarda recortado en `rechazo_producto.razon_rechazo` |
| `comentario` | No | Solo se guarda si `decision` es `"aprobar"`. Texto; se guarda recortado (o NULL si vacío) en `propuesta_producto.comentario_aprobacion` |

### 200

```json
{
  "ok": true,
  "mensaje": "Propuesta aprobada",
  "payload": { "_id": 103, "estado": "activo", "nombre": "...", "variantes": [ ... ], ... }
}
```

`mensaje` es `"Propuesta aprobada"` o `"Propuesta rechazada"`; `payload` es
el documento del producto con su nuevo `estado`. Al aprobar se ponen
`propuesta_producto.fecha_aprobacion = now()`, `id_usuario_aprobo` (quien
aprobó) y el `comentario` si vino.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La decision debe ser una de: aprobar, rechazar", "payload": null }
{ "ok": false, "mensaje": "La razon del rechazo es obligatoria y no puede estar vacia", "payload": null }
{ "ok": false, "mensaje": "El comentario debe ser texto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Producto inexistente, producto normal (sin propuesta), o quien llama no es
la tienda ni un admin.

### 409

```json
{ "ok": false, "mensaje": "Esta propuesta no esta en revision (esta activo)", "payload": null }
```

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo revisar la propuesta", "payload": null }
```

Probado en vivo el 29 de agosto de 2026 (81 comprobaciones, con
`/reenviar`): aprobar → `activo` (visible, con oferta posible),
`fecha_aprobacion` / `id_usuario_aprobo` / `comentario` puestos, evento de
modificación, sale de `/sin-aprobar`; rechazar → `rechazado`, fila en
`rechazo_producto`, `fecha_aprobacion` sigue NULL, sigue en `/sin-aprobar`;
admin también puede; `decision` inválida / `razon` vacía / `comentario` no
texto → 400 sin mover nada; revisar una `activo`/`rechazado` → 409; producto
normal → 404; vendedor normal (incluido el que propuso) → 404, comprador →
403; el historial reconstruye el estado por fecha; **12 carreras
aprobar-vs-rechazar** siempre 1×200 + 1×409 con estado coherente; y
forzando un fallo de Postgres se confirmó que Mongo se revierte (estado y
evento).

---

## PATCH /vendedor/productos/:id/reenviar

El **vendedor que propuso** re-envía su propia propuesta **rechazada** a
revisión: `rechazado` → `en_revision`, **sin editar nada** (por diseño una
propuesta no se edita; si quiere cambiarla, propone otra). `:id` es el
`_id` del producto en Mongo. Sin cuerpo.

**Solo el dueño de la propuesta** (`propuesta_producto.id_usuario`). Una
propuesta ajena, inexistente, o de la tienda/un admin (que no son dueños de
propuestas) → **404 genérico**. La propuesta tiene que estar `rechazado`;
cualquier otro estado → 409.

El rechazo previo **se conserva** en `rechazo_producto` — reenviar no borra
el historial.

### 200

```json
{
  "ok": true,
  "mensaje": "Propuesta reenviada a revision",
  "payload": { "_id": 103, "estado": "en_revision", ... }
}
```

### 400 / 401 / 403 / 404 / 409 / 503 / 500

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "No existe una propuesta tuya para ese producto", "payload": null }
{ "ok": false, "mensaje": "Solo se puede reenviar una propuesta rechazada (esta en_revision)", "payload": null }
{ "ok": false, "mensaje": "No se pudo reenviar la propuesta", "payload": null }
```

---

## PATCH /vendedor/productos/:id

**Solo `tienda@mesh.com` o una cuenta con rol admin**, igual que
`POST /vendedor/productos` — mismo 404 genérico para cualquier otro
vendedor. Edita cualquier campo que tenga
sentido cambiar: `nombre`, `descripcion`, `estado`, `id_categoria`,
`caracteristicas_adicionales`, `caracteristicas_personalizadas` y
**`variantes`** — sí, las variantes se editan aquí mismo, como un campo
más del producto, no en una ruta aparte. Sin precio ni stock, igual que al
crear: eso se edita en la oferta (`PATCH /vendedor/ofertas/:id`), nunca
aquí.

**No edita un producto que esté en el flujo de propuesta** (`en_revision`
o `rechazado`): cualquier `PATCH` sobre uno de esos —incluido
`{estado:'activo'}`— responde **409**, sin tocar nada. La única forma de
sacar un producto de esos dos estados es
`PATCH /vendedor/productos/:id/revision` (aprobar/rechazar) o
`PATCH /vendedor/productos/:id/reenviar` — las rutas que dejan constancia
en `propuesta_producto` de quién y cuándo. Sin este candado, un
`PATCH .../:id {estado:'activo'}` publicaba el producto dejando su
propuesta con `fecha_aprobacion = NULL` para siempre: atascada en
`GET /vendedor/productos/propuestas/sin-aprobar` y sin poder reenviarse
(reenviar exige estado `rechazado`).

Cada campo es independiente: el que venga en `null` (o no venga) no se
toca. Debe venir al menos uno. Para las dos listas de características, un
array (aunque sea `[]`) reemplaza la lista completa; `null` es no tocarla.
Enviar `[]` a propósito la vacía del todo (el producto queda sin ese campo,
igual que si nunca hubiera tenido características).

**`variantes` se comporta distinto: no admite quedar vacío.** Si se manda,
reemplaza el array completo — mismas reglas que al crear el producto
(`nombre_variante` y `descripcion` obligatorios, características
validadas contra `caracteristicas_variante` de la categoría vigente) —
pero siempre tiene que traer al menos una: un producto nunca se queda sin
ninguna variante, ni siquiera al editar.

### Conservar una variante (`variantes[].id_producto_variante`)

Cada variante del array puede traer, opcionalmente, el
`id_producto_variante` que ya tenía (el mismo que devuelve `GET
/vendedor/productos/:id`). Esto decide si esa variante se trata como "la
misma, editada" o como una completamente nueva:

- **Si lo manda y coincide con una variante que el producto ya tenía**, esa
  variante **conserva ese mismo id, su `fecha_creacion`, su `estado` real y
  sus cinco campos calculados** (`precio_tienda`/`precio_desde`/
  `stock_tienda`/`stock_total`/`total_ofertas`) — solo `nombre_variante`,
  `descripcion`, `imagenes` y las características cambian a lo que venga
  en la petición, porque son los únicos datos de la variante que esta ruta
  de verdad pregunta.
- **Si no lo manda**, es una variante nueva de verdad: le toca un
  `id_producto_variante` nuevo, nace `activa`, hoy, y con los cinco campos
  calculados en `null`/`0` (todavía no existe ninguna oferta sobre ella).
- **Si lo manda y no coincide con ninguna variante actual del producto**,
  la edición completa se rechaza (400) — no se crea una variante nueva
  ignorando el id que se mandó, ni se adivina a cuál se refería.

```
PATCH /vendedor/productos/53
{
  "variantes": [
    { "id_producto_variante": 5, "nombre_variante": "M azul (renombrada)", "descripcion": "..." },
    { "nombre_variante": "Talla XL", "descripcion": "..." }
  ]
}
-> la variante 5 conserva su id, fecha de creacion, estado y campos calculados; "Talla XL" nace con id nuevo
```

**Corregido y probado en vivo el 25 de agosto de 2026** (antes de esto,
`construirVariantes` reiniciaba `precio_tienda`/`precio_desde`/
`stock_tienda`/`stock_total`/`total_ofertas`, `fecha_creacion` y `estado`
de **cualquier** variante que viniera en el array, incluida una
"conservada" sin ningún cambio real — le borraba las ofertas activas que
tuviera y, de paso, la raíz del producto quedaba con números viejos que ya
no coincidían con sus propias variantes). La corrección: para una variante
conservada (encontrada por `id_producto_variante`), esos siete campos se
copian de la variante existente en vez de reinicializarse; solo una
variante genuinamente nueva nace con los valores por defecto.

Casos probados contra la base real:
- Producto con una oferta activa (precio 120.00, stock 10) sobre una
  variante — editar el nombre de **otra** variante del mismo producto ya
  no le borra nada a la primera (antes sí, aunque ni se mencionaba en la
  petición más que para conservarla).
- Agregar una variante nueva junto a las que ya existían: la nueva nace
  en `null`/`0`/`activa`/hoy: las viejas no se mueven ni un campo.
- Editar de verdad el `nombre_variante`/`descripcion` de la variante con
  oferta: esos dos cambian, los cinco calculados y la fecha de creación
  siguen intactos.
- Caso extremo: una variante con `estado: "inactiva"` (no lo pone ninguna
  ruta hoy, se forzó a mano para la prueba) sobrevive intacta a varias
  ediciones seguidas del producto — antes del fix, cualquier edición la
  hubiera vuelto `activa` sola.
- La reconstrucción de historial (`GET .../historial`) se probó de nuevo
  después de la corrección: sigue devolviendo el estado correcto.
- Un id de variante que no pertenece al producto se sigue rechazando con
  400, igual que siempre.

Un id que no existe, o cualquier cuenta que no sea la tienda ni admin: mismo
404 — no hay forma de usar esta ruta para confirmar qué productos existen
si no eres la tienda o admin.

Un mismo evento de modificación puede traer varias llaves en `cambios` a
la vez, una por cada cosa que cambió en esa edición (por ejemplo, `nombre`
y `estado` juntos, o `categoria` y `variantes` juntos, si se mandan en la
misma petición).

### El caso especial: cambiar de categoría

Las características siempre están atadas a la categoría — nunca sueltas, y
esto aplica igual a las de la raíz que a las de cada variante. Por eso:

- **Si mandas `caracteristicas_adicionales` y/o `variantes` nuevas**, se
  validan contra la categoría que quede vigente después de esta edición (la
  nueva, si también mandaste `id_categoria`; si no, la que ya tenía).
- **Si cambias `id_categoria` sin mandar características ni variantes
  nuevas**, se revisa que las que el producto ya tenía — las suyas y las de
  cada variante existente — sigan siendo válidas para la categoría nueva.
  Si alguna ya no encaja, la edición se rechaza: hay que mandar también las
  características (o las variantes) correctas en la misma petición.

```
PATCH /vendedor/productos/53
{ "id_categoria": 27 }
-> rechazado si alguna variante tenia "Color" y la categoria nueva no lo ofrece

PATCH /vendedor/productos/53
{ "id_categoria": 27, "variantes": [{ "nombre_variante": "Edicion unica", "descripcion": "Libro" }] }
-> aceptado: categoria y variantes cambian juntas, en el mismo evento
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto actualizado correctamente",
  "payload": { "...": "el producto completo, ya actualizado" }
}
```

También se agrega un evento de modificación en `productos_eventos`, con
`cambios` conteniendo solo las llaves que de verdad cambiaron, cada una
completa (el array entero, no un diff adentro) — mismo criterio que ya usan
`categoria` y `variantes` en los eventos existentes.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos un campo para actualizar", "payload": null }
{ "ok": false, "mensaje": "El nombre del producto es obligatorio", "payload": null }
{ "ok": false, "mensaje": "El nombre del producto no puede tener mas de 200 caracteres", "payload": null }
{ "ok": false, "mensaje": "La descripcion no puede quedar vacia", "payload": null }
{ "ok": false, "mensaje": "El estado debe ser uno de: borrador, activo, inactivo", "payload": null }
{ "ok": false, "mensaje": "El id de la categoria no es valido", "payload": null }
{ "ok": false, "mensaje": "La categoria no existe o no es valida para publicar", "payload": null }
{ "ok": false, "mensaje": "\"<nombre>\" ya no es una caracteristica valida para la nueva categoria", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos una variante", "payload": null }
{ "ok": false, "mensaje": "La variante <id> no pertenece a este producto", "payload": null }
```

Más los mismos errores de característica que `POST /vendedor/productos`
(nombre repetido, tipo incorrecto, no pertenece a la categoría, formato de
personalizada inválido — ver arriba). Si el cuerpo trae `precio` o
`stock_inicial` en alguna variante, se ignoran en silencio, igual que en
`POST /vendedor/productos`.

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Un id que no existe, o cualquier cuenta que no sea la tienda ni admin (el
mismo 404 disfrazado) — este 404 **le gana al 409** de abajo: a un vendedor
ajeno no se le confirma que el producto existe, aunque esté `en_revision`.

### 409

```json
{ "ok": false, "mensaje": "Este producto esta en el flujo de propuesta (en_revision) y no se edita por aca: usa PATCH /vendedor/productos/:id/revision para aprobarlo o rechazarlo, o /reenviar si es una propuesta rechazada", "payload": null }
```

El producto está `en_revision` o `rechazado`. Esos dos estados solo se
mueven por `PATCH .../:id/revision` o `.../:id/reenviar`. Las validaciones
de formato (400 — id inválido, cuerpo vacío, estado inválido en el body)
**le ganan** a este 409: se revisan antes de leer el producto.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo actualizar el producto", "payload": null }
```

### Candado del flujo de propuesta — probado en vivo el 29 de agosto de 2026

36 comprobaciones, 0 fallos. Un vendedor propone un producto (nace
`en_revision`) y:

- `PATCH .../:id {estado:'activo'}` como tienda **y** como admin → **409**;
  el producto sigue `en_revision`, no aparece en `GET /productos/:id` y
  sigue en `/propuestas/sin-aprobar`.
- Cualquier otro campo (`{nombre}`, `{descripcion}`) → 409 también.
- El flujo bueno sigue intacto: `PATCH .../:id/revision {decision:'aprobar'}`
  → 200, `activo`, `propuesta_producto.fecha_aprobacion` e
  `id_usuario_aprobo` quedan puestos, sale de `/sin-aprobar`, se vuelve
  visible; y ya `activo`, `PATCH .../:id {descripcion}` vuelve a dar 200.
- `rechazado` bloqueado igual; `PATCH .../:id/reenviar` (del proponente) no
  se ve afectado — devuelve el producto a `en_revision`, donde el candado
  sigue aplicando.
- Regresión: un `borrador` (creado por `POST /vendedor/productos`) se edita
  y transiciona `borrador → activo → inactivo` por esta ruta sin problema.
- Precedencias: un vendedor ajeno recibe 404 (no 409), un comprador 403; el
  cuerpo vacío / `estado` inválido / id no numérico dan 400 antes del 409.

---

## GET /vendedor/productos

**Solo `tienda@mesh.com` o una cuenta con rol admin**, igual que
`POST /vendedor/productos` — no es "mis productos", es el catálogo
completo para administrarlo. Cualquier
otro vendedor recibe el mismo 404 genérico que las demás rutas de
`/vendedor/productos` (ver la tabla al principio de este archivo), aunque
aquí no haya ningún `id` de por medio: el mensaje es el mismo
`"No existe un producto con ese id"`, reutilizado tal cual.

Todo el catálogo, **en cualquier estado** (`borrador`, `activo` e
`inactivo` — a diferencia del catálogo público, que oculta `borrador` e
`inactivo`): la tienda tiene que poder ver y administrar lo que todavía
no se ha publicado, no solo lo que ya está activo. Ordenados por
`fecha_creacion`, más reciente primero. Sin paginación ni filtros — trae
todo de una vez.

**Sin `variantes[].stock`, a propósito.** Esta es una ruta "rápida": no
toca PostgreSQL. El stock real es de cada oferta, no del producto — ver
[GET /vendedor/ofertas](#get-vendedorofertas).

### 200

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": [
    { "_id": 52, "nombre": "...", "estado": "borrador", "...": "..." }
  ]
}
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Este es el que sale para **cualquier cuenta que no sea la tienda ni
admin** — el mismo mensaje que usan las rutas con `:id`, aunque aquí no
se haya mandado ningún id.

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas de `/vendedor/productos` (ver arriba).

---

## GET /vendedor/productos/paginado

**Solo `tienda@mesh.com` o una cuenta con rol admin**, igual que
`GET /vendedor/productos` — mismo 404 genérico para cualquier otro
vendedor. Lo mismo que `GET /vendedor/productos` (el catálogo completo,
**en cualquier estado**, sin excluir `borrador`/`inactivo`), pero
paginado por número de página — igual que `GET /productos/paginacion`
del catálogo público, no por cursor — y con un solo filtro posible.

**Un solo filtro, a propósito: `nombre`, "contiene".** A diferencia del
catálogo público (`GET /productos`/`/paginacion`, con filtros fijos y
dinámicos por categoría, precio, stock y características), este panel
solo necesita encontrar un producto por nombre en toda la lista — no
tiene sentido filtrar por precio o stock de la tienda cuando ya se está
viendo todo, incluido lo que ni siquiera tiene ofertas todavía. Sin
`id_categoria`, `precio_min`/`max`, `stock_min`/`max` ni características:
ninguno de esos existe aquí.

**El filtro `nombre` es insensible a mayúsculas y a tildes.** Buscar
`camara` encuentra "Cámara" y buscar `Cámara` encuentra "camara" — sin
importar de qué lado quedó la tilde. La `í` insensible a mayúsculas de
`GET /productos?nombre=` (`$options: 'i'` en el regex de Mongo) no cubre
tildes por sí sola; `construirRegexNombreFlexible()`
(`helpers/validaciones-productos.ts`) expande cada vocal del término de
búsqueda a una clase de caracteres que cubre sus variantes acentuadas,
antes de armar el regex. La `ñ` **no** se funde con la `n` a propósito:
es una letra distinta en español, no un acento (fundirla cambiaría el
significado — "año" ≠ "ano").

Ordenado igual que `GET /vendedor/productos`: por `fecha_creacion`, más
reciente primero.

### Query params

| Param | Tipo | Obligatorio | Qué hace |
| --- | --- | --- | --- |
| `pagina` | entero | No (por defecto 1) | Qué página pedir, 1 es la primera |
| `limite` | entero | No (por defecto 20, tope 100) | Cuántos productos trae cada página |
| `nombre` | texto | No | "Contiene", insensible a mayúsculas y a tildes |

### Ejemplo

```
GET /vendedor/productos/paginado?nombre=camara&limite=10&pagina=1
```

### 200

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": {
    "productos": [ "... mismos documentos que GET /vendedor/productos ..." ],
    "pagina": 1,
    "limite": 10,
    "total_productos": 2,
    "total_paginas": 1
  }
}
```

### 400

```json
{ "ok": false, "mensaje": "La pagina debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El limite debe ser un numero entero mayor a 0", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Este es el que sale para **cualquier cuenta que no sea la tienda ni
admin** — mismo mensaje genérico que el resto de `/vendedor/productos`,
aunque aquí tampoco haya ningún `id` de por medio.

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas de `/vendedor/productos` (ver arriba).

---

## GET /vendedor/productos/:id

**Solo `tienda@mesh.com` o una cuenta con rol admin**, igual que las demás
rutas de `/vendedor/productos` (ver la tabla al principio del archivo). Un
producto tal como está **hoy**, con todos sus detalles (el mismo
documento completo que devuelven las rutas de creación y edición). A
diferencia del catálogo público (que no tiene una ruta de detalle por id
todavía, y de cualquier forma solo mostraría productos `activo`), esta
funciona sin importar el estado — sirve justo para ver un producto en
`borrador` o `inactivo` antes de publicarlo.

Un id que no existe, o cualquier cuenta que no sea la tienda ni admin: mismo 404.

**Sin `variantes[].stock`, a propósito** — mismo motivo que
`GET /vendedor/productos` (ver arriba): el stock real es de cada oferta,
ver [GET /vendedor/ofertas/producto/:idProducto](#get-vendedorofertasproductoidproducto).

### 200

```json
{
  "ok": true,
  "mensaje": "Producto obtenido",
  "payload": { "_id": 52, "nombre": "...", "estado": "activo", "...": "..." }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas.

---

## GET /vendedor/productos/:id/historial

**Solo `tienda@mesh.com` o una cuenta con rol admin**, igual que las demás
rutas de `/vendedor/productos`. Misma reconstrucción, mismo resultado, que
`GET /productos/:id/historial` (endpoints-productos.md), pública y sin
restricción de dueño — esta ruta solo le suma el chequeo de "tienda o
admin" antes de delegar (llama al mismo método). Reconstruye un producto
**como estaba en un momento específico**: toma el evento de creación y
todos los de modificación hasta ese momento, en orden, y los fusiona uno
encima del otro.

**El query param `fecha` acepta `AAAA-MM-DD` (todo ese día, hora de
Guatemala) o `AAAA-MM-DDTHH:MM[:SS]` (hasta ese instante inclusive, hora en
UTC)** — el detalle completo, con la tabla de las dos formas, está en
`endpoints-productos.md` (`GET /productos/:id/historial`).

**Se arma con el framework de agregación de Mongo, no en el código del
backend**: la búsqueda, el orden y la fusión de eventos pasan dentro de un
pipeline de `db.productos_eventos.aggregate(...)` (`$match`, `$sort`,
`$group`, `$reduce`, `$mergeObjects`) — el backend solo valida el id y la
fecha, y le agrega el `_id` de vuelta al resultado. El `$match` usa `$lt`
sobre la medianoche del día siguiente cuando se da solo la fecha, y `$lte`
sobre el instante exacto cuando se da hora.

Como cada evento aporta el estado completo de lo que cambió (`datos` en la
creación, `cambios` en cada modificación — nunca un campo suelto), fusionar
todos en orden con `$mergeObjects` reconstruye el documento exacto de ese
momento: si algo cambió dos veces antes del momento pedido, se queda con el
valor de la segunda vez, porque se fusiona después y lo sobrescribe.

**Nunca trae `variantes[].stock`**, ni de la fecha pedida ni de hoy: el
stock no es parte de ningún evento (ver `cambios-etl-productos.md`), así
que reconstruir un producto a una fecha pasada no dice qué stock tenía en
ese momento — eso solo lo sabe el libro `stock_movimiento` en PostgreSQL.

Un id que no existe, o cualquier cuenta que no sea la tienda ni admin: mismo 404.
Una fecha anterior a la creación del producto también da 404, con un
mensaje distinto (el producto sencillamente no existía todavía).

```
GET /vendedor/productos/52/historial?fecha=2026-01-07
GET /vendedor/productos/52/historial?fecha=2026-01-07T13:00
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto reconstruido correctamente",
  "payload": { "_id": 52, "nombre": "Producto historico editado", "estado": "borrador", "...": "..." }
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La fecha es obligatoria", "payload": null }
{ "ok": false, "mensaje": "La fecha debe tener el formato AAAA-MM-DD o AAAA-MM-DDTHH:MM (con :SS opcional)", "payload": null }
{ "ok": false, "mensaje": "La fecha no es valida", "payload": null }
{ "ok": false, "mensaje": "La hora no es valida", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
{ "ok": false, "mensaje": "El producto no existia en esa fecha", "payload": null }
```

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas.

---

# Las ofertas: modelo multi-vendedor

Todo lo de aquí abajo (`/vendedor/ofertas`) **sí** está construido contra el
modelo nuevo — nada de parche. Las ofertas viven solo en PostgreSQL (tabla
`oferta`, `migrations/005_ofertas.sql`); el catálogo (nombre, variantes,
imágenes) vive solo en Mongo. Las dos rutas de aquí cruzan las dos bases:
Postgres dice qué es mío, Mongo le pone nombre.

**Cualquier vendedor, o admin, no solo la tienda.** A diferencia de crear
un producto del catálogo (solo `tienda@mesh.com` o admin), publicar una
oferta sobre un producto que ya existe es lo que cualquier cuenta con rol
vendedor **o admin** puede hacer — es el corazón del modelo
multi-vendedor. Eso sí: no hay ningún chequeo de cuenta específica aquí
que **bloquee** (a diferencia de `/vendedor/productos`), pero para un
admin sí hay una **sustitución de identidad** — la oferta nace bajo la
cuenta de la tienda, no bajo la del admin (ver "Ofertas creadas por un
admin caen bajo la cuenta de la tienda" más arriba). Un vendedor que no
es admin sigue actuando bajo su propia cuenta, sin cambios. `POST
/vendedor/ofertas` (crear) y `PATCH /vendedor/ofertas/:id` (editar precio,
estado y/o stock) ya están hechos.

---

## GET /vendedor/ofertas

Todas mis ofertas — **en cualquier estado** (`activa`, `pausada` o
`retirada`: es mi panel, tengo que poder ver las tres, a diferencia de la
ficha pública de `GET /productos/:id`, que solo enseña las activas). Cada
una trae el nombre del producto y de la variante, y su portada, para no
tener que pedir cada producto aparte. Ordenadas por la más recién tocada
primero (`fecha_actualizacion`).

**Con sesión de admin, "mis ofertas" son las de la cuenta de la tienda**,
no las del admin — ver la nota al principio del archivo. No debería haber
nunca una oferta bajo el id propio de un admin, porque `POST
/vendedor/ofertas` nunca la deja nacer ahí.

Dos consultas nada más, sin importar cuántas ofertas haya: una a Postgres
por todas mis filas de `oferta`, y una sola a Mongo por todos los
productos distintos que aparecen ahí (con `$in`) — nunca una consulta a
Mongo por oferta.

Sin paginación por ahora: para un vendedor de prueba son decenas de
ofertas, no miles (mismo criterio que `GET /vendedor/productos` hoy).

```
GET /vendedor/ofertas
```

### 200

```json
{
  "ok": true,
  "mensaje": "Ofertas obtenidas",
  "payload": [
    {
      "id_oferta": "5",
      "id_producto": 2,
      "id_producto_variante": 2,
      "nombre_producto": "Laptop Bastion 16",
      "nombre_variante": "64 GB / 2 TB",
      "imagen": null,
      "precio": "13803.00",
      "stock": 15,
      "estado": "pausada",
      "fecha_aprobacion": "2026-08-25T15:54:00.258Z",
      "aprobado_por": {
        "id_usuario": "2",
        "usuario": "mesh_tienda",
        "nombre": "Mesh",
        "apellido": "Tienda"
      },
      "fecha_creacion": "2026-01-09T16:22:00.000Z",
      "fecha_actualizacion": "2026-08-25T15:54:00.258Z"
    },
    {
      "id_oferta": "14",
      "id_producto": 3,
      "id_producto_variante": 5,
      "nombre_producto": "Laptop Aurora 14",
      "nombre_variante": "16 GB / 512 GB",
      "imagen": "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1e/Laptop-hard-drive-exposed.jpg/960px-Laptop-hard-drive-exposed.jpg",
      "precio": "6343.00",
      "stock": 4,
      "estado": "activa",
      "fecha_aprobacion": null,
      "aprobado_por": null,
      "fecha_creacion": "2026-01-04T16:52:00.000Z",
      "fecha_actualizacion": "2026-08-25T15:54:00.258Z"
    }
  ]
}
```

`id_oferta` sale como texto (`bigint` de Postgres, ver el resto de la API);
`id_producto`/`id_producto_variante` como número, porque son los `_id` de
Mongo. `imagen` es la primera de `variantes[].imagenes` de esa variante, o
`null` si no tiene ninguna. Si un producto o una variante no aparecieran en
Mongo (no debería pasar nunca: el catálogo no borra, solo desactiva), la
oferta sale igual con `"(producto no encontrado)"`/`"(variante no
encontrada)"` en vez de romper la lista entera por una fila huérfana.

`fecha_aprobacion` y `aprobado_por` cuentan cómo entró en circulación la
oferta (flujo de aprobación, migración `010_aprobacion_ofertas.sql`):

- `fecha_aprobacion` — cuándo la aprobó la tienda. `null` = **nunca
  aprobada**: está `pendiente`, `rechazada`, o `retirada` sin haber pasado
  por revisión. Sobrevive a que después la oferta se pause o se retire.
- `aprobado_por` — **quién** la aprobó (`id_usuario`, `usuario`, `nombre`,
  `apellido` — la cuenta de la tienda, o el admin real que la revisó). Es
  `null` en tres casos: la oferta nunca fue aprobada (`fecha_aprobacion`
  también `null`); es una oferta de la **propia tienda o de un admin**
  (nacen aprobadas sin revisor — `fecha_aprobacion` puesta, `aprobado_por`
  `null`); o es anterior al flujo de aprobación. El **dueño** de la oferta
  no sale de aquí, sale de que es tu panel.

Un vendedor sin ninguna oferta recibe `[]`, no un error.

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudieron obtener las ofertas", "payload": null }
```

---

## GET /vendedor/ofertas/pendientes

La **cola de revisión**: todas las ofertas en estado `pendiente`, de
cualquier vendedor, de la más antigua a la más nueva (`fecha_creacion`
ascendente — la que lleva más tiempo esperando va primero). Es lo que la
tienda usa para aprobar o rechazar (`PATCH /vendedor/ofertas/:id/revision`,
todavía no implementado).

**Solo `tienda@mesh.com` o un admin.** Un vendedor cualquiera recibe el
**mismo 404 genérico** que el resto de `/vendedor/*` restringido a la
tienda — no se le confirma que la ruta existe. Un admin la ve tal cual (no
hay sustitución de identidad aquí: la cola es global, no "mis pendientes").

Segmento literal: se resuelve antes que `:id/rechazos`.

```
GET /vendedor/ofertas/pendientes
```

### 200

```json
{
  "ok": true,
  "mensaje": "Ofertas pendientes obtenidas",
  "payload": [
    {
      "id_oferta": "591",
      "id_producto": 12,
      "id_producto_variante": 24,
      "nombre_producto": "Silla Ergonomica Onda",
      "nombre_variante": "Malla / Negro",
      "imagen": null,
      "precio": "80.00",
      "stock": 0,
      "fecha_creacion": "2026-08-28T21:40:11.002Z",
      "vendedor": {
        "id_usuario": "6",
        "usuario": "ventas_sur",
        "nombre": "Lucia",
        "apellido": "Morales"
      }
    }
  ]
}
```

Dos consultas en total sin importar cuántas ofertas haya: una a Postgres
(`oferta` en `pendiente` + `JOIN usuarios` por el vendedor) y una sola a
Mongo con `$in` por los productos distintos. Lista vacía (`[]`) si no hay
ninguna pendiente. `stock` puede ser `> 0`: una oferta pendiente pudo
nacer con `stock_inicial`, pero no cuenta para nada del catálogo hasta que
se apruebe.

### 401 / 403

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

Un vendedor que no es la tienda ni admin: el mismo mensaje reutilizado
(igual que `GET /vendedor/productos`, que tampoco lleva id).

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudieron obtener las ofertas pendientes", "payload": null }
```

Probado en vivo el 28 de agosto de 2026 (28 comprobaciones, con las dos
rutas GET): la cuenta coincide con `SELECT count(*) ... WHERE estado =
'pendiente'`, el admin ve la misma lista, un vendedor normal recibe 404,
el comprador 403, sin sesión 401; el contenido trae el vendedor y los
nombres correctos; las ofertas `activa`/`rechazada` no aparecen; el orden
es `fecha_creacion` ascendente.

---

## GET /vendedor/ofertas/:id/rechazos

El **historial de rechazos** de una oferta **propia**: cada vez que la
tienda la rechazó, con su motivo y su fecha, de la más reciente a la más
vieja. `:id` es `id_oferta`.

Como una oferta se puede rechazar, corregir (vuelve a `pendiente`) y
rechazar otra vez, puede haber varias filas. El historial **se conserva**
aunque la oferta ya no esté `rechazada` (la haya reenviado el vendedor, o
la tienda la haya aprobado después).

**La tienda o un admin** ven los rechazos de **cualquier** oferta (son
quienes escriben esos motivos, en `PATCH /vendedor/ofertas/:id/revision`).
**Un vendedor cualquiera**, solo los de **sus** ofertas. En los dos casos,
una oferta que no existe (o que no es suya, para un vendedor) da el mismo
**404 genérico**. Una oferta sin rechazos devuelve `[]` (no 404).

```
GET /vendedor/ofertas/174/rechazos
```

### 200

```json
{
  "ok": true,
  "mensaje": "Rechazos de la oferta obtenidos",
  "payload": [
    {
      "id_rechazo_oferta": "2",
      "razon_rechazo": "Sigue sin cumplir, foto de baja calidad",
      "fecha_rechazo": "2026-08-25T20:30:00.000Z"
    },
    {
      "id_rechazo_oferta": "1",
      "razon_rechazo": "Precio muy por debajo del mercado",
      "fecha_rechazo": "2026-08-20T16:00:00.000Z"
    }
  ]
}
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 401 / 403

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

Mismo mensaje para una que no existe y para una de otro vendedor.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudieron obtener los rechazos de la oferta", "payload": null }
```

Probado en vivo el 28 de agosto de 2026 (dueño) y el 29 de agosto de 2026
(tienda/admin): una oferta con 2 rechazos los devuelve del más reciente al
más viejo; una sin rechazos devuelve `[]`; el dueño ve las suyas y una
ajena da 404; **la tienda y un admin ven los rechazos de cualquier oferta**
(incluida una de otro vendedor); un vendedor que no es dueño ni tienda/admin
→ 404; `id` con formato inválido 400; sin sesión 401; comprador 403; y tras
reenviar la oferta (vuelve a `pendiente`) el historial sigue completo.

---

## GET /vendedor/ofertas/producto/:idProducto

Un producto completo del catálogo — misma forma que `GET /productos/:id`
(sin `ofertas`, que es una lista de vendedores para la ficha pública, no
para esto) — **pero sin excluir `inactivo`/`borrador`**: un vendedor tiene
que poder ver un producto oculto para decidir si le conviene ofertarlo,
aunque todavía no esté publicado. Cada variante trae `mi_oferta` embebida:
mi oferta sobre esa variante si tengo una, o `null` si no. Con sesión de
admin, `mi_oferta` es la de la cuenta de la tienda (misma sustitución de
identidad que en `GET /vendedor/ofertas`, ver la nota al principio del
archivo).

El segmento `producto` en la ruta es literal, a propósito: `:id` va a ser
`id_oferta` en `PATCH /vendedor/ofertas/:id` (todavía no construida), y
esta ruta necesita distinguirse por `id_producto` sin chocar con esa.

```
GET /vendedor/ofertas/producto/2
```

### 200

```json
{
  "ok": true,
  "mensaje": "Producto obtenido",
  "payload": {
    "_id": 2,
    "nombre": "Laptop Bastion 16",
    "descripcion": "Estacion de trabajo de 16 pulgadas para render y compilacion.",
    "estado": "activo",
    "categoria": { "nombre": "Laptops", "id_categoria": 7, "categoria_padre": "Electronica" },
    "precio_tienda": { "$numberDecimal": "9400.00" },
    "precio_desde": { "$numberDecimal": "9400.00" },
    "stock_tienda": 46,
    "stock_total": 68,
    "total_ofertas": 2,
    "variantes": [
      {
        "id_producto_variante": 2,
        "nombre_variante": "64 GB / 2 TB",
        "estado": "activa",
        "mi_oferta": {
          "id_oferta": "5",
          "precio": "13803.00",
          "stock": 15,
          "estado": "pausada",
          "fecha_aprobacion": "2026-08-25T15:54:00.258Z",
          "aprobado_por": {
            "id_usuario": "2",
            "usuario": "mesh_tienda",
            "nombre": "Mesh",
            "apellido": "Tienda"
          },
          "fecha_creacion": "2026-01-09T16:22:00.000Z",
          "fecha_actualizacion": "2026-08-25T15:54:00.258Z"
        }
      },
      {
        "id_producto_variante": 3,
        "nombre_variante": "32 GB / 1 TB",
        "estado": "activa",
        "mi_oferta": null
      }
    ]
  }
}
```

Un producto donde no tengo ninguna oferta todavía sale igual, con
`mi_oferta: null` en todas sus variantes — no es un error, es la señal de
"todavía no publicaste nada aquí".

`mi_oferta` trae `fecha_aprobacion` y `aprobado_por` con el mismo
significado que en `GET /vendedor/ofertas` (quién y cuándo aprobó la
tienda esa oferta; los dos `null` mientras no circule, `aprobado_por`
también `null` en las ofertas de la propia tienda/admin).

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
```

Sin el matiz de siempre de "mismo 404 que ajeno": el catálogo no es de
nadie, así que un id que no existe es sencillamente eso, sin nada que
ocultar.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo obtener el producto", "payload": null }
```

---

## POST /vendedor/ofertas

Publica una oferta sobre una variante que **ya existe** en el catálogo
compartido. Cualquier vendedor, o admin, no solo la tienda — crear la
variante misma sigue siendo solo de `tienda@mesh.com` o admin (`POST
/vendedor/productos`), pero ofertar sobre una que ya está publicada es lo
que hace a alguien vendedor en este modelo.

**Si quien crea es admin, `oferta.id_usuario` sale con el id de la cuenta
de la tienda, no el del admin** — ver "Ofertas creadas por un admin caen
bajo la cuenta de la tienda" al principio de este archivo. La respuesta
de abajo (`payload`) no expone `id_usuario` directamente, pero
`nombre_producto`/`nombre_variante` y el resto de los datos son iguales
sea quien sea que la creó; la diferencia solo se nota en que esa oferta
pasa a contar para `precio_tienda`/`stock_tienda`/`es_tienda` del
producto.

**El estado con el que nace depende de quién la crea** (flujo de aprobación
de ofertas, ver `plan pendiente/aceptacion-de-ofertas.md`):

| Quién crea | Estado inicial | `fecha_aprobacion` |
| --- | --- | --- |
| `tienda@mesh.com` (o un admin, que actúa como la tienda) | `activa` | `now()` |
| Cualquier otro vendedor | `pendiente` | `NULL` |

Una oferta `pendiente` **no circula**: no aparece en la ficha pública
(`GET /productos/:id`), no cuenta para `precio_tienda`/`precio_desde`/
`stock_tienda`/`stock_total`/`total_ofertas`, y no se puede agregar a un
pedido ni comprar (`agregar_linea` la rechaza con 409). La tienda la
aprueba después con `PATCH /vendedor/ofertas/:id/revision` (todavía no
implementado a esta fecha — solo la creación). El vendedor **sí** ve su
propia oferta `pendiente` en `GET /vendedor/ofertas`, con ese estado.

**Nace siempre con `stock = 0`**, nunca con `stock_inicial` puesto directo:
el kardex (`stock_movimiento`) tiene que explicar cada unidad, así que si
viene `stock_inicial > 0` se repone aparte, con `reponer_stock`, justo
después de que la oferta nazca — esto ocurre igual aunque la oferta esté
`pendiente` (el kardex es independiente del estado). El `reponer_stock`
toca `fecha_actualizacion` vía trigger, pero **no** `fecha_aprobacion`:
por eso el flujo de aprobación usa una columna dedicada y no
`fecha_actualizacion`.

**Solo sobre productos activos.** Un producto `inactivo`/`borrador` da el
mismo 404 que uno que no existe — mismo criterio que `GET /productos/:id`
y `agregar_linea`: nadie más lo ve, no debería poder recibir una oferta
nueva tampoco.

```
POST /vendedor/ofertas
```

```json
{
  "id_producto": 1,
  "id_producto_variante": 1,
  "precio": "3950.00",
  "stock_inicial": 7
}
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `id_producto` | Sí | El `_id` de Mongo. Entero > 0 |
| `id_producto_variante` | Sí | Tiene que ser una variante de ese producto. Entero > 0 |
| `precio` | Sí | Numero > 0, hasta 2 decimales, como texto (mismo formato que `POST /vendedor/productos`) |
| `stock_inicial` | No (por defecto 0) | Entero ≥ 0 |

### 201

```json
{
  "ok": true,
  "mensaje": "Oferta creada",
  "payload": {
    "id_oferta": "169",
    "id_producto": 1,
    "id_producto_variante": 1,
    "nombre_producto": "Laptop Nimbo 13",
    "nombre_variante": "8 GB / 256 GB",
    "imagen": null,
    "precio": "3950.00",
    "stock": 7,
    "estado": "pendiente",
    "fecha_aprobacion": null,
    "aprobado_por": null,
    "fecha_creacion": "2026-08-25T17:10:24.348Z",
    "fecha_actualizacion": "2026-08-25T17:10:24.348Z"
  }
}
```

(`estado` es `"activa"` si quien la crea es la tienda o un admin, y en ese
caso `fecha_aprobacion` viene puesta — pero `aprobado_por` sigue `null`:
la tienda/admin nace aprobada sin revisor. Un vendedor normal nace
`pendiente` con las dos en `null`. Recién creada, `aprobado_por` siempre
es `null`.)

Misma forma que cada elemento de `GET /vendedor/ofertas`. Deja al día en
Mongo los cinco campos calculados del producto y la variante afectados
(`precio_tienda`/`precio_desde`/`stock_tienda`/`stock_total`/`total_ofertas`,
ver `ProductosService.recalcularCamposCalculados`) — una oferta `pendiente`
no cambia ninguno de esos números, pero el recálculo se llama igual.

Probado en vivo el 28 de agosto de 2026 contra la base real (48
comprobaciones), con las cinco cuentas:
`tienda@mesh.com` y un admin crean `activa` con `fecha_aprobacion` puesta
(la del admin bajo `oferta.id_usuario` de la tienda, no del admin); los
demás vendedores crean `pendiente` con `fecha_aprobacion NULL`; el
`stock_inicial` de una oferta `pendiente` sí llega al kardex como
`reposicion` sin aprobarla; la oferta `pendiente` no sale en la ficha
pública, no cuenta en los campos calculados de Mongo (probado con una
`pendiente` de stock 7 que dejó `stock_total` en 0), y `agregar_linea` la
rechaza con 409; el vendedor la ve en su panel como `pendiente`. Sin
regresión: la tienda ofertando una variante que ya tiene sigue dando 409.

### 400

```json
{ "ok": false, "mensaje": "El id_producto es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El id_producto_variante es obligatorio y debe ser un numero entero mayor a 0", "payload": null }
{ "ok": false, "mensaje": "El precio es obligatorio y debe ser un numero mayor a 0, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "El stock_inicial es obligatorio y debe ser un numero entero mayor o igual a 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un producto con ese id", "payload": null }
{ "ok": false, "mensaje": "No existe una variante con ese id en este producto", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "Ya tenes una oferta sobre esta variante -- para cambiarla hay que editar la existente, no crear otra", "payload": null }
```

Del `UNIQUE (id_usuario, id_producto_mongo, id_producto_variante_mongo)` de
`oferta` (`005_ofertas.sql`): un vendedor tiene una sola oferta por
variante.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo crear la oferta", "payload": null }
```

---

## PATCH /vendedor/ofertas/:id

Edita una oferta propia: precio, estado, y/o un ajuste manual de stock.
Los tres campos son independientes — se puede mandar uno, dos o los tres
juntos — pero al menos uno tiene que venir. `:id` es `id_oferta`.

Cada campo registra su cambio en la tabla que le corresponde, nunca a
mano desde esta ruta:

- **`precio`** — un `UPDATE` sobre `oferta.precio`. El trigger
  `trg_oferta_registrar_precio` (`005_ofertas.sql`) escribe solo la fila
  nueva en `precio_historial`.
- **`estado`** — un `UPDATE` sobre `oferta.id_estado_oferta`. Depende de
  si la oferta **ya fue aprobada** alguna vez (`fecha_aprobacion` no NULL):
  - **Aprobada** (`activa`/`pausada`/`retirada` que pasó por revisión): sin
    restricción, el dueño la maneja como quiera, incluido volver de
    `retirada` a `activa`.
  - **Nunca aprobada** (`pendiente`, `rechazada`, o `retirada` sin haber
    pasado por revisión — `fecha_aprobacion` NULL): el vendedor **no** puede
    ponerla `activa` ni `pausada` por su cuenta (**409**); solo `retirada`.
    Y **cualquier otra edición** (un `precio` nuevo y/o un `ajuste_stock`)
    la deja —o la devuelve, si estaba `rechazada`— a **`pendiente`**, para
    que la tienda la revise otra vez. Es el mecanismo de re-envío tras un
    rechazo, sin recrear la oferta.
  El cliente **nunca** manda `pendiente` ni `rechazada` en el cuerpo (los
  pone el servidor): `estado` solo acepta `activa`/`pausada`/`retirada`, el
  resto es 400.
- **`ajuste_stock`** — un entero con signo, nunca `0`. Positivo llama a
  `reponer_stock(..., 'reposicion', ...)` (sube el stock); negativo llama
  con `'ajuste'` y la magnitud (resta). Son los mismos dos motivos que
  `reponer_stock()` ya admitía fuera del flujo del pedido — la misma
  corrección manual (sube o baja) que existía en el modelo viejo de
  inventario, ahora sobre la oferta.

**Solo el dueño de la oferta** — una ajena da el mismo 404 genérico que
una que no existe, mismo criterio de siempre. **Con sesión de admin,
"dueño" se resuelve como la cuenta de la tienda**: un admin puede editar
cualquier oferta de la tienda (incluidas las que la tienda creó ella
misma, no solo las que nacieron por esta vía), pero sigue sin poder tocar
la de un vendedor que no es la tienda — ver la nota al principio del
archivo.

```
PATCH /vendedor/ofertas/174
```

```json
{ "precio": "550.00", "ajuste_stock": -2, "estado": "activa" }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `precio` | No | Mismo formato que al crear: número > 0, hasta 2 decimales |
| `estado` | No | Uno de `activa`/`pausada`/`retirada` |
| `ajuste_stock` | No | Entero != 0. Positivo repone, negativo corrige a la baja |

Al menos uno de los tres tiene que venir.

### 200

```json
{
  "ok": true,
  "mensaje": "Oferta actualizada",
  "payload": {
    "id_oferta": "174",
    "id_producto": 6,
    "id_producto_variante": 11,
    "nombre_producto": "Audifonos Estudio 900",
    "nombre_variante": "Cable 3 m",
    "imagen": null,
    "precio": "550.00",
    "stock": 6,
    "estado": "activa",
    "fecha_aprobacion": "2026-08-28T22:11:03.512Z",
    "aprobado_por": {
      "id_usuario": "2",
      "usuario": "mesh_tienda",
      "nombre": "Mesh",
      "apellido": "Tienda"
    },
    "fecha_creacion": "2026-08-25T17:10:44.377Z",
    "fecha_actualizacion": "2026-08-25T17:18:46.987Z"
  }
}
```

Misma forma que `POST /vendedor/ofertas`. `payload.estado` trae el estado
real tras el cambio (puede ser `pendiente` si la oferta no estaba
aprobada). `fecha_aprobacion` / `aprobado_por` traen quién y cuándo la
aprobó la tienda, con el mismo significado que en `GET /vendedor/ofertas`;
editar la oferta no los toca (una oferta ya aprobada que se edita sigue
mostrando a su aprobador). Deja al día en Mongo los cinco campos
calculados del producto y la variante afectados.

Probado en vivo el 25 de agosto de 2026 (aprobadas) y el 28 de agosto de
2026 (flujo de aprobación) contra la base real:

- **Ofertas aprobadas** — precio (verificado que `precio_historial`
  registró la fila nueva), pausar y reactivar, `retirada → activa`, ajuste
  positivo y negativo verificado en el kardex fila por fila, cuerpo vacío
  → 400, oferta ajena → 404, `estado` inválido → 400.
- **Ofertas nunca aprobadas** (48 comprobaciones) — una `pendiente`
  editando `precio` o `ajuste_stock` sigue `pendiente` con
  `fecha_aprobacion` NULL; una `rechazada` editando `precio` **vuelve a
  `pendiente`**; una `retirada` sin haber sido aprobada, al editarse,
  también vuelve a `pendiente`; `estado: "activa"` o `"pausada"` sobre
  cualquiera de esas → **409**; `estado: "retirada"` sí se respeta;
  `estado: "pendiente"`/`"rechazada"` en el cuerpo → 400. Sin regresión en
  las aprobadas (mismo script).

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "Debes enviar al menos un campo para actualizar", "payload": null }
{ "ok": false, "mensaje": "El precio es obligatorio y debe ser un numero mayor a 0, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "El estado debe ser uno de: activa, pausada, retirada", "payload": null }
{ "ok": false, "mensaje": "El ajuste_stock debe ser un numero entero distinto de 0", "payload": null }
```

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

Mismo mensaje para una que no existe y para una que es de otro vendedor —
no hay nada que confirmar por esta vía.

### 409

```json
{ "ok": false, "mensaje": "El ajuste dejaria la oferta 174 en -993 unidades", "payload": null }
{ "ok": false, "mensaje": "Esta oferta todavia no fue aprobada por la tienda: no puedes activarla ni pausarla. Editala (precio o stock) y queda pendiente de revision otra vez.", "payload": null }
```

El primero es de `reponer_stock()` tal cual, cuando el ajuste negativo deja
el stock por debajo de 0. El segundo, cuando se intenta poner `activa` o
`pausada` una oferta que nunca fue aprobada.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo actualizar la oferta", "payload": null }
```

---

## PATCH /vendedor/ofertas/:id/revision

La tienda (o un admin) **aprueba** una oferta `pendiente` — pasa a `activa`
y ya circula (aparece en la ficha, cuenta para los campos calculados, se
puede comprar) — o la **rechaza** con un motivo — pasa a `rechazada` y se
guarda una fila en `rechazo_oferta`. `:id` es `id_oferta`.

Es la **única** vía para aprobar o rechazar; ni el vendedor ni un admin
pueden forzar ese estado por `PATCH /vendedor/ofertas/:id`.

**Solo `tienda@mesh.com` o un admin.** Un vendedor cualquiera —**incluido
el dueño de la oferta**— recibe el **mismo 404 genérico** que si la ruta no
existiera: uno no aprueba su propia oferta. La comprobación de permiso va
antes de validar el id o el cuerpo.

La oferta tiene que estar **`pendiente`**. Cualquier otro estado → 409. La
comprobación va dentro de una transacción con `SELECT ... FOR UPDATE` sobre
la fila de `oferta`: si dos revisiones caen a la vez sobre la misma oferta,
la segunda espera y al desbloquearse ve el estado ya cambiado y responde
409 — nunca queda aprobada y rechazada a la vez. En el rechazo, el cambio
de estado y el `INSERT` en `rechazo_oferta` van en esa misma transacción.

```
PATCH /vendedor/ofertas/174/revision
```

```json
{ "decision": "aprobar" }
```
```json
{ "decision": "rechazar", "razon": "La foto no corresponde al producto" }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `decision` | Sí | `"aprobar"` o `"rechazar"` |
| `razon` | Solo si `decision` es `"rechazar"` | Texto no vacío. Se guarda recortado (`trim`) en `rechazo_oferta.razon_rechazo` |

### 200

```json
{
  "ok": true,
  "mensaje": "Oferta aprobada",
  "payload": {
    "id_oferta": "174",
    "id_producto": 6,
    "id_producto_variante": 11,
    "nombre_producto": "Audifonos Estudio 900",
    "nombre_variante": "Cable 3 m",
    "imagen": null,
    "precio": "550.00",
    "stock": 6,
    "estado": "activa",
    "fecha_aprobacion": "2026-08-28T22:11:03.512Z",
    "aprobado_por": {
      "id_usuario": "2",
      "usuario": "mesh_tienda",
      "nombre": "Mesh",
      "apellido": "Tienda"
    },
    "fecha_creacion": "2026-08-25T17:10:44.377Z",
    "fecha_actualizacion": "2026-08-28T22:11:03.512Z"
  }
}
```

`mensaje` es `"Oferta aprobada"` o `"Oferta rechazada"` según la decisión;
`payload.estado` es `activa` o `rechazada`. Misma forma que
`PATCH /vendedor/ofertas/:id`. **Al aprobar** se ponen `fecha_aprobacion =
now()` y `id_usuario_aprobo` = **quien revisa** (la cuenta de la tienda, o
el `id_usuario` real del admin — no se sustituye por la tienda, igual que
en `PATCH /vendedor/productos/:id/revision`), y `payload.aprobado_por` lo
devuelve resuelto; después se recalculan los cinco campos del producto en
Mongo. **Al rechazar**, `fecha_aprobacion` y `aprobado_por` quedan `null`
y solo se inserta la fila en `rechazo_oferta`.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La decision debe ser una de: aprobar, rechazar", "payload": null }
{ "ok": false, "mensaje": "La razon del rechazo es obligatoria y no puede estar vacia", "payload": null }
```

### 401 / 403

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

Oferta inexistente, o quien llama no es la tienda ni un admin — el mismo
mensaje, para no revelar que la ruta existe.

### 409

```json
{ "ok": false, "mensaje": "Esta oferta no esta pendiente de revision (esta activa)", "payload": null }
```

La oferta ya no está `pendiente` (otra revisión se adelantó, o nunca lo
estuvo).

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo revisar la oferta", "payload": null }
```

Probado en vivo el 28 de agosto de 2026 (55 comprobaciones): aprobar y
rechazar (con `razon` recortada y una fila en `rechazo_oferta`); `activa`
tras aprobar aparece en la ficha y se puede comprar, y `precio_desde` baja
si la oferta es más barata que la de la tienda; una `rechazada` no aparece
y el vendedor la ve en `GET /vendedor/ofertas/:id/rechazos`; el dueño de la
oferta y un vendedor ajeno reciben 404, el comprador 403, sin sesión 401;
`decision` ausente/inválida y `razon` vacía → 400; revisar una oferta en
cualquier estado ≠ `pendiente` → 409, y el 409 no deja fila de rechazo
(rollback); el ciclo completo `pendiente → rechazada → (el vendedor
corrige) → pendiente → aprobada` funciona y conserva el historial de
rechazo; y **12 carreras concurrentes aprobar-vs-rechazar sobre la misma
oferta**: siempre exactamente un 200 y un 409, con estado final coherente.

Probado otra vez el 29 de agosto de 2026 (20 comprobaciones) al añadir
`aprobado_por` / `id_usuario_aprobo`: la tienda aprueba → `aprobado_por` =
`mesh_tienda` (id 2), `oferta.id_usuario_aprobo = 2`; un **admin** aprueba
→ `aprobado_por` = `admin_mesh` (id 5), no la tienda; rechazar deja
`aprobado_por` y `fecha_aprobacion` en `null` y `id_usuario_aprobo` NULL en
la base; la oferta aprobada aparece con su `aprobado_por` en
`GET /vendedor/ofertas`, en `GET /vendedor/ofertas/producto/:id`
(`mi_oferta`) y al editarla; las ofertas de la propia tienda salen con
`fecha_aprobacion` puesta y `aprobado_por` `null`; y las 350 ofertas de
vendedor de la semilla salen con `aprobado_por` = `mesh_tienda`. Teardown
sin drift en los campos calculados de Mongo.
