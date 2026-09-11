# Toma de cuenta + patrones lentos/repartidos (Elasticsearch) sobre fraude de login

**Fecha:** 2026-09-11.
**Alcance:** `backend/`. Catálogo `tipo_alerta_fraude` ampliado (4 filas
nuevas) — mismo workflow de siempre: `.sql` de referencia aplicado en
local, la migración real la integra el compañero.

Cuarta y quinta pieza del módulo de fraude por login (punto 3 de
`plan pendiente/fraude-login-eventos.md`). Las anteriores dejaron el log en
Mongo, lo sincronizaron a Elasticsearch, y los contadores reactivos de
Redis. Esta ronda cubre **solo dos de las cuatro señales retrospectivas
posibles, por decisión explícita del usuario** en la conversación de
planificación: toma de cuenta y patrones lentos/repartidos. Viaje imposible
queda pendiente (depende de geolocalización, punto 2, sin decidir en el
backend — aunque en la misma conversación se validó por separado que
`geoip-lite` sirve: probado contra IPs públicas reales, incluyendo la IP de
prueba oficial de MaxMind y la IP real del usuario, con el cálculo de
distancia/velocidad funcionando correctamente). El panel de exploración
manual tampoco se pidió en esta ronda.

No hizo falta índice ni tabla nueva: las dos señales caen en la misma
`alerta_fraude` que ya usa Redis — solo se amplió el catálogo
`tipo_alerta_fraude` de 3 a 7 filas.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `elementos Generales/plan pendiente/fraude-login-eventos.sql` | ampliado — 4 filas nuevas en `tipo_alerta_fraude` (ids 4-7). Reaplicado en local |
| `src/models/alerta-fraude.ts` | + 4 constantes `ID_TIPO_ALERTA_FRAUDE_*`, `TipoAlertaFraude` ampliado a 7 valores |
| `src/helpers/registrar-alerta-fraude.ts` | **nuevo** — el UPSERT de `alerta_fraude`, extraído de `FraudeLoginService.registrarAlerta` para compartirlo entre los tres servicios que ahora escriben alertas |
| `src/services/fraude-login/toma-cuenta.service.ts` | **nuevo** — `TomaCuentaService`, dispara en cada login exitoso |
| `src/services/fraude-login/fraude-login-retrospectivo.service.ts` | **nuevo** — `FraudeLoginRetrospectivoService`, worker `@Interval` cada 15 min |
| `src/controllers/usuario.controller.ts` | llama `tomaCuentaService.revisarLogin(...)` sin `await`, junto a `fraudeLoginService.registrarIntento(...)`, solo en éxito |
| `src/services/fraude-login/fraude-login.service.ts` | usa el helper compartido de UPSERT; `consultarAlertasPaginado`/`listarAlertasPaginado` reciben el filtro `tipo` |
| `src/dto/paginar-alertas-fraude.ts` | + `tipo` en `PaginarAlertasFraudeQuery`, + `TIPOS_ALERTA_FRAUDE_VALIDOS` |
| `src/helpers/validaciones-fraude.ts` | + `validarFiltroTipoAlerta` (mismo molde que `validarFiltroEstadoAlerta`) |
| `src/app.module.ts` | registra `TomaCuentaService` y `FraudeLoginRetrospectivoService` |

Documentación: `endpoints/endpoints-fraude.md` (sección
`GET /admin/fraude/alertas-login` reescrita para las 7 señales) y
`plan pendiente/fraude-login-eventos.md` (punto 3 actualizado, punto 5
resuelto: no hizo falta tabla aparte).

### El catálogo

`tipo_alerta_fraude` pasa de 3 a 7 filas: `fuerza_bruta_ip` (1),
`fuerza_bruta_cuenta` (2), `multi_cuenta_ip` (3) — sin cambios — más
`toma_cuenta` (4), `fuerza_bruta_cuenta_lenta` (5), `multi_cuenta_ip_lenta`
(6), `ip_rotacion_cuenta` (7). Nada más cambia en `alerta_fraude` — mismas
columnas, mismo `UNIQUE(tipo, clave, ventana_inicio)`.

**Nota sobre los ids en la base LOCAL:** al aplicar el `.sql` de referencia
por segunda vez, el `smallserial` de `tipo_alerta_fraude` ya venía con un
hueco (ids 4-6 nunca insertados, de pruebas anteriores que se revirtieron)
y las 4 filas nuevas cayeron primero en 7-10. Se realinearon a mano
(`DELETE` + `INSERT` con id explícito + `setval`) para que coincidan con
los ids que la migración real va a producir de verdad (7 filas insertadas
en orden sobre una tabla recién creada = ids 1-7), que es contra lo que
`models/alerta-fraude.ts` fija sus constantes. Detalle completo en la
sección "Compañero" del plan.

### Toma de cuenta (`TomaCuentaService`)

Dispara **en cada login exitoso** (no en el worker de 15 min): es un
chequeo puntual de una cuenta, no una agregación periódica, así que encaja
en el mismo punto donde ya se llama `fraudeLoginService.registrarIntento`
— fire-and-forget, nunca bloquea el login, nunca lanza.

Dos agregaciones `terms` (tamaño 1000) contra `mesh_eventos_autenticacion`,
filtradas por `id_usuario.keyword` + `tipo.keyword: login` +
`resultado.keyword: exito`: IPs conocidas y huellas conocidas de la cuenta.
Si el historial de logins exitosos previos es menor a 3, no evalúa nada
(evita marcar el primer login de una cuenta nueva). Si la IP actual no está
en las conocidas, nace la alerta `toma_cuenta` — la huella es señal
corroborante en el `detalle`, no dispara ella sola (se falsea cambiando una
cabecera, es más débil que la IP).

**Limitación conocida, no resuelta:** una IP dinámica de ISP puede cambiar
sin que el usuario se haya movido — falsos positivos ocasionales posibles;
no se ajustó el umbral sin datos reales.

### Patrones lentos/repartidos (`FraudeLoginRetrospectivoService`)

Worker `@Interval` cada 15 min (mismo molde que
`EventosAutenticacionSyncService`/`GrafoSyncService`: flag `procesando`,
`try/catch` que solo loguea). Tres agregaciones contra
`mesh_eventos_autenticacion`, ventana `fecha >= now-24h`:

| Señal | Agregación | Umbral |
|---|---|---|
| `fuerza_bruta_cuenta_lenta` | `terms(identificador_intentado.keyword)` + `min_doc_count`, filtro `resultado: fallo` | 15 fallos |
| `multi_cuenta_ip_lenta` | `terms(ip.keyword)` + `cardinality(identificador_intentado.keyword)` + `bucket_selector` | 8 cuentas distintas |
| `ip_rotacion_cuenta` | `terms(identificador_intentado.keyword)` + `cardinality(ip.keyword)` + `bucket_selector` | 5 IPs distintas |

Elasticsearch entrega la lista de sospechosos **ya filtrada**
(`min_doc_count`/`bucket_selector`) — el worker no decide a quién mirar,
solo convierte cada bucket en una fila de `alerta_fraude` vía el helper
compartido. `ventana_inicio` se trunca a la **hora** (no al minuto, como
Redis y toma de cuenta): con un intervalo de 15 min, truncar al minuto
crearía una fila casi en cada corrida mientras el patrón siga activo.

Los tres umbrales (15/8/5) son una propuesta razonable, no datos medidos
contra tráfico real — constantes fáciles de ajustar.

### El listado — filtro `tipo` nuevo

`GET /admin/fraude/alertas-login?tipo=toma_cuenta` — con 7 tipos mezclados
en un solo listado, hacía falta poder acotar. `validarFiltroTipoAlerta`
(mismo molde que `validarFiltroEstadoAlerta`), interpolado en el `WHERE`
tras pasar por la lista blanca — mismo criterio que `condicionEstado`.

## Probado en vivo — 2026-09-11

Contra el servidor real (`npm run start:dev`) y los contenedores
(`mesh-postgres`, `mesh-mongo`, `mesh-elastic`, `mesh-redis`). Scripts en
el scratchpad, no en el repo.

### Toma de cuenta

Cuenta real `comprador_sur` (id 3, historial real de logins desde
`172.22.192.1`). Se sembraron 3 logins exitosos sintéticos más desde
`203.0.113.5` insertando en Mongo con `pendiente_elastic: true` (pasando
por el `EventosAutenticacionSyncService` real, no un atajo directo a
Elasticsearch) y esperando su indexado (confirmado con una consulta directa
al índice).

| # | Caso | Resultado |
|---|---|---|
| 1 | Login real, exitoso, desde `127.0.0.1` (IP nunca vista para la cuenta; historial de 12 logins exitosos ≥ 3) | alerta `toma_cuenta` (id 19): `{"ip_nueva":"127.0.0.1","huella_nueva":true,"ips_conocidas":2,"logins_exitosos_previos":12}` |
| 2 | Segundo login real, misma cuenta, misma IP (`127.0.0.1`, ya indexada tras el login #1) | no nace una alerta nueva — sigue siendo la id 19, sin duplicar |
| 3 | Cuenta con solo 2 logins exitosos previos (`admin_mesh`, antes de esta prueba) | no se evaluó nada — `MINIMO_HISTORIAL = 3` |
| 4 | `GET /admin/fraude/alertas-login?tipo=toma_cuenta` (sesión admin real) | `200`, exactamente la alerta de arriba |
| 5 | `...?tipo=fuerza_bruta_cuenta_lenta` (sin datos de ese tipo aún en ese momento) | `200`, `alertas: []` — no un error |
| 6 | `...?tipo=no-existe` | `400`, mensaje con los 7 tipos válidos |

### Patrones lentos/repartidos

Las tres agregaciones se validaron **exactas** — mismo índice, mismos
nombres de campo, mismo script de `bucket_selector` que el código — contra
Elasticsearch real, con datos sembrados vía Mongo (31 documentos
sintéticos, `pendiente_elastic: true`, mismo pipeline real):

| # | Caso sembrado | Resultado de la agregación real |
|---|---|---|
| 1 | 16 fallos en ~20h contra `victima.lenta@mesh.test`, rotando entre 5 IPs | `fuerza_bruta_cuenta_lenta`: 1 bucket, `doc_count: 16` (≥15) |
| 2 | 9 identificadores distintos probados desde `198.51.100.9` en ~20h | `multi_cuenta_ip_lenta`: 1 bucket, `cardinalidad: 9` (≥8), `muestra` con los 9 |
| 3 | `rotador@mesh.test` probado desde 6 IPs distintas en ~20h | `ip_rotacion_cuenta`: 1 bucket, `cardinalidad: 6` (≥5) |
| 4 | (efecto colateral esperado) `victima.lenta@mesh.test` también rota entre 5 IPs | también cruza `ip_rotacion_cuenta` (5 ≥5) — correcto: un ataque real que además rota IP dispara las dos señales, no es un bug |
| 5 | Cuentas/IPs bajo el umbral en la misma ventana | no aparecen en ningún bucket — el filtro lo aplica Elasticsearch (`min_doc_count`/`bucket_selector`), no el backend |

El worker real (`FraudeLoginRetrospectivoService`, `@Interval` de 15 min,
con el backend corriendo vía `npm run start:dev`) se dejó vivo contra estos
mismos datos sembrados para confirmar el ciclo completo — no solo la
consulta, también la escritura en `alerta_fraude` — con una espera en
segundo plano (`docker exec` a Postgres cada 15-30 s) en vez de bloquear la
sesión 15 minutos.

**Confirmado: en su primer ciclo real, el worker escribió exactamente las 4
filas esperadas**, sin intervención manual:

| `id_alerta_fraude` | `tipo_alerta` | `clave` | `detalle` |
|---|---|---|---|
| 20 | `fuerza_bruta_cuenta_lenta` | `victima.lenta@mesh.test` | `{"fallos":16,"ventana_horas":24}` |
| 21 | `multi_cuenta_ip_lenta` | `198.51.100.9` | `{"cuentas_distintas":9,"ventana_horas":24,"identificadores":[...9]}` |
| 22 | `ip_rotacion_cuenta` | `victima.lenta@mesh.test` | `{"ips_distintas":5,"ventana_horas":24,"ips":[...5]}` |
| 23 | `ip_rotacion_cuenta` | `rotador@mesh.test` | `{"ips_distintas":6,"ventana_horas":24,"ips":[...6]}` |

Las filas 20-23 coinciden exactamente con la validación previa contra
Elasticsearch directo (arriba) — mismo `doc_count`/`cardinalidad` en cada
una. `GET ...?tipo=ip_rotacion_cuenta` devolvió `total_alertas: 2` (las
filas 22 y 23, la cuenta que rota Y ataca por fuerza bruta cuenta dos
veces, correctamente) y el listado sin filtro subió de 2 a 6 alertas
totales.

Nota sobre el tiempo de esta prueba: un `eslint --fix` aplicado a mitad de
sesión reinició el backend (`--watch` de Nest se reinicia solo con cada
cambio de archivo), lo que reinició también el temporizador del `@Interval`
— la primera espera en segundo plano (18 min) venció unos segundos antes
del ciclo real; una segunda espera de 5 min, ya alineada con el nuevo
horario, sí lo capturó.

`npx tsc --noEmit` limpio sobre todo el proyecto.

**Limpieza:** `DELETE FROM alerta_fraude WHERE id_alerta_fraude BETWEEN 19
AND 23` (las 5 filas de esta prueba; la 18 es de una ronda anterior, no se
tocó) y `db.eventos_autenticacion.deleteMany({identificador_intentado:
{$regex: "mesh.test$"}})` más `ip: "203.0.113.5"` en Mongo, con su réplica
en Elasticsearch (`_delete_by_query` sobre los mismos filtros). El regex de
`identificador_intentado` terminado en `mesh.test` también arrastró 14
documentos sintéticos que no eran de esta sesión (de pruebas anteriores del
mismo módulo, identificadores tipo `demo.fraude@mesh.test`) — se dejan
fuera a propósito: es basura de prueba vieja, no datos reales, y su
limpieza no afecta ninguna alerta ya existente (esas viven en
`alerta_fraude`/Postgres, no dependen de los documentos de Mongo). La
colección `eventos_autenticacion` quedó en 24 documentos reales.

## Lo que no se hizo en esta ronda (y por qué)

- **Viaje imposible.** Depende del punto 2 (geolocalización), que sigue sin
  decidirse en el backend — aunque ya se validó por separado que
  `geoip-lite` sirve (IPs públicas reales, incluida la IP de prueba oficial
  de MaxMind para verificar precisión, y el cálculo de distancia/velocidad
  con haversine). Queda como la siguiente pieza natural cuando se decida
  ese punto.
- **Panel de exploración manual.** No se pidió en esta ronda.
- **`PATCH` para marcar una alerta revisada/descartada.** Sigue sin
  construirse — no se pidió, se deja para cuando el frontend tenga la
  pantalla de triage (igual que se dejó anotado en la ronda de Redis).
- **Bloqueo o frenado del login.** Decisión explícita del usuario, vigente
  desde la ronda de Redis: el sistema solo alerta.

## Le toca al compañero (fuera de `backend/`)

Migración real de las 4 filas nuevas de `tipo_alerta_fraude` — el `.sql` de
referencia (`fraude-login-eventos.sql`) ya las incluye en el orden
correcto. Ver la sección "Compañero" del plan, incluida la nota sobre por
qué los ids locales tuvieron que realinearse a mano.
