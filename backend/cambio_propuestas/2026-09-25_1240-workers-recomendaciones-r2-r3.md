# Workers de R2 y R3 (sin ruta HTTP todavia) -- probar el mecanismo antes de conectarlo

**Fecha:** 2026-09-25, continuación directa de R1
(`2026-09-25_1150-vistos-recientemente.md`). El usuario pidió construir
primero los WORKERS de R2 ("también vieron") y R3 ("para ti") -- sin ruta
`GET` todavía -- específicamente para ver cómo reaccionan antes de
conectarlos a algo público.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## Por qué worker y no caché perezosa (decisión tomada con el usuario)

Se discutió antes de codear: con un worker, ninguna petición en vivo corre
nunca la consulta pesada -- siempre lee un resultado ya calculado en
Redis. El costo se paga en el ciclo del worker, no en el momento en que
alguien pide su recomendación; a cambio, el dato puede tener hasta un
ciclo de antigüedad (mismo trato que `mas-vendidos`).

**Intervalo: 15 minutos para los dos**, decisión del usuario tras discutir
que la frescura (qué tan rápido cambia lo que la gente mira) y la
capacidad (si un ciclo alcanza a terminar antes del siguiente) son dos
preguntas distintas -- la segunda depende de cuántos productos/cuentas
activas haya, no del largo del intervalo en sí, y ya está cubierta por la
misma bandera `procesando` que usan `MasVendidosSyncService`/
`BuscadorSyncService` (si un ciclo se alarga, el siguiente se salta, nunca
se rompe nada).

## Diseño

**`TambienVieronSyncService`** (R2): cada 15 min, junta los productos con
AL MENOS una vista en los últimos 30 días (no el catálogo entero), corre
R2 por cada uno con los umbrales fijos del compañero
(`min_sesiones_en_comun: 2`, `limite: 10`), y guarda en
`mesh:producto:<id>:tambien-vieron` (JSON, se sobrescribe cada ciclo, sin
TTL -- nunca queda "frío").

**`ParaTiSyncService`** (R3): mismo patrón, pero junta CUENTAS
(`id_usuario`, nunca sesiones anónimas) con al menos una vista reciente --
no todas las cuentas registradas: una cuenta sin vistas no tiene semillas,
R3 le daría vacío igual, así que ni se intenta. Guarda en
`mesh:cuenta:<id>:para-ti`. Si R3 no encuentra nada para una cuenta con
historial, se guarda un arreglo vacío -- la decisión de caer a T1 en ese
caso queda para quien lea esta caché después (la ruta `GET`, todavía sin
construir), no es responsabilidad del worker.

Los dos: nunca lanzan (try/catch por item, un producto/cuenta que falle no
tumba el resto), y si la consulta de descubrimiento (qué productos/cuentas
tienen vistas recientes) falla, el ciclo entero se salta y se reintenta en
el próximo -- mismo criterio que `VentasLimitadasService.revisarVencidas()`.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/services/productos/tambien-vieron-sync.service.ts` | nuevo -- worker de R2 |
| `src/services/productos/para-ti-sync.service.ts` | nuevo -- worker de R3 |
| `src/app.module.ts` | registra los dos servicios nuevos |

Sin controller, sin DTO, sin modelo de respuesta -- todavía no hay nada
que lea esta caché por HTTP. Eso es el siguiente paso, después de haber
visto que el mecanismo reacciona bien.

## Probado en vivo -- 2026-09-25

Contra el servidor, ClickHouse y Redis reales, con el intervalo bajado a
8 s solo para la prueba (repuesto a 15 min después). Se reusó el MISMO
escenario sembrado (Juan + 5 sesiones ajenas) que ya se había verificado a
mano corriendo el `.sql` del compañero directo, para poder comparar el
resultado del worker contra un valor ya conocido:

| Caso | Resultado |
|---|---|
| Primer ciclo | `worker de para-ti: 3/3 cuenta(s) recalculadas`; `worker de tambien-vieron: 11/11 producto(s) recalculados` -- sin errores |
| `mesh:producto:990001:tambien-vieron` | `[{"id_producto":990003,"sesiones_en_comun":2,"afinidad":0.707}]` -- **idéntico** al valor ya verificado a mano con el `.sql` directo |
| `mesh:cuenta:999101:para-ti` | `[{"id_producto":990006,"puntaje":1.4,...},{"id_producto":990003,"puntaje":1.374,...}]` -- **idéntico**, mismo orden, mismo `porque_viste` |
| Varios ciclos seguidos | mismo resultado estable, sin acumular ni duplicar (la clave se sobrescribe, no se le agrega) |
| ClickHouse real caído (`docker stop`) a mitad de ciclo | `WARN` en el log ("no se pudo leer ClickHouse"), la app y el resto de rutas siguieron respondiendo `200`; Redis conservó el ÚLTIMO valor bueno, sin borrarlo ni corromperlo |
| ClickHouse recuperado | el siguiente ciclo recalculó normal, sin intervención |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo, antes y después de reponer el intervalo | limpios los dos |

**Hallazgo de paso, no un problema:** al correr contra la base real, los
workers también calcularon caché real para productos/cuentas que ya
tenían actividad genuina de rondas de prueba anteriores en este proyecto
(productos 1/3/4/12/30/50, cuentas 3/5) -- esas quedaron en Redis
(correctas, no son basura); solo se borraron las claves de los ids
ficticios de esta prueba puntual (990001-990006, 999101).

Teardown: claves ficticias borradas de Redis, filas sembradas borradas de
ClickHouse (`ALTER TABLE ... DELETE`), intervalos repuestos a 15 minutos,
servidor de prueba detenido.

## Lo que sigue

Construir las rutas `GET` que lean `mesh:producto:<id>:tambien-vieron` y
`mesh:cuenta:<id>:para-ti` (con su respectivo enriquecido desde Mongo,
mismo patrón que `AdminTendenciasAvanzadasService`), y decidir el
comportamiento de "cae a T1 si está vacío" para R3 -- ninguna de las dos
cosas se tocó en esta ronda, era solo probar los workers.
