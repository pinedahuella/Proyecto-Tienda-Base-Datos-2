# Que pasa en Mesh cuando se cae una base de datos

Mesh usa seis bases de datos y cada una tiene un trabajo distinto. Aqui esta lo
que pasa con la tienda cuando se apaga cada una, medido apagandolas de verdad.
Para cada base se dice que se ve en la pagina, de donde sale lo que esa base
daba, que se pierde y como verlo con los propios ojos en la pagina, en el
registro del backend y en la base.

El profesor pidio que, si se apaga una base, la tienda siga respondiendo con las
que quedan, y que se pueda ver en vivo y no solo con un script. Desde el 20 de
octubre de 2026 cada base tiene un respaldo en las otras, y hay una forma de
apagar y prender cada una en vivo, desde el panel de comandos, mientras la tienda
esta abierta.

## Resumen

| Base | Para que sirve | Se puede comprar | Si se cae, lo que daba sale de | Que se pierde |
|---|---|---|---|---|
| PostgreSQL | Pedidos, pagos, stock, cuentas y el carrito | No, avisa y no queda nada a medias | La sesion abierta sigue con su token, el perfil y el carrito con la copia de Redis, el catalogo y la ficha de MongoDB | Nada. No se puede pagar, agregar al carrito ni iniciar sesion nueva hasta que vuelva |
| MongoDB | La ficha completa de cada producto | Si | La copia del catalogo en PostgreSQL, sin las caracteristicas | El registro de las entradas a la tienda de ese rato |
| Redis | Rankings ya calculados, copia rapida del carrito | Si | Los rankings se calculan en el momento en ClickHouse, las ofertas destacadas salen de PostgreSQL y el carrito de PostgreSQL | Los contadores que vigilan entradas sospechosas de ese rato |
| Elasticsearch | Buscador | Si | La copia del catalogo en PostgreSQL, con los mismos filtros y tolerando errores de tecleo | Nada, los cambios esperan en una cola |
| Neo4j | Recomendaciones y anillos de fraude | Si | Para ti y quienes lo compraron tambien llevaron salen de los pedidos en PostgreSQL | Nada, los cambios esperan en una cola |
| ClickHouse | Vistas, busquedas y tendencias | Si | Lo mas vendido y lo mas visto siguen saliendo de Redis. Viste hace poco y las tendencias del administrador no tienen otra fuente y avisan | Las vistas, busquedas y agregados al carrito de ese rato |

La idea que lo explica todo es que PostgreSQL es la verdad. El dinero, el stock
y los pedidos solo se escriben ahi, en una transaccion. Las demas bases tienen
copias o datos de apoyo, y cada copia tiene de donde rehacerse, asi que cuando
una se cae la tienda sigue mostrando lo mismo, a veces con un poco menos de
detalle, y no pierde ventas.

Ninguna pantalla nombra la base que se cayo. A quien compra no le sirve saberlo,
asi que cuando algo de verdad no se puede (pagar con PostgreSQL caida, por
ejemplo) ve un aviso comun que dice que no se pudo completar y que intente en un
momento. El nombre de la base queda en la consola del navegador y en el registro
del backend, para quien tenga que arreglarlo.

## Como se apaga una base en vivo

Hay dos formas, y las dos sirven con las bases en esta computadora o en otra.

La facil es el panel de comandos, en el grupo Caida de una base.

1. Preparar la demo de caidas. Levanta un interruptor entre el backend y cada
   base y reinicia el backend apuntado a el. Tarda unos tres minutos, lo que
   tarda el backend en arrancar.
2. Apagar una base. Se elige cual y como. Apagada es lo que pasa con un docker
   stop, la base rechaza la conexion al instante. Congelada es la red cortada a
   mitad de camino, la base acepta y no contesta, y el backend espera su limite
   antes de darla por caida. Es lo que se vio el 19 de octubre apagando bases en
   la otra computadora por la red.
3. Abrir la tienda y mirar que sigue saliendo.
4. Prender la base. El backend la vuelve a usar solo, a los 15 segundos, sin
   reiniciar nada.
5. Terminar la demo de caidas. El backend vuelve a hablar directo con las bases.

Lo mismo desde una terminal.

```
.\remoto\caidas.ps1 -Accion levantar
.\remoto\caidas.ps1 -Accion apagar -Base redis
.\remoto\caidas.ps1 -Accion congelar -Base mongo
.\remoto\caidas.ps1 -Accion prender -Base redis
.\remoto\caidas.ps1 -Accion estado
.\remoto\caidas.ps1 -Accion quitar
```

La otra forma, con las bases en esta computadora, es parar el contenedor de
verdad, por ejemplo docker stop mesh-redis, y despues docker start mesh-redis.
El backend lo ve igual que una base apagada con el interruptor.

Y hay una prueba que hace todo esto sola, base por base, y comprueba cada cosa
de este documento.

```
node pruebas/caidas.mjs                 las seis, apagadas
node pruebas/caidas.mjs --congeladas    las seis, congeladas
```

El 20 de octubre dio 51 comprobaciones bien y ninguna mal en las dos formas,
con las bases en la computadora de Jose David.

## Como se mira cada cosa

- En la pagina. Se abre la tienda y se mira que sigue saliendo, o que aviso sale.
- En el registro del backend. Cada base tiene un cortacircuitos. Cuando una no
  contesta queda una linea que dice que no responde y que hace una pausa de 15
  segundos, y cuando vuelve otra que dice que volvio. Durante la pausa el
  backend ni le pregunta, y va directo al respaldo, para que nadie espere lo que
  tarda una base caida en decir que no esta.

  ```
  WARN [Cortacircuitos] Redis no responde (Command timed out): pausa de 15 s
  LOG  [Cortacircuitos] Redis volvio
  ```

  Ademas cada respaldo deja su propia linea al entrar y al salir, por ejemplo
  [CatalogoRespaldo] para MongoDB, [BuscadorRespaldo] para Elasticsearch,
  [RecomendacionesRespaldo] para Neo4j y [SesionGuard] para PostgreSQL.
- En el backend, la ruta GET /db/cortacircuitos dice que base ve caida y desde
  cuando. Es para quien mantiene la tienda y solo contesta con la cuenta del
  administrador, la pagina no la usa.
- En la base. Lo que tiene que llegar a otra base y no puede perderse se anota en
  una cola de PostgreSQL mientras la otra base no esta. Se ve cuantas esperan
  con una consulta, y se ve como bajan a cero cuando la base vuelve.

## PostgreSQL

Es la base que manda. Guarda el pedido, el pago, el movimiento de stock, las
cuentas y el carrito de verdad.

Que se ve en la tienda.

- Quien ya habia entrado sigue dentro. Su sesion es un token firmado que dura
  hasta dos horas, y cuando PostgreSQL no contesta el backend se lo cree en vez
  de preguntarle a la base si la cuenta sigue activa. Si PostgreSQL contesta que
  la cuenta esta suspendida, se corta como siempre. Solo se le cree cuando no se
  pudo preguntar.
- La cabecera lo sigue saludando, porque al entrar se guarda en Redis una copia
  del perfil (nombre y correo, sin la contrasena), que vence con el token.
- Ve su carrito, que sale de la copia de Redis.
- El catalogo, la ficha, el buscador y las recomendaciones siguen saliendo de
  MongoDB, Elasticsearch, Redis y Neo4j.
- La ficha de un producto se ve, pero en lugar de los vendedores dice que ahora
  no se puede mostrar quien lo vende ni comprarlo. Los vendedores y sus precios
  viven en PostgreSQL.
- Al pagar sale el aviso de que no se pudo completar la compra y que el carrito
  sigue guardado. Agregar al carrito y entrar con otra cuenta tampoco se pueden
  hasta que vuelva.

Que se midio el 20 de octubre, con una sesion abierta antes de apagarla.

- Apagada, la sesion, el carrito, la ficha, el catalogo, para ti, lo mas
  vendido, las ofertas, el buscador y quienes lo compraron tambien llevaron
  contestaron bien en menos de 1.5 segundos. Pagar, agregar al carrito e iniciar
  sesion contestaron 503 en dos decimas.
- Congelada, la primera peticion con sesion tardo 3.4 segundos (lo que se
  espera para dar la base por caida) y las demas lo mismo que apagada.
- El 18 de octubre se midio la compra con PostgreSQL apagada a la hora de pagar.
  La compra no se hizo (503), antes y despues habia 707 pedidos, 707 pagos,
  16316 movimientos de stock y 8 unidades de la oferta, el carrito siguio entero,
  y al prenderla la misma compra se hizo y el stock bajo de 8 a 7.

Que se pierde. Nada. Una compra se hace entera o no se hace.

Que no se hace a proposito. Iniciar sesion sin PostgreSQL. Se podria copiar las
cuentas a otra base, pero las contrasenas quedarian en dos lugares que proteger,
y una cuenta suspendida podria entrar con la copia vieja. Quien ya estaba dentro
sigue, y quien no, puede mirar la tienda sin cuenta.

Como verlo. En el registro sale una linea de [SesionGuard] que dice que las
sesiones abiertas se aceptan por su token, como mucho una por minuto.

## MongoDB

Tiene el catalogo con la ficha completa de cada producto, sus fotos y sus
caracteristicas. Tambien guarda el registro de seguridad de cada entrada a la
tienda.

PostgreSQL guarda ademas una copia minima de cada producto. Es el nombre, el
estado, la categoria, la descripcion y cada variante con su foto de portada. La
mantiene al dia el mismo backend, que escribe en las dos bases en la misma
operacion cada vez que un vendedor crea o cambia un producto. Los precios, el
stock, los vendedores y las notas ya vivian en PostgreSQL.

Que se ve en la tienda. Casi nada cambia. El catalogo, sus filtros, la ficha de
cada producto, las categorias, para ti, quienes lo compraron tambien llevaron y
los productos parecidos salen de la copia. En la ficha falta la pestana de
detalles (las caracteristicas, que solo estan en MongoDB), y en su lugar dice
Algunos detalles de este producto no se pueden mostrar ahora. Filtrar por una
caracteristica, como la memoria de una laptop, avisa que no se pudo cargar.

Que se midio.

- Se pidieron 71 cosas a la tienda (catalogo con todos sus filtros y paginas,
  35 fichas, categorias, recomendaciones y tendencias) con MongoDB y sin
  MongoDB, y se compararon campo por campo. Salieron 362 comparaciones iguales y
  1 distinta, la del filtro por caracteristica, que avisa a proposito. El tiempo
  de las 71 fue casi el mismo, 12.4 segundos con MongoDB y 12.6 sin MongoDB.
- MongoDB se apago con la tienda en uso. La primera ficha tardo 3.2 segundos,
  lo que tarda en rendirse la conexion, y las siguientes 70 milesimas. Al
  prenderla otra vez, a los 15 segundos las fichas volvieron a salir de MongoDB,
  sin reiniciar nada.
- Congelada (la red cortada a mitad de camino), la primera ficha tardaba entre
  9 y 15 segundos, porque la conexion ya abierta esperaba a que el driver notara
  la caida. Desde el 20 de octubre la consulta del catalogo tiene su propio
  limite de 3 segundos, y la primera ficha tarda entre 3.2 y 3.7 segundos.
- Antes de la copia (19 de octubre, con MongoDB apagada en la otra computadora)
  se compro igual, la compra se hizo en menos de 2 segundos, y al volver MongoDB
  los cambios que esperaban en su cola llegaron solos en 20 segundos.

En el panel de la tienda y del admin (desde el 20 de octubre). Las ofertas
viven en PostgreSQL, asi que se ven, se abren y se cambian igual. Precio,
existencias, descuento, venta relampago, pausar y publicar una oferta nueva
sobre un producto que ya existe. El nombre de cada producto sale de la copia.
La lista del catalogo tambien sale, con su busqueda por nombre. Antes las dos
pantallas decian que no se pudo cargar, y editar una oferta la guardaba pero
contestaba que habia fallado.

Que se pierde. El registro de seguridad de las entradas de ese rato. La persona
entra igual, pero su entrada no queda anotada. Tampoco se pueden crear ni cambiar
productos ni ver su historial mientras MongoDB no esta, porque la ficha completa
y sus cambios viven ahi.

Como verlo.

- En la pagina, abrir un producto cualquiera y leer el aviso de los detalles.
- En el registro, [CatalogoRespaldo] dice que el catalogo sale de la copia y
  despues que MongoDB volvio.
- En la base, la copia es la tabla producto_catalogo.

  ```
  SELECT estado, count(*) FROM producto_catalogo GROUP BY estado
  ```

## Redis

Tiene los rankings ya calculados (lo mas vendido, lo mas visto, se compran
juntos y quienes vieron esto tambien vieron), las ofertas destacadas ya armadas,
una copia rapida del carrito y los contadores que vigilan las entradas
sospechosas. Nada de eso es la verdad, son copias para contestar rapido.

Que se ve en la tienda. Lo mismo que con Redis arriba.

- Los cuatro rankings los calcula en ese momento ClickHouse, con la misma
  consulta que cada 10 minutos los deja guardados en Redis. Lo calculado se
  recuerda un minuto, para no repetirle la consulta a ClickHouse con cada
  visita.
- Las dos vitrinas de ofertas, con descuento y en venta relampago, se arman
  desde la tabla de ofertas de PostgreSQL, que es de donde salen.
- El carrito se lee de PostgreSQL, que es donde esta el de verdad, y la pagina
  del carrito dice que puede ir un poco mas lento pero funciona igual. Se puede
  comprar.

Que se midio el 20 de octubre.

- Se pidieron las ocho vitrinas con Redis y sin Redis y se compararon. Salieron
  iguales las ocho, los mismos productos en el mismo orden.
- Apagada, las vitrinas y el carrito contestaron en 60 a 115 milesimas.
  Congelada, la primera peticion tardo 3.2 segundos y las demas lo mismo que
  apagada. Antes de este cambio los rankings desaparecian y cada uno tardaba 10
  segundos en rendirse.
- Al volver Redis, el backend se reconecto solo, las ventas relampago se
  reconstruyeron desde PostgreSQL y los rankings guardados seguian ahi, porque
  Redis los guarda en disco.
- Esa comparacion encontro algo que estaba mal con Redis arriba. La copia de las
  ofertas destacadas no se actualizaba cuando una compra bajaba el stock, y la
  vitrina podia mostrar unidades que ya no habia. Ahora se refresca con cada
  cambio de una oferta.

Que se pierde. Los contadores de entradas sospechosas de ese rato. La persona
entra igual, pero esos intentos no cuentan para la deteccion de fraude.

Como verlo.

- En la pagina, la portada con sus vitrinas completas.
- En el registro, [Cortacircuitos] dice que Redis no responde, y al volver salen
  Conectado a Redis y Redis volvio.

## Elasticsearch

Es el buscador de productos y el de ofertas del vendedor, y guarda los avisos de
los compradores (avisame cuando haya algo asi).

Que se ve en la tienda. El buscador sigue funcionando. Sale de la copia del
catalogo en PostgreSQL, con la misma regla para comparar texto que el indice de
Elasticsearch. No distingue tildes ni mayusculas, tolera errores de tecleo con la
misma tolerancia (labtop encuentra laptop) y da mas peso a las palabras raras que
a las que estan en todos lados. Los filtros del panel y sus conteos tambien
salen, calculados igual. Lo unico que falta es el tal vez quisiste decir.

Que se midio el 20 de octubre.

- La misma busqueda con y sin Elasticsearch, para laptop, labtop, audifonos,
  camisa, laptop gamer, silla de comedor y asdffff. Los totales y los conteos de
  todos los filtros salieron identicos, y los primeros resultados son los mismos
  productos. Mas abajo cambia el orden entre productos que se llaman igual.
- Sin Elasticsearch cada busqueda tardo entre 50 y 760 milesimas. Congelada, la
  primera tardo 3.5 segundos y las siguientes lo mismo que apagada. Antes de
  este cambio el buscador avisaba a los 22 segundos.
- Con Elasticsearch apagada una compra no puede llegar al buscador. Queda
  anotada en una cola de PostgreSQL, y al volver la cola bajo a 0 sola en un
  minuto (medido el 19 de octubre).

Que se pierde. Nada, los cambios esperan en la cola. Lo que no se puede mientras
no esta es crear un avisame (la comparacion de cada oferta contra los avisos
vive en Elasticsearch) y buscar entre las ofertas en el panel del vendedor. El
vendedor sigue viendo y cambiando sus ofertas en la lista de siempre.

Como verlo.

- En la pagina, buscar cualquier cosa, con y sin filtros.
- En el registro, [BuscadorRespaldo] dice que el buscador sale de la copia, y
  despues que Elasticsearch volvio.
- En la base, la cola de ofertas que esperan el buscador.

  ```
  SELECT count(*) FROM evento_oferta WHERE procesado_en IS NULL
  ```

## Neo4j

Tiene el grafo de quien compro que y quien califico a quien. De ahi salen las
recomendaciones para ti y quienes lo compraron tambien llevaron, y la busqueda
de anillos de resenas falsas.

Que se ve en la tienda. Lo mismo. Cada compra del grafo es una linea de un
pedido comprado, enviado o entregado de PostgreSQL, asi que las dos
recomendaciones se pueden preguntar ahi, con los mismos criterios y el mismo
orden. Lo que no sale es la revision del grafo en el panel del administrador,
que justamente compara Neo4j con PostgreSQL.

Que se midio el 20 de octubre.

- Para ti de dos cuentas y quienes lo compraron tambien llevaron de seis
  productos, con y sin Neo4j. Salieron iguales las ocho, con los mismos
  productos, los mismos conteos y el mismo porque.
- Sin Neo4j contestaron en unas 90 milesimas cada una. Congelada, la primera
  tardo 3 segundos.
- El 19 de octubre, con Neo4j apagada se compro, la compra quedo en una cola de
  PostgreSQL y al volver la cola bajo a 0 sola en 15 segundos. La revision del
  grafo dio que cuadra con PostgreSQL.

Que se pierde. Nada, las compras y las resenas esperan en la cola.

Como verlo.

- En la pagina, entrar con una cuenta y mirar para ti en la portada, y abrir un
  producto para ver quienes lo compraron tambien llevaron.
- En el registro, [RecomendacionesRespaldo] dice que salen de los pedidos.
- En la base, la cola de compras que esperan el grafo.

  ```
  SELECT count(*) FROM evento_grafo_compra WHERE procesado_en IS NULL
  ```

## ClickHouse

Guarda los eventos de la tienda para analizarlos. Las vistas de cada producto,
las busquedas, los agregados al carrito y una copia de las compras. De ahi salen
las tendencias del administrador, los productos vistos hace poco y los rankings
que despues se guardan en Redis.

Que se ve en la tienda.

- Lo mas vendido, lo mas visto y se compran juntos siguen saliendo, porque se
  calcularon antes y estan guardados en Redis.
- Desaparece viste hace poco y las tendencias del administrador avisan que no se
  pudieron cargar. Las vistas solo viven en ClickHouse, no hay otra base que las
  tenga, y por eso no tienen respaldo.

Que se midio el 19 y el 20 de octubre.

- Lo mas vendido, lo mas visto y se compran juntos contestaron bien.
- Viste hace poco y las tendencias del administrador contestaron 503.
- Congelada, viste hace poco tardaba 8 segundos en avisar, el limite del
  cliente de ClickHouse. Desde el 20 de octubre esa consulta tiene 3 segundos, y
  avisa entre 3.0 y 3.5 segundos.
- Se registro una vista de producto. La pagina recibio que estaba registrada,
  pero al volver ClickHouse esa vista no estaba.

Que se pierde. Las vistas, las busquedas y los agregados al carrito de ese rato.
Se mandan sin esperar respuesta y sin cola, a proposito, para que quien compra
no espere ni vea un error por algo que solo sirve para analizar. La copia de las
compras no se pierde, porque sale de PostgreSQL y la vuelve a traer la carga de
compras.

Como verlo.

- En la pagina, entrar con una cuenta que ya miro productos y ver que falta
  Viste hace poco.
- En el registro, [Cortacircuitos] dice que ClickHouse no responde, y salen
  lineas de EventosService que dicen que no se pudo registrar la vista.

## Por que la tienda aguanta

- El dinero y el stock viven en una sola base, PostgreSQL, y se escriben en una
  transaccion. Si esa base no esta, no se cobra nada. Si esta, la compra no
  depende de las demas.
- Lo que tiene que llegar a otra base y no puede perderse, como una compra o una
  resena para el grafo o un cambio de oferta para el buscador, se anota primero
  en una cola de PostgreSQL. Cuando la otra base vuelve, se procesa sola.
- Cada copia sabe de donde se rehace. Los rankings de Redis salen de ClickHouse,
  las ofertas destacadas de PostgreSQL, el grafo de los pedidos, y el buscador y
  el catalogo de la copia del catalogo. Si la copia no esta, se pregunta a la
  fuente en el momento.
- Cada base tiene un cortacircuitos. La primera peticion despues de una caida
  espera lo que tarda la base en no contestar (como mucho unos 3 segundos en lo
  que pide la pagina), y durante los 15 segundos siguientes el backend ni le
  pregunta y va directo al respaldo. Cuando vuelve, la usa otra vez sola.
- Lo que solo sirve para analizar, como una vista o una busqueda, se manda sin
  esperar. Si la base no esta se pierde ese dato, pero la persona que esta
  comprando no espera ni ve un error.
- La sesion abierta se mantiene sin PostgreSQL porque el token esta firmado. Lo
  que no se mantiene es lo que tiene que escribir en PostgreSQL, como pagar.

## Guion para mostrarlo en clase

Unos diez minutos. Antes de empezar, con todo arriba, se corre Preparar la demo
de caidas en el panel de comandos y se espera a que el backend conteste. Se deja
abierta la tienda en una pestana con la cuenta compradora.norte@mesh.com, el
panel de comandos en otra y el registro del backend a la vista.

1. Redis. Se apaga y se recarga la portada. Lo mas vendido, lo mas visto, se
   compran juntos y las dos vitrinas de ofertas siguen ahi, iguales. Se abre el
   carrito, dice que puede ir mas lento y se puede comprar. En el registro sale
   que Redis no responde. Se prende y a los 15 segundos sale que volvio.
2. MongoDB. Se apaga y se abre un producto. La ficha sale completa con el aviso
   de que algunos detalles no se pueden mostrar, y sin la pestana de detalles.
   El catalogo y sus filtros siguen. Filtrar por la memoria de una laptop avisa.
   Se prende.
3. Elasticsearch. Se apaga y se busca labtop. Salen las laptops, con el panel de
   filtros y sus conteos. Se elige la categoria Laptops y el panel se recorta a
   esa categoria, porque el filtro va en la busqueda. Se busca asdffff y sale el
   aviso de que no se encontro nada, con productos que pueden interesar. Se
   prende.
4. Neo4j. Se apaga y se mira para ti en la portada, que sigue con sus
   productos, y en un producto quienes lo compraron tambien llevaron. Salen de
   los pedidos en PostgreSQL. Se prende.
5. ClickHouse. Se apaga y se mira la portada. Lo mas vendido sigue (esta
   guardado en Redis) y desaparece viste hace poco. Es la unica base cuyas
   vistas no estan en otro lado, y se explica que se pierden las vistas de ese
   rato a proposito, para que nadie espere por algo que solo sirve para
   analizar. Se prende.
6. PostgreSQL al final, porque es la que manda. Se apaga y se recarga la
   portada, que sigue con la sesion abierta. Se abre un producto, que dice que
   ahora no se puede comprar. Se intenta pagar el carrito y sale que no se pudo
   y que el carrito sigue guardado. Se cierra sesion y se intenta entrar, y dice
   que ahora no se puede iniciar sesion pero que se puede seguir mirando la
   tienda. Se prende y la compra se hace.

Si algo falla en vivo, Terminar la demo de caidas deja el backend hablando directo
con las bases.

## Una busqueda que no encuentra nada

Tambien lo pidio el profesor. Si alguien busca algo sin sentido, como asdffff,
la pagina no queda vacia. Dice que no encontro nada y debajo ofrece productos
que pueden interesar. Los elige Elasticsearch, con una segunda consulta mas
tolerante que la de la busqueda (hasta dos letras distintas en cualquier
palabra, y tambien contra el nombre de la categoria). Lo que se parece a lo
escrito, aunque sea de lejos, sale primero, y si nada se parece, el mismo motor
ordena los productos activos por resenas, nota y existencias. Siempre trae algo.

Sin Elasticsearch los elige el backend. Primero los mas cercanos por
significado (los vectores de los productos en PostgreSQL), y si eso no se
puede, lo mas vendido, y si tampoco, los productos con mas resenas. La respuesta
dice de donde salieron (`sugeridos_desde`).

Esos productos van aparte de los resultados. La busqueda se sigue contando como
sin resultados, y asi se guarda en ClickHouse, para que el reporte de busquedas
sin resultados del administrador siga mostrando lo que la gente busca y la
tienda no tiene.

## Como se midio

- El 18 de octubre, PostgreSQL con pruebas/falla_checkout.sh en una base de
  prueba. Apaga cada base a la hora de pagar, una por una, y compara pedidos,
  pagos, movimientos de stock y stock antes y despues. Dio 32 comprobaciones bien
  y ninguna mal.
- El 19 de octubre, las bases se apagaron por rondas en la computadora de Jose
  David, llamando a cada funcion de la tienda con cada ronda de bases apagadas y
  haciendo en cada ronda una compra de una unidad que despues se cancelo.
- El 20 de octubre, con el interruptor, cada base apagada y congelada una por
  una, comparando cada respuesta con la que da la tienda con todo arriba, y con
  pruebas/caidas.mjs, que dio 51 comprobaciones bien y ninguna mal en las dos
  formas.
