# Sincronización de `eventos_autenticacion` (Mongo) → Elasticsearch, por bandera

**Fecha:** 2026-09-10, media mañana.
**Alcance:** solo `backend/`. Sin migraciones.

Segunda pieza del módulo de fraude por login. La primera
(`2026-09-10_0906-eventos-autenticacion-mongo.md`) dejó los eventos en
MongoDB; esta los lleva al índice de Elasticsearch para la capa de
consulta/análisis.

**Aclaración importante:** esto **no** es la detección de ataques en tiempo
real. Un ataque de fuerza bruta ("20 intentos por segundo") se atrapa con
**contadores en Redis en el propio camino del login**, síncrono, en la
misma request — eso queda pendiente (ver `plan pendiente/fraude-login-eventos.md`).
El índice de Elastic responde las preguntas retrospectivas: "IPs con N
fallos en 24 h", "viaje imposible en la semana", las facetas del panel de
admin, donde un retraso de segundos da igual.

## Qué se hizo

Mismo patrón que `BuscadorSyncService` (el worker del buscador de
catálogo), a pedido del usuario — y más simple, porque el evento de
autenticación es **inmutable**: la bandera se pone una vez y se quita una
vez, nunca vuelve.

| Archivo | Qué es |
|---|---|
| `src/models/evento-autenticacion.ts` | + campo `pendiente_elastic?: true` — "cola sin cola" en el propio documento |
| `src/services/log.service.ts` | cada evento nace con `pendiente_elastic: true` |
| `src/services/eventos-autenticacion/eventos-autenticacion-sync.service.ts` | **nuevo** — el worker `@Interval` (5 s) |
| `src/services/eventos-autenticacion/documento-elastic.ts` | **nuevo** — arma el documento del índice a partir del evento (sin `_id` ni la bandera; `fecha` a ISO 8601) |
| `src/app.module.ts` | registra `EventosAutenticacionSyncService` |
| `.env.example` | `ELASTIC_INDICE_EVENTOS=mesh_eventos_autenticacion` (y de paso documenta `ELASTIC_INDICE` del buscador, que no estaba) |

### El worker

- `@Interval` cada **5 s** (el buscador usa 10; aquí la frescura importa más
  — es una constante). Guard `procesando` para que una corrida lenta no se
  pise con la siguiente. Tope 500 por corrida.
- `find({ pendiente_elastic: true }).sort({ fecha: 1 }).limit(500)` → por
  cada uno: `elasticClient.index()` con **el `_id` de Mongo como `_id` en
  Elastic** (reindexar es idempotente) → `$unset` de la bandera.
- Un fallo suelto (Elastic caído, o ese documento) **no tumba el lote**: se
  deja la bandera, se reintenta en la próxima corrida. `logger.warn` por
  cada fallo, `logger.log` con el conteo cuando sincroniza algo.
- El worker **nunca toca el camino del login**. La escritura del evento en
  Mongo sigue siendo fire-and-forget e instantánea.

### Carga inicial

La hace el **ETL del compañero** (`etl/`), igual que con el buscador de
catálogo (`etl/cargar_busqueda.sh` cargó, `BuscadorSyncService` mantiene).
Este worker solo mantiene al día el flujo nuevo.

## Probado en vivo — 2026-09-10

Contra el servidor real y los contenedores. Script en el scratchpad.

| # | Caso | Resultado |
|---|---|---|
| 1 | Login nuevo | doc en Mongo con `pendiente_elastic: true` |
| 2 | Espera ≤5 s | el worker lo indexa, `$unset` de la bandera; `mesh_eventos_autenticacion` pasa a 1 doc |
| 3 | Paridad | el `_source` de Elastic (`_id` = `_id` de Mongo) coincide **campo a campo** con el documento de Mongo (`fecha` como ISO 8601) |
| 4 | Backfill: marcar los 11 docs viejos (sin bandera) | el worker los alcanza en 1-2 corridas; Mongo total 11 == ES total 11 |
| 5 | `docker stop mesh-elastic`, login | login `200` en 0.14 s; doc queda pendiente; `WARN [EventosAutenticacionSyncService] ... other side closed` cada 5 s; al volver Elastic, pendientes → 0 solo |
| 6 | Re-marcar un doc ya sincronizado | ES count 12 → 12 (reindex sobre el mismo `_id`, sin duplicado) |
| 7 | Agregación `terms` sobre `motivo`/`ip` | funciona vía `.keyword` (ver nota de mapping abajo); devuelve `credenciales_invalidas`/`cuenta_inactiva`/`datos_invalidos`/`usuario_inexistente` x1, y "2 cuentas distintas desde 172.22.192.1" |
| 8 | 3 logins seguidos | ~0.077 s cada uno — el worker no afecta al login |
| 9 | Estado final | Mongo total == ES total (15 == 15) |

`npx tsc --noEmit` limpio. `eslint` limpio en los archivos tocados. LF.

**Los docs de prueba quedan en Mongo y en `mesh_eventos_autenticacion` a
propósito, para que el usuario los revise.**

## Nota de mapping — le toca al compañero

El índice se auto-creó con **mapping dinámico**: los campos de texto
(`ip`, `motivo`, `tipo`, `resultado`, `id_usuario`, `huella_cliente`,
`identificador_intentado`) quedan como `text`, que **no se puede agregar**
directo (`Fielddata is disabled`). Hoy funciona usando el sub-campo
`.keyword` (`terms: { field: "motivo.keyword" }`), pero lo correcto es que
el compañero cree `mesh_eventos_autenticacion` con un **mapping explícito**:

- `keyword`: `ip`, `motivo`, `tipo`, `resultado`, `id_usuario`,
  `huella_cliente`, `identificador_intentado`
- `date`: `fecha`
- `text` (o `keyword`, a decidir): `user_agent`
- más adelante (paso de geo): `geo` como `geo_point`

Cuando exista ese mapping, `documento-elastic.ts` no cambia — solo hay que
reindexar (marcar todo con `pendiente_elastic: true` y dejar correr el
worker, o el `etl/` de carga inicial).
