# Endpoints del buscador

El motor de busqueda de la Entrega 3 (Elasticsearch, la quinta base). Detalle
del indice, el analizador y el ETL que lo carga en `elastic/README.md` (fuera
de `backend/`, no se toca desde aca) -- esto solo documenta la ruta.

Código: `src/controllers/buscador/productos.controller.ts` +
`src/services/buscador/productos.service.ts`.

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

**200**

```json
{
  "ok": true,
  "mensaje": "Busqueda completada",
  "payload": [
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
  ]
}
```

`estado` en esta ruta **siempre** dice `"activo"` -- viaja en la respuesta
solo para que la forma sea igual a la de `/admin` (mas abajo), no porque
aca pueda variar.

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
el filtro de estado** -- trae cualquier producto, en cualquier estado.
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
