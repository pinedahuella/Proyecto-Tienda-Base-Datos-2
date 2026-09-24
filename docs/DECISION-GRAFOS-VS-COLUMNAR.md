# ADR-3 -- Grafos contra columnar, para los dos analisis de la Entrega 2

**Fecha:** 2026-09-03. **Estado:** decidido y ya implementado.
**Sigue la estructura de registro de decision que pide el enunciado**
(seccion 5.3): contexto, alternativas, decision, justificacion y consecuencias.
Y cierra con lo que el enunciado pide aparte y que se olvida: **bajo que
condiciones estaria justificada la alternativa que NO se eligio.**

Todo numero de este documento sale de una corrida contra la base viva el
2026-09-03. Los comandos estan escritos para que se puedan repetir.

---

## 1. Contexto

La Entrega 2 pone sobre la mesa **dos analisis distintos** y no dice que se
resuelvan igual. El propio enunciado lo advierte: *"estos requerimientos no
necesariamente ameritan la misma solucion tecnica"*.

| | Analisis A | Analisis B |
|---|---|---|
| Que pide | senalar cuentas que se califican entre si de forma reiterada | ver la actividad de ventas por intervalos y detectar demanda en ascenso |
| Familia que sugiere el enunciado | grafos | columnar |
| La pregunta, en una linea | **quien esta conectado con quien, y por que camino** | **cuanto se vendio de que, entre dos fechas** |

Son dos formas de acceso opuestas. La primera recorre relaciones de largo
variable y no sabe de antemano cuantos saltos hara. La segunda barre muchas
filas de una franja de tiempo y las agrega por una o dos columnas.

**Lo que hay hoy en Mesh, medido:**

```sql
SELECT count(*) FROM pedido;             --   32 pedidos
SELECT count(*) FROM pedido_producto;    --  127 lineas
SELECT count(*) FROM stock_movimiento;   -- 5655 movimientos de kardex
SELECT count(*) FROM resena;             --   90 resenas
SELECT count(*) FROM usuarios;           --   12 cuentas
```

Las ventas cubren cuatro meses de 2026:

```
 mes     | pedidos | unidades
 2026-01 |       2 |       19
 2026-03 |       7 |       59
 2026-04 |       2 |       20
 2026-08 |      21 |       53
```

Y el grafo de calificacion, que es el que importa para el analisis A, tiene
**14 aristas distintas** entre 12 cuentas:

```sql
SELECT count(*) FROM (SELECT DISTINCT id_usuario, id_usuario_vendedor
                        FROM resena WHERE id_usuario <> id_usuario_vendedor) t;
-- 14
```

**Esa es la primera conclusion, y hay que decirla antes que ninguna otra: a este
volumen ninguna de las dos familias hace falta por rendimiento.** Cualquier
afirmacion de que Cassandra o Neo4j "son mas rapidos aqui" seria inventada. La
decision se toma por otra cosa, y este documento dice por cual.

---

## 2. Alternativas consideradas

Se evaluaron **tres**, porque el enunciado exige que una de ellas sea "no
introducir cambios".

1. **Base de grafos (Neo4j)** para el analisis A.
2. **Base columnar (Cassandra)** para el analisis B.
3. **Quedarse en PostgreSQL** para los dos.

### 2.1 La tercera no es de adorno: se implemento y se midio

Antes de decidir se escribio el analisis A **entero en SQL**, para no comparar
contra una suposicion. Es un `WITH RECURSIVE` sobre `resena` que camina de
cuenta en cuenta hasta cerrar el circulo:

```sql
WITH RECURSIVE arista AS (
    SELECT DISTINCT id_usuario AS de, id_usuario_vendedor AS a
      FROM resena WHERE id_usuario <> id_usuario_vendedor),
camino AS (
    SELECT a.de AS inicio, a.a AS actual, 1 AS saltos,
           ARRAY[a.de, a.a] AS visitados
      FROM arista a
    UNION ALL
    SELECT c.inicio, a.a, c.saltos + 1, c.visitados || a.a
      FROM camino c JOIN arista a ON a.de = c.actual
     WHERE c.saltos < 4
       AND (a.a = c.inicio OR NOT (a.a = ANY (c.visitados))))
SELECT saltos AS cuentas_en_el_anillo, count(*) AS cuantos
  FROM camino
 WHERE actual = inicio AND saltos >= 2
   AND inicio = (SELECT min(v)
                   FROM unnest(visitados[1:array_length(visitados,1)-1]) AS v)
 GROUP BY saltos ORDER BY saltos;
```

Y el resultado es el que hay que mirar de frente:

| | Neo4j (`A1_anillo.cypher`) | PostgreSQL (`WITH RECURSIVE`) |
|---|---|---|
| Anillos encontrados | 1 de 2 cuentas, 1 de 3 | **exactamente los mismos** |
| Tiempo de ejecucion | instantaneo sobre 90 relaciones | **28.7 ms** (`EXPLAIN ANALYZE`) |
| Caminos explorados | -- | 23, y **no crece** al subir el tope de saltos de 3 a 10 |

**PostgreSQL resuelve hoy el analisis A, da el mismo resultado y tarda 28.7
milisegundos.** El tope de saltos ni siquiera importa: con 14 aristas no existen
caminos simples mas largos, asi que subir de 3 a 10 explora los mismos 23
caminos. A este tamano no hay diferencia de rendimiento que medir, y decir que
la hay seria mentir.

---

## 3. Decision

**Se implementa la base de grafos (Neo4j) para el analisis A. No se incorpora
una base columnar. El analisis B se queda en PostgreSQL.**

---

## 4. Justificacion

Si el rendimiento no decide, hay que decir que decide. Son tres criterios, y los
tres estan medidos sobre este sistema y no sacados de un manual.

### 4.1 La consulta de fraude es de largo variable, y eso en SQL se paga en correccion, no en tiempo

La pregunta del analisis A no es "cuantas resenas escribio Ana". Es **"hay un
camino que vuelva a su punto de partida, de longitud que no se sabe de
antemano"**. Un anillo puede ser de dos cuentas, de tres o de cuatro.

En Cypher eso es una sola linea, y el largo variable es parte del lenguaje:

```cypher
MATCH anillo = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
```

En SQL hace falta un `WITH RECURSIVE`, y con el llegan dos obligaciones que el
motor de grafos cumple solo. **La segunda ya nos mordio, y esta medida.**

**Obligacion 1: cortar la recursion a mano.** `WHERE c.saltos < 4`. Sin ese
tope, un ciclo en los datos hace que la consulta no termine nunca.

**Obligacion 2: impedir que un camino repita una cuenta.** Y aqui esta el
punto. Se corrio el MISMO SQL quitandole el array `visitados`:

```
CON la guardia          SIN la guardia
 2 cuentas | 1           2 cuentas | 2
 3 cuentas | 1           3 cuentas | 3
                         4 cuentas | 2
```

**Dos anillos reales se convierten en siete.** El de dos cuentas se cuenta dos
veces, el de tres se cuenta tres veces, y aparecen dos "anillos de cuatro
cuentas" que no existen: son el de dos, recorrido dos vueltas. Un panel de
fraude que reporte siete anillos donde hay dos **acusa a gente que no hizo
nada**, y no da ningun error.

Neo4j tampoco lo regala del todo -- un camino de largo variable garantiza que no
se repita una RELACION, pero no un NODO, y eso esta escrito en
`neo4j/consultas/A1_anillo.cypher` porque tambien costo un anillo inventado.
La diferencia es donde vive el problema: en Cypher es **una linea de filtro**
sobre nodos que el lenguaje ya te entrega; en SQL hay que arrastrar un array por
cada fila de la recursion, compararlo con `= ANY` en cada paso y acordarse de
recortarle el ultimo elemento al cerrar. Son cuatro sitios donde equivocarse en
vez de uno.

**El criterio, entonces, no es "cual corre mas rapido" sino "cual expresa la
pregunta".** La consulta de fraude no es una consulta que se escribe una vez: es
una que se va a retocar cada vez que aparezca un patron nuevo, y cada retoque
sobre el `WITH RECURSIVE` vuelve a poner en juego esas cuatro trampas.

### 4.2 El analisis B ya lo resuelve PostgreSQL, y la consulta no llega a 17 ms

El panel de tendencias es una agregacion por franja de tiempo. Hoy se escribe
asi, y esto es `EXPLAIN (ANALYZE, BUFFERS)` contra la base viva. Desde la
migracion 020 el ingreso lleva el descuento de la fila de historial; la medicion
de abajo es de antes, con `ph.precio` solo:

```sql
SELECT date_trunc('month', p.fecha_creacion) AS mes,
       pp.id_producto_mongo,
       sum(pp.cantidad) AS unidades,
       sum(pp.cantidad * ROUND(ph.precio * (1 - COALESCE(ph.porcentaje_descuento, 0) / 100), 2)) AS ingreso
  FROM pedido p
  JOIN pedido_producto pp ON pp.id_pedido = p.id_pedido
  JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
  JOIN estado_pedido ep ON ep.id_estado_pedido = p.id_estado_pedido
 WHERE ep.estado_pedido_nombre IN ('comprado','enviado','entregado')
 GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- Planning Time: 15.858 ms
-- Execution Time: 16.379 ms
```

**16 milisegundos, con indices que ya existen y sin una sola tabla nueva.** El
plan usa `Index Scan` sobre `idx_pedido_producto_pedido` y la clave primaria de
`precio_historial`; no hay ni un `Seq Scan` sobre las tablas grandes.

Meter Cassandra para esto significaria, hoy:

- una tabla nueva por cada forma de pregunta, porque en Cassandra el modelo se
  disena por consulta y no por entidad. "Ventas por mes y producto", "ventas por
  dia y vendedor" y "ventas por semana y categoria" son **tres tablas**, cada
  una con su clave de particion;
- un proceso que copie cada venta a esas tres tablas, o sea un cuarto ETL
  ademas de los dos que ya hay (`etl/cargar.js` a Mongo y `etl/cargar_grafo.sh`
  a Neo4j), con su propio desfase y su propia forma de quedarse viejo;
- renunciar a los `JOIN`. El precio de la linea vive en `precio_historial` y el
  estado del pedido en `estado_pedido`; en Cassandra habria que desnormalizar
  los dos dentro de cada fila de evento;
- y un octavo contenedor, con su memoria, en una maquina que ya corre siete.

Todo eso para bajar de 16 ms a un numero mas chico que nadie va a notar, sobre
32 pedidos.

### 4.3 El grafo aporta algo que no es velocidad: las senales se combinan solas

El analisis A no es una consulta, son cinco (`neo4j/consultas/A1..A5`), y la
quinta **combina las cuatro anteriores en un puntaje por par de cuentas**:
se califican mutuamente, sobre el mismo producto, solo con notas altas, y
comparten domicilio.

Esa ultima senal es la que decide el asunto. `:Direccion` es un nodo, y "dos
cuentas que viven en la misma casa" es simplemente **dos aristas `VIVE_EN` que
llegan al mismo nodo**. En el modelo relacional esa pregunta es un self-join de
`direcciones` por cuatro columnas de texto normalizadas a mano.

El grafo, medido hoy, es pequeno y cabe entero en la cabeza:

```
:Resena     90 nodos      ESCRIBIO    90
:Producto   51            CALIFICA_A  90
:Usuario    12            SOBRE       90
:Direccion   7            VIVE_EN      9
```

Y tiene una decision de modelado que lo sostiene: **`:Resena` es un NODO, no una
arista**, porque conecta TRES cosas (quien la escribe, a quien califica y sobre
que producto). Y **no existe `:Vendedor`**: en Mesh comprar no pide rol, asi que
partir la cuenta en dos etiquetas dejaria a la misma persona como dos nodos y
**el anillo no cerraria nunca**. Las dos estan escritas en `neo4j/README.md`.

### 4.4 Y el criterio que el enunciado pone por encima de los demas

El enunciado dice que *"el criterio determinante es la calidad del analisis, no
la cantidad de tecnologias incorporadas"*. Incorporar Cassandra para un panel
que PostgreSQL sirve en 16 ms seria justo lo contrario: sumar una tecnologia
para tener una tecnologia mas.

---

## 5. Consecuencias

### Lo que se gana

- La consulta de varios saltos se escribe una vez y se lee de un vistazo.
- Cinco senales de fraude y un puntaje compuesto, con el panel
  (`GET /admin/fraude/anillos` + `PanelFraude.svelte`) funcionando de punta a
  punta.
- Un componente menos que operar, respaldar y explicar.

### Lo que se asume, y no se disimula

**1. El grafo se queda viejo.** No hay CDC: una resena nueva no llega a Neo4j
hasta que alguien corre el ETL, y el panel de fraude **no avisa de que esta
mirando datos de ayer**. Esta escrito entero en `docs/PENDIENTE-OUTBOX.md` y es
el pendiente 4. La salida propuesta es un outbox transaccional, que ademas es la
respuesta al documento de consistencia de la Entrega 3.

**2. El ETL del grafo relee todo cada vez.** 90 resenas, 14 segundos medidos. No
duele hoy; duele el dia que sean cien mil.

**3. El panel de tendencias no esta implementado.** Se decidio que se queda en
PostgreSQL, y eso significa que hay que escribirlo en PostgreSQL. Lo que existe
hoy son los dos reportes agregados de `GET /admin/reportes/*`, que **no** son un
analisis por intervalos. La consulta de la seccion 4.2 es el punto de partida y
no cuesta mas que una ruta.

**4. Dos motores para preguntar por lo mismo.** Las resenas viven en PostgreSQL
(fuente de verdad) y en Neo4j (copia para analizar). Cualquier divergencia entre
las dos es invisible hasta que alguien las cuente. Lo mas barato que arregla eso
son cuatro `count` de conciliacion, y esta anotado como lo primero que se puede
hacer del pendiente 4.

---

## 6. Cuando SI habria que incorporar la base columnar

Esto es lo que el enunciado pide para la alternativa no elegida, y es la parte
que se olvida. **No se descarta Cassandra: se aplaza, y con condiciones
concretas y medibles.**

La decision se revisa cuando se cumpla **cualquiera** de estas cinco, y cada una
lleva como comprobarla contra este mismo sistema.

### 6.1 Cuando la consulta de tendencias pase de un segundo

El disparador no es el numero de filas, es el tiempo. Hoy son 16 ms sobre 127
lineas de pedido. Se vuelve a medir con el `EXPLAIN` de la seccion 4.2, y el
umbral es que **`Execution Time` pase de 1000 ms** con los indices ya puestos y
sin `Seq Scan` evitable. En ese punto PostgreSQL esta leyendo por fila lo que un
motor columnar leeria por columna, y la diferencia deja de ser teorica.

### 6.2 Cuando el volumen de eventos crezca dos ordenes de magnitud

La referencia de hoy:

```
   127 lineas de pedido en 8 meses      =   ~16 al mes
  5655 movimientos de kardex en 9 meses =  ~630 al mes
```

Un motor columnar empieza a pagar cuando la tabla de eventos ronda las decenas
de millones de filas y las consultas tocan pocas columnas de muchas filas.
**Para Mesh eso son unas 100 000 lineas de pedido**, o sea del orden de mil
veces lo que hay. Con el ritmo actual no se llega, y por eso la condicion se
escribe como umbral y no como fecha.

### 6.3 Cuando haya que retener series largas que nadie consulta enteras

Si el panel pasa a pedir "las mismas ventas, pero de los ultimos cinco anos, por
dia", la tabla se vuelve un historico que se consulta siempre por franjas
recientes. Ese es exactamente el patron para el que Cassandra particiona por
tiempo y descarta particiones enteras sin leerlas. Hoy el historico de Mesh son
ocho meses y cabe en memoria.

### 6.4 Cuando la escritura de eventos sea el cuello de botella

Cassandra gana escribiendo, no leyendo. La condicion es que las escrituras de
`stock_movimiento` y `pedido_producto` empiecen a competir con las transacciones
de compra sobre las mismas paginas. Se comprueba mirando `pg_stat_database` y
las esperas de bloqueo. Hoy no pasa: la compra entera es una transaccion sobre
una fila de `oferta` con `FOR UPDATE`, y la Entrega 1 midio **cero sobreventas
sobre 555 ofertas**.

### 6.5 Cuando haya mas de un nodo, y se necesite que siga en pie si cae uno

Cassandra es una base distribuida, sin nodo maestro, con replicacion ajustable.
Nada de eso sirve en una sola maquina, que es donde corre Mesh hoy: los siete
contenedores estan en el mismo Docker. **Meter una base distribuida en un solo
nodo es quedarse con todos sus costes y ninguna de sus ventajas.** El dia que el
proyecto tenga mas de una maquina, esta condicion cambia sola.

### Lo que NO es una razon para incorporarla

- Que el enunciado la mencione. La menciona "segun decision del equipo", y lo
  dice con esas palabras.
- Que quede bien en el informe. El propio enunciado evalua igual mantener algo
  en relacional si el analisis lo sostiene.
- Que ya este el `docker-compose` medio escrito. Levantar un contenedor es lo
  barato; mantener un cuarto ETL y tres tablas desnormalizadas es lo caro.

---

## 7. Como repetir estas mediciones

```bash
export MSYS_NO_PATHCONV=1

# los volumenes de la seccion 1
docker exec -i mesh-postgres psql -U <DB_USER> -d <DB_NAME> -c \
  "SELECT count(*) FROM pedido_producto;"

# la consulta de tendencias con su plan (seccion 4.2)
docker exec -i mesh-postgres psql -U <DB_USER> -d <DB_NAME> -c \
  "EXPLAIN (ANALYZE, BUFFERS) SELECT date_trunc('month', p.fecha_creacion), ..."

# el grafo y sus cinco consultas
bash neo4j/correr_fraude.sh
```

El `WITH RECURSIVE` de la seccion 2.1 y su version sin guardia estan escritos
enteros aqui arriba: se pegan en `psql` y se comparan las dos salidas. Son la
unica forma de comprobar por cuenta propia que este documento no invento la
diferencia entre 2 anillos y 7.
