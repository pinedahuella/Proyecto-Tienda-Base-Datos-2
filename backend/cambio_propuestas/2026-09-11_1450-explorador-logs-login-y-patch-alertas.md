# Explorador manual de logs de login + PATCH para marcar alertas

**Fecha:** 2026-09-11, cuarta ronda del día (después de
`2026-09-11_1002-toma-cuenta-patrones-lentos-elastic.md`,
`2026-09-11_1045-ip-rotacion-cuenta-redis.md` y
`2026-09-11_1242-viaje-imposible.md`).
**Alcance:** `backend/`, solo archivos nuevos + `app.module.ts` +
`helpers/validaciones-fraude.ts` (aditivo). No se tocó `FraudeController`
ni `FraudeLoginService`.

## Decisiones tomadas en esta ronda (confirmadas por el usuario antes de codear)

1. **Controller y servicio nuevos**, separados de `FraudeController`/
   `FraudeLoginService` — no se extendió el controller de `anillos`/
   `alertas-login`.
2. **La "búsqueda" sobre los logs es filtro exacto (`term`), no texto
   difuso** — los campos disponibles (`ip`, `identificador_intentado`,
   `huella_cliente`) son identificadores, no descripciones.
3. **El `PATCH` aplica a las 9 señales por igual**, sin distinguir si la
   alerta nació de Redis o de Elasticsearch — todas viven en la misma tabla
   `alerta_fraude`.
4. **Solo se admite la transición desde `pendiente`** — una alerta ya
   revisada o descartada no se puede volver a mover desde esta ruta (409 si
   se intenta). Nunca se puede reabrir a `pendiente`.
5. **`incluir_usuario` en el explorador — ambas versiones a propósito,
   conviven en el código, no una descarta a la otra.** Sin la bandera, la
   respuesta trae solo `id_usuario`, sin ningún viaje adicional a Postgres.
   Con `incluir_usuario=true`, un lookup batch (un `WHERE id_usuario =
   ANY($1)`, nunca una consulta por evento) agrega el `usuario` de cada
   cuenta. Se dejaron las dos a propósito para poder medir el costo real
   del enriquecimiento contra la versión base, antes de decidir cuál usa el
   frontend por defecto.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/dto/paginar-eventos-autenticacion.ts` | **nuevo** — query de `GET /admin/fraude/eventos-login`, forma de un evento y de la respuesta paginada, listas de valores válidos (tipo/resultado/motivo) |
| `src/dto/marcar-alerta-fraude.ts` | **nuevo** — cuerpo de `PATCH /admin/fraude/alertas-login/:id` |
| `src/helpers/validaciones-fraude.ts` | + `validarNuevoEstadoAlerta`, `validarIdAlertaFraude`, `validarFiltroTipoEvento`, `validarFiltroResultadoEvento`, `validarFiltroMotivoEvento`, `validarFiltroIdUsuarioEvento`, `validarFiltroTextoEvento`, `validarRangoFechasEvento`, `validarIncluirUsuarioEvento` — todo aditivo, no se tocó lo existente |
| `src/services/fraude-login/fraude-login-exploracion.service.ts` | **nuevo** — `FraudeLoginExploracionService`: `listarEventosPaginado` (lee Elasticsearch) + `marcarAlerta` (escribe Postgres) |
| `src/controllers/admin/admin-fraude-login.controller.ts` | **nuevo** — `AdminFraudeLoginController`, las dos rutas |
| `src/app.module.ts` | registra el controller y el servicio nuevos |

Documentación: `endpoints/endpoints-fraude.md` (dos secciones nuevas
completas, con ejemplos y pruebas) y `plan pendiente/fraude-login-eventos.md`
(puntos 3 y 5 marcados HECHO).

### `GET /admin/fraude/eventos-login` — el explorador

Query a Elasticsearch armada con `bool.filter` (uno por cada parámetro
presente), `sort: fecha desc`, `from`/`size` para la paginación,
`track_total_hits: true` para el conteo exacto. Cada evento se mapea desde
`hit._source` a la forma de API, reconstruyendo `geo` como
`{lat, lon, pais, ciudad}` a partir de los tres campos sueltos del índice
(`geo_punto`/`geo_pais`/`geo_ciudad` — ver
`2026-09-11_1242-viaje-imposible.md` para el porqué de esa forma aplanada).

```ts
const filtros = [];
if (tipo) filtros.push({ term: { 'tipo.keyword': tipo } });
// ... un term por cada filtro presente ...
if (desde || hasta) filtros.push({ range: { fecha: { gte, lte } } });

const respuesta = await elasticClient.search({
  index: INDICE, from: saltar, size: limite, track_total_hits: true,
  sort: [{ fecha: 'desc' }],
  query: filtros.length > 0 ? { bool: { filter: filtros } } : { match_all: {} },
});
```

### `PATCH /admin/fraude/alertas-login/:id` — marcar revisada/descartada

Un `UPDATE ... WHERE id = $1 AND id_estado_alerta_fraude = <pendiente>
RETURNING id_alerta_fraude`. Si no actualiza ninguna fila, una segunda
consulta (`SELECT 1 FROM alerta_fraude WHERE id = $1`) distingue 404 (no
existe) de 409 (existe, ya no está pendiente). Si actualizó, una tercera
consulta (mismos `JOIN` que `FraudeLoginService.consultarAlertasPaginado`)
trae la fila completa para la respuesta. El mapeo `fila -> AlertaFraude` se
**duplicó** (chico, ~15 líneas) en vez de exportarlo desde
`fraude-login.service.ts`, para no tocar ese archivo — mismo criterio que
`mensajeCorto()`, ya repetido en varios servicios del módulo.

## Probado en vivo — 2026-09-11

Contra el servidor y las bases reales (`mesh-elastic`, `mesh-postgres`,
`mesh-redis`, `mesh-neo4j`, todos `healthy`), `npm run start:dev`
(`npx tsc --noEmit` limpio antes de arrancar). Sesiones reales: `admin_mesh`
(`Admin123`) y `compradora.norte@mesh.com` (`Comprador123`). Scripts curl
en el scratchpad, no en el repo.

### `GET /admin/fraude/eventos-login`

| Caso | Resultado |
|---|---|
| Sin filtros, `limite=3` | `200`, 3 eventos, `total_eventos: 28`, `incluyo_usuario: false`, ningún evento trae `cuenta_involucrada` |
| Igual, `incluir_usuario=true` | `200`, mismos 3 eventos, cada uno con `cuenta_involucrada: {"id_usuario":"5","usuario":"admin_mesh"}` |
| `tipo=login&resultado=exito&ip=172.22.192.1&limite=2` | `200`, `total_eventos: 12`, solo esa combinación |
| `identificador=admin_mesh&limite=1` | `200`, `total_eventos: 10` |
| `id_usuario=5&limite=1` | `200`, evento del admin |
| `geo_pais=Guatemala&limite=2` | `200`, `eventos: []`, `total_eventos: 0` — sin datos con esa geo en el entorno local, no es un error |
| `tipo=noexiste` | `400` "El tipo debe ser uno de: login, logout, registro" |
| `fecha_desde=no-es-fecha` | `400` "fecha_desde debe ser una fecha valida (ISO 8601)" |
| `fecha_desde=2026-09-11&fecha_hasta=2026-09-01` | `400` "fecha_desde no puede ser posterior a fecha_hasta" |
| Sin cookie | `401` |
| Sesión comprador | `403` |

### `PATCH /admin/fraude/alertas-login/:id`

Contra una alerta real y pendiente (`id_alerta_fraude: 18`,
`fuerza_bruta_cuenta`, sembrada en una ronda anterior — `clave:
"demo.fraude@mesh.test"`).

| Caso | Resultado |
|---|---|
| `{"estado":"revisada"}` sobre la 18 (pendiente) | `200`, `estado: "revisada"` |
| Mismo `PATCH` otra vez | `409` "La alerta ya no esta pendiente de revision" |
| `PATCH` sobre id `999999` | `404` "No existe una alerta con ese id" |
| `{"estado":"pendiente"}` (destino inválido) | `400` "El estado debe ser uno de: revisada, descartada" |
| `PATCH` sobre id `abc` | `400` "El id de la alerta debe ser un numero entero" |
| Sesión comprador | `403` |

`npx tsc --noEmit` limpio antes y después de las pruebas.

**Limpieza:** la alerta 18 se restauró a `pendiente` (`UPDATE ...
id_estado_alerta_fraude = 1`) al terminar — era una alerta real, no un dato
descartable de esta prueba. No se creó ni se borró ningún documento
sintético en Mongo/Elasticsearch: el explorador es de solo lectura y se
probó contra los eventos reales generados por los propios logins de
prueba.

## Lo que no se hizo en esta ronda (y por qué)

- **Enriquecer la respuesta con más que `usuario`** (por ejemplo nombre y
  apellido) — no se pidió; `incluir_usuario` resuelve exactamente lo que se
  preguntó (¿vale la pena el lookup extra?), no una vista de perfil
  completa.
- **Decidir cuál de las dos versiones (`incluir_usuario` true/false) usa el
  frontend por defecto** — a propósito: se deja para medir el costo real
  antes de decidir.
- **Vistas agregadas sobre el explorador** ("todas las cuentas que
  comparten este dispositivo", "el mapa de un usuario") — el endpoint es
  el listado crudo filtrado; una agregación así sería una ruta aparte.
- **Bloqueo o frenado del login** — decisión explícita del usuario, vigente
  desde la primera ronda: el sistema solo alerta.
