# Endpoints del panel de fraude

> **Cambio del refactor de fraude (2026-09-30, etapa 7, parte 2 --
> `plan pendiente/refactor-fraude-senales.md`).** Las tres rutas de admin por
> fuente (`alertas-resenas`, `alertas-eventos` y `alertas-login`) y el
> agrupador de casos ya **no leen las tablas viejas** (`anillo_fraude`,
> `hallazgo_evento_fraude`, `alerta_fraude`) sino `senal_fraude`, una sola
> tabla de señales. Las URL, los filtros, los códigos de error y la forma de
> las respuestas **no cambian**, pero cambia lo que significan algunos campos:
>
> - **El id es el de la señal.** `id_anillo_fraude`, `id_hallazgo_evento_fraude`
>   e `id_alerta_fraude` son ahora `senal_fraude.id_senal_fraude`. Un id de
>   una familia pedido por la ruta de otra da `404` (por ejemplo, el id de una
>   alerta de login en `PATCH /alertas-resenas/:id`).
> - **Una señal junta todas sus ventanas.** Ya no hay una fila por minuto, por
>   hora o por día: `contador` es `total_detecciones` (cuántas veces la vio un
>   detector) y `ventana_inicio` es la última vez que se detectó. En los
>   anillos, `ultima_vez_confirmado_activo` es esa misma última detección.
> - **Se revisa la señal entera.** `PATCH` marca revisada o descartada la
>   señal; si después llega evidencia nueva (una cuenta, una IP, un producto o
>   un pedido que no tenía, o una métrica mayor), el detector la vuelve a
>   `pendiente` sola.
> - **`cuentas_afectadas` (login):** `fecha_lectura` es la de la notificación
>   de esa cuenta para esa señal (`null` si no la ha leído).
> - **Las rutas del usuario también cambian (parte 3):** `GET` y
>   `PATCH /perfil/alertas-fraude` leen la notificación de la señal
>   (`notificacion_fraude.id_senal_fraude`). Mismas URL y misma forma de
>   respuesta, pero `id_alerta_fraude` es el id de la **señal**, `contador` son
>   sus detecciones y `fecha_creacion` es la última vez que se le avisó a esa
>   cuenta. Se avisa **una vez por señal y cuenta** (ya no en cada ventana de
>   un minuto u hora): la notificación nace la primera vez que la cuenta
>   aparece en la señal, y si la señal se reabre por evidencia nueva vuelve a
>   quedar **sin leer** y sube en la lista. Marcar una alerta de otra cuenta
>   sigue dando `404`.
>
> Los ejemplos de respuesta de abajo son de antes del cambio: los ids y los
> contadores de esas muestras son de las tablas viejas.

Once rutas de admin, más dos rutas de usuario (agregadas 2026-09-15, ver
más abajo). El panel de fraude en reseñas y la conciliación tocan el grafo
de **Neo4j**; el de fraude de login es **solo Elasticsearch + Redis**, sin
tocar el grafo; el de hallazgos de eventos es **solo ClickHouse + Postgres**,
sin tocar Neo4j ni Elasticsearch; el agrupador de casos es **solo
PostgreSQL**, sobre lo que las demás rutas ya detectaron y persistieron:

- **`GET`/`PATCH /admin/fraude/casos` y `GET .../casos/:id`** — el
  **agrupador de casos de fraude**: junta en un solo caso, con puntaje y
  nivel combinados, los hallazgos de las tres fuentes de abajo (más una
  cuarta desde 2026-10-02, `elastic`: el texto de las reseñas) cuando
  comparten cuentas. No reemplaza los tres paneles individuales, los
  junta. Ver la sección "El agrupador de casos de fraude", al final.
- **`GET`/`PATCH /admin/fraude/alertas-resenas` y
  `GET /admin/fraude/alertas-resenas/:id/detalle-grafo`** — el **panel de
  manipulación de reseñas** de la Entrega 2 (Bloque 4 de
  `BACKEND-PENDIENTE.md`): los anillos de cuentas cuyo patrón de
  calificaciones no se explica por el uso normal de la tienda, detectados
  por un worker y persistidos en PostgreSQL. Nombrado en paralelo con
  `alertas-login`. Ver la sección "Anillos de fraude en reseñas", al final.
- **`GET`/`PATCH /admin/fraude/alertas-eventos`** — el **panel de F1-F6**:
  hallazgos de fraude sobre eventos de ClickHouse (vistas infladas, compras
  en ráfaga, IP con varias cuentas, carrito acaparador, devoluciones
  seriales, granja de registros), detectados por un worker diario y
  persistidos en PostgreSQL. Nombrado en el mismo patrón que
  `alertas-login`/`alertas-resenas`. Ver la sección "Hallazgos de fraude
  sobre eventos", al final.
- **`GET /admin/grafo/conciliacion`** — la **red de seguridad** de la
  sincronización del grafo: compara los conteos de PostgreSQL (la verdad)
  contra Neo4j (la proyección) y avisa de la deriva. Ver la sección
  dedicada.
- **`GET /admin/fraude/alertas-login`** — las **alertas de fraude de
  login**: nueve señales, guardadas todas en PostgreSQL — cuatro inmediatas
  con contadores de Redis en el camino del login (fuerza bruta, multi-cuenta,
  rotación de IP) y cinco consultadas contra Elasticsearch (toma de cuenta,
  viaje imposible, y tres patrones lentos/repartidos que una ventana de
  Redis de minutos no puede ver). Ver la sección dedicada.
- **`GET /admin/fraude/eventos-login`** — el **explorador manual** de los
  logs crudos de autenticación, contra Elasticsearch directamente (no
  contra Mongo, que es el origen pero no el que se consulta). Filtros
  exactos por tipo, resultado, motivo, cuenta, IP, huella de cliente, país y
  rango de fechas.
- **`PATCH /admin/fraude/alertas-login/:id`** — marcar una alerta (de
  cualquiera de las 9 señales) como `revisada` o `descartada`. Solo desde
  `pendiente`.
- **`GET /perfil/alertas-fraude` y `PATCH /perfil/alertas-fraude/:id`** —
  las dos únicas rutas de este archivo que NO son de admin: el usuario
  afectado ve y marca como leídas las alertas sobre su propia cuenta. Ver
  la sección dedicada, después de "alertas-login".

> **2026-09-18: se eliminó el panel EN VIVO `GET /admin/fraude/anillos`**
> (`FraudeController.anillos()`, `FraudeService`, `models/fraude.ts`) —
> era la prueba de concepto de la Entrega 2, sin persistencia. Con los
> anillos ya detectados por worker y persistidos (sección "Anillos de
> fraude en reseñas"), ese código quedó sin uso y se borró junto con
> `GrafoSyncService.estadoSincronizacion()` (el dato auxiliar de
> sincronización que solo consumía esa ruta). La documentación de esa
> ruta vieja, incluidas sus pruebas del 2026-08-30/09-04, queda solo en
> `cambio_propuestas/` como registro histórico.

Cliente Neo4j: `src/database/neo4j.ts` (helpers `consultarGrafo` en modo
**READ**, y `ejecutarGrafo` en modo **WRITE** para el worker del outbox —
ver abajo).

---

## De dónde salen los datos

El grafo **no es una fuente de verdad**: es una **proyección** de la tabla
`resena` de PostgreSQL. La carga inicial la hace el ETL
`etl/cargar_grafo.sh` (lo lleva el compañero, fuera de `backend/`), y a
partir de ahí el **worker del outbox** (`GrafoSyncService`, un `@Interval`
cada 10 s) lo mantiene al día: cada reseña que se crea, edita o borra deja
un evento en la cola `evento_grafo` y el worker lo proyecta a Neo4j segundos
después. Ver `cambio_propuestas/2026-09-04_0030-worker-outbox-grafo.md` y
`plan pendiente/outbox-grafo.md`. La **conciliación**
(`GET /admin/grafo/conciliacion`, abajo) es la red de seguridad que
comprueba que el worker no dejó nada atrás. Modelo:

```
(:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
                        (:Resena)-[:SOBRE]->(:Producto)
(:Usuario)-[:VIVE_EN]->(:Direccion)
```

- No hay nodo `:Vendedor`: quien califica y quien es calificado son el mismo
  `:Usuario` (en Mesh un vendedor también compra).
- La reseña es un **nodo**, no una relación: conecta tres cosas (autor,
  vendedor, producto).
- El nodo `:Direccion` se identifica por su **texto normalizado** y lleva
  `tiene_calle` (una dirección sin calle no identifica una casa, solo una
  ciudad).

Si el grafo está vacío (`GET /grafo` devuelve `nodos: 0`), las consultas de
detección y de conciliación responden igual sin fallar, simplemente no
encuentran nada — no sirve de nada hasta que se corra el ETL.

---

> El panel EN VIVO que corría cuatro consultas Cypher (A.1/A.2/A.4 +
> conteo) contra Neo4j en cada request (`GET /admin/fraude/anillos`, sin
> persistir nada) se eliminó el 2026-09-18 — ver la nota al inicio de este
> archivo. Las consultas A.1/A.2, con ventana de tiempo agregada, siguen
> vivas en `AnillosDetectorService` (el worker que llena la tabla
> `anillo_fraude`); A.4 (misma dirección) quedó sin implementar en ningún
> lado tras el borrado (ver "Lo que le toca al compañero" al final de la
> sección "Anillos de fraude en reseñas"). Payload y pruebas históricas de
> aquel panel (2026-09-04) en
> `cambio_propuestas/2026-09-04_0745-sincronizacion-panel-fraude.md`.

---

# GET /admin/fraude/alertas-login

Las alertas de fraude de **login**. Nueve señales, tres mecanismos:

- **Cuatro inmediatas** (`fuerza_bruta_ip`, `fuerza_bruta_cuenta`,
  `multi_cuenta_ip`, `ip_rotacion_cuenta`) — `FraudeLoginService`,
  **contadores de Redis en el propio camino del login**. Punto 4 del plan.
- **Dos comparadas contra el historial, en login exitoso** (`toma_cuenta`,
  `viaje_imposible`) — `TomaCuentaService` / `ViajeImposibleService`, no
  son ventanas de tiempo: comparan el login actual contra el historial (o
  el login anterior) de la misma cuenta, consultando Elasticsearch.
- **Tres retrospectivas, worker cada 15 min** (`fuerza_bruta_cuenta_lenta`,
  `multi_cuenta_ip_lenta`, `ip_rotacion_cuenta_lenta`) — contra el índice
  de Elasticsearch `mesh_eventos_autenticacion` (el mismo que alimenta
  `EventosAutenticacionSyncService`), lo que una ventana de Redis de 1-5
  min no puede ver: patrones repartidos en horas. Punto 3 del plan.

**Tres de las cuatro señales de Redis tienen su espejo `_lenta` en
Elasticsearch** (misma pregunta, ventana distinta): `fuerza_bruta_cuenta` ↔
`fuerza_bruta_cuenta_lenta`, `multi_cuenta_ip` ↔ `multi_cuenta_ip_lenta`,
`ip_rotacion_cuenta` ↔ `ip_rotacion_cuenta_lenta`. **`fuerza_bruta_ip` es la
única sin espejo lento** (no se pidió). `toma_cuenta` y `viaje_imposible`
no tienen par: no son ventanas de tiempo, comparan contra el historial.

**Nota de nombres:** `ip_rotacion_cuenta` nació primero del lado lento
(2026-09-11, primera ronda) y en ese momento no llevaba sufijo. Al
agregarle la versión Redis (2026-09-11, segunda ronda) se **renombró** el
tipo original a `ip_rotacion_cuenta_lenta` para no romper el patrón — si
algo en documentación vieja o en datos de esa primera ronda dice
`ip_rotacion_cuenta` refiriéndose a Elasticsearch, es ese renombre.

Todas caen en la **misma tabla** `alerta_fraude` — solo cambia el catálogo
`tipo_alerta_fraude` (9 filas) y quién la escribe. Plan:
`plan pendiente/fraude-login-eventos.md`; esquema de referencia:
`plan pendiente/fraude-login-eventos.sql`.

> **Estado (2026-09-10, ampliado 2026-09-11 en tres rondas): implementada y
> PROBADA en vivo.** Ver "Pruebas" al final de esta sección.

Código: `src/controllers/fraude/fraude.controller.ts` (mismo controlador
que `anillos`, ruta hermana) + `src/services/fraude-login/fraude-login.service.ts`
(las cuatro de Redis y el listado) + `src/services/fraude-login/toma-cuenta.service.ts`
(`toma_cuenta`) + `src/services/fraude-login/viaje-imposible.service.ts`
(`viaje_imposible`) + `src/services/fraude-login/fraude-login-retrospectivo.service.ts`
(las tres del worker). **Solo admin** (`SesionGuard` +
`@Roles(ID_ROL_ADMIN)`, en la clase) — no la tienda, mismo criterio que el
resto del panel.

## De dónde salen las alertas

**Esto NO es un log de cada intento** — eso ya vive en la colección
`eventos_autenticacion` de MongoDB (ver
`cambio_propuestas/2026-09-10_0906-eventos-autenticacion-mongo.md`). Una
fila de `alerta_fraude` es "esto merece que un admin lo mire".

**Por decisión explícita del usuario (2026-09-10): el sistema SOLO
alerta, nunca frena el login.** Ningún umbral bloquea ni retrasa una
cuenta o una IP — cruzarlo únicamente deja la fila para revisión humana.
Esto aplica igual a las cinco señales que consultan Elasticsearch.

| `tipo_alerta` | Mecanismo | Qué mide | Ventana | Umbral |
|---|---|---|---|---|
| `fuerza_bruta_ip` | Redis, en el login | Fallos de login desde una misma IP | 60 s | 8 |
| `fuerza_bruta_cuenta` | Redis, en el login | Fallos de login contra un mismo identificador | 60 s | 5 |
| `multi_cuenta_ip` | Redis, en el login | Identificadores **distintos** probados desde una misma IP (credential stuffing) | 300 s | 4 |
| `ip_rotacion_cuenta` | Redis, en el login | IPs **distintas** probando un mismo identificador (evade bloqueo por IP) — el espejo invertido de `multi_cuenta_ip` | 300 s | 4 |
| `toma_cuenta` | Elasticsearch, en login **exitoso** | IP nueva para la cuenta, comparada contra **todo su historial** | histórico | — (ver abajo) |
| `viaje_imposible` | Elasticsearch, en login **exitoso** | Velocidad implícita entre el login actual y el anterior de la cuenta | histórico (el login anterior) | 800 km/h |
| `fuerza_bruta_cuenta_lenta` | Elasticsearch, worker cada 15 min | Fallos contra una cuenta, repartidos | 24 h | 15 |
| `multi_cuenta_ip_lenta` | Elasticsearch, worker cada 15 min | Cuentas distintas probadas desde una misma IP, repartidas | 24 h | 8 |
| `ip_rotacion_cuenta_lenta` | Elasticsearch, worker cada 15 min | IPs distintas contra una misma cuenta, repartidas | 24 h | 5 |

`viaje_imposible` requiere geolocalizar la IP: se calcula con `geoip-lite`
(base offline embebida, sin llamada de red) directo en el camino del login
— ver `helpers/contexto-peticion.ts` (`geolocalizarIp`). Compara el login
actual contra el login exitoso **inmediatamente anterior** de la misma
cuenta que tenga geolocalización conocida (haversine + velocidad
implícita, 800 km/h ≈ más rápido que un vuelo comercial, con margen). Sin
geolocalización en cualquiera de los dos (IP privada/local, o una IP
anycast/CDN que `geoip-lite` no resuelve) no se evalúa nada — no es un
error, simplemente no hay con qué comparar. **Limitación conocida y
ACEPTADA, no un bug:** un usuario con VPN da un falso positivo legítimo
("viaja imposible" sin haberse movido) — es además la única forma práctica
de demostrar este patrón en una demo sin depender de gente real en países
distintos (decisión del usuario, 2026-09-11).

Los umbrales de 24h (15/8/5) y el de `ip_rotacion_cuenta` en Redis (4,
igual que `multi_cuenta_ip` — no hay razón técnica para que cambie según
qué lado se agrupa) son una **propuesta razonable, no datos medidos**
contra tráfico real — son constantes fáciles de ajustar
(`FraudeLoginService`/`FraudeLoginRetrospectivoService`).

`ip_rotacion_cuenta` (Redis) usa el mismo mecanismo que `multi_cuenta_ip`
con los roles invertidos: en vez de `SADD` de identificadores en una clave
por IP, es `SADD` de IPs en una clave por identificador
(`mesh:fraude:ips_cuenta:<identificador>`). Corre en **cada** intento
(éxito o fallo), igual que `multi_cuenta_ip` — un acierto en medio de la
rotación cuenta igual.

Cada contador de Redis es de **ventana fija**: `INCR`/`SADD` y después
`EXPIRE ... NX` — el TTL se pone una sola vez, al crear la clave (Redis 7+,
ya en `redis:8-alpine` del compose). Las agregaciones de Elasticsearch
(`terms` + `min_doc_count`, y `terms` + `cardinality` + `bucket_selector`
para las que cuentan valores distintos) le entregan al worker la lista de
sospechosos **ya filtrada** — el worker no decide a quién mirar, solo
convierte cada bucket que la query devuelve en una fila de `alerta_fraude`.

**`toma_cuenta` no evalúa nada si la cuenta tiene menos de 3 logins
exitosos previos** — si no, el primerísimo login de una cuenta nueva
siempre tendría "IP nueva" (nunca tuvo ninguna) y se marcaría sin serlo.
**Limitación conocida, no resuelta:** una IP dinámica de ISP cambia sin que
el usuario se haya movido — puede generar falsos positivos ocasionales; no
se ajustó el umbral sin datos reales de cuántos genera.

**Deduplicación:** la llave de conflicto de `alerta_fraude` es
`(tipo, clave, ventana_inicio)`. Para las cuatro de Redis, `toma_cuenta` y
`viaje_imposible`, `ventana_inicio` se trunca **al minuto** — varios cruces
del umbral en el mismo minuto **suman `contador`** en vez de duplicar. Para
las tres del worker (cada 15 min, ventana de 24h) se trunca **a la hora**:
truncar al minuto crearía una fila nueva casi en cada corrida mientras el
patrón siga activo; a la hora da una alerta persistente por hora sin
perder la reaparición si el ataque sigue horas después. Si el ataque sigue
en la ventana siguiente (el minuto u hora que sea), nace una fila nueva a
propósito — una alerta ya revisada no se reabre sola. El UPSERT vive en
`helpers/registrar-alerta-fraude.ts`, compartido por los cuatro servicios
que escriben alertas.

## Qué llena cada columna

- **`clave`** — el origen de la señal: la IP (`fuerza_bruta_ip`,
  `multi_cuenta_ip`, `multi_cuenta_ip_lenta`) o el identificador intentado
  (`fuerza_bruta_cuenta`, `toma_cuenta`, `viaje_imposible`,
  `fuerza_bruta_cuenta_lenta`, `ip_rotacion_cuenta`,
  `ip_rotacion_cuenta_lenta` — las dos de rotación agrupan por CUENTA, no
  por IP, aunque lo que cuentan sean IPs distintas).
- **`cuentas_afectadas`** — **cambió de forma el 2026-09-15** (segunda
  ronda): antes era `cuenta_involucrada`, un objeto o `null` (una sola
  cuenta). Ahora es un ARRAY — cada cuenta a la que le corresponde ver la
  alerta, con su propio `fecha_lectura` (viene de la tabla
  `notificacion_fraude`, ver `endpoints.md` para el lado de usuario). Un
  elemento en `toma_cuenta`/`viaje_imposible`/`fuerza_bruta_cuenta`/
  `ip_rotacion_cuenta` y sus `_lenta` (cuando el identificador corresponde
  a una cuenta real); **varios** elementos en `multi_cuenta_ip`/
  `multi_cuenta_ip_lenta` (una por cada cuenta real que esa IP probó, no
  solo la primera); array vacío en `fuerza_bruta_ip` (no tiene lista de
  cuentas objetivo). Detalle de por qué en
  `plan pendiente/notificacion-fraude-usuario.md`.
- **`detalle`** — evidencia por tipo: conteos, la ventana, y una muestra
  (hasta 20) de identificadores o IPs vistos en `multi_cuenta_ip`,
  `multi_cuenta_ip_lenta`, `ip_rotacion_cuenta` e `ip_rotacion_cuenta_lenta`.
  `toma_cuenta` trae `ip_nueva`, `ips_conocidas` (cuántas tenía antes),
  `huella_nueva` (booleano, señal corroborante — no dispara ella sola, ver
  la limitación de arriba) y `logins_exitosos_previos`. `viaje_imposible`
  trae `distancia_km`, `horas_transcurridas`, `velocidad_kmh`, y las dos
  ubicaciones (`ubicacion_anterior`/`ubicacion_actual`, cada una con
  `lat`/`lon`/`pais`/`ciudad`).
- **`estado`** — `pendiente` al nacer. El admin la marca `revisada` o
  `descartada` con `PATCH /admin/fraude/alertas-login/:id` (ver la sección
  dedicada, después de las pruebas de esta ruta).

## GET /admin/fraude/alertas-login

```
GET /admin/fraude/alertas-login?pagina=1&limite=20&estado=pendiente&tipo=toma_cuenta
```

Paginación por número de página (`validarLimite`/`validarPagina` de
`helpers/validaciones-productos.ts`, mismas reglas y mensajes que el resto
del proyecto). Dos filtros opcionales e independientes:

- `estado=pendiente|revisada|descartada` → solo esas.
- `tipo=fuerza_bruta_ip|fuerza_bruta_cuenta|multi_cuenta_ip|ip_rotacion_cuenta|toma_cuenta|viaje_imposible|fuerza_bruta_cuenta_lenta|multi_cuenta_ip_lenta|ip_rotacion_cuenta_lenta`
  → solo esa señal. Necesario desde que hay nueve tipos mezclados en el
  mismo listado.
- sin alguno de los dos → no se filtra por ese campo; sin ninguno, todas,
  más recientes primero (`fecha_actualizacion DESC`).

### 200

```json
{
  "ok": true,
  "mensaje": "Alertas de login obtenidas",
  "payload": {
    "alertas": [
      {
        "id_alerta_fraude": "16",
        "tipo_alerta": "fuerza_bruta_cuenta",
        "clave": "admin_mesh",
        "cuentas_afectadas": [
          { "id_usuario": "5", "usuario": "admin_mesh", "fecha_lectura": null }
        ],
        "detalle": { "fallos": 5, "ventana_segundos": 60 },
        "contador": 1,
        "ventana_inicio": "2026-09-11T04:18:00.000Z",
        "estado": "pendiente",
        "fecha_creacion": "2026-09-11T04:18:45.656Z",
        "fecha_actualizacion": "2026-09-11T04:18:45.656Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_alertas": 4,
    "total_paginas": 1
  }
}
```

Ejemplo con VARIOS afectados (`multi_cuenta_ip`, la IP probó 3 cuentas
reales de las 4 que intentó):

```json
{
  "id_alerta_fraude": "20",
  "tipo_alerta": "multi_cuenta_ip",
  "clave": "198.51.100.9",
  "cuentas_afectadas": [
    { "id_usuario": "3", "usuario": "comprador_sur", "fecha_lectura": null },
    { "id_usuario": "5", "usuario": "admin_mesh", "fecha_lectura": "2026-09-15T19:41:02.000Z" },
    { "id_usuario": "9", "usuario": "anillo_dos", "fecha_lectura": null }
  ],
  "detalle": {
    "cuentas_distintas": 4,
    "ventana_segundos": 300,
    "identificadores": ["comprador_sur", "admin_mesh", "anillo_dos", "no.existe@mesh.test"]
  },
  "estado": "pendiente"
}
```

(`no.existe@mesh.test` no resolvió a ninguna cuenta real, así que no
aparece en `cuentas_afectadas` aunque sí en `detalle.identificadores` —
son cosas distintas: `detalle` es evidencia cruda, `cuentas_afectadas` son
las cuentas reales a las que se les notificó.)

### 400

```json
{ "ok": false, "mensaje": "El estado debe ser uno de: pendiente, revisada, descartada", "payload": null }
{ "ok": false, "mensaje": "El tipo debe ser uno de: fuerza_bruta_ip, fuerza_bruta_cuenta, multi_cuenta_ip, ip_rotacion_cuenta, toma_cuenta, viaje_imposible, fuerza_bruta_cuenta_lenta, multi_cuenta_ip_lenta, ip_rotacion_cuenta_lenta", "payload": null }
```

### 401 / 403

Mismo comportamiento que `anillos`: sin sesión → `401`; sesión válida pero
no admin (comprador, vendedor, o la tienda) → `403`.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

## Pruebas — hechas el 2026-09-10 (Redis) y el 2026-09-11 (Elasticsearch)

Contra el servidor y las bases reales (`mesh-postgres`, `mesh-redis`,
`mesh-mongo`, `mesh-elastic`), `npm run start:dev`. Scripts en el
scratchpad, no en el repo.

### Redis (2026-09-10)

| Caso | Resultado |
|---|---|
| 6 fallos en 60 s contra un mismo identificador inexistente | `mesh:fraude:fallos_cuenta:<id>` llega a 6; alerta `fuerza_bruta_cuenta` nace en el fallo 5, `contador: 2` tras el 6º (mismo minuto) |
| 3 fallos más, con 3 identificadores distintos, misma IP | `fallos_ip` llega a 9 (≥8) → alerta `fuerza_bruta_ip`; `cuentas_ip` llega a 4 distintos (≥4) → alerta `multi_cuenta_ip` con los 4 identificadores en `detalle` |
| Login **exitoso** después, misma IP | no rompe nada; el identificador exitoso también entra al set de `multi_cuenta_ip` (a propósito: credential stuffing puede acertar una), la alerta existente sube de `contador` |
| 5 fallos de contraseña contra una cuenta **real** (`admin_mesh`) | la alerta trae `cuenta_involucrada: { id_usuario: "5", usuario: "admin_mesh" }` |
| `GET /admin/fraude/alertas-login` sin filtro | `200`, 4 alertas, `total_paginas` correcto |
| `...?estado=pendiente&limite=2` | `200`, 2 alertas, `total_paginas: 2` |
| `...?estado=basura` | `400` "El estado debe ser uno de: ..." |
| Sin cookie | `401` |
| `TTL` de `mesh:fraude:fallos_cuenta:admin_mesh` tras 5 intentos rápidos | 54 s (no se reinició a 60 en cada intento — confirma `EXPIRE ... NX`) |

Limpieza: `DELETE FROM alerta_fraude` (4 filas) + `redis-cli --scan --pattern
"mesh:fraude:*" | xargs DEL` (5 claves).

### `toma_cuenta` (2026-09-11)

Contra `comprador_sur` (id 3, con historial real de logins previos desde
`172.22.192.1`). Se sembraron 3 logins exitosos sintéticos más desde
`203.0.113.5` (vía Mongo, `pendiente_elastic: true`, para pasar por el
`EventosAutenticacionSyncService` real, no un atajo) y se esperó su
indexado.

| Caso | Resultado |
|---|---|
| Login real, exitoso, desde `127.0.0.1` (IP nunca vista para esta cuenta, historial de 12 logins ≥ 3) | alerta `toma_cuenta` nace: `{"ip_nueva":"127.0.0.1","huella_nueva":true,"ips_conocidas":2,"logins_exitosos_previos":12}` |
| Segundo login real, misma cuenta, misma IP (`127.0.0.1`, ya indexada como conocida) | **no** nace una alerta nueva — el IP ya está en el historial |
| Cuenta con solo 2 logins exitosos previos (`admin_mesh`, antes de esta prueba) | no se evaluó nada (`MINIMO_HISTORIAL = 3`) |
| `GET ...?tipo=toma_cuenta` | `200`, la alerta exacta de arriba |
| `GET ...?tipo=fuerza_bruta_cuenta_lenta` (sin datos aún de ese tipo) | `200`, `alertas: []`, no un error |
| `GET ...?tipo=no-existe` | `400` con el mensaje de los 7 tipos válidos |

### Patrones lentos/repartidos (2026-09-11)

Las tres agregaciones (`terms`+`min_doc_count`, y `terms`+`cardinality`+
`bucket_selector`) se validaron **exactas** —mismo índice, mismos nombres
de campo (`*.keyword`), mismo script— contra Elasticsearch real, con datos
sembrados vía Mongo:

| Caso sembrado | Resultado de la agregación |
|---|---|
| 16 fallos en 20h contra `victima.lenta@mesh.test`, rotando por 5 IPs | `fuerza_bruta_cuenta_lenta`: 1 bucket, `doc_count: 16` (≥15). La misma cuenta **también** cruza `ip_rotacion_cuenta_lenta` (5 IPs ≥5) — correcto: un ataque real que además rota IP dispara las dos señales |
| 9 identificadores distintos probados desde `198.51.100.9` en 20h | `multi_cuenta_ip_lenta`: 1 bucket, `cardinalidad: 9` (≥8), `muestra` con los 9 identificadores |
| `rotador@mesh.test` probado desde 6 IPs distintas en 20h | `ip_rotacion_cuenta_lenta`: 1 bucket, `cardinalidad: 6` (≥5) |
| Cuentas/IPs con menos del umbral en la misma ventana | no aparecen en ningún bucket — `min_doc_count`/`bucket_selector` los descarta en el propio Elasticsearch, no en el backend |

El worker completo (`FraudeLoginRetrospectivoService`, corrida real del
`@Interval` de 15 min con el backend corriendo) se dejó corriendo en
segundo plano contra estos mismos datos sembrados para confirmar que
efectivamente escribe las filas en `alerta_fraude` — resultado en el
`cambio_propuestas` de esta ronda.

`npx tsc --noEmit` limpio sobre todos los archivos tocados. Limpieza:
`DELETE FROM alerta_fraude` + los documentos sintéticos de
`eventos_autenticacion` (por `identificador_intentado` en
`mesh.test`/`ip: 203.0.113.5`) y su réplica en el índice de Elasticsearch.

### `ip_rotacion_cuenta` en Redis (2026-09-11, segunda ronda)

No se puede generar tráfico real desde varias IPs distintas en una sola
máquina, así que se sembraron 3 IPs previas directo en la clave de Redis
que usa el código (`mesh:fraude:ips_cuenta:<identificador>`, vía
`redis-cli SADD`+`EXPIRE`) y se dejó que un login real fuera la 4ª — así
se ejercitó el código real de punta a punta, solo el "historial previo" es
simulado.

| Caso | Resultado |
|---|---|
| `SADD` manual de 3 IPs (`198.18.0.1/2/3`) + `EXPIRE 300` | `SCARD` → 3, no dispara nada (umbral 4) |
| Login real y exitoso de `comprador_sur`, desde `127.0.0.1` | `SADD` agrega la 4ª IP → `SCARD` → 4 (≥4) → alerta `ip_rotacion_cuenta`: `{"ips":["198.18.0.1","198.18.0.2","198.18.0.3","127.0.0.1"],"ips_distintas":4,"ventana_segundos":300}`, `cuenta_involucrada` con el id real |
| `TTL` de la clave tras el login | 292 s (no se reinició a 300 — confirma `EXPIRE ... NX`, la clave ya tenía TTL puesto por el `SADD` manual) |

Limpieza: `DELETE FROM alerta_fraude` de la fila de prueba +
`redis-cli DEL mesh:fraude:ips_cuenta:comprador.sur@mesh.com`.

### `viaje_imposible` (2026-09-11, tercera ronda)

Desde esta máquina solo hay IPs privadas (nunca geolocalizan), así que ni
siquiera un login real propio sirve para probar el lado "login actual" del
patrón. Se probó `ViajeImposibleService` **directo, con `ts-node`**, sin
pasar por HTTP — es una clase sin dependencias de inyección de Nest
(`elasticClient`/`pool` se importan directo), así que `new
ViajeImposibleService().revisarLogin(...)` ejercita el código real
(consulta real a Elasticsearch, UPSERT real en Postgres), solo sin la capa
HTTP encima. El "login anterior" se sembró en Mongo con geolocalización
real (Londres, la IP de prueba de MaxMind ya validada en la sesión donde
se probó `geoip-lite`) y se esperó su indexado.

**Bug real encontrado y corregido en el camino:** un campo `geo_point` de
Elasticsearch solo acepta `lat`/`lon` -- el primer intento (`geo: {lat,
lon, pais, ciudad}` como un solo objeto) hizo que CADA documento con esa
forma fallara al indexar (`document_parsing_exception: field [pais] not
supported`), y el worker de sync se quedó reintentando en silencio cada 5s
sin lograrlo (el diseño de "nunca tumba nada" funcionó como debía, pero
escondía el problema). Se corrigió aplanando el dato en tres campos
sueltos: `geo_punto` (el `geo_point` de verdad, solo `lat`/`lon`),
`geo_pais`, `geo_ciudad` (texto plano, mapping dinámico). El mapping viejo
de `geo` como `geo_point` quedó abandonado en el índice (nunca tuvo datos,
Elasticsearch no permite borrar un campo del mapping) -- inofensivo, pero
si alguien ve `geo` en el mapping del índice y no en ningún documento, es
por esto.

| # | Caso | Resultado |
|---|---|---|
| 1 | Login "anterior" sembrado: Londres (IP de prueba de MaxMind), hace 5 min | indexado correcto tras la corrección: `geo_punto: {"lat":51.753,"lon":-0.3256}`, `geo_pais:"GB"`, `geo_ciudad:"St Albans"` |
| 2 | `revisarLogin()` real, cuenta `comprador_sur`, geo actual = Guatemala City (real), `fecha` = ahora | alerta `viaje_imposible` (id 25): `distancia_km: 8748`, `horas_transcurridas: 0.14`, `velocidad_kmh: 63158` -- coincide exacto con la distancia Guatemala↔Londres ya validada en la prueba de `geoip-lite` |
| 3 | Mismo par de coordenadas, pero `fecha` 20h después (vuelo real) | **no** nace una segunda alerta -- `63158 km/h` vs `437 km/h`, la diferencia de 20h da una velocidad bajo el umbral |
| 4 | `GET /admin/fraude/alertas-login?tipo=viaje_imposible` (sesión admin real) | `200`, exactamente la alerta del caso 2, con las dos ubicaciones completas en `detalle` |

`npx tsc --noEmit` y `eslint` limpios sobre todos los archivos tocados.

**Limpieza:** `DELETE FROM alerta_fraude` de la fila de prueba +
el documento sintético de `eventos_autenticacion` (Mongo y su réplica en
Elasticsearch, por `ip: 81.2.69.142`).

## Lo que no se hizo en esta versión (y por qué)

- **Bloqueo o frenado automático.** Decisión explícita del usuario: por
  ahora el sistema solo alerta, nunca actúa sobre el login.
- **Mapping explícito de `geo_punto` del lado del compañero.** Se aplicó
  directo al índice local (`PUT _mapping`) para poder desarrollar y probar
  — la versión "oficial" en la carpeta `elastic/` (fuera de `backend/`)
  queda pendiente de que la integre.

El `PATCH` de revisión y el explorador de logs (punto 3 y 5 del plan,
mencionados como pendientes en versiones anteriores de este documento) se
construyeron en la ronda del 2026-09-11 — ver las dos secciones siguientes.

---

# GET /admin/fraude/eventos-login

El **explorador manual** de los logs crudos de autenticación — punto 3 del
plan (`fraude-login-eventos.md`), la parte que quedaba pendiente después de
`toma_cuenta`/patrones lentos/`viaje_imposible`: "todo lo que hizo esta
cuenta", sin agregación, para que un admin investigue a mano.

Código: `src/controllers/admin/admin-fraude-login.controller.ts` (controller
nuevo, no el mismo que `anillos`/`alertas-login`) +
`src/services/fraude-login/fraude-login-exploracion.service.ts`. **Solo
admin**, mismo criterio que el resto del panel.

**Lee directo de Elasticsearch (`mesh_eventos_autenticacion`), nunca de
Mongo** — Mongo es el origen inmutable del evento, pero no el que se
consulta (mismo criterio que el buscador de productos contra su propio
índice). Todos los filtros son exactos (`term` de Elasticsearch): los
campos disponibles (`ip`, `identificador_intentado`, `huella_cliente`) son
identificadores, no texto para buscar de forma difusa como en
`GET /buscador/productos`.

```
GET /admin/fraude/eventos-login?pagina=1&limite=20&tipo=login&resultado=fallo&ip=203.0.113.5&fecha_desde=2026-09-01&fecha_hasta=2026-09-11&incluir_usuario=true
```

| Filtro | Valores | Nota |
|---|---|---|
| `tipo` | `login`\|`logout`\|`registro` | |
| `resultado` | `exito`\|`fallo` | |
| `motivo` | `credenciales_invalidas`\|`usuario_inexistente`\|`cuenta_inactiva`\|`datos_invalidos` | solo tiene sentido con `resultado=fallo`, pero no se exige la combinación |
| `id_usuario` | entero | |
| `identificador`, `ip`, `huella_cliente`, `geo_pais` | texto exacto | se recorta espacios; vacío cuenta como ausente |
| `fecha_desde`, `fecha_hasta` | ISO 8601 | rango sobre `fecha`; `fecha_desde > fecha_hasta` es `400` |
| `incluir_usuario` | `true`\|`false` (por defecto `false`) | ver la nota de abajo |

Todos son opcionales e independientes; sin ninguno, todos los eventos, más
recientes primero (`sort: fecha desc`). Paginación por número de página
(`pagina`/`limite`, mismas reglas que el resto del proyecto), traducida a
`from`/`size` de Elasticsearch.

**`incluir_usuario` — dos versiones a propósito, conviven en el código.**
Por defecto (`false`), la respuesta trae `id_usuario` tal cual está en el
evento, sin ningún viaje adicional a Postgres. Con `incluir_usuario=true`,
el servicio junta los `id_usuario` distintos de la página (nunca más de
`limite`) y hace **una sola consulta batch** a `usuarios` para resolver el
`usuario` de cada uno, agregando `cuenta_involucrada: { id_usuario, usuario
} | null` a cada evento. Se dejaron las dos rutas de código en vez de
reemplazar una por otra, a pedido explícito: sirven para medir el costo
real del enriquecimiento contra la versión base antes de decidir cuál usar
por defecto en el frontend.

### 200

```json
{
  "ok": true,
  "mensaje": "Eventos de autenticacion obtenidos",
  "payload": {
    "eventos": [
      {
        "id": "6aa4699439dd84265ac1e448",
        "tipo": "login",
        "resultado": "exito",
        "motivo": null,
        "id_usuario": "5",
        "cuenta_involucrada": { "id_usuario": "5", "usuario": "admin_mesh" },
        "identificador_intentado": "admin_mesh",
        "ip": "172.22.192.1",
        "user_agent": "curl/8.6.0",
        "huella_cliente": "0853efb34c97d391f0436e3e4c5789d1cad6a4a25e342f538ffbf4ffc02d15b7",
        "geo": { "lat": 51.753, "lon": -0.3256, "pais": "GB", "ciudad": "St Albans" },
        "fecha": "2026-09-11T20:50:28.263Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_eventos": 28,
    "total_paginas": 2,
    "incluyo_usuario": true
  }
}
```

`cuenta_involucrada` **no viene en la respuesta** (ni siquiera en `null`)
cuando la petición no pidió `incluir_usuario=true` — así el frontend puede
distinguir "no se pidió" de "no hay cuenta para este evento". `geo` es
`null` sin IP, con IP privada/local, o si `geoip-lite` no la resolvió — ver
`endpoints-fraude.md` arriba, sección `viaje_imposible`, para el detalle
del campo.

### 400

```json
{ "ok": false, "mensaje": "El tipo debe ser uno de: login, logout, registro", "payload": null }
{ "ok": false, "mensaje": "fecha_desde debe ser una fecha valida (ISO 8601)", "payload": null }
{ "ok": false, "mensaje": "fecha_desde no puede ser posterior a fecha_hasta", "payload": null }
{ "ok": false, "mensaje": "incluir_usuario debe ser \"true\" o \"false\"", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto del panel: sin sesión → `401`; sesión
válida pero no admin (comprador, vendedor, o la tienda) → `403`.

## Pruebas — hechas el 2026-09-11

Contra el servidor y las bases reales (`mesh-elastic`, `mesh-postgres`),
`npm run start:dev`, sesión real de `admin_mesh`. Scripts en el scratchpad,
no en el repo.

| Caso | Resultado |
|---|---|
| Sin filtros, `limite=3` | `200`, 3 eventos, `total_eventos: 28`, `incluyo_usuario: false`, sin `cuenta_involucrada` en ningún evento |
| Igual, con `incluir_usuario=true` | `200`, mismos 3 eventos, cada uno con `cuenta_involucrada: {"id_usuario":"5","usuario":"admin_mesh"}` |
| `tipo=login&resultado=exito&ip=172.22.192.1&limite=2` | `200`, solo los logins exitosos de esa IP, `total_eventos: 12` |
| `identificador=admin_mesh&limite=1` | `200`, 1 evento, `total_eventos: 10` |
| `id_usuario=5&limite=1` | `200`, evento del admin |
| `geo_pais=Guatemala&limite=2` | `200`, `eventos: []`, `total_eventos: 0` (sin datos con esa geo en el entorno local) — no es un error |
| `tipo=noexiste` | `400` "El tipo debe ser uno de: login, logout, registro" |
| `fecha_desde=no-es-fecha` | `400` "fecha_desde debe ser una fecha valida (ISO 8601)" |
| `fecha_desde=2026-09-11&fecha_hasta=2026-09-01` (invertido) | `400` "fecha_desde no puede ser posterior a fecha_hasta" |
| Sin cookie | `401` "No hay sesion activa" |
| Sesión de `compradora.norte@mesh.com` (rol comprador) | `403` "No tienes permiso para hacer esto" |

`npx tsc --noEmit` limpio sobre todos los archivos tocados. Sin limpieza
necesaria: esta ruta es de solo lectura.

---

# PATCH /admin/fraude/alertas-login/:id

Marcar una alerta ya existente (de cualquiera de las 9 señales de
`alerta_fraude`, sin distinguir si nació de Redis o de Elasticsearch) como
`revisada` o `descartada` — punto 5 del plan, la pieza de escritura que le
faltaba a `GET /admin/fraude/alertas-login`.

Código: mismo controller y servicio que `GET /admin/fraude/eventos-login`
(`AdminFraudeLoginController` / `FraudeLoginExploracionService`) — no toca
`FraudeLoginService` ni el resto de servicios que escriben alertas.

```
PATCH /admin/fraude/alertas-login/18
Content-Type: application/json

{ "estado": "revisada" }
```

**Solo admite `revisada` o `descartada` como destino — nunca `pendiente`.**
Y **solo se admite viniendo de `pendiente`**: una alerta ya revisada o
descartada no se puede volver a mover desde esta ruta.

```sql
UPDATE alerta_fraude
   SET id_estado_alerta_fraude = <destino>, fecha_actualizacion = now()
 WHERE id_alerta_fraude = <id>
   AND id_estado_alerta_fraude = <pendiente>
```

Si el `UPDATE` no afecta ninguna fila, una segunda consulta distingue el
motivo: si la alerta no existe → `404`; si existe pero ya no está pendiente
→ `409`.

### 200

```json
{
  "ok": true,
  "mensaje": "Alerta actualizada",
  "payload": {
    "id_alerta_fraude": "18",
    "tipo_alerta": "fuerza_bruta_cuenta",
    "clave": "demo.fraude@mesh.test",
    "cuentas_afectadas": [],
    "detalle": { "fallos": 5, "ventana_segundos": 60 },
    "contador": 1,
    "ventana_inicio": "2026-09-11T04:47:00.000Z",
    "estado": "revisada",
    "fecha_creacion": "2026-09-11T04:47:19.126Z",
    "fecha_actualizacion": "2026-09-11T20:51:04.262Z"
  }
}
```

Misma forma que una fila de `GET /admin/fraude/alertas-login`.

### 400

```json
{ "ok": false, "mensaje": "El estado debe ser uno de: revisada, descartada", "payload": null }
{ "ok": false, "mensaje": "El id de la alerta debe ser un numero entero", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una alerta con ese id", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "La alerta ya no esta pendiente de revision", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto del panel.

## Pruebas — hechas el 2026-09-11

Contra una alerta real y pendiente (`id_alerta_fraude: 18`,
`fuerza_bruta_cuenta`, sembrada en una sesión anterior). Sesión real de
`admin_mesh`.

| Caso | Resultado |
|---|---|
| `PATCH /alertas-login/18 {"estado":"revisada"}` | `200`, `estado: "revisada"`, `fecha_actualizacion` avanza |
| Mismo `PATCH` otra vez (ya no está pendiente) | `409` "La alerta ya no esta pendiente de revision" |
| `PATCH /alertas-login/999999 {"estado":"revisada"}` (no existe) | `404` "No existe una alerta con ese id" |
| `PATCH /alertas-login/18 {"estado":"pendiente"}` (destino inválido) | `400` "El estado debe ser uno de: revisada, descartada" |
| `PATCH /alertas-login/abc {"estado":"revisada"}` (id no numérico) | `400` "El id de la alerta debe ser un numero entero" |
| Sesión de `compradora.norte@mesh.com` | `403` |

`npx tsc --noEmit` limpio. **Limpieza:** la alerta 18 se restauró a
`pendiente` por SQL directo al terminar (era una alerta real, sembrada
antes de esta ronda, no un dato descartable de la prueba).

---

## GET /perfil/alertas-fraude y PATCH /perfil/alertas-fraude/:id

Segundo pedido del profesor sobre este módulo (después del disparo
inmediato por login, más abajo): que las alertas de fraude también las vea
el **usuario afectado**, no solo el admin — "por si cualquiera desea tomar
acción". Detalle de diseño completo en
`elementos Generales/plan pendiente/notificacion-fraude-usuario.md`
(incluida la corrección de una ronda a otra: la primera versión asumía UN
afectado por alerta, y es falso para `multi_cuenta_ip`/`multi_cuenta_ip_lenta`).

Dos rutas en `PerfilController` (mismo lugar que `PATCH /perfil/contrasena`)
— "mis datos", protegidas solo por `SesionGuard` (cualquier usuario
logueado, no `@Roles(ID_ROL_ADMIN)`), nunca reciben un id de cuenta por
parámetro: `id_usuario` siempre sale de la sesión. Leen/escriben la tabla
`notificacion_fraude` (una fila por cada cuenta a la que le corresponde
ver una alerta — no una columna en `alerta_fraude`), vía
`FraudeLoginService`.

**`GET /perfil/alertas-fraude`** — paginado (`pagina`/`limite`, mismas
reglas que el resto del proyecto), filtrado a
`notificacion_fraude.id_usuario = <la sesión>`, ordenado por
`fecha_creacion` de la alerta, más nueva primero. Cada fila trae
`fecha_lectura` de LA NOTIFICACIÓN de esa cuenta (`null` = no leída) — no
de la alerta en sí, cada afectado tiene la suya. Aparecen las 6 señales de
una sola cuenta (`fuerza_bruta_cuenta`, `ip_rotacion_cuenta` y sus
`_lenta`, `toma_cuenta`, `viaje_imposible`) **y también**
`multi_cuenta_ip`/`multi_cuenta_ip_lenta` si esta cuenta fue una de las
probadas desde esa IP — a diferencia de la primera versión de esta ruta,
ya no se quedan solo-admin. Solo `fuerza_bruta_ip` sigue sin llegarle a
nadie (no trae una lista de cuentas objetivo).

**El `detalle` de `multi_cuenta_ip`/`multi_cuenta_ip_lenta` viene
redactado** para este endpoint: sin la lista `identificadores` (los
correos/usuarios de las DEMÁS cuentas que esa misma IP también probó) —
solo se conserva `cuentas_distintas` (el conteo) y el resto de campos.
Decisión explícita del usuario: el afectado sabe que no fue el único
blanco, sin enterarse de quiénes fueron los demás. Admin sigue viendo la
lista completa en `GET /admin/fraude/alertas-login`.

**`PATCH /perfil/alertas-fraude/:id`** — marca la fila de
`notificacion_fraude` de esa cuenta como leída
(`SET fecha_lectura = COALESCE(fecha_lectura, now())`, idempotente). El
`ownership check` va en el propio `UPDATE`
(`WHERE id_alerta_fraude = $1 AND id_usuario = $2` sobre
`notificacion_fraude`) — si no existe esa notificación (la alerta no
existe, o existe pero esta cuenta nunca estuvo entre los afectados), el
mismo `404` genérico en los dos casos, para no filtrar si una alerta ajena
existe.

### 200 — GET

Una cuenta con una alerta propia (`viaje_imposible`) y otra que además fue
una de las probadas en un `multi_cuenta_ip` (`detalle` ya redactado, sin
`identificadores`):

```json
{
  "ok": true,
  "mensaje": "Alertas de fraude obtenidas",
  "payload": {
    "alertas": [
      {
        "id_alerta_fraude": "20",
        "tipo_alerta": "multi_cuenta_ip",
        "clave": "198.51.100.9",
        "detalle": { "cuentas_distintas": 4, "ventana_segundos": 300 },
        "contador": 1,
        "ventana_inicio": "2026-09-15T19:40:00.000Z",
        "fecha_creacion": "2026-09-15T19:40:12.400Z",
        "fecha_lectura": null
      },
      {
        "id_alerta_fraude": "140",
        "tipo_alerta": "viaje_imposible",
        "clave": "usuario_afectado",
        "detalle": { "distancia_km": 14313, "velocidad_kmh": 80520 },
        "contador": 1,
        "ventana_inicio": "2026-09-15T17:34:00.000Z",
        "fecha_creacion": "2026-09-15T17:34:54.600Z",
        "fecha_lectura": "2026-09-15T19:41:02.000Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_alertas": 2,
    "total_paginas": 1
  }
}
```

Sin `cuentas_afectadas` ni nada del lado admin (`estado`,
`id_usuario_reviso`) — esa es toda la diferencia con la forma que ve el
admin en `GET /admin/fraude/alertas-login`.

### 200 — PATCH

Misma forma que una fila del `GET`, con `fecha_lectura` ya puesta.

### 400

```json
{ "ok": false, "mensaje": "El id de la alerta debe ser un numero entero", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe una alerta con ese id para tu cuenta", "payload": null }
```

### 401

Sin cookie de sesión válida — mismo comportamiento que el resto de `/perfil`.

## Pruebas — hechas el 2026-09-15 (dos rondas)

**Primera ronda** (columna `fecha_lectura_usuario`, superada por la
segunda): 401 sin cookie, listado y paginación correctos, `PATCH`
idempotente, 404 genérico ante alerta ajena / con `id_usuario NULL` / id
inexistente, 400 con id no numérico. Detalle completo en
`cambio_propuestas/2026-09-15_1500-notificacion-fraude-usuario.md`.

**Segunda ronda** (la corrección: `notificacion_fraude`, multi-afectados),
contra el servidor real, con 3 cuentas de prueba registradas para la
ocasión (`multicuenta_test_a/b/c`) probadas desde la misma IP en un
ataque `multi_cuenta_ip` real (más un cuarto identificador,
`multicuenta_test_fantasma`, que no correspondía a ninguna cuenta):

**Bug real encontrado y corregido en esta ronda:** `id_usuario` dentro de
`cuentas_afectadas` salía como número JSON (`16`), no como texto —
inconsistente con el resto de la API, donde todos los ids son string (para
no perder precisión con bigint). `json_build_object` en Postgres serializa
el valor tal cual es; hacía falta `nf.id_usuario::text` explícito dentro
del `json_build_object` de `SQL_CUENTAS_AFECTADAS`. Corregido en las dos
copias (`fraude-login.service.ts` y `fraude-login-exploracion.service.ts`)
antes de seguir probando.

| Caso | Resultado |
|---|---|
| Las 4 cuentas reales probadas desde la misma IP (incluida `prueba_admin_fraude`, que se sumó sin querer al loguearse para las pruebas) | la alerta `multi_cuenta_ip` nace con `cuentas_afectadas` con las 4 — `id_usuario` como string, ya corregido |
| El identificador `multicuenta_test_fantasma` (no correspondía a ninguna cuenta) | **no** genera fila en `notificacion_fraude` ni aparece en `cuentas_afectadas`, aunque sí sigue en `detalle.identificadores` (evidencia de admin) |
| `GET /perfil/alertas-fraude` de cada una de las 4 cuentas afectadas | cada una la trae, `detalle` SIN `identificadores`, con `cuentas_distintas` — 4 notificaciones de la misma alerta, una por cuenta |
| Una de las 4 cuentas marca `PATCH /perfil/alertas-fraude/:id` | `200`, esa cuenta pasa a `fecha_lectura` puesta; las otras 3 siguen en `null` — confirma que la lectura es POR CUENTA, no compartida |
| `GET /admin/fraude/alertas-login` después del `PATCH` anterior | la misma alerta muestra una cuenta con `fecha_lectura` y tres sin — admin ve quién ya se enteró |
| Repetir el mismo ataque dentro de la misma ventana (`contador` 1→2, con un login exitoso de una de las cuentas afectadas) | `notificacion_fraude` sigue en exactamente 4 filas — el `xmax = 0` solo dispara en el `INSERT`, no en el `UPDATE` del `ON CONFLICT`, confirmado por SQL directo antes y después |
| Ownership: una cuenta AJENA a la alerta (nunca probada desde esa IP) intenta `PATCH` | `404` "No existe una alerta con ese id para tu cuenta" |
| Ownership, primer intento de esta prueba, descartado | se probó por error con una cuenta que en realidad SÍ era una de las afectadas — dio `200` correctamente (no es el caso de ownership que se quería probar); se repitió con una cuenta genuinamente ajena para el resultado de arriba |
| Alerta de una sola cuenta, sembrada ANTES de que existiera `notificacion_fraude` (`toma_cuenta`, de la primera ronda) | `cuentas_afectadas: []` — no hay backfill retroactivo, decisión aceptada desde el plan, no es un bug |
| Alerta de una sola cuenta, sembrada DESPUÉS (`fuerza_bruta_cuenta` fresca, 5 fallos contra `multicuenta_test_c`) | `cuentas_afectadas` con exactamente un elemento — confirma el camino de una-sola-cuenta sigue intacto |
| `fuerza_bruta_ip` (sin lista de cuentas objetivo) | `cuentas_afectadas: []` en admin; nunca aparece en ningún `GET` de usuario |

Confirmado además, por SQL directo, que marcar `notificacion_fraude.fecha_lectura`
NO toca `alerta_fraude.fecha_actualizacion` ni `id_estado_alerta_fraude` —
el estado de revisión del admin y la lectura de cada usuario afectado
quedan completamente independientes, igual que en la primera ronda.

`npx tsc --noEmit` limpio. Sin errores ni warnings en el log del servidor
durante toda la ronda.

---

# GET /admin/grafo/conciliacion

La **red de seguridad** de la sincronización del grafo. El grafo de Neo4j
es una **proyección** de la tabla `resena`: hoy lo carga el ETL
(`etl/cargar_grafo.sh`), y cuando esté el worker del outbox se mantendrá al
día solo. Esta ruta **compara** los conteos de las dos bases y **avisa** si
hay deriva — **no repara** (para eso está `etl/cargar_grafo.sh --limpiar`,
que reconstruye el grafo desde cero). Es lo que el profesor pidió como "un
job que lo reconcilie de ser necesario".

> **Estado (2026-09-03): implementada y PROBADA en vivo.** Ver "Pruebas" al
> final de esta sección.

Código: `src/controllers/grafo/grafo.controller.ts` +
`src/services/grafo/grafo-sync.service.ts` (el worker del outbox se
agregará a esta misma clase). **Solo admin** — no la tienda, es información
de operación de todo el sistema, mismo criterio que `/admin/fraude/alertas-resenas`.

## Qué compara

Seis filas. Lo que de verdad importa es que **cada reseña de PostgreSQL
tenga su nodo completo en el grafo**:

| Recurso | PostgreSQL | Neo4j | ¿cuenta para el veredicto? |
|---|---|---|---|
| `resenas` | `count(*) FROM resena` | nodos `:Resena` | **sí** |
| `relacion ESCRIBIO` | `count(*) FROM resena` | relaciones `ESCRIBIO` | **sí** |
| `relacion CALIFICA_A` | `count(*) FROM resena` | relaciones `CALIFICA_A` | **sí** |
| `relacion SOBRE` | `count(*) FROM resena` | relaciones `SOBRE` | **sí** |
| `productos resenados` | `count(DISTINCT id_producto_mongo)` | nodos `:Producto` | no |
| `usuarios con resena` | autores ∪ vendedores distintos | nodos `:Usuario` | no |

**Por qué productos y usuarios no cuentan para el veredicto:** el worker
incremental puede dejar nodos huérfanos (una reseña borrada se lleva su
`:Resena` con `DETACH DELETE` pero deja el `:Producto`), y el ETL completo
carga **todos** los usuarios, no solo los que aparecen en una reseña. Un
exceso ahí (`diferencia > 0`) es normal. Se informan igual, para tener el
panorama.

`cuadra` es `true` solo si las cuatro filas de arriba tienen
`diferencia = 0` (`diferencia = neo4j - postgres`).

## 200

```json
{
  "ok": true,
  "mensaje": "El grafo tiene deriva respecto a PostgreSQL",
  "payload": {
    "cuadra": false,
    "verificado_en": "2026-09-04T05:43:26.080Z",
    "ultima_sincronizacion": null,
    "cola": { "pendientes": 1, "apartados": 0 },
    "comparacion": [
      { "recurso": "resenas",             "postgres": 87, "neo4j": 86, "diferencia": -1, "cuenta_para_veredicto": true },
      { "recurso": "relacion ESCRIBIO",   "postgres": 87, "neo4j": 86, "diferencia": -1, "cuenta_para_veredicto": true },
      { "recurso": "relacion CALIFICA_A", "postgres": 87, "neo4j": 86, "diferencia": -1, "cuenta_para_veredicto": true },
      { "recurso": "relacion SOBRE",      "postgres": 87, "neo4j": 86, "diferencia": -1, "cuenta_para_veredicto": true },
      { "recurso": "productos resenados", "postgres": 55, "neo4j": 54, "diferencia": -1, "cuenta_para_veredicto": false },
      { "recurso": "usuarios con resena", "postgres": 7,  "neo4j": 8,  "diferencia": 1,  "cuenta_para_veredicto": false }
    ],
    "eventos_apartados": [],
    "sugerencia": "Al grafo le faltan datos: 1 en resenas, 1 en relacion ESCRIBIO, 1 en relacion CALIFICA_A, 1 en relacion SOBRE. Hay 1 evento(s) pendiente(s) en la cola: si el numero no baja solo en unos minutos, corre `etl/cargar_grafo.sh --limpiar`."
  }
}
```

Cuando todo cuadra: `"cuadra": true`, `"sugerencia": null`, mensaje "El
grafo esta al dia con PostgreSQL".

| Campo | Qué es |
|---|---|
| `cuadra` | `true` si las reseñas y sus tres relaciones están todas al día |
| `verificado_en` | Cuándo se corrió esta comprobación (ISO 8601) |
| `ultima_sincronizacion` | `max(procesado_en)` de la cola del outbox — el evento aplicado más reciente. `null` si ninguno se ha procesado, o si la tabla aún no existe |
| `cola` | `{ pendientes, apartados }` del outbox (`evento_grafo`). **`null` si la tabla `evento_grafo` todavía no existe** (la migración `015` la hace el compañero) — la conciliación sigue siendo útil sin la cola |
| `cola.pendientes` | eventos sin aplicar (`procesado_en IS NULL`, `intentos < 5`) |
| `cola.apartados` | eventos que fallaron 5 veces y no se reintentan más (`intentos >= 5`) |
| `comparacion[]` | Una fila por recurso (ver la tabla de arriba) |
| `eventos_apartados[]` | Los apartados en detalle (`id_evento`, `id_resena`, `intentos`, `ultimo_error`, `fecha`), hasta 100. Para que un humano los mire |
| `sugerencia` | Frase lista para la pantalla: qué falta y qué hacer. `null` solo cuando `cuadra` es `true` **y** no hay apartados |

## 401 / 403

Sin sesión → `401`. Con sesión pero rol comprador o vendedor (**incluida la
tienda**) → `403`.

## 503

PostgreSQL o Neo4j caídos → `503` "No se pudo conectar con PostgreSQL" /
"...con Neo4j", sin colgarse (límite de 15 s sobre las dos consultas).

## Pruebas — hechas el 2026-09-03

Contra el servidor y las bases reales. En ese momento el grafo estaba
**atrasado por 1 reseña** (la reseña de demostración 112, creada en
PostgreSQL y nunca cargada al grafo) — un caso de deriva real, no sembrado.

| Caso | Resultado |
|---|---|
| Sin sesión | `401` |
| Rol comprador | `403` |
| Rol vendedor / tienda | `403` |
| Admin, grafo atrasado | `cuadra: false`; las 4 filas de veredicto en `diferencia: -1`; `cola.pendientes: 1`; `sugerencia` con la lista de faltantes y el consejo de `--limpiar` |
| Admin, tras `etl/cargar_grafo.sh --limpiar` | `cuadra: true`, `sugerencia: null`; `usuarios con resena` queda en `+1` (Neo4j carga todos los usuarios) sin tumbar el veredicto |
| Evento envenenado (`id_resena` inexistente, `intentos = 5`) | aparece en `cola.apartados` y en `eventos_apartados[]` con su `ultimo_error`; si los conteos cuadran, `sugerencia` lo menciona igual ("Los conteos cuadran. Hay 1 evento apartado...") |
| Tabla `evento_grafo` ausente | `cola: null`, `ultima_sincronizacion: null`, `eventos_apartados: []`; la comparación PG↔Neo4j sigue funcionando |
| Neo4j caído | `503` "No se pudo conectar con Neo4j"; se recupera solo al volver |

`npx tsc --noEmit` y `eslint` limpios. `cambio_propuestas/2026-09-03_2359-conciliacion-grafo.md`.

---

# Anillos de fraude en reseñas -- alertas-resenas (2026-09-17/18, renombrado 2026-09-18)

Tres rutas, **controller y servicio aparte** de todo lo de arriba a
propósito (pedido explícito): `AdminFraudeAnillosController` +
`FraudeAnillosPersistidosService`
(`src/controllers/admin/admin-fraude-anillos.controller.ts` +
`src/services/fraude/fraude-anillos-persistidos.service.ts`). **Solo
admin**, mismo criterio que el resto del panel. Nombradas `alertas-resenas`
en paralelo con `alertas-login` (mismo sustantivo, distinto dominio) desde
que se eliminó el panel EN VIVO `GET /admin/fraude/anillos` (ver la nota al
inicio de este archivo) y el sufijo `-persistidos` dejó de tener con qué
contrastar.

Estas rutas leen la tabla `anillo_fraude`/`anillo_fraude_resena`, que llenan
DOS workers: `AnillosDetectorService` (A.1 ciclos, A.2 mismo producto,
tipos `mutuo`/`ciclo`/`reiterado`, ver `plan pendiente/anillos-fraude-persistencia.sql`)
y, desde 2026-09-24, `PatronesFraudeDetectorService` -- seis consultas más
(`cadena_abierta`, `satelites`, `persistente`, `favor_devuelto`,
`coordinados`, `reputacion_expres`; B.1-B.3 y B.5-B.7 de
`neo4j/consultas/`), ver `plan pendiente/anillos-fraude-familia-b.md`. Los
dos workers corren cada 15 min sobre una ventana de **60 días** y tienen su
propio chequeo acotado por reseña (excepto `satelites`/`reputacion_expres`,
que agrupan por vendedor y solo corren en el periódico).

**Desde 2026-10-02 hay un tercero:** `ResenasRepetidasDetectorService`
(tipo `resenas_repetidas`, familia `patron_resenas`), que no usa el grafo sino
el texto de las reseñas en Elasticsearch (`mesh_comentarios`): una cuenta con
5 o más reseñas que tienen una "gemela" suya (otra casi igual, coseno 0,92) **y**
que son el **30 %** o más de sus reseñas de 100 caracteres o más, en los
últimos 180 días (desde 2026-10-04 por porcentaje; antes un grupo de 5 de al
menos 40 caracteres). Una señal por cuenta (`clave` = su id). Corre cada 15 min y
no tiene chequeo acotado por reseña. Ver
`plan pendiente/resenas-repetidas.md`. Y su hermano `AnilloDeTextoDetectorService`
(tipo `anillo_de_texto`, también fuente `elastic`): 3 o más cuentas distintas con
reseñas casi iguales (de 100 caracteres o más desde 2026-10-04) sobre el mismo
vendedor, con 30 días o menos de diferencia; sigue por **cantidad de cuentas**,
no por porcentaje; una señal por anillo (`clave` = sus cuentas ordenadas, unidas con guion). Ver
`plan pendiente/anillo-de-texto.md`. Sus señales salen en esta lista y en
`detalle-grafo` como las demás (la lista de reseñas de la evidencia se consulta
en el grafo igual).

**Desde 2026-10-04 hay dos más, de reseñas copiadas**
(`ResenasParecidasDetectorService`, fuente `elastic`, familia `patron_resenas`):
`resenas_parecidas_vendedor` (clave = id del vendedor) y
`resenas_parecidas_producto` (clave = `p<id_producto>`). Una reseña tiene
"gemela" si otra, de **otra cuenta**, se le parece (coseno ≥ 0,92) y se escribió
con 30 días o menos de diferencia; las de la misma cuenta no cuentan (esa es
`resenas_repetidas`). Piden 5 o más reseñas con gemela **y** que sean el
**20 %** (vendedor) o el **40 %** (producto) de las analizadas (raíz, 100
caracteres o más, 180 días). Son solo alerta para el admin: no forman casos ni
suman puntos. Ver `plan pendiente/resenas-parecidas.md`.

**Desde 2026-10-04 hay tres más, de reseñas "contradictorias"**
(`NotasIncoherentesDetectorService`, fuente `elastic`, familia
`patron_resenas`): una reseña es contradictoria si su **texto** es malo y tiene
4 o 5 estrellas, o su texto es bueno y tiene 1 o 2 (el 3 nunca cuenta). El
texto lo valora una regresión logística (`valoracion_texto` en
`mesh_comentarios`, la pone `ValoracionComentariosService`). Solo cuentan
reseñas raíz de 100 a 350 caracteres, de los últimos 180 días. Cada señal pide
**5 o más** contradictorias **y** un porcentaje de las reseñas valoradas:

| Tipo | Sobre quién | Porcentaje | `clave` | Entra a los casos |
|---|---|---|---|---|
| `notas_incoherentes_cuenta` | las reseñas que escribió una cuenta | 20 % | su id | **sí** (10 puntos, no es `TIPOS_FUERTES`) |
| `notas_incoherentes_producto` | las reseñas que recibió un producto | 40 % | `p<id_producto>` | no, solo alerta |
| `notas_incoherentes_vendedor` | las reseñas de los productos de un vendedor | 20 % | su id | no, solo alerta |

La de producto y la de vendedor son **solo alerta para el admin** (salen en
`GET /admin/fraude/alertas-resenas`, no forman casos ni suman puntos), porque
una reseña contradictoria tanto puede venir de quien compra reseñas como de una
campaña en contra del vendedor. En la de vendedor la cuenta sale en `cuentas`
con rol `autor` solo porque así lo guarda `senal_fraude_cuenta`: aquí no
significa culpable. La de producto no lleva cuentas (la `clave` empieza con `p`
para que no se tome por una) y se liga en `senal_fraude_producto`. Ver
`plan pendiente/notas-incoherentes.md`.

A.4 (misma dirección) y B.4 (anillo en el tiempo) **no** están en esta
tabla: A.4 no depende de reseñas, así que no tiene un disparador natural con
el mecanismo actual (ver `plan pendiente/anillos-fraude-persistencia.md`);
B.4 es una consulta de diagnóstico (qué tanto esconde la ventana de 60 días)
que no se conectó al backend a propósito (ver
`plan pendiente/anillos-fraude-familia-b.md`).

## GET /admin/fraude/alertas-resenas

```
GET /admin/fraude/alertas-resenas?pagina=1&limite=20&estado=pendiente&tipo=ciclo
```

Paginación por número de página (`validarLimite`/`validarPagina`, mismas
reglas que el resto del proyecto). Dos filtros opcionales e independientes:

- `estado=pendiente|revisada|descartada` -- reusa el mismo catálogo y las
  mismas funciones de validación que `alertas-login`
  (`validarFiltroEstadoAlerta`), sin duplicar nada.
- `tipo=mutuo|ciclo|reiterado|cadena_abierta|satelites|persistente|favor_devuelto|coordinados|reputacion_expres|resenas_repetidas|anillo_de_texto|notas_incoherentes_cuenta|notas_incoherentes_producto|notas_incoherentes_vendedor|resenas_parecidas_producto|resenas_parecidas_vendedor`
  (`anillo_en_el_tiempo`, B.4, no está porque no se persiste como caso propio).
- sin alguno de los dos -- no se filtra por ese campo; sin ninguno, todos,
  ordenados por `ultima_vez_confirmado_activo DESC` (los que siguen activos
  primero, no por cuándo se crearon).

### 200

```json
{
  "ok": true,
  "mensaje": "Anillos obtenidos",
  "payload": {
    "anillos": [
      {
        "id_anillo_fraude": "19",
        "tipo": "reiterado",
        "clave": "9-10",
        "cuentas": [
          { "id_usuario": "9", "usuario": "anillo_dos" },
          { "id_usuario": "10", "usuario": "anillo_uno" }
        ],
        "resenas": [87, 88],
        "estado": "pendiente",
        "fecha_creacion": "2026-09-18T06:21:06.153Z",
        "ultima_vez_confirmado_activo": "2026-09-18T06:21:06.153Z",
        "fecha_actualizacion": "2026-09-18T06:21:06.153Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_anillos": 2,
    "total_paginas": 1
  }
}
```

`cuentas` **no es una tabla propia** -- no existe `anillo_fraude_cuenta`:
sale de un `UNION` sobre `resena.id_usuario`/`id_usuario_vendedor`, unido
contra `usuarios`, para las reseñas listadas en `resenas`. Para casi todos
los tipos toda cuenta del caso es autor o vendedor de alguna de sus reseñas,
así que guardarlas aparte sería redundante. **Excepción: `coordinados`
(B.6)** -- ahí el vendedor calificado es un tercero ajeno al patrón (los dos
autores coinciden calificándolo, no se relacionan entre sí), así que ese
tipo deriva las cuentas SOLO de `resena.id_usuario`, sin el vendedor.
`resenas` son los ids de `resena` (los mismos que en Neo4j) que son la
evidencia -- ver `detalle-grafo` abajo para su contenido real.

**Sin ningún campo JSON de evidencia** (a diferencia de `alerta_fraude.detalle`)
y **sin ninguna notificación a las cuentas del anillo** -- decisión
explícita: en un anillo de reseñas la cuenta señalada es la SOSPECHOSA, no
la víctima (al revés que en fraude de login), así que avisarle le daría la
oportunidad de evadir la detección. El caso es 100% interno para revisión
de un admin. Detalle completo del razonamiento en
`plan pendiente/anillos-fraude-persistencia.md`.

### 400

```json
{ "ok": false, "mensaje": "El estado debe ser uno de: pendiente, revisada, descartada", "payload": null }
{ "ok": false, "mensaje": "El tipo debe ser uno de: mutuo, ciclo, reiterado, cadena_abierta, satelites, persistente, favor_devuelto, coordinados, reputacion_expres, resenas_repetidas, anillo_de_texto, notas_incoherentes_cuenta, notas_incoherentes_producto, notas_incoherentes_vendedor, resenas_parecidas_producto, resenas_parecidas_vendedor", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto del panel: sin sesión -> `401`; sesión
válida pero no admin -> `403`.

## PATCH /admin/fraude/alertas-resenas/:id

```
PATCH /admin/fraude/alertas-resenas/19
Content-Type: application/json

{ "estado": "revisada" }
```

Mismo criterio exacto que `PATCH /admin/fraude/alertas-login/:id`: solo
admite `revisada`/`descartada` como destino, y **solo desde `pendiente`** --
un anillo ya revisado o descartado no se puede volver a mover desde esta
ruta. Devuelve el anillo actualizado (misma forma que el listado).

### 409

```json
{ "ok": false, "mensaje": "El anillo ya no está pendiente de revisión", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un anillo con ese id", "payload": null }
```

## GET /admin/fraude/alertas-resenas/:id/detalle-grafo

El detalle REAL de un anillo ya persistido -- **no vuelve a correr A.1/A.2**
(ya se sabe cuáles son las reseñas de este anillo, en
`anillo_fraude_resena`), solo le pide a Neo4j esas reseñas puntuales con su
autor, vendedor, producto, fecha y calificación.

```
GET /admin/fraude/alertas-resenas/18/detalle-grafo
```

### 200

```json
{
  "ok": true,
  "mensaje": "Detalle del anillo obtenido",
  "payload": {
    "id_anillo_fraude": "18",
    "tipo": "ciclo",
    "clave": "9-10-11",
    "resenas": [
      {
        "id_resena": 87,
        "autor": "anillo_uno",
        "correo_autor": "anillo.uno@mesh.com",
        "vendedor": "anillo_dos",
        "correo_vendedor": "anillo.dos@mesh.com",
        "producto": "Cartas al puerto seco",
        "calificacion": 5,
        "fecha": "2026-03-08T15:12:00Z"
      }
    ]
  }
}
```

`404` "No existe un anillo con ese id" si el id no existe. `503` "No se
pudo conectar con Neo4j" si el grafo no responde en 15 s.

## Pruebas -- hechas el 2026-09-17/18

Contra el servidor y las bases reales (`mesh-postgres`, `mesh-neo4j`),
`npm run start:dev`, sesión real de `admin_mesh` (HTTP de verdad, con
`curl` y cookie de sesión -- no solo llamadas directas al servicio). Se
usó el anillo REAL ya sembrado en el dataset (cuentas
`anillo_uno`/`anillo_dos`/`anillo_tres`, reseñas 87-90) para no fabricar
datos falsos -- es de marzo 2026, fuera de la ventana de 60 días, así que
se ensanchó la ventana solo en el script de prueba (en runtime, sin tocar
el código fuente) para tener datos que persistir.

| Caso | Resultado |
|---|---|
| `GET .../alertas-resenas` sin filtros | `200`, los 2 anillos (`ciclo` 9-10-11, `reiterado` 9-10), con `cuentas` y `resenas` correctos |
| `GET .../alertas-resenas?tipo=ciclo` | `200`, `total_anillos: 1` |
| `GET .../alertas-resenas?tipo=no-existe` | `400` con los 3 tipos válidos |
| `GET .../18/detalle-grafo` | `200`, las 3 reseñas del ciclo con autor/vendedor/producto/fecha reales, ordenadas por fecha |
| `GET .../999999999/detalle-grafo` | `404` |
| `PATCH .../19 {"estado":"descartada"}` | `200`, el anillo pasa a `descartada` |
| `PATCH .../19` otra vez | `409` "El anillo ya no está pendiente de revisión" |
| `PATCH .../999999999 {"estado":"revisada"}` | `404` |
| `GET .../alertas-resenas?estado=pendiente&tipo=ciclo` (tras marcar) | `total_anillos: 0` -- el filtro ya no lo trae |
| Sin cookie de sesión | `401` |
| Sesión de `compradora.norte@mesh.com` (rol comprador) | `403` |

**2026-09-24, familia B**: `PatronesFraudeDetectorService` corrió de verdad
(worker con intervalo bajado solo para la prueba) contra el grafo real y
persistió el caso orgánico `reputacion_expres` (cuentas 14/16/17, el mismo
`prueba.admin.fraude@example.com` ya visto en el panel viejo). Detalle
completo en `plan pendiente/anillos-fraude-familia-b.md`.

| Caso | Resultado |
|---|---|
| `GET .../alertas-resenas?tipo=reputacion_expres` (sesión admin real) | `200`, el caso persistido, con las cuentas correctas |
| `GET .../alertas-resenas?tipo=no-existe` | `400` con los 9 tipos válidos (ya no solo 3) |

También se probó (por servicio directo, sin HTTP) que dos `registrarAnilloFraude`
concurrentes a la misma `clave` y que `detectar()`+`detectarInmediato()`
corriendo al mismo tiempo sobre el mismo anillo no duplican fila -- ver
`cambio_propuestas/2026-09-18_0015-anillos-fraude-persistencia.md`.

`npx tsc --noEmit` y `eslint` limpios sobre los ocho archivos nuevos/tocados
(`controllers/admin/admin-fraude-anillos.controller.ts`,
`services/fraude/fraude-anillos-persistidos.service.ts`,
`dto/paginar-anillos-fraude.ts`, `dto/marcar-anillo-fraude.ts`,
`models/anillo-fraude.ts`, `helpers/validaciones-anillo-fraude.ts`,
`app.module.ts`). Datos de prueba limpiados al final: `anillo_fraude`/
`anillo_fraude_resena` quedaron vacías, sin tocar `resena` ni el grafo.

---

# Hallazgos de fraude sobre eventos (F1-F6) -- alertas-eventos (2026-09-25)

Dos rutas, **controller y servicio aparte** de todo lo de arriba, mismo
criterio que `alertas-resenas`: `AdminFraudeEventosController` +
`HallazgosEventoFraudePersistidosService`
(`src/controllers/admin/admin-fraude-eventos.controller.ts` +
`src/services/fraude/hallazgos-evento-fraude-persistidos.service.ts`).
**Solo admin**. Nombradas `alertas-eventos` en el mismo patrón que
`alertas-login`/`alertas-resenas`: mismo sustantivo, distinto dominio
(eventos de ClickHouse -- vistas, carritos, compras, devoluciones,
registros -- en vez de login o grafo).

Estas rutas leen `hallazgo_evento_fraude`/`hallazgo_evento_fraude_cuenta`
(`elementos Generales/plan pendiente/hallazgos-evento-fraude.sql`), que
llena `HallazgosEventoFraudeDetectorService` -- un worker nuevo que corre
**una vez al día** (no cada 15 min como los demás workers de fraude: F2 y
F6 hacen un self-join sobre 30 días completos de datos, mucho más pesado
que un `GROUP BY`) las seis consultas de `clickhouse/consultas/F1..F6.sql`
sin tocarles una coma. Detalle completo del worker y su diseño en
`plan pendiente/hallazgos-evento-fraude.md`.

A diferencia de `alertas-resenas`, aquí **sí existe una tabla de pivote
real** para las cuentas (`hallazgo_evento_fraude_cuenta`, con `es_nucleo`)
en vez de derivarlas por `UNION` -- decisión explícita del usuario, al
notar que `docs/fraude-entrega3/02-reglas-backend.md` ya proponía ese
mismo patrón (`hallazgo_fraude_cuenta`) para su agrupador de casos, sin
construir. `es_nucleo` es siempre `true` por ahora: la distinción
núcleo/periferia solo tiene sentido al agrupar varios hallazgos en un caso,
que no está construido.

**Sin ruta de detalle** (a diferencia de `.../alertas-resenas/:id/detalle-grafo`):
toda la evidencia de un hallazgo de eventos ya vive en Postgres (`detalle`
jsonb + las cuentas del pivote), no hace falta consultar otra base para
ampliarla.

## GET /admin/fraude/alertas-eventos

```
GET /admin/fraude/alertas-eventos?pagina=1&limite=20&estado=pendiente&tipo=ip_multicuenta_compras
```

Paginación por número de página, mismas reglas que el resto del proyecto.
Dos filtros opcionales e independientes:

- `estado=pendiente|revisada|descartada` -- reusa el mismo catálogo y las
  mismas funciones de validación que `alertas-login`/`alertas-resenas`
  (`validarFiltroEstadoAlerta`), sin duplicar nada.
- `tipo=vistas_infladas|compras_en_rafaga|ip_multicuenta_compras|carrito_acaparador|devoluciones_seriales|granja_de_registros`
- sin alguno de los dos -- no se filtra por ese campo; sin ninguno, todos,
  ordenados por `fecha_actualizacion DESC`.

### 200

```json
{
  "ok": true,
  "mensaje": "Hallazgos obtenidos",
  "payload": {
    "hallazgos": [
      {
        "id_hallazgo_evento_fraude": "6",
        "tipo": "ip_multicuenta_compras",
        "clave": "10.0.0.5",
        "cuentas": [
          { "id_usuario": "3", "usuario": "comprador_sur", "es_nucleo": true },
          { "id_usuario": "4", "usuario": "ventas_norte", "es_nucleo": true }
        ],
        "id_producto_mongo": null,
        "detalle": { "cuentas_distintas": 2, "pedidos": 6 },
        "contador": 1,
        "ventana_inicio": "2026-09-26T00:29:30.202Z",
        "estado": "pendiente",
        "fecha_creacion": "2026-09-26T00:29:30.202Z",
        "fecha_actualizacion": "2026-09-26T00:29:30.202Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_hallazgos": 1,
    "total_paginas": 1
  }
}
```

`cuentas` sale de la tabla de pivote real (`hallazgo_evento_fraude_cuenta`
unida contra `usuarios`), no de un `UNION` derivado. `id_producto_mongo`
solo viene lleno en `vistas_infladas`/`carrito_acaparador` -- `null` en el
resto. `detalle` es evidencia libre por tipo (conteos, ventana, tasas) --
las cuentas NUNCA van ahí, ya están normalizadas en `cuentas`.

**Sin ninguna notificación a las cuentas del hallazgo** -- mismo criterio
que `alertas-resenas`: son las SOSPECHOSAS, no la víctima, avisarles daría
oportunidad de evadir la detección.

### 400

```json
{ "ok": false, "mensaje": "El estado debe ser uno de: pendiente, revisada, descartada", "payload": null }
{ "ok": false, "mensaje": "El tipo debe ser uno de: vistas_infladas, compras_en_rafaga, ip_multicuenta_compras, carrito_acaparador, devoluciones_seriales, granja_de_registros", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto del panel: sin sesión -> `401`; sesión
válida pero no admin -> `403`.

## PATCH /admin/fraude/alertas-eventos/:id

```
PATCH /admin/fraude/alertas-eventos/6
Content-Type: application/json

{ "estado": "revisada" }
```

Mismo criterio exacto que `PATCH /admin/fraude/alertas-resenas/:id`: solo
admite `revisada`/`descartada` como destino, y **solo desde `pendiente`** --
un hallazgo ya revisado o descartado no se puede volver a mover desde esta
ruta. Devuelve el hallazgo actualizado (misma forma que el listado).

### 409

```json
{ "ok": false, "mensaje": "El hallazgo ya no esta pendiente de revision", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un hallazgo con ese id", "payload": null }
```

## Pruebas -- hechas el 2026-09-25

Contra el servidor y la base real. Se sembró un hallazgo sintético de
`ip_multicuenta_compras` directo en Postgres (`hallazgo_evento_fraude` +
dos filas en `hallazgo_evento_fraude_cuenta`, cuentas reales `comprador_sur`/
`ventas_norte`) para probar el camino completo sin esperar al worker.

| Caso | Resultado |
|---|---|
| `GET .../alertas-eventos` sin datos | `200`, `payload.hallazgos: []` |
| `GET .../alertas-eventos` sin sesión | `401` |
| `GET .../alertas-eventos` con el hallazgo sembrado, sin filtro | `200`, el hallazgo con `cuentas` resueltas a nombre real |
| `GET .../alertas-eventos?tipo=ip_multicuenta_compras` | `200`, `total_hallazgos: 1` |
| `GET .../alertas-eventos?tipo=vistas_infladas` | `200`, `total_hallazgos: 0` (no aplica a este hallazgo) |
| `GET .../alertas-eventos?tipo=no_existe` | `400` con los 6 tipos válidos |
| `GET .../alertas-eventos?estado=revisada` (antes de marcar) | `total_hallazgos: 0` |
| `PATCH .../alertas-eventos/6` con `{ "estado": "revisada" }` | `200`, el hallazgo actualizado |
| `PATCH .../alertas-eventos/6` de nuevo | `409` |
| `PATCH .../alertas-eventos/999` (inexistente) | `404` |
| `PATCH .../alertas-eventos/6` con `{ "estado": "pendiente" }` | `400` (no es un destino válido) |
| `GET .../alertas-eventos?estado=revisada` (después de marcar) | `total_hallazgos: 1` -- el filtro ya refleja el cambio |
| Vendedor (`ventas_norte`) contra `GET .../alertas-eventos` | `403` |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Además, el worker completo (`HallazgosEventoFraudeDetectorService`) se
corrió a mano contra ClickHouse/Postgres reales, sembrando 5 compras
sintéticas en ráfaga -- ver `plan pendiente/hallazgos-evento-fraude.md`
para el detalle de esa prueba.

Teardown: el hallazgo sintético y sus dos filas de cuenta se borraron
(`ON DELETE CASCADE` desde `hallazgo_evento_fraude`); las dos tablas
quedaron vacías.

# El agrupador de casos de fraude -- alertas-eventos/alertas-login/alertas-resenas juntas (2026-09-26)

Tres rutas, **controller y servicio propios**, capa aparte de todo lo de
arriba: `AdminCasosFraudeController` + `CasosFraudeService`
(`src/controllers/admin/admin-casos-fraude.controller.ts` +
`src/services/fraude/casos-fraude.service.ts`). **Solo admin**. No
reemplaza ninguno de los tres paneles individuales (`alertas-resenas`,
`alertas-eventos`, `alertas-login`) -- los junta: agrupa por cuentas
compartidas los hallazgos de las fuentes que hoy no se hablan entre
sí (`anillo_fraude` del grafo, `hallazgo_evento_fraude` de ClickHouse,
`alerta_fraude` del login y, desde 2026-10-02, el texto de las reseñas en
Elasticsearch, `fuente: "elastic"`) en un solo "caso" con un puntaje y un nivel
combinados, para que el admin no tenga que revisar tres paneles sueltos y
armar la conexión a mano. Diseño completo, decisiones y la propuesta
original del compañero en
`elementos Generales/plan pendiente/agrupador-fraude.md`.

La agrupación (unión-búsqueda sobre cuentas compartidas), el puntaje y las
cinco reglas "casi confirmado" las arma
`AgrupadorFraudeWorkerService` (`@Interval` cada 15 minutos, recalcula
todo desde cero) -- estas tres rutas **solo leen y actualizan** lo que ese
worker ya dejó en `caso_fraude`/`evidencia_caso_fraude`/
`evidencia_caso_fraude_cuenta`, nunca agrupan ni califican por su cuenta.

## GET /admin/fraude/casos

```
GET /admin/fraude/casos?pagina=1&limite=20&nivel=prioritario&estado=pendiente
```

Paginación por número de página, mismas reglas que el resto del proyecto.
Dos filtros opcionales e independientes:

- `nivel=informativo|revisar|prioritario|casi_confirmado`
- `estado=pendiente|revisada|descartada|confirmada` -- el mismo catálogo
  de siempre, más `confirmada` (el único que habilita sanciones).
- sin alguno de los dos -- no se filtra por ese campo; sin ninguno, todos,
  ordenados por nivel (los más graves primero), luego puntaje, luego
  última evidencia.

### 200

```json
{
  "ok": true,
  "mensaje": "Casos de fraude obtenidos",
  "payload": {
    "casos": [
      {
        "id_caso_fraude": 13,
        "nivel": "prioritario",
        "puntaje": 54.24,
        "estado": "pendiente",
        "reglas_cumplidas": [],
        "cantidad_evidencias": 5,
        "cantidad_cuentas": 6,
        "ultima_evidencia": "2026-09-24T17:28:46.048Z",
        "fecha_creacion": "2026-09-27T00:12:58.901Z",
        "fecha_actualizacion": "2026-09-27T00:42:58.808Z"
      }
    ],
    "pagina": 1,
    "limite": 20,
    "total_casos": 1,
    "total_paginas": 1
  }
}
```

El resumen no trae cuentas ni evidencia -- eso solo en el detalle
(`GET .../casos/:id`), para no arrastrar la lista de identificadores de
`multi_cuenta_ip`/`multi_cuenta_ip_lenta` (puede traer decenas) en cada
fila del listado.

### 400

```json
{ "ok": false, "mensaje": "El nivel debe ser uno de: informativo, revisar, prioritario, casi_confirmado", "payload": null }
{ "ok": false, "mensaje": "El estado debe ser uno de: pendiente, revisada, descartada, confirmada", "payload": null }
```

### 401 / 403

Mismo comportamiento que el resto del panel: sin sesión -> `401`; sesión
válida pero no admin -> `403`.

## GET /admin/fraude/casos/:id

```
GET /admin/fraude/casos/13
```

### 200

```json
{
  "ok": true,
  "mensaje": "Caso de fraude obtenido",
  "payload": {
    "id_caso_fraude": 13,
    "nivel": "prioritario",
    "puntaje": 54.24,
    "estado": "pendiente",
    "reglas_cumplidas": [],
    "cantidad_evidencias": 5,
    "cantidad_cuentas": 6,
    "ultima_evidencia": "2026-09-24T17:28:46.048Z",
    "fecha_creacion": "2026-09-27T00:12:58.901Z",
    "fecha_actualizacion": "2026-09-27T00:42:58.808Z",
    "motivo": null,
    "cuentas": [
      { "usuario": "prueba_admin_fraude", "es_nucleo": true, "id_usuario": "14" },
      { "usuario": "prueba_comprador_fraude", "es_nucleo": false, "id_usuario": "13" }
    ],
    "evidencia": [
      {
        "id_evidencia_caso_fraude": 37,
        "fuente": "grafo",
        "tipo": "reputacion_expres",
        "clave": "14-16-17",
        "metricas": { "autor_minutos_vida": 54.35 },
        "puntos": 20,
        "ultima_evidencia": "2026-09-24T17:28:46.048+00:00"
      }
    ]
  }
}
```

`cuentas` -- **todas** las cuentas involucradas en algún hallazgo del caso,
resueltas contra `usuarios` (nunca el id crudo solo), con `es_nucleo` (en
2+ hallazgos del caso, o en uno "fuerte") para que el admin distinga el
centro del anillo de la periferia. `evidencia` -- cada hallazgo real,
resuelto contra su tabla de origen (exactamente una según `fuente`:
`grafo`=`anillo_fraude`, `eventos`=`hallazgo_evento_fraude`,
`login`=`alerta_fraude`; desde 2026-10-02 también `elastic`, las señales
`resenas_repetidas` que salen del texto de las reseñas -- ver
`plan pendiente/resenas-repetidas.md`), con `metricas` igual a la `detalle` jsonb de esa
fila (las cuentas de la evidencia individual **nunca** van en `metricas`,
ya están en `cuentas` a nivel de caso). `puntos` es el aporte de ESE
hallazgo al puntaje total del caso (`PuntajeFraudeService.puntosDeHallazgo`),
no el puntaje del caso completo.

### 404

```json
{ "ok": false, "mensaje": "No existe un caso con ese id", "payload": null }
```

### 400

```json
{ "ok": false, "mensaje": "El id no es valido", "payload": null }
```

## PATCH /admin/fraude/casos/:id

```
PATCH /admin/fraude/casos/13
Content-Type: application/json

{ "estado": "revisada", "motivo": "opcional para revisada/confirmada" }
```

Solo admite `revisada`/`descartada`/`confirmada` como destino (`pendiente`
es de donde se sale, nunca a donde se llega desde esta ruta), y **solo
desde `pendiente`** -- un caso ya revisado, descartado o confirmado no se
puede volver a mover desde esta ruta. `motivo` es obligatorio para
`descartada` (opcional para los otros dos). Al descartar, guarda la firma
de la evidencia de ese momento (`fuente:tipo:clave` por hallazgo,
ordenado) -- si más adelante llega evidencia nueva y la firma cambia, el
worker lo reabre solo como `pendiente` con una nota; si la firma es
idéntica, se queda descartado. Devuelve el caso actualizado (misma forma
que el detalle).

### 400

```json
{ "ok": false, "mensaje": "El estado debe ser uno de: revisada, descartada, confirmada", "payload": null }
{ "ok": false, "mensaje": "Descartar un caso exige un motivo", "payload": null }
```

### 409

```json
{ "ok": false, "mensaje": "El caso ya no esta pendiente de revision", "payload": null }
```

### 404

```json
{ "ok": false, "mensaje": "No existe un caso con ese id", "payload": null }
```

## Pruebas -- hechas el 2026-09-26/27

Contra el servidor (`npx nest start`) y la base real, sin sembrar nada: el
worker (`AgrupadorFraudeWorkerService`) ya había armado un caso real de
los datos existentes (el anillo `prueba_admin_fraude`/`multicuenta_test_*`
de pruebas anteriores de login + el hallazgo de `reputacion_expres` con
`autor_minutos_vida` real, ver la memoria del arreglo de `detalle`).

| Caso | Resultado |
|---|---|
| `GET .../casos` sin filtros | `200`, el caso real (`id 13`, `prioritario`, `puntaje 54.24`, `5` evidencias, `6` cuentas) |
| `GET .../casos?nivel=prioritario` | `200`, `total_casos: 1` |
| `GET .../casos?nivel=informativo` | `200`, `total_casos: 0` (no aplica a este caso) |
| `GET .../casos?nivel=no_existe` | `400` con los 4 niveles válidos |
| `GET .../casos?estado=no_existe` | `400` con los 4 estados válidos |
| `GET .../casos` sin sesión | `401` |
| `GET .../casos` con sesión de vendedor (`ventas_poniente`) | `403` |
| `GET .../casos/13` | `200`, cuentas resueltas a nombre real y evidencia de las tres fuentes (`reputacion_expres` del grafo con `metricas.autor_minutos_vida: 54.35`, tres `multi_cuenta_ip`/`multi_cuenta_ip_lenta` del login) |
| `GET .../casos/999999` (inexistente) | `404` |
| `GET .../casos/abc` (id no numérico) | `400` |
| `PATCH .../casos/13` con `{ "estado": "pendiente" }` | `400` (no es un destino válido) |
| `PATCH .../casos/13` con `{ "estado": "descartada" }` sin `motivo` | `400` |
| `PATCH .../casos/999999` | `404` |

### Pruebas -- hechas el 2026-10-02 (señales de texto, fuente `elastic`)

Contra el servidor y la base local, con sesión de admin real. Las dos señales
nuevas de reseñas (`resenas_repetidas` y `anillo_de_texto`, ver
`plan pendiente/resenas-repetidas.md` y `plan pendiente/anillo-de-texto.md`)
no tienen ruta propia: entran por las rutas de arriba, porque son de la
familia `patron_resenas`, y el agrupador las junta en casos como a cualquier
otra señal. Las cuentas de la segunda y tercera fila eran de prueba hechas a
propósito (cinco reseñas casi iguales; tres cuentas con una plantilla sobre el
mismo vendedor), ya borradas.

| Caso | Resultado |
|---|---|
| `GET .../alertas-resenas?tipo=resenas_repetidas` | `200`, 2 señales (las cuentas 3 y 7 del generador), `pendiente`, con su lista de reseñas |
| `GET .../alertas-resenas?tipo=anillo_de_texto` | `200`, lista vacía cuando no hay un anillo; con el anillo de prueba, 1 señal con `clave` `53-54-55` |
| `GET .../alertas-resenas?tipo=xxx` | `400`, el mensaje lista los dos tipos nuevos |
| `GET .../alertas-resenas/:id/detalle-grafo` de una señal `resenas_repetidas` | `200`, sus 5 reseñas |
| Agrupador con una cuenta de prueba con `resenas_repetidas` y nada más | caso propio: 15 puntos, nivel `informativo`, evidencia `fuente: "elastic"`, la cuenta como periferia (`es_nucleo: false`) |
| Agrupador con el anillo de prueba de tres cuentas | caso propio: 25 puntos, nivel `revisar`, evidencia `elastic` / `anillo_de_texto`, las tres cuentas como periferia |
| `GET .../casos/13` | las dos señales de las cuentas 3 y 7 se unieron al caso que ya existía (comparten cuentas con otras señales): evidencia `elastic:resenas_repetidas` x2 junto a `grafo`, `login`; puntaje 32,5 con tres motores (x1,6) |

`es_nucleo` sale `false` porque ninguna de las dos señales está en
`TIPOS_FUERTES`: una cuenta solo es núcleo si aparece en 2 o más hallazgos del
caso o en uno "fuerte". Se dejó así a propósito hasta ver cómo se comportan con
datos reales.
| `PATCH .../casos/13` con `{ "estado": "revisada", "motivo": "..." }` | `200`, el caso actualizado con `estado: "revisada"` |
| `PATCH .../casos/13` de nuevo | `409` |
| `npx tsc --noEmit` y `npx eslint` sobre los archivos tocados | limpios |

Teardown: el caso real `13` se devolvió a `pendiente` por SQL directo
(`UPDATE caso_fraude SET id_estado_alerta_fraude = ... WHERE id_caso_fraude = 13`,
`motivo`/`firma_al_descartar` a `NULL`) -- es un caso real armado por el
worker sobre datos de pruebas anteriores, no algo sembrado para esta
prueba, así que se dejó exactamente como estaba antes de probar el
`PATCH`.

### Pruebas -- hechas el 2026-10-04 (notas incoherentes)

Contra el servidor y la base local, con sesión de admin real. Las seis
situaciones salieron de 22 cuentas de prueba (`zz_nota_*`, 95 reseñas escritas a
propósito: 85 de 100 a 192 caracteres y 10 de 45, ya borradas junto con sus señales, el
caso y los nodos del grafo). El modelo valoró **todas** como se esperaba:
24 malas, 61 buenas.

| Situación de prueba | Resultado |
|---|---|
| Cuenta con 10 reseñas: 6 contradictorias (4 malas con 5★, 2 buenas con 1★) | `notas_incoherentes_cuenta`, 6 de 10 (60 %), 6 reseñas de evidencia; el vendedor de esas reseñas también: `notas_incoherentes_vendedor`, 6 de 10 |
| Cuenta con 35 reseñas, 5 contradictorias (14 %) | **sin señal** (llega a 5 pero no al 20 %), tampoco su vendedor |
| Producto con 10 reseñas de 10 cuentas distintas, 5 contradictorias (50 %) | `notas_incoherentes_producto` con `clave` `p50`, `senal_fraude_producto` = 50, sin cuentas; su vendedor (5 de 10) también |
| Producto con 20 reseñas (dos vendedores), 5 contradictorias (25 %) | **sin señal** (menos del 40 %); sus vendedores, con 3 y 2, tampoco |
| 10 reseñas de texto malo y bueno con 3 estrellas | **sin señal** (el 3 no cuenta) |
| 10 reseñas de texto malo con 5 estrellas pero de 45 caracteres | **sin señal**: quedan `corta`, no se valoran |
| `GET .../alertas-resenas?tipo=notas_incoherentes_cuenta` / `_producto` / `_vendedor` | `200`, 1 / 1 / 2 señales, `pendiente`; las de cuenta y vendedor con su cuenta, la de producto con `cuentas: []` |
| `GET .../alertas-resenas?tipo=xxx` | `400`, el mensaje lista los tres tipos nuevos |
| Agrupador (reinicio del backend) | la señal de cuenta formó un caso propio de **10 puntos**, nivel `informativo`; las de producto y vendedor **no están en ningún caso** |
| `npx tsc --noEmit` | limpio |

Las 97 reseñas locales originales son todas de menos de 100 caracteres: quedan
`corta` y no producen ninguna señal.

### Pruebas -- hechas el 2026-10-04 (reseñas parecidas)

Contra el servidor y la base local, con sesión de admin real. 28 cuentas de prueba
(`zz_par_*`) y 80 reseñas escritas a propósito, ya borradas junto con sus señales,
casos y nodos del grafo. Hay 30 textos distintos (coseno máximo 0,67 entre
sí) y 4 plantillas con pequeñas variaciones (coseno 0,97 o más entre sus copias
y 0,56 o menos contra los distintos), todos de 117 a 161 caracteres, más 8 copias
de 39 caracteres.

| Situación de prueba | Resultado |
|---|---|
| Cuenta con 12 reseñas: 6 copias de una plantilla y 6 distintas (50 %) | `resenas_repetidas`, 6 de 12, 6 reseñas de evidencia; caso propio de 15 puntos |
| Cuenta con 20 reseñas: 5 copias y 15 distintas (25 %) | **sin señal** (llega a 5 pero no al 30 %) |
| Cuenta con 8 copias de menos de 100 caracteres | **sin señal** (no se analizan) |
| Producto con 10 reseñas de 10 cuentas, 5 con gemela de otra cuenta (50 %) | `resenas_parecidas_producto` con `clave` `p41`, `senal_fraude_producto` = 41, sin cuentas |
| El vendedor de ese producto (10 reseñas, las mismas 5 con gemela, 50 %) | `resenas_parecidas_vendedor`, 5 de 10 |
| Producto con 20 reseñas, 5 con gemela (25 %) | **sin señal** (menos del 40 %) |
| Su vendedor, con 30 reseñas y las mismas 5 con gemela (16,7 %) | **sin señal** (menos del 20 %) |
| Las 5 cuentas de las copias sobre un vendedor | `anillo_de_texto` por cantidad de cuentas (sigue funcionando); los dos anillos de las mismas 5 cuentas comparten señal, con 10 reseñas de evidencia |
| `GET .../alertas-resenas?tipo=resenas_parecidas_vendedor` / `_producto` | `200`, 1 señal cada una, `pendiente`; la de producto con `cuentas: []` |
| Adaptador de casos | las dos señales `resenas_parecidas_*` **no** entran; `resenas_repetidas` y `anillo_de_texto` sí (casos de 15 y 25 puntos) |
| Notas incoherentes sobre las mismas cuentas | ninguna señal (no hubo 5 contradictorias) |
| `npx tsc --noEmit` y `npx eslint` sobre los archivos tocados | limpios |

Las 97 reseñas locales originales miden menos de 100 caracteres: no producen
señales de texto. Las señales viejas de `resenas_repetidas` de las cuentas 3 y 7
(del generador) siguen en la base; el detector no cierra señales.
