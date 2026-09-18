# Disparo inmediato (por login) de los tres chequeos "_lenta" de Elasticsearch

**Fecha:** 2026-09-15, primera ronda del día.
**Alcance:** `backend/`, aditivo sobre tres archivos existentes. No se
tocó el worker de 15 min (`FraudeLoginRetrospectivoService.evaluar()` y
sus tres métodos originales), que sigue de respaldo tal cual.

## Contexto

Pedido explícito del profesor: además de esperar el worker de 15 min, las
tres señales `_lenta` (`fuerza_bruta_cuenta_lenta`, `multi_cuenta_ip_lenta`,
`ip_rotacion_cuenta_lenta`) también debían dispararse por cada login —
igual que ya hacen los contadores de Redis. Diseño validado contra
patrones reales de arquitecturas de detección de fraude (hot path / cold
path) antes de construir — ver conversación de la sesión, no hay un
archivo de investigación aparte.

## Decisiones tomadas en esta ronda

1. **Tercera capa intermedia, no reemplazo.** Redis (hot path) y el worker
   de 15 min (cold path, respaldo) quedan intactos. Lo nuevo es un
   disparo por-login con una versión ACOTADA (a la cuenta/IP de ESE login)
   de las mismas tres consultas — no la agregación `terms` que barre todas
   las cuentas.
2. **Mismo `id_tipo_alerta_fraude` y misma hora truncada que el worker de
   15 min.** Si ambos coinciden en la misma hora, se juntan en una sola
   fila (`ON CONFLICT` de `registrarAlertaFraude`) en vez de duplicar.
3. **`sincronizarAhora()` NO comparte el mutex `procesando` con el
   intervalo de 5s** — ver el bug real encontrado abajo.
4. Todo el flujo nuevo es fire-and-forget desde `UsuarioController`, igual
   que el resto del camino de login: la respuesta HTTP no se retrasa.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/services/eventos-autenticacion/eventos-autenticacion-sync.service.ts` | + `sincronizarAhora()` (indexa con `refresh: 'wait_for'`, sin mutex compartido con el `@Interval`) |
| `src/services/fraude-login/fraude-login-retrospectivo.service.ts` | + `evaluarInmediato()` y tres métodos privados `*Acotado` (mismas consultas que las tres originales, filtradas a un solo identificador/IP) |
| `src/controllers/usuario.controller.ts` | + `dispararRevisionElasticInmediata()`, encadenado en los tres call sites del login (éxito, `ErrorInicioSesion`, `ErrorValidacion`) |
| `elementos Generales/plan pendiente/fraude-login-eventos.md` | punto 3 actualizado, entrada "Disparo inmediato por login — HECHO (2026-09-15)" |

No hizo falta ningún cambio de esquema: se reutilizan los mismos
`id_tipo_alerta_fraude` (1-9) y la misma tabla `alerta_fraude`.

## Bug real encontrado y corregido en esta misma ronda

La primera versión de `sincronizarAhora()` SÍ compartía el flag
`procesando` con el `@Interval` de 5s. Probado en vivo: bajo una ráfaga de
16 logins fallidos casi simultáneos contra la misma cuenta, casi todas las
llamadas a `sincronizarAhora()` se topaban con el mutex ya tomado (por la
llamada anterior, todavía en curso) y no hacían nada — el chequeo acotado
corría contra datos incompletos y **ninguna** alerta `_lenta` aparecía,
justo el caso (ráfaga rápida) que más importa acertar. Se corrigió
quitando el mutex de `sincronizarAhora()` — es seguro porque indexar en
Elasticsearch es idempotente por `_id` (el mismo de Mongo).

## Probado en vivo — 2026-09-15

Contra el servidor real y los contenedores reales (`mesh-postgres`,
`mesh-mongo`, `mesh-elastic`, `mesh-redis`). `npx tsc --noEmit` limpio
antes de cada arranque.

| Caso | Resultado |
|---|---|
| 16 fallos seguidos, cuenta nueva (umbral `fuerza_bruta_cuenta_lenta`: 15) | Fila nueva en segundos (no en 15 min), `fallos: 16` |
| 9 identificadores distintos, misma IP (umbral `multi_cuenta_ip_lenta`: 8) | Fila nueva en segundos, `cuentas_distintas: 12` (acumulado de la sesión) |
| `ip_rotacion_cuenta_lenta` (umbral: 5 IPs distintas) — 4 eventos sembrados en Mongo con IPs sintéticas + 1 login real como 5ta IP | Fila nueva, `ips_distintas: 5`, con la IP real (`127.0.0.1`) incluida en la evidencia |
| Latencia del login bajo carga de fondo | ~200-290ms constante, sin degradación |
| Worker de 15 min, tras ~15 min de wall-clock | Actualizó `multi_cuenta_ip_lenta` (contador 14→17) **sobre la misma fila** — confirma que el `ON CONFLICT` fusiona el disparo inmediato y el worker de respaldo, no duplica |
| Log del servidor durante toda la ronda | Sin errores ni warnings |

Detalle completo de la validación extensa (las 9 señales, panel de admin,
smoke-test de anillos) en la conversación de la sesión — no se repite
aquí porque no tocó archivos nuevos de este cambio en concreto.

## Lo que no se hizo en esta ronda (y por qué)

- **Notificación a usuario/admin** — segunda parte del pedido del
  profesor, explícitamente pospuesta a otra ronda (ver
  `2026-09-15_1500-notificacion-fraude-usuario.md`).
- **Eliminar el worker de 15 min** — sigue de respaldo a propósito (cubre
  una corrida concurrente saltada, o Elastic caído justo en el momento del
  login).
