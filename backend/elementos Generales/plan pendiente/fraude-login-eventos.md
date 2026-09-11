# Detección de fraude por eventos de login

Módulo propuesto por el profesor: guardar los eventos de autenticación y
consultarlos desde Elasticsearch para detectar abuso (fuerza bruta,
multi-cuenta desde un mismo navegador/IP, viaje imposible, toma de cuenta).
Contexto y reparto Elasticsearch vs ClickHouse en la memoria
`elastic-fraude-vs-clickhouse-tendencias`.

**Antes de seguir con el paso 2, el usuario tiene que cerrar con el
profesor:** si este módulo reemplaza, completa o se reparte con el panel de
fraude **por IP en ClickHouse** (que todavía no está implementado en el
backend), y si el alerting automático entra en la rúbrica de la Entrega 3 o
basta con paneles de consulta.

---

## Paso 1 — el registro en Mongo — HECHO (2026-09-10)

Detalle y pruebas en
`cambio_propuestas/2026-09-10_0906-eventos-autenticacion-mongo.md`.

- `LogService` escribe la colección **`eventos_autenticacion`** de MongoDB
  (antes: tablas `log_login` / `log_registro` de PostgreSQL, que siguen
  existiendo pero ya no se escriben).
- Un documento por `login` (exitoso **y fallido**, con `motivo` fino),
  `logout` y `registro`. Campos: `tipo`, `resultado`, `motivo`,
  `id_usuario`, `identificador_intentado`, `ip`, `user_agent`,
  `huella_cliente` (SHA-256 de `user-agent` + `accept-language`), `fecha`.
- El cliente sigue recibiendo el mismo 401 genérico en todos los fallos de
  credenciales; el `motivo` viaja en `ErrorInicioSesion` solo para el log.
- Escritura best-effort sin `await`: con Mongo caído el login no se retrasa
  (se pierde el evento del lapso de caída > ~3 s).

---

## Paso 2 — Elasticsearch + consultas de fraude

### Backend (`backend/`)

1. **Sincronizador `eventos_autenticacion` → Elasticsearch — HECHO
   (2026-09-10).** Índice `mesh_eventos_autenticacion`. Se hizo con la
   **bandera `pendiente_elastic`** en el propio documento + worker
   `@Interval` de 5 s (`EventosAutenticacionSyncService`), mismo patrón que
   `BuscadorSyncService`. El `_id` de Mongo se reutiliza como `_id` en
   Elastic (reindexar es idempotente). Detalle y pruebas en
   `cambio_propuestas/2026-09-10_1020-sync-eventos-autenticacion-elastic.md`.
   Falta que el compañero cree el índice con **mapping explícito** (`keyword`
   para `ip`/`motivo`/`tipo`/`resultado`/`id_usuario`/`huella_cliente`/
   `identificador_intentado`, `date` para `fecha`) — hoy las agregaciones
   funcionan vía `.keyword` del mapping dinámico.
2. **Enriquecer con geolocalización de la IP** (país, ciudad, lat/lon, ASN,
   organización). Se difirió del paso 1. Decisión pendiente: base offline
   embebida (MaxMind GeoLite2 / `geoip-lite`) vs API externa (mete un
   tercero y latencia). En local no aplica: las IPs de prueba son privadas.
3. **Endpoints de consulta** (solo admin, `SesionGuard` + `@Roles(ID_ROL_ADMIN)`,
   mismo criterio que fraude de reseñas y buscador admin):
   - `GET /admin/eventos/login/...` — series y agregaciones para el panel.
   - Señales: fallos por identificador/IP en ventana (fuerza bruta),
     `cardinality(id_usuario)` por `ip`/`huella_cliente` (multi-cuenta),
     `geo_distance` contra la ubicación habitual (viaje imposible), IP/ASN
     nuevo para una cuenta tras varios fallos (toma de cuenta).
4. **Detección reactiva en tiempo real — contadores en Redis en el camino
   del login — HECHO (2026-09-10).** Por decisión explícita del usuario:
   esto **solo alerta, nunca frena el login** (se preguntó directamente:
   "solo alertar" vs "frenar activamente", y se eligió alertar). Tres
   señales, `INCR`/`SADD` + `EXPIRE ... NX` de ventana fija en el propio
   `UsuarioController` (sin `await`, igual que `LogService` — best-effort,
   nunca retrasa el login): `fuerza_bruta_ip` (8 fallos/60s),
   `fuerza_bruta_cuenta` (5 fallos/60s), `multi_cuenta_ip` (4 identificadores
   distintos/300s). Al cruzar el umbral se escribe (UPSERT, deduplicado por
   minuto) una fila en la tabla nueva `alerta_fraude` (Postgres) —
   `FraudeLoginService`, esquema en `fraude-login-eventos.sql` (mismo
   folder). Listado para el admin: `GET /admin/fraude/alertas-login`
   (paginado, filtro `estado`), en el mismo `FraudeController` que
   `anillos`. Detalle, forma exacta de las columnas y pruebas en vivo en
   `endpoints-fraude.md`.

   No incluye (fuera de esta ronda): geolocalización (sigue en el punto 2,
   sin decidir) ni las señales que dependen de ella (viaje imposible,
   IP/ASN nueva); tampoco `PATCH` para marcar una alerta revisada/descartada
   (se agrega cuando el frontend tenga la pantalla de triage).
5. **(Opcional, según rúbrica) Alerting retrospectivo sobre Elasticsearch.**
   Lo que el punto 4 NO cubre: patrones que una ventana de Redis de 1-5
   minutos no ve (abuso lento repartido en horas). Worker `@Interval` que
   corra las señales retrospectivas contra `mesh_eventos_autenticacion` y
   escriba en la MISMA tabla `alerta_fraude` del punto 4 (columna `origen`
   para distinguir `redis_reactivo` de `elastic_retrospectivo` si hace
   falta), no una tabla aparte. `GET/PATCH /admin/alertas` ya tiene el `GET`
   (`alertas-login`, punto 4); falta el `PATCH` y esta segunda fuente.

### Compañero (fuera de `backend/`)

- **Migración real de `alerta_fraude`** (punto 4, ya HECHO del lado de
  `backend/`): el `.sql` de referencia, aplicado en local, está en
  `fraude-login-eventos.sql` (mismo folder) — mismo workflow de siempre
  (`solo-backend`), integrarlo en `migrations/` en el orden correcto
  (después de `015_outbox_grafo.sql`) y en `migrations/README.md`.
- **Repuntar el ETL de ClickHouse de logueos.** `etl/extraer_eventos.sql` /
  `etl/cargar_eventos.sh` leen `log_login` / `log_registro` de PostgreSQL,
  que ya no reciben filas. Hay que leer de `eventos_autenticacion` en Mongo
  (o decidir que ClickHouse deja de cubrir logins y lo hace solo
  Elasticsearch). Mientras tanto, `evento_login` / `evento_registro` de
  ClickHouse y el panel de fraude por IP están congelados.
- **Índices de `eventos_autenticacion`** (`mongo/`). Mínimo:
  `{id_usuario:1, fecha:-1}`, `{ip:1, fecha:-1}`,
  `{tipo:1, resultado:1, fecha:-1}`, `{identificador_intentado:1, fecha:-1}`,
  `{huella_cliente:1, fecha:-1}`. Y uno **parcial** para el worker:
  `{fecha:1}` con `partialFilterExpression: {pendiente_elastic: true}`, para
  que no recorra la colección entera en cada corrida (5 s) cuando crezca.
- **Índice `mesh_eventos_autenticacion` en Elasticsearch con mapping
  explícito** (hoy se auto-crea con mapping dinámico y las agregaciones
  necesitan `.keyword`): `keyword` para `ip`, `motivo`, `tipo`, `resultado`,
  `id_usuario`, `huella_cliente`, `identificador_intentado`; `date` para
  `fecha`; y más adelante `geo_point` para la geolocalización. El backend
  ya escribe ahí (`EventosAutenticacionSyncService`); crear el mapping y
  reindexar (marcar todo con `pendiente_elastic: true`).
- **Retención** de la colección (IP + User-Agent es dato personal): decidir
  una política de purga (p. ej. eventos > N meses).

---

## Descartado / fuera de alcance

- `id_sesion` para emparejar login↔logout: metería un campo nuevo en el JWT
  (`firmarToken`, `TokenUsuario`, `SesionGuard`), demasiado radio para el
  paso 1. Se puede hacer con una cookie aparte si se decide que hace falta.
- Registrar los **intentos de registro fallidos** (para detectar bots que
  martillean `POST /usuario/registro`): fácil de añadir por simetría con el
  login, pero no se pidió; hoy solo se registra el registro exitoso.
- Recomendaciones por co-ocurrencia / ML: es la otra directiva del profesor,
  no este módulo (ver memoria `estado-backend-tienda`).
