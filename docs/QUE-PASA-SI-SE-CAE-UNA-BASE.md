# Que pasa en Mesh cuando se cae una base de datos

Mesh usa seis bases de datos y cada una tiene un trabajo distinto. Aqui esta lo
que pasa con la tienda cuando se apaga cada una, medido apagandolas de verdad.
Para cada base se dice que se ve en la pagina, que sigue funcionando, que se
pierde y como verlo con los propios ojos en la pagina, en el registro del
backend y en la base.

Las bases vivian en otra computadora conectada por la red, y la tienda en esta.
El 19 de octubre de 2026 en la noche se apagaron por rondas, primero Neo4j y
ClickHouse, despues Redis y Elasticsearch, y despues MongoDB. PostgreSQL se
apago el 18 de octubre con una prueba automatica que se explica al final.

## Resumen

| Base | Para que sirve | Se puede comprar | Que se ve en la tienda | Que se pierde |
|---|---|---|---|---|
| PostgreSQL | Pedidos, pagos, stock, cuentas y el carrito | No | La compra no se hace y avisa | Nada, no queda nada a medias |
| MongoDB | Ficha de cada producto | Si | El catalogo y la ficha avisan que no se pudieron cargar | El registro de entradas de ese rato |
| Redis | Rankings ya calculados, copia rapida del carrito | Si | Desaparecen lo mas vendido, lo mas visto y se compran juntos | Nada |
| Elasticsearch | Buscador | Si | El buscador avisa que no se pudo cargar | Nada, los cambios esperan en una cola |
| Neo4j | Recomendaciones y anillos de fraude | Si | Para ti se cambia por lo mas visto, y desaparece quienes lo compraron tambien llevaron | Nada, los cambios esperan en una cola |
| ClickHouse | Vistas, busquedas y tendencias | Si | Desaparece viste hace poco, y las tendencias del administrador avisan | Las vistas, busquedas y agregados al carrito de ese rato |

La idea que lo explica todo es que PostgreSQL es la verdad. El dinero, el stock
y los pedidos solo se escriben ahi, en una transaccion. Las demas bases tienen
copias o datos de apoyo, asi que cuando una se cae la tienda pierde una funcion
pero no pierde ventas.

Ninguna pantalla nombra la base que se cayo. A quien compra no le sirve saberlo,
asi que ve un aviso comun, No pudimos cargar esto ahora, intenta de nuevo en un
momento, con un boton para reintentar. El nombre de la base queda en la consola
del navegador y en el registro del backend, para quien tenga que arreglarlo.

## Como se mira cada cosa

Hay tres lugares donde se ve lo que pasa, y en cada base se dice que buscar en
cada uno.

- En la pagina. Se abre la tienda y se mira que seccion falta o que aviso sale.
- En el registro del backend. Es lo que el servidor va escribiendo mientras
  corre. Cada vez que una base no contesta deja una linea con el nombre del
  servicio que fallo.
- En la base. Algunas cosas que no pueden perderse se anotan en una cola de
  PostgreSQL mientras la otra base no esta. Se ve cuantas esperan con una
  consulta, y se ve como bajan a cero cuando la base vuelve.

## PostgreSQL

Es la base que manda. Guarda el pedido, el pago, el movimiento de stock, las
cuentas y el carrito de verdad.

Que se ve en la tienda. Al pagar, la compra no se hace y sale el aviso de que no
se pudo completar. El carrito sigue lleno para volver a intentarlo.

Que se midio, apagandola a la hora de pagar con un carrito listo.

- La compra no se hizo (respuesta 503).
- No quedo nada a medias. Antes y despues habia 707 pedidos, 707 pagos, 16316
  movimientos de stock y 8 unidades de la oferta.
- El carrito siguio entero, con su producto.
- Al prender PostgreSQL otra vez, la misma compra se hizo y el stock bajo de 8
  a 7.

Que se pierde. Nada. Una compra se hace entera o no se hace.

## MongoDB

Tiene el catalogo con la ficha completa de cada producto, sus fotos y sus
caracteristicas. Tambien guarda el registro de seguridad de cada entrada a la
tienda (quien entro, desde donde y si la clave estaba bien). Lo que hace falta
para cobrar ya esta copiado en PostgreSQL.

Que se ve en la tienda.

- En la portada, la lista de productos del catalogo cambia por el aviso de que
  no se pudo cargar, con el boton Reintentar. Arriba siguen saliendo lo mas
  vendido, las ofertas con descuento y se compran juntos.
- Al abrir un producto, la ficha entera cambia por el mismo aviso.
- El buscador sigue encontrando productos, porque tiene su propia copia.

Que se midio.

- Se entro a la cuenta en medio segundo y se compro una unidad. La compra se
  hizo (respuesta 201, pedido 1065) en menos de 2 segundos y el stock bajo de 6
  a 5.
- La lista del catalogo, la ficha, para ti y quienes lo compraron tambien
  llevaron contestaron 503 despues de 3 segundos.
- El buscador, el carrito, lo mas vendido, lo mas visto, se compran juntos, el
  reporte de ventas y los casos de fraude contestaron bien.

Que se pierde. El registro de seguridad de las entradas que se hicieron en ese
rato. La persona entra igual, pero su entrada no queda anotada, y por eso los
detectores de fraude de entradas no la ven.

Como verlo.

- En la pagina, abrir un producto cualquiera.
- En el registro del backend salen lineas de `LogService` que dicen que no se
  pudo guardar el evento de autenticacion, una por cada entrada perdida, y
  lineas de `EventoProductoSyncService` que dicen que Mongo no responde y que se
  reintenta en la proxima corrida.

## Redis

Tiene los rankings ya calculados (lo mas vendido, lo mas visto y se compran
juntos), una copia rapida del carrito y los contadores que vigilan las entradas
sospechosas.

Que se ve en la tienda. En la portada desaparecen las secciones Lo mas vendido
ahora, Lo mas visto y Se compran juntos, sin ningun aviso. Al abrir un producto
desaparece quienes vieron esto tambien vieron. Todo lo demas se ve normal y se
puede comprar.

Que se midio, con Redis y Elasticsearch apagadas a la vez.

- Se entro a la cuenta en 2 segundos y se compro una unidad. La compra se hizo
  (respuesta 201, pedido 1064) en 1 segundo y el stock bajo de 6 a 5.
- Lo mas vendido, lo mas visto, se compran juntos y tambien vieron contestaron
  503 despues de 10 segundos.
- La lista del catalogo, los productos parecidos, el carrito, para ti, quienes
  lo compraron tambien llevaron, el reporte de ventas y los casos de fraude
  contestaron bien.
- Al volver Redis, el backend se reconecto solo y los rankings seguian ahi,
  porque Redis los guarda en disco. Las 3 secciones volvieron sin recalcular
  nada.

Que se pierde. Nada. Mientras Redis no esta, el carrito se lee de PostgreSQL,
que es donde esta el de verdad, y la pagina del carrito dice que puede ir un
poco mas lento pero funciona igual.

Como verlo.

- En la pagina, la portada sin sus tres secciones de arriba.
- En el registro del backend salen lineas de `[Redis]` que dicen que fallo
  hablando con Redis, y al volver una que dice conectado a Redis.

## Elasticsearch

Es el buscador de productos y el de ofertas del vendedor, y guarda los avisos de
los compradores (avisame cuando haya algo asi).

Que se ve en la tienda. Al buscar algo en la barra de arriba sale el aviso de
que no se pudo cargar. Todo lo demas se ve normal y se puede comprar.

Que se midio.

- Buscar laptop contesto 503 despues de 22 segundos.
- En la compra del pedido 1064, el cambio de stock de esa oferta no podia
  llegar al buscador. Quedo anotado en una cola de PostgreSQL, que paso de 0 a
  1 esperando.
- Al volver Elasticsearch, la cola bajo a 0 sola en un minuto, y en el buscador
  la oferta quedo con el mismo stock que en PostgreSQL.
- El 18 de octubre se midio tambien crear un aviso con Elasticsearch apagada.
  No se pudo, y en PostgreSQL no quedo un aviso a medias. Al volver, crear
  avisos funciono otra vez sin reiniciar nada.

Que se pierde. Nada. Lo que tenia que llegar al buscador espera en la cola.

Como verlo.

- En la pagina, buscar cualquier cosa.
- En el registro del backend salen lineas de `BuscadorSyncService` y de
  `EventoOfertaSyncService` que no pueden llegar a Elasticsearch.
- En la base, la cola de ofertas que esperan el buscador.

  ```
  SELECT count(*) FROM evento_oferta WHERE procesado_en IS NULL
  ```

## Neo4j

Tiene el grafo de quien compro que y quien califico a quien. De ahi salen las
recomendaciones para ti y quienes lo compraron tambien llevaron, y la busqueda
de anillos de resenas falsas.

Que se ve en la tienda.

- En la portada, la seccion Para ti se llena con Lo mas visto. La pagina tiene
  ese plan B a proposito, asi que la persona no ve un hueco ni un error.
- Al abrir un producto desaparece quienes lo compraron tambien llevaron.
- En el panel del administrador, en Fraude, no aparece la revision del grafo.

Que se midio, con Neo4j y ClickHouse apagadas a la vez.

- Se compro una unidad. La compra se hizo (respuesta 201, pedido 1063) en 0.8
  segundos y el stock bajo de 6 a 5.
- Para ti, quienes lo compraron tambien llevaron y la revision del grafo
  contestaron 503 despues de 8 segundos.
- La compra no se perdio para el grafo. Quedo anotada en una cola de
  PostgreSQL, que paso de 1 a 2 esperando.
- Al volver Neo4j, la cola bajo a 0 sola en 15 segundos, sin reiniciar nada.
  La revision del grafo dio que cuadra con PostgreSQL, 633 resenas en las dos.

Que se pierde. Nada. Las compras y las resenas esperan en la cola.

Como verlo.

- En la pagina, entrar con una cuenta y mirar la portada, que dice Lo mas visto
  donde antes decia Para ti.
- En el registro del backend salen lineas de `GrafoComprasSyncService` que
  dicen que la corrida se interrumpio, cada 10 segundos.
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

- En la portada desaparece Viste hace poco. Lo mas vendido, lo mas visto y se
  compran juntos siguen saliendo, porque se calcularon antes y estan guardados
  en Redis.
- En el panel del administrador, las tendencias avisan que no se pudieron
  cargar.

Que se midio, con Neo4j y ClickHouse apagadas a la vez.

- Lo mas vendido, lo mas visto y se compran juntos contestaron bien en menos de
  una decima de segundo.
- Viste hace poco y las tres tendencias del administrador contestaron 503
  despues de 8 segundos.
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
- En el registro del backend salen lineas de `EventosService` que dicen que no
  se pudo registrar la vista de producto, o la compra en ClickHouse.

## Por que la tienda aguanta

- El dinero y el stock viven en una sola base, PostgreSQL, y se escriben en una
  transaccion. Si esa base no esta, no se cobra nada. Si esta, la compra no
  depende de las demas.
- Lo que tiene que llegar a otra base y no puede perderse, como una compra o una
  resena para el grafo o un cambio de oferta para el buscador, se anota primero
  en una cola de PostgreSQL. Cuando la otra base vuelve, se procesa sola.
- Lo que cuesta calcular, como los rankings, se guarda ya listo en Redis. Si la
  base de donde sale se cae, se sigue mostrando el ultimo calculo.
- Lo que solo sirve para analizar, como una vista o una busqueda, se manda sin
  esperar. Si la base no esta se pierde ese dato, pero la persona que esta
  comprando no espera ni ve un error.
- Las secciones de recomendaciones desaparecen sin aviso si fallan, porque son
  un extra. Lo que la persona vino a hacer, ver el catalogo, abrir un producto o
  pagar, si avisa y deja reintentar.

## Como se midio

- PostgreSQL, con `pruebas/falla_checkout.sh` el 18 de octubre en una base de
  prueba. Apaga cada base a la hora de pagar, una por una, y compara pedidos,
  pagos, movimientos de stock y stock antes y despues. Dio 32 comprobaciones bien
  y ninguna mal. Esa misma prueba confirmo que sin Redis y sin MongoDB se compra.
- Elasticsearch, ademas, con `pruebas/ofertas_y_seguimientos.sh` el 18 de
  octubre. Dio 56 comprobaciones bien y ninguna mal.
- Las rondas del 19 de octubre se midieron llamando a cada funcion de la tienda
  con cada ronda de bases apagadas, anotando la respuesta, el tiempo y si traia
  datos, y haciendo en cada ronda una compra de una unidad que despues se
  cancelo. Las pantallas se fotografiaron con las bases apagadas.
