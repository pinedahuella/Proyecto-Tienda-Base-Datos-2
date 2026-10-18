# Plan pendiente — Todos los vectores a PostgreSQL (pgvector)

> **Estado (2026-10-16): HECHO en `backend/` y probado en local, con el backend
> corriendo. Falta lo de otros: la migración real (`vectores-pgvector.sql`, este
> folder), el ETL de vectores de productos, retirar `mesh_comentarios` y los
> campos de vector de `mesh_productos` en `elastic/`, scripts y docs — ver
> "Lo que le toca a otros".** Sin las dos tablas, el backend no tiene de dónde
> leer ni dónde escribir vectores.

## Qué cambia

A pedido del profesor, todas las consultas por vectores pasan a PostgreSQL con
pgvector. Elasticsearch se queda con lo que es suyo: la búsqueda por palabras de
`mesh_productos` (difusa, sugerencias, facetas, "quisiste decir") y el log de
autenticación. Deja de guardar vectores y deja de tener un índice de comentarios.

| Antes (Elasticsearch) | Ahora (PostgreSQL) |
|---|---|
| Campos `vector`, `vector_hash`, `vector_grupo`, `vector_modelo` de `mesh_productos` | Tabla `vector_producto` |
| Índice `mesh_comentarios` (texto, vector y valoración de cada comentario) | Tabla `vector_comentario`; el texto ya estaba en `comentario` |
| kNN de Elasticsearch | `ORDER BY vector <=> $1 LIMIT k` sobre un índice HNSW |
| Coseno de todas contra todas en Node (los detectores traían los vectores) | Lo calcula PostgreSQL (`paresParecidos()`); los vectores no salen de la base |
| Agregaciones `terms` + `bucket_selector` (notas incoherentes) | `GROUP BY` con `count(*) FILTER` |

## Las tablas

Las dos son 1 a 1 con la tabla que describen, con FK y `ON DELETE CASCADE`
(detalle y comentarios en `vectores-pgvector.sql`):

- **`vector_producto`** (`id_producto_mongo` → `producto_catalogo`): `vector`,
  `texto_hash`, `grupo`, `activo`, `modelo`, `fecha_calculo`. `activo` es copia
  de `estado = 'activo'` en Mongo: `producto_catalogo` no guarda el estado.
- **`vector_comentario`** (`id_comentario` → `comentario`): `vector`,
  `texto_hash`, `modelo`, `fecha_calculo` y la valoración (`valoracion_texto`,
  `prob_mala`, `valoracion_modelo`), que se calcula desde el vector y se borra
  cuando el vector cambia.

Índice HNSW con `vector_cosine_ops` en las dos.

## Decisiones

1. **Tablas aparte, no columnas en `comentario` ni en `producto_catalogo`.**
   Los triggers de `comentario` encolan en `evento_comentario` cada cambio del
   texto: si el worker escribiera el vector en la misma fila, se encolaría solo.
   Un vector pesa ~3 KB y haría más pesada cada lectura de reseñas. `texto_hash`,
   `modelo` y la valoración describen el cálculo, no el comentario. "Sin vector"
   es no tener fila. Y la FK con cascada se lleva el vector cuando se borra el
   comentario o el producto.
2. **No se llama `producto_vector`.** La 036 hace `DROP TABLE IF EXISTS
   producto_vector` y `arrancar.ps1` la vuelve a correr en cada arranque: una
   tabla con ese nombre desaparecería sola.
3. **`buscarCercanos()` fija `hnsw.ef_search` y `hnsw.iterative_scan`.** Con los
   valores por defecto de pgvector, una consulta que usa el índice HNSW revisa
   solo 40 candidatos y lo que descarta el filtro se pierde: en local, un
   `LIMIT 200` sobre `vector_producto` volvió con 39 filas. Dentro de una
   transacción (`set_config(..., true)`, no ensucia la conexión del pool) se sube
   `ef_search` a lo que era `num_candidates` en Elasticsearch y se activa
   `iterative_scan = strict_order`. Con tablas chicas PostgreSQL prefiere
   recorrerlas enteras (el resultado exacto); esto cuenta cuando crezcan.
4. **El vector va como parámetro (`$1::vector`), nunca como subconsulta.** Con
   `ORDER BY vector <=> (SELECT ...)` el planificador no usa el índice HNSW.
5. **`VectoresSyncService` corre cada 10 s (antes, cada 3 h).** `activo` decide
   qué productos salen en las búsquedas por significado, y antes lo daba el
   `estado` del documento, que `BuscadorSyncService` actualiza cada 10 s. Ollama
   solo se llama cuando cambia el texto.
6. **Lo que se muestra de un producto sale de `mesh_productos`.** Intención,
   híbrida y sugerencias piden a PostgreSQL los ids más cercanos y después el
   documento a Elasticsearch (nombre, precio, estrellas), que de paso confirma que
   siga `activo`. Similares, como siempre, lo pide a Mongo.
7. **Híbrida: si PostgreSQL falla, `modo: solo_texto`**, igual que cuando Ollama
   no responde. La búsqueda principal no se cae por el servicio de apoyo.
8. **La regla de largo (`MIN_CARACTERES`) se sigue contando en JavaScript**
   (`texto.trim().length`), igual que la validación de la reseña y la valoración:
   así las tres cuentan igual (un emoji ocupa dos, como en el resto del backend).
   SQL trae las reseñas y PostgreSQL compara los vectores.
9. **La fuente de las señales de texto sigue llamándose `elastic`** en el
   catálogo de señales. Es la que usan el puntaje, la regla `R-CASI-3` y la API
   (`fuente: "elastic"`); cambiarla sería otro cambio, con frontend y migración.
10. **`BuscadorSyncService` sigue con `update` + `doc_as_upsert`.** Ya no hace
    falta para no pisar el vector, pero tampoco estorba; solo se corrigió su
    comentario.

## Lo que hace el backend

| Archivo | Qué hace ahora |
|---|---|
| `helpers/vectores-pgvector.ts` (nuevo) | `aVectorPg`/`deVectorPg`, `buscarCercanos()` y `paresParecidos()` |
| `helpers/similitud-vectores.ts` | `marcarConGemela` y `agruparPorParecido` reciben pares; sin `norma`/`cosenoEntre`/`cosenoDePuntaje` |
| `helpers/manejar-error-db.ts` | Exporta `esFalloDeConexion` y `describirError` |
| `services/productos/vectores-sync.service.ts` | Escribe `vector_producto`; cada 10 s |
| `services/productos/similares.service.ts` | Vecinos en `vector_producto`; ya no usa Elasticsearch |
| `services/buscador/intencion.service.ts` | Vecinos en `vector_comentario` y `vector_producto` |
| `services/buscador/hibrida.service.ts` | Palabras en Elasticsearch, significado en `vector_producto` |
| `services/vendedores/sugerencias-propuesta.service.ts` | Vecinos en `vector_producto` |
| `services/resenas/evento-comentario-sync.service.ts` | Escribe `vector_comentario` desde la cola |
| `services/resenas/valoracion-comentarios.service.ts` | Valora en `vector_comentario` |
| `services/fraude/resenas-repetidas-detector.service.ts`, `resenas-parecidas-...`, `anillo-de-texto-...` | Reseñas de PostgreSQL, pares de `paresParecidos()` |
| `services/fraude/notas-incoherentes-detector.service.ts` | Agregación en SQL |
| `.env.example` | Sin `ELASTIC_INDICE_COMENTARIOS` |

Las respuestas de las rutas no cambian de forma. Lo documentado de cada una está
en `endpoints-productos.md`, `endpoints-buscador.md`, `endpoints-vendedores.md` y
`endpoints-fraude.md`; las pruebas, en
`cambio_propuestas/2026-10-16_2100-vectores-a-pgvector.md`.

## Lo que le toca a otros

- **Migración real** con `vectores-pgvector.sql` (después de la 039). Las dos
  tablas, sus índices y los comentarios de `evento_comentario`.
- **Una base que ya tiene vectores en Elasticsearch** (la local de cada uno, la
  compartida): correr una vez `vectores-pgvector-copiar.cjs` (este folder) después de
  la migración, antes de borrar `mesh_comentarios`. Copia los mismos números, sin
  Ollama. En local copió 1001 productos y 675 comentarios.
- **Una base nueva:** los comentarios no necesitan nada (la semilla los encola
  por los triggers de la 034 y el worker los calcula al arrancar). Los productos
  sí: `etl/cargar_vectores.ps1` tiene que escribir en `vector_producto` (mismo
  texto, `texto_hash`, `grupo` y `activo` que `VectoresSyncService`; el producto
  tiene que estar ya en `producto_catalogo`) en vez de en `mesh_productos`. La
  otra forma es marcar `pendiente_vector: true` en todo el catálogo de Mongo y
  dejar que el worker los calcule.
- **`elastic/`:** borrar `003_comentarios.json` y quitar los cuatro campos de
  vector de `001_indice.json`. `elastic/README.md`.
- **`arrancar.ps1`:** ya no crea ni llena `mesh_comentarios`, y ya no hace falta
  guardar los vectores en `mesh_productos_vectores_previos` antes de reconstruir
  el índice (viven en PostgreSQL y el índice se puede tirar sin perderlos).
  `etl/cargar_busqueda.sh`, lo mismo.
- **Scripts que leen los vectores o `mesh_comentarios` en Elasticsearch:**
  `demo-entrega-final.ps1`, `demo-resenas-texto.ps1` (espera las reseñas en
  `mesh_comentarios`), `pruebas/clasificador_en_elastic.mjs`,
  `pruebas/recomendacion_semantica.py`, `pruebas/vectores_worker.cjs`,
  `panel-comandos/servidor.mjs`. `pruebas/correr_detectores_resenas.cjs` sigue
  sirviendo (solo cambia su comentario).
- **Docs y sustentación:** el ADR-10 de `docs/ARQUITECTURA.md` vuelve a pgvector
  (el traslado a Elasticsearch del 2026-10-02 se revierte), `docs/base-de-datos.md`
  (dos tablas nuevas), los diagramas, `PREGUNTAS-SUSTENTACION.md` y los informes.
- Cada uno quita `ELASTIC_INDICE_COMENTARIOS` de su `backend/.env` (ya no se lee).

## Opcional, no se hizo

- El trigger `trg_resena_al_indice_comentario` encola los comentarios de una
  reseña también cuando cambia `calificacion` o `id_producto_mongo`: eso era para
  el documento de Elasticsearch. Ya no hace falta, pero no estorba (el hash no
  cambia y el worker no llama a Ollama). Se puede dejar solo con `INSERT OR
  DELETE`.
- `comentarios-indice.json` (este folder) ya no se usa.
- Renombrar la fuente `elastic` del catálogo de señales (ver decisión 9).
