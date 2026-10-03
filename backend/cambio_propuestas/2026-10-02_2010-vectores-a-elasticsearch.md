# Vectores de productos: de pgvector (PostgreSQL) a `dense_vector` en Elasticsearch

**Fecha:** 2026-10-02.
**Alcance:** `backend/`. En local, el mapping de `mesh_productos` está
**ampliado a mano** (`PUT _mapping`); el mapping real (`elastic/001_indice.json`),
los ETL y la limpieza de PostgreSQL le tocan al resto del equipo (ver
"Pendiente fuera de `backend/`").

## Por qué

Se quiso darle a Elasticsearch un uso más allá del texto (autocompletado,
corrección con `fuzziness` y facetas ya existían). Se comprobó antes que el
Elasticsearch del compose (8.15.3) soporta `dense_vector` con kNN, con filtro
y en la misma consulta que el texto (búsqueda híbrida). El vector se **mueve**,
no se duplica: deja de vivir en `producto_vector` (pgvector) y pasa a vivir en
el documento de `mesh_productos`.

Esto reemplaza la decisión de usar pgvector (ADR-10 de la Entrega final). La
justificación y las preguntas de sustentación que la mencionan hay que
reescribirlas (ver el final).

## Qué se hizo en `backend/`

### 1. Campos nuevos en el documento de `mesh_productos`

| Campo | Tipo | Qué guarda |
|---|---|---|
| `vector` | `dense_vector`, 768 dims, `index: true`, `similarity: cosine` | El embedding de Ollama (`paraphrase-multilingual`) |
| `vector_hash` | `keyword` | md5 de `"nombre. Categoria X. descripcion"` (el mismo texto y hash de siempre) |
| `vector_grupo` | `keyword` | md5 de `"categoria\|descripcion"` (las copias del generador que solo cambian el nombre) |
| `vector_modelo` | `keyword` | El modelo que lo calculó |

El "activo" ya no se guarda aparte: es el `estado` que ya tiene el documento.

### 2. `VectoresSyncService` escribe en Elasticsearch

`services/productos/vectores-sync.service.ts`. Misma bandera `pendiente_vector`
de Mongo y mismo intervalo (3 h). Cambia el destino:

- Lee `vector_hash` y `vector_grupo` del documento con un `mget`.
- Hash distinto: pide el vector a Ollama (lotes de 32) y lo guarda con un
  `_bulk` de actualizaciones **parciales** (solo los 4 campos de arriba).
- Hash igual y grupo distinto: solo actualiza `vector_grupo`, sin Ollama.
- Si el documento no existe todavía en el índice, deja el producto pendiente.

### 3. `BuscadorSyncService` pasa de `index` a `update`

`services/buscador/buscador-sync.service.ts`: `update` con `doc_as_upsert`.
Con `index` cada reindexado reemplazaba el documento entero y borraba el
vector. Ahora cada worker toca solo sus campos.

### 4. `SimilaresService` consulta Elasticsearch

`services/productos/similares.service.ts` (`GET /productos/:id/similares`).
Lee el vector del producto base, hace una búsqueda `knn` (`k` 200,
`num_candidates` 400) con filtro `estado: activo`, sin el propio producto y
sin su mismo `vector_grupo`, se queda con uno por grupo y corta en 6. Mismas
reglas que `productos_similares()`. `similitud = 2 * puntaje - 1` (Elasticsearch
puntúa `(1 + coseno) / 2`), la misma escala que daba pgvector. Mongo sigue
enriqueciendo la tarjeta. Sin vector o sin documento: `[]`. Elasticsearch
caído: `503`.

## Probado (local, 2026-10-02)

Elasticsearch 8.15.3, MongoDB y el Ollama real, 102 productos.

| Caso | Resultado |
|---|---|
| Los 102 marcados `pendiente_vector` y una corrida del worker | `102 recalculado(s)`, ~16 s, 102 documentos con `vector`, 0 pendientes |
| Producto 1: hash, grupo y vector contra `producto_vector` | idénticos |
| `BuscadorSyncService` sobre el producto 1 | conserva el vector |
| Similares del producto 1 | los mismos 6 que pgvector; se cruzan dos casi empatados (3 y 7); similitudes a menos de 0,002 (el índice cuantiza a int8) |
| Similares del producto 50 | los mismos 6 y en el mismo orden |
| Similares de un id inexistente | `[]` |

## Pendiente fuera de `backend/`

Todo esto es del resto del equipo. Lo de `etl/` es lo que hace falta para que
una máquina nueva arranque entera.

### A. `elastic/001_indice.json` — agregar los 4 campos al mapping

Dentro de `mappings.properties`:

```json
"vector": {
  "type": "dense_vector",
  "dims": 768,
  "index": true,
  "similarity": "cosine"
},
"vector_hash": { "type": "keyword" },
"vector_grupo": { "type": "keyword" },
"vector_modelo": { "type": "keyword" }
```

Sin esto, `etl/cargar_busqueda.sh` (que borra y recrea el índice con ese
mapping) deja un índice **sin** el campo, y la escritura del vector fallaría.
Hay que volver a probarlo en una máquina limpia.

### B. `etl/cargar_vectores.ps1` — escribir en Elasticsearch, no en PostgreSQL

Hoy calcula el vector con Ollama y hace `INSERT INTO producto_vector` por
`psql`. Tiene que producir lo mismo, pero en el documento de `mesh_productos`:

- El texto, el `hash` y el `grupo` se calculan **igual** (no cambian). Lo
  único que cambia es dónde se guardan y dónde se lee lo que ya hay.
- Lo que ya hay (paso 3): en vez de `SELECT ... FROM producto_vector`, leer
  `vector_hash` y `vector_grupo` de Elasticsearch (`_search` con
  `_source: ["vector_hash","vector_grupo"]` y `size` grande, o `_mget` por
  ids).
- Guardar (paso 4): en vez de `INSERT ... ON CONFLICT`, un `_bulk` de
  actualizaciones parciales, una por producto:

  ```
  {"update":{"_index":"mesh_productos","_id":"<id>"}}
  {"doc":{"vector":[...768 numeros...],"vector_hash":"<md5>","vector_grupo":"<md5>","vector_modelo":"paraphrase-multilingual"}}
  ```

  Mismo cuidado que `cargar_busqueda.sh`: `_bulk` contesta `200` aunque
  documentos sueltos fallen, hay que revisar `errors` en la respuesta.
- Los que cambiaron solo de grupo: `{"doc":{"vector_grupo":"<md5>"}}`.
- Los que ya no están en Mongo: no hace falta borrar nada aparte, el documento
  se va con el índice.
- Conteo final (paso 5): contar con `_count` y `{"exists":{"field":"vector"}}`
  y compararlo con los productos de Mongo, en vez de `count(*)` en PostgreSQL.
- Reglas que ya cumple y hay que mantener: sin tuberías a `docker exec`
  (BOM), números con cultura invariante, 768 dimensiones comprobadas.

**Orden de arranque:** el vector se escribe en un documento que ya tiene que
existir, así que `cargar_vectores.ps1` va **después** de `cargar_busqueda.sh`
en `arrancar.ps1` (hoy se llama en la línea ~2850). Y cada vez que se
reconstruye el índice con `cargar_busqueda.sh` se pierden los vectores:
hay que volver a correr `cargar_vectores.ps1 -Todo`.

### C. `demo-entrega-final.ps1` — ya no puede mirar `producto_vector`

Las líneas ~176 a ~280 cuentan filas de `producto_vector`, piden el plan de
`productos_similares()` y buscan `Index Scan using idx_producto_vector_hnsw`.
Hay que cambiarlas por: documentos con `vector` en `mesh_productos`
(`_count` con `exists`), y la prueba de que la consulta usa el índice
(kNN de Elasticsearch, p. ej. con `profile: true` o midiendo el tiempo).

### D. PostgreSQL: retirar `producto_vector` y `productos_similares()`

Ya no los usa el backend. Una migración nueva (no editar la 024 ni la 027, ya
corrieron) con `DROP FUNCTION productos_similares(bigint, int)` y
`DROP TABLE producto_vector`. Mejor dejarla **para el final**, cuando A, B y C
estén probados, por si hay que volver atrás. La imagen
`pgvector/pgvector:pg18` del compose podría volver a `postgres` a secas, pero
conviene decidirlo con calma (cambiar la imagen toca el volumen).

### E. Documentación y sustentación

- `docs/ARQUITECTURA.md` (ADR-10, líneas ~281 a ~286), `docs/BACKEND-PENDIENTE.md`
  (~315 y ~355), `contenido-entrega-final.json` (sección 2.1 "Por qué pgvector"),
  `docs/diagrama-arquitectura.drawio` y `PREGUNTAS-SUSTENTACION.md`
  (alrededor de la 116 en adelante): hablan de pgvector, `producto_vector`,
  el índice HNSW de PostgreSQL y las cifras 3,8 ms contra 32 ms y 3099 de 3103.
  Esas cifras son de pgvector y ya no aplican al sistema nuevo; si se quieren
  cifras equivalentes hay que medirlas de nuevo sobre Elasticsearch.
- Argumento nuevo para el ADR: una sola consulta combina texto, vector y
  filtros (búsqueda híbrida), y un solo documento y un solo índice en vez de
  una tabla aparte. Alternativas descartadas: seguir con pgvector (dos copias
  de los ids y dos motores para buscar).

## Pendiente de `backend/` (opcional)

- Hacer que `VectoresSyncService` corra una vez al arrancar, como
  `MasVendidosSyncService`, en vez de esperar las 3 h (útil tras reconstruir
  el índice).
- Búsqueda híbrida (texto + kNN) en `GET /buscador/productos`, y vectores de
  reseñas. No se tocaron: se acordó hacer primero el cambio de similares.
