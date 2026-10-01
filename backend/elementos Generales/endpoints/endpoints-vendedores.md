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
| `GET /vendedor/ofertas/paginado` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin (idéntico a `GET /vendedor/ofertas`) |
| `GET /vendedor/ofertas/pendientes` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `GET /vendedor/ofertas/pendientes/paginado` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** (idéntico a `GET /vendedor/ofertas/pendientes`) |
| `GET /vendedor/ofertas/:id/rechazos` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** (cualquier oferta), o el vendedor dueño (solo la suya) |
| `GET /vendedor/ofertas/producto/:idProducto` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin |
| `POST /vendedor/ofertas` | vendedor **o** admin (2 o 3) | cualquier vendedor o admin |
| `PATCH /vendedor/ofertas/:id` | vendedor **o** admin (2 o 3) | cualquier vendedor, pero solo sobre **su propia** oferta; un admin, sobre cualquier oferta **de la tienda** |
| `PATCH /vendedor/ofertas/:id/revision` | vendedor **o** admin (2 o 3) | **`tienda@mesh.com` o admin** |
| `POST /vendedor/ofertas/:id/venta-limitada` | vendedor **o** admin (2 o 3) | solo sobre **su propia** oferta; un admin, sobre cualquier oferta **de la tienda** |
| `DELETE /vendedor/ofertas/:id/venta-limitada` | vendedor **o** admin (2 o 3) | igual que el `POST` |
| `POST /vendedor/reglas-descuento` | vendedor **o** admin (2 o 3) | solo sobre **su propia** oferta; un admin, sobre cualquier oferta **de la tienda** |
| `GET /vendedor/reglas-descuento` | vendedor **o** admin (2 o 3) | solo las **suyas** |
| `GET /vendedor/reglas-descuento/paginado` | vendedor **o** admin (2 o 3) | solo las **suyas** (idéntico a `GET /vendedor/reglas-descuento`) |
| `PATCH /vendedor/reglas-descuento/:id` | vendedor **o** admin (2 o 3) | solo sobre **su propia** regla; un admin, sobre cualquier regla **de la tienda** |
| `DELETE /vendedor/reglas-descuento/:id` | vendedor **o** admin (2 o 3) | solo sobre **su propia** regla; 409 si está `activa` |
| `POST /vendedor/reglas-descuento-periodos` | vendedor **o** admin (2 o 3) | solo sobre **su propia** oferta; un admin, sobre cualquier oferta **de la tienda** |
| `GET /vendedor/reglas-descuento-periodos` | vendedor **o** admin (2 o 3) | solo las **suyas** |
| `GET /vendedor/reglas-descuento-periodos/paginado` | vendedor **o** admin (2 o 3) | solo las **suyas** (idéntico a `GET /vendedor/reglas-descuento-periodos`) |
| `PATCH /vendedor/reglas-descuento-periodos/:id` | vendedor **o** admin (2 o 3) | solo sobre **su propia** regla; un admin, sobre cualquier regla **de la tienda** |
| `DELETE /vendedor/reglas-descuento-periodos/:id` | vendedor **o** admin (2 o 3) | solo sobre **su propia** regla; 409 si está `activa` |

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
transacción de Mongo (no está en modo replica set).

**Copia del catálogo en PostgreSQL (2026-10-01).** Al crear, el producto y
sus variantes se copian también a `producto_catalogo` y `variante_catalogo`
(nombre, nombre de la variante, estado, imagen de portada), en una
transacción de PostgreSQL abierta mientras se escribe en Mongo: primero el
`UPSERT` de la copia, luego Mongo, luego el `COMMIT`. Si Mongo falla se hace
`ROLLBACK` (todo o nada, 503); si falla el `COMMIT`, se deshace lo de Mongo.
Lo mismo aplica a `POST /vendedor/productos/propuestas` (aquí además va el
`INSERT` de la propuesta dentro de la misma transacción) y a
`PATCH /vendedor/productos/:id` cuando cambia `nombre` o `variantes` (si solo
cambia otra cosa, no se toca la copia). Ventana que queda, declarada: si el
proceso muere entre la escritura de Mongo y el `COMMIT`, o falla la propia
compensación, Mongo y la copia pueden quedar distintos. Aprobar, rechazar y
reenviar una propuesta no cambian nombre ni variantes y no tocan la copia.

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

Esta ruta trae **todas** las ofertas de una sola vez. Cuando el catálogo
crece (Entrega 3) la lista se vuelve pesada — un vendedor grande, y sobre
todo la tienda, puede tener miles de ofertas — así que existe la versión
paginada [`GET /vendedor/ofertas/paginado`](#get-vendedorofertaspaginado),
más abajo. Esta se queda para clientes que ya la consumen y para paneles
chicos.

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
      "stock_disponible": null,
      "estado": "pausada",
      "fecha_aprobacion": "2026-08-25T15:54:00.258Z",
      "aprobado_por": {
        "id_usuario": "2",
        "usuario": "mesh_tienda",
        "nombre": "Mesh",
        "apellido": "Tienda"
      },
      "es_inventario_limitado": false,
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
      "stock_disponible": 1,
      "estado": "activa",
      "fecha_aprobacion": null,
      "aprobado_por": null,
      "es_inventario_limitado": true,
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

`es_inventario_limitado` (`oferta.es_inventario_limitado`, migración `014`):
`true` si el vendedor abrió la **venta relámpago** de esta oferta —
`POST /vendedor/ofertas/:id/venta-limitada`, más abajo. En el panel es lo
que decide si el botón dice "Abrir venta relámpago" o "Cerrar la venta".
Cuando es `true`, el stock de esa oferta lo lleva un contador atómico en
Redis, no el flujo normal de PostgreSQL.

`stock_disponible` — las unidades que quedan **ahora mismo** de una oferta
en venta relámpago, leídas de ese contador de Redis (operación `estado` de
`redis/inventario_limitado.lua`). Solo se llena cuando
`es_inventario_limitado` es `true`; en el resto de ofertas es `null`.
También `null` si la venta ya cerró o si Redis no respondió — ahí el número
que hay que mostrar es `stock`, y el panel se pinta igual. `stock` en una
oferta en venta relámpago **queda congelado** desde que se abrió: no es el
número real mientras la venta esté abierta. Mismo campo, mismo significado,
en `GET /vendedor/ofertas/producto/:id` (dentro de `mi_oferta`) y en
`GET /productos/:id` (público, en `ofertas[]`).

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

## GET /vendedor/ofertas/paginado

La **versión paginada** de `GET /vendedor/ofertas`. Las mismas ofertas del
panel (cualquier estado) y **la misma forma de cada una** — nombre de
producto/variante, portada, `estado`, `stock`, `stock_disponible`,
`fecha_aprobacion`/`aprobado_por`, `es_inventario_limitado`, las dos fechas
—, pero por **número de página**, igual que
[`GET /vendedor/productos/paginado`](#get-vendedorproductospaginado) (no
por cursor). Mismo orden: `fecha_actualizacion` descendente, con
`id_oferta` descendente de desempate (ese desempate lo tiene también la
ruta sin paginar, así que recorrer las páginas da exactamente la misma
secuencia).

**Autorización e identidad idénticas a `GET /vendedor/ofertas`:** cualquier
vendedor o admin; con sesión de admin, "mis ofertas" son las de la cuenta
de la tienda (sustitución de identidad, ver la nota al principio del
archivo).

Segmento literal `paginado`: se resuelve antes que `:id/rechazos`.

### Query params

| Param | Default | Regla |
|---|---|---|
| `pagina` | `1` | entero ≥ 1. `0`, negativo o no numérico → 400 `La pagina debe ser un numero entero mayor a 0`. |
| `limite` | `20` | entero ≥ 1, **tope 100** (un valor mayor se capa a 100 en silencio). `0` o no numérico → 400 `El limite debe ser un numero entero mayor a 0`. |
| `estado` | — (todas) | Uno de los cinco `ESTADOS_OFERTA`: `pendiente`, `activa`, `pausada`, `retirada`, `rechazada` — filtra a **esa sola**, no un booleano. Ausente → sin filtrar por estado. Cualquier otro valor → 400 `El estado debe ser uno de: pendiente, activa, pausada, retirada, rechazada`. |

**Cambio del 2026-09-19:** antes el único filtro era `activo` (`true`/`false`,
un booleano que solo distinguía "activa" de "todo lo demás junto"). Se
reemplazó por `estado`, que deja pedir cualquiera de las cinco por
separado — a petición del usuario, para que se pudiera filtrar por
cualquier estado individual, no solo activa/no-activa.

`pagina`/`limite` son exactamente los mismos validadores (mismas reglas,
mismos mensajes) que `/productos/paginacion` y `/vendedor/productos/paginado`
— `validarLimite`/`validarPagina` en `helpers/validaciones-productos.ts`.
`estado` va como parámetro ligado en la consulta a Postgres (`$2::text IS
NULL OR estado_oferta_nombre = $2`), no interpolado.

```
GET /vendedor/ofertas/paginado?pagina=1&limite=20&estado=activa
```

### 200

```json
{
  "ok": true,
  "mensaje": "Ofertas obtenidas",
  "payload": {
    "ofertas": [
      {
        "id_oferta": "552",
        "id_producto": 6,
        "id_producto_variante": 4,
        "nombre_producto": "Monitor Halo 27",
        "nombre_variante": "27\" / 144 Hz",
        "imagen": null,
        "precio": "1899.00",
        "stock": 12,
        "stock_disponible": null,
        "estado": "activa",
        "fecha_aprobacion": "2026-09-05T00:57:18.095Z",
        "aprobado_por": null,
        "es_inventario_limitado": false,
        "fecha_creacion": "2026-09-05T00:57:18.095Z",
        "fecha_actualizacion": "2026-09-05T00:57:18.095Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_ofertas": 202,
    "total_paginas": 11
  }
}
```

`total_ofertas` cuenta **todas** las que cumplen el filtro (no solo la
página); `total_paginas` es `ceil(total_ofertas / limite)`, o `0` si no hay
ninguna. Pedir una `pagina` más allá del final devuelve `"ofertas": []`
con el `total_ofertas` real, no un error.

Por dentro: **dos consultas a Postgres** (una cuenta el total que cumple el
filtro, otra trae solo la página) en una misma transacción `REPEATABLE
READ READ ONLY` para que el conteo y la página salgan de la misma foto — el
equivalente Postgres del `$facet` que usa `GET /productos/paginacion` —, y
**una sola a Mongo con `$in`** por los productos distintos de esa página.
Nunca una consulta por oferta, y el trabajo por request queda acotado al
tamaño de página, sin importar cuántas ofertas tenga el vendedor.

### 400 / 401 / 403 / 503 / 500

Mismos cuerpos que `GET /vendedor/ofertas` (más el 400 del filtro `estado`
de arriba). Sin sesión → 401; comprador → 403.

Probado en vivo el 7 de septiembre de 2026 (54 comprobaciones sobre las dos
rutas paginadas): `total_ofertas` cuadra con `SELECT count(*)` de la base;
concatenar todas las páginas da exactamente la lista de `GET
/vendedor/ofertas`, sin duplicados ni faltantes y en el mismo orden;
página fuera de rango → `[]` con el total correcto; `limite` se capa
a 100; un admin ve el mismo conjunto que la tienda; un vendedor normal solo
las suyas; comprador 403, sin sesión 401.

**Pruebas del filtro `estado` -- hechas el 2026-09-19**, contra el
servidor y PostgreSQL reales, con sesión de `ventas_norte` (id 4, 80
ofertas `activa`, 8 `pausada`, ninguna en las otras tres):

| Caso | Resultado |
|---|---|
| `estado=activa` | `total_ofertas: 80` -- cuadra exacto con `SELECT count(*) ... WHERE estado_oferta_nombre = 'activa'` |
| `estado=pausada` | `total_ofertas: 8` -- cuadra exacto |
| `estado=retirada` / `pendiente` / `rechazada` | `total_ofertas: 0` -- correcto, no hay ninguna oferta en esos tres estados en TODA la base (confirmado con una consulta aparte a Postgres) |
| sin `estado` | `total_ofertas: 88` (80 + 8, la suma de las dos que sí existen) |
| `estado=lateral` | `400` "El estado debe ser uno de: pendiente, activa, pausada, retirada, rechazada" |

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

## GET /vendedor/ofertas/pendientes/paginado

La **versión paginada** de `GET /vendedor/ofertas/pendientes`. La misma
cola de revisión, el mismo orden (`fecha_creacion` ascendente, con
`id_oferta` ascendente de desempate) y **la misma forma de cada oferta**
(con el vendedor embebido, que quien revisa no conoce), pero por número de
página.

**Sin filtros:** la cola es toda de estado `pendiente` por definición, así
que el filtro `activo` de `GET /vendedor/ofertas/paginado` no aplica aquí.
Solo `pagina` y `limite`, con las mismas reglas y mensajes que las otras
rutas paginadas (tope de `limite` 100, default 20).

**Solo `tienda@mesh.com` o un admin**, igual que la ruta sin paginar: un
vendedor cualquiera recibe el **mismo 404 genérico** (`No existe una oferta
con ese id`) — no se le confirma que la ruta existe —, y no hay
sustitución de identidad (la cola es global, no "mis pendientes"). El
chequeo va **antes** de validar la paginación.

Segmento literal: se resuelve antes que `:id/rechazos`.

```
GET /vendedor/ofertas/pendientes/paginado?pagina=1&limite=20
```

### 200

```json
{
  "ok": true,
  "mensaje": "Ofertas pendientes obtenidas",
  "payload": {
    "ofertas": [
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
    ],
    "pagina": 1,
    "limite": 20,
    "total_ofertas": 1,
    "total_paginas": 1
  }
}
```

`total_ofertas` es el total de pendientes (no solo la página);
`total_paginas` es `ceil(total_ofertas / limite)`. Página más allá del
final → `"ofertas": []` con el `total_ofertas` real. Mismo motor que
`GET /vendedor/ofertas/paginado`: dos consultas a Postgres (total + página)
en una transacción `REPEATABLE READ READ ONLY` y una sola a Mongo con
`$in`.

### 401 / 403 / 404 / 503 / 500

Mismos cuerpos que `GET /vendedor/ofertas/pendientes`. Un vendedor que no
es la tienda ni admin → 404 `No existe una oferta con ese id`; comprador →
403; sin sesión → 401.

Probado en vivo el 7 de septiembre de 2026 (con datos de prueba sembrados y
retirados después): concatenar las páginas da la misma lista y el mismo
orden que `GET /vendedor/ofertas/pendientes`, sin solapamiento entre
páginas; `total_ofertas`/`total_paginas` cuadran; página fuera de rango →
`[]`; un vendedor normal 404, comprador 403, sin sesión 401.

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
          "stock_disponible": null,
          "estado": "pausada",
          "fecha_aprobacion": "2026-08-25T15:54:00.258Z",
          "aprobado_por": {
            "id_usuario": "2",
            "usuario": "mesh_tienda",
            "nombre": "Mesh",
            "apellido": "Tienda"
          },
          "es_inventario_limitado": false,
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

`mi_oferta` trae `fecha_aprobacion`, `aprobado_por`,
`es_inventario_limitado` y `stock_disponible` con el mismo significado que
en `GET /vendedor/ofertas` (quién y cuándo aprobó la tienda esa oferta; los
dos `null` mientras no circule, `aprobado_por` también `null` en las
ofertas de la propia tienda/admin; `es_inventario_limitado` = si su venta
relámpago está abierta; `stock_disponible` = unidades reales en Redis
cuando lo está, `null` si no).

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
    "stock_disponible": null,
    "estado": "pendiente",
    "fecha_aprobacion": null,
    "aprobado_por": null,
    "es_inventario_limitado": false,
    "fecha_creacion": "2026-08-25T17:10:24.348Z",
    "fecha_actualizacion": "2026-08-25T17:10:24.348Z"
  }
}
```

(Una oferta recién creada nunca está en venta relámpago:
`es_inventario_limitado` es siempre `false` aquí y `stock_disponible`
siempre `null` — la venta se abre aparte, con
`POST /vendedor/ofertas/:id/venta-limitada`.)

(`estado` es `"activa"` si quien la crea es la tienda o un admin, y en ese
caso `fecha_aprobacion` viene puesta — pero `aprobado_por` sigue `null`:
la tienda/admin nace aprobada sin revisor. Un vendedor normal nace
`pendiente` con las dos en `null`. Recién creada, `aprobado_por` siempre
es `null`.)

Misma forma que cada elemento de `GET /vendedor/ofertas`. Deja al día en
Mongo los cinco campos calculados del producto y la variante afectados
(`precio_tienda`/`precio_desde`/`stock_tienda`/`stock_total`/`total_ofertas`)
— desde el 2026-10-01 no en la petición sino por el worker de
`evento_producto` (cada 5 s; el trigger de `oferta` anota el producto). Una
oferta `pendiente` no cambia ninguno de esos números.

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
  nueva en `precio_historial`. **Funciona igual con un descuento activo**
  (`porcentaje_descuento` no `NULL`, ver `POST .../:id/descuento` más
  abajo): las dos cosas son independientes, el precio de lista cambia y el
  `precio_final` de la respuesta se recalcula sobre el precio nuevo, sin
  ninguna restricción ni aviso especial.
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
  inventario, ahora sobre la oferta. **Rechazado con 409 si la oferta está
  en una venta relámpago** (`es_inventario_limitado`): ahí el stock real lo
  lleva Redis (las unidades reservadas se descuentan ahí, no en
  `oferta.stock`), y tocar la columna de PostgreSQL por este camino
  desincroniza las dos — Redis seguiría prometiendo unidades que PostgreSQL
  ya no tiene, y el checkout revienta con un error que no explica nada. Se
  comprueba antes de tocar nada: si el cuerpo trae `ajuste_stock` junto con
  `precio` y/o `estado`, el 409 corta los tres, no se aplica ninguno.
  `precio` y `estado` siguen editables normalmente con la venta relámpago
  abierta — solo se restringe `ajuste_stock`.

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
    "porcentaje_descuento": null,
    "precio_final": "550.00",
    "stock": 6,
    "stock_disponible": null,
    "estado": "activa",
    "fecha_aprobacion": "2026-08-28T22:11:03.512Z",
    "aprobado_por": {
      "id_usuario": "2",
      "usuario": "mesh_tienda",
      "nombre": "Mesh",
      "apellido": "Tienda"
    },
    "es_inventario_limitado": false,
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
mostrando a su aprobador). Deja al día en Mongo los seis campos
calculados del producto y la variante afectados (agosto: `precio_tienda`,
`precio_desde`, `stock_tienda`, `stock_total`, `total_ofertas`;
2026-09-23: `hay_descuento`). `porcentaje_descuento` (2026-09-23, ver
`POST .../:id/descuento` más abajo) es `null` salvo que la oferta tenga un
descuento activo; `precio_final` es lo que de verdad se cobra/muestra.

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

**Probado en vivo el 4 de septiembre de 2026 (409 de `ajuste_stock` en
venta relámpago):** con la venta relámpago abierta sobre una oferta activa,
`ajuste_stock` solo → 409; `ajuste_stock` junto con `precio` → 409 y el
precio **no** se tocó (verificado en la fila); `precio` solo → 200 (sigue
editable); `estado` solo → 200 (sigue editable); cerrada la venta relámpago
(`DELETE .../venta-limitada`), el mismo `ajuste_stock` que antes daba 409 →
200 normal.

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
{ "ok": false, "mensaje": "La oferta esta en una venta relampago: cierra la venta relampago antes de ajustar su existencia", "payload": null }
```

El primero es de `reponer_stock()` tal cual, cuando el ajuste negativo deja
el stock por debajo de 0. El segundo, cuando se intenta poner `activa` o
`pausada` una oferta que nunca fue aprobada. El tercero, cuando el cuerpo
trae `ajuste_stock` y la oferta está en venta relámpago.

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
    "stock_disponible": null,
    "estado": "activa",
    "fecha_aprobacion": "2026-08-28T22:11:03.512Z",
    "aprobado_por": {
      "id_usuario": "2",
      "usuario": "mesh_tienda",
      "nombre": "Mesh",
      "apellido": "Tienda"
    },
    "es_inventario_limitado": false,
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

---

## POST /vendedor/ofertas/:id/venta-limitada

**Abre la venta relámpago** (inventario limitado en Redis) de una oferta
propia. Es el paso 2 del inventario limitado — ver
`plan pendiente/inventario-limitado.md` y `endpoints-carrito.md`. `:id` es
`id_oferta`.

Vive en su propio controlador/servicio (`VentasLimitadasController` /
`VentasLimitadasService`), aparte del CRUD de ofertas: el mecanismo no
toca el flujo de `oferta` de PostgreSQL, solo enciende la columna
`es_inventario_limitado` y siembra el contador de Redis. Comparte el
prefijo `/vendedor/ofertas`, el guard y los roles (`vendedor` o `admin`).

**Autorización:** la oferta tiene que ser **tuya**. Una oferta ajena o
inexistente da el **404 genérico** de siempre (`"No existe una oferta con
ese id"`) — no se confirma que exista. Un **admin** actúa como la cuenta
de la tienda (igual que el resto de `/vendedor/ofertas`): abre ventas
sobre ofertas de `tienda@mesh.com`.

Qué hace por dentro: siembra el contador de Redis
(`mesh:oferta:<id_oferta>`) con el `stock` que la oferta tiene en ese
instante en PostgreSQL, y marca `oferta.es_inventario_limitado = true`. A
partir de ahí, agregar esa oferta al carrito **reserva de verdad**
unidades (ver `endpoints-carrito.md`).

### Cuerpo

```json
{ "duracion_segundos": 3600 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `duracion_segundos` | No (por defecto `0`) | Entero entre `0` y `604800` (7 días). Es **cuándo cierra la venta entera**: pasado ese tiempo las claves de Redis de la oferta desaparecen solas y la venta vuelve al flujo normal. `0` = sin vencimiento (hay que cerrarla a mano con el `DELETE`). No confundir con el plazo de una reserva individual del comprador (15 min, fijo). |

El cuerpo tiene que ser JSON válido: mandar `{}` para usar el valor por
defecto. Un `POST` con `Content-Type: application/json` y cuerpo
**totalmente vacío** da `400` de Fastify (igual que el resto de los `POST`
del backend).

### 201

```json
{
  "ok": true,
  "mensaje": "Venta relampago abierta",
  "payload": { "id_oferta": "3", "stock_sembrado": 24 }
}
```

`stock_sembrado` es cuántas unidades quedaron en el contador de Redis — el
`stock` de la oferta en PostgreSQL en el instante de abrir.

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "La duracion_segundos debe ser un entero entre 0 y 604800 (7 dias); 0 = sin vencimiento", "payload": null }
```

### 401 / 403

Sin sesión → `401`. Con rol distinto de `vendedor`/`admin` (un comprador) →
`403`.

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

La oferta no existe **o no es tuya** (mismo mensaje para las dos cosas).

### 409

```json
{ "ok": false, "mensaje": "La oferta 3 no esta activa (esta pausada), no se puede abrir una venta limitada", "payload": null }
{ "ok": false, "mensaje": "La oferta 3 ya esta en modo venta limitada -- sembrar de nuevo borraria sus reservas vivas", "payload": null }
{ "ok": false, "mensaje": "La oferta 3 necesita un descuento activo antes de abrir una venta relampago: aplicalo primero con POST /vendedor/ofertas/3/descuento", "payload": null }
{ "ok": false, "mensaje": "Esta oferta ya tiene una regla de descuento automatico activa: los mecanismos de descuento/venta relampago son mutuamente excluyentes, hay que desactivar ese primero", "payload": null }
```

El último **(agregado 2026-09-24)**: si la oferta tiene una regla de
descuento automático o por período activa, no se puede abrir una venta
relámpago manual sobre ella. Ver "Exclusión mutua entre los cuatro
mecanismos de descuento/venta relámpago" más abajo. El descuento manual
**no** entra en esta exclusión contra la venta relámpago manual -- al
revés, es un requisito (la línea de arriba).

Tres casos que el panel distingue: la oferta no está `activa` (está
`pausada`/`retirada`/`pendiente`/`rechazada`), **ya** está en venta
relámpago (esto impide que un segundo clic vuelva a sembrar y borre las
reservas que ya tomaron los compradores), o **todavía no tiene un
descuento activo** (2026-09-23) — una venta relámpago sin descuento no
tiene sentido de negocio, así que `VentasLimitadasService.abrir()` exige
`oferta.porcentaje_descuento` no `NULL` antes de sembrar Redis (chequeo en
`VentasLimitadasService`, no en Redis ni en `activar()`).

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con Redis", "payload": null }
{ "ok": false, "mensaje": "No se pudo abrir la venta relampago", "payload": null }
```

Si Redis falla **después** de haber marcado la columna en PostgreSQL, el
servicio deshace la marca (`es_inventario_limitado = false`) para no dejar
la oferta marcada como limitada sin nada sembrado en Redis.

---

## DELETE /vendedor/ofertas/:id/venta-limitada

**Cierra la venta relámpago** de una oferta propia: apaga
`oferta.es_inventario_limitado` y borra las dos claves de Redis de esa
oferta (`mesh:oferta:<id>` y `mesh:oferta:<id>:reservas`). `:id` es
`id_oferta`. Misma autorización que el `POST` (tuya, o de la tienda si
sos admin; 404 genérico si no).

**OJO:** cerrar **no confirma** las reservas que hubiera en curso — lo que
de verdad quedó vendido solo se sabe con `confirmar` por ticket, y eso es
el flujo del checkout. Por ahora cerrar una venta con reservas vivas las
descarta (sus unidades vuelven al `stock` de PostgreSQL vía el `DEL`, no
se pierden, pero el comprador que había apartado se queda sin su
reserva). Sirve para cerrar una venta tranquila o deshacer una prueba, no
para cortar en seco una que está caliente.

### 200

```json
{ "ok": true, "mensaje": "Venta relampago cerrada", "payload": null }
```

### 400 / 401 / 403

`400` id inválido; `401` sin sesión; `403` rol comprador.

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

La oferta no existe o no es tuya.

### 409

```json
{ "ok": false, "mensaje": "La oferta 3 no esta en una venta relampago", "payload": null }
```

La oferta no estaba en modo venta relámpago (`es_inventario_limitado` era
`false`). El panel no debería ofrecer el botón "Cerrar" en ese caso, pero
se comprueba igual.

### 503 / 500

Igual que el `POST` (`No se pudo cerrar la venta relampago` como mensaje
por defecto).

---

## POST /vendedor/ofertas/:id/descuento

**Aplica un % de descuento** a una oferta propia (2026-09-23, ver
`plan pendiente/descuentos-oferta.md`). `:id` es `id_oferta`. A diferencia
de la venta relámpago, esto **no** tiene controlador/servicio propio: vive
en `OfertasVendedorController`/`OfertasVendedorService`, junto al resto
del CRUD de la oferta — es Postgres puro, sin ningún cliente nuevo de por
medio.

**`oferta.precio` NUNCA se toca por esto.** Sigue siendo el precio de
lista; el % vigente vive aparte en `oferta.porcentaje_descuento`, y el
precio real a cobrar/mostrar (`precio_final`, en las respuestas de
`GET`/`PATCH` de ofertas y en la ficha pública) se calcula en cada
consulta, nunca se guarda — decisión explícita del equipo, ver el plan
para el porqué y la lista completa de consultas que aplican la fórmula.

**Autorización:** la oferta tiene que ser **tuya** — mismo 404 genérico
que el resto de `/vendedor/ofertas/:id/*`. Un admin actúa como la tienda.

### Cuerpo

```json
{ "porcentaje_descuento": 20, "duracion_segundos": 3600 }
```

| Campo | Obligatorio | Regla |
| --- | --- | --- |
| `porcentaje_descuento` | Sí | Número entre **1 y 90**, hasta 2 decimales. `0` no es un descuento (para eso está el `DELETE`); `90` es un límite de sanidad de negocio (más estricto que el `CHECK` de la base, que solo exige `< 100`) — un descuento mayor sin más contexto huele a error de tipeo. |
| `duracion_segundos` | No (por defecto `0`) | **(agregado 2026-09-24)** Puramente interno -- no aparece en ninguna respuesta, el cliente no tiene por qué saber que existe. Entero entre `0` y `604800` (7 días), mismo campo/mismo mensaje que `POST .../venta-limitada` (`validarDuracionVencimiento()`, compartido). `0` = el descuento no vence solo (comportamiento de siempre). Si es mayor a `0`, el descuento se quita solo pasado ese tiempo -- mismo mecanismo de TTL de Redis + `VentasLimitadasService.revisarVencidas()` que ya usaba la venta relámpago, ver la sección dedicada más abajo. |

### 201

```json
{
  "ok": true,
  "mensaje": "Descuento aplicado",
  "payload": {
    "id_oferta": "3",
    "precio": "5840.00",
    "porcentaje_descuento": "25.00",
    "precio_final": "4380.00",
    "...": "el resto de los campos de OfertaPropia, sin cambios"
  }
}
```

`precio` no cambió; `precio_final` es lo que de verdad se cobra/muestra
(`ROUND(precio * (1 - porcentaje_descuento/100), 2)`).

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
{ "ok": false, "mensaje": "El porcentaje_descuento debe ser un numero entre 1 y 90, con hasta 2 decimales", "payload": null }
{ "ok": false, "mensaje": "La duracion_segundos debe ser un entero entre 0 y 604800 (7 dias); 0 = sin vencimiento", "payload": null }
```

`0`, `100`, `91`, negativo, con más de 2 decimales, o texto en vez de
número — los seis casos de `porcentaje_descuento` dan este mismo 400;
`duracion_segundos` negativo, mayor a 7 días, o no entero, igual.

### 401 / 403

Sin sesión → `401`. Rol comprador → `403`.

### 404

```json
{ "ok": false, "mensaje": "No existe una oferta con ese id", "payload": null }
```

La oferta no existe o no es tuya.

### 409

```json
{ "ok": false, "mensaje": "Esta oferta ya tiene un descuento activo", "payload": null }
```

Hay que quitar el descuento actual antes de poner otro — no se
reemplaza/apila silenciosamente. Comprobado dentro de una transacción con
`SELECT ... FOR UPDATE`, mismo patrón que `PATCH .../:id/revision`: dos
peticiones concurrentes sobre la misma oferta nunca dejan un estado
inconsistente.

**(agregado 2026-09-24)** También 409 si la oferta tiene una regla de
descuento automático o por período activa:

```json
{ "ok": false, "mensaje": "Esta oferta ya tiene una regla de descuento automatico activa: los mecanismos de descuento/venta relampago son mutuamente excluyentes, hay que desactivar ese primero", "payload": null }
```

Ver la sección "Exclusión mutua entre los cuatro mecanismos de
descuento/venta relámpago" más abajo.

### 503 / 500

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo aplicar el descuento", "payload": null }
```

---

## DELETE /vendedor/ofertas/:id/descuento

**Quita el descuento activo** de una oferta propia: limpia
`oferta.porcentaje_descuento` a `NULL`. `oferta.precio` no se toca — nunca
lo estuvo. Mismo patrón de transacción + `FOR UPDATE` + autorización que
el `POST`.

**Rechaza con 409 si la oferta está en una venta relámpago** (2026-09-23,
`es_inventario_limitado`): como abrir una venta relámpago ya exige un
descuento activo (ver `POST .../venta-limitada` más arriba), quitarlo por
separado dejaría la venta relámpago sin el descuento que la justifica. Hay
que cerrar la venta relámpago primero
(`DELETE .../venta-limitada`) — recién ahí se puede quitar el descuento.

**(agregado 2026-09-24)** Si el `POST` se hizo con `duracion_segundos`,
este `DELETE` también borra la clave de Redis del TTL -- no se queda
esperando a que la revisión periódica limpie una clave que ya no tiene
sentido.

### 200

```json
{
  "ok": true,
  "mensaje": "Descuento retirado",
  "payload": {
    "id_oferta": "3",
    "precio": "5840.00",
    "porcentaje_descuento": null,
    "precio_final": "5840.00",
    "...": "..."
  }
}
```

`precio` vuelve a ser el que ya era — **exacto, sin arrastre de
redondeo**, porque nunca cambió. `precio_final` pasa a coincidir con
`precio`.

### 400 / 401 / 403

Igual que el `POST`.

### 404

La oferta no existe o no es tuya.

### 409

```json
{ "ok": false, "mensaje": "Esta oferta no tiene ningun descuento activo", "payload": null }
{ "ok": false, "mensaje": "La oferta 3 esta en una venta relampago: cierra la venta relampago (DELETE /vendedor/ofertas/3/venta-limitada) antes de quitar el descuento", "payload": null }
```

El primer chequeo (sin descuento) va antes que el de venta relámpago: si
la oferta no tiene descuento, ese es el mensaje que sale, aunque además
estuviera en venta relámpago (no debería poder pasar, ya que abrirla exige
el descuento).

### 503 / 500

Igual que el `POST` (`No se pudo quitar el descuento` como mensaje por
defecto).

---

## Pruebas — descuentos en ofertas (2026-09-23)

Contra el servidor y las bases reales (`ventas_norte`, oferta 3 = Laptop
Ambar Campus 14, Q5840.00).

| Caso | Resultado |
|---|---|
| Aplicar 25% | 201; `precio` sigue en 5840.00, `porcentaje_descuento: "25.00"`, `precio_final: "4380.00"` |
| Aplicar un segundo descuento sobre la misma oferta | 409 |
| `PATCH /vendedor/ofertas/:id` con `precio` mientras el descuento está activo | 200, funciona sin restricción; `precio_final` se recalcula sobre el precio nuevo (probado: Q6000 + 25% → `precio_final: "4500.00"`) |
| `90` exacto (límite inclusivo) | 201 |
| `0` / `100` / `91` / `-5` / `15.505` (3 decimales) / `"20"` (texto) | 400 en los seis casos |
| Quitar el descuento | 200; `precio` vuelve exacto, `porcentaje_descuento: null` |
| Quitar de nuevo (ya no tiene) | 409 |
| Aplicar/quitar sobre oferta ajena | 404 genérico |
| Oferta inexistente / sin sesión | 404 / 401 |
| `GET /productos/:id` (ficha), con el descuento activo | la oferta aparece a `precio_final`, **ordenada por precio final** (con el descuento se adelantó a una oferta con precio de lista más barato) |
| `GET /productos`, `GET /productos/:id` | `hay_descuento: true` en la variante y la raíz con el descuento activo; `false` en las demás |
| Carrito → checkout con la oferta descontada | la foto de Redis guarda el precio final; `POST /carrito/comprar` cobra ese monto — verificado contra `precio_historial` (`precio` de lista + `porcentaje_descuento` guardados por separado) y `pago.monto` |
| `GET /admin/reportes/ventas` | el monto por estado aplica la fórmula (verificado contra un cálculo manual sin la fórmula: discrepancia exacta al descuento otorgado) |
| `npx tsc --noEmit` y `eslint` sobre los 14 archivos tocados | limpios |

Detalle completo, con la lista de archivos y decisiones de diseño, en
`plan pendiente/descuentos-oferta.md`.

---

## Venta relámpago exige descuento activo (agregado 2026-09-23)

Regla de negocio nueva, sobre los dos endpoints de arriba: una venta
relámpago **siempre** tiene que traer un descuento aplicado, y mientras
esté abierta **no se puede quitar el descuento por separado** — hay que
cerrar la venta relámpago primero. La idea: el descuento es lo que
justifica el mecanismo, así que abrir sin descuento o quitarlo a mitad de
la venta dejaría la oferta en un estado que no tiene sentido de negocio.

- **`POST /vendedor/ofertas/:id/venta-limitada`** (`VentasLimitadasService.abrir`)
  ahora exige `oferta.porcentaje_descuento` no `NULL` antes de sembrar
  Redis — 409 si falta (ver el nuevo caso en la sección de arriba).
- **`DELETE /vendedor/ofertas/:id/descuento`** (`OfertasVendedorService.quitarDescuento`)
  ahora rechaza con 409 si `oferta.es_inventario_limitado` es `true` (ver
  el nuevo caso en la sección de arriba). `POST .../descuento` (aplicar un
  descuento nuevo) no cambia.

### Probado en vivo el 23 de septiembre de 2026

Contra el servidor y las bases reales (`ventas_norte`, oferta 549 = Eau de
parfum Bruma, Q1081.00, sin descuento ni venta relámpago al empezar).

| Caso | Resultado |
|---|---|
| Abrir venta relámpago sin descuento | 409, `"...necesita un descuento activo antes de abrir una venta relampago..."` |
| Aplicar 15% de descuento | 201, `precio_final: "918.85"` |
| Abrir venta relámpago con el descuento ya aplicado | 201, `stock_sembrado: 24` |
| Quitar el descuento con la venta relámpago abierta | 409, `"...esta en una venta relampago: cierra la venta relampago..."` |
| Cerrar la venta relámpago | 200 |
| Quitar el descuento ya cerrada la venta relámpago | 200, `porcentaje_descuento: null` |

La oferta quedó exactamente como al empezar (sin descuento, sin venta
relámpago). `npx tsc --noEmit` sobre el backend completo, limpio.

---

## El worker que apaga solas las ventas relámpago vencidas (agregado 2026-09-04, corregido 2026-09-24)

No es una ruta HTTP: es un `@Interval` (`VentasLimitadasService.revisarVencidas()`,
cada 60 s, mismo mecanismo que el worker del outbox del grafo). **Se movió
de `InventarioLimitadoService` a `VentasLimitadasService` el 2026-09-24**
(ver el bug corregido abajo) porque la versión corregida necesita
`ProductosService` para recalcular Mongo, y `ProductosService` ya inyecta
`InventarioLimitadoService` (para `estado()` en la ficha) — dejarlo ahí
habría sido una dependencia circular.

**El problema que corrige, versión original (2026-09-04).** Cuando
`POST .../venta-limitada` abre la venta con `duracion_segundos`, Redis le
pone `EXPIRE` a `mesh:oferta:<id>` (y `redis/inventario_limitado.lua`
sincroniza el de su ZSET de reservas con el mismo TTL). Al vencer, las dos
claves **desaparecen solas** en Redis — pero `oferta.es_inventario_limitado`
en PostgreSQL solo se apagaba antes con `DELETE .../venta-limitada` manual.

**Bug encontrado el 2026-09-24, al diseñar los workers de las reglas de
descuento automático/período:** la corrección de 2026-09-04 solo apagaba
`es_inventario_limitado` — dejaba `oferta.porcentaje_descuento` pegado
**para siempre**, porque nada más lo tocaba (`revertir()` tampoco lo toca;
`quitarDescuento()` de `OfertasVendedorService` ni se puede llamar
mientras `es_inventario_limitado` sigue en `true`, es un 409). Una venta
relámpago que vencía sola por TTL dejaba el descuento activo de manera
permanente, sin que ninguna pantalla lo reflejara como "en venta
relámpago" ni tampoco como "sin descuento" — un estado que antes no tenía
ninguna ruta de salida salvo tocar la base a mano. Corregido para que la
misma revisión apague **las dos columnas en la misma sentencia** y
recalcule los campos calculados de Mongo (`hay_descuento`/`precio_tienda`/
`precio_desde`) para las ofertas que tocó, igual que
`OfertasVendedorService.quitarDescuento()`.

**Qué hace (versión corregida).** Cada minuto: `SELECT id_oferta,
id_producto_mongo FROM oferta WHERE es_inventario_limitado = true`, y para
cada una un `EXISTS` en Redis (reusa
`InventarioLimitadoService.existeVentaLimitada()`). Si la clave ya no
existe: `UPDATE oferta SET es_inventario_limitado = false,
porcentaje_descuento = NULL`, `RegistroOfertasRedisService.sincronizar()`
(saca la oferta de las dos llaves de `mesh:ofertas:*`, ver la sección de
abajo) y, al final de la corrida, `ProductosService.recalcularCamposCalculados()`
en lote sobre todas las ofertas que tocó. Nunca toca Redis directamente —si
venció sola, las dos claves ya se fueron solas; si la cerraron con
`DELETE`, también. Nunca relanza: un fallo de Postgres, Redis o Mongo en
una corrida se loguea como warning y se reintenta en la próxima.

**No afecta** una venta sin vencimiento (`duracion_segundos: 0` o
ausente): su clave nunca expira, así que el `EXISTS` sigue en `1` para
siempre y el worker no la toca.

**Atribución (corregida 2026-09-25):** el `UPDATE` de este worker dispara
el trigger `oferta_registrar_precio()`, que guarda una fila nueva en
`precio_historial`. Antes caía siempre en `id_usuario_modifico` = el dueño
de la oferta (el fallback de `current_setting('mesh.id_usuario')`, que el
backend nunca seteaba) -- como si el vendedor hubiera quitado el descuento
él mismo. Ahora `apagarVentaLimitadaVencida()`/`quitarDescuentoVencido()`
ponen `mesh.id_usuario` en el id de **la tienda** (`set_config(...,
true)`, dentro de una transacción) antes del `UPDATE`, así que la fila
queda atribuida a la tienda -- no al vendedor, no a un id de sistema que no
existe. Detalle completo y pruebas en
`cambio_propuestas/2026-09-25_0745-atribucion-limpiezas-automaticas.md`.

### Probado en vivo el 4 de septiembre de 2026 (versión original)

| Caso | Resultado |
|---|---|
| Venta con `duracion_segundos: 5` | a los 5 s las dos claves de Redis desaparecen solas; `es_inventario_limitado` queda en `true` hasta el siguiente tick del worker (≤ 60 s) y ahí pasa a `false` — confirmado en el log (`"1 oferta(s) apagada(s) (vencieron solas)"`) y en la fila de PostgreSQL |
| Venta con `duracion_segundos: 0` (sin vencer) | dos ticks completos del worker (2 min) sin tocarla: `es_inventario_limitado` se queda en `true`, sin log |
| `DELETE .../venta-limitada` manual, antes de que el worker corriera | sigue funcionando igual que siempre — el worker no interfiere |

### Probado en vivo el 24 de septiembre de 2026 (el bug del descuento pegado)

Contra el servidor y las bases reales (`ventas_norte`, oferta 3).

| Caso | Resultado |
|---|---|
| `POST .../3/descuento` (20%) → `POST .../3/venta-limitada` con `duracion_segundos: 6` | 201 los dos; Postgres: `porcentaje_descuento: 20.00`, `es_inventario_limitado: true` |
| A los 6 s, las dos claves de Redis (`mesh:oferta:3`, `mesh:oferta:3:reservas`) | confirmadas ausentes (`EXISTS` → `0`) |
| Al siguiente tick del worker (≤ 60 s) | log `"1 oferta(s) apagada(s) y su descuento quitado (vencieron solas)"`; Postgres: `porcentaje_descuento: NULL`, `es_inventario_limitado: false`, `precio`/`stock` sin tocar (`5840.00`/`24`) |
| `precio_historial` | fila nueva con `porcentaje_descuento: NULL` (el trigger disparó igual que con un `quitarDescuento()` manual) |
| Mongo (`productos._id: 1`) | `hay_descuento` vuelve a `false`; `precio_tienda`/`precio_desde`/`stock_tienda` sin cambios (otras ofertas de ese producto siguen igual) |
| `npx tsc --noEmit` y `eslint` sobre los dos archivos tocados | limpios |

Sin migración: es lectura de columnas que ya existían
(`014_inventario_limitado.sql`, `descuentos-oferta.sql`). `stock` de
PostgreSQL no se toca en ningún caso.
`cambio_propuestas/2026-09-04_0900-apagar-venta-relampago-vencida.md` (original) y
`cambio_propuestas/2026-09-24_2200-bug-ttl-descuento-pegado.md` (esta corrección).

---

## TTL opcional para el descuento manual puro (agregado 2026-09-24)

Pedido explícito del usuario: que el descuento manual (`POST .../descuento`,
sin venta relámpago) pueda vencer solo, copiando **tal cual** el mismo
mecanismo que ya tenía `POST .../venta-limitada`. Es **puramente interno**
-- no aparece en ninguna respuesta ni le importa al cliente, solo al
backend.

**`duracion_segundos` opcional en el cuerpo** (`0` o ausente = de siempre,
no vence solo). La validación (`validarDuracionVencimiento()`, en
`helpers/validaciones-oferta.ts`) se sacó del método privado que tenía
`VentasLimitadasService` para que los dos endpoints compartan exactamente
el mismo rango y el mismo mensaje -- no una copia con reglas propias.

**Cómo funciona, mismo patrón que la venta relámpago:**
`OfertasVendedorService.aplicarDescuento()` siembra
`mesh:oferta:<id>:descuento` en Redis -- con `EXPIRE duracion_segundos` si
es mayor a `0`, sin él si es `0` (igual que
`InventarioLimitadoService.activar()` siembra su propia clave: SIEMPRE se
crea, con o sin vencimiento, porque la existencia de la clave es la única
señal que usa el worker para decidir "sigue vivo"). `quitarDescuento()`
borra esa clave si el vendedor lo quita a mano antes de tiempo.

**El worker.** `VentasLimitadasService.revisarVencidas()` ahora corre DOS
revisiones cada minuto: la de siempre (venta relámpago) y una nueva,
`revisarDescuentosVencidos()`, que mira las ofertas con
`porcentaje_descuento` puesto que NO están en venta relámpago (esas ya las
cubre la otra revisión) y, si la clave de Redis ya no existe, limpia el
descuento y recalcula Mongo -- mismo mecanismo, misma forma, un método
nuevo separado del de venta relámpago (no se fusionaron porque las
consultas de Postgres y las columnas que tocan son distintas).

**Al vencer una venta relámpago, también se borra la clave del
descuento** (si tenía una) aunque a esa clave todavía le faltara tiempo --
si no, un descuento con `duracion_segundos` largo que quedó debajo de una
venta relámpago que venció primero dejaría esa clave viva en Redis para
siempre, sin que nada la revise nunca más (la oferta ya no entra en la
consulta de `revisarDescuentosVencidos()` porque `porcentaje_descuento` ya
quedó `NULL`).

**Limitación conocida y aceptada:** un descuento puesto por fuera de
`aplicarDescuento()` (a mano, directo en Postgres) nunca tiene esta clave
sembrada, así que `revisarDescuentosVencidos()` lo trataría como "vencido"
en el siguiente tick y lo quitaría. Hoy no hay ningún descuento activo así
en la base, así que no aplica en la práctica -- queda anotado por si algún
día se siembra uno directo por SQL.

### Probado en vivo el 24 de septiembre de 2026

Contra el servidor y las bases reales (`ventas_norte`, ofertas 3/18/27).

| Caso | Resultado |
|---|---|
| `POST .../3/descuento` con `duracion_segundos: 6` | 201; `TTL mesh:oferta:3:descuento` → `6` |
| `POST .../18/descuento` sin `duracion_segundos` | 201; la clave existe pero `TTL` → `-1` (sin vencimiento) |
| Al siguiente tick del worker (≤ 60 s tras vencer los 6 s) | log `"1 descuento(s) quitado(s) (vencieron solos)"`; oferta 3 con `porcentaje_descuento: NULL`, clave de Redis ausente |
| Oferta 18 (sin duración), mismo tick | sin tocar -- `porcentaje_descuento: 10.00` sigue activo, la clave sigue existiendo |
| `DELETE .../18/descuento` | 200; la clave de Redis se borra en el acto (`EXISTS` → `0`) |
| Aplicar descuento con `duracion_segundos: 300` en 27, abrir venta relámpago con `duracion_segundos: 6` encima | 201 los dos; `TTL` de la clave del descuento → `300` |
| Al vencer la venta relámpago (6 s + el tick del worker) | `porcentaje_descuento: NULL`, `es_inventario_limitado: false`, Y la clave del descuento (que todavía tenía ~294 s de sobra) también quedó borrada |
| Mongo, en los tres casos | `hay_descuento` recalculado correctamente para cada producto tocado |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: ninguno hizo falta -- las tres ofertas volvieron solas a su
estado original (el mecanismo que se estaba probando es justamente que se
limpien solas).
`cambio_propuestas/2026-09-24_2345-ttl-descuento-manual.md`.

---

## El registro de ofertas con descuento/venta relámpago en Redis (agregado 2026-09-23)

No son rutas HTTP propias de este archivo (la lectura pública vive en
`GET /productos/ofertas/descuento` y `GET /productos/ofertas/venta-relampago`,
documentadas en `endpoints-productos.md`) — esto es la parte que las
mantiene al día: `RegistroOfertasRedisService` y `RegistroOfertasSyncService`
(`src/services/vendedores/registro-ofertas-redis.service.ts` y
`registro-ofertas-sync.service.ts`).

**Dos `HASH` en Redis, mutuamente excluyentes**, mismo criterio de "tarjeta
representativa, no la fila cruda" que `mesh:productos:mas_vendidos:detalle`:

```
mesh:ofertas:descuento         HASH { id_oferta: <detalle en JSON> }
mesh:ofertas:venta_relampago   HASH { id_oferta: <detalle en JSON> }
```

Un campo de hash (no un `SET` de ids sueltos) porque hacía falta guardar
más que el id — nombre, imagen, precio, vendedor, stock — y un `HASH`
también garantiza "nunca duplicados" (`HSET` sobre un campo existente lo
reemplaza, nunca lo repite). Una oferta vive en una llave o en la otra,
nunca en las dos: una oferta en venta relámpago siempre tiene descuento
(ver la sección de arriba), pero se cuenta ahí, no en la de "solo
descuento".

**`RegistroOfertasRedisService.sincronizar(idOferta)`** decide, leyendo el
estado ACTUAL de la oferta en PostgreSQL (nunca lo que el llamador cree que
cambió): sin descuento → la saca de las dos llaves; con descuento y sin
venta relámpago → `mesh:ofertas:descuento`; en venta relámpago →
`mesh:ofertas:venta_relampago` (y la saca de la otra). Nunca lanza — un
fallo de Postgres, Mongo o Redis se loguea como warning, para no tumbar la
operación de negocio que ya se comiteó; el worker de reconciliación lo
corrige después.

**Quién la llama, reactivo, al instante:**
- `OfertasVendedorService.aplicarDescuento` / `quitarDescuento`.
- `VentasLimitadasService.abrir` / `cerrar`.
- `VentasLimitadasService.revisarVencidas()` (antes vivía en
  `InventarioLimitadoService`, ver la sección de arriba) — cuando una venta
  relámpago vence sola por TTL (no por un `DELETE` manual), justo después
  de apagar `es_inventario_limitado` **y** `porcentaje_descuento` en
  Postgres. Antes de esto, una venta que vencía sola se quedaba en
  `mesh:ofertas:venta_relampago` hasta que la agarrara el worker de
  reconciliación (hasta 10 min); ahora es inmediato, igual que cerrarla a
  mano — y desde el 2026-09-24 sale de las DOS llaves (ya no tiene
  descuento), no solo se mueve a `mesh:ofertas:descuento`.

**`RegistroOfertasSyncService`** (worker `@Interval`, cada 10 min): red de
seguridad, no la fuente principal. Compara cada `HASH` contra PostgreSQL
(`porcentaje_descuento IS NOT NULL AND NOT es_inventario_limitado` para la
de descuento; `es_inventario_limitado AND porcentaje_descuento IS NOT NULL`
para la de venta relámpago — **la misma condición que usa `sincronizar()`
para decidir**, a propósito, ver el bug de abajo) y corrige: lo que sobra
se borra con `HDEL`, lo que falta se repara llamando a `sincronizar()`.

### Probado en vivo el 23 de septiembre de 2026

Contra el servidor y las bases reales (`ventas_norte`, ofertas 549 y 18).

| Caso | Resultado |
|---|---|
| Aplicar descuento → `mesh:ofertas:descuento` | aparece con el detalle correcto (nombre, imagen, precio, vendedor, stock) |
| Abrir venta relámpago → se mueve | desaparece de `descuento`, aparece — sola — en `venta_relampago` |
| Cerrar venta relámpago manual → vuelve | reaparece en `descuento`, desaparece de `venta_relampago` |
| Quitar el descuento → sale de las dos | `HGET` de las dos llaves da `nil` |
| Venta relámpago vencida por TTL (`duracion_segundos: 5`, antes del arreglo del 2026-09-24) | al siguiente tick de `revisarVencidas()` (≤ 60 s): `es_inventario_limitado` en `false` en Postgres, la oferta sale sola de `venta_relampago` y vuelve a `descuento` — sin `DELETE` manual, confirmado en Postgres y Redis |
| Venta relámpago vencida por TTL, **después** del arreglo del 2026-09-24 (`porcentaje_descuento` también se quita) | al siguiente tick: la oferta sale de las DOS llaves de `mesh:ofertas:*` (ya no tiene descuento que mostrar en ninguna) — ver la prueba completa en la sección de arriba |
| Reconciliación: simular una escritura perdida (`HDEL` a mano) + una llave sobrante (`HSET` de basura) en cada `HASH`, correr el worker | repara las dos: agrega la que faltaba con detalle fresco, borra la sobrante |
| **Bug encontrado y corregido en esta misma ronda:** la consulta original del worker para `venta_relampago` no exigía `porcentaje_descuento IS NOT NULL` | contaba como "faltante" la oferta 6 (venta relámpago heredada de antes de la regla de descuento obligatorio, sin descuento) y el log decía "agregada" aunque `sincronizar()` la descartaba en silencio por no tener descuento — corregido para que la consulta del worker coincida exactamente con la condición de `sincronizar()` |
| `npx tsc --noEmit` y `eslint` sobre los archivos nuevos/tocados | limpios |

Detalle completo (decisiones de diseño) en los comentarios de los propios
archivos — no hay `plan pendiente/` para esto, se decidió y se hizo en la
misma conversación.

---

## Pruebas — venta relámpago del vendedor (2026-09-03)

`test-ventas-limitadas.sh`, contra el servidor y las bases reales (no va al
repo). Ofertas de `ventas_norte` (3, 6) y de la tienda (7); teardown por
oferta (`es_inventario_limitado = false` + `DEL` de las claves de Redis) y
verificación de que los carritos de validación sembrados a mano quedan
intactos. **45 comprobaciones, 0 fallos.**

| Grupo | Qué | Resultado |
|---|---|---|
| A | `POST` con `duracion_segundos: 3600` | 201 `{ id_oferta, stock_sembrado }`; PG marcada; Redis sembrado con el stock; TTL de la clave ≈ 3600 s |
| B | Los tres GET de ofertas | `GET /vendedor/ofertas`, `GET /vendedor/ofertas/producto/:id` (en `mi_oferta`) y `GET /productos/:id` (público, en `ofertas[]`) traen `es_inventario_limitado` con el valor correcto |
| C | Errores de `abrir` | abrir de nuevo → 409 "ya está en modo venta limitada"; oferta ajena → 404; inexistente → 404; sin sesión → 401; rol comprador → 403; oferta pausada → 409 "no está activa"; `duracion_segundos` negativa / > 7 días / no numérica → 400; ningún intento fallido sembró nada en Redis |
| D | `POST` con body `{}` | 201, la venta no vence (TTL `-1`). Cuerpo totalmente vacío → 400 de Fastify |
| E | `DELETE` (cerrar) | 200; PG desmarcada; las dos claves de Redis borradas; cerrar de nuevo → 409; cerrar una ajena → 404 y la venta ajena no se toca |
| F | Un admin | abre y cierra la venta relámpago de una oferta de la **tienda** (actúa como `tienda@mesh.com`) |

---

## Pruebas — `stock_disponible` en los GET de ofertas (2026-09-03)

Contra el servidor y las bases reales, con la oferta 11 en venta relámpago
(PG `stock` 26, contador de Redis en 2). El campo `stock_disponible` se
agregó a `GET /productos/:id` (`ofertas[]`), `GET /vendedor/ofertas` y
`GET /vendedor/ofertas/producto/:id` (`mi_oferta`), y se calcula con la
operación `estado` de `redis/inventario_limitado.lua` (solo lectura, no
cosecha).

| Caso | Resultado |
|---|---|
| Oferta en venta relámpago | Los tres endpoints devuelven `stock_disponible: 2` (el contador de Redis), mientras `stock` sigue en 26 (PG, congelado) |
| Oferta normal (no relámpago) | `stock_disponible: null` en los tres |
| Se reserva 1 unidad (Redis 2 → 1) | La ficha pasa a `stock_disponible: 1` en el acto; al `devolver`, vuelve a 2 |
| Oferta marcada `es_inventario_limitado` en PG **sin** clave en Redis (venta cerrada pero columna aún `true`) | `stock_disponible: null`, sin error y sin warning en el log — el `estado` del `.lua` devuelve `-1` y se traduce a `null` |
| _(agregado el 4 de septiembre de 2026)_ ese mismo estado — columna `true` sin clave en Redis — ya no queda permanente: el worker de más abajo lo corrige solo dentro de 1 minuto |
| Redis caído | `estado()` no lanza: deja un warning y devuelve `null`; el catálogo y el panel se pintan igual con el `stock` de PostgreSQL |

Sin migración: es lectura de Redis desde el backend.
`cambio_propuestas/2026-09-03_2359-stock-disponible-ofertas.md`.

---

## Reglas de descuento automático (agregado 2026-09-23)

**Solo el CRUD de la configuración.** El disparo real -- un worker que
consulte ClickHouse (unidades vendidas de una oferta en una ventana de
tiempo), compare contra el umbral configurado y, si se cumple, active el
descuento o abra la venta relámpago -- **todavía no existe**. Esto es
nada más la tabla y las cuatro rutas para que un vendedor cree, liste,
pagine y edite sus reglas.

**Tabla nueva:** `regla_descuento_automatico` (Postgres, aplicada solo en
local por ahora -- sin migración real todavía, sin `plan pendiente/` para
esto, se diseñó y se creó en la misma conversación). Una fila por oferta
como máximo (`UNIQUE(id_oferta)`, `FK` a `oferta` con `ON DELETE CASCADE`):

| Columna | Qué es |
|---|---|
| `id_regla_descuento_automatico` | PK propia |
| `id_oferta` | `UNIQUE`, `FK → oferta` |
| `umbral_unidades` | Unidades vendidas que disparan la regla (entero > 0) |
| `ventana_minutos` | La ventana de tiempo, en minutos, en la que esas unidades tienen que venderse (entero > 0) |
| `es_venta_relampago` | `true` = al dispararse abre una venta relámpago completa (descuento + inventario limitado); `false` = solo aplica el descuento normal |
| `duracion_segundos` | Cuánto dura lo que se active (entero > 0 -- a diferencia de `POST .../venta-limitada`, aquí `0` no es válido: la regla siempre tiene que vencer sola) |
| `porcentaje_descuento` | El % a aplicar cuando dispare (`numeric(5,2)`, `> 0 AND < 100` a nivel de base; `1`-`90` es el límite de negocio, igual que en `POST .../descuento`) |
| `activa` | Para pausar la regla sin borrarla |
| `fecha_creacion` / `fecha_actualizacion` | De siempre; `fecha_actualizacion` se toca sola con el trigger genérico `oferta_tocar_fecha()`, reutilizado tal cual |

Controlador y servicio en su propia carpeta, fuera de `vendedores/`:
`src/controllers/reglas-descuento-automatico/` y
`src/services/reglas-descuento-automatico/` (mismo criterio que
`carrito/`/`inventario-limitado/`: una carpeta propia para un dominio
autocontenido, aunque las rutas sigan bajo el prefijo `/vendedor`).

**Autorización, igual que el resto de `/vendedor/ofertas`:** cualquier
vendedor o admin; un admin actúa como la cuenta de la tienda
(`resolverIdEfectivo()`, misma duplicación de siempre, no compartida entre
servicios). Una regla ajena o inexistente da el mismo 404 genérico de
siempre.

### POST /vendedor/reglas-descuento

Crea la regla de una oferta propia. Rechaza con 409 si esa oferta **ya
tiene** una regla (`UNIQUE(id_oferta)`) -- no se pueden duplicar, hay que
editar la existente. **(agregado 2026-09-24)** También 409 si la oferta
tiene un descuento manual, una venta relámpago manual o una regla de
período activa -- nace `activa: true`, y los cuatro mecanismos son
mutuamente excluyentes (ver la sección dedicada más abajo). Lo mismo aplica
al reactivar una regla pausada con `PATCH { activa: true }`.

```json
{
  "id_oferta": 549,
  "umbral_unidades": 10,
  "ventana_minutos": 60,
  "es_venta_relampago": true,
  "duracion_segundos": 3600,
  "porcentaje_descuento": 20
}
```

Todos los campos son obligatorios. `porcentaje_descuento` usa
`validarPorcentajeDescuento` de `validaciones-oferta.ts` tal cual -- mismo
rango (1-90) y mismo mensaje que `POST .../descuento`, no una copia.

201 con la fila creada (`activa: true` de por sí). 400 si algún campo no
cumple su rango; 404 si `id_oferta` no existe o no es tuya; 409 si ya tiene
regla.

### GET /vendedor/reglas-descuento y GET /vendedor/reglas-descuento/paginado

Las reglas de tus propias ofertas -- nunca las de otro vendedor. La
paginada es por número de página, sin filtros (no hay un "estado" que
filtrar aquí, solo `activa`, y no se pidió ese filtro), mismo criterio que
`GET /vendedor/ofertas/paginado`.

```
GET /vendedor/reglas-descuento
GET /vendedor/reglas-descuento/paginado?pagina=1&limite=20
```

200 con el array (la sin paginar) o `{ reglas, pagina, limite, total_reglas, total_paginas }` (la paginada). Array/lista vacía si no tienes ninguna, nunca un error.

### PATCH /vendedor/reglas-descuento/:id

Edita una o más columnas de una regla propia -- **incluye `activa`**, así
que pausar/reactivarla es la misma ruta que editar los números, no una
ruta aparte:

```json
{ "activa": false }
```

```json
{ "umbral_unidades": 25, "porcentaje_descuento": 30 }
```

Cualquier subconjunto de `umbral_unidades`, `ventana_minutos`,
`es_venta_relampago`, `duracion_segundos`, `porcentaje_descuento`,
`activa` -- al menos uno es obligatorio (400 `"Debes enviar al menos un
campo para actualizar"` si no viene ninguno, mismo mensaje que
`PATCH /vendedor/ofertas/:id`). 200 con la fila ya actualizada. 404 si la
regla no existe o es de otro vendedor.

### Probado en vivo el 23 de septiembre de 2026

Contra el servidor y la base real (`ventas_norte` y `ventas_sur`, ofertas
549 y 18 de `ventas_norte`).

| Caso | Resultado |
|---|---|
| Crear regla sobre oferta propia (549) | 201, `activa: true` |
| Crear una segunda regla sobre la misma oferta | 409 `"Esta oferta ya tiene una regla de descuento automatico"` |
| Crear sobre oferta ajena (id 1, de otro vendedor) | 404 genérico |
| `porcentaje_descuento: 95` (fuera de 1-90) | 400, mismo mensaje que `POST .../descuento` |
| Crear una segunda regla sobre otra oferta propia (18) | 201 |
| `GET /vendedor/reglas-descuento` | trae las dos, orden `fecha_actualizacion DESC` |
| `GET .../paginado?limite=1&pagina=1` | 1 regla, `total_reglas: 2`, `total_paginas: 2` |
| `PATCH .../1` con `{ "activa": false }` | 200, pausada; `fecha_actualizacion` se tocó sola |
| `PATCH .../1` con `{ "umbral_unidades": 25, "porcentaje_descuento": 30 }` | 200, los dos campos cambiaron, el resto intacto |
| `PATCH .../1` con `{}` | 400 `"Debes enviar al menos un campo para actualizar"` |
| `PATCH .../999` (inexistente) | 404 |
| Otro vendedor (`ventas_sur`) intenta `PATCH` sobre la regla 1 (ajena) | 404 genérico |
| Otro vendedor lista las suyas | `payload: []` -- no ve las de `ventas_norte` |
| `npx tsc --noEmit` y `eslint` sobre los 8 archivos nuevos | limpios |

Teardown: las dos reglas de prueba se borraron a mano de Postgres, la tabla
quedó vacía otra vez.

### DELETE /vendedor/reglas-descuento/:id (agregado 2026-09-25)

Borra una regla propia de verdad -- hasta ahora las pruebas la borraban
directo en Postgres, no había ruta. **409 `"Pausa la regla (activa: false)
antes de borrarla"` si la regla está activa** -- borrar una regla activa
dejaría a la oferta con un descuento aplicado (via TTL de Redis) y ninguna
fila que lo explique; hay que pausarla primero (`PATCH { "activa": false
}`), lo que además la desactiva de una vez. 200 (`payload: null`) si se
borró. 404 si no existe o es de otro vendedor.

### Probado en vivo el 25 de septiembre de 2026

| Caso | Resultado |
|---|---|
| `DELETE` sobre una regla `activa: true` | 409 |
| `PATCH { "activa": false }` seguido de `DELETE` | 200, la fila desaparece |
| `DELETE` sobre un id ya borrado | 404 |
| `npx tsc --noEmit` y `eslint` sobre los archivos tocados | limpios |

---

## Reglas de descuento por período / calendario (agregado 2026-09-24)

El CRUD de la configuración, igual que `regla_descuento_automatico`
-- ver esa sección para el criterio de autorización, que es idéntico.
**El disparador real ya existe** -- ver "El disparador de
`regla_descuento_periodo`" más abajo, la última sección de este archivo.
El plan completo de esta feature está en
`elementos Generales/plan pendiente/reglas-descuento-periodos.md`.

A diferencia de `regla_descuento_automatico` (dispara por umbral de ventas
en una ventana), esta dispara por **calendario**: un rango de fechas que se
repite con distinta granularidad según qué campos se omiten.

**Tabla nueva:** `regla_descuento_periodo` (Postgres, aplicada solo en
local por ahora -- referencia en `plan pendiente/reglas-descuento-periodos.sql`,
sin migración real todavía). A diferencia de `regla_descuento_automatico`,
**no tiene `UNIQUE(id_oferta)`**: una misma oferta puede tener varios
períodos (ej. uno fijo de Black Friday 2026 y uno recurrente mensual).

| Columna | Qué es |
|---|---|
| `id_regla_descuento_periodo` | PK propia |
| `id_oferta` | `FK → oferta`, sin `UNIQUE` |
| `dia_inicio` / `dia_fin` | Rango de día del mes (1-31), siempre obligatorios |
| `mes_inicio` / `mes_fin` | Rango de mes (1-12), opcionales -- van siempre juntos (los dos o ninguno) |
| `anio` | Opcional, no puede venir sin `mes_inicio`/`mes_fin` |
| `es_venta_relampago` | Igual que en `regla_descuento_automatico` |
| `porcentaje_descuento` | Igual que en `regla_descuento_automatico` (`numeric(5,2)`, 1-90 de negocio) |
| `activa` | Para pausar la regla sin borrarla |
| `fecha_creacion` / `fecha_actualizacion` | `fecha_actualizacion` se toca sola con el mismo trigger `oferta_tocar_fecha()` |

**La cascada** (la ausencia de un campo amplía la repetición, de más
específico a más general):

1. **Con `anio`** → ocurre una sola vez, en ese año exacto.
2. **Sin `anio`** (con mes) → se repite cada año, mismo rango de día/mes.
3. **Sin mes** (y por lo tanto sin `anio`) → se repite en todos los meses de
   todos los años, usando solo el rango de día.

No hay validación de que `dia_fin`/`mes_fin` sea "posterior" a
`dia_inicio`/`mes_inicio`: un período puede cruzar el fin de año o de mes
(ej. del 20 de diciembre al 5 de enero), así que esa comparación queda para
el disparador real, no para este CRUD.

Controlador y servicio en su propia carpeta:
`src/controllers/reglas-descuento-periodo/` y
`src/services/reglas-descuento-periodo/` (mismo criterio que
`reglas-descuento-automatico/`).

### POST /vendedor/reglas-descuento-periodos

Crea un período de una oferta propia. No hay `UNIQUE(id_oferta)`: una
oferta puede acumular varios períodos activos a la vez, **siempre que
ninguno se solape en días con otro ya activo de la misma oferta**
-- 409 si se solapan (agregado 2026-09-24, ver "Solape entre reglas de
período de la misma oferta" más abajo). **(agregado 2026-09-24)** También
da 409 si la oferta tiene un descuento manual, una venta relámpago manual
o una regla automática activa -- nace `activa: true`, y esos cuatro
mecanismos son mutuamente excluyentes (ver la sección dedicada más abajo).
Lo mismo aplica al reactivar un período pausado con `PATCH { activa: true }`,
para las dos comprobaciones.

```json
{
  "id_oferta": 3,
  "dia_inicio": 20,
  "dia_fin": 31,
  "mes_inicio": 12,
  "mes_fin": 12,
  "anio": 2026,
  "es_venta_relampago": true,
  "porcentaje_descuento": 30
}
```

`id_oferta`, `dia_inicio`, `dia_fin`, `es_venta_relampago` y
`porcentaje_descuento` son obligatorios; `mes_inicio`/`mes_fin`/`anio` son
opcionales, sujetos a la cascada de arriba. 400 con un mensaje específico si
`mes_inicio` viene sin `mes_fin` (o viceversa), o si `anio` viene sin mes.
`porcentaje_descuento` reutiliza `validarPorcentajeDescuento` de
`validaciones-oferta.ts` tal cual -- mismo rango (1-90) y mismo mensaje que
en `regla_descuento_automatico`.

201 con la fila creada (`activa: true`). 400 si algún campo no cumple su
rango o su cascada; 404 si `id_oferta` no existe o no es tuya.

### GET /vendedor/reglas-descuento-periodos y GET .../paginado

Idéntico en forma a `GET /vendedor/reglas-descuento`: solo tus propios
períodos, la paginada sin filtros.

```
GET /vendedor/reglas-descuento-periodos
GET /vendedor/reglas-descuento-periodos/paginado?pagina=1&limite=20
```

200 con el array (la sin paginar) o `{ reglas, pagina, limite, total_reglas, total_paginas }` (la paginada).

### PATCH /vendedor/reglas-descuento-periodos/:id

Edita una o más columnas de un período propio -- incluye `activa`, así que
pausar/reactivarlo es la misma ruta que editarle las fechas o el descuento.
Al menos un campo es obligatorio.

```json
{ "activa": false }
```

```json
{ "dia_inicio": 15, "porcentaje_descuento": 40 }
```

**La cascada se valida contra el estado final de la fila, no solo contra lo
que llega en la petición.** Si editas `mes_inicio` de una regla que ya tenía
`mes_fin` puesto, la combinación final es válida y no hace falta reenviar
`mes_fin`; si la regla no tenía mes (nivel "todo el mes, todos los años") y
mandas solo `mes_inicio`, el backend rechaza con 400 porque el estado final
tendría `mes_inicio` sin `mes_fin` -- el mismo mensaje que en `POST`, aunque
la petición de `PATCH` nunca haya tocado `mes_fin`.

200 con la fila ya actualizada. 404 si el período no existe o es de otro
vendedor. 400 `"Debes enviar al menos un campo para actualizar"` si no viene
ninguno.

### Probado en vivo el 24 de septiembre de 2026

Contra el servidor y la base real (`ventas.norte@mesh.com` oferta 3,
`ventas.sur@mesh.com` oferta 2 como ajena).

| Caso | Resultado |
|---|---|
| Tabla: sin `UNIQUE`, FK `ON DELETE CASCADE`, 8 `CHECK`, trigger de fecha | Los cinco, correctos |
| Sin sesión / comprador contra `POST` | 401 / 403 |
| `dia_inicio: 0`, `dia_fin: 32`, `mes_inicio: 13` | 400 cada uno |
| `mes_inicio` sin `mes_fin`, `anio` sin mes, `anio: 1999` (fuera de rango) | 400 cada uno |
| `porcentaje_descuento: 95`, falta `dia_fin` | 400 cada uno |
| Ninguna de esas validaciones dejó fila en Postgres | confirmado |
| Crear con `anio` (una vez), sin `anio` (recurrente por mes), sin mes (recurrente por día) -- misma oferta | 201 los tres; Postgres guardó exactamente lo enviado; sin 409 al repetir oferta |
| Crear sobre oferta ajena | 404 |
| `GET` y `GET .../paginado` | las tres reglas aparecen; `total_reglas`/`total_paginas` cuadran con Postgres |
| `PATCH .../:id` con `{ "activa": false }` | 200, pausada; `fecha_actualizacion` se tocó sola |
| `PATCH .../:id` con `{ "dia_inicio": 15, "porcentaje_descuento": 40 }` | 200, esos dos cambiaron, el resto intacto |
| `PATCH .../:id` con `{}` | 400 |
| `PATCH .../:id` con `porcentaje_descuento: 91` | 400 |
| `PATCH` a un id inexistente | 404 |
| `PATCH { "mes_inicio": 3 }` sobre la regla "sin mes" (recurrente por día) | 400 -- la cascada rechaza el estado final aunque la petición no tocó `mes_fin`; la fila no cambió |
| `PATCH { "anio": 2027 }` sobre la regla "sin año" (recurrente por mes, ya tenía `mes_inicio`/`mes_fin`) | 200 -- válido porque el estado final ya tenía mes completo |
| Otro vendedor (`ventas_sur`) intenta `PATCH` sobre una regla ajena | 404 genérico |
| Otro vendedor lista las suyas | no ve las de `ventas_norte` |
| `npx tsc --noEmit` y `eslint` sobre los 7 archivos nuevos + `app.module.ts` | limpios |

Teardown: las tres reglas de prueba se borraron a mano de Postgres, la tabla
quedó vacía otra vez.

### DELETE /vendedor/reglas-descuento-periodos/:id (agregado 2026-09-25)

Mismo criterio exacto que `DELETE /vendedor/reglas-descuento/:id` (ver esa
sección): 409 `"Pausa la regla (activa: false) antes de borrarla"` si el
período está activo, 200 si ya estaba pausado, 404 si no existe o es de
otro vendedor. Aquí el riesgo de borrar en caliente es más concreto porque
ya se vio en vivo (ver "Teardown" de la ronda del disparador, más abajo):
sin este bloqueo, borrar un período activo deja a la oferta con un
descuento que ninguna fila de `regla_descuento_periodo` justifica, y el
disparador ya no puede verla para limpiarla -- queda huérfana para
siempre, no solo hasta el próximo tick.

### Probado en vivo el 25 de septiembre de 2026

| Caso | Resultado |
|---|---|
| `DELETE` sobre un período `activa: true` | 409 |
| `PATCH { "activa": false }` seguido de `DELETE` | 200, la fila desaparece |
| `DELETE` sobre un id ya borrado | 404 |
| `npx tsc --noEmit` y `eslint` sobre los archivos tocados | limpios |

---

## Exclusión mutua entre los cuatro mecanismos de descuento/venta relámpago (agregado 2026-09-24)

Decidido con el usuario al diseñar los workers que le faltan a las reglas
de descuento (automático y por período): los cuatro mecanismos que pueden
poner un descuento o abrir una venta relámpago en una oferta son
**mutuamente excluyentes** -- como mucho UNO puede estar activo a la vez
sobre la misma oferta:

1. Descuento manual (`POST /vendedor/ofertas/:id/descuento`)
2. Venta relámpago manual (`POST /vendedor/ofertas/:id/venta-limitada`)
3. Regla de descuento automático (`activa: true`)
4. Regla de descuento por período (`activa: true`)

**"Activo" para las dos reglas es su columna `activa = true`.** Una regla
pausada (`activa: false`) no cuenta y no bloquea nada -- confirmado
explícitamente con el usuario ("un activo en false, significa que no
está, así que no es excluyente").

**La única excepción, no simétrica a propósito:** descuento manual y venta
relámpago manual **no** se excluyen entre sí. Una venta relámpago manual
ya EXIGE un descuento manual puesto (`abrir()` da 409 si falta, ver la
sección de `POST .../venta-limitada`) -- son la misma "pista manual", no
dos mecanismos en competencia. Las dos reglas (automática y por período) sí
excluyen a los cuatro mecanismos restantes, incluida la otra regla y las
dos manuales.

**Contra su propio tipo, cada regla se comporta distinto** (esto NO es
parte de esta exclusión, son reglas aparte):
- `regla_descuento_automatico` ya tenía su propio `UNIQUE(id_oferta)`
  desde que se creó: nunca puede haber una segunda para la misma oferta.
- `regla_descuento_periodo` SÍ puede tener varias activas a la vez sobre la
  misma oferta -- pero solo si sus rangos de días **nunca se solapan**.
  Esa comprobación es aparte de esta exclusión y está documentada en su
  propia sección más abajo, "Solape entre reglas de período de la misma
  oferta".

**Dónde se comprueba: al activar, no al pausar.** Crear una regla nace
`activa: true`, así que crear ES activar. Reactivar una regla pausada
(`PATCH { activa: true }`) pasa por el mismo chequeo. Pausar (`activa:
false`) nunca lo necesita.

**Implementación:** un helper nuevo y compartido,
`helpers/exclusion-mecanismos-descuento.ts`
(`exigirSinOtroMecanismoActivo()`), para no repetir la consulta ni el
mensaje en los cuatro puntos de entrada -- mismo criterio que
`expresionPrecioFinal()`. Una sola consulta trae los cuatro flags (el
`porcentaje_descuento`/`es_inventario_limitado` de la oferta, más un
`EXISTS` por cada tabla de reglas con `activa = true`), y una tabla interna
(`EXCLUYE`) define contra cuáles choca cada uno al entrar -- la asimetría
del párrafo de arriba vive ahí. En
`OfertasVendedorService.aplicarDescuento()` corre DENTRO de la misma
transacción con `SELECT ... FOR UPDATE` que ya existía (recibe el
`PoolClient`, no `pool`); en los otros tres puntos (`abrir()`, y los
`crear()`/`editar()` de las dos reglas) es una consulta suelta con `pool`,
igual que el resto de esos servicios.

Mensaje uniforme en los cuatro puntos de entrada:

```json
{ "ok": false, "mensaje": "Esta oferta ya tiene <mecanismo>: los mecanismos de descuento/venta relampago son mutuamente excluyentes, hay que desactivar ese primero", "payload": null }
```

Con `<mecanismo>` siendo `un descuento manual activo`, `una venta
relampago activa`, `una regla de descuento automatico activa` o `una
regla de descuento por periodo activa`, según cuál sea el que ya está
puesto.

### Probado en vivo el 24 de septiembre de 2026

Contra el servidor y la base real (`ventas_norte`, ofertas 18/27/35/39/42;
`ventas_sur`, oferta 5).

| Caso | Resultado |
|---|---|
| Descuento manual en 18 → crear regla automática sobre 18 | 409 `"...un descuento manual activo..."` |
| Descuento manual en 18 (sigue activo) → crear regla de período sobre 18 | 409, mismo mensaje |
| Crear regla automática en 27 → aplicar descuento manual sobre 27 | 409 `"...una regla de descuento automatico activa..."` |
| Regla automática en 27 (sigue activa) → abrir venta relámpago sobre 27 | 409 -- pero por el chequeo PREVIO ("necesita un descuento activo primero"), no por el nuevo: como nunca hay descuento sin que la exclusión ya lo hubiera bloqueado, ese camino nunca llega al chequeo nuevo en la práctica |
| `PATCH` la regla automática de 27 a `{ "activa": false }`, luego aplicar descuento manual sobre 27 | 200 y 201 -- una regla pausada **no bloquea**, confirmado explícitamente |
| Crear regla de período en 35 → crear regla automática sobre 35 | 409 `"...una regla de descuento por periodo activa..."` |
| Aplicar descuento manual en 39, luego abrir venta relámpago sobre 39 (misma oferta) | 201 los dos -- la única excepción funciona, no se bloquean entre sí |
| Crear regla de período en 42, pausarla, aplicar descuento manual sobre 42, luego reintentar `PATCH { "activa": true }` sobre esa regla | 409 `"...un descuento manual activo..."` -- la reactivación pasa por el mismo chequeo que crear() |
| `PATCH { "activa": true }` sobre la regla automática 4 (oferta 27, con descuento manual activo desde el caso de arriba) | 409, mismo mecanismo |
| `ventas_sur` crea una regla automática sobre su propia oferta 5 (sin nada activo ahí) | 201 -- el chequeo es por oferta, no interfiere entre vendedores |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: se cerraron/quitaron todos los descuentos y ventas relámpago de
prueba (`DELETE .../descuento`, `DELETE .../venta-limitada`) y se borraron
a mano de Postgres las filas de `regla_descuento_automatico`/
`regla_descuento_periodo` creadas para la prueba. Las ofertas tocadas
(5, 18, 27, 35, 39, 42) quedaron en su estado original.

### Lo que quedaba pendiente en esta ronda -- todo resuelto después

- **El disparador real de `regla_descuento_automatico`**: se construyó el
  2026-09-25, ver la sección dedicada más abajo. Los disparadores de
  período y automático pasan el id REAL del vendedor dueño de la oferta
  (nunca un id de sistema) al llamar `aplicarDescuento()`/`abrir()`, así
  que su atribución en `precio_historial` siempre fue correcta -- nunca
  hizo falta arreglar nada ahí.
- **Atribución de las limpiezas automáticas por TTL** (venta relámpago y
  descuento manual vencidos, `VentasLimitadasService.revisarVencidas()`):
  esa sí caía en el dueño de la oferta por defecto, sin que fuera él quien
  actuó. Corregido el 2026-09-25 -- ver la sección "Atribución (corregida
  2026-09-25)" más arriba y
  `cambio_propuestas/2026-09-25_0745-atribucion-limpiezas-automaticas.md`.
`cambio_propuestas/2026-09-24_2300-exclusion-mecanismos-descuento.md`.

---

## Solape entre reglas de período de la misma oferta (agregado 2026-09-24)

La pieza que quedaba pendiente de la sección de arriba: `regla_descuento_periodo`
permite varias reglas activas a la vez sobre una misma oferta, pero solo si
sus rangos de días **nunca coinciden en un mismo día real**. Antes de esto,
nada impedía crear dos reglas de período que sí se pisaran.

**El enfoque:** representar el rango de día/mes de cada regla como una
máscara de 12×31 casillas (mes 1-12, día 1-31) y comparar máscaras --
`helpers/solape-regla-descuento-periodo.ts`, `reglasDePeriodoSeSolapan()`.
Una casilla que no es un día real (30 de febrero) no molesta: la tabla
tampoco valida que el día exista dentro del mes, así que tratarla como
cualquier otra del rango es consistente. Dos reglas se solapan si:

1. Sus máscaras comparten al menos una casilla, **y**
2. Comparten al menos un año en el que las dos puedan ocurrir:
   - las dos sin `año` (recurrentes) → comparten TODOS los años;
   - una con `año` y la otra sin → la recurrente también ocurre en el año
     de la otra;
   - las dos con `año` → solo si es el MISMO año -- años distintos nunca
     se solapan, sin importar el rango de día/mes.

**Asunción sobre las reglas "con año":** se asume que no cruzan al año
siguiente (mismo criterio que el ejemplo del plan original, "del
2026-12-20 al 2026-12-31") -- solo las reglas recurrentes (sin año) cruzan
el fin de año libremente (ej. "20 de diciembre al 5 de enero", recurrente).

**Dónde se comprueba:** en `crear()`, siempre (nace `activa: true`). En
`editar()`, cada vez que la regla queda activa después de la edición --ya
sea porque se reactiva con `activa: true`, o porque ya estaba activa y solo
se le cambian las fechas-- se revisa el **rango final** (lo nuevo mezclado
con lo que ya tenía) contra las demás reglas activas de la misma oferta.
Esto significa que editar solo `dia_inicio` de una regla ya activa puede
rechazar con 409 si el nuevo rango choca con otra, aunque la edición nunca
haya tocado `activa`. Contra sí misma nunca se compara (se excluye por
`id_regla_descuento_periodo`).

```json
{ "ok": false, "mensaje": "Esta oferta ya tiene una regla de descuento por periodo activa (id 6) que se solapa en dias con esta", "payload": null }
```

### Probado -- unitario y en vivo, 24 de septiembre de 2026

**Unitario** (script de scratchpad, 18 casos sobre `reglasDePeriodoSeSolapan()`
directamente, sin servidor): rangos de solo día con y sin *wrap* (28-3),
rangos de mes con y sin *wrap* de año (nov-feb), año exacto vs año exacto
(mismo año se solapan, distinto no), año exacto vs recurrente (la
recurrente sí aplica en ese año), y combinaciones cruzadas día-solo vs
mes-rango. Los 18 en verde.

**En vivo**, contra el servidor y la base real (`ventas_norte`, ofertas
18/27/31/35):

| Caso | Resultado |
|---|---|
| Crear regla A (día 1-5) → crear regla B (día 3-10, se solapan en 3-5) | 201, luego 409 |
| Crear regla C (día 10-15, no se solapa con A) sobre la misma oferta | 201 -- dos reglas activas conviven sin problema |
| `PATCH` regla C a `dia_inicio: 4` (ahora sí se solapa con A en 4-5) | 409; la fila de Postgres no cambió |
| Crear mes 1-3 → crear mes 3-5 (se solapan en marzo) → crear mes 6-8 (no se solapa) | 201, 409, 201 |
| Año 2026 dic 20-31 → mismo rango año 2027 (no se solapan) → mismo rango año 2026 de nuevo (sí se solapan) | 201, 201, 409 |
| Crear regla D (día 1-5) → pausarla → crear regla E (día 3-8, se solapa con D) mientras D está pausada | 201, 200, 201 -- D pausada no bloquea, mismo criterio que la exclusión de mecanismos |
| Reactivar D (`PATCH activa: true`) con E ya activa y solapada | 409 |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: las ocho reglas de prueba se borraron a mano de Postgres.
`cambio_propuestas/2026-09-24_2330-solape-regla-descuento-periodo.md`.

---

## El disparador de `regla_descuento_periodo` (agregado 2026-09-24)

No es una ruta HTTP: `DisparadorReglasPeriodoService.revisar()`, un
`@Interval` cada 15 min (`src/services/reglas-descuento-periodo/`). Es el
primero de los dos workers que le faltaban a las reglas de descuento --
el segundo es el de `regla_descuento_automatico`, ver la sección dedicada
más abajo. `regla_descuento_periodo` es una condición de estado ("¿hoy cae
en el rango?"), reevaluable sola en cada corrida sin necesitar memoria de
nada -- a diferencia de `regla_descuento_automatico`, que dispara una vez
y depende de un TTL para saber cuándo apagarse.

**Por qué ya se podía construir.** Las dos piezas de diseño que le
faltaban (exclusión mutua entre los cuatro mecanismos, solape entre reglas
de período de la misma oferta -- ambas arriba) garantizan dos invariantes
que el disparador necesita para no tener que arbitrar nada: mientras una
regla de período está activa, es la ÚNICA dueña del
`porcentaje_descuento`/`es_inventario_limitado` de esa oferta; y a lo sumo
UNA regla activa de una oferta puede aplicar en un día dado.

**Reusa las rutas existentes en vez de escribir SQL propio.**
`OfertasVendedorService.aplicarDescuento()`/`quitarDescuento()` y
`VentasLimitadasService.abrir()`/`cerrar()` -- así vienen gratis la
validación, el recálculo de Mongo, la sincronización de Redis y el
trigger de `precio_historial`, en vez de duplicarlos. Como esas rutas
piden un actor humano, el disparador pasa el `id_usuario` DUEÑO de la
oferta con rol vendedor (nunca admin): opera exactamente como si el
vendedor lo hubiera hecho él mismo. `duracion_segundos: 0` siempre -- el
disparador mismo decide cuándo apagar, por calendario, no por un TTL de
Redis.

**Bug real encontrado construyendo esto (no en el diseño de papel): el
disparador se rechazaba a sí mismo.** `aplicarDescuento()`/`abrir()`
llamaban a `exigirSinOtroMecanismoActivo()` con el mecanismo
`'descuento_manual'`/`'venta_relampago_manual'` **fijo**, sin importar
quién llamara. Cuando el disparador los invocaba para aplicar la MISMA
regla que los estaba disparando, el chequeo veía "hay una regla de
período activa" (la propia regla) y respondía 409, como si un mecanismo
ajeno estuviera compitiendo. **Arreglado** agregando un parámetro
`mecanismo` opcional (por defecto `'descuento_manual'`/
`'venta_relampago_manual'`, así los llamadores HTTP de siempre no cambian
nada) a los dos métodos, para que el disparador se identifique como
`'regla_periodo'` -- que no choca contra sí mismo en la tabla `EXCLUYE`.

Un segundo caso más sutil, mismo origen: al aplicar una regla con
`es_venta_relampago: true`, `aplicarDescuento()` corre primero y dispara
el trigger de Postgres; para cuando `abrir()` corre después, el
`porcentaje_descuento` que la propia regla ACABA de poner ya luce como "un
descuento manual activo" (`exigirSinOtroMecanismoActivo()` no sabe quién
lo puso, solo si la columna está llena). Por eso `abrir()` **salta por
completo** el chequeo de exclusión cuando `mecanismo` no es
`'venta_relampago_manual'` -- confía en que la exclusividad ya la validó
el `aplicarDescuento()` que la misma regla llamó un instante antes.

**El algoritmo, por oferta con al menos una regla de período (activa o
no):**

1. `reglaHoy` = la regla ACTIVA de esa oferta cuyo rango incluya la fecha
   de hoy (a lo sumo una, por el solape ya resuelto).
2. Si el estado actual de la oferta ya coincide con `reglaHoy` (mismo %,
   mismo `es_venta_relampago`) → no hacer nada.
3. Si el estado actual no está vacío pero NO coincide con `reglaHoy`:
   primero hay que decidir si es "nuestro" -- ¿coincide con ALGUNA regla
   de período de esa oferta, activa o no? Si no coincide con ninguna, se
   deja intacto (no es un estado que este mecanismo haya puesto) y se
   loguea una advertencia. Si coincide con alguna, se quita (cierra la
   venta relámpago si corresponde, después quita el descuento).
4. Si `reglaHoy` existe (y el estado ya quedó vacío, sea porque lo estaba
   desde el principio o porque el paso 3 lo vació) → se aplica.

El paso 3 es lo que reconcilia una regla que se pausó a mano
(`PATCH { activa: false }`) mientras su efecto seguía activo en la oferta
-- `editar()` de `ReglasDescuentoPeriodoService` solo apaga la columna
`activa`, nunca toca `oferta`, así que sin este paso el descuento se
quedaría pegado. La consulta del disparador por eso NO filtra
`WHERE r.activa = true` a secas: trae toda oferta con
`r.activa = true OR o.porcentaje_descuento IS NOT NULL`, para que una
regla recién pausada siga siendo visible el tiempo suficiente para
limpiarla.

**Limitación conocida y aceptada, documentada también en la sección de
`revisarDescuentosVencidos()`:** un descuento que no coincide con NINGUNA
regla de período de su oferta (puesto por otra vía) se deja intacto con una
advertencia en el log, nunca se pisa a ciegas. Ahora que sí existe un
`DELETE` de reglas (ver la sección dedicada más arriba), ese `DELETE`
rechaza con 409 borrar una regla `activa` precisamente para no volver a
caer en este caso -- solo se puede llegar a un descuento huérfano borrando
la fila por SQL directo, fuera de la aplicación.

**Corre también al arrancar el backend (agregado 2026-09-25).** El
`@Interval` de Nest no dispara de inmediato, solo después de que pase el
primer intervalo (15 min) -- si el backend estuvo apagado un día en que una
regla de período debía prenderse o apagarse, se quedaba desincronizado
hasta 15 minutos después de reiniciar. `DisparadorReglasPeriodoService`
ahora implementa `OnApplicationBootstrap` y llama a la misma `revisar()`
una vez, apenas Nest termina de inicializar todos los módulos -- antes
incluso de que el servidor empiece a escuchar peticiones.

### Probado en vivo el 24 de septiembre de 2026

Contra el servidor y la base real (`ventas_norte`, ofertas 3/18/27), con el
intervalo bajado a 8 s solo para la prueba (repuesto a 15 min después).

| Caso | Resultado |
|---|---|
| Regla que cubre hoy (día 20-28, recurrente) en oferta 3 | primer intento: 409 `"...una regla de descuento por periodo activa..."` -- el bug de arriba, antes del arreglo |
| Mismo caso, después del arreglo del `mecanismo` | se aplica sola en el siguiente tick: `porcentaje_descuento: 15.00` |
| Regla que NO cubre hoy (día 1-5) en oferta 18 | nunca se toca, `porcentaje_descuento` sigue `NULL` |
| Regla que cubre hoy CON `es_venta_relampago: true` en oferta 27 | se aplican las dos cosas en el mismo tick: `porcentaje_descuento: 30.00`, `es_inventario_limitado: true`, clave de Redis de la venta relámpago sembrada |
| Pausar la regla ya aplicada de la oferta 3 (`activa: false`) | en el siguiente tick, el descuento se quita solo (reconciliación del paso 3) |
| Crear una segunda regla en la oferta 18 que sí cubre hoy (día 20-28) | se aplica en el siguiente tick, sin tocar la regla vieja (que sigue sin cubrir hoy) |
| Pausar la regla con venta relámpago de la oferta 27 | en el siguiente tick, se cierra la venta relámpago Y se quita el descuento -- las dos cosas |
| `npx tsc --noEmit` y `eslint` sobre el repo completo | limpios |

Teardown: las reglas de prueba se borraron a mano de Postgres; la oferta
18 quedó con un descuento huérfano (su regla se borró directo por SQL, sin
pasar por la app) que se quitó con el `DELETE .../descuento` real, no a
mano en la base -- confirma en vivo la limitación conocida de arriba.
`cambio_propuestas/2026-09-24_2359-disparador-reglas-periodo.md`.

### Probado en vivo el 25 de septiembre de 2026 -- corre también al arrancar

Contra el servidor y la base real (`ventas_norte`, oferta 251).

| Caso | Resultado |
|---|---|
| Regla de período insertada directo en Postgres (fuera de la app, simulando "cambió mientras el backend estaba apagado") con rango que cubre el día de hoy, `activa: true`, sobre una oferta sin ningún otro mecanismo activo | `oferta.porcentaje_descuento` queda `NULL` -- nadie la aplicó todavía |
| Reiniciar el backend y revisar Postgres a los pocos segundos (sin esperar 15 min) | log `"disparador de reglas de periodo: 1 oferta(s) con descuento aplicado, 0 con descuento quitado"` **antes** de `"Nest application successfully started"`; `porcentaje_descuento` ya en `20.00` |
| `npx tsc --noEmit` y `eslint` sobre el archivo tocado | limpios |

Teardown: la regla y el descuento de prueba se limpiaron con las rutas
reales (`PATCH { activa: false }` + `DELETE` de la regla, `DELETE
.../descuento` de la oferta) -- ver las pruebas del `DELETE` de reglas más
arriba, que se hicieron sobre esta misma oferta y regla.

---

## El disparador de `regla_descuento_automatico` (agregado 2026-09-25)

No es una ruta HTTP: `DisparadorReglasAutomaticoService.revisar()`, un
`@Interval` cada 60 s (`src/services/reglas-descuento-automatico/`). Cierra
el segundo de los dos workers que le faltaban a las reglas de descuento.

**Por qué el pendiente de "cuándo se activó" ya no bloquea nada.** El
problema original era que este disparo es de una sola vez con duración
fija, a diferencia de `regla_descuento_periodo` (una condición de estado
reevaluable sola). Pero `duracion_segundos` en `regla_descuento_automatico`
**nunca puede ser 0** (`validarDuracionSegundos`, "acá la regla siempre
tiene que vencer sola") -- así que toda activación de este worker usa
EXACTAMENTE el mismo TTL de Redis que ya usan `POST .../descuento` y
`POST .../venta-limitada` con `duracion_segundos`, y
`VentasLimitadasService.revisarVencidas()` (el worker que ya existía, sin
ningún cambio) es quien la apaga sola cuando vence. No hace falta guardar
"cuándo se activó" en Postgres: la cuenta regresiva vive en Redis. Por el
mismo motivo, este disparador **nunca desactiva nada** -- a diferencia de
`DisparadorReglasPeriodoService`, no tiene ningún `quitarEfecto()`.

**Algoritmo, mucho más simple que el de período:**

1. Trae toda regla `activa = true` cuya oferta tenga
   `porcentaje_descuento IS NULL` -- mientras esa columna esté llena, la
   exclusión mutua garantiza que esta MISMA regla es su única dueña
   (`UNIQUE(id_oferta)` en `regla_descuento_automatico`), así que no hace
   falta gastar una consulta a ClickHouse por ella en cada corrida: ya está
   activa, esperando a que su propio TTL venza.
2. Por cada una, consulta ClickHouse (`compra_producto`, `lote = 'real'`):
   unidades vendidas de esa oferta en los últimos `ventana_minutos`.
3. Si llegan a `umbral_unidades`: `aplicarDescuento()` con
   `mecanismo: 'regla_automatica'` y el `duracion_segundos`/
   `porcentaje_descuento` de la regla; si `es_venta_relampago`, `abrir()`
   con el mismo `duracion_segundos` y mecanismo, inmediatamente después.

**Hallazgo real de diseño, encontrado probando (no es un bug de código):
si `duracion_segundos` de la regla es MENOR que su `ventana_minutos`, la
oferta "parpadea".** El TTL apaga el descuento, pero las mismas ventas que
lo dispararon siguen dentro de la ventana en el siguiente tick, así que se
vuelve a activar de inmediato -- ciclo de encendido/apagado hasta que esas
ventas salgan de la ventana. Confirmado en vivo con `duracion_segundos: 8`
y `ventana_minutos: 10`: se reactivó solo tres veces seguidas (cada vez que
`VentasLimitadasService.revisarVencidas()` la apagaba) hasta que se pausó
la regla a mano. En el uso normal esperado (`duracion_segundos` MAYOR que
`ventana_minutos`, ej. "2 horas de oferta" disparadas por "30 minutos de
ventas") esto no pasa: para cuando el TTL vence, las ventas que lo
motivaron ya salieron de la ventana, y solo se reactiva si de verdad
siguieron vendiendo rápido -- que es el comportamiento deseado. Queda
anotado como algo a explicar al configurar una regla, no como algo a
corregir en el código.

**Pausar la regla (`PATCH { activa: false }`) mientras su efecto está
activo NO lo apaga de inmediato** -- a diferencia del disparador de
período (que sí reconcilia esto), acá se deja que el TTL de Redis termine
su curso normal. Decisión consciente: el mecanismo entero de esta regla
está construido sobre "el TTL manda", meterle una desactivación forzada
por fuera de eso sería una segunda vía de apagado que no aporta nada, dado
que lo peor que pasa es que el descuento dure unos segundos/minutos más de
lo que la config actual diría.

### Probado en vivo el 25 de septiembre de 2026

Contra el servidor y las bases reales (`ventas_norte` oferta 31,
`ventas_sur` oferta 34), con el intervalo bajado a 5 s solo para la
prueba (repuesto a 60 s después).

| Caso | Resultado |
|---|---|
| Regla creada (umbral 3, ventana 10 min), sin ventas sembradas | nunca se toca |
| 2 unidades sembradas en ClickHouse (bajo el umbral) | sigue sin tocarse |
| 1 unidad más (total 3, cruza el umbral) | se activa sola: `porcentaje_descuento: 15.00`; `precio_historial` nuevo con `id_usuario_modifico` = el vendedor dueño real (no un id de sistema); `precio_final` correcto en `GET /vendedor/ofertas` |
| `POST .../descuento` manual sobre la misma oferta mientras el automático está activo | 409 "ya tiene un descuento activo" |
| Regla con `es_venta_relampago: true` (umbral 5, ventana 1 min, duración 90 s) + 5 unidades sembradas | se activan las dos cosas en el mismo tick: `porcentaje_descuento: 20.00`, `es_inventario_limitado: true`; Redis: HASH de stock sembrado con el stock real de Postgres, TTL del descuento y de la venta relámpago sincronizados (~90 s) |
| Duración (90 s) mayor que la ventana (1 min): al vencer el TTL | se apaga sola, sin reactivarse (las ventas que la dispararon ya habían salido de la ventana) |
| Pausar la regla (`activa: false`) mientras el efecto seguía activo | el efecto ya activo se dejó correr su TTL normal; sin la pausa, se había reactivado 3 veces seguidas (ver el hallazgo del parpadeo arriba) |
| ClickHouse real caído (`docker stop`), con una regla activa sin disparar | `WARN` en el log por cada intento, la app y el resto de rutas siguieron respondiendo `200` normal, ninguna activación falsa |
| ClickHouse recuperado (`docker start`) | siguiente corrida limpia, sin reactivación espuria (0 unidades reales, bajo el umbral) |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: las dos reglas de prueba y las filas sembradas en
`compra_producto` (`ALTER TABLE ... DELETE`, ClickHouse no tiene
transacciones) se borraron a mano; las ofertas 31 y 34 quedaron sin
descuento/venta relámpago y sin ninguna clave de Redis residual.
`cambio_propuestas/2026-09-25_0700-disparador-reglas-automatico.md`.
