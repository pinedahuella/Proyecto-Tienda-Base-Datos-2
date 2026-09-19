# clickhouse/lote/

Eventos **de mentira** para ClickHouse, deterministas por semilla, con dos
senales plantadas dentro que se pueden senalar con el dedo.

| | |
|---|---|
| `generar_vistas.sql` | siembra vistas de producto, logueos y registros marcados |
| `generar_actividad.sql` | siembra el resto del embudo, encima de esas vistas: carrito, compra, devolucion, busquedas y clics |
| `borrar_lote.sql` | deshace un lote por su semilla, **de las nueve tablas, incluido el resumen que no se vacia solo** |

Esta carpeta es una subcarpeta por el mismo motivo que `migrations/lote/` y
`mongo/lote/`. `arrancar.ps1` corre los archivos que encuentra sueltos en la
carpeta de cada base, y `clickhouse/001_esquema.sql` se aplica en cada arranque
porque es idempotente. Este generador **crea filas cada vez que corre**, asi que
un arranque que lo ejecutara solo llenaria la base de eventos inventados en cada
reinicio de la maquina y nadie sabria de donde salieron.

---

## Que hace

Hoy las tres tablas de eventos estan vivas y **vacias de vistas**.
`vista_producto` es la unica que nace en ClickHouse y todavia no la escribe
nadie, porque falta la ruta del backend y falta el aviso del frontend al entrar
en la ficha. Un panel de tendencias contra una tabla vacia no se puede ensenar y
tampoco se puede corregir.

Y hay un segundo motivo, que es el que de verdad obliga. Medido el 2026-09-06
sobre esta base, `log_login` tiene **317 logueos reales y todos salen de la
misma IP**, la 127.0.0.1, porque todo el desarrollo se ha hecho en local.
`log_registro` tiene **una fila**. Las cuentas de verdad son doce.

Contra esos datos el analisis de fraude no se puede ni calibrar. La pregunta que
`evento_login` existe para contestar es cuantas cuentas distintas salen de una
misma IP, y la respuesta seria "doce cuentas desde 127.0.0.1", o sea que el
propio equipo saldria marcado como anillo por construccion. Un detector que
acusa a todo el mundo no dice nada.

### Lo que siembra, y por que cada cosa

**Un fondo de ruido.** `vistas` filas repartidas entre los productos del 1 al 60
y los ultimos 14 dias, un tercio sin cuenta iniciada, cerca de dos vistas por
sesion. Existe para tener contra que comparar. Una senal sin fondo deja de ser
una senal y se queda en el unico dato que hay.

**Un producto en ascenso.** Uno solo, de la banda 61 a 80. Su rampa esta escrita
a mano en el archivo, en vistas por dia y de hoy hacia atras, para que se pueda
leer de un vistazo lo que se sembro.

```
[70, 44, 26, 16, 11, 8, 6, 5, 4, 4, 3, 3, 2, 2]
 hoy ayer  ...                          hace 13 dias
```

Cada numero de esa rampa es un multiplo del ruido de fondo. Hoy tiene 70 veces
lo que un producto cualquiera y hace dos semanas tenia el doble. Sus sesiones
son casi todas distintas, alrededor de vista y media por sesion, y eso es lo que
lo separa de un inflado. Mucha gente mirando una vez es moda.

**Un anillo de fraude.** Ocho cuentas nacidas la misma manana desde **una sola
IP**, con 47 segundos entre una y la siguiente, que entran 48 veces desde esa
misma IP y machacan **un** producto de la banda 81 a 100 desde **seis sesiones**,
todo dentro de los ultimos dos dias, y siempre con origen `directo`. No llegan
por el catalogo ni por el buscador, van derechas a la ficha, que es lo que hace
alguien que trae el enlace escrito en una lista.

Con `vistas=3000` eso da 45 vistas por sesion contra las 1.1 del fondo.

### Todo lo generado va marcado

Cada fila lleva `lote = 'generado-<semilla>'`. El valor `real`, que es el DEFAULT
de las tres tablas, queda para lo que mande el portal y para la copia de
PostgreSQL cuando exista. Es el mismo marcador que la `L` de `migrations/lote` y
la `M` de `mongo/lote`.

La marca sube hasta `vistas_por_producto_dia` porque esta en su `ORDER BY`. Sin
ella el panel leeria un solo numero por producto y por dia sin poder decir que
parte se la invento un script.

### Las tres bandas de producto

El catalogo tiene 1101 productos y los cien primeros existen todos. Medido con
`SELECT count(*) FROM productos WHERE id_producto BETWEEN 1 AND 100` sobre
PostgreSQL, que devuelve 100. Se usan ids bajos y comprobados a proposito,
porque un panel que ensena el producto 8341 manda a quien lo mire a una ficha
que da 404, y a partir de ahi ya no se sabe si lo que falla es el panel o el
catalogo.

| Banda | Para que |
|---|---|
| 1 a 60 | el fondo, el ruido repartido |
| 61 a 80 | de ahi sale **el** producto en ascenso |
| 81 a 100 | de ahi sale **el** producto inflado |

Las bandas impiden por construccion que las dos senales caigan en el mismo
producto y se sumen en la misma fila. Cual de los veinte toca en cada banda lo
decide la semilla, y el resumen del final lo imprime.

### Las cuentas, que van al reves que los productos

Este archivo **no le pone ni un evento a las doce cuentas reales**, ni una vista
ni un logueo. Las generadas viven en dos bandas altisimas.

| Banda | Quienes |
|---|---|
| 1000000 y arriba | las ocho del anillo, todas desde una sola IP |
| 2000000 y arriba | las 200 de fondo, cada una con **su** IP |

La contrapartida honesta es que esas cuentas no existen en `usuarios`, asi que
el panel ensenara ids que no se pueden abrir, que es justo lo que se evito con
los productos. Aqui se acepta al reves por una razon concreta. Un id de producto
falso rompe un enlace. Un id de usuario tomado prestado senala a una persona, y
un anillo dibujado por un generador y colgado del id de alguien de verdad es una
acusacion inventada que en un panel de fraude no se distingue de un hallazgo.

### Las IP

| Rango | Quien |
|---|---|
| `10.100.x.y` | una cuenta de fondo, y cada cuenta tiene siempre la suya |
| `10.200.x.y` | visitantes sin sesion iniciada, sueltos |
| `10.66.x.y` | el anillo entero, una sola para las ocho cuentas |

Que la IP de una cuenta de fondo sea funcion de su numero y de nada mas es lo
que hace que su registro y sus logueos cuadren entre ellos. Con una IP sorteada
por fila, cada cuenta saldria de decenas de IP distintas, el panel de cuentas
por IP daria uno en todas las filas y no habria contra que comparar al anillo.

---

## Como se corre

El contenedor **no tiene el repositorio montado dentro**, asi que el archivo
entra por la entrada estandar y no por una ruta.

```bash
export MSYS_NO_PATHCONV=1

docker exec -i mesh-clickhouse clickhouse-client \
    --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_DB" \
    --param_semilla=42 --param_vistas=3000 \
    --multiquery < clickhouse/lote/generar_vistas.sql
```

Las credenciales salen del `.env` de la raiz, con `CLICKHOUSE_USER`,
`CLICKHOUSE_PASSWORD` y `CLICKHOUSE_DB`.

**Los dos parametros.** `semilla` es cualquier entero sin signo y decide el
sorteo entero. `vistas` es cuantas vistas de fondo sembrar, de 840 a 5000000, y
las dos senales se escalan solas a partir de ese numero.

### Tres cosas de la linea de comandos que muerden

**`--param_<nombre>` no se parece a `-v` de psql.** Dentro del SQL se leen como
`{nombre:Tipo}`, con el tipo escrito ahi mismo, y lo valida el servidor. Medido,
`--param_semilla=abc` contesta `Code: 457. Value abc cannot be parsed as UInt64`
y sale sin haber tocado ni una tabla.

**`--multiquery` se deja por compatibilidad, no porque haga falta aqui.** Este
REAME decia que sin el `clickhouse-client` se queda con la primera sentencia, y
eso se midio el 2026-09-06 contra la 25.3.14.14 y es falso: dos sentencias por
tuberia sin la bandera corren las dos.

Lo que SI se sostiene es la otra mitad, y es la que importa: **la primera
sentencia que falla para el archivo entero**. Eso es lo que hace util a la
guardia, porque ClickHouse no tiene transaccion y un lote a medias no se
deshace solo.

**Ningun `INSERT ... VALUES` puede entrar por ahi.** Todos los INSERT del
generador son `INSERT ... SELECT`. Uno con `VALUES` se comeria el resto del
archivo creyendo que son sus datos, y no fallaria, insertaria basura y se
callaria.

### La escala, que es el parametro que hay que entender

El fondo reparte `vistas` filas entre 60 productos y 14 dias, o sea que la media
son `vistas / 840` vistas por producto y por dia. A ese numero el archivo lo
llama `factor`, y las dos senales van multiplicadas por el.

Sin eso, un lote grande esconderia sus propias senales. Con `vistas=100000` el
fondo pone 119 vistas por producto y por dia, y una tendencia de 70 vistas en su
dia mas alto quedaria **por debajo** del ruido. Se veria un panel lleno de datos
donde no destaca nada, y lo primero que pensaria quien lo mire es que la
consulta de tendencia esta mal escrita.

El anillo se queda siempre en seis sesiones, suba lo que suba el volumen, para
que la senal no se diluya nunca. La contrapartida es que con volumenes muy
grandes queda caricaturesco, y esta medido mas abajo.

### La semilla reproduce el mismo SORTEO, no la misma BASE

Lo mismo que ya advierte `migrations/lote/README.md`, y aqui hay que decirlo
igual de fuerte.

Correr dos veces la semilla 42 no deja la base como estaba, deja **el doble**.
El sorteo es identico, las mismas cuentas y los mismos productos, pero se aplica
encima de lo que ya hay y las filas se suman. El producto en ascenso pasaria a
tener el doble de vistas, el anillo el doble de clics, y todo seguiria
pareciendo coherente.

**Y aqui no hay transaccion que lo arregle despues.** ClickHouse no tiene BEGIN,
no tiene COMMIT y no tiene forma de deshacer a medias, asi que la unica defensa
es mirar antes. Eso es el PASO 0 del generador, y aborta contra las tres tablas
si esa marca ya existe.

```
Code: 395. La semilla 42 ya sembro en esta base. Correrla otra vez deja el
doble, no lo mismo. Usa otra semilla, o deshaz esta antes con borrar_lote.sql
```

La misma falta de transaccion es la que obliga a que **todo lo de una tabla
entre en un solo INSERT**. Los tres bloques de `vista_producto` van unidos con
`UNION ALL` dentro de la misma sentencia, y no como tres seguidas, porque tres
seguidas pueden dejar el fondo puesto y la senal sin poner. Esa es la peor mitad
posible, porque el panel se pinta entero y no ensena nada.

Si aun asi una corrida muere entre el INSERT de una tabla y el de la siguiente,
la salida es correr `borrar_lote.sql` con esa misma semilla y volver a empezar.

### Por que `cityHash64` y no `rand()`

`rand()` devuelve un numero distinto en cada evaluacion y no acepta semilla, asi
que dos corridas de la misma semilla darian dos lotes distintos y la palabra
determinista seria mentira. `cityHash64` es una funcion pura, el mismo par de
argumentos da el mismo entero de 64 bits siempre.

Cada campo pide su hash con una etiqueta de texto propia. Sin esa etiqueta todos
los campos de una fila saldrian del mismo numero y quedarian correlacionados, o
sea que la sesion 7 miraria siempre el producto 7 desde la misma IP, y eso se
nota a simple vista en el panel.

**Lo que la semilla NO fija es el dia.** Todo se ancla en el dia de hoy, asi que
la misma semilla manana siembra exactamente el mismo lote corrido veinticuatro
horas. Las filas del dia en curso ademas se reparten solo sobre los segundos que
ya pasaron, porque sumar un resto de hasta 86400 pondria vistas con hora futura
y esas se cuelan en cualquier panel de los ultimos N dias con una fecha que
todavia no ha ocurrido.

---

## Como se deshace, y son DOS mitades

```bash
export MSYS_NO_PATHCONV=1

docker exec -i mesh-clickhouse clickhouse-client \
    --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
    --database "$CLICKHOUSE_DB" \
    --param_semilla=42 \
    --multiquery < clickhouse/lote/borrar_lote.sql
```

### La mitad que se olvida

**`vistas_por_producto_dia` no se vacia al borrar de `vista_producto`.** Esto es
lo mas facil de olvidar de toda la carpeta y no da ningun error.

El motivo esta en lo que una vista materializada de ClickHouse es. Funciona como
un disparador sobre la insercion. Cada vez que entra un bloque de filas en
`vista_producto`, la vista lo agrega y escribe el resultado en el resumen. Mira
lo que **entra**, una vez, y nunca vuelve a mirar la tabla de origen. Un DELETE
sobre la tabla cruda no le llega.

Y lo peor es como se ve eso. La tabla cruda queda limpia, con lo cual quien
compruebe con `SELECT count() FROM vista_producto` se lleva un cero y da el
borrado por hecho. El panel, que lee del resumen porque para eso existe el
resumen, **sigue ensenando el lote**. Los dos numeros son ciertos y se
contradicen, y no hay ningun mensaje que lo explique.

Esta medido abajo, con el lote de la semilla 7.

Por eso `borrar_lote.sql` borra de las **cuatro** tablas y despues las vuelve a
contar y aborta si alguna quedo con filas.

### Dos detalles del borrado que hay que saber

**Usa `ALTER TABLE ... DELETE` y no el `DELETE FROM` ligero.** El ligero marca
las filas con una mascara y las esconde al leer. La mutacion reescribe las
partes de disco sin ellas. Sobre `vistas_por_producto_dia`, que es
`AggregatingMergeTree` y guarda estados de agregacion en vez de numeros, lo que
se quiere es que la parte se reescriba de verdad y no que quede una mascara
encima de unos estados que despues se van a fusionar con los que entren luego.

**`SETTINGS mutations_sync = 2`, que es la trampa de verdad.** Una mutacion es
**asincrona por defecto**. El ALTER vuelve en milisegundos con todo bien, la
mutacion se queda encolada en `system.mutations`, y las filas siguen ahi
mientras tanto. Sin ese ajuste, borrar y volver a sembrar en la misma corrida se
estrella contra la guardia del generador diciendo que la semilla ya existe.

### Lo que el borrado no puede tocar

Nada que lleve `lote = 'real'`. La comparacion es contra `'generado-<semilla>'`,
que nunca puede valer `real` porque la semilla entra tipada como `UInt64` y el
prefijo esta escrito en el archivo.

Eso importa porque las vistas de producto son el unico dato de las cuatro tablas
que **no se puede reconstruir**. `evento_login` y `evento_registro` son copias
de PostgreSQL y se vuelven a copiar. Un clic en una ficha no se deriva de nada y
no esta guardado en ninguna otra parte.

### Para barrer todo lo generado de una vez

`borrar_lote.sql` deshace **un lote nombrado**, que es una peticion concreta.
Barrer todo lo generado no cabe en el parametro y se hace a mano, con las mismas
cuatro mutaciones y cambiando la comparacion por `WHERE lote != 'real'`.

Se escribe asi y no con un `LIKE 'generado-%'` a proposito. Lo que hay que
proteger es lo real, y una marca nueva que alguien invente manana y que no
empiece por `generado-` se quedaria dentro con el LIKE y fuera con esto.

### El borrado es idempotente, el generador no

Correr `borrar_lote.sql` dos veces con la misma semilla borra cero filas la
segunda y sale bien. Eso es a proposito, porque las cuatro mutaciones tampoco
van en transaccion y una caida entre la segunda y la tercera deja dos tablas
limpias y dos sin limpiar. Volver a correrlo termina el trabajo sin quejarse.

---

## Que se midio

Todo esto es del **2026-09-06**, contra `mesh-clickhouse` vivo, ClickHouse
25.3.14.14, base `mesh_eventos`, con la zona horaria `America/Guatemala` ya
puesta.

### El lote de la semilla 42, con `vistas=3000`

```
lote          factor   producto_en_ascenso   producto_inflado   ip_del_anillo
generado-42        3                    73                100   ::ffff:10.66.221.180
                                                                cuentas 1895540 a 1895547
```

```
tabla                      filas
evento_login                 848
evento_registro              208
vista_producto              3882
vistas_por_producto_dia      832
```

Las 3882 vistas son 3000 de fondo, 612 de la tendencia y 270 del anillo.

**La tendencia, los ultimos 3 dias contra los 11 anteriores.**

```
id_producto   ultimos_3_dias   los_11_anteriores   veces
        100              270                   0     270
         73              420                 192    2.19
         46               17                  33    0.52
         44               16                  32     0.5
```

Los dos plantados salen arriba y por motivos distintos. El 73 porque su rampa se
dobla, el 100 porque todo lo suyo cabe en dos dias.

**El fraude, leido del resumen que se mantiene solo.**

```
id_producto   vistas   personas   vistas_por_persona
        100      270          6                   45
         73      612        371                  1.6
         16       54         51                  1.1
```

Ese 45 contra 1.1 es la senal. Un producto con 270 vistas de 6 sesiones no esta
de moda.

Sale del resumen y no de la tabla cruda a proposito, porque asi la vista
materializada queda comprobada de paso. Si alguien la hubiera borrado y vuelto a
crear despues de sembrar, esta tabla saldria vacia mientras la de tendencia
sigue dando numeros.

**El anillo por donde de verdad se ve, que son las cuentas por IP.**

```
ip                     cuentas   logueos
::ffff:10.66.221.180         8        48
::ffff:10.100.0.29           1        11
::ffff:10.100.0.123          1        10
::ffff:10.100.0.66           1         9
```

Ese ocho contra unos es exactamente el contraste que con los datos reales no se
puede tener, porque los 317 logueos de verdad comparten la misma 127.0.0.1.

### Que de verdad es determinista, comprobado con una huella

Se sembro la semilla 7, se calculo una huella de todas sus vistas dejando la
fecha fuera, se borro el lote entero y se volvio a sembrar la misma semilla.

```sql
SELECT sum(cityHash64(id_producto, toString(id_usuario), sesion,
                      toString(ip), origen)) AS huella,
       count()
  FROM vista_producto WHERE lote = 'generado-7';
```

```
primera corrida    6042158249464693745    3882 filas
segunda corrida    6042158249464693745    3882 filas
```

La fecha se deja fuera porque el lote se ancla en el dia de hoy y en los
segundos que ya pasaron de hoy, asi que los timestamps del dia en curso se
mueven entre corridas aunque el sorteo sea el mismo.

### La trampa de las dos mitades, reproducida a proposito

Con el lote de la semilla 7 puesto, se borro **solo** de la tabla cruda, que es
lo que haria cualquiera.

```sql
ALTER TABLE vista_producto DELETE WHERE lote = 'generado-7'
  SETTINGS mutations_sync = 2;
```

```
vista_producto              0
vistas_por_producto_dia   836     <- siguen ahi
```

Y el panel, preguntando al resumen, seguia ensenando el lote entero.

```
id_producto   vistas   personas
         65      612        391
         84      270          6
```

Despues `borrar_lote.sql` con la semilla 7 dejo las cuatro tablas en cero y no
toco ni `generado-42` ni las filas marcadas `real`.

### Un lote grande, para ver que la escala funciona

Semilla 99 con `vistas=100000`, o sea `factor` 119.

```
id_producto   ultimos_3_dias   los_11_anteriores   veces
         97            10710                   0   10710
         73            16660                7616    2.19
         23              409                1287    0.32
```

```
id_producto   vistas   personas   vistas_por_persona
         97    10710          6               1785
         73    24276      15371                1.6
         19     1716       1702                  1
```

El 2.19 de la tendencia es **el mismo** que con 3000 vistas, que es lo que la
escala tenia que conseguir. Y ahi se ve tambien la contrapartida de dejar el
anillo en seis sesiones pase lo que pase. Esas 1785 vistas por sesion son una
vista cada minuto y medio por sesion durante dos dias seguidos, o sea un robot
descarado. Es
util para una demostracion y no sirve para calibrar un umbral fino.

### Los tiempos, que varian y conviene tomar como orden de magnitud

```
generar   3000 vistas de fondo    3.6 s
generar 100000 vistas de fondo    5.8 s
borrar un lote de 3882 vistas     3.7 s
```

Una de las borradas tardo 24 segundos justo despues de haber escrito el lote
grande, con las fusiones de fondo todavia corriendo. Las mutaciones compiten con
esas fusiones, asi que el numero de arriba es el caso tranquilo.

---

## Lo que quedo en la base

**El lote `generado-42` esta sembrado ahora mismo**, con las 3882 vistas de la
tabla de arriba, para que el panel se pueda montar y mirar sin tener que sembrar
antes. Las filas marcadas `real` que hay al lado son los logueos y el registro
de verdad, y este generador no las ha tocado.

Para quitarlo, `borrar_lote.sql` con `--param_semilla=42`.

### La marca separa, pero no protege de un TRUNCATE

Esto paso hoy mismo mientras se escribia esta carpeta, asi que conviene dejarlo
apuntado. Con el lote 42 puesto, otra sesion que estaba montando la copia de
`log_login` vacio `evento_login` para volver a empezar, y se llevo por delante
las 848 filas generadas del lote junto con las suyas. El generador no dio ningun
error, porque el borrado no vino de aqui, y el lote quedo a medias con sus
vistas intactas y sus logueos en cero.

La columna `lote` sirve para leer, para filtrar y para borrar por marca. No es
un permiso. Un `TRUNCATE TABLE` o un `DELETE` sin `WHERE` se lleva las cuatro
marcas por igual.

Se arregla en una linea, borrando el lote y volviendolo a sembrar con la misma
semilla, que para eso el sorteo es el mismo. Lo que hay que saber es que la
comprobacion vale la pena hacerla antes de ensenar el panel.

```sql
SELECT lote, count() FROM evento_login GROUP BY lote;
```

---

# La actividad: el resto del embudo (2026-09-18)

> **AVISO DEL 2026-09-19.** Desde hoy las seis rutas de `/admin/eventos/*` y el ranking de mas vendidos cuentan
> SOLO `lote = 'real'` (decision de Jose David, sin parametro). **Nada de lo que siembra este generador se ve en
> Tendencias ni en el estante de la portada.** Sigue sirviendo para consultar ClickHouse a mano
> (http://localhost:8123/play) y para probar consultas sobre datos con forma real. Las secciones de abajo se
> escribieron cuando si se veia y se dejan como estan.

`generar_actividad.sql` existe porque, medido ese dia, cuatro de las seis tablas de eventos
estaban vacias o casi: `busqueda_realizada` y `busqueda_clic` en cero, y compra,
devolucion y carrito con las pocas filas que dejo alguien probando. Dos de los seis
rankings de Tendencias no ensenaban nada y el estante de mas vendidos salia vacio.

Sale de las vistas de la MISMA semilla, asi el embudo es coherente:

```
vista_producto -> carrito (1 de cada 6, si tenia cuenta) -> compra (1 de cada 3)
                                                              -> devolucion (1 de cada 8, dias despues)
vista con origen 'buscador' -> busqueda_clic -> busqueda_realizada
mas busquedas sin clic, y algunas que no encuentran nada (tablet, consola, dron...)
```

Con la semilla 42 y 3000 vistas: 3882 vistas, 451 carritos, 154 compras, 14 devoluciones,
1174 clics y unas 2300 busquedas. `arrancar.ps1 -Vistas 3000 -Semilla 42` corre las dos.

## LA TRAMPA DE LAS FECHAS, y por que hay que sembrar el mismo dia

Las vistas llevan la fecha de cuando se corrio el generador (las de la semilla 42 de antes
eran del 24 de agosto al 6 de septiembre) y los rankings miran **los ultimos 7 dias** por
defecto. La tabla tenia 3882 filas y la pantalla salia vacia. Todo lo de `generar_actividad.sql`
hereda la fecha de las vistas, asi que **para una demo hay que renovar el lote el mismo dia**:

```
.\arrancar.ps1 -BorrarVistas 42
.\arrancar.ps1 -Vistas 3000 -Semilla 42
```

El lote de eventos NO se renueva solo. Si la pantalla de Tendencias sale vacia con la tabla
llena, mira primero de que dia son las filas.

## Lo que no es real

`id_oferta` vale lo mismo que `id_producto` (no apunta a ninguna oferta) y `id_pedido` va entre
3000000000 y 3999999999. Los terminos de busqueda salen de una lista fija por rango de
producto, aproximada al catalogo. Ninguna fila lleva una cuenta real.

## Dos trampas de ClickHouse que salieron escribiendolo

`throwIf` exige un mensaje CONSTANTE (Code 44): no se puede decir cuantas filas hay dentro
del error de la guardia. Y un alias de `WITH` que usa una columna no se puede resolver desde
una subconsulta (Code 1, "correlated column"): va dentro de la rama que lo usa.
