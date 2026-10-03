# Plan pendiente — Cola de comentarios por indexar (`evento_comentario`)

> **Estado (2026-10-02): etapas 1 (tabla y triggers) y 2 (worker) HECHAS y
> probadas en local, con el backend corriendo. Falta la ruta de búsqueda, y la
> migración real y el ETL del índice (le tocan a quien lleva `migrations/` y
> `etl/`).** Sin la migración, el worker falla: no existe `evento_comentario`.
> Sin el índice `mesh_comentarios` (mapping de referencia:
> `comentarios-indice.json`, este folder), también.

## El problema

Los vectores de productos ya viven en Elasticsearch
(`cambio_propuestas/2026-10-02_2010-vectores-a-elasticsearch.md`). Se quiere lo
mismo para el texto de las reseñas y de sus respuestas: poder buscar por
significado ("reseñas que dicen que se rompió rápido"). Para eso hace falta que
cada comentario nuevo o cambiado llegue solo a Elasticsearch, con su vector.

## Decisión: cola propia, igual que `evento_producto`

No se amplió `evento_grafo`:

- Es la cola de Neo4j: una fila por id de **reseña**, y el worker del grafo la
  consume. Un segundo consumidor sobre la misma fila se estorbaría con el
  primero.
- Sus triggers solo miran `resena`. Las respuestas cuelgan de otro comentario
  (`comentario.id_comentario_padre`), no de una reseña, así que nunca
  dispararían nada ahí.

`evento_comentario` es el hermano de `evento_producto`: misma forma, mismo
`UPSERT`, una sola fila pendiente por comentario, y el worker marca
`procesado_en` solo si `fecha` no cambió mientras trabajaba. Sin FK a
propósito, para ver el id de un comentario ya borrado.

SQL de referencia, aplicado en local: `evento-comentario.sql` (este folder).

## Etapas

### Etapa 1 — Tabla y triggers (HECHA en local)

| Pieza | Qué hace |
|---|---|
| `evento_comentario` | `id_evento`, `id_comentario`, `fecha`, `procesado_en`, `intentos`, `ultimo_error` |
| `uq_evento_comentario_pendiente` | Índice único parcial (`WHERE procesado_en IS NULL`): una pendiente por comentario |
| `trg_comentario_al_indice` | Sobre `comentario`: `INSERT`, `DELETE` y `UPDATE OF comentario` (solo el texto) |
| `trg_resena_al_indice_comentario` | Sobre `resena`: `INSERT`, `DELETE` y `UPDATE OF calificacion, id_producto_mongo`; encola el comentario **raíz** (`resena.id_comentario`) |

Decisiones:

- **El `UPDATE` de `comentario` mira solo la columna `comentario`.** Los likes y
  dislikes (`cantidad_likes`, `cantidad_dislikes`) no entran en el vector y
  cambian todo el tiempo; si el trigger los mirara, cada like encolaría un
  comentario.
- **La calificación y el producto viven en `resena`, no en `comentario`.** Van
  en el documento de la raíz, así que un cambio en `resena` re-encola la raíz.
- **El alta de una reseña encola la raíz por los dos triggers**; no estorba, el
  `UPSERT` los junta en una sola fila.

Probado en local (todo dentro de una transacción con `ROLLBACK`, la cola quedó
en 0):

| Caso | Pendientes |
|---|---|
| Un like sobre la raíz | 0 (no encola) |
| Cambio de texto de la raíz | 1 |
| Otro cambio de texto, misma raíz | 1 (se juntan) |
| Cambio de texto de una respuesta | 2 |
| Cambio de calificación de la reseña (raíz ya pendiente) | 2 |
| Raíz marcada procesada y luego un cambio nuevo | la raíz tiene 1 procesada + 1 pendiente |
| Alta de una respuesta | +1 |
| Baja de esa respuesta | la misma fila pendiente, sin duplicar |
| Tras el `ROLLBACK` | 0 |

El archivo también corrió dos veces seguidas sin error (idempotente).

### Etapa 2 — El worker (HECHA en local)

`EventoComentarioSyncService` (`services/resenas/evento-comentario-sync.service.ts`),
un `@Interval` aparte de 10 s, no el de `GrafoSyncService` ni el de
`VectoresSyncService` (Neo4j caído u Ollama lento no deben frenar al otro).
Misma mecánica que `EventoProductoSyncService`:

1. Toma las pendientes (`FOR UPDATE SKIP LOCKED`, tope por corrida).
2. Mira si el comentario **todavía existe**: no existe → borra el documento de
   `mesh_comentarios`; existe → lo indexa. No hace falta guardar "alta" o
   "baja" en la fila.
3. Para indexar, sube por `id_comentario_padre` hasta la raíz (una CTE
   recursiva) para saber de qué reseña y de qué producto es, y toma de
   `resena` la calificación.
4. Compara el hash del texto con el `vector_hash` del documento, y solo llama
   a Ollama si cambió (igual que `VectoresSyncService`). La llamada a Ollama
   se sacó a un helper compartido, `helpers/vectores-ollama.ts`
   (`pedirVectores`, `md5`, `LOTE_VECTORES`, `DIMENSIONES_VECTOR`), que usan los
   dos workers.
5. Escribe todo con un solo `_bulk` de `update` parciales (`doc_as_upsert`) y de
   `delete`.
6. Marca `procesado_en` solo si `fecha` sigue siendo la leída; los que fallan
   suben `intentos` y `ultimo_error`. Si Ollama no responde, no cuenta como
   intento: el comentario se reintenta en la próxima corrida.

Decisiones ya tomadas para esa etapa:

- Índice **aparte**, `mesh_comentarios`, no dentro de `mesh_productos`: las
  reseñas son muchas más y cambian más.
- Las respuestas **no copian la calificación** de la raíz (si cambia, habría
  que refrescar todo el hilo). Guardan solo el `id_producto` y el id de la
  raíz.
- Las respuestas de menos de 15 caracteres ("gracias") casi no tienen
  significado: se indexan para la búsqueda de texto pero **sin vector**. La
  raíz de una reseña siempre lleva vector. Si el texto de una respuesta se
  acorta, el worker le quita el vector que tenía.
- La raíz de un comentario cuya reseña no existe no se indexa (y se borra su
  documento si lo hubiera).

### Etapa 3 — Índice, carga inicial y búsqueda

- **Mapping de `mesh_comentarios` (HECHO en local, a mano):** el texto,
  `id_comentario_padre`, `id_raiz`, `id_resena`, `id_producto`, `id_usuario`,
  `es_respuesta`, `calificacion` (solo en la raíz), la fecha, `vector`,
  `vector_hash` y `vector_modelo`. Referencia: `comentarios-indice.json`.
- **Carga inicial (HECHA en local).** Los 125 comentarios que ya existían no
  tenían evento. Se encolaron una sola vez, con el worker ya funcionando:

  ```sql
  INSERT INTO evento_comentario (id_comentario)
  SELECT id_comentario FROM comentario
  ON CONFLICT (id_comentario) WHERE procesado_en IS NULL DO NOTHING;
  ```

- **Falta:** una ruta de búsqueda sobre reseñas (kNN, con el producto como
  filtro).

## Pendiente fuera de `backend/` (le toca al compañero)

- La migración real con `evento-comentario.sql`, después de la última migración
  real (hoy `033_sin_llaves_viejas_de_fraude.sql`).
- El mapping de `mesh_comentarios` (`comentarios-indice.json`) en
  `elastic/`, su creación y carga inicial en el ETL (el `INSERT` de arriba, que
  encola los comentarios existentes, o un `_bulk`), y el orden de arranque en
  `arrancar.ps1`: el índice tiene que existir antes de que arranque el
  backend, porque el worker no lo crea.

## Fuera de alcance de esta etapa

- Los likes y dislikes no se indexan (si algún día se quiere ordenar por
  utilidad, el trigger tendría que mirar esas columnas, con el costo de arriba).
- El API actual solo inserta comentarios y da likes: no tiene ruta para editar
  ni borrar un comentario. Los triggers de `UPDATE` y `DELETE` quedan puestos
  por si aparece, igual que en `evento_grafo`.
