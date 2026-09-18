# Corrección: alertas de fraude con varios afectados (pivote de columna a tabla)

**Fecha:** 2026-09-15, tercera ronda del día (después de
`2026-09-15_1130-fraude-login-disparo-inmediato.md` y
`2026-09-15_1500-notificacion-fraude-usuario.md`).
**Alcance:** `backend/`. Reemplaza el esquema de la ronda anterior
(columna `fecha_lectura_usuario`) por una tabla nueva
(`notificacion_fraude`) — la migración real nunca se mandó, así que esto
corrige el diseño en el lugar, no lo apila.

## Contexto

Al revisar el esquema de notificaciones ya construido, el usuario notó que
`multi_cuenta_ip` (una IP probando muchas cuentas distintas) no tenía a
quién avisarle del lado usuario — la alerta no tiene un `id_usuario` único
(el origen es la IP), así que la columna de la ronda anterior nunca se
llenaba para esa señal, aunque el `detalle.identificadores` ya traía la
lista de cuentas probadas. La pregunta llevó a notar que el problema es
más general: una alerta puede involucrar a VARIAS cuentas a la vez, y una
columna no puede representar eso.

## Decisión resuelta con el usuario antes de codear

Única pregunta abierta: si el `detalle` que ve la cuenta afectada por
`multi_cuenta_ip`/`multi_cuenta_ip_lenta` debía incluir los
correos/usuarios de las DEMÁS cuentas también afectadas (lo mismo que ve
admin) o una versión resumida. Se decidió **resumida**: solo el conteo
(`cuentas_distintas`), sin exponer a nadie más — es la única pieza
genuinamente nueva de privacidad/seguridad de esta ronda, todo lo demás ya
estaba decidido en rondas anteriores.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/notificacion-fraude-usuario.sql` | reescrito: `DROP COLUMN fecha_lectura_usuario` + `CREATE TABLE notificacion_fraude` |
| `elementos Generales/plan pendiente/notificacion-fraude-usuario.md` | reescrito para reflejar el diseño corregido (no se conserva la versión descartada, ver la nota de estado al inicio) |
| `src/helpers/registrar-alerta-fraude.ts` | reescrito: transacción completa (antes un solo `pool.query`), `xmax = 0` para distinguir INSERT de UPDATE del `ON CONFLICT`, nueva función `resolverCuentasDestino` (genérica: mira la FORMA de `detalle`, no hardcodea qué tipo de alerta es) |
| `src/models/alerta-fraude.ts` | `FilaAlertaFraude`/`AlertaFraude.cuenta_involucrada` (objeto\|null) → `cuentas_afectadas` (array), nuevo tipo `CuentaAfectada` |
| `src/services/fraude-login/fraude-login.service.ts` | consulta admin con `SQL_CUENTAS_AFECTADAS` (subconsulta `json_agg` correlacionada); las tres consultas de usuario (`consultarAlertasPaginadoUsuario`, `marcarLeida`, `obtenerAlertaUsuarioPorId`) reescritas contra `notificacion_fraude` en vez de la columna; nueva función `detalleParaUsuario` (redacción) |
| `src/services/fraude-login/fraude-login-exploracion.service.ts` | mismo cambio de consulta en `obtenerAlertaPorId` (el `PATCH` de admin), mismo criterio de duplicar en vez de compartir |

No se tocó ningún controller: los cuatro endpoints (`GET`/`PATCH` de admin
y de usuario) son pass-through puro, solo cambió lo que el servicio
devuelve.

## Bug real encontrado y corregido en esta misma ronda

`id_usuario` dentro de `cuentas_afectadas` salía como número JSON (`16`),
no como texto — inconsistente con el resto de la API. `json_build_object`
de Postgres serializa el valor de la columna tal cual es (un `bigint` sale
como número JSON); hacía falta `nf.id_usuario::text` explícito dentro del
`json_build_object`. Se corrigió en las dos copias de
`SQL_CUENTAS_AFECTADAS` antes de seguir probando.

## Probado en vivo — 2026-09-15

Contra el servidor real, 3 cuentas de prueba nuevas
(`multicuenta_test_a/b/c`) más `prueba_admin_fraude` (que se sumó sin
querer al loguearse para las pruebas de admin), todas probadas desde
`127.0.0.1` en un `multi_cuenta_ip` real, más un identificador
(`multicuenta_test_fantasma`) que no correspondía a ninguna cuenta.

| Caso | Resultado |
|---|---|
| Las 4 cuentas reales probadas desde la misma IP | `notificacion_fraude` nace con exactamente 4 filas, una por cuenta |
| `multicuenta_test_fantasma` | no genera fila — solo queda en `detalle.identificadores` para admin |
| `GET /perfil/alertas-fraude` de cada una de las 4 cuentas | cada una trae la alerta, `detalle` sin `identificadores` |
| `PATCH` de una cuenta | esa queda con `fecha_lectura`, las otras 3 siguen en `null` |
| `GET /admin/fraude/alertas-login` después | ve exactamente qué cuentas ya leyeron y cuáles no |
| Repetir el ataque en la misma ventana (`contador` 1→2) | `notificacion_fraude` sigue en 4 filas — no duplica |
| `PATCH` desde una cuenta genuinamente ajena | `404` |
| Alerta de una sola cuenta, de ANTES de esta tabla (`toma_cuenta`) | `cuentas_afectadas: []` — sin backfill, aceptado |
| Alerta de una sola cuenta, fresca (`fuerza_bruta_cuenta`) | `cuentas_afectadas` con 1 elemento |
| `fuerza_bruta_ip` | `cuentas_afectadas: []` |

Confirmado por SQL directo: marcar `notificacion_fraude.fecha_lectura` no
toca `alerta_fraude.fecha_actualizacion` ni `id_estado_alerta_fraude`.

`npx tsc --noEmit` limpio. Sin errores ni warnings inesperados en el log
del servidor durante toda la ronda.

## Lo que no se hizo en esta ronda (y por qué)

- **Backfill de `notificacion_fraude` para alertas ya existentes** — no se
  pidió; las alertas de prueba de rondas anteriores simplemente no tienen
  notificaciones retroactivas. Aceptado, no es un problema para datos de
  prueba locales.
- **Extender este mecanismo a los anillos de reseñas (Neo4j)** —
  explícitamente fuera de esta ronda ("no te metas con grafos de
  momento"); esos ni siquiera tienen persistencia hoy, es trabajo aparte.
- **Actualizar `MESH.postman_collection.json`** — mismo criterio que la
  ronda anterior, no es un artefacto que este módulo mantenga
  sincronizado.
