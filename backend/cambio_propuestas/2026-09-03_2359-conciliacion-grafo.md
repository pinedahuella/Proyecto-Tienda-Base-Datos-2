# Cambio: `GET /admin/grafo/conciliacion` — la red de seguridad de la sincronización del grafo

**Fecha aproximada:** 2026-09-03, noche.
**Alcance:** solo `backend/`. No tocó migraciones, Mongo, `etl/` ni `neo4j/`.

Es el **paso 1** del plan `elementos Generales/plan pendiente/outbox-grafo.md`
y lo que el profesor pidió como "un job que lo reconcilie de ser
necesario". Se hace primero porque es barato, sirve solo (aunque el worker
del outbox no exista todavía) y hace visible el problema que el worker
resuelve.

## Qué hace

`GET /admin/grafo/conciliacion` (solo admin, no la tienda). Compara los
conteos de PostgreSQL (la verdad) contra Neo4j (la proyección del grafo de
fraude) y devuelve un informe. **No repara** — para eso está
`etl/cargar_grafo.sh --limpiar`.

Compara seis recursos; cuatro cuentan para el veredicto `cuadra`:

| Recurso | cuenta para `cuadra` |
|---|---|
| reseñas (`count(*) FROM resena` vs `:Resena`) | sí |
| relaciones `ESCRIBIO` / `CALIFICA_A` / `SOBRE` (cada una = nº reseñas) | sí |
| productos reseñados (`count(DISTINCT id_producto_mongo)` vs `:Producto`) | no |
| usuarios con reseña (autores ∪ vendedores vs `:Usuario`) | no |

Productos y usuarios no cuentan para el veredicto porque el worker
incremental puede dejar nodos huérfanos y el ETL completo carga **todos**
los usuarios (no solo los que aparecen en una reseña) — un `diferencia > 0`
ahí es normal.

Además devuelve el estado de la cola del outbox (`evento_grafo`):
`pendientes`, `apartados` (`intentos >= 5`), `ultima_sincronizacion`
(`max(procesado_en)`) y la lista de eventos apartados. **Si la tabla
`evento_grafo` todavía no existe** (la migración `015` la hace el
compañero), esos campos van `null`/`[]` y la comparación PG↔Neo4j sigue
funcionando.

`sugerencia` es una frase lista para la pantalla: qué falta y qué hacer.

## Archivos nuevos

- `src/models/grafo.ts` — `ConciliacionGrafo`, `FilaConciliacion`,
  `EstadoColaGrafo`, `EventoGrafoApartado`.
- `src/services/grafo/grafo-sync.service.ts` — `GrafoSyncService.conciliar()`.
  El worker del outbox (`@Interval`) se agregará a esta misma clase.
- `src/controllers/grafo/grafo.controller.ts` — `GrafoController`, prefijo
  `admin/grafo`, `@Roles(ID_ROL_ADMIN)`.
- Registrados en `app.module.ts`.

Sin cambios de esquema. La consulta a Neo4j usa seis `CALL {}` de
agregación (cada uno devuelve una fila aunque su etiqueta esté vacía — con
`MATCH` suelto un label sin nodos cortaría la consulta). Sesión en modo
READ, como el resto del backend contra el grafo.

## Probado (contra el servidor y las bases reales)

En ese momento el grafo estaba atrasado por 1 reseña (la reseña de
demostración 112) — deriva real, no sembrada:

- sin sesión → 401; comprador → 403; vendedor/tienda → 403;
- admin, grafo atrasado → `cuadra: false`, las 4 filas de veredicto en
  `-1`, `cola.pendientes: 1`, `sugerencia` con la lista y el consejo de
  `--limpiar`;
- tras `etl/cargar_grafo.sh --limpiar` → `cuadra: true`, `sugerencia: null`
  (con `usuarios` en `+1`, sin tumbar el veredicto);
- evento envenenado (`id_resena` inexistente, `intentos = 5`) → aparece en
  `cola.apartados` y `eventos_apartados[]`; con conteos que cuadran, la
  `sugerencia` lo menciona igual;
- tabla `evento_grafo` ausente → `cola: null`, comparación sigue andando;
- Neo4j caído → 503, se recupera solo.

`npx tsc --noEmit` y `eslint` limpios. Base local: la reseña 112 y su
evento en la cola quedaron (son de la demo del outbox); el grafo quedó
recargado y al día.

## Lo que sigue (mismo plan)

El **worker** (`@Interval` en `GrafoSyncService`) que vacía la cola
aplicando cada evento a Neo4j, y `ultima_sincronizacion` en
`GET /admin/fraude/anillos`. Ver `plan pendiente/outbox-grafo.md`.
