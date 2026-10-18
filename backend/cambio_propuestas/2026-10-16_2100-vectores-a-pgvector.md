# Todos los vectores, de Elasticsearch a PostgreSQL (pgvector)

**Fecha:** 2026-10-16.
**Alcance:** `backend/`. En local, las dos tablas están aplicadas a mano
(`plan pendiente/vectores-pgvector.sql`) y los vectores copiados de
Elasticsearch (`plan pendiente/vectores-pgvector-copiar.cjs`); se pierden con
`.\arrancar.ps1 -Reiniciar`. Lo de fuera de `backend/` está en
`plan pendiente/vectores-pgvector.md`.

## Por qué

El profesor pidió que las consultas por vectores se hagan con pgvector. Revierte
`2026-10-02_2010-vectores-a-elasticsearch.md` y `2026-10-02_2130-cola-de-comentarios.md`
en cuanto a dónde viven los vectores; las reglas de cada señal y de cada búsqueda
no cambian.

## Qué se hizo

- Tablas `vector_producto` y `vector_comentario` (1 a 1, con FK y cascada, índice
  HNSW). Las decisiones (por qué tablas aparte, por qué no `producto_vector`, el
  ajuste de `hnsw.ef_search`/`iterative_scan`, el worker a 10 s) están en el plan.
- Los dos workers (`VectoresSyncService`, `EventoComentarioSyncService`) y
  `ValoracionComentariosService` escriben en PostgreSQL.
- Las cuatro búsquedas (similares, intención, híbrida, sugerencias) piden los
  vecinos a PostgreSQL con `buscarCercanos()`.
- Los tres detectores que comparaban vectores en Node le piden los pares a
  PostgreSQL (`paresParecidos()`); notas incoherentes es una agregación SQL.
- Documentado en `endpoints-productos.md`, `endpoints-buscador.md`,
  `endpoints-vendedores.md` y `endpoints-fraude.md`, con un aviso en los planes de
  las señales de texto y de la cola de comentarios.

## Cómo se probó

Contra PostgreSQL 18 con pgvector 0.8.6, Elasticsearch 8.15.3, MongoDB y el
Ollama reales. Primero, con el código **anterior**, se cargaron 50 reseñas de
prueba (cuentas `zzvec_*`) armadas para disparar cada señal de texto y sus
bordes, y se guardó lo que devolvía todo (con el registro de señales
interceptado, para no guardar nada). Después, con el código nuevo y los mismos
vectores copiados, lo mismo, y se compararon.

| Qué | Resultado |
|---|---|
| Los 4 detectores, pasada periódica | **Idénticos**: las mismas 7 señales, con las mismas reseñas de evidencia y el mismo `detalle` (porcentajes, similitud media y mínima) |
| El chequeo inmediato en 9 reseñas (gemela, sin gemela, contradictoria, fuera de ventana, corta, a 45 días) | **Idéntico** |
| Valoración de los 50 comentarios | **Idéntica** (texto, `prob_mala`, versión del modelo) |
| Vectores de los 51 comentarios de prueba recalculados con Ollama por el worker nuevo | coseno 1 y el mismo hash que los de Elasticsearch; los detectores vuelven a dar lo mismo |
| Similares de los 1103 productos, contra el coseno exacto calculado aparte | pgvector coincide en 1000 de 1001 (el otro es un empate a 4e-8), error máximo 2e-7. Elasticsearch coincidía en 317: su índice `int8_hnsw` cuantiza los vectores, con errores de hasta 0,016 |
| Intención (15 frases × 2), híbrida (15) y sugerencias (8) | los mismos resultados salvo en el borde del límite y el orden entre casi empates, por la misma cuantización; la parte por significado de la híbrida coincide con el coseno exacto |
| Las mismas búsquedas forzando el índice HNSW (`enable_seqscan=off`) | iguales al recorrido exacto (solo cambia el orden entre `puntaje` idénticos) |
| `LIMIT 200` sobre el índice HNSW sin / con los ajustes de `buscarCercanos()` | 39 / 200 filas |
| Una cuenta al 29,4 % de reseñas con gemela y, tras borrar una reseña distinta, al 31,3 % | sin señal / con señal (el borde del 30 %) |

Casos del worker de comentarios (todos bien): respuesta de menos de 15
caracteres sin vector; respuesta acortada pierde el vector y lo recupera al
alargarla; texto sin cambios no llama a Ollama ni toca la fila; texto nuevo de una
raíz borra la valoración y se revalora; si el vector cambia mientras se valora, la
valoración se salta (`0 valorados, 1 saltados`) y la próxima pasada la arregla;
una fila que falla suma `intentos` con su `ultimo_error` y no frena a las demás;
reseña borrada quita el vector del comentario que quedó sin reseña; comentario
borrado se va por la cascada; Ollama caído deja el evento pendiente sin sumar
intentos.

Casos del worker de productos (todos bien): marca sin cambios no llama a Ollama;
`inactivo` y de vuelta cambia `activo` sin Ollama; descripción cambiada da
hash, grupo y vector nuevos y, al restaurarla, los de antes (coseno 1); producto
sin vector se calcula igual al que había en Elasticsearch; producto que no está en
`producto_catalogo` se queda pendiente. Mongo quedó como estaba.

Por HTTP, con el backend corriendo: las cuatro rutas `200`, `400` sin texto,
`401` sin sesión en sugerencias. Con PostgreSQL apagado: similares, intención y
sugerencias `503` "No se pudo conectar con PostgreSQL", híbrida `200` en
`solo_texto`. Con Elasticsearch apagado: similares sigue en `200` (ya no lo usa),
las otras tres `503`. Al volver, todo responde sin reiniciar el backend.

`npx tsc --noEmit` y `nest build` limpios. Las reseñas y cuentas de prueba se
borraron (también sus documentos en `mesh_comentarios`).

## Encontrado de paso

- La documentación de la híbrida decía que el `503` de Elasticsearch era "No se
  pudo completar la busqueda"; el mensaje real es "No se pudo conectar con
  Elasticsearch". Corregido.
- Con PostgreSQL apagado, el log de la híbrida salía con el motivo vacío (el
  driver lanza un `AggregateError`, sin `message`). Ahora usa `describirError()`.
