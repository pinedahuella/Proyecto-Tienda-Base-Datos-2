# Cola de comentarios por indexar (`evento_comentario`): primer paso para buscar reseñas por significado en Elasticsearch

**Fecha:** 2026-10-02.
**Alcance:** `backend/`. Esquema nuevo en PostgreSQL y un índice nuevo en
Elasticsearch que **en local están aplicados a mano**; la migración real y el
ETL del índice le tocan al resto del equipo (ver "Pendiente fuera de
`backend/`"). Incluye el worker que vacía la cola (segunda parte, abajo).

## Por qué

Los vectores de productos ya viven en Elasticsearch
(`2026-10-02_2010-vectores-a-elasticsearch.md`). Se quiere lo mismo para el
texto de las reseñas y el de sus respuestas, que cuelgan unas de otras
(`comentario.id_comentario_padre`). Para que cada comentario llegue solo a
Elasticsearch, con su vector, hace falta una cola que avise del cambio dentro
de la misma transacción.

## Qué se hizo

Tabla `evento_comentario` y dos triggers, con el mismo diseño que
`evento_producto`: una sola fila pendiente por comentario (`UPSERT`), sin FK, y
el worker marca `procesado_en` solo si `fecha` no cambió mientras trabajaba.

- `trg_comentario_al_indice` sobre `comentario`: alta, baja y cambio del
  **texto** (los likes y dislikes no la activan).
- `trg_resena_al_indice_comentario` sobre `resena`: alta, baja y cambio de
  `calificacion` o `id_producto_mongo`; encola el comentario raíz de la reseña.

No se amplió `evento_grafo`: es la cola de Neo4j (una fila por id de reseña, y
la consume su worker), y sus triggers solo miran `resena`, así que las
respuestas nunca la dispararían.

SQL de referencia, idempotente: `elementos Generales/plan pendiente/evento-comentario.sql`.
Plan con las etapas siguientes y las decisiones cerradas:
`plan pendiente/evento-comentario.md`.

## Probado (local)

El SQL corrió dos veces seguidas sin error. Con datos reales, dentro de una
transacción con `ROLLBACK` (la cola quedó en 0):

| Caso | Resultado |
|---|---|
| Un like sobre la raíz | no encola |
| Cambio de texto de la raíz, dos veces | una sola pendiente |
| Cambio de texto de una respuesta | segunda pendiente |
| Cambio de calificación con la raíz ya pendiente | sigue en 2 |
| Raíz procesada y luego un cambio | 1 procesada y 1 pendiente nueva |
| Alta y baja de una respuesta | una sola fila pendiente, sin duplicar |

## Segunda parte: el worker y el índice `mesh_comentarios`

### Qué se hizo

- `services/resenas/evento-comentario-sync.service.ts`
  (`EventoComentarioSyncService`, registrado en `app.module.ts`), `@Interval`
  de 10 s. Vacía `evento_comentario`: mira si el comentario todavía existe (si
  no, borra el documento), sube por `id_comentario_padre` hasta la raíz para
  saber de qué reseña y producto es, y lo indexa en `mesh_comentarios` con un
  solo `_bulk` de `update` parciales.
- Compara el md5 del texto con el `vector_hash` del documento y **solo llama a
  Ollama si cambió**. Una respuesta de menos de 15 caracteres se indexa sin
  vector. La calificación va solo en la raíz.
- `helpers/vectores-ollama.ts`: la llamada a Ollama (`pedirVectores`), `md5` y
  las constantes se sacaron de `VectoresSyncService` a un helper que usan los
  dos workers. El comportamiento de `VectoresSyncService` no cambió.
- Índice nuevo `mesh_comentarios`. Mapping de referencia:
  `plan pendiente/comentarios-indice.json`. Variable de entorno nueva
  `ELASTIC_INDICE_COMENTARIOS` (en `.env.example`).

### Probado (local, con el backend corriendo)

| Caso | Resultado |
|---|---|
| Los 125 comentarios existentes encolados | `125 al dia, 125 vector(es) calculados`, 0 errores. 97 raíces y 28 respuestas; ninguna respuesta lleva calificación |
| kNN sobre `mesh_comentarios` con "se rompió muy rápido, mala calidad" | devuelve las reseñas de calificación 1 y 2 sobre mal estado y empaque |
| Cambio de texto de la raíz | cambia el `vector_hash`, 1 vector calculado |
| Cambio de calificación de la reseña | el documento se actualiza (5 a 2) sin llamar a Ollama |
| Respuesta corta ("gracias") | indexada, sin vector |
| Respuesta larga | indexada, con vector |
| Borrar las dos respuestas | `2 borrados del indice`, ya no aparecen |
| Revertir los cambios de prueba | cola en 0 pendientes, 125 en PostgreSQL y 125 en el índice |

## Pendiente

**Fuera de `backend/` (le toca a quien lleva el ETL y las migraciones):**

- El mapping de `mesh_comentarios` (`plan pendiente/comentarios-indice.json`)
  en `elastic/`, y que el ETL cree el índice **antes** de que arranque el
  backend: el worker no lo crea. Sin el índice el worker falla.
- La carga inicial de los comentarios que ya existan: encolarlos con el
  `INSERT` de `evento-comentario.md`, o un `_bulk` directo.
- La migración real con `evento-comentario.sql`, después de la última migración
  real (hoy `033_sin_llaves_viejas_de_fraude.sql`). Sin ella, el worker falla.

**De `backend/`:**

- La ruta de búsqueda sobre reseñas (kNN, con el producto como filtro).
