# Persistencia y tiempo real para los anillos de fraude en reseñas

> **Estado (2026-09-18): TODO lo de A.1/A.2 (mutuo/ciclo/reiterado) está
> construido, persistido y con endpoints propios, probado en vivo.**
> Detección (puntos 0/3), persistencia (punto 2, ver "Persistencia -- YA
> HECHA") y ahora **también los endpoints de admin** (`GET`/`PATCH
> /admin/fraude/alertas-resenas` + `GET .../:id/detalle-grafo`, ver
> `endpoints-fraude.md`, sección "Anillos de fraude en reseñas"). Lo único
> que sigue sin construir es **A.4 (misma dirección)** -- fuera de alcance
> en todas las rondas de este plan.
>
> **Actualización, misma noche del 2026-09-18:** el panel EN VIVO
> `GET /admin/fraude/anillos` (`FraudeController.anillos()` /
> `FraudeService` / `models/fraude.ts`) se eliminó por completo -- era la
> prueba de concepto de la Entrega 2, sin persistencia, ya redundante con
> lo de arriba. Se borró junto con `GrafoSyncService.estadoSincronizacion()`
> (dato auxiliar que solo consumía esa ruta). Las rutas
> `GET`/`PATCH /admin/fraude/anillos-persistidos` se renombraron a
> `alertas-resenas` (sin el sufijo `-persistidos`, que ya no tenía con qué
> contrastar) para quedar en paralelo con `alertas-login`. El resto de este
> documento describe el estado y el razonamiento ANTES de este borrado --
> las referencias a `GET /admin/fraude/anillos` y a `anillos-persistidos`
> más abajo son historia, no el contrato vigente.

## Contexto

Hoy `GET /admin/fraude/anillos` (`FraudeService.analizar()`) corre 4
consultas Cypher **en vivo, cada vez que se pide el panel**, sin ninguna
ventana de tiempo y sin persistir nada — cada llamada recalcula todo desde
cero contra el estado actual del grafo. Se detectaron dos problemas
reales al revisarlo:

1. **Sin ventana de tiempo**, un anillo de hace dos años se ve igual que
   uno de ayer.
2. **Sin persistencia**, no hay forma de que un admin lo marque
   revisado/descartado — cada vez que se abre el panel, todo vuelve a
   aparecer igual, sin memoria.

Se evaluó reutilizar `alerta_fraude`/`notificacion_fraude` (el esquema de
hoy para fraude de login) y se descartó: `ventana_inicio` está pensado
para "umbral cruzado en un momento" (un intento de login), y un anillo es
"esto existe ahora mismo en el grafo" — una pregunta distinta. Forzarlo en
la misma tabla mezclaría dos responsabilidades distintas en un solo
artefacto (dos razones para que esa tabla cambie). **Decisión: tablas
nuevas**, propias del dominio de anillos, reusando el PATRÓN de
`notificacion_fraude` (una fila por cuenta afectada, con su propio estado
de lectura) pero no necesariamente la misma tabla física — ver la
pregunta abierta 4 más abajo.

## Punto 0 — YA HECHO (2026-09-15, cuarta ronda del día)

`GrafoSyncService.procesarAhora()`: cuando se crea una reseña,
`ResenasService.crear()` le avisa al worker del outbox para que la
proyecte al grafo de inmediato, sin esperar los 10s del `@Interval`. Sin
mutex compartido con el intervalo (aprendiendo del bug real que se
encontró y corrigió en la ronda de login del mismo día). Detalle completo
y pruebas en vivo:
`../../cambio_propuestas/2026-09-15_1900-grafo-sync-bajo-demanda.md`.

Esto es la base para todo lo que sigue: el grafo ya está fresco casi al
instante después de cada reseña — ahora hace falta que ALGO revise ese
grafo fresco y guarde lo que encuentre.

## Persistencia -- YA HECHA (2026-09-17)

Todo lo de A.1/A.2 (`mutuo`/`ciclo`/`reiterado`) que describen los puntos
0/3/4 de abajo ya está construido, aplicado en local y probado en vivo:

- **`AnillosDetectorService`** (`src/services/fraude/anillos-detector.service.ts`):
  - `detectar()` -- worker `@Interval` cada 15 min, corre A.1/A.2 con
    ventana de **60 días** (`VENTANA_DIAS`).
  - `detectarInmediato(idResena)` -- versión acotada, llamada desde
    `ResenasService.crear()` **encadenada después** de
    `GrafoSyncService.procesarAhora()` (fire-and-forget, no bloquea la
    respuesta): las mismas dos consultas, pero exigiendo que el camino/par
    incluya la reseña específica recién proyectada, no solo "las dos
    cuentas" en general.
  - Las dos versiones comparten `agrupar()` (junta mutuo/ciclo/reiterado
    del mismo grupo de cuentas, "reiterado" pisa a "mutuo") y ahora también
    `persistir()`, que escribe cada grupo encontrado.
- **Esquema nuevo** (`anillos-fraude-persistencia.sql`, mismo folder,
  aplicado en local): catálogo `tipo_anillo_fraude` (`mutuo`/`ciclo`/
  `reiterado`), tabla `anillo_fraude` (una fila por anillo, identificado por
  `clave` = ids de cuenta ordenados **sin el tipo** -- ver el comentario de
  esa columna en el `.sql` para el porqué) y `anillo_fraude_resena` (pivote
  a las reseñas exactas que son la evidencia). **Sin JSON, sin tabla de
  cuentas, sin notificación a nadie** -- ver "Decisiones cerradas" abajo.
- **`registrarAnilloFraude`** (`src/helpers/registrar-anillo-fraude.ts`): el
  UPSERT, mismo criterio que `registrarAlertaFraude` (no reabre un estado
  ya revisado/descartado por un admin).

### Decisiones cerradas en esta ronda (resuelven las preguntas 2 y 5 de abajo)

1. **Nada de JSON**: la evidencia vive en `anillo_fraude_resena` (ids de
   reseña reales, mismos en Postgres y en Neo4j), no en una columna
   `detalle jsonb`. Con esos ids un admin puede ir directo a
   `MATCH (r:Resena) WHERE r.id IN (...)` en Neo4j o a `SELECT * FROM
   resena WHERE id_resena IN (...)` en Postgres.
2. **Nada de tabla de cuentas aparte**: para `mutuo`/`ciclo`/`reiterado`,
   toda cuenta del anillo es autor o vendedor de alguna de sus reseñas, así
   que se derivan con un join contra `resena.id_usuario`/
   `id_usuario_vendedor` -- guardarlas aparte sería redundante.
3. **Nada de notificación a las cuentas del anillo, y esto no es solo
   normalización**: a diferencia del fraude de login (donde la cuenta
   señalada casi siempre es la VÍCTIMA), en un anillo de reseñas la cuenta
   señalada es la SOSPECHOSA -- avisarle le daría la oportunidad de evadir
   la detección. Investigado contra la práctica real (fraud rings /
   trust & safety): la respuesta estándar es un caso interno para que un
   humano lo revise, nunca un aviso al sospechoso. Por eso no existe ningún
   `notificacion_anillo_fraude` ni columna de lectura por cuenta -- el caso
   es 100% para el panel de admin (cuando exista, ver preguntas 4/5).
4. **`clave` no lleva el tipo** (a diferencia del `Anillo.id` de
   `fraude.service.ts`, que sí): un mismo par/grupo de cuentas puede subir
   de `mutuo` a `reiterado` (o bajar) sin dejar de ser, para persistencia,
   el mismo caso -- se actualiza la fila, no se crea una nueva. Ver el
   comentario de la columna en el `.sql`.

### Probado en vivo -- 2026-09-17

Contra Postgres y Neo4j reales:

| Caso | Resultado |
|---|---|
| Camino orgánico completo (`detectar()` → `agrupar()` → `persistir()`) contra un anillo REAL ya sembrado en el dataset (cuentas 9/10/11, reseñas 87-90, de marzo -- fuera de la ventana de 60 días, ensanchada solo en el script de prueba para ejercitar el camino sin fabricar datos) | Se detectan y persisten correctamente `ciclo` (9-10-11) y `reiterado` (9-10), con la evidencia exacta en `anillo_fraude_resena` |
| Repetir la misma corrida | No duplica filas; `ultima_vez_confirmado_activo` avanza, `fecha_creacion` no cambia |
| Marcar un anillo `revisada` (simulando admin) y volver a correr | El estado se mantiene en `revisada`, no se reabre solo |
| Downgrade de tipo (`reiterado` → `mutuo`) sobre el mismo `clave`, llamando `registrarAnilloFraude` directo | Actualiza la fila existente, sin crear una nueva |
| Acumular evidencia (una reseña más al mismo anillo, en otra llamada) | Se suma al pivote sin duplicar ni perder las anteriores |
| Un id de reseña inexistente mezclado en la evidencia | Toda la transacción falla (viola la FK), sin dejar ningún rastro parcial, sin tumbar el proceso |
| App completa arrancando con todo esto (ventana real de 60 días) | `Nest application successfully started`, sin errores |

`npx tsc --noEmit` y `eslint` limpios en todos los archivos tocados. Las
tablas quedaron vacías al final de las pruebas (se limpiaron los datos de
prueba); en producción real, con la ventana de 60 días sin ensanchar, este
anillo de marzo NO se persiste (es correcto: ya no está "activo").

### Endpoints -- YA HECHOS (2026-09-18)

Resuelven las preguntas 4 y 5 de abajo, con controller y servicio **aparte**
de `FraudeController`/`FraudeService` (pedido explícito): ver
`endpoints-fraude.md`, sección "Anillos de fraude en reseñas --
PERSISTIDOS", para el detalle completo (payloads, errores, pruebas).

- `GET /admin/fraude/anillos-persistidos` -- paginado, filtrable por
  `estado`/`tipo`.
- `PATCH /admin/fraude/anillos-persistidos/:id` -- marcar revisado/descartado.
- `GET /admin/fraude/anillos-persistidos/:id/detalle-grafo` -- el detalle
  real (autor/vendedor/producto/fecha/calificación) de las reseñas de ESE
  anillo, consultado en vivo contra Neo4j a partir de
  `anillo_fraude_resena` -- no vuelve a correr A.1/A.2.

`GET /admin/fraude/anillos` (el panel EN VIVO, sin persistencia) **no
cambió de forma** -- las dos rutas conviven, pregunta 4 resuelta así: no se
tocó la vieja, se agregó una nueva y separada.

### Lo que sigue sin hacer, a propósito

- **A.4 (misma dirección)** sigue fuera, sin disparador, sin tabla, sin
  endpoint. Es lo único que queda de este plan.

## Decisiones ya cerradas en conversación

1. **Tablas nuevas, no reusar `alerta_fraude`** (ver Contexto). Reusar el
   catálogo `estado_alerta_fraude` (`pendiente`/`revisada`/`descartada`)
   sí tiene sentido — es un catálogo genérico de 3 valores sin lógica de
   dominio propia, no arrastra el mismo problema que la tabla de datos.
2. **De las 4 consultas de anillos, solo A.1 (ciclos) y A.2 (mismo
   producto) pasan por el camino de "esta reseña nueva"** — ambas
   recorren autor→reseña→vendedor. A.4 (misma dirección) es
   `(:Usuario)-[:VIVE_EN]->(:Direccion)`, no depende de reseñas en
   absoluto, así que una reseña nueva no es su disparador natural.
3. **La ventana de tiempo se filtra por `Resena.fecha`** (el nodo, no la
   relación — `ESCRIBIO`/`CALIFICA_A` no tienen propiedades). No aplica a
   A.4 de la misma forma, porque A.4 no pasa por ningún nodo `:Resena`.
4. **El tamaño de la ventana (cuántos días) es una decisión de dominio,
   no técnica** — no se fijó todavía. Mismo criterio que los umbrales de
   Redis/Elasticsearch: se elige pragmáticamente (ajustable), no con una
   fórmula. Sugerido en conversación: 30-90 días, a confirmar.
5. **Dos disparadores, mismo espíritu que login (hot path + backstop
   periódico):**
   - **Acotado, por evento**: al proyectar una reseña nueva al grafo
     (enganchado justo después de `procesarAhora()`), correr A.1/A.2
     SOLO sobre las dos cuentas de esa reseña (autor/vendedor) — no las
     24h/todo el grafo. Mismo patrón que `toma_cuenta`/`viaje_imposible`
     en login.
   - **Periódico, de respaldo**: un worker `@Interval` (mismo molde que
     `FraudeLoginRetrospectivoService`) que re-corre A.1/A.2/A.4
     completas sobre la ventana de tiempo, para cubrir lo que el disparo
     acotado no vea — en particular A.4, que no tiene disparador por
     evento.

## Pasos para la próxima sesión (en orden)

1. **Cerrar las preguntas abiertas de abajo** con el usuario antes de
   tocar esquema — mismo workflow de siempre (plan → `.sql` de
   referencia aplicado en local → código → pruebas en vivo → documentar).
2. **Esquema**: la(s) tabla(s) nueva(s) — forma exacta a definir con las
   respuestas de las preguntas abiertas, pero ya se sabe que necesita:
   - Identidad del anillo (`tipo` + `clave` estable, ej. `mutuo-9-10`,
     igual al `Anillo.id` que ya arma `fraude.service.ts`).
   - Estado de investigación (reusar `estado_alerta_fraude`).
   - "Primera vez visto" / "última vez confirmado activo" en vez de
     `ventana_inicio` — la pregunta real para un anillo es "¿sigue
     activo?", no "¿en qué ventana cayó?".
   - Evidencia (`detalle` jsonb: cuentas, reseñas, señales — mismo shape
     que ya devuelve `Anillo`).
   - La notificación por cuenta afectada (una fila por cuenta del
     anillo, con su propio estado de lectura) — mismo PATRÓN que
     `notificacion_fraude`.
3. **El chequeo acotado por evento**: engancharlo después de
   `GrafoSyncService.procesarAhora()` — correr A.1/A.2 (con la ventana de
   tiempo ya aplicada) filtradas a las dos cuentas de la reseña recién
   proyectada, y persistir lo que encuentre.
4. **El worker periódico de respaldo**: nuevo servicio (o método en
   `FraudeService`), `@Interval`, corre A.1/A.2/A.4 completas sobre la
   ventana, persiste/actualiza.
5. **Endpoints**: decidir si `GET /admin/fraude/anillos` pasa a leer la
   tabla persistida (en vez de recalcular en vivo) o si conviven las dos
   formas por un tiempo — y las rutas de usuario equivalentes a
   `/perfil/alertas-fraude`, si aplica el mismo patrón de notificación.
6. **Probar en vivo, extenso** — mismo rigor que las rondas de login: el
   `neo4j/correr_fraude.sh` que siembra un anillo de mentira es el arnés
   natural para esto.
7. **Documentar**: `endpoints-fraude.md`, este plan marcado HECHO,
   `cambio_propuestas/` con las pruebas.

## Preguntas abiertas — resolver ANTES de construir

1. **¿Cuántos días de ventana?** (sugerido 30-90, a confirmar — posible
   pregunta para el profesor, como quedó pendiente en
   `fraude-login-eventos.md` punto 2 en su momento).
2. **¿La tabla de notificación es nueva y propia de anillos, o se
   generaliza `notificacion_fraude` para apuntar a cualquiera de las dos
   fuentes** (login o anillos)? Mencionado como posibilidad si algún día
   se quiere una sola bandeja de notificaciones — no decidido.
3. **A.4 (misma dirección): ¿qué disparador tiene, ya que no depende de
   reseñas?** Candidatos: solo el worker periódico (más simple), o
   engancharlo a cuando se crea/edita una dirección (`DireccionUsuarioService`)
   — no evaluado todavía.
4. **¿El panel de admin (`GET /admin/fraude/anillos`) cambia de forma**
   (pasa a traer también `estado`, `cuentas_afectadas` con lectura, etc.,
   como ya tiene `alertas-login`) **o se deja como está y la persistencia
   vive aparte, en un endpoint nuevo?** Afecta al frontend
   (`PanelFraude.svelte`), que está fuera de `backend/` — probablemente
   haga falta avisar al equipo de frontend antes de cambiar la forma de
   una ruta que ya consumen.
5. **¿Se conserva el resultado 100% en vivo como fallback** si la tabla
   nueva está vacía o el worker todavía no corrió, igual que "anillos: []
   con el grafo real" es hoy un resultado válido y no un error?

## Lo que se descarta de entrada

- **No tocar A.3 (ráfaga) ni A.5 (puntaje compuesto)** en esta ronda —
  existen como consultas pero nunca se conectaron al backend; quedan
  fuera del alcance de "persistir lo que ya se detecta", son una
  ampliación aparte si se decide sumarlas después.
- **No cambiar el mecanismo de A.1/A.2/A.4 en sí** (las consultas Cypher
  ya probadas) — el trabajo es de persistencia y disparo, no de rediseñar
  qué cuenta como anillo.
