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

> **Nota (2026-09-11):** esta pregunta para el profesor sigue sin
> respuesta, pero el usuario decidió avanzar con el paso 2 de todos modos
> (cuatro rondas seguidas, 2026-09-11), sin esperarla -- el módulo entero
> quedó construido y probado en vivo mientras tanto, incluida la pieza de
> escritura (`PATCH`) y el explorador manual. Si la respuesta del profesor
> termina pidiendo repartir la señal de otra forma (por ejemplo, que
> ClickHouse se quede con todo lo de IP), esto habrá que ajustarlo después,
> no antes.

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
2. **Enriquecer con geolocalización de la IP — HECHO (2026-09-11, tercera
   ronda).** Se eligió `geoip-lite` (base offline embebida, sin llamada de
   red): validado antes contra IPs públicas reales (incluida la IP de
   prueba oficial de MaxMind, para confirmar precisión) y contra la propia
   IP del usuario. Se calcula **directo en el camino del login**
   (`geolocalizarIp()` en `helpers/contexto-peticion.ts`), no en un worker
   aparte -- es una búsqueda 100% en memoria, del orden de microsegundos,
   así que no vale la pena la complejidad de diferirlo (decisión del
   usuario, 2026-09-11: "un par de ms más en el login no es tan malo"). Se
   guarda en `eventos_autenticacion` de Mongo y se replica a Elasticsearch
   como `geo_punto`/`geo_pais`/`geo_ciudad` (ver el punto 3, "Viaje
   imposible", para el porque de los tres campos sueltos en vez de un
   objeto). `null` en tres casos: sin IP, IP privada/local, o una IP
   anycast/CDN que `geoip-lite` no resuelve.
3. **Endpoints de consulta contra `mesh_eventos_autenticacion` — tres de
   cuatro HECHOS (2026-09-11, dos rondas), toma de cuenta, patrones
   lentos/repartidos y viaje imposible.** Cubren justo lo que el punto 4
   (Redis) **no puede ver**: historial completo de una cuenta, o patrones
   repartidos en horas.

   - **Toma de cuenta — HECHO (2026-09-11).** IP nueva para la cuenta,
     comparada contra todo su historial de logins exitosos (mínimo 3
     previos para evaluar algo). `TomaCuentaService`, dispara en cada login
     **exitoso** (fire-and-forget, en `UsuarioController.iniciarSesion`,
     no un worker separado). Detalle, pruebas en vivo y el resto de esta
     entrada en `endpoints/endpoints-fraude.md` y el `cambio_propuestas` de
     esta ronda.
   - **Patrones lentos o repartidos — HECHO (2026-09-11).** Tres señales:
     fuerza bruta contra una cuenta repartida en 24h (Redis solo ve 60s),
     multi-cuenta desde una IP repartida en 24h (Redis solo ve 300s), e IP
     rotando contra una misma cuenta repartida en 24h.
     `FraudeLoginRetrospectivoService`, worker `@Interval` cada 15 min,
     agregaciones `terms`+`min_doc_count` y `terms`+`cardinality`+
     `bucket_selector` — Elasticsearch entrega ya filtrada la lista de
     sospechosos, el worker no decide a quién mirar. Estas tres señales
     llevan el sufijo `_lenta` en el catálogo (`fuerza_bruta_cuenta_lenta`,
     `multi_cuenta_ip_lenta`, `ip_rotacion_cuenta_lenta`) porque la
     rotación de IP **sí** terminó teniendo una versión corta en Redis
     también (ver el punto 4, segunda ronda, más abajo) — al principio
     "IP rotando" no tenía par corto y no llevaba sufijo; se renombró para
     no romper el patrón.
   - **Viaje imposible — HECHO (2026-09-11, tercera ronda).** No es
     `geo_distance` contra una "ubicación habitual" agregada: compara el
     login actual contra el login exitoso **inmediatamente anterior** de
     la misma cuenta (el que Elasticsearch devuelve ordenando por `fecha`
     desc, con `geo_punto` presente), calcula la distancia (haversine) y
     la velocidad implícita, y marca si supera 800 km/h.
     `ViajeImposibleService`, dispara en cada login **exitoso**
     (fire-and-forget, igual que `TomaCuentaService`, no el worker de 15
     min -- es una comparación puntual entre dos eventos, no una
     agregación sobre una ventana). Limitación conocida y **aceptada, no
     un bug**: un usuario con VPN da un falso positivo legítimo -- decidido
     así porque además es la única forma práctica de demostrar el patrón
     en la demo sin depender de gente real en países distintos.
   - **Disparo inmediato por login — HECHO (2026-09-15).** Además del
     worker de 15 min (que sigue de respaldo, sin cambios), las tres
     señales `_lenta` ahora también se evalúan justo después de cada
     login, acotadas a la cuenta y/o la IP de ESE intento (no las 24h de
     todas las cuentas). `UsuarioController` encadena, sin `await`:
     `EventosAutenticacionSyncService.sincronizarAhora()` (indexa YA ese
     evento en Elasticsearch, con `refresh: 'wait_for'` para que sea
     buscable de inmediato) y, al terminar,
     `FraudeLoginRetrospectivoService.evaluarInmediato()` (las mismas tres
     consultas de arriba, pero filtradas a un solo identificador/IP en vez
     de una agregación `terms` sobre todas). Mismo `id_tipo_alerta_fraude`
     y misma hora truncada que el worker de 15 min: si ambos coinciden en
     la misma hora, se juntan en una sola fila (`ON CONFLICT` de
     `registrarAlertaFraude`) en vez de duplicar. Pedido por el profesor,
     con la comparación explícita a como ya funcionan los contadores de
     Redis (punto 4). Detalle y pruebas en
     `cambio_propuestas/2026-09-15_1130-fraude-login-disparo-inmediato.md`,
     incluido un bug real de concurrencia encontrado y corregido en la
     misma ronda.
   - **Panel de exploración manual — HECHO (2026-09-11, cuarta ronda).**
     `GET /admin/fraude/eventos-login`: logs crudos de
     `mesh_eventos_autenticacion` (Elasticsearch, no Mongo), paginados, con
     filtros exactos por tipo, resultado, motivo, cuenta, IP, huella de
     cliente, país y rango de fechas. Controller/servicio nuevos
     (`AdminFraudeLoginController` / `FraudeLoginExploracionService`), no
     tocan `FraudeController`/`FraudeLoginService`. Detalle y pruebas en
     `endpoints/endpoints-fraude.md` y el `cambio_propuestas` de esta ronda.
     "Qué otras cuentas comparten este dispositivo" (buscar por
     `huella_cliente`) queda cubierto por el mismo filtro; no se construyó
     ninguna vista agregada aparte (por cuenta, por dispositivo) — este
     endpoint es solo el listado crudo filtrado.
4. **Contadores en Redis en el camino del login — HECHO (2026-09-10),
   CONFIRMADO como pieza válida (2026-09-10, noche).**

   Este punto llegó a decir, por un tiempo, que estaba mal y pendiente de
   revertir: la frase original ("el profesor insiste en que... se resuelve
   con Redis") nunca se verificó, y el usuario aclaró que nunca fue parte
   de lo hablado con el profesor (ver memoria
   `verificar-planes-contra-conversaciones-reales` para el detalle completo
   de esa confusión). **Esa parte de la historia sigue siendo cierta y no
   se borra** — pero, ya aclarado el malentendido, el usuario revisó la
   idea por sus propios méritos (no porque el profesor la haya pedido) y la
   confirmó: son contadores menores, le parece bien tenerlos.

   **Entonces, la arquitectura que queda, decidida:** Redis (este punto) y
   Elasticsearch (punto 3) son capas **complementarias**, no una sustituye
   a la otra — Redis para lo inmediato (en 1-5 minutos), Elasticsearch para
   lo que necesita historial completo o ventanas largas. Solo alerta, nunca
   frena el login (decisión explícita del usuario). Detalle técnico
   completo en `cambio_propuestas/2026-09-10_2216-deteccion-fraude-login-redis.md`
   y `endpoints/endpoints-fraude.md`.

   **Segunda ronda (2026-09-11): `ip_rotacion_cuenta` también en Redis.**
   Tras cerrar la ronda de Elasticsearch, se notó que tres de las cuatro
   señales retrospectivas tenían espejo corto en Redis y una no
   (`ip_rotacion_cuenta_lenta`, la única sin par). Se agregó el espejo
   corto que faltaba: mismo mecanismo que `multi_cuenta_ip` (`SADD` +
   `EXPIRE ... NX` + `SCARD`) con los roles invertidos — agrupa por
   identificador y cuenta IPs distintas, en vez de agrupar por IP y contar
   identificadores distintos. 300s / 4 IPs distintas, mismos números que
   `multi_cuenta_ip` (no hay razón técnica para que cambien). El catálogo
   `tipo_alerta_fraude` quedó en **8 filas** (antes 7): el tipo original
   `ip_rotacion_cuenta` se renombró a `ip_rotacion_cuenta_lenta` para que
   el nombre sin sufijo quedara libre para la versión Redis, igual que los
   otros dos pares. Ahora **fuerza_bruta_ip es la única señal sin espejo
   lento** (no se pidió). Detalle y pruebas en vivo en el `cambio_propuestas`
   de esta segunda ronda.
5. **Alerting persistente para las señales del punto 3 — RESUELTO (2026-09-11)
   para toma de cuenta y patrones lentos: SÍ le alcanzó con agregar tipos
   nuevos al catálogo, no hizo falta tabla aparte.** `alerta_fraude` (la
   misma del punto 4) ya tenía estructura genérica (`tipo`, `clave`,
   `detalle` jsonb, `estado`) — las cuatro señales retrospectivas solo
   agregaron 4 filas a `tipo_alerta_fraude`, sin columnas ni tablas nuevas.
   **El `PATCH` para marcar revisada/descartada — HECHO (2026-09-11, cuarta
   ronda).** `PATCH /admin/fraude/alertas-login/:id`, body `{estado:
   "revisada"|"descartada"}`, solo admite el destino viniendo de
   `pendiente` (409 si ya se movió, 404 si no existe). Aplica a las 9
   señales por igual, sin distinguir Redis/Elasticsearch — todas viven en
   la misma tabla. Mismo controller/servicio que el explorador de logs de
   arriba.

### Compañero (fuera de `backend/`)

- **Migración real de `alerta_fraude`** (punto 4, confirmado y HECHO del
  lado de `backend/`): el `.sql` de referencia, aplicado en local, está en
  `fraude-login-eventos.sql` (mismo folder) — mismo workflow de siempre
  (`solo-backend`), integrarlo en `migrations/` en el orden correcto
  (después de `015_outbox_grafo.sql`) y en `migrations/README.md`. **El
  `.sql` de referencia ya incluye las 9 filas del catálogo** en el orden
  final: `fuerza_bruta_ip`, `fuerza_bruta_cuenta`, `multi_cuenta_ip`,
  `toma_cuenta`, `fuerza_bruta_cuenta_lenta`, `multi_cuenta_ip_lenta`,
  `ip_rotacion_cuenta_lenta`, `ip_rotacion_cuenta`, `viaje_imposible` — con
  el `INSERT` de las 9 corriendo sobre una tabla recién creada,
  `tipo_alerta_fraude` queda con los ids 1-9 exactos que ya usa el backend
  (`models/alerta-fraude.ts`, fijos como constantes). **La migración real NO
  necesita el `UPDATE` de
  renombre** que trae el `.sql` de referencia (el que cambia
  `ip_rotacion_cuenta` por `ip_rotacion_cuenta_lenta`) — ese `UPDATE`
  existe solo para corregir la base LOCAL de desarrollo, que en algún
  momento tuvo la fila vieja con el nombre sin sufijo (de la primera ronda,
  antes de que existiera la versión Redis); sobre una tabla vacía el
  `UPDATE` simplemente no encuentra nada que renombrar y el `INSERT` ya
  inserta los 8 nombres correctos desde el principio. **Ojo, aparte:** en
  la base LOCAL varias de estas filas tuvieron que realinearse a mano más
  de una vez porque pruebas anteriores dejaron huecos en el `smallserial`
  (ids saltados, de inserciones revertidas) — no es un problema de la
  migración real, que arranca de una tabla vacía y no tiene esos huecos,
  pero si algo no cuadra al aplicar esto en otro entorno, revisar primero
  si el catálogo local tiene huecos parecidos.
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
  explícito, del lado oficial (carpeta `elastic/`, fuera de `backend/`)**
  (hoy se auto-crea con mapping dinámico y las agregaciones necesitan
  `.keyword`): `keyword` para `ip`, `motivo`, `tipo`, `resultado`,
  `id_usuario`, `huella_cliente`, `identificador_intentado`; `date` para
  `fecha`; **`geo_point` para `geo_punto`** (agregado 2026-09-11, ya
  aplicado a mano en el índice LOCAL con `PUT _mapping` para poder
  desarrollar y probar — falta integrarlo del lado oficial). **Ojo con la
  forma exacta:** `geo_punto` tiene que ser un campo con SOLO `lat`/`lon`
  adentro (`geo_pais`/`geo_ciudad` van SUELTOS, aparte, NO anidados dentro
  de `geo_punto`) — un intento con los tres campos juntos dentro de un
  mismo objeto `geo` falló en vivo con
  `document_parsing_exception: field [pais] not supported`, porque un
  campo `geo_point` de Elasticsearch solo acepta coordenadas, nada más. El
  backend ya escribe ahí (`EventosAutenticacionSyncService`); crear el
  mapping completo y reindexar (marcar todo con `pendiente_elastic: true`).
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
