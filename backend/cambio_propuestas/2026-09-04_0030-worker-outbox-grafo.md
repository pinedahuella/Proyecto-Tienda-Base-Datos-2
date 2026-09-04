# Cambio: el worker del outbox — el grafo de fraude se mantiene al día solo

**Fecha aproximada:** 2026-09-04, madrugada.
**Alcance:** solo `backend/`. No tocó migraciones, Mongo, `etl/` ni `neo4j/`.
Depende de la tabla `evento_grafo` + el trigger (ya en local por
`plan pendiente/outbox-grafo.sql`; migración real `015` la hace el compañero).

Es el **paso 2** de `plan pendiente/outbox-grafo.md` — la pieza que
completa el patrón outbox. El trigger encola en `evento_grafo` cada cambio
de una reseña; este worker vacía esa cola y proyecta cada cambio a Neo4j.
Es el "envío asíncrono" que pidió el profesor: `POST /resenas` commitea en
PostgreSQL y responde sin hablarle a Neo4j; el grafo se actualiza segundos
después, aquí.

## Qué se agregó

### Dependencia

`@nestjs/schedule` v12 (`npm install`). `ScheduleModule.forRoot()` en los
`imports` de `AppModule` — habilita `@Interval`/`@Cron`.

### El worker — `GrafoSyncService.vaciarCola()`

`@Interval('grafo-outbox', 10000)` — cada 10 s. Va en la **misma clase** que
la conciliación (`GrafoSyncService`), no en un servicio aparte ni en un
script de `etl/`: como tarea de Nest tiene el mismo ciclo de vida que la API.

Cada corrida procesa los eventos pendientes **de a uno, en su propia
transacción corta** (`FOR UPDATE SKIP LOCKED LIMIT 1`), hasta vaciar la cola
o llegar a 500:

- Relee la reseña de PostgreSQL (`SQL_RESENA`, el JOIN de reconstrucción —
  el evento sólo trae el id).
  - **Existe** → `ejecutarGrafo(CYPHER_PROYECTAR_RESENA)`: `MERGE` del nodo
    `:Resena`, sus dos `:Usuario` (autor y vendedor), sus `:Direccion` +
    `[:VIVE_EN]`, el `:Producto`, y las 3 relaciones `ESCRIBIO` /
    `CALIFICA_A` / `SOBRE`. Un comprador que reseña por primera vez todavía
    no tiene nodo → por eso se hace `MERGE` de los participantes también.
  - **No existe** (borrada) → `MATCH (r:Resena {id}) DETACH DELETE r`.
  - `UPDATE evento_grafo SET procesado_en = now()`.
- **Fallo de CONEXIÓN** (Neo4j/PostgreSQL caídos, `42P01`) → ROLLBACK, se
  corta la corrida **sin gastar intento**; se reintenta entera en la próxima.
- **Fallo de DATOS** (`Neo.ClientError.Statement.*`) → `intentos + 1` +
  `ultimo_error`; sigue con el resto de la cola. A los 5 queda apartado y lo
  reporta la conciliación.
- **Poda**: cada ~360 corridas (≈ 1 h) borra lo procesado hace > 7 días.

Todo idempotente (`MERGE` / `DETACH DELETE`) — reaplicar un evento no cambia
nada. Es "al menos una vez".

### `ejecutarGrafo()` en `src/database/neo4j.ts`

Gemelo de `consultarGrafo` pero en modo **WRITE**. Hasta ahora el backend
nunca escribía al grafo (sólo el ETL). Se actualizó el comentario del
módulo.

## Detalles que costaron y hay que recordar

- **Los ids van con `neo4j.int()`, obligatorio.** Comprobado en vivo: un
  `number` de JS crudo se guarda como `Float` y `MERGE (:Usuario {id: 3.0})`
  crea un nodo **duplicado** que ninguna consulta encuentra. Todos los
  params de id/calificación pasan por `neo4j.int(...)`.
- **Las fechas** salen de PostgreSQL con
  `to_char(... AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')` — no
  como `Date` de JS (perdería los microsegundos) — para que `datetime()` de
  Cypher las tome igual que el ETL.
- **La normalización de la clave de `:Direccion`** está copiada **verbatim**
  de `pg_temp.clave_direccion` de `etl/extraer_grafo.sql` dentro de
  `SQL_DIRECCIONES`. Verificado: misma clave que el ETL. Si esa función del
  ETL cambia, hay que cambiar `SQL_DIRECCIONES` a la par (comentado en el
  código).
- **No colapsa eventos de la misma reseña**: si hay 3 para la reseña 5, se
  procesan los 3 (`MERGE` no-op). Colapsar era opcional; se descartó por
  simplicidad.

## Probado a fondo (contra el servidor y las bases reales)

| Caso | Resultado |
|---|---|
| Reseña nueva | ~10 s después: nodo `:Resena` + los 2 `:Usuario` + `:Producto` + las 3 relaciones, con calificación/fecha/texto correctos |
| Reseña borrada | el worker hace `DETACH DELETE`; el nodo desaparece del grafo |
| Idempotencia | reencolar el mismo evento → 154 nodos antes y después (sin duplicados) |
| Comprador sin nodo `:Usuario` | (se borró `:Usuario {id:8}` a mano) → el worker lo recrea vía `MERGE` con todas sus props |
| **Neo4j caído al encolar** | 3+ corridas logueando `WARN "corrida interrumpida"`, el evento queda `procesado_en NULL`, `intentos 0` (NO se envenena); al reiniciar Neo4j, la siguiente corrida lo aplica |
| Evento apartado (`intentos = 5`) | el worker lo salta, no loopea; la conciliación lo reporta |
| Backlog (10 eventos de golpe) | una sola corrida: "10 evento(s) aplicados", cola a 0 |
| Conciliación tras cada caso | `cuadra: true` (o detecta la deriva sembrada y sugiere `--limpiar`, que la arregla) |

`npx tsc --noEmit` y `eslint` limpios. Datos de prueba borrados, grafo
recargado con `--limpiar`, `evento_grafo` con la cola vacía.

## Cómo correrlo

`npm run start:dev` (o `start`). El worker arranca solo con la app y loguea
`[GrafoSyncService] worker del grafo: N evento(s) aplicados` cuando hace
trabajo. No hay nada que arrancar aparte.

## Lo que queda

- `ultima_sincronizacion` (+ nº de pendientes) en `GET /admin/fraude/anillos`,
  para que el panel de fraude muestre "grafo actualizado hace X" y no
  enseñe un análisis viejo en silencio. Es chico — ya está calculado en la
  conciliación.
- Del compañero: la migración real `015_outbox_grafo.sql` y la etapa A de
  `etl/cargar_grafo.sh` (que vacíe la cola en vez de releer todo).
