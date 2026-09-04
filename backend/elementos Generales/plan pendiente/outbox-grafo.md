# Plan pendiente — Outbox para mantener el grafo Neo4j al día

> **Estado (2026-09-04). Las cinco piezas del backend quedaron HECHAS —
> cierra la parte de Entrega 2 de este outbox.**
>
> HECHO:
> - Tabla `evento_grafo` + trigger sobre `resena` — `outbox-grafo.sql`
>   (este folder), aplicado en local.
> - **Conciliación** — `GET /admin/grafo/conciliacion`.
>   `cambio_propuestas/2026-09-03_2359-conciliacion-grafo.md`.
> - **El worker** — `@Interval` en `GrafoSyncService`, probado a fondo en
>   vivo. `cambio_propuestas/2026-09-04_0030-worker-outbox-grafo.md`.
> - **`sincronizacion` en `GET /admin/fraude/anillos`** —
>   `GrafoSyncService.estadoSincronizacion()`, un envoltorio de
>   `estadoCola()` que nunca lanza (degrada a `null` si Postgres falla o
>   `evento_grafo` no existe). Probado en vivo (pendientes, apartados, tabla
>   ausente, Neo4j caído). Ver `endpoints-fraude.md`.
>
> FALTA (fuera de `backend/`, le toca al compañero):
> - La migración real `015` + el cambio del ETL (`etl/cargar_grafo.sh`
>   etapa A).

## De dónde viene esto

El compañero (José David) deja de mantener el grafo al día: de ahora en
adelante es responsabilidad de este equipo que una reseña nueva llegue a
Neo4j. El traspaso es de esa responsabilidad funcional, **no de
territorio** — seguimos tocando solo `backend/`, con el workflow de SQL de
referencia de siempre (plan + `.sql` de referencia aplicado en local; la
migración real la escribe el compañero).

El diseño de fondo ya estaba escrito en `docs/PENDIENTE-OUTBOX.md`. Este
`.md` es la versión acotada a lo que vamos a construir, con las decisiones
ya cerradas.

## El problema

Hoy el grafo se llena corriendo `etl/cargar_grafo.sh` a mano (o desde
`arrancar.ps1`). Dos costuras:

1. **El grafo se queda viejo y no lo dice.** Una reseña publicada después de
   la última corrida no está en Neo4j. El panel de fraude
   (`GET /admin/fraude/anillos`) la ignora sin ninguna señal: enseña un
   análisis correcto sobre datos incompletos, que es peor que fallar.
2. **El ETL relee TODO cada vez.** Es idempotente (`MERGE`) pero no
   incremental: con ~90 reseñas tarda ~14 s, y ese número crece con el
   catálogo aunque no haya cambiado nada.

## La directiva del profesor, y cómo la cumple este diseño

El profesor pidió tres cosas para esta sincronización:

| Lo que pidió | Cómo lo cumple el outbox |
|---|---|
| "No debe bloquear nada" | El `POST /resenas` commitea en PostgreSQL y responde. Nunca le habla a Neo4j en el camino de la petición. Si Neo4j está caído, la reseña se guarda igual. |
| "Envío asíncrono" | El grafo se actualiza en un worker aparte, segundos después. |
| "Un job que lo reconcilie de ser necesario" | Un endpoint de admin que compara PostgreSQL contra Neo4j (4 `count`) y avisa de la deriva. Es la red de seguridad. |

Esto es, literalmente, **"aceptación documentada de una ventana de
consistencia eventual"** — uno de los tres mecanismos válidos del documento
de estrategia de consistencia de la **Entrega 3 (5 pts de puro texto)**. No
da puntos en la Entrega 2 (el panel de fraude ya cumple el criterio de los
3 pts con lo que tenga cargado), así que **no hay reloj encima**: se hace
bien.

Por qué el outbox transaccional completo y no una versión "best-effort"
(el backend hace `LPUSH` a Redis tras commitear, sin `await`): el
best-effort tiene un hueco — si el proceso se cae entre el `COMMIT` y el
`LPUSH`, esa reseña no se encola y nadie se entera. El outbox no tiene ese
hueco porque el evento se escribe **en la misma transacción** que la
reseña. Además el outbox es exactamente el entregable de la Entrega 3, con
código corriendo detrás en vez de un texto que describe algo que no
existe.

---

## Pieza 1 — la tabla `evento_grafo` (HECHA en local)

Una **tabla normal de PostgreSQL** (no de Neo4j; es una cola de
pendientes). Forma exacta en `outbox-grafo.sql`:

```
evento_grafo
  id_evento     bigserial PK   -- el orden de este número ES el orden de aplicación
  id_resena     bigint         -- la reseña que cambió (SIN FK)
  fecha         timestamptz    -- cuándo se encoló
  procesado_en  timestamptz    -- NULL = pendiente; con fecha = ya está en Neo4j
  intentos      integer        -- para apartar un evento que falla siempre
  ultimo_error  text
```

Decisiones:

- **`id_evento` serial, y ese orden es el de aplicación.** No se usa `fecha`
  para ordenar: dos eventos en el mismo milisegundo quedarían sin desempate.
- **Solo el `id_resena`, no una copia de la reseña.** El worker relee de
  PostgreSQL, así siempre aplica el estado ACTUAL. Si una reseña cambió tres
  veces antes de que el worker llegara, se aplica la última versión y las
  otras dos no hacen falta.
- **`id_resena` SIN llave foránea a `resena`.** Si la hubiera, el trigger
  `AFTER DELETE` intentaría insertar una fila que apunta a un `id_resena`
  recién borrado → violación de FK → el `DELETE` quedaría bloqueado. Mismo
  trato que `oferta.id_producto_mongo` y `pedido_producto.id_producto_mongo`.
- **Índice parcial `WHERE procesado_en IS NULL`.** Lo procesado se acumula
  para siempre y la cola no lo mira nunca; el índice solo cubre lo
  pendiente.

### Por qué NO hay columnas `entidad` ni `operacion`

`docs/PENDIENTE-OUTBOX.md` proponía `entidad varchar(30)` ("'resena' por
ahora") y `operacion varchar(10)` (`'alta'`/`'baja'`). Las dos se quitaron:

- **`entidad` era especulativa.** La tabla se llama `evento_grafo` y hoy —y
  para todo el alcance del curso— son eventos de reseña. El trigger siempre
  escribiría `'resena'`. Lo demás del grafo (nombre de usuario, direcciones,
  nombre de producto) cambia poquísimo y lo agarra el `--limpiar` periódico
  o la conciliación; y cuando el worker proyecta una reseña ya hace `MERGE`
  del estado actual de sus 2 usuarios + producto + direcciones. Si algún día
  hiciera falta, es una migración chica y su forma sería distinta.
- **`operacion` no aportaba información que la base no tenga ya.** El worker,
  al procesar el evento de la reseña N, hace `SELECT ... FROM resena WHERE
  id_resena = N` (el JOIN de reconstrucción). Devuelve fila → la reseña
  existe → `MERGE` (alta/upsert). Devuelve 0 filas → ya no está → `DETACH
  DELETE` del nodo (baja). El worker **infiere** alta/baja del estado
  actual, que es el mismo principio que "guardar solo el id y releer".
  Guardar `operacion` congelaba un pedacito de "qué pasó" que contradice
  eso, y encima ya era redundante con "la fila existe". Quitarlo cuesta cero
  (ese `SELECT` es el mismo que el worker ya hace) y es más robusto: un
  `operacion` viejo nunca puede engañar al worker. Y de paso no queda
  ninguna columna enum-ish que discutir si va normalizada en tabla catálogo.

**Esto hay que decírselo a José** para que la migración `015` real siga esta
forma y no la de `PENDIENTE-OUTBOX.md`.

## Pieza 2 — el trigger sobre `resena` (HECHO en local)

```
AFTER INSERT OR UPDATE OR DELETE ON resena  FOR EACH ROW
  -> INSERT INTO evento_grafo (id_resena) VALUES (<id_resena>)
```

- **Los tres eventos encolan lo mismo: el `id_resena`.** El worker decide
  alta vs baja mirando si la reseña todavía existe cuando procesa el evento
  (ver Pieza 1).
- **Se ramifica por `TG_OP`** para leer `OLD.id_resena` en el `DELETE` y
  `NEW.id_resena` en el resto — en un `DELETE` la fila `NEW` no está
  asignada. Misma trampa que el trigger de `likes` de la 011.
- **Por qué `UPDATE` aunque hoy nada actualice una reseña:**
  `resenas.controller.ts` solo tiene crear reseña, responder, votar, quitar
  voto y 3 GET — no hay ruta para editar ni borrar una reseña. Se incluye
  `UPDATE` igual porque cuesta cero (encola el mismo `id_resena`) y cubre
  gratis un futuro "editar calificación".
- **Por qué NO hay trigger sobre `comentario`** (donde viven el texto y la
  fecha de la reseña): en el alta, `POST /resenas` inserta el `comentario`
  raíz en la misma transacción **antes** que la `resena`, así que cuando el
  trigger de `resena` dispara el comentario ya existe y el worker lo lee
  bien. Un trigger en `comentario` solo haría falta si apareciera una ruta
  para editar el texto de una reseña ya publicada. Si aparece, se agrega
  entonces. Los cambios hechos a mano en la base por fuera de la API los
  cubre la conciliación (Pieza 4).

---

## Pieza 3 — el worker (HECHO, 2026-09-04)

Una tarea programada de **NestJS** (`@nestjs/schedule` v12, `@Interval('grafo-outbox', 10000)`
en `GrafoSyncService.vaciarCola`). **NO** un script suelto en `etl/`: como
tarea de Nest tiene el mismo ciclo de vida que la API (si el server está
arriba, el worker está arriba), lo que resuelve la objeción de
`docs/PENDIENTE-OUTBOX.md` sobre "un proceso de fondo frágil que no vuelve
tras reiniciar".

Cada corrida procesa los eventos **de a uno, en su propia transacción
corta**:

```
por evento (hasta vaciar la cola o llegar a 500):
  BEGIN
    SELECT id_evento, id_resena FROM evento_grafo
    WHERE procesado_en IS NULL AND intentos < 5
    ORDER BY id_evento LIMIT 1
    FOR UPDATE SKIP LOCKED
    -- (cola vacía -> ROLLBACK, fin de la corrida)

    SELECT ... FROM resena WHERE id_resena = <id>   (el JOIN de reconstrucción)
      devuelve fila   -> ejecutarGrafo(CYPHER_PROYECTAR_RESENA)   (alta / upsert)
      devuelve 0 filas -> ejecutarGrafo('MATCH (r:Resena {id}) DETACH DELETE r')  (baja)

    UPDATE evento_grafo SET procesado_en = now() WHERE id_evento = <id>
  COMMIT

  -- si falla:
  --   fallo de CONEXIÓN (Neo4j/PostgreSQL caídos)  -> ROLLBACK, se corta la corrida
  --                                                    SIN gastar intento; se reintenta luego
  --   fallo de DATOS (Cypher/parámetro inválido)    -> ROLLBACK, luego en otra tx:
  --                                                    intentos+1, ultimo_error; sigue con la cola
```

**Transacción por evento, no por lote:** el `FOR UPDATE SKIP LOCKED`
mantiene el candado sólo mientras se aplica ESE evento a Neo4j (~decenas de
ms), no todos. La cola normalmente está casi vacía; no hace falta lotear.

**Distinguir "conexión" de "datos" es la clave** (`esFalloDeConexionGrafo`):
un `Neo.ClientError.Statement.*` es culpa del evento y gasta intento; un
`ServiceUnavailable` / `08*` de Postgres / `42P01` es transitorio y **no**
gasta intento — si no, una caída de Neo4j de 1 minuto envenenaría toda la
cola a `intentos = 5`. Probado en vivo (ver el `cambio_propuestas`).

**Sin colapsar eventos de la misma reseña:** si hay 3 eventos para la
reseña 5, se procesan los 3 (`MERGE` no-op los redundantes). Se probó que
no genera duplicados; colapsar era una optimización opcional y se descartó
por simplicidad.

`INTERVALO_MS`, `MAX_POR_CORRIDA` (500), `MAX_INTENTOS` (5), `PODA_CADA`
(360 corridas ≈ 1 h), `RETENCION_DIAS` (7) son constantes de la clase. Un
flag `procesando` hace que una corrida que tarde más que el intervalo no se
pise con la siguiente.

### Las trampas (de `PENDIENTE-OUTBOX.md`, siguen aplicando)

1. **Es "al menos una vez", nunca "exactamente una vez".** El worker puede
   escribir en Neo4j y caerse antes del `UPDATE`; al volver lo aplica otra
   vez. Por eso **toda escritura al grafo es `MERGE`, nunca `CREATE`** — y
   ya lo es en todo `extraer_grafo.sql`.
2. **Dos workers a la vez se pisan** (el `@Interval` y alguien corriendo el
   ETL). Lo resuelve `FOR UPDATE SKIP LOCKED`: cada uno toma eventos
   distintos. **Este `FOR UPDATE` no contradice la Entrega 2** — lo que ahí
   se prohíbe es usar bloqueos para la venta de inventario limitado bajo
   concurrencia de usuarios; esto es un trabajo de fondo repartiéndose una
   cola. (Pregunta típica de la presentación.)
3. **Un evento envenenado tapa la cola.** Si un evento falla siempre y la
   cola se procesa en orden, bloquea todo lo que viene detrás. Por eso el
   `WHERE intentos < 5`: a los 5 intentos el evento se salta y algo tiene
   que mirar los apartados (los devuelve la conciliación).
4. **La tabla crece para siempre.** Poda, en la misma tarea o en otra:
   `DELETE FROM evento_grafo WHERE procesado_en IS NOT NULL AND procesado_en < now() - interval '7 dias'`.
   El `procesado_en IS NOT NULL` no es opcional: sin él una poda por fecha
   se lleva los pendientes viejos, justo los que más falta hacen.
5. **El día que se enciende, lo viejo no tiene eventos.** Ver "Semilla"
   abajo — es decisión del compañero.

### La unidad incremental — qué aplica el worker por cada reseña

Aplicar una reseña `N` al grafo no es solo crear el nodo `:Resena`: hay que
asegurar que existan sus dos participantes y sus direcciones, porque un
comprador recién registrado que escribe su primera reseña **todavía no
tiene nodo `:Usuario`**. Es "re-correr el ETL del grafo pero acotado a una
reseña". En orden (los nodos antes que las relaciones):

```
-- 1. autor y vendedor como :Usuario (MERGE por id, props de `usuarios`)
-- 2. sus :Direccion + [:VIVE_EN]  (clave normalizada, igual que extraer_grafo.sql seccion 3-4)
-- 3. el :Producto  (MERGE por id; nombre de `productos` LEFT JOIN, o el relleno
--    "Producto <id> (solo en MongoDB)")
-- 4. MERGE (:Resena {id}) SET calificacion, fecha (de comentario.fecha_publicacion), texto
--    MERGE (autor)-[:ESCRIBIO]->(r)
--    MERGE (r)-[:CALIFICA_A]->(vendedor)
--    MERGE (r)-[:SOBRE]->(producto)
```

Si el `SELECT` a `resena` no devuelve nada (la reseña se borró), es una
baja: `MATCH (r:Resena {id}) DETACH DELETE r`. Los nodos de
usuario/producto/dirección se dejan (pueden estar en otros caminos); la
conciliación no cuenta nodos huérfanos como error.

**La normalización de la clave de dirección** (`translate` de las 14 letras
acentuadas, minúsculas, espacios colapsados) quedó **copiada verbatim** de
`pg_temp.clave_direccion` de `etl/extraer_grafo.sql` dentro de la consulta
del worker (`SQL_DIRECCIONES`, en `grafo-sync.service.ts`), no
reimplementada en TypeScript. Verificado: produce la misma clave que el ETL
en las 2 direcciones del conjunto de datos. **Si esa función del ETL
cambia, hay que cambiar `SQL_DIRECCIONES` a la par** (comentado en el
código).

**Los ids van con `neo4j.int()`, obligatorio.** Se comprobó en vivo: un
`number` de JS crudo se guarda como `Float` y `MERGE (:Usuario {id: 3.0})`
crea un nodo duplicado que ninguna consulta encuentra. Todos los params de
id/calificación pasan por `neo4j.int(...)`. Las fechas salen de PostgreSQL
con `to_char(... AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')` (no
como `Date` de JS, que perdería los microsegundos) para que `datetime()` de
Cypher las tome igual que el ETL.

**Qué NO sincroniza el worker** (sale del alcance incremental, lo cubre el
`--limpiar` periódico): usuarios y direcciones que no participan de ninguna
reseña. El ETL completo carga TODOS los usuarios; el worker sólo toca los 2
de cada reseña. Por eso la conciliación no cuenta `:Usuario`/`:Producto`
para su veredicto.

## Pieza 4 — la conciliación (BACKEND, nuestro, HECHA)

Un endpoint de solo lectura para admin (no la tienda), p. ej.
`GET /admin/grafo/conciliacion`. Cuatro `count` que comparan:

```
resenas en PostgreSQL        == nodos :Resena en Neo4j
usuarios con reseña           == nodos :Usuario  (al menos)
productos con reseña          == nodos :Producto
relaciones ESCRIBIO/CALIFICA_A/SOBRE == 3 x nº de reseñas
```

Si no cuadra, lo dice y sugiere `etl/cargar_grafo.sh --limpiar`. **No
repara: avisa.** Es lo más barato de todo el diseño, sirve solo (aunque no
exista el worker), y es literalmente el "job que reconcilie" que pidió el
profesor. Devuelve también los eventos apartados (`intentos >= 5`).

## Pieza 5 — "última sincronización" en el panel de fraude (BACKEND, nuestro, HECHA)

`GET /admin/fraude/anillos` devuelve `sincronizacion: { ultima_sincronizacion,
pendientes, apartados } | null` — `GrafoSyncService.estadoSincronizacion()`,
un envoltorio de `estadoCola()` (la misma consulta que usa la conciliación)
con dos diferencias a propósito: **nunca lanza** (Postgres caído o
`evento_grafo` ausente devuelven `null`, no tumban el resto de la
respuesta) y usa un límite de tiempo más corto (3 s, aparte del de 15 s del
análisis del grafo) porque es un dato auxiliar de otra ruta. Antes de esto,
si el grafo estaba viejo, el panel enseñaba un análisis incompleto sin
ninguna señal. Probado en vivo el 2026-09-04 (pendientes, apartados, tabla
ausente, Neo4j caído) — ver `endpoints-fraude.md`.

---

## Qué le toca al compañero (fuera de `backend/`)

1. **La migración real** — la tabla `evento_grafo` + el trigger sobre
   `resena`, como `migrations/015_outbox_grafo.sql` (las migraciones van
   hasta la 014). Tal cual el `outbox-grafo.sql` de este folder, integrado
   en el orden y en `migrations/README.md`. **Sigue este `.sql`, no el
   esquema de `docs/PENDIENTE-OUTBOX.md`:** ese traía columnas `entidad` y
   `operacion` que se quitaron a propósito (ver "Por qué no hay columnas
   `entidad` ni `operacion`" arriba).
2. **`etl/cargar_grafo.sh` — etapa A:** que en vez de releer todo, vacíe la
   cola (aplique solo los `evento_grafo` pendientes). Sigue corriéndose a
   mano y desde `arrancar.ps1` igual que hoy. Se gana que el ETL deje de
   crecer con el catálogo sin agregar ningún proceso vivo.
3. **La semilla — decidir ANTES de que el trigger quede en la migración
   real y `arrancar.ps1` la corra:**
   - Opción A: `etl/cargar_grafo.sh --limpiar` una vez al arrancar, y de ahí
     en adelante la cola. Simple, y funciona porque el grafo es una
     proyección.
   - Opción B: sembrar la cola —
     `INSERT INTO evento_grafo (id_resena) SELECT id_resena FROM resena;`
   El problema a evitar: con el trigger puesto, `generador.js` / la semilla
   van a generar ~90 eventos cada vez que se cargue la base.
4. **`docs/base-de-datos.md`** — la tabla nueva, si el equipo documenta el
   esquema ahí.

## Orden de trabajo (backend) — las cuatro HECHAS

1. **La conciliación** (Pieza 4). Barata, útil sola, y hace visible el
   problema que el worker resuelve.
2. **El worker** (Pieza 3) — el `@Interval`, la unidad incremental, las
   cinco trampas.
3. **"Última sincronización"** en el panel (Pieza 5).
4. Documentado en `endpoints-fraude.md` y en `cambio_propuestas/`.

## Pruebas a hacer (contra la base real, con teardown)

- Insertar una reseña → aparece 1 fila pendiente en `evento_grafo` en la
  misma transacción; con `ROLLBACK` no queda ninguna.
- Correr el worker → el nodo `:Resena` + sus 3 relaciones aparecen en Neo4j;
  correrlo dos veces deja los mismos conteos (idempotencia).
- Reseña de un **comprador nuevo** (sin nodo `:Usuario` previo) → se crean
  su `:Usuario`, sus `:Direccion` y `[:VIVE_EN]`.
- Reseña sobre un **producto que solo vive en Mongo** → nodo `:Producto` con
  el nombre de relleno, no se pierde la reseña.
- Neo4j caído → el `POST /resenas` sigue dando 201; el evento queda
  pendiente y se aplica cuando Neo4j vuelve.
- Evento envenenado (un `id_resena` cuyo autor/vendedor/producto no se puede
  resolver en Neo4j) → a los 5 intentos se aparta, la cola sigue avanzando,
  la conciliación lo reporta.
- La conciliación detecta una discrepancia sembrada a mano (borrar un nodo
  `:Resena` en Neo4j y ver que el endpoint lo dice).

## Lo que queda fuera

- **Reconciliación que REPARE sola** (no solo avise). El profesor dijo "de
  ser necesario"; por ahora avisa y quien mira corre `--limpiar`.
- **Cola para Mongo** (los campos calculados de `productos`). Es otro
  problema — `ProductosService.recalcularCamposCalculados` ya lo hace
  síncrono y es plano respecto al tamaño del catálogo. Encaja como Entrega
  3 si acaso.
- **Escrituras en vivo a Neo4j desde otras entidades** (usuarios,
  direcciones, productos sin reseña). El grafo solo necesita lo que toca una
  reseña; el resto entra por la unidad incremental cuando hace falta.
