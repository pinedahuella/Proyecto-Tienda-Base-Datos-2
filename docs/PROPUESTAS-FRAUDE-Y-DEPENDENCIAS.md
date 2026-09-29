# Propuestas sobre fraude, dependencias entre bases, carrito y Elasticsearch

Escrito el 2026-09-28 en la noche, a partir de la revision del profesor. Son propuestas para decidir en equipo antes
de tocar codigo. Nada de esto esta implementado todavia. Cada punto dice que hay hoy, que se propone, contra que
practica de la industria se compara y cuanto cuesta.

La observacion del profesor fue que las decisiones del informe son genericas y no contestan dos cosas concretas, por
que cada flujo depende de las bases de las que depende, y como se detecta y se maneja el fraude. Las secciones 1 a 5
responden eso y la seccion 6 propone como reescribir las decisiones.

## Resumen

| # | Tema | Recomendacion | Costo aproximado |
|---|---|---|---|
| 1 | Fraude | Un solo modelo para todas las fuentes, senal, deteccion, evidencia y caso. Cada re-deteccion se guarda como un hecho con fecha en ClickHouse y suma evidencia | medio, una migracion, una tabla de ClickHouse y un servicio comun en el backend |
| 1b | Consultas nuevas | Doce consultas repartidas en las cinco bases, cada una con una tecnica que se usa en la industria (velocidad, secuencias, texto casi igual, grafo de identidad, anomalia robusta) | cada una es chica, se pueden hacer de a una |
| 2 | Checkout | Copiar el nombre del producto y el estado de la variante en `oferta`. Publicar y comprar quedan con PostgreSQL y Redis, sin MongoDB en el camino critico | bajo, una migracion y un evento del outbox |
| 3 | Carrito | Guardar la foto que manda el frontend, validada por forma y tamano. Agregar al carrito solo toca Redis y el cobro sigue revalidando contra PostgreSQL | bajo, el mismo hash de hoy con otro valor |
| 4 | Elasticsearch | Pasar de agregaciones simples a lo que distingue a este motor, analizador en espanol con sinonimos, ranking con `function_score`, sugerencias de frase, percolator, `significant_terms`, EQL y transforms | medio, se puede hacer por partes |
| 5 | Vectores | pgvector se queda como fuente de los parecidos. Elasticsearch recibe una copia del vector solo para la busqueda hibrida de la caja de busqueda | bajo, el vector ya existe |
| 6 | Decisiones | Reescribir las decisiones del informe con un formato atado a flujos, bases y caidas medidas | medio, es texto con numeros que ya tenemos |

---

## 1. Fraude, un solo modelo para todas las fuentes

### 1.1 Lo que hay hoy

Hay cuatro familias de deteccion y cada una guarda su resultado a su manera.

| Familia | Donde se detecta | Donde se guarda | Tipos |
|---|---|---|---|
| A, anillos de resenas | Neo4j | `anillo_fraude` y `anillo_fraude_resena` | mutuo, ciclo, reiterado |
| B, patrones de resenas | Neo4j | las mismas tablas, con tipos nuevos (023) | cadena abierta, satelites, persistente, favor devuelto, coordinados, reputacion expres |
| F, compras y navegacion | ClickHouse | `hallazgo_evento_fraude` (025) | F1 a F6 |
| Login | Elasticsearch, Redis y MongoDB | `alerta_fraude` (016) | nueve tipos, de fuerza bruta a viaje imposible |

Encima esta el agrupador de casos (026). `evidencia_caso_fraude` tiene tres llaves que pueden ser nulas, una por
cada tabla de origen, y el agrupador necesita tres adaptadores distintos para leerlas. De ahi salen los problemas que
ya medimos.

- Cada tabla tiene su propio estado y su propia fecha, y la fecha que mueve el admin se confunde con la del fraude.
  Es el C4 de `BACKEND-PENDIENTE.md`.
- Cuando un detector vuelve a encontrar el mismo anillo solo actualiza `ultima_vez_confirmado_activo`. La historia se
  pierde. No se sabe si el par mutuo aparecio una vez o doce semanas seguidas, que es justo lo que el profesor puso de
  ejemplo.
- La ventana de Neo4j es fija, 60 dias, y lo que pasa antes no existe para ningun detector.
- La unica huella fisica es la IP. En local todo sale de 127.0.0.1 y por eso el caso gigante del 26 (C1).

### 1.2 El modelo propuesto

Cuatro piezas con el mismo nombre para todas las fuentes.

| Pieza | Que es | Donde vive | Por que ahi |
|---|---|---|---|
| Senal | Un patron sobre un conjunto de entidades, identificado por tipo y clave canonica, por ejemplo mutuo entre las cuentas 9 y 10 | PostgreSQL, tabla `senal_fraude` | tiene estado, lo cambia el admin, necesita llaves y transacciones |
| Deteccion | Cada vez que un detector vuelve a ver esa senal, con su fecha y sus metricas de ese momento | ClickHouse, tabla `deteccion_fraude` | es un registro que solo crece, se consulta por tiempo y se agrega por millones |
| Evidencia | Una senal metida en un caso, con sus puntos | PostgreSQL, `evidencia_caso_fraude` con UNA llave a `senal_fraude` | reemplaza las tres llaves nulas |
| Caso | Un grupo de cuentas y entidades con su puntaje, su nivel y la decision del admin | PostgreSQL, `caso_fraude` (ya existe) | igual que hoy |

El catalogo de tipos se vuelve uno solo, `tipo_senal_fraude`, con familia, fuente, peso base, si es fuerte o debil y
la ventana en la que se busca. Hoy son tres catalogos que no se hablan.

El ejemplo del profesor queda asi. Dos cuentas que se resenan mutuamente son una senal. El detector de Neo4j la
encuentra hoy y deja una fila en `deteccion_fraude`. Si la semana que viene la vuelve a encontrar, deja otra fila, y la
senal no se duplica. El puntaje de la evidencia sube con la cantidad de detecciones y con cuantas semanas distintas
aparecio, y baja con el tiempo que lleva sin aparecer. Si el admin la habia descartado y reaparece con detecciones
nuevas despues del descarte, el caso se reabre marcado como reincidente, con la fecha de cada deteccion a la vista.

En Neo4j la misma idea queda como memoria del grafo. Entre las dos cuentas se guarda una relacion `SOSPECHA` con el
tipo, la primera y la ultima deteccion y cuantas veces se vio. Asi una consulta de grafo puede preguntar por cuentas
que ya fueron sospechosas juntas antes, sin ir a otra base.

### 1.3 Temporalidad

- Cada detector corre con varias ventanas, 24 horas, 7 dias, 30 dias y 180 dias, en lugar de solo 60 dias. La ventana
  corta encuentra rafagas y la larga encuentra lo lento y constante.
- La persistencia se calcula sobre `deteccion_fraude`, en cuantas semanas distintas aparecio la senal en los ultimos
  seis meses. Un par mutuo que aparece ocho semanas seguidas pesa mas que uno que aparecio una vez.
- El puntaje decae con vida media de 30 dias contando desde la ultima deteccion. Resuelve el C4, porque la fecha la
  pone el detector y el admin no la toca.
- ClickHouse guarda las detecciones un ano con TTL y una vista materializada lleva el conteo por senal y por dia, que
  es lo que dibuja la linea de tiempo en el panel.

### 1.4 Consultas nuevas por base

Ninguna necesita arquitectura nueva. Todas usan bases que ya estan levantadas y cada una trae una tecnica que se usa en
sistemas de fraude reales.

| Id | Base | Tecnica | Que detecta | Dato que necesita |
|---|---|---|---|---|
| V1 | Redis | Reglas de velocidad con ventana deslizante (sorted set por cuenta, IP y huella), como las reglas de velocidad de los procesadores de pago | mas de N resenas por hora de una cuenta, mas de N registros por IP o huella en una hora, mas de N compras por tarjeta | ya existe el patron en el login, se extiende a resenas, registro y compra |
| V2 | Redis | Puntaje de riesgo por cuenta en cache, con TTL de 15 minutos | que el backend pueda frenar una resena o pedir revision sin consultar cuatro bases en el camino | lo escribe el agrupador |
| M1 | MongoDB | `$setWindowFields` sobre los eventos de autenticacion, intervalo entre eventos por cuenta y su coeficiente de variacion | cuentas que entran con una regularidad que ninguna persona tiene, un script | eventos que ya existen |
| M2 | MongoDB | Huella del navegador (hash de agente, pantalla, zona horaria e idioma) guardada con cada evento | muchas cuentas desde el mismo equipo aunque cambien de IP. Es mas fuerte que la IP y no falla en local | que el frontend mande la huella en login, registro, resena y compra |
| E1 | Elasticsearch | EQL con `sequence` y `maxspan`, el lenguaje que usan las herramientas de seguridad | toma de cuenta, varios fallos, entrada desde un pais nuevo, cambio de correo y compra en menos de 30 minutos | indice de login con categoria de evento |
| E2 | Elasticsearch | `significant_terms` contra el fondo | la IP, el pais o la huella que aparece de forma anormal en los logins de las cuentas que resenan a un vendedor | indice de login |
| E3 | Elasticsearch | `more_like_this` sobre un indice nuevo de resenas | textos casi iguales escritos por cuentas distintas, la marca de las cuentas titere | copiar el texto de las resenas al indice |
| C1 | ClickHouse | `sequenceMatch` y `windowFunnel` | registro, compra y resena en menos de N minutos por cuenta, la reputacion expres medida en eventos | eventos de registro, compra y resena en ClickHouse |
| C2 | ClickHouse | Anomalia robusta, mediana y desviacion absoluta mediana de las resenas de 5 estrellas por vendedor y dia contra sus 28 dias previos | un vendedor que de golpe recibe muchas mas notas altas que su propia historia | resenas copiadas a ClickHouse |
| C3 | ClickHouse | Cruce de resenas contra vistas | cuentas que califican un producto que nunca abrieron | vistas (ya estan) y resenas |
| C4 | ClickHouse | Historial de precio antes de un descuento | descuento inflado, el vendedor sube el precio mas de 15 por ciento en los 7 dias previos y luego pone el descuento | `precio_historial` copiado a ClickHouse |
| N1 | Neo4j | Grafo de identidad, nodos de huella, IP y direccion unidos a las cuentas, y componentes conexos para armar el caso | varias cuentas que son la misma persona aunque no se resenen entre si | M2 y las direcciones que ya estan |
| N2 | Neo4j | Ciclo de dinero, A le compra a B, B a C y C a A | colusion por compras, ademas de la de resenas | pedidos proyectados al grafo |
| N3 | Neo4j | Relacion `SOSPECHA` con historia (ver 1.2) | reincidencia entre las mismas cuentas | la escribe el registro de senales |

Con N1 el agrupador puede dejar de ser un union-find en TypeScript. El caso sale de los componentes conexos del grafo,
y la decision de C1 se vuelve una regla sobre el tipo de relacion. Una IP compartida es debil y no une sola, una huella
compartida o una direccion compartida si une.

### 1.5 Refactor que haria falta

Base de datos.
- Migracion 029 con `tipo_senal_fraude`, `senal_fraude` y el cambio de `evidencia_caso_fraude` a una sola llave. Las
  filas de `anillo_fraude`, `hallazgo_evento_fraude` y `alerta_fraude` pasan a `senal_fraude` con un INSERT desde cada
  una. Las tres tablas viejas pueden quedar como vistas del mismo nombre para que las pantallas actuales no se rompan
  mientras se cambian.
- `clickhouse/002_detecciones.sql` con `deteccion_fraude` (MergeTree ordenado por senal y fecha, TTL de un ano) y su
  vista materializada por dia.

Backend.
- Una interfaz comun para los detectores, con tipo, fuente y un metodo que devuelve senales. Hoy cada detector escribe
  en su tabla.
- Un solo servicio que registra una senal, hace el upsert en PostgreSQL y agrega la deteccion en ClickHouse.
- El agrupador lee solo `senal_fraude`. Desaparecen los tres adaptadores.
- Las rutas del panel se juntan en una lista de senales con filtros por familia, fuente, tipo y estado.

Orden sugerido, de menos a mas riesgo. Primero la tabla de detecciones y el registro comun, sin tocar las tablas
viejas. Despues la migracion de evidencias. Al final las consultas nuevas, de a una, cada una con su arnes.

### 1.6 Pendientes del panel de fraude

Lo que el panel todavia no tiene, junto en un solo lugar.

- La linea de tiempo de cada senal y de cada caso, cuantas veces y cuando se detecto. Depende de 1.2.
- La marca de reincidente en un caso descartado que vuelve a aparecer.
- Una sola lista de senales. Hoy son tres pestanas, Resenas, Compras y navegacion, y Login, cada una con su estado.
- Separar en la vista lo que viene de 127.0.0.1, para no culpar a la logica por datos de prueba en local.
- Un boton de recalcular casos para el admin. Desde de5de2a el agrupador corre al arrancar, pero no hay ruta para
  pedirlo despues.
- C1 (si una IP compartida une casos), C4 (la recencia), C9 (evidencia de un hallazgo ya descartado) y los puntos 2 y
  4 de `BACKEND-PENDIENTE.md`, que siguen abiertos.
- R-CASI-4 y el bono B.4 leen metricas que ningun detector escribe, asi que la regla sale en la pantalla sin poder
  cumplirse nunca.
- El motivo del descarte no tiene largo maximo en el backend y la pantalla lo corta en 500.

---

## 2. Dependencias entre bases, la base minima de cada flujo

### 2.1 Hoy

| Flujo | Redis | PostgreSQL | MongoDB | Que pasa si MongoDB se cae |
|---|---|---|---|---|
| Ver el carrito | lee | no | no | nada, funciona |
| Agregar al carrito | escribe | lee precio y stock | lee nombre, variante e imagen | no se puede agregar |
| Comprar | candado, lineas y reservas | la transaccion | lee nombre y estado de la variante antes del COMMIT | 503, no se compra. Es la fila 11 de `CONSISTENCIA-CHECKOUT.md` y la 12 de `PENDIENTES.md` |
| Publicar una oferta | registro de ofertas | escribe la oferta | lee el producto y recalcula agregados | no se publica |

MongoDB no participa del COMMIT y aun asi bloquea comprar. Es la dependencia que el profesor senala.

### 2.2 La propuesta del profesor, el nombre dentro de `oferta`

Copiar en `oferta` el nombre del producto, el de la variante, la imagen principal y si la variante esta activa. Con eso
publicar y comprar solo necesitan PostgreSQL y Redis. MongoDB sigue siendo el catalogo que se navega y se busca, y
recibe sus agregados despues, por el outbox que ya existe.

Cuando un producto cambia de nombre en MongoDB, un evento del outbox actualiza las ofertas de ese producto. Mientras
llega, una oferta puede mostrar el nombre anterior unos segundos, y el pedido guarda el nombre con el que se compro,
que es lo correcto para un comprobante.

Contra la industria.
- Guardar en la linea del pedido una copia del nombre y del precio al comprar es la practica comun de los sistemas de
  comercio. Mesh ya lo hace en `pedido_producto` (`nombre_producto`, `nombre_variante`, `nombre_vendedor`).
- Que cada parte del sistema tenga la copia de los datos que necesita para no depender de otra en su camino critico es
  la separacion por contextos del diseno guiado por dominio, y el modelo de lectura de CQRS.
- El costo es la duplicacion y un desfase corto. Se acepta porque el dato duplicado es de lectura para el comprador y
  la verdad del dinero y del stock sigue en una sola base.

Veredicto. Justificado. Saca a MongoDB del camino del dinero, cierra la fila 12 de pendientes y convierte una
dependencia que no estaba escrita en una decision escrita con su desfase medido.

---

## 3. El carrito que guarda lo que manda el frontend

### 3.1 Hoy

El carrito ya vive solo en Redis, un hash por cuenta, y cada linea ya es una foto en JSON con nombre, variante, imagen,
precio, vendedor y stock. La diferencia es quien arma la foto. Hoy la arma el backend al agregar, leyendo PostgreSQL y
MongoDB. Ver el carrito ya es Redis puro, y al cobrar el backend compara la foto contra el precio de hoy y avisa si
cambio.

### 3.2 La propuesta

El frontend manda la foto que ya tiene en pantalla (nombre, variante, imagen, precio que vio) junto con la oferta y la
cantidad. El backend valida la forma y el tamano y la guarda tal cual. Agregar al carrito toca solo Redis. La
existencia de la oferta se comprueba contra un conjunto de ofertas activas en Redis, que mantiene el mismo worker que
hoy lleva el registro de ofertas con descuento y venta relampago.

Reglas para que no se abuse.
- Lista cerrada de campos, un maximo de 2 KB por linea y 50 lineas por carrito.
- El precio que manda el frontend es solo lo que la persona vio. Nunca se cobra. Al comprar se revalida contra
  PostgreSQL, que es lo que ya hace hoy.
- El texto se guarda y se devuelve como texto. La pantalla no usa `{@html}`, asi que no abre la puerta a inyectar
  codigo.

Contra la industria.
- Los carritos en Redis o en almacenes clave valor son lo habitual en comercio con mucho trafico, por latencia y por
  que el carrito es desechable.
- La regla que no se negocia en ningun lado es no confiar en el precio del cliente al cobrar. La guia de OWASP sobre
  logica de negocio lo pone como el error clasico. Esta propuesta la respeta porque el cobro sigue leyendo PostgreSQL.
- Algunas plataformas grandes calculan el carrito del lado del servidor en cada cambio. Lo hacen porque aplican
  promociones complejas al carrito entero. Mesh aplica el descuento por oferta y lo recalcula al cobrar, asi que no lo
  necesita.

Veredicto. Migrar el carrito que ya existe, la misma clave y el mismo hash con otro contenido, y no crear un segundo
carrito. Dos carritos serian dos verdades sobre lo mismo. Con 2.2 y 3.2 juntos, agregar al carrito depende solo de
Redis y comprar depende solo de Redis y PostgreSQL. No se justifica que el carrito dependa de dos bases ademas de
Redis.

---

## 4. Elasticsearch, mas alla de la agregacion simple

### 4.1 Hoy

El indice de productos tiene busqueda por texto con tolerancia a errores, autocompletado con `bool_prefix` sobre
`nombre.escribiendo` y las facetas con agregaciones `terms`, `range` y `filter`. El analizador solo pasa a minusculas y
quita acentos. El indice de login usa `terms` y `cardinality` para el fraude retrospectivo y tiene la IP como tipo `ip`
y la ubicacion como `geo_point`. La version es 8.15 con licencia basica.

Contra lo que se usa en la industria es un uso correcto pero de entrada. Las facetas son lo minimo de cualquier tienda.

### 4.2 Lo que se propone dentro de la aplicacion

| Propuesta | Que usa de Elasticsearch | Donde se ve | Licencia basica |
|---|---|---|---|
| Buscar en espanol de verdad | analizador con raiz del espanol y sinonimos (portatil y laptop, celular y telefono) | la caja de busqueda | si |
| Ordenar por relevancia de negocio | `function_score` con `rank_feature` para ventas y nota, y decaimiento por antiguedad | resultados de busqueda | si |
| Quisiste decir | `phrase` suggester | cuando no hay resultados | si |
| Una fila por producto | `collapse` por producto cuando varias variantes coinciden | resultados | si |
| Avisame cuando baje | percolator, se guarda la busqueda de la persona y cada cambio de precio se prueba contra todas las busquedas guardadas | campana de avisos | si |
| Lo que distingue esta busqueda | `significant_terms` sobre categoria y marca | panel de tendencias | si |
| Tendencia con pendiente | `date_histogram` con `derivative` y `moving_fn` | panel del admin | si |
| Mapa de logins | `geotile_grid` sobre la ubicacion | pestana de login en Fraude | si |
| Perfil de riesgo por cuenta | transform continuo que arma un indice por cuenta (paises distintos, IPs distintas, fallos en 30 dias) | Fraude | si |
| Secuencias de ataque | EQL (E1 de la seccion 1) | Fraude | si |
| Deteccion de anomalias automatica | trabajos de aprendizaje automatico | no se propone | no, es de pago |

El percolator y EQL son los que mas lucen ante el profesor porque solo existen en un motor de busqueda. Una base
relacional no puede preguntar que busquedas guardadas coinciden con este documento nuevo.

---

## 5. Elasticsearch y la base vectorial

Hoy los vectores estan en PostgreSQL con pgvector, 768 dimensiones calculadas con Ollama, indice HNSW, 3,8 ms por
producto. Sirven para Parecidos a este y los mantiene el ETL al arrancar y el worker de David cada 3 horas.

Elasticsearch 8.15 tambien guarda vectores (`dense_vector`) y busca vecinos con HNSW, con licencia basica. La propuesta
es usar cada uno para lo que hace mejor, sin duplicar funciones.

- pgvector sigue siendo la fuente del vector y de Parecidos a este. Ahi el vector vive junto a la llave del producto,
  dentro de la transaccion, y ya esta medido.
- Elasticsearch recibe una copia del vector en el indice de productos solo para la busqueda hibrida de la caja de
  busqueda. Una busqueda como algo para correr en la lluvia no tiene palabras en comun con chaqueta impermeable
  deportiva, y el vector si la encuentra. En Elasticsearch la busqueda por texto, las facetas y los filtros ya estan
  en el mismo indice, asi que el vecino mas cercano se puede filtrar por categoria y precio en la misma peticion.
- La copia la lleva `etl/extraer_busqueda.js`, que ya lee de PostgreSQL. Son unos 9,5 MB para 3105 productos.
- La mezcla de puntajes se hace con la combinacion lineal de consulta y `knn`, que es basica. La fusion por rango
  reciproco hay que confirmarla contra la licencia de 8.15 antes de prometerla.
- Para fraude, el vector del texto de las resenas en pgvector es la alternativa a E3. Encuentra resenas que dicen lo
  mismo con otras palabras, que `more_like_this` no ve.

---

## 6. Como reescribir las decisiones del informe

Las decisiones actuales dicen que base se eligio y por que es buena en general. Lo que pide el profesor es la
dependencia concreta. Se propone que cada decision tenga siempre estas partes.

- El flujo que toca, por ejemplo comprar, agregar al carrito o detectar un anillo.
- Las bases que lee y las que escribe, y cuales estan dentro de la transaccion.
- Que pasa si cada una se cae, medido con `pruebas/falla_checkout.sh` o con su arnes.
- La alternativa descartada, con el numero que la descarto.
- La practica de la industria contra la que se compara.

Decisiones nuevas que saldrian de este documento.

| Id | Decision |
|---|---|
| ADR-12 | Comprar y publicar sin MongoDB, con el nombre en `oferta` |
| ADR-13 | El carrito guarda la foto del cliente y cobra con PostgreSQL |
| ADR-14 | Un solo modelo de senales para todas las fuentes de fraude |
| ADR-15 | Las detecciones como serie de tiempo en ClickHouse |
| ADR-16 | Grafo de identidad en Neo4j para armar los casos |
| ADR-17 | Busqueda hibrida en Elasticsearch con pgvector como fuente del vector |
