# Disparo bajo demanda del worker del grafo (sin fraude todavía)

**Fecha:** 2026-09-15, cuarta ronda del día (después de
`2026-09-15_1700-notificacion-fraude-multiusuario.md`).
**Alcance:** `backend/`, dos archivos. Primer paso hacia detectar anillos
de fraude en reseñas casi en tiempo real — a propósito, esta ronda NO
guarda nada nuevo ni evalúa ningún patrón de fraude, solo adelanta cuándo
una reseña llega al grafo.

## Contexto

Al revisar cómo se podría llevar el mismo esquema de alertas de login a
los anillos de reseñas, se notó que `GrafoSyncService.vaciarCola()` (el
worker que mantiene Neo4j al día) es puramente `@Interval` — igual que
estaba `EventosAutenticacionSyncService` antes de la primera ronda de
hoy. El usuario pidió explícitamente, con alcance acotado: nada de
guardar alertas todavía, nada de disparar detección de fraude — solo que
una reseña nueva le avise al worker para que la proyecte de inmediato, en
vez de esperar hasta 10s.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/services/grafo/grafo-sync.service.ts` | `vaciarCola()` dividido: el cuerpo pasa a `procesarPendientes(ejecutarPoda)` (privado); nuevo método público `procesarAhora()` que lo llama sin el mutex `procesando` del intervalo y sin ejecutar la poda |
| `src/services/resenas/resenas.service.ts` | inyecta `GrafoSyncService`; `crear()` llama `void this.grafoSyncService.procesarAhora()` justo después del `INSERT` (sin `await`) |

## Diseño (mismo patrón que la primera ronda del día, aplicado antes de que hiciera falta encontrar el bug de nuevo)

A diferencia de `EventosAutenticacionSyncService.sincronizarAhora()` (que
tuvo que corregirse EN VIVO tras encontrar el bug del mutex compartido),
acá se aplicó la lección directamente: `procesarAhora()` nunca comparte
`procesando` con el `@Interval`. Es seguro sin mutex por dos razones que
se refuerzan:

1. `procesarUnEvento` ya toma cada fila de `evento_grafo` con
   `FOR UPDATE SKIP LOCKED` — dos corridas superpuestas se reparten la
   cola sin pisarse, no compiten por la misma fila.
2. La proyección al grafo es `MERGE`, idempotente — aunque dos corridas
   llegaran a tocar la misma reseña (no debería pasar por el punto 1),
   el resultado es el mismo.

La poda (`podar()`) sigue atada exclusivamente al ritmo del `@Interval`
(`ejecutarPoda: false` en la llamada de `procesarAhora()`) — no tiene
sentido que se dispare en cada reseña, es housekeeping de la cola, no
frescura del grafo.

## Probado en vivo — 2026-09-15

Contra Postgres y Neo4j reales (`mesh-postgres`, `mesh-neo4j`), sin
levantar el servidor completo para el mecanismo en sí (se probó
`GrafoSyncService.procesarAhora()` directo, con un script ts-node
desechable — no se commiteó):

| Caso | Resultado |
|---|---|
| Insertar una reseña por SQL directo | el trigger encola 1 evento en `evento_grafo`, `procesado_en IS NULL` |
| Neo4j antes de `procesarAhora()` | el nodo `:Resena` todavía no existe (confirmado con `cypher-shell`) |
| Llamar `procesarAhora()` | log "1 evento(s) aplicados"; el nodo `:Resena` con sus relaciones `ESCRIBIO`/`CALIFICA_A` aparece de inmediato; `evento_grafo.procesado_en` queda con fecha |
| Dos reseñas nuevas + dos llamadas a `procesarAhora()` EN PARALELO (dos procesos de Node distintos) | las dos corridas se reparten la cola (1 evento cada una), sin duplicar ni bloquearse — confirma que no hace falta el mutex |
| Arrancar la app completa con `ResenasService` ahora inyectando `GrafoSyncService` | arranca sin errores de DI, `Nest application successfully started` |

No se probó el camino HTTP completo (`POST /resenas` → `crear()` →
`procesarAhora()`) porque el conjunto de datos local no tiene ningún
pedido en estado `pagado` (`exigirCompraPagada` lo exige) — armar una
compra completa solo para probar esta línea era desproporcionado al
tamaño del cambio. Se cubrió por partes: el mecanismo real
(`procesarAhora()`) se probó a fondo en vivo, y el enganche en `crear()`
se verificó por revisión de código + compilación + que la app arranca sin
errores de inyección.

`npx tsc --noEmit` limpio. `eslint` limpio en los dos archivos. Sin
errores en el log del servidor.

## Lo que no se hizo en esta ronda (y por qué)

- **Nada de detección ni persistencia de anillos** — explícitamente fuera
  de esta ronda, por pedido directo del usuario ("no guardes nada, no
  dispares fraudes"). Es trabajo de una ronda aparte, que ahora puede
  apoyarse en que el grafo está fresco casi al instante.
- **El mismo disparo para editar/borrar una reseña** — hoy no existe ruta
  para eso (`ResenasController` solo tiene crear, responder, votar,
  quitar voto y 3 `GET`), así que no había otro punto de enganche que
  agregar.
- **Probar el camino HTTP completo** — ver arriba, cubierto por partes en
  vez de armar una compra completa solo para esta prueba.
