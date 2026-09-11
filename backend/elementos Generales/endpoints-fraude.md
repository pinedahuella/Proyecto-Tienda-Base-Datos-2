# Endpoints del panel de fraude

Tres rutas de admin, todas de **solo lectura**. Las dos primeras sobre el
grafo de **Neo4j**; la tercera sobre **PostgreSQL**, sin tocar el grafo:

- **`GET /admin/fraude/anillos`** — el **panel de manipulación de reseñas**
  de la Entrega 2 (Bloque 4 de `BACKEND-PENDIENTE.md`): los grupos de
  cuentas cuyo patrón de calificaciones no se explica por el uso normal de
  la tienda.
- **`GET /admin/grafo/conciliacion`** — la **red de seguridad** de la
  sincronización del grafo: compara los conteos de PostgreSQL (la verdad)
  contra Neo4j (la proyección) y avisa de la deriva. Ver la sección al
  final.
- **`GET /admin/fraude/alertas-login`** — las **alertas de fraude de
  login** (fuerza bruta contra una cuenta o una IP, multi-cuenta desde una
  misma IP) que detecta el propio backend con contadores de Redis, en el
  camino del login mismo — no consulta ningún log retrospectivo. Ver la
  sección dedicada, después de "anillos".

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

Las alertas de fraude de **login** — fuerza bruta y multi-cuenta —, que
detecta `FraudeLoginService` con **contadores de Redis en el propio camino
del login**, sin esperar a ningún worker ni consultar Elasticsearch. Punto
4 de `plan pendiente/fraude-login-eventos.md`; el esquema de referencia es
`plan pendiente/fraude-login-eventos.sql`.

> **Estado (2026-09-10): implementada y PROBADA en vivo.** Ver "Pruebas" al
> final de esta sección.

Código: `src/controllers/fraude/fraude.controller.ts` (mismo controlador
que `anillos`, ruta hermana) + `src/services/fraude-login/fraude-login.service.ts`.
**Solo admin** (`SesionGuard` + `@Roles(ID_ROL_ADMIN)`, en la clase) — no la
tienda, mismo criterio que el resto del panel.

## De dónde salen las alertas

**Esto NO es un log de cada intento** — eso ya vive en la colección
`eventos_autenticacion` de MongoDB (ver
`cambio_propuestas/2026-09-10_0906-eventos-autenticacion-mongo.md`). Una
fila de `alerta_fraude` es "esto merece que un admin lo mire": nace cuando
un contador de Redis, revisado en cada intento de login (éxito o fallo),
cruza su umbral.

**Por decisión explícita del usuario (2026-09-10): el sistema SOLO
alerta, nunca frena el login.** Ningún umbral bloquea ni retrasa una
cuenta o una IP — cruzarlo únicamente deja la fila para revisión humana.

Tres señales, las únicas que no requieren geolocalización (punto 2 del
plan, todavía sin decidir) ni una consulta retrospectiva contra
Elasticsearch:

| `tipo_alerta` | Qué mide | Ventana | Umbral |
|---|---|---|---|
| `fuerza_bruta_ip` | Fallos de login desde una misma IP | 60 s | 8 |
| `fuerza_bruta_cuenta` | Fallos de login contra un mismo identificador | 60 s | 5 |
| `multi_cuenta_ip` | Identificadores **distintos** probados desde una misma IP (credential stuffing) | 300 s | 4 |

Cada contador es de **ventana fija**: `INCR`/`SADD` en Redis y después
`EXPIRE ... NX` — el TTL se pone una sola vez, al crear la clave, y no se
reinicia con cada intento nuevo (Redis 7+, ya en `redis:8-alpine` del
compose).

**Deduplicación:** la llave de conflicto de `alerta_fraude` es
`(tipo, clave, ventana_inicio)`, con `ventana_inicio` truncado al minuto.
Varios cruces del umbral dentro del mismo minuto **suman `contador`** en
una sola fila (no duplican); si el ataque sigue al minuto siguiente, nace
una fila nueva a propósito — una alerta ya revisada no se reabre sola.

## Qué llena cada columna

- **`clave`** — el origen de la señal: la IP (`fuerza_bruta_ip`,
  `multi_cuenta_ip`) o el identificador intentado (`fuerza_bruta_cuenta`).
- **`cuenta_involucrada`** — solo en `fuerza_bruta_cuenta`, y solo si el
  identificador corresponde a una cuenta real (`credenciales_invalidas` /
  `cuenta_inactiva`); `null` en los otros dos tipos y cuando la cuenta no
  existe (`usuario_inexistente`).
- **`detalle`** — evidencia por tipo: conteos, la ventana en segundos, y
  (solo en `multi_cuenta_ip`) hasta 20 identificadores vistos.
- **`estado`** — `pendiente` al nacer. El admin la marca `revisada` o
  `descartada` desde una pantalla aparte (esta ruta es de solo lectura; no
  hay `PATCH` todavía — ver "Lo que no se hizo").

## GET /admin/fraude/alertas-login

```
GET /admin/fraude/alertas-login?pagina=1&limite=20&estado=pendiente
```

Paginación por número de página (`validarLimite`/`validarPagina` de
`helpers/validaciones-productos.ts`, mismas reglas y mensajes que el resto
del proyecto). Un único filtro opcional:

- `estado=pendiente|revisada|descartada` → solo esas.
- sin el parámetro → todas, sin filtrar, más recientes primero
  (`fecha_actualizacion DESC`).

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
```

### 401 / 403

Mismo comportamiento que `anillos`: sin sesión → `401`; sesión válida pero
no admin (comprador, vendedor, o la tienda) → `403`.

### 503

```json
{ "ok": false, "mensaje": "No se pudo conectar con PostgreSQL", "payload": null }
```

## Pruebas — hechas el 2026-09-10

Contra el servidor y las bases reales (`mesh-postgres`, `mesh-redis`),
`npm run start:dev`. Scripts en el scratchpad, no en el repo.

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
"mesh:fraude:*" | xargs DEL` (5 claves). `npx tsc --noEmit` limpio sobre
todos los archivos tocados.

## Lo que no se hizo en esta versión (y por qué)

- **`PATCH` para marcar una alerta revisada/descartada.** El plan
  (`fraude-login-eventos.md` punto 5) lo menciona, pero no se pidió en esta
  ronda — se deja para cuando el frontend tenga la pantalla de triage.
- **Geolocalización de IP (país, ASN) y las señales que dependen de ella**
  (viaje imposible, IP/ASN nueva tras fallos) — punto 2 del plan, decisión
  pendiente entre una base offline (GeoLite2) y una API externa.
- **El worker retrospectivo sobre Elasticsearch** (punto 3/5 del plan):
  patrones que una ventana de Redis de 1-5 minutos no puede ver (abuso
  lento repartido en horas). `EventosAutenticacionSyncService` ya alimenta
  el índice; falta la consulta y el worker que la corra.
- **Bloqueo o frenado automático.** Decisión explícita del usuario: por
  ahora el sistema solo alerta, nunca actúa sobre el login.

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
