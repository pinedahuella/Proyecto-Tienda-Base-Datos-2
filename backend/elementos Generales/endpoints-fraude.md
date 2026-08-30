# Endpoint del panel de fraude

El **panel de manipulación de reseñas** de la Entrega 2 (Bloque 4 de
`BACKEND-PENDIENTE.md`). Una sola ruta, de **solo lectura**, que recorre el
grafo de **Neo4j** y devuelve los grupos de cuentas cuyo patrón de
calificaciones no se explica por el uso normal de la tienda.

> **Estado (2026-08-30): ruta implementada y PROBADA en vivo.** Contra
> `mesh-neo4j` cargado (150 nodos): autorización 401/403/403/403/200,
> `anillos: []` con el grafo real, y los 4 grupos correctos con un anillo
> sembrado (`neo4j/consultas/siembra.cypher`). Neo4j caído → 503 en 0.3 s.
> Ver "Pruebas".

Código: `src/controllers/fraude/fraude.controller.ts` +
`src/services/fraude/fraude.service.ts`. Cliente Neo4j:
`src/database/neo4j.ts` (helper `consultarGrafo`, sesión en modo **READ** —
el backend **nunca** le escribe al grafo). Pantalla que la consume:
`frontend/src/lib/PanelFraude.svelte`.

---

## De dónde salen los datos

El grafo **no es una fuente de verdad**: es una **proyección** de la tabla
`resena` de PostgreSQL, que carga el ETL `etl/cargar_grafo.sh` (lo lleva el
compañero, está fuera de `backend/`). Modelo:

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
    "analizado": { "cuentas": 10, "resenas": 86, "relaciones": 272 }
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

### Limpieza

Borrada la siembra (`MATCH (n:Prueba) DETACH DELETE n`), el grafo vuelve a
150 nodos y la ruta a `anillos: []`. Nada quedó tocado en PostgreSQL (la
siembra vive solo en Neo4j).
