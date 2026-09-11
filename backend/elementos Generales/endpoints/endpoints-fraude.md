# Endpoints del panel de fraude

Cinco rutas de admin. Las dos primeras sobre el grafo de **Neo4j**; las
otras tres sobre **PostgreSQL, Redis y Elasticsearch**, sin tocar el grafo
— y ese segundo grupo (fraude por IP/cuenta en el login) es **solo
Elasticsearch + Redis**, no toca Neo4j:

- **`GET /admin/fraude/anillos`** — el **panel de manipulación de reseñas**
  de la Entrega 2 (Bloque 4 de `BACKEND-PENDIENTE.md`): los grupos de
  cuentas cuyo patrón de calificaciones no se explica por el uso normal de
  la tienda.
- **`GET /admin/grafo/conciliacion`** — la **red de seguridad** de la
  sincronización del grafo: compara los conteos de PostgreSQL (la verdad)
  contra Neo4j (la proyección) y avisa de la deriva. Ver la sección al
  final.
- **`GET /admin/fraude/alertas-login`** — las **alertas de fraude de
  login**: nueve señales, guardadas todas en PostgreSQL — cuatro inmediatas
  con contadores de Redis en el camino del login (fuerza bruta, multi-cuenta,
  rotación de IP) y cinco consultadas contra Elasticsearch (toma de cuenta,
  viaje imposible, y tres patrones lentos/repartidos que una ventana de
  Redis de minutos no puede ver). Ver la sección dedicada, después de
  "anillos".
- **`GET /admin/fraude/eventos-login`** — el **explorador manual** de los
  logs crudos de autenticación, contra Elasticsearch directamente (no
  contra Mongo, que es el origen pero no el que se consulta). Filtros
  exactos por tipo, resultado, motivo, cuenta, IP, huella de cliente, país y
  rango de fechas.
- **`PATCH /admin/fraude/alertas-login/:id`** — marcar una alerta (de
  cualquiera de las 9 señales) como `revisada` o `descartada`. Solo desde
  `pendiente`. Es la única ruta de **escritura** de todo este panel.

> **Estado (2026-08-30, sincronización agregada 2026-09-04): ruta
> implementada y PROBADA en vivo.** Contra `mesh-neo4j` cargado (150 nodos):
> autorización 401/403/403/403/200, `anillos: []` con el grafo real, y los 4
> grupos correctos con un anillo sembrado
> (`neo4j/consultas/siembra.cypher`). Neo4j caído → 503 en 0.3 s. Desde
> 2026-09-04 la respuesta también trae `sincronizacion` (qué tan al día está
> el grafo respecto a PostgreSQL) — ver "Pruebas".

Código: `src/controllers/fraude/fraude.controller.ts` +
`src/services/fraude/fraude.service.ts`. Cliente Neo4j:
`src/database/neo4j.ts` (helpers `consultarGrafo` en modo **READ** para el
panel, y `ejecutarGrafo` en modo **WRITE** para el worker del outbox — ver
abajo). Pantalla que la consume: `frontend/src/lib/PanelFraude.svelte`.

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

Si el grafo está vacío (`GET /grafo` devuelve `nodos: 0`), esta ruta
responde `200` con `anillos: []` y `analizado` en ceros — no falla, pero no
sirve de nada hasta que se corra el ETL.

---

## GET /admin/fraude/anillos

**Solo admin** (`SesionGuard` + `@Roles(ID_ROL_ADMIN)`, ambos en la clase
del controlador). **No la tienda**: la tienda es un vendedor más, y
enseñarle quién la está calificando de forma sospechosa le entrega justo la
lista que no debería ver. Sin cuerpo, sin query params.

```
GET /admin/fraude/anillos
```

### Qué hace por dentro

Corre **cuatro consultas Cypher en paralelo** (adaptadas de
`neo4j/consultas/A1..A4`, que están escritas para el visor de línea de
comandos y no se pueden ejecutar tal cual desde el driver). La lógica de
detección es la misma; el `RETURN` arma ya la forma del payload.

| Consulta | Qué busca | `tipo` que produce |
|---|---|---|
| **A.1** grupos cíclicos | Camino cerrado `ESCRIBIO`/`CALIFICA_A` de 4 a 8 saltos. Ancla cada anillo en su cuenta de menor id (no lo cuenta una vez por rotación) y exige cuentas distintas | 2 cuentas → `mutuo`; 3+ → `ciclo` |
| **A.2** par sobre mismo producto | Dos cuentas que se califican en **los dos sentidos** sobre el **mismo producto** (la frase literal del enunciado) | `reiterado` |
| **A.4** misma dirección | Cuentas distintas en un nodo `:Direccion` **con calle**. Adjunta las reseñas que esas cuentas se escribieron entre sí, si las hay | `direccion` |
| **conteo** | `count` de `:Usuario`, `:Resena` y todas las relaciones | (llena `analizado`) |

**Deduplicación:** el mismo par puede llegar por A.1 y por A.2 (o por varias
rotaciones del mismo ciclo). Se juntan por la clave "ids ordenados": la
evidencia se acumula y `reiterado` **tapa** a `mutuo` (misma pareja, señal
más fuerte). Un grupo `direccion` **siempre** es su propia entrada, aunque
toque a las mismas cuentas: es un hallazgo distinto.

**`senales`** — frases redactadas por el backend a partir de lo que
devuelve el grafo, sin volver a consultarlo:

- ciclo / mutuo / reiterado: el camino cerrado, todas las notas 5★ (o ≥4★),
  la ventana de tiempo entre la primera y la última reseña (si es ≤ 72 h), y
  si todas las cuentas se crearon el mismo día (`fecha_alta` del nodo).
- direccion: la dirección compartida, mismo día de alta, y si además se
  califican entre sí.

**Orden:** más señales primero; a igualdad, más reseñas.

### 200

```json
{
  "ok": true,
  "mensaje": "Analisis completado",
  "payload": {
    "anillos": [
      {
        "id": "ciclo-11-12-13",
        "tipo": "ciclo",
        "saltos": 6,
        "cuentas": [
          {
            "id_usuario": 11,
            "usuario": "ventas_altiplano",
            "correo_electronico": "ventas.altiplano@mesh.com",
            "nombre": "Rodrigo",
            "apellido": "Similox"
          }
        ],
        "productos": [
          { "id_producto": 12, "nombre": "Laptop Ambar Campus 14" }
        ],
        "resenas": [
          {
            "id_resena": 901,
            "autor": "ventas_altiplano",
            "vendedor": "ventas_bocacosta",
            "producto": "Laptop Ambar Campus 14",
            "calificacion": 5,
            "fecha": "2026-07-01T09:00:00Z"
          }
        ],
        "senales": [
          "La calificacion forma un circulo cerrado entre 3 cuentas: ventas_altiplano -> ventas_bocacosta -> ventas_izabal -> ventas_altiplano",
          "Las 3 calificaciones son de 5 estrellas",
          "Las 3 resenas se escribieron en un intervalo de 40 minutos"
        ]
      }
    ],
    "analizado": { "cuentas": 10, "resenas": 86, "relaciones": 272 },
    "sincronizacion": {
      "ultima_sincronizacion": "2026-09-04T06:21:57.459Z",
      "pendientes": 0,
      "apartados": 0
    }
  }
}
```

**Contra los datos sembrados de hoy `anillos` es `[]`** — y eso es lo
**correcto**: no hay anillos reales (0 pares mutuos, 0 autocalificaciones,
verificado en PostgreSQL). El frontend, ante `[]` + `analizado`, dice
"se recorrieron N cuentas, M reseñas… sin encontrar nada", que es un
resultado, no un error. Para ver la ruta devolver anillos hay que sembrar
uno con `neo4j/correr_fraude.sh` (lo del compañero).

- `cuentas[].nombre` / `apellido` salen como `""` si el nodo no los trae.
- `resenas[].fecha` es lo que devuelve `toString(datetime)` del grafo (ISO
  8601, normalmente con `Z`). El frontend hace `new Date(...)`.
- `productos` se deduce de `resenas` (los productos distintos que aparecen).
- **`sincronizacion`** — que tan al día está el grafo respecto a
  PostgreSQL, para que el panel no enseñe un análisis sobre datos
  incompletos sin decirlo (mismos números que `cola` y
  `ultima_sincronizacion` de `GET /admin/grafo/conciliacion`, calculados con
  la misma consulta a `evento_grafo`):
  - `ultima_sincronizacion`: `max(procesado_en)` del outbox, o `null` si
    nada se ha procesado todavía.
  - `pendientes`: eventos sin aplicar (`procesado_en IS NULL`,
    `intentos < 5`).
  - `apartados`: eventos que fallaron 5 veces y no se reintentan más.
  - **`sincronizacion` completo puede salir `null`** — si PostgreSQL no
    respondió a tiempo (3 s) o si `evento_grafo` todavía no existe (falta la
    migración `015`). Es un dato auxiliar: cuando falla, el resto de la
    respuesta (`anillos`, `analizado`) sigue igual, no se cae el endpoint.
    Ver `GrafoSyncService.estadoSincronizacion()`.

### 401

```json
{ "ok": false, "mensaje": "No hay sesion activa", "payload": null }
{ "ok": false, "mensaje": "Token invalido o expirado", "payload": null }
```

### 403

```json
{ "ok": false, "mensaje": "No tienes permiso para hacer esto", "payload": null }
```

Sesión válida pero no es admin (un comprador, un vendedor, o **la tienda**).

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con Neo4j", "payload": null }
```

Neo4j no responde, o el análisis no terminó en 15 s.

### 500

```json
{ "ok": false, "mensaje": "No se pudo completar el analisis de fraude", "payload": null }
```

Cualquier otra cosa (por ejemplo un error de sintaxis de Cypher —
`Neo.ClientError.Statement.*` — que sería un bug del backend, no una caída
de la base).

---

## Lo que NO se hizo en esta versión (y por qué)

- **A.3 (ráfagas) y A.5 (puntaje compuesto) como consultas propias.** El
  contrato del frontend solo define cuatro `tipo` (`ciclo`, `mutuo`,
  `reiterado`, `direccion`), así que A.3 no tiene dónde encajar como
  "anillo". Su señal —"muchas notas en pocos días"— se cubre desde el
  backend con la ventana de 72 h calculada sobre las reseñas del grupo.
  A.5 (el ranking por número de señales) se replica con el `sort` final.
  Si el equipo quiere las consultas Cypher A.3/A.5 exactas, es un cambio
  acotado en `fraude.service.ts`.
- **El cruce "ninguna de estas cuentas compró el producto que calificó".**
  Es, según `neo4j/README.md`, la señal de fraude más fuerte, pero vive en
  PostgreSQL (`pedido` / `pedido_producto`), no en el grafo. Añadirla es
  una consulta a Postgres con los `id_resena` encontrados. Se dejó fuera a
  propósito para no acoplar este servicio a Postgres en la primera versión
  — **conviene discutirlo**, porque el enunciado la menciona.
- **`analizado.relaciones`** cuenta **todas** las relaciones del grafo
  (`ESCRIBIO` + `CALIFICA_A` + `SOBRE` + `VIVE_EN`). Si se prefiere contar
  solo las de reseña (× 3 por reseña), es un cambio de una línea en
  `CYPHER_CONTEO`.

---

## Lo que le toca al compañero (fuera de `backend/`)

Nada de esquema. Solo asegurarse de que **el grafo esté cargado** antes de
la demo:

1. `./etl/cargar_grafo.sh` (desde Git Bash) — carga el grafo desde
   PostgreSQL. `GET /grafo` tiene que dejar de decir `nodos: 0`.
2. Para la presentación, como los datos reales no tienen anillo:
   `bash neo4j/correr_fraude.sh` siembra un anillo de mentira (cuentas con
   id negativo, etiqueta `:Prueba`), y lo borra al final. Con él sembrado,
   `GET /admin/fraude/anillos` debería devolver esos grupos.

El backend **no** dispara el ETL ni reconstruye el grafo: es un script de
shell que se corre a mano, y el grafo es de solo lectura para el backend.

---

## Pruebas — hechas el 2026-08-30

Contra los contenedores reales (`mesh-postgres`, `mesh-neo4j` con el grafo
cargado, 150 nodos), backend en `npm run start:dev`. Scripts en el
scratchpad, no en el repo.

### Autorización

| Sesión | Resultado |
|---|---|
| Sin sesión | `401` "No hay sesion activa" |
| `comprador_sur` (rol comprador) | `403` |
| `mesh_tienda` (la tienda, rol vendedor) | `403` |
| `ventas_norte` (rol vendedor) | `403` |
| `admin_mesh` (rol admin) | `200` |

### Grafo real, sin sembrar

`200`, `anillos: []`, `analizado: { cuentas: 8, resenas: 86, relaciones: 260 }`.
Es el resultado **correcto**: los datos sembrados no tienen anillo.

### Con un anillo de mentira sembrado (`neo4j/consultas/siembra.cypher`)

Devuelve **4 grupos**, ninguno repite cuenta:

| `tipo` | cuentas | `saltos` | reseñas | señales clave |
|---|---|---|---|---|
| `direccion` | anillo_a..d (4) | 2 | 8 | misma dirección con calle; además se califican entre sí; todas 5★ |
| `reiterado` | doble_a, doble_b | 4 | 4 | 2 productos en común; ráfaga de 30 min; todas 5★ |
| `ciclo` | anillo_a/b/c | 6 | 3 | círculo cerrado `anillo_c → anillo_a → anillo_b → anillo_c`; 40 min; todas 5★ |
| `reiterado` | anillo_a, anillo_b | 4 | 2 | mismo producto; 1 hora; todas 5★ |

Verificado: el par `anillo_a`↔`anillo_b` sale **una sola vez** como
`reiterado` (no además como `mutuo`); `analizado` sube a
`{ 14, 98, 300 }` con la siembra puesta.

### Neo4j caído

`docker stop mesh-neo4j` → la ruta responde `503` "No se pudo conectar con
Neo4j" en **0.3 s**, no se cuelga.

### `sincronizacion` — probado el 2026-09-04

Contra la cola `evento_grafo` real (misma consulta que usa la conciliación).

| Caso | `sincronizacion` |
|---|---|
| Cola al día (sin pendientes ni apartados) | igual a `ultima_sincronizacion`/`cola` de `GET /admin/grafo/conciliacion` en el mismo instante |
| Evento insertado a mano, leído antes de que el worker lo aplique (10 s) | `pendientes: 1` |
| El mismo evento, tras el siguiente tick del worker | `pendientes: 0`, `ultima_sincronizacion` avanza a la hora del tick |
| Evento con `intentos = 5` (simulando uno apartado) | `apartados: 1`; el worker nunca lo toca (`WHERE intentos < 5`) |
| Tabla `evento_grafo` renombrada (simulando la migración `015` sin aplicar) | `sincronizacion: null`; `anillos` y `analizado` siguen presentes, la ruta sigue en `200` |
| Neo4j caído (con la cola normal) | sigue en `503` antes de llegar a leer `sincronizacion` — mismo comportamiento que antes de este cambio |

`npx tsc --noEmit` y `eslint` limpios sobre los cuatro archivos tocados
(`models/grafo.ts`, `models/fraude.ts`, `services/grafo/grafo-sync.service.ts`,
`services/fraude/fraude.service.ts`).

### Limpieza

Borrada la siembra (`MATCH (n:Prueba) DETACH DELETE n`), el grafo vuelve a
150 nodos y la ruta a `anillos: []`. Nada quedó tocado en PostgreSQL (la
siembra vive solo en Neo4j).

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
- **`cuenta_involucrada`** — cuando el identificador corresponde a una
  cuenta real: siempre en `toma_cuenta` y `viaje_imposible`; en
  `fuerza_bruta_cuenta`, `fuerza_bruta_cuenta_lenta`, `ip_rotacion_cuenta` e
  `ip_rotacion_cuenta_lenta` solo si existe; `null` en las señales cuyo
  origen es una IP (`fuerza_bruta_ip`, `multi_cuenta_ip`,
  `multi_cuenta_ip_lenta`).
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
        "cuenta_involucrada": { "id_usuario": "5", "usuario": "admin_mesh" },
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
    "cuenta_involucrada": null,
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
de operación de todo el sistema, mismo criterio que `/admin/fraude/anillos`.

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
