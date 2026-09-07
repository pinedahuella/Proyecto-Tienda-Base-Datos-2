# ClickHouse -- la base columnar de los eventos

La SEXTA base de Mesh. Guarda lo que pasa en el portal, no lo que el portal es.

Levantada y medida el **2026-09-06**.

---

## Por que existe

El sistema hoy solo guarda **el final de la historia**, que es la compra. Todo
lo que pasa antes -- quien miro que producto, desde donde entro, cuantas veces
volvio -- no se guarda en ninguna parte.

Y ahi es donde vive lo que el profesor pidio, que son dos cosas a la vez:

```
tendencia   que producto se esta calentando ANTES de venderse
fraude      que cuentas se comportan como no se comporta una persona
```

Las dos preguntas se hacen sobre lo mismo: eventos con hora.

## Por que ClickHouse y no Cassandra

El enunciado pone a Cassandra como opcion de referencia y a ScyllaDB como su
equivalente. Se eligio ClickHouse, y el 5.2 lo permite ("alternativas
equivalentes") mientras el 5.5 dice que lo que se califica es la calidad del
analisis.

El motivo es uno solo y es fuerte:

> Con Cassandra hay que saber la pregunta ANTES de guardar el dato. Con
> ClickHouse se guarda el evento una vez y se pregunta lo que sea despues.

Cassandra es wide-column: guarda agrupado por clave de particion y esta hecha
para leer por clave conocida. No sabe hacer `GROUP BY` entre particiones ni
ordenar fuera de la particion. Cada pregunta nueva es **una tabla nueva mas
recargar todo el historico**.

Detectar fraude es, por definicion, encontrar lo que no sabias que estabas
buscando. Cassandra es el peor motor posible para eso.

Y hay un detalle que conviene saber contar: ClickHouse es columnar en el sentido
estricto, guarda **por columna**. Cassandra es wide-column, que lleva la palabra
pero sigue guardando filas juntas.

**Esto no contradice el ADR-3, lo continua.** Aquel documento rechazo la
columnar con dos argumentos medidos: 32 pedidos y una consulta de tendencias de
16 ms. Con clics de por medio esos dos numeros dejan de ser ciertos, que es
exactamente la condicion 6.2 que el propio ADR dejo escrita. Y una de las
razones que dio contra Cassandra -- "tres tablas, cada una con su clave de
particion" -- es justo la que ClickHouse borra.

---

## Como se levanta

Sube sola con el resto:

```powershell
.\arrancar.ps1
```

Y su esquema se aplica en cada arranque, porque es idempotente.

| | Donde |
|---|---|
| Consola web | **http://localhost:8123/play** |
| HTTP, el driver de Node | `localhost:8123` |
| Protocolo nativo, `clickhouse-client` | `localhost:9010` |
| Base | `mesh_eventos` |
| Usuario y contrasena | del `.env`, `CLICKHOUSE_USER` y `CLICKHOUSE_PASSWORD` |

No lleva contenedor de visor al lado como PostgreSQL, MongoDB y Redis. La
consola viene dentro de la imagen, en `/play`.

Desde la terminal:

```bash
docker exec -it mesh-clickhouse clickhouse-client \
  --user TU_USUARIO --password TU_CLAVE --database mesh_eventos
```

---

## Las tablas

Todo esta en `001_esquema.sql`, con el porque de cada decision al lado.

| Tabla | Que guarda | Su pregunta |
|---|---|---|
| `vista_producto` | el clic en la ficha | que le paso a ESTE producto en el tiempo |
| `evento_login` | copia de `log_login` | cuantas cuentas salen de esta misma IP |
| `evento_registro` | copia de `log_registro` | cuantas cuentas nacieron desde esta IP |
| `vistas_por_producto_dia` | el resumen por dia | se mantiene solo, no hay ETL |

**`vista_producto` es la unica que NACE aqui.** Las otras dos son copias.

### La columna `lote`, que separa lo medido de lo inventado

Las cuatro tablas la llevan. Vale `real` o `generado-<semilla>`.

Existe porque **hoy casi todas las vistas estan generadas**: el portal todavia no
manda ninguna. Una tabla de eventos donde no se distingue lo medido de lo inventado
no se puede ensenar a nadie, y en un panel de fraude es peor todavia, porque acusa
a cuentas de la semilla por un patron que dibujo un script.

Es el mismo marcador que ya usan los otros dos generadores del proyecto, la `L` de
`migrations/lote` y la `M` de `mongo/lote`.

**Y sube hasta el resumen**, que es la parte que se olvida. `vistas_por_producto_dia`
lo lleva en su `ORDER BY`; sin eso, lo real y lo generado quedarian sumados en la
misma celda y aguas abajo ya no habria forma de separarlos.

---

## Las consultas que sostienen el panel

Las tres corren contra la base viva. Se pegan tal cual en
**http://localhost:8123/play**.

### Productos en ascenso

Lee del resumen y no de la tabla cruda, por eso tarda milisegundos. Los contadores
de un `AggregatingMergeTree` se leen con `countMerge` y `uniqMerge`, que es lo que
sorprende a quien nunca ha tocado uno: en la tabla no hay numeros, hay estados
parciales que hay que fusionar al leer.

```sql
SELECT id_producto,
       countMergeIf(vistas, dia >  today() - 7) AS ahora,
       countMergeIf(vistas, dia <= today() - 7) AS antes,
       uniqMergeIf(sesiones, dia > today() - 7) AS personas,
       round(ahora / greatest(antes, 1), 2)     AS veces
FROM vistas_por_producto_dia
WHERE lote = 'real'
GROUP BY id_producto
ORDER BY veces DESC
LIMIT 20;
```

### El producto que estan inflando

```sql
SELECT id_producto, count() AS vistas, uniq(sesion) AS personas,
       round(count() / uniq(sesion), 1) AS vistas_por_persona
FROM vista_producto
GROUP BY id_producto
HAVING personas >= 3
ORDER BY vistas_por_persona DESC
LIMIT 20;
```

Un producto con 500 vistas de 3 sesiones no esta de moda, lo estan inflando. El
`HAVING` esta para que una sola visita suelta no encabece la lista con un cociente
de 1 sobre 1.

### Cuentas que comparten IP

```sql
SELECT ip, uniq(id_usuario) AS cuentas, count() AS entradas,
       min(fecha) AS primera, max(fecha) AS ultima
FROM evento_login
WHERE fecha > now() - INTERVAL 30 DAY
GROUP BY ip
HAVING cuentas > 1
ORDER BY cuentas DESC;
```

**Esta es la senal que el grafo no puede ver.** Neo4j sabe que dos cuentas se
califican entre si; no sabe que las dos entran desde la misma casa a la misma hora.
Juntas valen mucho mas que cualquiera por separado, y eso es lo que hay que contar
el dia de la presentacion.

### Copia, no mudanza

`log_login` y `log_registro` **se quedan en PostgreSQL**. Las dos tienen llave
foranea contra `usuarios` con `ON DELETE RESTRICT`; sacarlas de ahi es perder esa
integridad y quedarse con ids sueltos que pueden apuntar a cuentas que ya no
existen.

Es el mismo criterio que ya se aplico con Neo4j y con Elasticsearch: **la verdad
vive en PostgreSQL y esto es una proyeccion.** Se puede borrar entera y
reconstruir sin perder un dato de negocio. Lo unico que no se recupera son las
vistas de producto, porque esas no se derivan de nada.

### El resumen que se mantiene solo

`vistas_por_producto_dia` es una vista materializada. Cada fila que entra en
`vista_producto` la actualiza **en ese momento**. No hay ETL, no hay worker, no
hay cola que se quede vieja.

Es justo lo que en Cassandra habria que precalcular a mano con un cuarto proceso
de copia, con su propio desfase.

Y no reemplaza a la tabla cruda: esa se sigue pudiendo consultar para cualquier
pregunta que todavia no se le haya ocurrido a nadie.

---

## Medido el 2026-09-06

Se sembraron 3000 vistas sobre 5 productos en 6 dias, con el producto 1
subiendo fuerte los ultimos dos.

**El resumen se lleno solo, sin correr nada:**

```
dia          id_producto   vistas   personas
2026-09-01             1      100         70
...
2026-09-05             1      500        350
2026-09-06             1      500        350
```

**Tendencia, los ultimos 2 dias contra los 4 anteriores, en 8 milisegundos:**

```
id_producto   ahora   antes   veces
          1    1000     400     2.5
          4       0     400       0
```

**Fraude, vistas por persona:**

```
id_producto   vistas   personas   vistas_por_persona
          4      400         70                  5.7
```

Ese ultimo numero es la senal. Un producto con 500 vistas de 3 sesiones no esta
de moda, lo estan inflando.

Los datos de prueba se borraron al terminar. Para volver a sembrarlos, la
consulta esta abajo.

---

## La memoria, que es lo primero que hay que mirar en esta maquina

**Los topes estan puestos a mano y no son opcionales.** El 2026-09-06 Windows se
quedo sin memoria con la base recien montada y mato el backend, el servidor del
frontend y un arnes a media corrida. Medido en ese momento, con Docker teniendo
7.6 GiB de los 15.7 de la maquina:

```
mesh-elastic       1.112 GiB      heap fijado a mano en 512m
mesh-clickhouse    799.9 MiB      SIN NINGUN TOPE
mesh-neo4j         689.7 MiB
```

ClickHouse no era el que mas gastaba. Lo que lo hacia peligroso es que era el
unico sin techo, asi que una consulta pesada podia llevarse casi los 7.6 GiB y
dejar sin nada a las otras cinco bases.

Con los topes puestos baja a **289.7 MiB**, medio giga menos, y las consultas del
panel siguen contestando igual.

Los topes viven en dos archivos, y ese reparto es la trampa de esta seccion:

```
clickhouse/config.d/limites.xml            ajustes del SERVIDOR
clickhouse/users.d/limites-consulta.xml    el perfil, o sea la CONSULTA
```

### Las dos trampas que costo ponerlos

**Un `max_memory_usage` fuera de sitio tumba el arranque sin decir por que.** Es
un ajuste de consulta, no de servidor. Escrito suelto bajo `<clickhouse>` deja el
contenedor en bucle de reinicio con codigo **137** y sin una sola linea de error
en el log: se lee el "Merging configuration file limites.xml" y despues nada.

Y el sintoma enganaba, porque la maquina tenia 0.9 GiB libres justo entonces, asi
que lo primero que uno piensa es que lo mata la falta de memoria. Lo que lo
separo fue quitar el montaje y volver a levantar: **sin el archivo arrancaba sano
con la misma memoria libre**. La diferencia era el archivo.

**Un contenedor sano no quiere decir que el ajuste se aplico.** Al moverlo a un
`<profiles>` dentro de `config.d`, el contenedor arrancaba bien y tres de los
cuatro topes salian correctos. El cuarto no, y no habia ningun aviso:

```sql
SELECT name, value FROM system.settings WHERE name = 'max_memory_usage'
-- 0.00 B    o sea, sin limite
```

Los perfiles se leen de `users.d`, no de `config.d`. Un `<profiles>` en el arbol
equivocado no da error, simplemente no se aplica.

**Como se comprueba que estan puestos de verdad**, que es lo unico que vale:

```sql
SELECT name, formatReadableSize(toUInt64(value))
  FROM system.server_settings
 WHERE name IN ('max_server_memory_usage','mark_cache_size','uncompressed_cache_size');

SELECT name, formatReadableSize(toUInt64(value)), changed
  FROM system.settings WHERE name = 'max_memory_usage';
```

Los cuatro tienen que salir con el numero del archivo, y el ultimo con
`changed = 1`.

**El dia que entre el millon de productos**, estos numeros son los primeros que
hay que subir, igual que el heap de Elasticsearch.

---

## Dos trampas que ya mordieron, y una que no llego a morder

### 1. La zona horaria, que se atrapo antes de que rompiera nada

El contenedor nace en **UTC** y Guatemala es UTC-6. Medido: `today()` dentro de
la base ya decia `2026-09-07` cuando el reloj de Windows decia `2026-09-06
20:34`.

En una base de eventos eso no es un desfase de seis horas, **es un dia entero
mal contado**: un panel de ventas por dia partiria el dia a las 6 de la tarde y
todo lo posterior se sumaria al dia siguiente. Nadie lo notaria, porque los
numeros salen y cuadran entre ellos. Solo estan corridos.

Se ve en la misma consulta de tendencia:

```
con UTC              500 contra 900     <- mal
con la zona puesta  1000 contra 400     <- lo que se sembro
```

Esta arreglado con `TZ: America/Guatemala` en el compose.

### 2. La contrasena solo se aplica en el PRIMER arranque

`CLICKHOUSE_USER` y `CLICKHOUSE_PASSWORD` crean el usuario cuando el volumen
esta vacio. Cambiarlas en el `.env` sobre un volumen que ya existe **no cambia
nada en la base**, y el contenedor arranca sano con la contrasena vieja.

Para que tomen valores nuevos: `.\arrancar.ps1 -Reiniciar`.

### 3. El puerto 9000 sale por el 9010

El protocolo nativo de ClickHouse es el 9000, que es de los puertos mas peleados
de Windows (Portainer, MinIO, php-fpm). Se publica en el **9010** por fuera, por
la misma razon por la que MongoDB salio al 27018.

Por dentro del contenedor sigue siendo el 9000.

---

## Lo que falta, y es lo siguiente que hay que hacer

Hoy las tres tablas estan **vacias y funcionando**. Lo que no existe todavia:

1. **Que el frontend mande la vista de producto.** Un `POST` al entrar a
   `/producto/[id]`. Sin esto la tabla que mas importa no se llena nunca.
2. **La ruta del backend que la recibe** y escribe en ClickHouse.
3. **La copia de `log_login` y `log_registro`.** El patron ya existe tres veces
   en el proyecto (el ETL de Mongo, la cola del grafo, la cola del buscador). El
   mas parecido es el del buscador, porque tambien es una copia hacia adelante.
4. **El panel de tendencias**, que es la funcionalidad de la Entrega 2 que quedo
   condicionada al elegir grafos, y la que el profesor esta pidiendo ahora.

### Para sembrar datos de prueba mientras tanto

```sql
INSERT INTO vista_producto
SELECT now() - INTERVAL (6 - intDiv(number,500)) DAY,
       if(intDiv(number,500) >= 4, 1, 1 + (number % 5)),
       if(number % 3 = 0, NULL, toUInt64(number % 40)),
       concat('s', toString(number % 350)),
       toIPv6(concat('::ffff:10.0.0.', toString(number % 25))),
       ['catalogo','buscador','directo'][1 + number % 3]
FROM numbers(3000);
```

Y para limpiar:

```sql
TRUNCATE TABLE vista_producto;
TRUNCATE TABLE vistas_por_producto_dia;
```
