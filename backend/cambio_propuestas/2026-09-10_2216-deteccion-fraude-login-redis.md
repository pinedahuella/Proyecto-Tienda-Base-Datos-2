# Detección reactiva de fraude de login (Redis) + alerta en PostgreSQL

**Fecha:** 2026-09-10, noche.
**Alcance:** `backend/`. Migración de referencia aplicada en local (no es
la migración real — le toca al compañero, ver abajo).

Tercera pieza del módulo de fraude por login (punto 4 de
`plan pendiente/fraude-login-eventos.md`). Las dos primeras
(`2026-09-10_0906-...md`, `2026-09-10_1020-...md`) dejaron los eventos en
Mongo y los sincronizaron a Elasticsearch — pero eso es **retrospectivo**
(consultas de horas/días). Esta pieza es la que responde a la pregunta del
usuario: "¿cómo hacemos que el sistema **por su cuenta**, **continuamente**,
detecte fuerza bruta / multi-cuenta?" — contadores de Redis en el propio
camino del login, sin esperar a ningún worker.

**Decisión explícita del usuario (2026-09-10):** se le preguntó "solo
alertar" vs "frenar activamente" al cruzar un umbral, y eligió **solo
alertar**. El sistema nunca bloquea ni retrasa un login por esto — cruzar
un umbral únicamente deja una fila para que un admin la revise.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/fraude-login-eventos.sql` | **nuevo** — referencia: `tipo_alerta_fraude`, `estado_alerta_fraude`, `alerta_fraude`. Aplicado en local |
| `src/models/alerta-fraude.ts` | **nuevo** — constantes de los catálogos + `FilaAlertaFraude`/`AlertaFraude` |
| `src/dto/paginar-alertas-fraude.ts` | **nuevo** — query/respuesta de `GET /admin/fraude/alertas-login` |
| `src/helpers/validaciones-fraude.ts` | **nuevo** — `validarFiltroEstadoAlerta` (mismo criterio que `validarFiltroActivo` de ofertas) |
| `src/services/fraude-login/fraude-login.service.ts` | **nuevo** — la detección (Redis → upsert en `alerta_fraude`) y el listado paginado |
| `src/controllers/usuario.controller.ts` | llama `fraudeLoginService.registrarIntento(...)` sin `await`, en éxito y en cada rama de fallo |
| `src/controllers/fraude/fraude.controller.ts` | + `GET /admin/fraude/alertas-login` |
| `src/app.module.ts` | registra `FraudeLoginService` |

Documentación: `endpoints-fraude.md` (sección nueva completa) y
`endpoints.md` (referencia actualizada). El plan (`fraude-login-eventos.md`)
marca el punto 4 como hecho y deja el punto 5 (worker retrospectivo sobre
Elasticsearch, mismo alcance que antes) como lo único que falta de esta
familia de señales.

### El esquema

`tipo_alerta_fraude` (catálogo, como `estado_oferta`/`motivo_movimiento`):
`fuerza_bruta_ip` (id 1), `fuerza_bruta_cuenta` (2), `multi_cuenta_ip` (3).
`estado_alerta_fraude`: `pendiente` (1), `revisada` (2), `descartada` (3).
`alerta_fraude`: `id_tipo_alerta_fraude`, `clave` (la IP o el
identificador, según el tipo), `id_usuario` (solo si `fuerza_bruta_cuenta`
apunta a una cuenta real), `detalle` (jsonb, evidencia), `contador`,
`ventana_inicio` (el minuto truncado de la detección), `id_estado_alerta_fraude`,
`id_usuario_reviso`/`fecha_revision` (para cuando exista el `PATCH`).
`UNIQUE(tipo, clave, ventana_inicio)` es la llave del UPSERT.

### La detección

Tres señales, `INCR`/`SADD` de Redis + `EXPIRE ... NX` (ventana fija, no se
alarga con cada intento):

| Señal | Ventana | Umbral |
|---|---|---|
| `fuerza_bruta_ip` | 60 s | 8 fallos |
| `fuerza_bruta_cuenta` | 60 s | 5 fallos |
| `multi_cuenta_ip` | 300 s | 4 identificadores distintos |

Al cruzar el umbral: `INSERT ... ON CONFLICT (tipo, clave, ventana_inicio)
DO UPDATE SET contador = contador + 1, detalle = ..., fecha_actualizacion = now()`.
Dedup por minuto: varios cruces seguidos en el mismo minuto suman
`contador` en una sola fila; el minuto siguiente, si el ataque sigue, abre
una fila nueva.

`registrarIntento()` nunca lanza (try/catch que solo loguea `warn`) y el
controlador la llama sin `await` — mismo criterio que `LogService`: si
Redis o Postgres no responden, se pierde esa señal puntual, el login
responde igual.

### El listado

`GET /admin/fraude/alertas-login` — paginado (`validarLimite`/`validarPagina`
de siempre), filtro opcional `estado`. Dos consultas en una transacción
`REPEATABLE READ READ ONLY` (mismo patrón que
`OfertasVendedorService.consultarOfertasPendientesPaginado`).

## Probado en vivo — 2026-09-10

Contra el servidor real (`npm run start:dev`) y los contenedores
(`mesh-redis`, `mesh-postgres`). Scripts de curl en el scratchpad.

| # | Caso | Resultado |
|---|---|---|
| 1 | 6 fallos en 60 s contra un identificador inexistente | `fallos_cuenta` → 6; alerta `fuerza_bruta_cuenta` nace en el fallo 5 (`contador: 1`), sube a `contador: 2` en el fallo 6 (mismo minuto) |
| 2 | 3 fallos más, 3 identificadores distintos, misma IP | `fallos_ip` → 9 (≥8) → alerta `fuerza_bruta_ip`; `cuentas_ip` → 4 (≥4) → alerta `multi_cuenta_ip` con los 4 identificadores en `detalle` |
| 3 | Login **exitoso** (admin real), misma IP | `200` normal; el identificador exitoso entra igual al set de `multi_cuenta_ip` (a propósito), la alerta existente sube de `contador` a 2 |
| 4 | 5 fallos de contraseña contra una cuenta real (`admin_mesh`) | alerta con `cuenta_involucrada: { id_usuario: "5", usuario: "admin_mesh" }` |
| 5 | `GET /admin/fraude/alertas-login` sin filtro | `200`, 3-4 alertas según el paso, `total_paginas` correcto |
| 6 | `...?estado=pendiente&limite=2` | `200`, 2 alertas, `total_paginas: 2` |
| 7 | `...?estado=basura` | `400` "El estado debe ser uno de: pendiente, revisada, descartada" |
| 8 | Sin cookie | `401` |
| 9 | `TTL` de `fallos_cuenta:admin_mesh` tras 5 intentos rápidos | 54 s — no se reinició a 60 en cada intento (confirma `EXPIRE ... NX`) |

`npx tsc --noEmit` limpio sobre todo el proyecto.

**Limpieza:** `DELETE FROM alerta_fraude` (quedaron 0 filas) + `redis-cli
--scan --pattern "mesh:fraude:*" | xargs DEL` (5 claves). A diferencia de
la sesión de Mongo/Elastic (donde se dejaron los docs de prueba a
propósito), aquí sí se limpió: una fila de `alerta_fraude` se lee como un
incidente de seguridad real en el panel del admin, y dejar 4 falsos
positivos con identificadores de prueba inventados confundiría la primera
vez que alguien abra esa pantalla.

## Lo que no se hizo en esta ronda (y por qué)

- **`PATCH` para marcar una alerta revisada/descartada.** No se pidió; se
  deja para cuando el frontend tenga la pantalla de triage (columnas
  `id_usuario_reviso`/`fecha_revision` ya están en el esquema, listas).
- **Geolocalización y las señales que dependen de ella** (viaje imposible,
  IP/ASN nueva) — punto 2 del plan, sigue sin decidir.
- **El worker retrospectivo sobre Elasticsearch** (punto 5 del plan) — esta
  ronda cubre solo la capa reactiva de Redis, que es la que responde
  directamente a "detectar por su cuenta, continuamente" sin depender de
  ningún worker externo.
- **Bloqueo o frenado del login.** Decisión explícita del usuario: solo
  alertar.

## Le toca al compañero (fuera de `backend/`)

Migración real de `alerta_fraude` (`fraude-login-eventos.sql` es solo la
referencia aplicada en local) — ver la sección "Compañero" del plan.
