# Endpoints de vendedor

Este archivo documenta solo las rutas de `/vendedor/*`. Las demás rutas del
backend están en [endpoints.md](endpoints.md) (usuario, perfil, direcciones,
admin), [endpoints-productos.md](endpoints-productos.md) (el catálogo
público) y [endpoints-compradores.md](endpoints-compradores.md) (comprar,
sin exigir un rol en particular).

Todas las rutas de aquí requieren la cookie `mesh_token`. Las de
`/vendedor/categorias` aceptan vendedor o admin (`id_rol_usuario` 2 o 3);
todas las de `/vendedor/productos` y `/vendedor/ofertas` son solo para
vendedor (2). Un rol sin permiso recibe 403, igual que en `/admin/*`.

**Modelo multi-vendedor: `/vendedor/productos` y `/vendedor/ofertas` ya no
son la misma cosa.** El catálogo (`/vendedor/productos`) es compartido y
**solo lo crea/edita la cuenta de la tienda** (`tienda@mesh.com` — ver
`cambios-multivendedor.md`, sección 9); un producto ya no pertenece a quien
lo crea. Lo que sí es de cualquier vendedor es la **oferta**: publicar un
precio y un stock propios sobre una variante del catálogo que ya existe.
Esa parte (`GET /vendedor/ofertas`, al final de este archivo) ya está
construida contra el modelo nuevo, con las ofertas viviendo en PostgreSQL
(tabla `oferta`) y el catálogo en Mongo.

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

**Solo `tienda@mesh.com`** (ver `helpers/constantes.ts`, `CORREO_TIENDA`) —
no cualquier vendedor, ni siquiera con `id_rol_usuario` 2: en el modelo
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
stock inicial — y ahí sí, cualquier vendedor, incluida la tienda.

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

Cuando el token ni siquiera tiene rol vendedor (por ejemplo, un comprador).

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

## PATCH /vendedor/productos/:id

**Solo `tienda@mesh.com`**, igual que `POST /vendedor/productos` — mismo
404 genérico para cualquier otro vendedor. Edita cualquier campo que tenga
sentido cambiar: `nombre`, `descripcion`, `estado`, `id_categoria`,
`caracteristicas_adicionales`, `caracteristicas_personalizadas` y
**`variantes`** — sí, las variantes se editan aquí mismo, como un campo
más del producto, no en una ruta aparte. Sin precio ni stock, igual que al
crear: eso se edita en la oferta (`PATCH /vendedor/ofertas/:id`), nunca
aquí.

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

Un producto de otro vendedor da el mismo 404 que un id que no existe — no
hay forma de usar esta ruta para confirmar que productos tiene otra
persona.

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

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo actualizar el producto", "payload": null }
```

---

## GET /vendedor/productos

Todos los productos del vendedor logueado, **en cualquier estado**
(`borrador`, `activo` e `inactivo` — a diferencia del catálogo público, que
oculta `borrador` e `inactivo`). Es el panel de "mis productos": el
vendedor tiene que poder ver y administrar los que todavía no ha
publicado, no solo los que ya están activos. Ordenados por
`fecha_creacion`, más reciente primero. Sin paginación ni filtros — trae
todos de una vez.

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

### 401 / 403 / 503 / 500

Mismos casos que las demás rutas de `/vendedor/productos` (ver arriba).

---

## GET /vendedor/productos/:id

Un producto propio tal como está **hoy**, con todos sus detalles (el mismo
documento completo que devuelven las rutas de creación y edición). A
diferencia del catálogo público (que no tiene una ruta de detalle por id
todavía, y de cualquier forma solo mostraría productos `activo`), esta
funciona sin importar el estado — sirve justo para ver un producto propio
en `borrador` o `inactivo` antes de publicarlo.

Un producto de otro vendedor da el mismo 404 que un id que no existe.

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

Reconstruye un producto propio **como estaba en una fecha específica**:
toma el evento de creación y todos los de modificación anteriores a esa
fecha (o de ese mismo día), en orden, y los fusiona uno encima del otro.

**Se arma con el framework de agregación de Mongo, no en el código del
backend**: la búsqueda, el orden y la fusión de eventos pasan dentro de un
pipeline de `db.productos_eventos.aggregate(...)` (`$match`, `$sort`,
`$group`, `$reduce`, `$mergeObjects`) — el backend solo valida el id y la
fecha, y le agrega el `_id` de vuelta al resultado.

Como cada evento aporta el estado completo de lo que cambió (`datos` en la
creación, `cambios` en cada modificación — nunca un campo suelto), fusionar
todos en orden con `$mergeObjects` reconstruye el documento exacto de ese
día: si algo cambió dos veces antes de la fecha pedida, se queda con el
valor de la segunda vez, porque se fusiona después y lo sobrescribe.

**Nunca trae `variantes[].stock`**, ni de la fecha pedida ni de hoy: el
stock no es parte de ningún evento (ver `cambios-etl-productos.md`), así
que reconstruir un producto a una fecha pasada no dice qué stock tenía en
ese momento — eso solo lo sabe el libro `stock_movimiento` en PostgreSQL.

Solo productos propios: un producto de otro vendedor da el mismo 404 que
un id que no existe. Una fecha anterior a la creación del producto también
da 404, con un mensaje distinto (el producto sencillamente no existía
todavía).

```
GET /vendedor/productos/52/historial?fecha=2026-01-07
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
{ "ok": false, "mensaje": "La fecha debe tener el formato AAAA-MM-DD", "payload": null }
{ "ok": false, "mensaje": "La fecha no es valida", "payload": null }
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

**Cualquier vendedor, no solo la tienda.** A diferencia de crear un
producto del catálogo (solo `tienda@mesh.com`), publicar una oferta sobre
un producto que ya existe es lo que cualquier cuenta con rol vendedor
puede hacer — es el corazón del modelo multi-vendedor. `POST
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

## GET /vendedor/ofertas/producto/:idProducto

Un producto completo del catálogo — misma forma que `GET /productos/:id`
(sin `ofertas`, que es una lista de vendedores para la ficha pública, no
para esto) — **pero sin excluir `inactivo`/`borrador`**: un vendedor tiene
que poder ver un producto oculto para decidir si le conviene ofertarlo,
aunque todavía no esté publicado. Cada variante trae `mi_oferta` embebida:
mi oferta sobre esa variante si tengo una, o `null` si no.

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
compartido. Cualquier vendedor, no solo la tienda — crear la variante
misma sigue siendo solo de `tienda@mesh.com` (`POST /vendedor/productos`),
pero ofertar sobre una que ya está publicada es lo que hace a alguien
vendedor en este modelo.

**Nace siempre `activa`** — sin aprobación previa de la tienda: eso quedó
pendiente de diseñar más adelante (fecha límite del profesor obligó a
priorizar el flujo directo primero, se retoma después). Y **nace siempre
con `stock = 0`**, nunca con `stock_inicial` puesto directo: el kardex
(`stock_movimiento`) tiene que explicar cada unidad, así que si viene
`stock_inicial > 0` se repone aparte, con `reponer_stock`, justo después
de que la oferta nazca.

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
    "estado": "activa",
    "fecha_creacion": "2026-08-25T17:10:24.348Z",
    "fecha_actualizacion": "2026-08-25T17:10:24.348Z"
  }
}
```

Misma forma que cada elemento de `GET /vendedor/ofertas`. Deja al día en
Mongo los cinco campos calculados del producto y la variante afectados
(`precio_tienda`/`precio_desde`/`stock_tienda`/`stock_total`/`total_ofertas`,
ver `ProductosService.recalcularCamposCalculados`).

Probado en vivo el 25 de agosto de 2026 contra la base real, con un
vendedor de prueba (`ventas.norte@mesh.com`): la oferta nace `activa` con
`id_estado_oferta = 1`, el kardex registra la reposición del
`stock_inicial` con `id_pedido NULL` y `id_usuario_modifico` del vendedor,
`precio_historial` registra el precio de nacimiento, y `total_ofertas`/
`stock_total` del producto en Mongo suben lo esperado.

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
- **`estado`** — un `UPDATE` sobre `oferta.id_estado_oferta`. Sin
  restricción sobre a cuál: el dueño maneja su oferta como quiera,
  incluido volver de `retirada` a `activa`.
- **`ajuste_stock`** — un entero con signo, nunca `0`. Positivo llama a
  `reponer_stock(..., 'reposicion', ...)` (sube el stock); negativo llama
  con `'ajuste'` y la magnitud (resta). Son los mismos dos motivos que
  `reponer_stock()` ya admitía fuera del flujo del pedido — la misma
  corrección manual (sube o baja) que existía en el modelo viejo de
  inventario, ahora sobre la oferta.

**Solo el dueño de la oferta** — una ajena da el mismo 404 genérico que
una que no existe, mismo criterio de siempre.

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
    "fecha_creacion": "2026-08-25T17:10:44.377Z",
    "fecha_actualizacion": "2026-08-25T17:18:46.987Z"
  }
}
```

Misma forma que `POST /vendedor/ofertas`. Deja al día en Mongo los cinco
campos calculados del producto y la variante afectados.

Probado en vivo el 25 de agosto de 2026 contra la base real: precio
(verificado que `precio_historial` registró la fila nueva), pausar y
reactivar, ajuste positivo (`reponer_stock` con `'reposicion'`) y negativo
(`'ajuste'`) — verificado el kardex fila por fila
(`reposicion +3 → 3`, `reposicion +5 → 8`, `ajuste -2 → 6`) — y que una
oferta ajena (probado contra la de `mesh_tienda`) da 404 sin tocar nada.

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
```

Mensaje de `reponer_stock()` tal cual, cuando el ajuste negativo deja el
stock por debajo de 0.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
{ "ok": false, "mensaje": "No se pudo conectar con MongoDB", "payload": null }
```

### 500

```json
{ "ok": false, "mensaje": "No se pudo actualizar la oferta", "payload": null }
```
