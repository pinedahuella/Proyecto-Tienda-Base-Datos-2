# Endpoints del buscador

El motor de busqueda de la Entrega 3 (Elasticsearch, la quinta base). Detalle
del indice, el analizador y el ETL que lo carga en `elastic/README.md` (fuera
de `backend/`, no se toca desde aca) -- esto solo documenta la ruta.

Código: `src/controllers/buscador/productos.controller.ts` +
`src/services/buscador/productos.service.ts`.

Hay seis rutas: la búsqueda por nombre (`GET /buscador/productos`), la de admin
(`.../admin`), el buscador facetado (`.../facetado`), el autocompletado
(`.../sugerencias`), desde 2026-10-02 la **búsqueda por intención**
(`.../intencion`), que busca por significado y no por palabras, y desde 2026-10-04
la **búsqueda híbrida** (`.../hibrida`), que junta palabras y significado en una
sola lista. Las secciones "Cuándo usar cuál", dentro de estas dos últimas, dicen
cuál elegir.

`GET /buscador` (la comprobacion de conexion con Elasticsearch, mismo patron
que `GET /db`, `/documental`, `/clave-valor` y `/grafo`) esta documentada en
`endpoints.md`, no aca.

---

## El indice es un RESUMEN, no el producto completo

El documento que guarda Elasticsearch (`mesh_productos`) trae solo lo que
hace falta para **encontrar y ordenar**: `nombre`, `descripcion`, `estado`,
`categoria`, `precio_desde`, `precio_tienda`, `stock_total`,
`resenas_promedio`, `resenas_total` y los nombres de las variantes. No trae
imagenes, caracteristicas ni el detalle de cada variante.

Por eso estas rutas devuelven el mismo resumen, uno por producto
encontrado, y no el producto entero. Para el detalle completo de un
resultado, el siguiente paso siempre es `GET /productos/:id` contra
MongoDB, que sigue siendo la fuente de verdad del catalogo -- copiar el
documento entero aca duplicaria mantenimiento sin ninguna ganancia, porque
nada de eso se usa desde el buscador.

El indice es una PROYECCION, igual que el grafo de Neo4j, pero con una
diferencia importante desde el 2026-09-04: **guarda TODOS los estados**
(`activo`, `inactivo`, `borrador`, `en_revision`, `rechazado`), no solo lo
publico. Lo que separa lo publico de lo que ve un admin no es el indice, es
cual de las dos rutas de abajo se llama -- ver
`cambio_propuestas/2026-09-04_2208-elastic-indexar-todos-los-estados.md`.

**Como se mantiene al dia:** cada vez que el backend crea o edita un
producto (`ProductosVendedorService`) o recalcula sus precios/stock/notas
(`ProductosService.recalcularUnProducto`), el documento de Mongo se marca
con `pendiente_busqueda: true`. Un worker (`BuscadorSyncService`, cada 10 s)
lee los pendientes, los reindexa en Elasticsearch y les quita la marca.
Detalle completo en
`cambio_propuestas/2026-09-04_2124-pendiente-busqueda-cola-elastic.md` y
`2026-09-04_2237-worker-y-rutas-buscador.md`.

---

## GET /buscador/productos

**Pública**, sin sesión -- igual que el resto del catálogo (`/productos`).
Busca por **palabras**; para buscar por lo que se quiere lograr ("mi ventana
está muy solitaria") está `GET /buscador/productos/intencion`, más abajo.
**Siempre** trae solo productos `activo`: el filtro va fijo en
`BuscadorProductosService.buscar()` (`bool.filter` sobre `estado`), no es
un query param y no se le puede pedir que lo quite. Para ver cualquier otro
estado esta `GET /buscador/productos/admin`, mas abajo.

| Query param | Obligatorio | Qué hace |
|---|---|---|
| `nombre` | sí | El texto a buscar. Con difusa (`fuzziness: AUTO`, tolera errores de tecleo) y sin distinguir tildes (analizador `espanol_llano`), sobre `nombre` (con más peso), `descripcion` y `variantes` |
| `limite` | no | Cuántos resultados como máximo. Por defecto 20, tope 50 |
| `sesion` | no | Solo para el evento de analítica `busqueda_realizada` en ClickHouse (`elementos Generales/plan pendiente/eventos-clickhouse.md`). La genera el navegador, igual que en `POST /eventos/vista`. Si no viene, la búsqueda funciona igual -- simplemente no se registra el evento |

```
GET /buscador/productos?nombre=labtop
GET /buscador/productos?nombre=ambár&limite=5
GET /buscador/productos?nombre=laptop&sesion=sesion-generada-en-el-navegador
```

**200** -- desde 2026-10-04 el `payload` es un objeto, ya no una lista sola
(ver "Tal vez quisiste decir" abajo):

```json
{
  "ok": true,
  "mensaje": "Busqueda completada",
  "payload": {
    "resultados": [
      {
        "id_producto": 5,
        "nombre": "Laptop Nimbo 13",
        "estado": "activo",
        "categoria": "Laptops",
        "precio_desde": 3779,
        "precio_tienda": 4100,
        "stock_total": 62,
        "resenas_promedio": 0,
        "resenas_total": 0
      }
    ],
    "quisiste_decir": null
  }
}
```

`estado` en esta ruta **siempre** dice `"activo"` -- viaja en la respuesta
solo para que la forma de cada resultado sea igual a la de `/admin` (mas
abajo), no porque aca pueda variar.

### Tal vez quisiste decir (agregado 2026-10-04)

`quisiste_decir` es el texto escrito con las palabras mal escritas ya
corregidas, o `null` si no hay nada que corregir. **La busqueda se hace con lo
que la persona escribio**, no con la correccion: la difusa (`fuzziness`) ya
encuentra productos con un error de tecleo, y `quisiste_decir` solo le avisa
a la pantalla que puede ofrecer "¿Quisiste decir **laptop**?".

```
GET /buscador/productos?nombre=labtop         -> quisiste_decir: "laptop"
GET /buscador/productos?nombre=telefno movil  -> quisiste_decir: "telefono movil"
GET /buscador/productos?nombre=laptop         -> quisiste_decir: null
GET /buscador/productos?nombre=xyzqwk         -> quisiste_decir: null (no se parece a nada)
GET /buscador/productos?nombre=zapatos comodos -> quisiste_decir: null (bien escritas, aunque no esten en el catalogo)
```

Como funciona (`helpers/correccion-busqueda.ts`):

- Va **dentro de la misma consulta** a Elasticsearch (bloque `suggest`), no
  hay una segunda peticion. Usa el *term suggester* sobre `nombre`, con
  `suggest_mode: missing`: solo sugiere para palabras que no existen en
  ningun nombre, y solo para palabras de 3 letras o mas.
- **Solo a una letra de distancia** (`max_edits: 1`, desde el 2026-10-17): una
  de mas, una de menos, una cambiada o dos cambiadas de lugar. Con 2, una
  palabra bien escrita que no esta en el catalogo se "corregia" a otra
  ("comodos" salia "comedor"). Los errores de tipeo reales son de una
  (labtop, camiza, audifnos, impermiable, laptpo); uno con dos ("labtpo") se
  queda sin sugerencia, pero la busqueda difusa igual lo encuentra.
- **El plural no es un error**: "zapatos" no se corrige a "zapato" (+s o +es,
  sin mirar tildes).
- **No toca el mapeo ni el ETL**: `espanol_llano` solo pasa a minusculas y
  quita tildes, asi que lo que sugiere son palabras reales del catalogo.
- Solo corrige **hacia palabras que ya estan en el indice**. Una palabra que
  no se parece a nada ("televisro", "xyzqwk") se queda como esta y no hay
  sugerencia.
- Cambia solo las palabras mal escritas; las demas quedan como las escribio la
  persona (`telefno Cuarzo` -> `telefono Cuarzo`). La palabra corregida sale
  en minusculas y sin tilde, porque asi esta en el indice.

Limites aceptados:

- El indice guarda **todos los estados**, asi que la palabra sugerida puede
  venir de un producto que no esta activo (por ejemplo un borrador). Resolverlo
  pediria un campo aparte en el mapeo.
- Una palabra bien escrita que solo aparece en una descripcion y se parece a
  una palabra de un nombre podria recibir una sugerencia. Es un "tal vez": no
  cambia lo que se busca.

**Cambio de forma**: antes el `payload` era la lista de resultados; ahora es
`{ resultados, quisiste_decir }`. Solo cambia esta ruta: `/admin` sigue
devolviendo la lista sola, y `/facetado` ya devolvia un objeto (solo se le
suma el campo `quisiste_decir`).

**400**, si no viene `nombre` (o viene vacío):

```json
{ "ok": false, "mensaje": "Escribe el nombre del producto que buscas", "payload": null }
```

**503**, si Elasticsearch no responde:

```json
{ "ok": false, "mensaje": "No se pudo completar la busqueda", "payload": null }
```

---

## GET /buscador/productos/admin

**Solo admin** (`SesionGuard` + `@Roles(ID_ROL_ADMIN)`). Ni la tienda: es
un vendedor mas, mismo criterio que ya usa `GET /admin/fraude/anillos`.

Mismos query params que la ruta pública (`nombre`, `limite`), pero **sin
el filtro de estado** -- trae cualquier producto, en cualquier estado. Sigue
devolviendo la **lista sola** en el `payload` y **no** trae `quisiste_decir`
(ese campo es solo de la ruta pública y de `/facetado`).
Pensada para revisar el catálogo completo, incluyendo lo que no circula
(propuestas en revisión, rechazadas, pausadas).

```
GET /buscador/productos/admin?nombre=labtop
```

**200** -- aquí `estado` sí puede ser cualquiera:

```json
{
  "ok": true,
  "mensaje": "Busqueda completada",
  "payload": [
    {
      "id_producto": 12,
      "nombre": "...",
      "estado": "inactivo",
      "categoria": "...",
      "precio_desde": null,
      "precio_tienda": null,
      "stock_total": 0,
      "resenas_promedio": 0,
      "resenas_total": 0
    }
  ]
}
```

**401**, sin sesión. **403**, con sesión pero sin rol admin (por ejemplo, la
tienda). Mismos `400`/`503` que la ruta pública.

---

## GET /buscador/productos/facetado (agregado 2026-09-26)

**Pública**, sin sesión, **siempre** solo `activo` (mismo filtro fijo que
`GET /buscador/productos`). Puerto directo de
`elastic/pruebas/facetas.py::consulta()`/`facetas()` a TypeScript
(`BuscadorFacetadoService`, `controllers/buscador/facetado.controller.ts`)
-- misma consulta a Elasticsearch, cambia solo el lenguaje.

Cuatro facetas: **categoría, precio, calificación y disponibilidad**. Cada
una se agrega con los filtros de las OTRAS ya aplicados (nunca el suyo
propio) -- elegir una opción no hace desaparecer las demás del panel. Las
opciones se suman con OR dentro de una faceta, con AND entre facetas
distintas.

| Query param | Obligatorio | Qué hace |
|---|---|---|
| `nombre` | **no** | A diferencia de la búsqueda simple, puede venir vacío o ausente -- sirve para navegar solo por facetas, sin texto (decisión del usuario, 2026-09-26) |
| `categoria` | no | Ids de categoría separados por coma: `categoria=7,9` |
| `precio` | no | Claves de rango separadas por coma: `hasta-250`, `250-500`, `500-1000`, `1000-3000`, `desde-3000` |
| `calificacion` | no | Claves separadas por coma: `4-o-mas`, `3-o-mas` (se contienen: si se eligen las dos, vale la más baja) |
| `disponible` | no | Cualquier valor no vacío cuenta como elegido (ej. `disponible=si`) -- filtra `stock_total > 0` |
| `limite` | no | Cuántos resultados como máximo. Por defecto 20, tope 50 -- **no afecta ni `total` ni las facetas**, solo cuántos `resultados` vienen |
| `sesion` | no | Igual que en la búsqueda simple: evento de analítica en ClickHouse, ver `endpoints-eventos.md`. Si no viene, no se registra nada |

```
GET /buscador/productos/facetado?nombre=laptop&categoria=7,9&precio=250-500,500-1000&calificacion=4-o-mas&disponible=si&limite=50&sesion=...
GET /buscador/productos/facetado?categoria=7          <- navegar solo por faceta, sin texto
```

**200**

```json
{
  "ok": true,
  "mensaje": "Busqueda completada",
  "payload": {
    "resultados": [ "...mismo resumen que GET /buscador/productos..." ],
    "total": 217,
    "quisiste_decir": null,
    "facetas": {
      "categoria":    [{ "id": 7, "nombre": "Laptops", "cantidad": 217 }],
      "precio":       [{ "clave": "250-500", "cantidad": 12 }],
      "calificacion": [{ "clave": "4-o-mas", "cantidad": 3 }],
      "disponible": 215
    }
  }
}
```

`quisiste_decir` es lo mismo que en la búsqueda simple (ver "Tal vez
quisiste decir", arriba, desde 2026-10-04): el texto con las palabras mal
escritas corregidas, o `null`. Es `null` también cuando `nombre` viene vacío.

`total` es el total real de la búsqueda (`hits.total.value`), sin importar
`limite`. `facetas.disponible` es un número (cuántos de los resultados
totales tienen existencias), no un arreglo -- es la única faceta que no es
un "top N" de opciones.

**503**, si Elasticsearch no responde -- mismo mensaje que la búsqueda
simple. Esta ruta **no valida nada antes de llamar al servicio** (a
diferencia de la simple, que exige `nombre`): cualquier combinación de
query params, incluso todos vacíos, es una petición válida.

**Se registra en ClickHouse** (`busqueda_realizada`) igual que
`GET /buscador/productos`, pero con `facetada: true` y las cuatro facetas
elegidas -- detalle completo de las columnas nuevas y las pruebas en
`endpoints-eventos.md`, sección "Registro de `busqueda_realizada`".

### Bug real encontrado y corregido durante las pruebas: `nombre` vacío daba 0 resultados

Un `multi_match` de Elasticsearch con `query: ''` no es "sin filtro de
texto" -- es "no encuentra nada". Probado en vivo: `GET
/buscador/productos/facetado?categoria=7` (sin `nombre`) daba `total: 0`,
rompiendo justo el caso de uso que se había decidido soportar (navegar
solo por facetas). Corregido en `construirConsulta()`: con `nombre` vacío
se usa `match_all` en vez de `multi_match`.

### Probado en vivo -- 2026-09-26

Contra Elasticsearch real (102 productos activos del catálogo).

| Caso | Resultado |
|---|---|
| `?nombre=laptop` (sin facetas) | `total: 11` (7 laptops + 4 coincidencias difusas de otras categorías, mismo comportamiento ya conocido de la búsqueda simple) |
| `?nombre=laptop&categoria=7` | `total: 7`; la faceta `categoria` **no cambia** respecto a sin el filtro (excluye su propio filtro); `precio`/`calificacion` **sí cambian** (ya solo cuentan sobre las 7 laptops) |
| `?nombre=laptop&categoria=7&precio=250-500,500-1000` | `total: 0` (ninguna laptop cae en ese rango -- las 7 son `desde-3000`, confirmado por la faceta de precio del caso anterior); la faceta `categoria` reflejó solo las categorías de los productos que SÍ caen en ese rango de precio (sin exigir `categoria=7`) |
| `?nombre=laptop&calificacion=4-o-mas` | `total: 5`; faceta `calificacion` sin cambiar (4:5, 3:6); `categoria`/`precio` recortadas a esos 5 |
| `?categoria=7` (sin `nombre`, tras la corrección) | `total: 7` -- confirma el bug de arriba resuelto |
| sin ningún query param | `total: 102` (todo el catálogo activo), `resultados: 20` (el límite por defecto) |
| `?limite=9999` | `resultados` topado en `50`, `total` sin cambiar (102) |
| `?limite=0` / `?limite=-5` | caen al defecto, `resultados: 20` |
| `?nombre=zzqxwabc123` (control, sin sentido) | `total: 0`, las cuatro facetas vacías/0 |
| Evento en ClickHouse, con `sesion` | fila real en `busqueda_realizada` con `facetada: 1` y las cuatro facetas exactas que se mandaron (ver `endpoints-eventos.md` para la tabla completa) |
| Evento en ClickHouse, sin `sesion` | ninguna fila -- igual que la búsqueda simple |
| `GET /buscador/productos` (regresión, sin tocar) | sigue registrando `facetada: 0` con arreglos vacíos, sin cambiar su comportamiento |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

---

## GET /buscador/productos/sugerencias (agregado 2026-09-26)

El autocompletado del buscador -- distinto del resto: no busca con
`fuzziness` (para cuando ya se terminó de escribir), sugiere nombres
**mientras se escribe**. Puerto de
`elastic/pruebas/facetas.py::autocompletar()`
(`BuscadorSugerenciasService`, `controllers/buscador/sugerencias.controller.ts`).

Usa `multi_match` con `type: bool_prefix` sobre `nombre.escribiendo` (campo
`search_as_you_type` que ya trae el mapeo, sin usar hasta ahora) y sus
variantes `_2gram`/`_3gram`. **Pública**, siempre `estado: activo`.

| Query param | Obligatorio | Qué hace |
|---|---|---|
| `prefijo` | sí | Lo que se lleva escrito -- string no vacío |
| `limite` | no | Por defecto 8, tope 20 (mas bajo que el buscador normal: es una lista desplegable, no una pagina de resultados) |

```
GET /buscador/productos/sugerencias?prefijo=lap&limite=8
```

**200**

```json
{
  "ok": true,
  "mensaje": "Sugerencias obtenidas",
  "payload": [{ "id_producto": 5, "nombre": "Laptop Nimbo 13" }]
}
```

**400**, sin `prefijo` (o vacío):

```json
{ "ok": false, "mensaje": "Escribe al menos una letra para sugerir", "payload": null }
```

**503**, si Elasticsearch no responde -- mismo mensaje que las demás rutas
del buscador.

### Probado en vivo -- 2026-09-26

| Caso | Resultado |
|---|---|
| `?prefijo=lap` | las 7 laptops del catálogo, todas empiezan con "Laptop" |
| `?prefijo=la` (mas corto) | mezcla de nombres cuya alguna palabra empieza en "la" -- "Lampara...", "La casa de...", "Laptop..." -- `bool_prefix` compara por PALABRA, no por el nombre completo |
| `?prefijo=labtop` (error de tecleo, control) | `[]` -- a diferencia de la búsqueda normal, el autocompletado **no corrige errores**, es prefijo exacto |
| sin `prefijo` / `prefijo=` | `400` "Escribe al menos una letra para sugerir" |
| `?prefijo=lap&limite=1` | 1 resultado |
| `?prefijo=a&limite=999` | topado en `20` |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

## GET /buscador/productos/intencion (agregado 2026-10-02)

La **búsqueda por intención**: la persona dice lo que quiere lograr, con sus
palabras ("mi ventana está muy solitaria"), y se le muestran productos cuyas
**reseñas o descripción se parecen en significado**, aunque no compartan ni una
palabra. Con la reseña de una maceta que dice "decora muy bien la ventana", esa
frase encuentra la maceta, cosa que `GET /buscador/productos` (que busca
palabras) no puede hacer.
(`BuscadorIntencionService`, `controllers/buscador/intencion.controller.ts`.)

### Cuándo usar cuál

| Quiero... | Ruta |
|---|---|
| Encontrar un producto del que sé el nombre (con errores de tecleo) | `GET /buscador/productos?nombre=` |
| Completar el nombre mientras escribo | `GET /buscador/productos/sugerencias?prefijo=` |
| Filtrar el catálogo por categoría, precio o nota | `GET /buscador/productos/facetado` |
| Encontrar algo por lo que quiero lograr o por cómo lo usaría | **`GET /buscador/productos/intencion?q=`** |
| Un cuadro de búsqueda que entienda nombres **y** frases, en una sola lista | `GET /buscador/productos/hibrida?q=` |

### Cómo funciona

La frase se convierte en un vector con el mismo modelo de Ollama
(`paraphrase-multilingual`, 768 dimensiones) que ya vectoriza el catálogo y las
reseñas, y se hacen dos búsquedas de vecinos en PostgreSQL (pgvector, desde el
2026-10-16; antes eran kNN de Elasticsearch):

1. **Sobre las reseñas** (`vector_comentario` con `resena`; solo las raíz, no las
   respuestas, y de calificación `calificacion_minima` o más; las 100 más
   cercanas). Es la fuente principal: la gente cuenta para qué le sirvió algo, y
   así se busca. También es la que dice **por qué** salió un producto (`motivo`).
2. **Sobre los productos activos** (`vector_producto`): nombre, categoría y
   descripción; los 50 más cercanos.

Se juntan por producto: el `puntaje` es el mayor de los dos parecidos (0 a 1, coseno)
y por él se ordena. Cada parecido tiene un **umbral** por debajo del cual no
cuenta (0,45 para reseñas, 0,40 para productos; son constantes del servicio): sin
él, la búsqueda devolvería siempre algo, aunque fuera ruido. Lo que se muestra de
cada producto (nombre, precio, estrellas) sale de su documento en `mesh_productos`
(Elasticsearch), que de paso confirma que siga activo.

**Pública**, sin sesión. **Siempre** trae solo productos `activo`: el filtro va
fijo en el código, igual que en `GET /buscador/productos`, y se comprueba también
para los productos que salen solo por una reseña.

| Query param | Obligatorio | Qué hace |
|---|---|---|
| `q` | sí | Lo que la persona quiere, con sus palabras. No vacío, hasta 250 caracteres (tope propio de esta ruta, no cambia con el de las reseñas: el modelo ve 512 tokens) |
| `limite` | no | Cuántos resultados como máximo. Por defecto 10, tope 30 |
| `calificacion_minima` | no | De 1 a 5. Solo cuentan las reseñas con esa nota o más. Por defecto 4: se busca lo que a otros les funcionó |

```
GET /buscador/productos/intencion?q=mi ventana esta muy solitaria
GET /buscador/productos/intencion?q=me duele la espalda de estar sentado todo el dia&limite=5
GET /buscador/productos/intencion?q=mi ventana esta muy solitaria&calificacion_minima=1
```

**200**

```json
{
  "ok": true,
  "mensaje": "Productos obtenidos",
  "payload": [
    {
      "id_producto": 40,
      "nombre": "Farol solar de jardin Luciernaga",
      "estado": "activo",
      "categoria": "Iluminacion",
      "precio_desde": 203,
      "precio_tienda": 203,
      "hay_descuento": false,
      "stock_total": 64,
      "resenas_promedio": 3.5,
      "resenas_total": 2,
      "puntaje": 0.582,
      "origen": ["resenas", "producto"],
      "motivo": {
        "id_resena": 182,
        "calificacion": 5,
        "comentario": "Lo puse en la ventana de mi cuarto y la decora muy bien, ya no se ve tan sola ni tan vacia.",
        "similitud": 0.582
      },
      "resenas_coincidentes": 1,
      "similitud_resenas": 0.582,
      "similitud_producto": 0.431
    }
  ]
}
```

Los campos hasta `resenas_total` son los mismos que devuelve
`GET /buscador/productos`. Los nuevos:

| Campo | Qué es |
|---|---|
| `puntaje` | El mayor entre `similitud_resenas` y `similitud_producto`. Por aquí se ordena |
| `origen` | De dónde viene la coincidencia: `resenas`, `producto`, o las dos |
| `motivo` | La reseña más cercana a lo pedido (`id_resena`, `calificacion`, `comentario`, `similitud`), o `null` si el producto salió solo por su descripción. Sirve para mostrar "por qué te lo recomendamos" |
| `resenas_coincidentes` | Cuántas reseñas del producto pasan del umbral |
| `similitud_resenas` | El parecido de la mejor reseña, o `null` si ninguna pasó el umbral |
| `similitud_producto` | El parecido con el nombre, la categoría y la descripción del producto, o `null` |

Una búsqueda sin coincidencias suficientes devuelve `200` con `payload: []`, no
un error.

**400**

```json
{ "ok": false, "mensaje": "Escribe lo que quieres lograr o buscar", "payload": null }
{ "ok": false, "mensaje": "La busqueda no puede tener mas de 250 caracteres", "payload": null }
{ "ok": false, "mensaje": "La calificacion minima debe ser un numero entero de 1 a 5", "payload": null }
```

**503**, si PostgreSQL, Elasticsearch u Ollama no responden (`"No se pudo
conectar con PostgreSQL"` / `"No se pudo conectar con Elasticsearch"` / `"No se
pudo conectar con Ollama"`). A diferencia de `GET /buscador/productos`, esta ruta
**necesita Ollama en cada búsqueda**, para convertir la frase en vector (espera
hasta 8 s).

### De vuelta a pgvector -- probado 2026-10-16

Mismas 15 frases (y cada una con `calificacion_minima=3`) contra el código
anterior (Elasticsearch) y el nuevo, con los mismos vectores copiados. Los
productos que salen son los mismos salvo en el borde del `limite` (por ejemplo,
4 de 30 en `q=candado`), y los parecidos se mueven hasta 0,01: el índice de
Elasticsearch (`int8_hnsw`) cuantizaba los vectores, y pgvector calcula el coseno
exacto (ver la prueba de `GET /productos/:id/similares` en
`endpoints-productos.md`). Forzando el índice HNSW (`enable_seqscan=off`) sale lo
mismo que con el recorrido exacto, salvo el orden entre resultados con el mismo
`puntaje`.

| Caso | Resultado |
|---|---|
| `q=mi ventana esta muy solitaria&limite=3` por HTTP | `200` |
| `q=` vacío | `400` |
| PostgreSQL apagado | `503` "No se pudo conectar con PostgreSQL" |
| Elasticsearch apagado | `503` "No se pudo conectar con Elasticsearch" |

### Probado en vivo -- 2026-10-02 (con Elasticsearch)

Contra el servidor, Elasticsearch y el Ollama reales. El catálogo **no tiene
ninguna maceta**: el ejemplo se probó con una reseña de prueba, escrita a
propósito, sobre un producto de decoración que sí existe (el farol solar de
jardín). Las reseñas de prueba (cuatro, de cuentas de prueba) se borraron al
terminar.

| Caso | Resultado |
|---|---|
| `q=mi ventana esta muy solitaria` | el farol primero, `puntaje` 0,582, `origen` reseñas + producto, con `motivo` "Lo puse en la ventana de mi cuarto y la decora muy bien..." |
| `q=me duele la espalda de estar sentado todo el dia` | la silla ergonómica, 0,64, solo por su reseña ("Mi espalda ya no me duele después de ocho horas...") |
| `q=quiero preparar bebidas rapido` | la cafetera (0,57, solo por descripción) y la licuadora (0,533, reseña + descripción, con su `motivo`) |
| `q=xyzzy qwerty asdf` (sin sentido) | `200` con `[]` |
| `q=mi ventana esta muy solitaria&calificacion_minima=1` | la reseña de 2 estrellas ("se ve bonito en la ventana pero dejó de funcionar...") también cuenta, y el farol sube a 0,613 |
| `q=` vacío o con espacios | `400` |
| `calificacion_minima=9` | `400` |
| `q=un regalo para mi mama que le gusta cocinar` | los productos de Cocina, solo por descripción |
| `q=quiero leer una historia de aventuras` | los de Literatura |
| `npx tsc --noEmit` y `npx eslint` | limpios |

### Límites conocidos

- **Los umbrales se calibraron a mano con unas pocas frases**, no con datos
  reales. Los de los productos dan parecidos más bajos que los de las reseñas,
  porque una descripción comercial se parece menos a una frase de una persona.
- **Por descripción hay ruido.** `q=quiero preparar bebidas rapido` también
  devolvió dos perfumes (0,52), y `q=mi ventana esta muy solitaria` una silla de
  comedor y un monitor (0,46): el modelo no está hecho para "pregunta contra
  documento", sino para comparar frases parecidas. Lo que sale por una **reseña**
  es mucho más confiable, y por eso el `motivo` es lo que hay que mostrar.
- Las reseñas de los datos del generador usan solo 20 textos distintos y casi
  todas hablan de envío o de empaque, así que con ellas la ruta casi no
  encuentra nada por intención. Va a lucir con reseñas reales y variadas (el
  compañero cambia el generador).
- Cuando un producto no sale aunque debería (por ejemplo, "organizar mis libros en
  la sala" no devolvió el librero), es el modelo, no un filtro: no hay forma de
  forzarlo desde aquí.
- No registra el evento `busqueda_realizada` de analítica, a diferencia de
  `GET /buscador/productos`.

## GET /buscador/productos/hibrida (agregado 2026-10-04)

La **búsqueda híbrida**: junta en una sola lista ordenada la búsqueda por
**palabras** (la de `GET /buscador/productos`, en Elasticsearch) y la búsqueda por
**significado** (vectores en PostgreSQL, como `.../intencion`). Es la ruta para un buscador "normal" que además
entiende frases: `labtop gamer` encuentra por las palabras, `algo para escuchar
música mientras corro` encuentra por el significado, y las dos caben en el mismo
cuadro de búsqueda.
(`BuscadorHibridoService`, `controllers/buscador/hibrida.controller.ts`,
`dto/buscar-hibrida.ts`.)

**Pública**, sin sesión. **Siempre** solo productos `activo`, fijo en el código
como en `GET /buscador/productos`.

| Query param | Obligatorio | Qué hace |
|---|---|---|
| `q` | sí | Lo que la persona escribió: palabras o una frase. No vacío, hasta 250 caracteres (el modelo de vectores ve 512 tokens) |
| `limite` | no | Cuántos resultados como máximo. Por defecto 20, tope 50 |

```
GET /buscador/productos/hibrida?q=laptop
GET /buscador/productos/hibrida?q=algo para escuchar musica mientras corro&limite=10
```

**200**

```json
{
  "ok": true,
  "mensaje": "Busqueda completada",
  "payload": {
    "modo": "hibrida",
    "resultados": [
      {
        "id_producto": 6,
        "nombre": "Laptop Bastion 16",
        "estado": "activo",
        "categoria": "Laptops",
        "precio_desde": 9606,
        "precio_tienda": 10052,
        "hay_descuento": false,
        "stock_total": 61,
        "resenas_promedio": 1,
        "resenas_total": 1,
        "puntaje": 0.977,
        "origen": ["texto", "significado"],
        "posicion_texto": 4,
        "posicion_significado": 1,
        "puntaje_texto": 8.733,
        "similitud": 0.743
      }
    ]
  }
}
```

Cada resultado trae el mismo resumen que `GET /buscador/productos` y, además, lo
que explica por qué salió:

| Campo | Qué es |
|---|---|
| `puntaje` | El puntaje combinado, de 0 a 1 (1 = primero en las dos búsquedas). **Por aquí se ordena.** Es relativo a esta búsqueda: sirve para comparar resultados entre sí, no con los de otra búsqueda |
| `origen` | Por dónde salió: `texto`, `significado`, o los dos |
| `posicion_texto` | Su lugar en la búsqueda por palabras (1 = el mejor), o `null` si no salió por ahí |
| `posicion_significado` | Su lugar en la búsqueda por significado (1 = el más cercano), o `null` |
| `puntaje_texto` | La relevancia de Elasticsearch en la búsqueda por palabras, o `null` |
| `similitud` | El parecido de significado con lo escrito, de 0 a 1 (coseno), o `null` |

`modo` dice cómo se hizo la búsqueda: **`hibrida`** (palabras + significado) o
**`solo_texto`**, cuando Ollama no respondió o PostgreSQL falló en la búsqueda
por significado, y se contestó solo con las palabras (en ese caso todos los
`origen` son `["texto"]` y `similitud` es `null`). Así la búsqueda principal no
se cae porque un servicio de apoyo esté apagado.

**400**

```json
{ "ok": false, "mensaje": "Escribe lo que buscas", "payload": null }
{ "ok": false, "mensaje": "La busqueda no puede tener mas de 250 caracteres", "payload": null }
```

**503**, si Elasticsearch no responde: `"No se pudo conectar con Elasticsearch"`.

### Cómo funciona

1. **Por palabras:** el `multi_match` difuso de `GET /buscador/productos`
   (tolera errores de tecleo, sin tildes, `nombre` pesa más que `descripcion` y
   `variantes`), pero **más estricto**: con una o dos palabras deben estar todas, y
   con más, el 70 % (`minimum_should_match: 2<70%`). Sin eso, una frase se llenaba
   de productos que solo comparten "para" o "algo" y le ganaban a la búsqueda por
   significado. Se piden 50 candidatos.
2. **Por significado:** la frase se convierte en vector (el mismo modelo de
   Ollama que usan los productos) y se piden los 50 productos activos más
   cercanos a `vector_producto` (PostgreSQL, pgvector). Los de coseno menor a
   **0,40** se descartan: por debajo es ruido. Lo que se muestra de cada uno sale
   de su documento en `mesh_productos`, igual que en la búsqueda por palabras.
3. **Se combinan por posición, no por puntaje** (RRF, *reciprocal rank
   fusion*, constante 60): cada búsqueda aporta `1 / (60 + posición)` y se suman.
   El puntaje de relevancia de las palabras y el coseno están en escalas
   distintas y no se pueden sumar. Un producto que sale bien en las dos sube; uno
   que sale en una sola queda donde esa lo pone. Se hace en el servicio y no con
   el `retriever` rrf de Elasticsearch porque ese es de licencia de pago.

### Cuándo usar cuál

| Quiero... | Ruta |
|---|---|
| Un cuadro de búsqueda que entienda nombres **y** frases | **`GET /buscador/productos/hibrida?q=`** |
| Buscar por nombre, con filtros por categoría, precio o nota | `GET /buscador/productos/facetado` |
| Completar el nombre mientras escribo | `GET /buscador/productos/sugerencias?prefijo=` |
| Saber **por qué** algo sirve (con la reseña que lo dice) | `GET /buscador/productos/intencion?q=` |

### Probado en vivo -- 2026-10-04

Contra el servidor y el catálogo local (102 productos):

| Caso | Resultado |
|---|---|
| `q=laptop` | `200`, `modo: hibrida`, las 5 laptops primero, todas por `texto` + `significado` (puntaje 0,95 a 0,98) |
| `q=labtop gamer` | `200`: la laptop gamer por palabras (a pesar del error) y un monitor gamer por significado |
| `q=algo para escuchar musica mientras corro` | `200`, solo por `significado` (las palabras no llegan al 70 %): unos tenis, un rodillo y unos audífonos deportivos |
| `q=telefono con buena camara` | `200`: el teléfono que coincide por palabras (Nautilo Pro) sube a 0,98 por salir en las dos; los demás teléfonos entran por significado |
| `q=xyzqwk` | `200`, `resultados: []` |
| `q=` (vacío), sin `q`, `q` de 300 caracteres | `400` |
| Ollama apagado | no se probó apagándolo; el camino `solo_texto` está en el código (`vectorDe` devuelve `null`) |

### De vuelta a pgvector -- probado 2026-10-16

Las mismas 15 frases contra el código anterior (Elasticsearch) y el nuevo, con
los mismos vectores copiados. Los resultados por significado coinciden con el
coseno exacto calculado aparte (en `q=candado`, `q=tapete yoga` y `q=mantener el
cafe caliente en la oficina`); con Elasticsearch no coincidían, por la
cuantización de su índice. Por eso cambian algunas posiciones y, en el borde del
`limite`, algún resultado.

| Caso | Resultado |
|---|---|
| `q=candado para bicicleta&limite=3` por HTTP | `200`, `modo: hibrida` |
| PostgreSQL apagado | `200`, `modo: solo_texto` (el log dice por qué) |
| Elasticsearch apagado | `503` "No se pudo conectar con Elasticsearch" |

### Límites conocidos

- **El modelo de vectores es el mismo de la búsqueda por intención, con los mismos
  límites**: no está hecho para "pregunta contra documento", así que con frases la
  parte de significado tiene ruido. En la prueba de la música, los audífonos
  deportivos quedaron tercero, detrás de unos tenis. Con datos reales y variados
  va a mejorar; el umbral de 0,40 se calibró a mano.
- **Las dos búsquedas pesan igual.** Si en la práctica manda mucho una, se puede
  cambiar sin tocar nada más (`RRF_K` y el peso de cada lista en `combinar`).
- Con una sola palabra suelta el vector dice poco y manda la búsqueda por palabras.
- No registra el evento `busqueda_realizada` de analítica, a diferencia de
  `GET /buscador/productos` y `.../facetado`.
- No trae `quisiste_decir` ni facetas; para eso están las otras rutas.

---

## Una cosa que conviene saber antes de leer resultados raros

La difusa busca a la vez en tres campos (`nombre`, `descripcion`,
`variantes`), así que a veces engancha coincidencias que no tienen que ver:
medido con `nombre=labtop`, salieron las siete laptops del catálogo **y
además** una lámpara y una sandalia, porque alguna palabra de su
descripción o de sus variantes cayó dentro de la distancia de edición que
permite `fuzziness: AUTO`. No es un error -- es el costo esperable de
buscar difuso en más de un campo -- pero si algún día hay que afinar la
relevancia (bajarle peso a `descripcion`/`variantes`, o subir el mínimo de
coincidencia), es el primer lugar donde mirar.
