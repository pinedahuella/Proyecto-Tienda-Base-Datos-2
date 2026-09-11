# El log de autenticación pasa de PostgreSQL a MongoDB

**Fecha:** 2026-09-10, mañana.
**Alcance:** solo `backend/`. Sin migraciones (colección nueva de Mongo, se
crea sola en el primer `insertOne`).

Primer paso del módulo de detección de fraude por login que propuso el
profesor (ver la memoria `elastic-fraude-vs-clickhouse-tendencias` y la
sección 4 de este documento). Este cambio **solo** mueve y enriquece el
registro; la sincronización a Elasticsearch y las consultas de fraude son
un segundo paso aparte.

## Qué cambió

### Antes

`LogService` escribía en las tablas `log_login` / `log_registro` de
PostgreSQL, con cuatro datos: `id_usuario`, `id_tipo_login`, `ip_origen`,
`fecha`. Solo se registraban **logins exitosos** (la llamada iba después de
que `iniciarSesion()` ya había tenido éxito), logout y registro.

### Ahora

`LogService` escribe en la colección **`eventos_autenticacion` de MongoDB**,
un documento por evento (modelo en `src/models/evento-autenticacion.ts`):

| Campo | Contenido |
|---|---|
| `tipo` | `login` / `logout` / `registro` |
| `resultado` | `exito` / `fallo` |
| `motivo` | por qué falló, o `null` en los éxitos: `credenciales_invalidas`, `usuario_inexistente`, `cuenta_inactiva`, `datos_invalidos` |
| `id_usuario` | id de la cuenta, o `null` cuando no se puede atribuir (login contra una cuenta inexistente, logout sin token válido) |
| `identificador_intentado` | el correo/usuario tecleado (en `registro`, el correo de la cuenta); `null` en `logout` |
| `ip` | `request.ip` de Fastify |
| `user_agent` | cabecera `User-Agent` cruda, o `null` |
| `huella_cliente` | SHA-256 de `user-agent` + `accept-language`; agrupa peticiones del mismo navegador honesto, **no** identifica de forma fiable (se falsea con una cabecera). `null` si no hay `User-Agent` |
| `fecha` | UTC, la pone el backend |

**Se registran ahora los intentos fallidos de login**, con el motivo fino.
El cliente sigue recibiendo **exactamente el mismo** 401 genérico
("Correo electronico, usuario o contrasena incorrectos") en los tres casos
de credenciales — el motivo viaja dentro de un `ErrorInicioSesion` nuevo
solo para el log, nunca a la respuesta HTTP, para no romper el
anti-enumeración.

### Las tablas de PostgreSQL

`log_login` y `log_registro` **siguen existiendo** (no se tocó ninguna
migración) pero el backend **ya no las escribe**. Quedan congeladas con su
contenido actual. Decisión del usuario: él coordina con el compañero el
repunte del ETL de ClickHouse que las leía (ver sección 4). Los modelos
`src/models/log-login.ts` y `log-registro.ts` quedan sin usar; se dejan
porque las tablas existen (`api.md` dice "un modelo por tabla que existe").

## Archivos tocados (todos en `backend/`)

| Archivo | Cambio |
|---|---|
| `src/models/evento-autenticacion.ts` | **nuevo** — el documento y sus tipos |
| `src/helpers/contexto-peticion.ts` | **nuevo** — extrae `ip` / `user_agent` / `huella_cliente` del `request`, para que `LogService` no dependa de Fastify |
| `src/helpers/errores.ts` | **nuevo** `ErrorInicioSesion extends ErrorSesion` — lleva `motivo` + `idUsuario` para el log, mismo 401 para el cliente |
| `src/services/log.service.ts` | reescrito: escribe `eventos_autenticacion` en Mongo; `registrarLoginExitoso` / `registrarLoginFallido` / `registrarLogout` / `registrarRegistro` |
| `src/services/usuario.service.ts` | `iniciarSesion()` parte el fallo genérico en tres `ErrorInicioSesion` (`usuario_inexistente` antes de `bcrypt` — mismo timing de siempre; `credenciales_invalidas`; `cuenta_inactiva`) |
| `src/controllers/usuario.controller.ts` | arma el `ContextoPeticion`, registra el login fallido en el `catch` clasificando el error, llama al log **sin `await`** |

## Por qué el log va sin `await` (fire-and-forget)

Con Mongo caído, `insertOne` tarda hasta 3 s en rendirse
(`serverSelectionTimeoutMS`, en `database/mongo.ts`). El login no tiene por
qué esperar eso: el evento es best-effort, igual que antes lo era el
`INSERT` a Postgres ("un log que no se pudo guardar no puede tumbar un
login que sí funcionó"). El controlador lo llama con `void`; `LogService`
traga su propio error y lo escribe en el log del servidor.

**Contrapartida, medida:** durante una caída de MongoDB **más larga que
~3 s**, los eventos de ese lapso **se pierden** (quedan en el log del
servidor como `ERROR [LogService]`). Una caída más corta que eso no los
pierde — el driver los reintenta al recuperarse. Una cola durable para no
perder ninguno queda fuera del alcance de este paso (sería el mismo patrón
outbox del grafo, o el worker de sincronización a Elasticsearch del paso 2).
Aun así es mejor que antes: con Postgres caído el login **fallaba entero**.

## Probado en vivo — 2026-09-10

Contra el servidor real (`172.22.192.1:3000`) y los contenedores `mesh-*`.
Script en el scratchpad, no en el repo (memoria `solo-backend`). **Los ~11
documentos de prueba quedan en `eventos_autenticacion` a propósito, para
que el usuario los revise.**

| # | Caso | Resultado |
|---|---|---|
| 1 | Login correcto | `200`, cookie puesta, doc `login/exito`, `motivo:null`, `id_usuario:"3"`, `ip`, `user_agent`, `huella_cliente` |
| 2 | Contraseña incorrecta (cuenta existe) | `401` mensaje genérico; doc `login/fallo`, `motivo:credenciales_invalidas`, **`id_usuario:"3"`** (la cuenta existe) |
| 3 | Identificador inexistente | `401` **mismo** mensaje; doc `motivo:usuario_inexistente`, `id_usuario:null` |
| 4 | Sin `contrasena` en el cuerpo | `400` "La contrasena es obligatoria"; doc `motivo:datos_invalidos`, `id_usuario:null` |
| 5 | Cuenta suspendida (estado 3, restaurada después) | `401` **mismo** mensaje; doc `motivo:cuenta_inactiva`, `id_usuario:"3"` |
| 6 | Login sin cabecera `User-Agent` | `200`; doc con `user_agent:null` y `huella_cliente:null` |
| 7 | Logout con cookie válida | `200`; doc `logout/exito`, `id_usuario:"3"`, `identificador_intentado:null` |
| 8 | Logout sin cookie | `200`; **ningún** documento nuevo (count 7→7) |
| 9 | Logout con token basura | `200`; **ningún** documento nuevo (count 7→7) |
| 10 | Registro correcto (usuario de prueba, borrado al final) | `201`; doc `registro/exito`, `id_usuario` nuevo, `identificador_intentado` = correo |
| 11 | Mongo caído (`docker stop mesh-mongo`), login | `200` en **0.13 s** (no ~3 s); evento perdido; `ERROR [LogService] ... MongoServerSelectionError` en el log; al volver Mongo, el login siguiente se guarda normal |
| 12 | `log_login` / `log_registro` de PostgreSQL | **sin cambios** — `24 → 24` y `0 → 0` tras toda la batería |

`npx tsc --noEmit` limpio. `eslint` sobre los 6 archivos tocados: limpio
(el repo arrastra ~84 violaciones de prettier preexistentes en archivos que
no se tocaron — ver `git status`; ninguna es de este cambio). Finales de
línea LF, como el resto de `src/`.

## 4. Lo que queda pendiente

### Del backend (paso 2, cuando el usuario cierre el alcance con el profesor)

- Sincronizar `eventos_autenticacion` → Elasticsearch (índice
  `mesh_eventos_autenticacion`) — **HECHO 2026-09-10**, con la bandera
  `pendiente_elastic` + worker `EventosAutenticacionSyncService`, mismo
  patrón que `BuscadorSyncService`. Ver
  `cambio_propuestas/2026-09-10_1020-sync-eventos-autenticacion-elastic.md`.
- Endpoints de consulta de fraude por login (`GET /admin/eventos/login/...`).
- Geolocalización de la IP (país/ciudad/coords/ASN) — se difirió a este
  paso; en local todas las IPs de prueba son privadas.
- `id_sesion` para emparejar login↔logout — se dejó fuera porque metería
  campo nuevo en el JWT (`firmarToken`, `TokenUsuario`, el guard); se puede
  hacer con una cookie aparte si se decide que hace falta.

### Del compañero (fuera de `backend/`)

- **Repuntar el ETL de ClickHouse.** `etl/extraer_eventos.sql` /
  `cargar_eventos.sh` leen `log_login` / `log_registro` de PostgreSQL, que
  ya no reciben filas nuevas. Las tablas `evento_login` / `evento_registro`
  de ClickHouse y el panel de fraude por IP quedan con datos congelados
  hasta que el ETL lea de `eventos_autenticacion` en Mongo.
- **Índices de la colección `eventos_autenticacion`** (en `mongo/`). Mínimo:
  `{id_usuario:1, fecha:-1}`, `{ip:1, fecha:-1}`,
  `{tipo:1, resultado:1, fecha:-1}`, `{identificador_intentado:1, fecha:-1}`,
  `{huella_cliente:1, fecha:-1}`, `{fecha:1}` (para el worker del paso 2).
- Decidir la retención de la colección (IP + UA es dato personal).
