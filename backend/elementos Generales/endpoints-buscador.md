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

El documento que guarda Elasticsearch (`mesh_productos`, cargado por
`etl/cargar_busqueda.sh` desde el catalogo de MongoDB) trae solo lo que hace
falta para **encontrar y ordenar**: `nombre`, `descripcion`, `categoria`,
`precio_desde`, `precio_tienda`, `stock_total`, `resenas_promedio`,
`resenas_total` y los nombres de las variantes. No trae imagenes,
caracteristicas ni el detalle de cada variante.

Por eso esta ruta devuelve el mismo resumen, uno por producto encontrado, y
no el producto entero. Para el detalle completo de un resultado, el
siguiente paso siempre es `GET /productos/:id` contra MongoDB, que sigue
siendo la fuente de verdad del catalogo -- copiar el documento entero aca
duplicaria mantenimiento sin ninguna ganancia, porque nada de eso se usa
desde el buscador.

El indice es una PROYECCION, igual que el grafo de Neo4j: se reconstruye
entera en cada corrida del ETL, y el backend solo la CONSULTA (nunca
escribe).

---

## GET /buscador/productos

**Pública**, sin sesión -- igual que el resto del catálogo (`/productos`).

| Query param | Obligatorio | Qué hace |
|---|---|---|
| `nombre` | sí | El texto a buscar. Con difusa (`fuzziness: AUTO`, tolera errores de tecleo) y sin distinguir tildes (analizador `espanol_llano`), sobre `nombre` (con más peso), `descripcion` y `variantes` |
| `limite` | no | Cuántos resultados como máximo. Por defecto 20, tope 50 |

```
GET /buscador/productos?nombre=labtop
GET /buscador/productos?nombre=ambár&limite=5
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

**400**, si no viene `nombre` (o viene vacío):

```json
{ "ok": false, "mensaje": "Escribe el nombre del producto que buscas", "payload": null }
```

**503**, si Elasticsearch no responde:

```json
{ "ok": false, "mensaje": "No se pudo completar la busqueda", "payload": null }
```

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
