# Persistencia de anillos de fraude en reseñas (A.1/A.2), sin endpoints todavía

**Fecha:** 2026-09-17/18, continuación directa de la ronda del
`2026-09-15_1900-grafo-sync-bajo-demanda.md` y del plan
`elementos Generales/plan pendiente/anillos-fraude-persistencia.md`.
**Alcance:** `backend/`, esquema nuevo aplicado en local + wiring de
persistencia en `AnillosDetectorService`. **Explícitamente fuera de esta
ronda**: ningún endpoint (`GET`/`PATCH`) para leer o revisar anillos -- eso
queda para otra ronda.

## Contexto

`AnillosDetectorService` (worker de 15 min + chequeo acotado por reseña,
construido en una ronda anterior) hasta ahora solo detectaba y logueaba los
anillos `mutuo`/`ciclo`/`reiterado` (A.1/A.2) que aparecían en el grafo de
Neo4j dentro de una ventana de 60 días. Esta ronda le agrega persistencia
real en PostgreSQL.

## Diseño del esquema, decidido en conversación antes de escribir nada

Tres decisiones cerradas con el usuario, cada una justificada:

1. **Sin columna JSON de evidencia.** En vez de un `detalle jsonb` (como
   tiene `alerta_fraude` para login), la evidencia son los ids de reseña
   reales en una tabla pivote (`anillo_fraude_resena`) -- el mismo id sirve
   para consultar Neo4j (`MATCH (r:Resena) WHERE r.id IN (...)`) o
   PostgreSQL directamente, sin traducir nada.
2. **Sin tabla de cuentas aparte.** Para `mutuo`/`ciclo`/`reiterado`, toda
   cuenta del anillo es autor o vendedor de alguna de sus reseñas, así que
   "quiénes están en el anillo" sale de un join contra
   `resena.id_usuario`/`id_usuario_vendedor` -- guardarlas aparte sería
   redundante (normalización, no una tabla pivote nueva).
3. **Sin notificación a ninguna cuenta del anillo.** Se investigó contra la
   práctica real de plataformas (fraud rings / trust & safety): a
   diferencia del fraude de login (la cuenta señalada suele ser la
   víctima), en un anillo de reseñas la cuenta señalada es la SOSPECHOSA --
   avisarle le daría la oportunidad de evadir la detección. La práctica
   estándar es un caso 100% interno para revisión humana, nunca un aviso al
   sospechoso. Por eso no existe ningún equivalente a `notificacion_fraude`
   para anillos.

Un cuarto detalle, más técnico, que salió de revisar el código ya construido
en vez de la conversación de diseño: `anillo_fraude.clave` **no lleva el
tipo** (a diferencia del `Anillo.id` que arma `fraude.service.ts` para el
panel en vivo, que sí, ej. `mutuo-9-10`) -- es solo los ids de cuenta
ordenados (`9-10`). Así, un mismo par/grupo que sube de `mutuo` a
`reiterado` (o baja, si la reseña que sostenía el `reiterado` sale de la
ventana) actualiza la misma fila en vez de crear una nueva -- mismo criterio
que ya usa `AnillosDetectorService.agrupar()` para fusionar mutuo/reiterado
del mismo par antes de loguear.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/anillos-fraude-persistencia.sql` | nuevo -- catálogo `tipo_anillo_fraude`, tabla `anillo_fraude`, tabla `anillo_fraude_resena`. Aplicado en local |
| `elementos Generales/plan pendiente/anillos-fraude-persistencia.md` | actualizado -- marca la persistencia de A.1/A.2 como hecha, documenta las decisiones de esquema y las pruebas |
| `src/models/anillo-fraude.ts` | nuevo -- constantes `ID_TIPO_ANILLO_FRAUDE_*`, mismo criterio que `ID_TIPO_ALERTA_FRAUDE_*` |
| `src/helpers/registrar-anillo-fraude.ts` | nuevo -- `registrarAnilloFraude()`, el UPSERT (mismo molde que `registrarAlertaFraude`: no reabre un estado ya revisado/descartado) |
| `src/services/fraude/anillos-detector.service.ts` | `agrupar()` ahora expone `clave` por grupo; nuevo método `persistir()`, llamado desde `detectar()` y `detectarInmediato()` justo después de loguear |

No se tocó ningún controller ni se agregó ninguna ruta.

## Probado en vivo -- 2026-09-17/18

Contra Postgres y Neo4j reales (`mesh-postgres`, `mesh-neo4j`):

| Caso | Resultado |
|---|---|
| Camino orgánico completo (`detectar()` real, sin llamadas directas al helper) contra un anillo REAL ya sembrado en el dataset (cuentas `anillo_uno`/`anillo_dos`/`anillo_tres`, ids 9/10/11, reseñas 87-90, de marzo 2026 -- fuera de los 60 días; la ventana se ensanchó SOLO en el script de prueba, en runtime, sin tocar el archivo fuente, para poder ejercitar el camino completo con ids reales sin fabricar ninguna reseña falsa) | Detecta y persiste correctamente `ciclo` (clave `9-10-11`, evidencia 87/89/90) y `reiterado` (clave `9-10`, evidencia 87/88) |
| Repetir la misma corrida | No duplica filas de `anillo_fraude`; `ultima_vez_confirmado_activo` avanza, `fecha_creacion` no cambia |
| Marcar un anillo `revisada` (UPDATE directo, simulando a un admin) y volver a correr el worker | El estado se mantiene en `revisada` -- el worker no lo reabre solo |
| Downgrade de tipo (`reiterado` → `mutuo`) sobre el mismo `clave`, llamando `registrarAnilloFraude` directo | Actualiza la fila existente, no crea una nueva, y el estado ya marcado sigue intacto |
| Acumular evidencia (sumar una reseña real distinta al mismo anillo, en otra llamada) | Se suma al pivote sin duplicar ni perder las reseñas anteriores |
| Un id de reseña inexistente mezclado en la evidencia | Toda la transacción falla (viola la FK `anillo_fraude_resena_id_resena_fkey`), sin dejar ningún rastro parcial ni tumbar el proceso |
| App completa arrancando con todo esto, ventana real de 60 días sin modificar | `Nest application successfully started`, sin errores |

`npx tsc --noEmit` y `eslint` limpios en los cinco archivos tocados. Las
tablas nuevas quedaron vacías al final (se borraron los datos de la
prueba): en producción real, con la ventana de 60 días sin ensanchar, el
anillo de marzo de las cuentas 9/10/11 NO se persiste hoy -- es correcto,
ya no está "activo" según el criterio vigente.

## Lo que no se hizo en esta ronda, y por qué

- **Ningún endpoint** (`GET`/`PATCH`) que lea o modifique `anillo_fraude` --
  pedido explícitamente fuera de esta ronda por el usuario ("de momento no
  hagas los gets... solo persistencia y modificación sql local"). Las
  preguntas 4 y 5 del plan (si `GET /admin/fraude/anillos` cambia de forma,
  y si se conserva el cálculo 100% en vivo como fallback) siguen abiertas.
- **A.4 (misma dirección)** sigue completamente fuera de alcance -- ni
  detección ni esquema.
- **La migración real** (`migrations/0XX_*.sql`) -- le toca al compañero,
  después de la última migración real existente, mismo workflow que
  `fraude-login-eventos.sql`/`notificacion-fraude-usuario.sql`.
