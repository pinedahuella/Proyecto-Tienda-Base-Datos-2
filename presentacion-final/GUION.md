# Guion de la presentacion final

Treinta minutos, en tres partes, una por persona. Las partes 1 y 2 recorren todo
lo que hace la tienda, y la parte 3 ensena en detalle lo de la Entrega final,
los vectores y el control de acceso, con las dos pruebas en vivo que pidio el
profesor. El texto de cada lamina es una guia para decirlo con las propias
palabras, no para leerlo.

Va por orden de importancia. Primero lo que se hace antes de presentar, despues
las tres partes lamina por lamina, despues lo que pregunta el profesor con el
codigo que pidio ver, los flujos de toda la tienda, los apoyos y al final las
palabras raras en facil.

**Como se lee cada funcionalidad.** Siempre igual.
- La accion en negrita y entre parentesis el service que hace la logica, con su
  archivo y linea, por ejemplo **Pagar** (`src/services/carrito/carrito.service.ts:634`, `comprarCarrito()`).
- Helper, si la logica usa una funcion suelta de `src/helpers/`.
- Si preguntan por la ruta, la ruta, el controller que la recibe y su `@Permiso`.
- Pagina y Base, si hace falta decir donde empieza y donde termina.
- Como explicarlo, en una o dos frases.

Los archivos que empiezan con `src/` son del backend, dentro de `backend/`. Los
de la pagina empiezan con `frontend/`. Las lineas se revisaron el 8 de noviembre
contra el codigo. Los modulos grandes con todos sus services, para buscarlos
rapido, estan en `docs/MAPA-FUNCIONALIDADES.md`.

| Parte | Laminas | Quien | Tiempo |
|---|---|---|---|
| 1. La tienda y todo lo que hace | 1 a 9, con la tienda en vivo y un producto nuevo de punta a punta | Jose Manuel | 12 min |
| 2. Lo que la tienda aprende y como resiste | 10 a 17, con el panel del admin | Juan Pablo | 8 min |
| 3. La Entrega final, vectores y control de acceso | 18 a 29, con las pruebas en vivo | Jose David | 10 min |

Lo que se dice, leido con la voz Sabina de Windows el 7 de noviembre, dura 2,8,
4,1 y 4,3 minutos. El 8 de noviembre las laminas 18 y 19 sumaron unos segundos
por el puntaje. Una persona habla mas despacio, como un tercio mas, y a eso se
suma lo que se ensena en la pantalla. En la parte 1, buscar un minuto y medio y
el producto nuevo de punta a punta unos 5 y medio. En la parte 2, los paneles
del admin unos 3. En la parte 3, las bases en vivo unos 3 y Postman uno. Da
unos 11, 8 y medio y 10 minutos, 29 en total, y queda uno para pasar de una
parte a otra. La caida en vivo de la lamina 14 suma un minuto y va solo si se
llega adelantado. Si el tiempo aprieta, en el producto nuevo no se cancela el
pedido, en el panel del admin se dicen las pestanas sin abrirlas, en las bases
en vivo se ensenan PostgreSQL, Redis y ClickHouse, y en Postman solo el Run de la
coleccion. Conviene ensayarlo una vez con reloj.

---

## Antes de presentar

**La red y lo que tiene que estar prendido.**
- Las dos PC en la misma red y sin cambiarse de red durante la presentacion. Un
  cambio de red corto las bases de la PC de Jose David unos 20 minutos el 23 de
  octubre.
- Tailscale prendido en las dos, y en la PC del backend
  `.\usar-bases-remotas.ps1 -Ip 100.64.42.11` antes de prender el backend. Si
  Tailscale dice que no tiene mapa de la red, `Restart-Service Tailscale` lo
  arregla, paso el 8 de noviembre.
- `node remoto/tunel.cjs 100.64.42.11` prendido en la PC del backend, para las
  carpetas 6 y 7 de Postman y la pagina `http://localhost:8123/play`. Las demos
  del panel de comandos lo usan y lo dejan prendido.
- `ollama serve` prendido en la PC del backend, y una busqueda por frase de
  prueba antes de empezar, porque la primera tarda unos 7 segundos.
- Para apagar una base en vivo, `.\remoto\caidas.ps1 -Accion levantar` unos
  minutos antes, tarda unos 3.

**Los datos de la demo.**
- Retirar en Admin, **Catalogo**, los productos del ensayo. El 8 de noviembre
  quedo activo el 1116, `cafeta de gotero aroma 12 tazas`, con su oferta 6250.
  Si sigue activo, al proponer la cafetera de goteo el vector dice **Puede que
  ya exista** y la demo no se ve igual. Otra opcion es cambiar el nombre de la
  demo, por ejemplo `Cafetera de goteo Aroma 10 tazas`.
- Entrar antes como `compradora.norte@mesh.com` y vaciar **Tu carrito**, porque
  **Pagar** se lleva todo lo que haya en el.
- Unos 15 minutos antes, abrir cinco o seis fichas en la tienda, porque lo mas
  visto sale con un solo producto si nadie navego.
- La matriz de permisos completa, `SELECT count(*) FROM rol_permiso;` tiene que
  dar 80, los 76 de la 050 y los 4 de la 051 a la 054.
- No correr la bateria de pruebas el mismo dia. Deja cuentas, ofertas y senales
  de fraude de prueba. `pedidos_tienda` y `caidas_varias` compran y cancelan con
  `compradora.norte`, y si en **Fraude** sale **Devoluciones seriales** de Ana
  Lopez es por eso. Se descarta con **Descartar**. El 7 de noviembre se descarto
  la que salio.

**Las ventanas.**
- Dos ventanas de Edge con la tienda, `http://localhost:5173`. Una normal, sin
  sesion al empezar, para la parte 1, donde se entra primero como vendedor y
  despues como compradora, y para las laminas 19 y 20. Otra InPrivate, con Ctrl
  Shift N, donde ya se entro como `admin@mesh.com` con `Admin123`, para aprobar
  la cafetera y su oferta, Tendencias, Fraude y Permisos. Cada ventana guarda su
  propia sesion, asi que no se pisan.
- Un bloc de notas abierto con los textos de **Para copiar** de la lamina 8.
- Postman abierto con la sesion iniciada, porque sin cuenta no deja usar
  colecciones, y con la coleccion y el ambiente **Mesh, claves de las bases**
  elegido. La carpeta 5 cambia la oferta 3 de verdad, la corre una sola persona
  a la vez.
- Una terminal abierta en la PC de las bases, para la lamina 27.

---

## Parte 1. La tienda y todo lo que hace (Jose Manuel, 12 min)

### 1. Portada
Buenos dias, somos Mesh. Hicimos una tienda en linea con varios vendedores y
seis bases de datos.

### 2. El equipo
Jose David hizo el backend, yo el frontend, las bases y las pruebas, y Juan
Pablo ClickHouse y Neo4j. Cada uno presenta lo suyo.

### 3. El reto
Un producto es la cosa, y una oferta es quien la vende, a que precio y cuantas
tiene. Son 96 tablas en seis bases.

### 4. Cada base, por la pregunta que contesta
PostgreSQL guarda el dinero y el stock, MongoDB el catalogo, Redis el carrito,
Neo4j las relaciones, ClickHouse los eventos y Elasticsearch la busqueda.

### 5. La regla
Lo que es dinero solo se escribe en PostgreSQL. Lo demas se puede rehacer desde
ahi.

**Si preguntan por que no todo en PostgreSQL.** Cada base contesta mejor su
pregunta, pero solo una guarda la verdad. Informe final, 4.2, la tabla de los
componentes.

### 6. El diagrama
PostgreSQL va abajo, ancha, porque es la fuente de verdad, y las otras cinco
bases encima. Las flechas llenas son lo que hace el backend con cada base, y las
punteadas y numeradas lo que viaja de una base a otra. Cada base dice con que
usuario entra el backend.

**Se hace.** Clic sobre el diagrama para abrirlo a tamano completo, Esc para
cerrar.

**Si preguntan.**
- Sale de `docs/dibujar-arquitectura.py`, en blanco y negro y con la notacion
  del modelo C4, para que se lea igual impreso. La tabla de abajo del dibujo
  dice que viaja en cada flecha punteada y cada cuanto.
- El diagrama entidad relacion es `docs/diagrama-er.png`, el mismo de la
  Entrega 1 puesto al dia el 7 de noviembre con las 96 tablas y sus 126 llaves
  foraneas. Lo actualiza `docs/actualizar-er.py`, que lee la base en
  funcionamiento y falla si una tabla queda sin caja o una llave sin flecha. Se
  abre editable en draw.io con `docs/diagrama-er.drawio`.

### 7. La tienda en vivo, buscar
Ahora la tienda. Primero buscar. La tarjeta de cada resultado sale entera de
Elasticsearch, con su foto, en una sola consulta.

**Se hace, buscar (un minuto y medio).** En la ventana normal de Edge, la
tienda en `http://localhost:5173`, sin sesion.
1. Clic en el buscador de arriba, **Buscar productos**, y escribir `labtop`, mal
   escrito a proposito. Sin dar Enter ya sale una lista con Laptop Aurora 14,
   Laptop Nimbo 13 y las demas laptops.
2. Enter. Se abre la pagina de resultados. Arriba dice **Tal vez quisiste decir
   laptop**, y a la izquierda estan los filtros **Categoria**, **Precio**,
   **Calificacion** y **Existencias**, cada uno con su numero.
3. Marcar **Laptops** y despues **Mas de Q3,000**. La lista y los numeros
   cambian juntos, de 83 productos a 68.
4. Clic en **Laptop Aurora 14**. Arriba sale la foto, el precio y **5 vendedores
   lo tienen**. En la pestana **Comprar** cada presentacion trae sus
   vendedores, con su precio y sus unidades. **Detalles** trae las
   caracteristicas que guarda MongoDB y **Resenas** lo que dicen los
   compradores. Bajando salen **Parecidos a este** y **Quienes lo compraron
   tambien llevaron**.

**Lo que se ensena, por dentro.**

**Buscar mientras se escribe** (`src/services/buscador/productos.service.ts:88`, `buscar()`)
- La consulta esta en `ejecutar()`, linea 132. La difusa en la 146 y la de la
  palabra a medias, `bool_prefix`, en la 159.
- Si preguntan por la ruta. `GET /buscador/productos`, controller
  `src/controllers/buscador/productos.controller.ts:36`, publica.
- Pagina. `buscarProductos()` de `frontend/src/lib/buscador.ts:107`.
- Como explicarlo. Encuentra con la palabra a medias, `lap` ya trae Laptop, y
  con errores, desde dos letras.

**La pagina de resultados con filtros** (`src/services/buscador/facetado.service.ts:99`, `buscar()`)
- La consulta la arma `construirConsulta()`, linea 178. El `multi_match` en la
  187, sobre `nombre^3`, `descripcion` y `variantes`, con `fuzziness: 'AUTO'` en
  la 190.
- Helper. `src/helpers/correccion-busqueda.ts:40`, `pedirCorreccion()`, el Tal
  vez quisiste decir.
- Si preguntan por la ruta. `GET /buscador/productos/facetado`, controller
  `src/controllers/buscador/facetado.controller.ts:30`, publica.
- Pagina. `buscarFacetado()` de `frontend/src/lib/buscador.ts:397`. Cada filtro
  marcado vuelve a llamar la misma ruta con `categoria=7` o `precio=desde-3000`.
- Base. Elasticsearch, indice `mesh_productos`. Las tildes y mayusculas no
  cuentan por el analizador `espanol_llano`, `elastic/001_indice.json:8`.
- Como explicarlo. AUTO perdona un error en palabras de 3 a 5 letras y dos en
  las mas largas, por eso `labtop` encuentra laptop. El nombre pesa tres veces
  mas que la descripcion.

**La ficha** (`src/services/productos/productos.service.ts:265`, `obtenerPublico()`)
- Helper. `src/helpers/catalogo-respaldo.ts:131`, `productosPorIds()`, la copia
  en PostgreSQL si MongoDB no contesta.
- Si preguntan por la ruta. `GET /productos/:id`, controller
  `src/controllers/productos/productos.controller.ts:100`, publica.
- Base. MongoDB para el producto, sus variantes y sus caracteristicas, y
  PostgreSQL para quien lo vende, a que precio y cuantas quedan.
- Como explicarlo. Cada estante de abajo pide su propia ruta, `/similares`,
  `/tambien-compraron` y `/resenas`, asi uno lento no frena a los demas.

### 8. Un producto nuevo, de punta a punta
Ahora el camino entero de un producto, que junta las partes principales de la
tienda. Un vendedor quiere vender una cafetera. Primero la escribe como el la
conoce, y la tienda le avisa que esa ya existe, aunque la escribio distinto. Eso
lo hace el vector, que compara lo que significa el texto y no sus letras.
Despues propone una que no existe, la tienda la aprueba, el le pone su oferta y
una compradora la compra.

**Se hace, proponer (dos minutos).** En la ventana normal de Edge, la misma de
buscar.
1. Arriba a la derecha **Iniciar sesion**. Correo `ventas.norte@mesh.com`, clave
   `Vendedor123`, **Entrar**. Sale **Hola, Carlos**, con las pestanas
   **Ofertas**, **Compartidas**, **Reglas**, **Proponer** y **Propuestas**.
2. Pestana **Proponer**. Sale **Proponer un producto** con su formulario.
3. En **Nombre del producto** escribir `Cafetera espresso Alba` y en
   **Descripcion** `Cafetera espresso de 15 bares con vaporizador de leche`. Clic
   fuera del cuadro. En unos segundos sale **Suele ir en COCINA**, con la
   categoria ya elegida arriba, y **Ya hay parecidos en la tienda**, con
   **Cafetera Alba Espresso** y en rojo **Puede que ya exista**.
4. Cambiar el nombre por `Cafetera de goteo Aroma 12 tazas` y la descripcion por
   `Cafetera electrica con jarra de vidrio y filtro permanente`. Clic fuera.
   Sigue **Suele ir en COCINA** y salen parecidos, como la Cafetera Alba
   Espresso, pero ninguno dice **Puede que ya exista**. Esta si es nueva.
5. Bajar. En **Caracteristicas del producto**, **Marca** `Aroma` y **Potencia
   (W)** `900`. En **Variantes**, **Nombre** `Negra`, **Descripcion**
   `Cuerpo negro y jarra de vidrio` y en **Imagenes** pegar la direccion de la
   foto, que esta abajo en **Para copiar**. En **Lo que distingue a esta variante**,
   **Color** `Negro` y **Capacidad (L)** `1.8`.
6. **Enviar a revision**. Arriba dice que quedo enviado a revision y que se
   sigue en **Mis propuestas al catalogo**.

**Se hace, aprobar (medio minuto).** En la ventana InPrivate del admin.
7. Arriba **Admin**, pestana **Propuestas**. En **Productos por revisar** sale
   la cafetera de goteo, de Carlos. **Aprobar**. Dice que ya esta en el
   catalogo.

**Se hace, la oferta (un minuto).** En la ventana normal, la del vendedor.
8. Pestana **Ofertas** y **Publicar una oferta**. Escribir `cafetera de goteo` y
   elegirla en la lista. Marcar la variante **Negra**, que dice **Nadie la
   ofrece todavia**. **Tu precio** `349.00`, **Unidades iniciales** `10` y
   **Publicar la oferta**.
9. En la ventana InPrivate, pestana **Ofertas** y el boton **Revisar ofertas**.
   Sale **Ofertas por revisar** con la oferta de Carlos, **Aprobar**.

**Se hace, comprar (dos minutos).** En la ventana normal.
10. Arriba **Salir** e **Iniciar sesion** con `compradora.norte@mesh.com` y
    `Comprador123`. Sale **Hola, Ana**.
11. En el buscador escribir `cafetera de goteo` y clic en **Cafetera de goteo
    Aroma 12 tazas**. Llego sola al buscador unos segundos despues de
    aprobarla. Ahi esta la oferta de Carlos con su boton **Agregar**. Clic en
    **Agregar** y se abre **Tu carrito** a la derecha.
12. **Continuar al pago**. Sale **Confirmar la compra**, con la direccion, **Lo
    que llevas** y **Como quieres pagar**. Elegir **Efectivo contra entrega** y
    **Pagar**. Sale **Gracias por tu compra** con el numero de pedido.
13. Arriba **Mis pedidos**. El pedido nuevo sale primero, **Comprado**. Si sobra
    tiempo, **Cancelar** y **Si, cancelar el pedido**, y dice que se devolvieron
    las unidades y que el pago quedo reembolsado.

Lo que se dice mientras. La propuesta nace en revision y no se ve en la tienda
hasta que la aprueban, porque el catalogo es de todos. Al aprobarla, los workers
la llevan al buscador y le calculan sus vectores, por eso aparece sola. La oferta
de un vendedor tambien pasa por la tienda. El carrito vive en PostgreSQL con una
copia rapida en Redis, y pagar es una sola transaccion en PostgreSQL, que cobra y
descuenta el stock juntos o no hace nada.

**Para copiar.** Conviene tenerlo en un bloc de notas abierto.
- `Cafetera espresso Alba`
- `Cafetera espresso de 15 bares con vaporizador de leche`
- `Cafetera de goteo Aroma 12 tazas`
- `Cafetera electrica con jarra de vidrio y filtro permanente`
- `Cuerpo negro y jarra de vidrio`
- La foto, `https://upload.wikimedia.org/wikipedia/commons/thumb/7/7f/A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg/960px-A_black_espresso_machine_sits_on_a_wooden_table%2C_with_a_clear_glass_cup_filled_with_freshly_brewed_coffee.jpg`

**Lo que se ensena, por dentro.**

**El aviso Puede que ya exista** (`src/services/vendedores/sugerencias-propuesta.service.ts:113`, `sugerir()`)
- Helper. `src/helpers/vectores-ollama.ts:33`, `pedirVectores()`, pasa el texto a
  vector, y `src/helpers/vectores-pgvector.ts:41`, `buscarCercanos()`, busca los
  vecinos.
- Si preguntan por la ruta. `POST /vendedor/productos/sugerencias`, controller
  `src/controllers/vendedores/sugerencias-propuesta.controller.ts:30`, con
  `@Permiso('catalogo.proponer')`.
- Pagina. `sugerir()` de `frontend/src/lib/PanelVendedor.svelte:656`, al salir
  del cuadro del nombre. Si la categoria esta vacia elige sola la primera que
  sugiere, linea 672.
- Como explicarlo. Busca los productos activos mas cercanos en PostgreSQL con
  pgvector y las categorias de esos vecinos votan por su parecido. Desde 0,85
  de parecido dice Puede que ya exista (`UMBRAL_DUPLICADO`, linea 37) y por
  debajo de 0,5 no lo cuenta (linea 33).

**Enviar a revision** (`src/services/vendedores/productos.service.ts:260`, `proponer()`)
- Si preguntan por la ruta. `POST /vendedor/productos/propuestas`, controller
  `src/controllers/vendedores/productos.controller.ts:218`, con
  `@Permiso('catalogo.proponer')`.
- Base. MongoDB, el producto nace `en_revision`, y la propuesta en PostgreSQL.
- Como explicarlo. No se ve en la tienda hasta que la tienda la aprueba.

**Aprobar el producto** (`src/services/vendedores/productos.service.ts:575`, `revisarPropuesta()`)
- Si preguntan por la ruta. `PATCH /vendedor/productos/:id/revision`, controller
  `src/controllers/vendedores/productos.controller.ts:238`, con
  `@Permiso('catalogo.revisar')`.
- Como explicarlo. Pasa a `activo` y le pone las banderas `pendiente_busqueda` y
  `pendiente_vector`. El worker del buscador lo lleva a Elasticsearch
  (`src/services/buscador/buscador-sync.service.ts:39`) y el de vectores le
  calcula los dos vectores (`src/services/productos/vectores-sync.service.ts:159`),
  cada 10 segundos. En el ensayo del 7 de noviembre salio en el buscador 3,8
  segundos despues.

**Publicar la oferta** (`src/services/vendedores/ofertas.service.ts:285`, `crear()`)
- Si preguntan por la ruta. `POST /vendedor/ofertas`, controller
  `src/controllers/vendedores/ofertas.controller.ts:176`, con
  `@Permiso('ofertas.publicar')`.
- Como explicarlo. La de un vendedor nace `pendiente` y la de la tienda nace
  activa, linea 295.

**Aprobar la oferta** (`src/services/vendedores/ofertas.service.ts:942`, `revisar()`)
- Si preguntan por la ruta. `PATCH /vendedor/ofertas/:id/revision`, controller
  `src/controllers/vendedores/ofertas.controller.ts:197`, con
  `@Permiso('ofertas.revisar')`.

**Agregar al carrito** (`src/services/carrito/carrito.service.ts:242`, `definirCantidad()`)
- Si preguntan por la ruta. `PUT /carrito/lineas/:idOferta`, controller
  `src/controllers/carrito/carrito.controller.ts:60`, con
  `@Permiso('carrito.usar')` en la linea 42, para toda la clase.
- Pagina. `frontend/src/routes/producto/[id]/+page.svelte:690`.
- Como explicarlo. Guarda la linea en Redis y contesta al instante, y debajo la
  copia al pedido `pendiente` de PostgreSQL, que es la verdad.

**Pagar** (`src/services/carrito/carrito.service.ts:634`, `comprarCarrito()`)
- El candado del doble clic, `conCandadoCheckout()` en
  `src/services/carrito/carrito-redis.service.ts:385`.
- Si preguntan por la ruta. `POST /carrito/comprar`, controller
  `src/controllers/carrito/carrito.controller.ts:124`, con
  `@Permiso('carrito.comprar')` en la linea 123.
- Base. PostgreSQL, `comprar_pedido()` de `migrations/020_descuentos_oferta.sql:226`.
- Como explicarlo. Una sola transaccion, `BEGIN` en la linea 683 y `COMMIT` en
  la 876. Cobra y descuenta el stock juntos, o con `ROLLBACK` en la 879 no hace
  nada.

**Cancelar el pedido** (`src/services/compradores/pedidos.service.ts:251`, `cancelarPedido()`)
- Si preguntan por la ruta. `POST /comprador/pedidos/:id/cancelar`, controller
  `src/controllers/compradores/pedidos.controller.ts:80`, con
  `@Permiso('pedidos.cancelar')`.
- Base. PostgreSQL, `cancelar_pedido_por()` de `migrations/051_pedidos_de_la_tienda.sql:75`.
- Como explicarlo. Devuelve las unidades a cada oferta y deja el pago
  reembolsado, en la misma transaccion.

### 9. Todo lo que hace la tienda
Para cerrar mi parte, todo lo que hace la tienda en una lamina. Quien compra
busca aunque escriba mal, ve cada vendedor y los parecidos, tiene un carrito que
no se pierde, paga de tres formas, cancela, resena lo que compro y pide avisos.
Quien vende publica ofertas, les pone descuentos, ventas relampago y reglas que
se aplican solas, comparte una oferta con otra cuenta y propone productos. La
tienda aprueba productos y ofertas, envia, entrega o cancela cualquier pedido,
pausa o retira ofertas, oculta resenas falsas sin borrarlas, crea categorias y
tiene sus reportes, sus permisos y su fraude. Y sola mantiene al dia el buscador,
el grafo y los vectores, recomienda, busca fraude y sigue vendiendo si se cae una
base. Juan Pablo sigue con lo que la tienda aprende de todo esto.

**Si preguntan por una de esas, el service que la hace.** Todas con su paso a
paso en Los flujos de toda la tienda, mas abajo.

| Lo que dice la lamina | Service | Ruta y permiso |
|---|---|---|
| Busca aunque escriba mal | `src/services/buscador/facetado.service.ts:99`, `buscar()` | `GET /buscador/productos/facetado`, publica |
| Ve cada vendedor | `src/services/productos/productos.service.ts:265`, `obtenerPublico()` | `GET /productos/:id`, publica |
| Los parecidos | `src/services/productos/similares.service.ts:123`, `obtener()` | `GET /productos/:id/similares`, publica |
| Un carrito que no se pierde | `src/services/carrito/carrito.service.ts:242`, `definirCantidad()` | `PUT /carrito/lineas/:idOferta`, `carrito.usar` |
| Paga de tres formas | `src/services/carrito/carrito.service.ts:634`, `comprarCarrito()` | `POST /carrito/comprar`, `carrito.comprar` |
| Cancela | `src/services/compradores/pedidos.service.ts:251`, `cancelarPedido()` | `POST /comprador/pedidos/:id/cancelar`, `pedidos.cancelar` |
| Resena lo que compro | `src/services/resenas/resenas.service.ts:288`, `crear()` | `POST /resenas`, `resenas.escribir` |
| Pide avisos | `src/services/compradores/seguimientos-oferta.service.ts:120`, `crear()` | `POST /comprador/seguimientos`, `avisos.usar` |
| Publica ofertas | `src/services/vendedores/ofertas.service.ts:285`, `crear()` | `POST /vendedor/ofertas`, `ofertas.publicar` |
| Descuentos | `src/services/vendedores/ofertas.service.ts:627`, `aplicarDescuento()` | `POST /vendedor/ofertas/:id/descuento`, `ofertas.descuento` |
| Ventas relampago | `src/services/vendedores/ventas-limitadas.service.ts:83`, `abrir()` | `POST /vendedor/ofertas/:id/venta-limitada`, `ofertas.venta_relampago` |
| Reglas que se aplican solas | `src/services/reglas-descuento-automatico/reglas-descuento-automatico.service.ts:94`, `crear()` | `POST /vendedor/reglas-descuento`, `reglas.administrar` |
| Comparte una oferta | `src/services/acl/acl-ofertas.service.ts:244`, `otorgar()` | `POST /vendedor/ofertas/:id/permisos`, `ofertas.compartir` |
| Propone productos | `src/services/vendedores/productos.service.ts:260`, `proponer()` | `POST /vendedor/productos/propuestas`, `catalogo.proponer` |
| Aprueba productos | `src/services/vendedores/productos.service.ts:575`, `revisarPropuesta()` | `PATCH /vendedor/productos/:id/revision`, `catalogo.revisar` |
| Aprueba ofertas | `src/services/vendedores/ofertas.service.ts:942`, `revisar()` | `PATCH /vendedor/ofertas/:id/revision`, `ofertas.revisar` |
| Envia o entrega cualquier pedido | `src/services/compradores/pedidos.service.ts:315`, `marcarEnvio()` | `POST /admin/pedidos/:id/enviado` y `/entregado`, `pedidos.administrar` |
| Cancela cualquier pedido | `src/services/compradores/pedidos.service.ts:284`, `cancelarComoTienda()` | `POST /admin/pedidos/:id/cancelar`, `pedidos.administrar` |
| Pausa o retira ofertas | `src/services/vendedores/ofertas.service.ts:840`, `administrar()` | `PATCH /admin/ofertas/:id`, `ofertas.administrar` |
| Oculta resenas sin borrarlas | `src/services/resenas/resenas.service.ts:735`, `moderar()` | `PATCH /admin/resenas/:id`, `resenas.moderar` |
| Crea categorias | `src/services/admin/admin-categorias.service.ts:116`, `crear()` | `POST /admin/categorias`, `catalogo.categorias` |
| Sus reportes | `src/services/admin/admin-reportes.service.ts:109`, `ventas()` | `GET /admin/reportes/ventas`, `reportes.ver` |
| Sus permisos | `src/services/acl/permisos.service.ts:341`, `revocar()` | `DELETE /admin/permisos/:idRol/:idPermiso`, `permisos.administrar` |
| Su fraude | `src/services/fraude/casos-fraude.service.ts:87`, `listarPaginado()` | `GET /admin/fraude/casos`, `fraude.ver` |
| Buscador, grafo y vectores al dia | `src/services/buscador/buscador-sync.service.ts:39`, `src/services/grafo/grafo-sync.service.ts:90` y `src/services/productos/vectores-sync.service.ts:159` | Ninguna, son workers |
| Sigue vendiendo si se cae una base | `src/helpers/cortacircuitos.ts:27`, `Cortacircuitos` | `GET /db/cortacircuitos`, `sistema.ver` |

---

## Parte 2. Lo que la tienda aprende y como resiste (Juan Pablo, 8 min)

### 10. Lo que pasa en el tiempo, ClickHouse
Cada vista, carrito, busqueda, compra y devolucion queda como un evento en
ClickHouse. Lo elegimos porque guarda cada columna por separado y compara
periodos sin definir cada pregunta antes de guardar el dato. La consulta de
productos en ascenso compara las vistas de los ultimos siete dias contra las
anteriores, y cuenta cuantas personas distintas hay detras, para que un producto
inflado con clics repetidos no parezca una tendencia.

**Se hace.** En la ventana InPrivate de Edge, donde ya entro el admin
(`admin@mesh.com`, clave `Admin123`).
1. Arriba, clic en **Admin**. Se abre el panel con sus pestanas.
2. Clic en **Tendencias**. Sale **Lo que mas esta creciendo**, **Lo mas visto**,
   **Lo que mas llevan al carrito**, **Lo mas vendido**, **Lo mas devuelto** y
   **Lo mas buscado**, todo de los ultimos 30 dias.

**Lo que se ensena, por dentro.**

**Lo mas visto y los demas rankings** (`src/services/admin/admin-tendencias.service.ts:63`, `rankingVistas()`)
- Todos pasan por `consultarRanking()`, linea 253.
- Si preguntan por la ruta. `GET /admin/eventos/vista`, `/carrito`, `/compra`,
  `/devolucion` y `/busqueda`, controller
  `src/controllers/admin/admin-tendencias.controller.ts:48` y las que siguen, con
  `@Permiso('tendencias.ver')` en la linea 40, para toda la clase.
- Base. ClickHouse, `vista_producto` en `clickhouse/001_esquema.sql:31`, con
  `ORDER BY (id_producto, fecha)` en la linea 71.
- Como explicarlo. Cuenta personas distintas y no clics,
  `count(DISTINCT sesion)` en la linea 68. El ORDER BY de ClickHouse es el orden fisico en el
  disco, no un indice aparte, y por eso leer un periodo es rapido.

**Lo que mas esta creciendo** (`src/services/admin/admin-tendencias-avanzadas.service.ts:93`, `enAscenso()`)
- Si preguntan por la ruta. `GET /admin/eventos/tendencias`, controller
  `src/controllers/admin/admin-tendencias-avanzadas.controller.ts:34`, con
  `@Permiso('tendencias.ver')`.
- Base. ClickHouse, sobre el resumen diario `vistas_por_producto_dia`. El
  embudo es `embudo()`, linea 155.
- Como explicarlo. En la Entrega 2 respondio en 13 ms sobre un lote sembrado y
  separo el ascenso real del producto inflado, 45 vistas por persona contra 1,6.

### 11. Las relaciones que delatan, y no solo en circulo
En la Entrega 2 parecia que en Neo4j solo buscabamos anillos. Buscamos siete
patrones, y solo tres son circulos, tres o cuatro cuentas que se califican en
rueda, dos que se califican una a la otra, y esas dos sobre el mismo producto.
Los otros cuatro no tienen ningun circulo. Cuentas nuevas que solo le ponen
cinco a un vendedor, como satelites a su alrededor. Una cuenta que califica al
mismo vendedor mes tras mes y casi a nadie mas. Dos cuentas que califican lo
mismo casi a la vez. Y un vendedor de una semana con notas de cuentas recien
creadas.

La consulta que mas nos gusta es la de las dos cuentas coordinadas. Dos cuentas,
dos resenas, el mismo producto y el mismo vendedor, con menos de un dia entre las
dos y tres veces o mas. Ninguna califica a la otra, asi que no hay circulo, y aun
asi el grafo las junta. Ninguna consulta prueba un fraude, senalan cuentas para
que una persona las revise. Y el mismo grafo da quienes lo compraron tambien
llevaron.

**Se hace.** En la ventana InPrivate del admin.
1. Pestana **Fraude** y despues **Resenas en anillo**. Sale **Manipulacion de
   resenas** con los pendientes.
2. En **Tipo** elegir **Cuentas que solo califican a un vendedor**. Salen las
   granjas alrededor de un vendedor, cada tarjeta con sus cuentas y sus resenas.
3. En **Tipo**, **Reputacion en minutos**, el vendedor nuevo con notas de cuentas
   recien nacidas. Si se quiere ver la de coordinadas, arriba **Todas** y en
   **Tipo** **Califican juntas lo mismo**, porque las que habia ya se revisaron.

**Lo que se ensena, por dentro.**

**La lista de Resenas en anillo** (`src/services/fraude/fraude-anillos-persistidos.service.ts:88`, `listarPaginado()`)
- Si preguntan por la ruta. `GET /admin/fraude/alertas-resenas`, controller
  `src/controllers/admin/admin-fraude-anillos.controller.ts:47`, con
  `@Permiso('fraude.ver')`.
- Pagina. `cargarAnillosPersistidos()` de `frontend/src/lib/PanelFraude.svelte:876`.
- Como explicarlo. Lee las senales que ya guardaron los detectores en
  `senal_fraude`, no corre el Cypher en cada clic.

**Los tres en circulo** (`src/services/fraude/anillos-detector.service.ts:39`, el `@Interval` cada 15 minutos)
- El ciclo es el Cypher de la linea 268,
  `MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)`.
- Como explicarlo. Un camino de 4 a 8 saltos que sale de una cuenta y vuelve a
  ella. La resena es un nodo y no una arista, para poder colgarle la
  calificacion, la fecha y el producto. Informe de la Entrega 2, 5.2.

**Los cuatro sin circulo** (`src/services/fraude/patrones-fraude-detector.service.ts:65`, el `@Interval` cada 15 minutos)
- La de coordinadas es el `MATCH` de la linea 342 y el de la 348, con 24 horas
  (linea 58) y 3 coincidencias (linea 59). Tambien corre al llegar una resena,
  `detectarInmediato()` en la 119.
- Las mismas consultas, para correrlas a mano en el navegador de Neo4j, estan en
  `neo4j/consultas/`, la de coordinadas en `neo4j/consultas/B6_coordinados.cypher`
  y la de satelites en `neo4j/consultas/B2_satelites.cypher`.

**Quienes lo compraron tambien llevaron** (`src/services/productos/tambien-compraron.service.ts:59`, `obtener()`)
- Si preguntan por la ruta. `GET /productos/:id/tambien-compraron`, controller
  `src/controllers/productos/tambien-compraron.controller.ts:22`, publica.
- Base. Neo4j, el Cypher de la linea 130.
- Como explicarlo. Va de este producto a quien lo compro y de ahi a lo que
  tambien compro. El `CASE WHEN` de la linea 136 pone grupo 0 a la misma
  categoria y el `ORDER BY grupo` de la 140 los pone primero. Es ADR-25.

**Si preguntan por que dice revisado hace unas horas.** Esa linea dice cuando
llego al grafo la ultima resena nueva, no cuando corrio el detector. **Al dia**
quiere decir que no falta ninguna por pasar. Sale de `max(procesado_en)` en
`src/services/grafo/grafo-sync.service.ts:495`.

### 12. 30 tipos de fraude, cada uno en la base que mejor lo ve
El fraude no vive solo en Neo4j. Son 30 tipos repartidos en cinco bases, cada uno
donde mejor se ve. Neo4j ve como se califican las cuentas entre ellas. PostgreSQL
compara el texto de las resenas por su significado, encuentra estrellas que
contradicen lo escrito y resenas con la compra cancelada. Redis cuenta al
instante las contrasenas probadas una tras otra. Elasticsearch recuerda desde
donde entra cada cuenta, para la IP que nunca uso y el viaje imposible. Y
ClickHouse mira como se compra y se devuelve. Cada hallazgo es una senal, y cada
15 minutos las que comparten cuentas se juntan en un caso para que una persona
decida.

**Se hace.** En la ventana InPrivate, dentro de **Fraude**, la pestana
**Casos**. Cada caso junta senales de varias bases con sus cuentas. Despues un
vistazo a **Intentos de entrada** y a **Compras y navegacion**.

**Lo que se ensena, por dentro.**

**Casos** (`src/services/fraude/casos-fraude.service.ts:87`, `listarPaginado()`)
- Los arma `src/services/fraude/agrupador-fraude-worker.service.ts:54`, cada 15
  minutos.
- Si preguntan por la ruta. `GET /admin/fraude/casos`, controller
  `src/controllers/admin/admin-casos-fraude.controller.ts:36`, con
  `@Permiso('fraude.ver')`.
- Como explicarlo. Junta las senales que comparten cuentas y les da un puntaje
  segun cuantas y de que tipo son. Una persona decide.

**Intentos de entrada** (`src/services/fraude-login/fraude-login.service.ts:346`, `listarAlertasPaginado()`)
- Si preguntan por la ruta. `GET /admin/fraude/alertas-login`, controller
  `src/controllers/fraude/fraude.controller.ts:29`, con `@Permiso('fraude.ver')`.
- Como explicarlo. Redis cuenta en ventanas de uno a cinco minutos y
  Elasticsearch en ventanas de 24 horas, para el ataque repartido en horas.

**Compras y navegacion** (`src/services/fraude/hallazgos-evento-fraude-persistidos.service.ts:90`, `listarPaginado()`)
- Los busca `src/services/fraude/hallazgos-evento-fraude-detector.service.ts:106`,
  una vez al dia, en ClickHouse.
- Si preguntan por la ruta. `GET /admin/fraude/alertas-eventos`, controller
  `src/controllers/admin/admin-fraude-eventos.controller.ts:45`, con
  `@Permiso('fraude.ver')`.

**Si preguntan.** Cada tipo, con un ejemplo y como se demuestra, en
`docs/FRAUDE-CATALOGO.md`. Los de ClickHouse corren una vez al dia, los demas al
instante y cada 15 minutos.

### 13. El panel del admin, pestana por pestana
Y lo que se ve del lado de la tienda, pestana por pestana. Dashboard, las ventas y
los clientes contra el periodo anterior, y cada pedido, para marcarlo enviado o
entregado o cancelarlo, sin culpar al comprador. Reportes, pedidos, pagos y
como paga la gente. Ofertas, donde se aprueban las de cada vendedor, como la de la
cafetera. Compartidas y Reglas, igual que un vendedor. Catalogo, cada producto con
su historial a cualquier fecha, sus ofertas para pausarlas o retirarlas y las
categorias. Propuestas, donde se aprobo la cafetera. Cuentas y Permisos, que Jose
David ensena en su parte. Fraude, con la pestana de Neo4j, donde una resena falsa
se oculta sin borrarla. Y Tendencias, de ClickHouse.

**Se hace (un minuto).** En la ventana InPrivate, un clic en cada pestana sin
apretar nada adentro, **Dashboard**, **Reportes**, **Ofertas**, **Catalogo**,
**Cuentas** y **Tendencias**.

**Lo que se ensena, por dentro.** Las pestanas que ve cada rol salen de
`frontend/src/routes/panel/+page.svelte:135`.

**Dashboard** (`src/services/dashboards/dashboard-general.service.ts:81`, `resumen()`)
- Si preguntan por la ruta. `GET /admin/dashboard/resumen`, `/ventas`,
  `/categorias` y `/pagos`, controller
  `src/controllers/dashboards/dashboard-general.controller.ts:67` y las que
  siguen, con `@Permiso('dashboard.ver')` en la linea 59.
- Como explicarlo. Cifras del periodo contra el anterior, de PostgreSQL.

**Los pedidos de la tienda** (`src/services/compradores/pedidos.service.ts:284`, `cancelarComoTienda()`, y `:315`, `marcarEnvio()`)
- Si preguntan por la ruta. `POST /admin/pedidos/:id/cancelar`, `/enviado` y
  `/entregado`, controller `src/controllers/admin/admin-pedidos.controller.ts:34`,
  con `@Permiso('pedidos.administrar')`.
- Base. PostgreSQL, `cancelar_pedido_por()` y `marcar_envio_pedido()` de
  `migrations/051_pedidos_de_la_tienda.sql`, lineas 75 y 186.
- Como explicarlo. Si cancela la tienda queda anotado quien y por que, y no se
  culpa al comprador en el fraude.

**Reportes** (`src/services/admin/admin-reportes.service.ts:109`, `ventas()`)
- Si preguntan por la ruta. `GET /admin/reportes/ventas`, controller
  `src/controllers/admin/admin-reportes.controller.ts:40`, con
  `@Permiso('reportes.ver')`.

**El historial a una fecha** (`src/services/productos/productos.service.ts:398`, `reconstruirEnFecha()`)
- Si preguntan por la ruta. `GET /vendedor/productos/:id/historial?fecha=`,
  controller `src/controllers/vendedores/productos.controller.ts:158`, con
  `@Permiso('catalogo.ver')`.
- Base. MongoDB, una agregacion con `$match`, `$sort` y `$group`, linea 419.
- Como explicarlo. Rehace como era el producto en cualquier fecha a partir de
  sus eventos. Es lo de la Entrega 1.

**Pausar, retirar o ajustar ofertas ajenas** (`src/services/vendedores/ofertas.service.ts:840`, `administrar()`)
- Si preguntan por la ruta. `PATCH /admin/ofertas/:id`, controller
  `src/controllers/admin/admin-ofertas.controller.ts:51`, con
  `@Permiso('ofertas.administrar')`.
- Como explicarlo. El precio no lo toca, es del vendedor. Cada ajuste de
  unidades queda en el kardex a nombre del admin.

**Las categorias** (`src/services/admin/admin-categorias.service.ts:195`, `renombrar()`)
- Si preguntan por la ruta. `PATCH /admin/categorias/:id`, controller
  `src/controllers/admin/admin-categorias.controller.ts:64`, con
  `@Permiso('catalogo.categorias')`.
- Como explicarlo. Cambia el nombre en todos sus productos con un solo
  `updateMany`, linea 233, porque cada producto de MongoDB lleva su categoria.

**Ocultar una resena** (`src/services/resenas/resenas.service.ts:735`, `moderar()`)
- Si preguntan por la ruta. `PATCH /admin/resenas/:id`, controller
  `src/controllers/admin/admin-resenas.controller.ts:31`, con
  `@Permiso('resenas.moderar')`.
- Como explicarlo. Sale de la ficha y del promedio, que solo cuenta las
  publicadas (linea 138), y sigue en la base y en Neo4j como evidencia.

### 14. Si se cae una base, la tienda sigue
Cada base tiene su respaldo, con un cortacircuitos. El profesor pregunto que hace
la tienda si no estan las seis, y lo medimos tambien con varias apagadas a la
vez. Mientras PostgreSQL este prendido se puede comprar, sea cual sea el resto.
Sin PostgreSQL la tienda se puede mirar pero no comprar, y lo dice con un aviso
en lugar de quedarse esperando. Al prender otra vez las bases, el backend las
vuelve a usar solo.

**Se hace (si hay tiempo).** Con `.\remoto\caidas.ps1 -Accion levantar` corrido
antes, `-Accion apagar -Base redis` y recargar la tienda. Despues
`-Accion prender -Base redis`.

**Lo que se ensena, por dentro.**

**El cortacircuitos** (`src/helpers/cortacircuitos.ts:27`, `Cortacircuitos`)
- Despues de un fallo pausa la base 15 segundos, linea 40, para no esperar en
  cada peticion.
- Los respaldos, `src/helpers/catalogo-respaldo.ts` sin MongoDB,
  `src/helpers/buscador-respaldo.ts` sin Elasticsearch y
  `src/helpers/recomendaciones-respaldo.ts` sin Neo4j o ClickHouse.
- Si preguntan por la ruta. `GET /db/cortacircuitos`, controller
  `src/controllers/base-datos.controller.ts:49`, con `@Permiso('sistema.ver')`.
  Dice cada base si contesta y desde cuando esta caida.

**Si preguntan.** La justificacion esta en el informe final, 4.4, la tabla de
varias bases apagadas, y en ADR-22. `node pruebas/caidas.mjs` da 51
comprobaciones con cada base apagada y otras 51 congelada.
`pruebas/caidas_varias.mjs` mide una, dos o tres a la vez, pero no se corre el
dia de presentar.

### 15. Las 26 decisiones
Los numeros de las decisiones chocaban entre entregas y ahora hay un solo
registro, del 1 al 26. Las de fondo verde se habian hecho sin su registro y
ahora lo tienen, como comprar sin MongoDB o la verdad del carrito en
PostgreSQL.

### 16. Retrospectiva
Siete decisiones que sostendriamos y ocho que no. La mas clara, el carrito solo
en Redis, que el 17 de octubre paso a tener su verdad en PostgreSQL.

### 17. Lo aprendido
Cada dato con un solo dueno escrito. En casi todo lo que replanteariamos, una
copia termino comportandose como si fuera la verdad.

---

## Parte 3. La Entrega final, vectores y control de acceso (Jose David, 10 min)

### 18. Recomendacion semantica
El enunciado pide sugerencias por la similitud semantica de la descripcion. Cada
producto tiene dos textos, leidos de MongoDB. El general junta su nombre, su
categoria y su descripcion. El segundo junta sus caracteristicas, como la marca,
la talla o el color, y lo sumamos despues de que el profesor preguntara con que
campos se calcula la similitud. Ollama convierte cada texto en un vector de 768
numeros con el modelo paraphrase-multilingual, en la misma maquina y sin costo.
Los dos se guardan en PostgreSQL con pgvector, y el general lleva un indice HNSW
por coseno. Solo por el vector general, sin decirle la categoria al modelo, dos
de cada tres vecinos ya son de la misma categoria, contra seis de cada cien al
azar.

**Lo que se ensena, por dentro.**

**Calcular los dos vectores** (`src/services/productos/vectores-sync.service.ts:160`, `recalcular()`)
- Corre cada 10 segundos, el `@Interval` de la linea 159.
- El texto general lo arma `construirTexto()`, linea 61, y el de
  caracteristicas `construirTextoCaracteristicas()`, linea 98, con las del
  producto y las de sus variantes, ordenadas por nombre.
- Helper. `src/helpers/vectores-ollama.ts:33`, `pedirVectores()`, la llamada a
  Ollama.
- Base. PostgreSQL, `vector_producto` en `migrations/040_vectores_en_postgres.sql:40`,
  el indice HNSW en la linea 69, y las dos columnas nuevas del segundo vector en
  `migrations/055_vector_caracteristicas.sql:35`.
- Como explicarlo. Guarda el md5 de cada texto y compara, lineas 248 y 249. Solo
  llama a Ollama si cambio el texto, y solo por el vector que cambio.

**Si preguntan por que un vector aparte.** Asi cada parte pesa lo que se decide
al ordenar, el general manda y las caracteristicas suman. Si un producto no
tiene caracteristicas, el general no cambia. Esta en la cabecera de la
migracion 055.

### 19. Primero su categoria, despues el resto
En la ficha, el estante Parecidos a este sigue el mismo esquema que quienes lo
compraron tambien llevaron. Primero los de su misma categoria y despues el resto
del catalogo. Dentro de cada bloque ordena un puntaje, el 70 por ciento es el
parecido general, el 20 el parecido de las caracteristicas y el 10 la nota de
las resenas. Lo calculamos aparte en PostgreSQL, sin indice, y en 60 de 60
productos dio lo mismo que la ruta. Y en 58 de esos 60 las caracteristicas y la
nota cambian el orden.

**Se hace.** En la ventana normal.
1. En el buscador de arriba escribir `maillot` y, en la lista que sale, clic en
   **Maillot de ruta Peloton**.
2. Bajar hasta **Parecidos a este**. Salen cinco de ciclismo, el candado, el
   casco, los guantes, el sillin y la bomba de piso, y al final la **Comoda
   Sendero**.
3. Lo que se dice. Solo por el parecido general los guantes iban antes que el
   casco. El casco sube porque sus caracteristicas se parecen mas a las del
   maillot y tiene mejor nota. La comoda va al final porque es de otra
   categoria, aunque se parece mas que la bomba de piso.

| Parecido | Puntaje | General | Caracteristicas | Nota |
|---|---|---|---|---|
| Candado plegable Cerrojo F8 | 0,683 | 0,707 | 0,621 | 3,3 |
| Casco de ruta Aerodino | 0,666 | 0,624 | 0,747 | 4,7 |
| Guantes de ciclismo Palma Corta | 0,650 | 0,629 | 0,710 | 3,5 |
| Sillin de ruta Vertebra SR-2 | 0,583 | 0,538 | 0,580 | 5,0 |
| Bomba de piso Piston | 0,483 | 0,456 | 0,539 | 2,7 |
| Comoda Sendero 4 gavetas, de otra categoria | 0,655 | 0,657 | 0,679 | sin resenas |

**Lo que se ensena, por dentro.**

**Parecidos a este** (`src/services/productos/similares.service.ts:123`, `obtener()`)
- Los candidatos los saca `buscarSimilares()`, linea 152. El bloque 1, los de su
  categoria, es la consulta de la linea 184, filtrada por `pc.id_categoria` en la
  192. El bloque 2, todo el catalogo, la de la 201, con el indice HNSW.
- El puntaje lo saca `puntuar()`, linea 277, en una consulta de PostgreSQL sobre
  esos candidatos, y la cuenta es `puntajeDe()`, linea 75, con los pesos de las
  lineas 20 a 27.
- Helper. `src/helpers/vectores-pgvector.ts:41`, `buscarCercanos()`, sube
  `hnsw.ef_search` y activa `hnsw.iterative_scan` (lineas 50 y 51), porque con
  los valores de fabrica el indice mira 40 candidatos y el filtro dejaba menos
  filas.
- Si preguntan por la ruta. `GET /productos/:id/similares`, controller
  `src/controllers/productos/similares.controller.ts:20`, publica.
- Pagina. `traerSimilares()` de `frontend/src/routes/producto/[id]/+page.svelte:178`,
  y el estante en la linea 1212.
- Como explicarlo. Cada bloque se ordena por puntaje (`enOrden`, linea 223) y se
  llenan los seis, uno por grupo, primero su categoria y despues el resto
  (lineas 263 y 264). Cada resultado trae `misma_categoria`, `similitud`,
  `puntaje`, `parecido_caracteristicas` y `nota_resenas`.

**La cuenta del puntaje, para decirla.**

```text
puntaje = 0,7 x parecido general + 0,2 x parecido de caracteristicas + 0,1 x nota / 5
nota    = (suma de estrellas + 2 x 3) / (resenas + 2)
```

- Si a alguno le faltan las caracteristicas, esa parte vale lo mismo que el
  general, asi no gana ni pierde por eso.
- La nota es bayesiana, como si cada producto tuviera dos resenas imaginarias de
  3 estrellas. Una sola resena de 5 no le gana a veinte buenas, y un producto
  sin resenas cuenta como de 3.
- El operador `<=>` es la distancia coseno, y el parecido es uno menos la
  distancia.

**Si preguntan por la prueba.** `python pruebas/recomendacion_semantica.py`, 30
en verde. La seccion 2c calcula el puntaje aparte, contra todos y sin indice, y
da los mismos seis, en el mismo orden y con diferencia 0. Saboteada con los
pesos 1, 0 y 0 dio 2 FALLA, como debia. En vivo,
`.\demo-entrega-final.ps1 -Parte semantica -Producto maillot`.

### 20. Una frase encuentra lo que nombra
Con los mismos vectores el buscador sumo dos formas de buscar. La hibrida junta
la busqueda por palabras de Elasticsearch con la busqueda por significado de
PostgreSQL. La de intencion compara la frase con el vector de las resenas y
ensena lo que cuentan otros compradores. Asi una frase encuentra un producto
aunque no comparta ninguna palabra con su nombre.

**Se hace.** En la ventana normal, en el buscador de arriba escribir
`algo para salir a pedalear` y dar Enter. En la pagina de resultados sale arriba la seccion
**Lo que cuentan otros compradores**, con resenas que hablan de eso aunque no
usen esas palabras.

**Lo que se ensena, por dentro.** Esa pagina llama tres rutas a la vez, la
hibrida, la de intencion y la facetada de siempre.

**La busqueda hibrida** (`src/services/buscador/hibrida.service.ts:128`, `buscar()`)
- Por palabras `buscarPorTexto()`, linea 186, y por significado
  `buscarPorSignificado()`, linea 247. Las junta `combinar()`, linea 352, con la
  constante 60 de la linea 33.
- Si preguntan por la ruta. `GET /buscador/productos/hibrida`, controller
  `src/controllers/buscador/hibrida.controller.ts:20`, publica.
- Pagina. `buscarHibrida()` de `frontend/src/lib/buscador.ts:196`.
- Como explicarlo. RRF junta las dos listas por la posicion de cada producto y
  no por su puntaje, porque el puntaje de Elasticsearch y el coseno no se pueden
  comparar. Si Ollama no contesta, responde solo por palabras.

**Lo que cuentan otros compradores** (`src/services/buscador/intencion.service.ts:108`, `buscar()`)
- Busca en las resenas con `buscarResenas()`, linea 194, sobre
  `vector_comentario`, y pide al menos 0,45 de parecido, linea 34.
- Si preguntan por la ruta. `GET /buscador/productos/intencion`, controller
  `src/controllers/buscador/intencion.controller.ts:22`, publica.
- Pagina. `buscarPorIntencion()` de `frontend/src/lib/buscador.ts:262`.

**Si preguntan donde mas se usan los vectores.** Las sugerencias al proponer un
producto, `src/services/vendedores/sugerencias-propuesta.service.ts:113`, y las
resenas casi iguales del fraude, que compara PostgreSQL con `paresParecidos()`
en `src/helpers/vectores-pgvector.ts:74`, sin sacar los vectores de la base.

### 21. El viaje del vector
Empezo en pgvector el 25 de septiembre. El 4 de octubre se mudo a Elasticsearch,
y el 16 volvio a pgvector, porque el profesor pidio pgvector y al medir contra el
coseno exacto pgvector coincidio en 1000 de 1001 y Elasticsearch en 317. El 8 de
noviembre le sumamos el vector de caracteristicas, en la misma tabla. Una
decision comoda tambien hay que medirla.

### 22. Cada servicio entra con lo justo
El control de acceso empezo en Redis con un usuario por servicio, y el 23 de
octubre lo llevamos a las cinco bases que lo permiten. El backend lee y escribe
datos, pero no puede crear ni borrar tablas, colecciones o indices. Las
herramientas solo miran. Neo4j es la unica base sin usuario por servicio, porque
la edicion community no trae roles.

**Si preguntan.** Los usuarios se crean en `seguridad/postgres.sql`,
`seguridad/mongo.js`, `seguridad/clickhouse.sql`, `seguridad/elastic.sh` y, los
de Redis, en `docker-compose.yml` de la linea 170 a la 205. El backend entra con
`mesh_backend`, se ve en `backend/.env`.

### 23. Lo que encontramos
Revisando la seguridad encontramos que Elasticsearch tenia la seguridad apagada
con un comentario que decia lo contrario, que DbGate entraba a MongoDB como root,
y que Neo4j no puede tener roles. Los tres estan corregidos o explicados.

### 24. La prueba
93 bien y 0 mal. Cada negativa tiene su control, que mesh_lectura no pueda
escribir solo cuenta si mesh_backend si pudo. Lo que borraria algo se intenta en
una transaccion que se deshace o sobre algo que no existe.

**Si preguntan.** `bash seguridad/prueba_acceso.sh`, corrida otra vez el 5 de
noviembre contra las bases, 93 OK.

### 25. Permisos por rol
El profesor pidio el control de acceso tambien a nivel de funcionalidades. Cada
una de las 146 rutas privadas declara la accion que hace, por ejemplo
ofertas.publicar, y un guard del backend le pregunta a la tabla rol_permiso en
ese momento si el rol de la cuenta la tiene. Si no, 403, y el intento queda
anotado. Quitar una fila vale en la peticion siguiente, sin compilar ni
reiniciar.

**Se hace.** En la ventana InPrivate del admin, pestana **Permisos**. Arriba
**Permisos por rol**, los 42 permisos con una columna por rol, Comprador,
Vendedor y Admin. Las casillas de `cuenta.ver` y las dos de `permisos` del admin
salen en gris, porque no se pueden quitar, y al pasar el raton dicen **No se
puede quitar**. Abajo **Lo ultimo que paso**, con cuando, quien, su rol, el
permiso que le falto y la ruta que pidio. Si Postman ya corrio, ahi salen sus
403. Las casillas en gris tambien las prueba Postman, en la carpeta 4. Quitarlas
directo contesta 409 y no borra nada.

**Lo que se ensena, por dentro.**

**La pregunta de cada peticion** (`src/services/acl/permisos.service.ts:106`, `tiene()`)
- Las dos guardias. `SesionGuard`, `src/guards/sesion.guard.ts:71`, dice quien
  es o 401, linea 77, y lee el rol de la base en cada peticion, linea 94, no del
  token. `PermisoGuard`, `src/guards/permiso.guard.ts:41`, dice que puede o 403,
  linea 81. Una ruta sin `@Permiso` tambien se niega, linea 55.
- El intento negado lo anota `registrarNegado()`,
  `src/services/acl/permisos.service.ts:176`, desde la linea 74 de la guard.
- Base. `rol_permiso` en `migrations/050_permisos_por_rol.sql:70` y
  `auditoria_permiso` en la linea 93.
- Como explicarlo. Le pregunta a la base en cada peticion, por eso quitar un
  permiso vale en la siguiente. Si PostgreSQL no contesta, usa la copia que
  guarda cada minuto.

**Marcar o desmarcar una casilla** (`src/services/acl/permisos.service.ts:309`, `otorgar()`, y `:341`, `revocar()`)
- Si preguntan por la ruta. `POST` o `DELETE /admin/permisos/:idRol/:idPermiso`,
  controller `src/controllers/admin/admin-permisos.controller.ts:61` y `:86`, con
  `@Permiso('permisos.administrar')`.
- Pagina. `frontend/src/lib/PanelPermisos.svelte:71`. La matriz y el registro los
  piden `leerMatriz()` y `leerRegistro()` de `frontend/src/lib/permisos.ts:53` y
  `:57`, por `GET /admin/permisos` y `/admin/permisos/registro`.
- Como explicarlo. La linea 350 no deja quitar `cuenta.ver` ni los dos de
  permisos del admin y contesta 409, para que nadie se quede fuera.

### 26. Un ACL por oferta
Lo de arriba es por rol. Ninguna base sabe que persona pide, todo llega como
mesh_backend, asi que el permiso de cada persona vive en la aplicacion. Cada
oferta lleva su lista, quien puede verla, editarla o ponerle descuento y hasta
cuando. Sin ninguna entrada se niega con el mismo 404 de una oferta ajena, y si
la ve pero no la puede editar, 403.

**Lo que se ensena, por dentro.**

**La guardia de cada oferta** (`src/services/acl/acl-ofertas.service.ts:83`, `comprobar()`)
- La llama `PermisoOfertaGuard`, `src/guards/permiso-oferta.guard.ts:42`.
- Base. `permiso_oferta` en `migrations/049_acl_ofertas.sql:61`.
- Como explicarlo. Sin ninguna entrada, 404 en la linea 132. Con ver pero sin
  editar, 403 en la 134.

**Compartir una oferta** (`src/services/acl/acl-ofertas.service.ts:244`, `otorgar()`)
- Si preguntan por la ruta. `POST /vendedor/ofertas/:id/permisos`, controller
  `src/controllers/vendedores/permisos-oferta.controller.ts:57`, con
  `@Permiso('ofertas.compartir')`.

### 27. En vivo, dentro de cada base
Ahora sin ningun script. Entramos a cada base con un usuario que no tiene el
permiso, ensenamos que si puede lo suyo, y que la base le dice que no.

**Se hace, lo corre Jose David en su PC, donde viven las bases (unos 3
minutos).** En PowerShell. Cada cliente pide la clave al entrar, se pega y no
se ve mientras se escribe. Son las del `.env` de su PC. Nada de esto dana la
tienda, lo que borraria algo apunta a algo que no existe o a cero filas.

| Base | Usuario | Clave |
|---|---|---|
| PostgreSQL | `mesh_lectura` | `rxdmtazh0s58jb3lpi261qev` |
| PostgreSQL | `mesh_backend` | `128xo93mu0nhc56zvlqispar` |
| MongoDB | `mesh_lectura` | `twoxug1mke52b9dh4cpj8ayv` |
| MongoDB | `mesh_backend` | `5ofgismu0p1bc46nrk8hyx23` |
| Redis | `inspeccion` | `hlow3n7iptmjye58kguqfb9a` |
| Redis | `backend` | `97hb8xzcna32yd64tkmspl0u` |
| ClickHouse | `mesh_lectura` | `yat2fo3bukge50dsqchivwj4` |
| Neo4j | `neo4j` | `meme1234` |

1. **PostgreSQL** como el usuario que solo lee.
   ```
   docker exec -it mesh-postgres psql -h postgres -U mesh_lectura -d mesh
   ```
   - `SELECT count(*) FROM pedido;` devuelve los pedidos, si puede leer.
   - `UPDATE pedido SET id_pedido = id_pedido WHERE false;` contesta
     `cannot execute UPDATE in a read-only transaction`.
   - `\q` para salir y entrar como el backend, el mismo comando con
     `-U mesh_backend`. `CREATE TABLE intruso (x int);` contesta
     `permission denied for schema public`.
   - Ojo, va con `-h postgres`. Con `localhost` entra sin clave y no probaria
     nada.
2. **MongoDB** como el usuario que solo lee.
   ```
   docker exec -it mesh-mongo mongosh -u mesh_lectura -p --authenticationDatabase admin mesh
   ```
   - `db.productos.countDocuments()` devuelve 1014, si puede leer.
   - `db.productos.updateOne({ _id: -1 }, { $set: { intruso: 1 } })` contesta
     `not authorized on mesh`.
   - `exit` y el mismo comando con `-u mesh_backend`. `db.prueba_acl.drop()`
     contesta `not authorized on mesh to execute command drop`.
3. **Redis** como el usuario de RedisInsight, que solo lee.
   ```
   docker exec -it mesh-redis redis-cli --user inspeccion --askpass
   ```
   - `DBSIZE` devuelve un numero, si puede leer.
   - `SET mesh:prueba:acl 1` contesta `NOPERM`.
   - `exit` y el mismo comando con `--user backend`. `KEYS *` contesta
     `NOPERM`. Nunca escribir `FLUSHALL`.
4. **ClickHouse** como el usuario que solo lee.
   ```
   docker exec -it mesh-clickhouse clickhouse-client --user mesh_lectura --ask-password --database mesh_eventos
   ```
   - `SELECT count() FROM vista_producto;` si.
   - `INSERT INTO vista_producto SELECT * FROM vista_producto WHERE 0;` contesta
     `Code 497 ACCESS_DENIED`.
5. **Neo4j**, la que no tiene roles.
   ```
   docker exec -it mesh-neo4j cypher-shell -u neo4j -d system
   ```
   - `CREATE ROLE lector;` contesta `Unsupported administration command`,
     porque la edicion community no trae roles.

Si el tiempo aprieta, solo 1, 3 y 4.

**Si preguntan por que esto no esta en Postman.** Postman solo habla HTTP.
Elasticsearch y ClickHouse contestan por HTTP y por eso tienen las carpetas 6 y
7. PostgreSQL, MongoDB y Redis tienen su propio protocolo, asi que se prueban
con su cliente de verdad, dentro de cada base. Todo junto, y mas, lo corre
`bash seguridad/prueba_acceso.sh`, 93 en verde.

### 28. Postman, la ruta directo
Y el control de las funciones, llamando al backend directo, sin la pagina.
Entramos como compradora y pedimos rutas de vendedor y de admin. Todas dan 403
con el permiso que falta. Despues como vendedor, las de admin dan 403. Y al final
el admin ve en el registro cada intento negado. La ultima carpeta intenta una
inyeccion SQL en el login, en un id y en el buscador, y no pasa, porque las
consultas van con parametros.

**Se hace (1 minuto).** En Postman, la coleccion **Mesh, control de acceso en
vivo**, **Run** y **Start run**. En unos once segundos salen 64 en verde. Si el
boton se queda en **Preparing to run**, Ctrl+R para recargar Postman y otra vez
**Start run**. Paso el 7 de noviembre y con eso corrio.
Despues, con **Send**, **Ver todas las cuentas** de la carpeta 2 para que se vea
el 403, y **Login con inyeccion SQL** de la carpeta 8 para que se vea el 401.

**Lo que se ensena, por dentro.**

**Entrar sin inyeccion SQL** (`src/services/usuario.service.ts:120`, `iniciarSesion()`)
- La consulta es `WHERE correo_electronico = $1 OR usuario = $1`, linea 137.
- Si preguntan por la ruta. `POST /usuario/login`, controller
  `src/controllers/usuario.controller.ts:154`, publica.
- Como explicarlo. Lo que escribe la persona viaja aparte como un valor y nunca
  se pega al SQL. `' OR '1'='1' --` es solo un correo que no existe.

**Un id con letras** (`src/services/compradores/pedidos.service.ts:126`, dentro de `obtener()`)
- Como explicarlo. Solo pasan digitos, `REGEX_ID` de la linea 20, y lo demas se
  corta con 400 antes de tocar la base.

**Si preguntan.** Cada peticion tiene su prueba en la pestana **Scripts**, y lo
que dio en **Test Results**. Las carpetas 0 a 7 son las 56 de permisos y la 8
las 8 de inyeccion. La coleccion completa se corrio el 6 de noviembre con Newman
y en Postman, 64 peticiones en verde, otra vez el 7 en el Postman de Jose
Manuel, ya con los 42 permisos, y el 8 con Newman despues del puntaje nuevo.
Esta en `presentacion-final/postman/`, y
`presentacion-final/postman/importar-a-postman.ps1` la mete con su ambiente en
el Postman de quien lo corra.

### 29. Gracias
Preguntas. Las respuestas cortas estan en `PREGUNTAS-SUSTENTACION.md`.

---

## Lo que pregunta el profesor, y el codigo

El 8 de noviembre el profesor le pregunto esto al grupo de Vidal, que presento
antes. Empezo por el diagrama y por como cambio la arquitectura, siguio con los
flujos de la aplicacion y lo que cambio desde las entregas, y pidio ver el codigo
de la busqueda en Elasticsearch y de la similitud de productos. Cada respuesta va
corta, con el archivo y la linea.

### Como cambio la arquitectura desde el inicio

**En una frase.** Empezamos con todo en PostgreSQL y fuimos sacando a otra base
lo que esa base hace mejor, pero el dinero y el stock nunca salieron de
PostgreSQL.

| Cuando | Que entro | Por que |
|---|---|---|
| Fase inicial | PostgreSQL y el diagrama entidad relacion | Pedidos, pagos y stock necesitan una transaccion que haga todo o nada |
| Entrega 1 | MongoDB, el catalogo | Cada categoria tiene atributos distintos, una laptop no se describe como una camisa. En columnas fijas quedarian casi vacias |
| Entrega 2 | Redis, el carrito y la venta relampago | Contesta al instante y su script Lua no deja vender mas unidades de las que hay |
| Entrega 2 | Neo4j, el fraude en resenas | Encuentra cuentas que se califican en circulo, que en SQL es una consulta larga y facil de equivocar |
| Entrega 2, despues | ClickHouse, los eventos | Las vistas y los clics son millones de filas con fecha, y se preguntan por periodo |
| Entrega 3 | Elasticsearch, el buscador | Encuentra aunque se escriba mal, sin tildes, y cuenta los filtros |
| Entrega final | pgvector dentro de PostgreSQL y Ollama | Recomendar por significado, con vectores |

**Cual es la fuente de verdad.** PostgreSQL. Lo que esta en las otras bases es
una copia que se puede rehacer desde ahi, menos los eventos de ClickHouse, que
nacen ahi. Esta en `docs/ARQUITECTURA.md:166` y es la regla de la lamina 5.

**El diagrama.** `docs/diagrama-arquitectura.png`, rehecho el 8 de noviembre en
blanco y negro con la notacion C4 por `docs/dibujar-arquitectura.py`. Las
personas arriba, la PC de la aplicacion con la tienda web, el backend y Ollama,
y la PC de las bases abajo. PostgreSQL al fondo y las otras cinco encima, cada
una con dos flechas numeradas hacia ella, explicadas en la tabla de abajo.

**El diagrama entidad relacion.** Es el de la Entrega 1 puesto al dia, 96
tablas y 126 llaves foraneas, en `docs/diagrama-er.png`. Lo agrega
`docs/actualizar-er.py` leyendo la base viva, sin mover lo que ya estaba.

### Lo que cambio desde que lo presentamos

| Antes | Ahora | Por que |
|---|---|---|
| El carrito vivia solo en Redis | El carrito de verdad es el pedido `pendiente` de PostgreSQL y Redis es la copia rapida | El profesor pidio que Redis nunca sea la verdad, 17 de octubre, ADR-21 |
| Los vectores se mudaron a Elasticsearch | Volvieron a pgvector en PostgreSQL | Lo pidio el profesor, y medido contra el calculo exacto acerto 1000 de 1001 contra 317, ADR-13 |
| Parecidos solo por nombre, categoria y descripcion | Tambien por las caracteristicas, con un segundo vector, y por la nota de las resenas | El profesor pregunto con que campos se calcula la similitud, 8 de noviembre, migracion 055 |
| Sin MongoDB no se podia comprar | Se compra igual | Lo que el pago necesita del producto tiene copia en `producto_catalogo`, ADR-18 |
| Si se caia una base se caia la tienda | Cada base tiene un cortacircuitos y un respaldo | Lo pidio el profesor el 19 de octubre, ADR-22 |
| Los permisos estaban escritos en el codigo | Viven en la tabla `rol_permiso` y se cambian desde el panel | Control de acceso por funcionalidad, ADR-26 |
| El fraude estaba en tres tablas | Una sola tabla, `senal_fraude` | Lo pidio el profesor el 28 de septiembre |
| El rol salia del token, que dura 2 horas | El rol se lee de la base en cada peticion | Si el admin le cambia el rol a alguien, vale en su peticion siguiente |

Todas las decisiones estan en `docs/DECISIONES.md`, del ADR-1 al ADR-26, y la
retrospectiva en el capitulo 7 del informe final.

### El control de acceso que pregunto

**Una pantalla para cambiar permisos sin abrir otra cosa.** Si, en el panel del
admin, pestana **Permisos**. Una casilla por rol y por permiso. Se marca o se
desmarca y vale en la peticion siguiente, sin compilar ni reiniciar. Abajo, **Lo
ultimo que paso**, con quien intento algo sin permiso.

**Quitar un permiso** (`src/services/acl/permisos.service.ts:341`, `revocar()`)
- Si preguntan por la ruta. `DELETE /admin/permisos/:idRol/:idPermiso`,
  controller `src/controllers/admin/admin-permisos.controller.ts:86`, con
  `@Permiso('permisos.administrar')`. Darlo es `POST` en la linea 61.
- Pagina. `frontend/src/lib/PanelPermisos.svelte:71`.
- Base. PostgreSQL, tabla `rol_permiso`, `migrations/050_permisos_por_rol.sql:70`.

**El ACL propio de Redis.** Si, con cuatro usuarios, en `docker-compose.yml` de
la linea 170 a la 205. El backend entra como `backend`, que solo toca claves que
empiezan con `mesh:` y no puede usar comandos peligrosos como `FLUSHALL` o
`KEYS`. `inspeccion` solo lee y es el de RedisInsight, `default` es el de los
scripts y `operador` el de mantenimiento.

**MongoDB y las demas, por servicio.** El backend nunca entra como dueno.
- MongoDB, `mesh_backend` con un rol hecho a medida que solo busca, inserta,
  cambia y borra documentos, sin borrar colecciones ni crear indices,
  `seguridad/mongo.js:37`.
- PostgreSQL, `mesh_backend` no es superusuario ni crea tablas ni usuarios,
  `seguridad/postgres.sql:36`, y `mesh_lectura` solo lee, linea 40.
- ClickHouse, `mesh_backend_rol` solo lee y agrega, `seguridad/clickhouse.sql:20`.
- Neo4j es la unica sin roles, porque la version gratis no los tiene.

**Que el carrito no pueda borrar usuarios.** Eso lo cuida la segunda capa, por
modulo. Cada ruta declara su permiso.
1. El carrito pide `carrito.usar`, `src/controllers/carrito/carrito.controller.ts:42`
2. Editar una cuenta pide `usuarios.editar`, `src/controllers/admin/admin-usuarios.controller.ts:42`
3. Quien no lo tiene recibe 403 en `src/guards/permiso.guard.ts:81`
4. Una ruta que olvide declarar su permiso tambien se niega, misma guard, linea 55

**La prueba.** `bash seguridad/prueba_acceso.sh`, 93 de 93, y la coleccion de
Postman, 64 de 64.

### La similitud semantica, con que campos

Hasta el 8 de noviembre el vector salia de un solo texto con tres campos, el
nombre, la categoria y la descripcion. Ese mismo dia sumamos lo que el profesor
pregunto. Ahora son dos vectores y la nota.

```
Vector general           Laptop Aurora 14. Categoria Laptops. Laptop de 14 pulgadas con ...
Vector de caracteristicas Color Gris grafito. Marca Aurora. Memoria RAM 16 GB, 32 GB.
```

**El texto general** (`src/services/productos/vectores-sync.service.ts:61`, `construirTexto()`)
- La carga completa del arranque usa el mismo texto, `etl/cargar_vectores.ps1:274`.

**El texto de caracteristicas** (`src/services/productos/vectores-sync.service.ts:98`, `construirTextoCaracteristicas()`)
- Junta las caracteristicas del producto y las de cada variante, una por
  nombre, ordenadas y sin repetir valores. Si no tiene ninguna queda vacio y el
  vector se guarda `NULL`.

**Pasarlos a vector y guardarlos** (`src/services/productos/vectores-sync.service.ts:462`, `guardar()`, y `:491`, `guardarCaracteristicas()`)
- Helper. `src/helpers/vectores-ollama.ts:33`, `pedirVectores()`.
- Base. PostgreSQL, `vector_producto`, `migrations/040_vectores_en_postgres.sql:40`,
  y el segundo vector en `migrations/055_vector_caracteristicas.sql:35`.

**Como pesa cada uno** (`src/services/productos/similares.service.ts:75`, `puntajeDe()`)
- 0,7 del parecido general, 0,2 del de caracteristicas y 0,1 de la nota de las
  resenas. La categoria decide el bloque, primero los de la misma.
- Como explicarlo. Un vector aparte deja decidir cuanto pesa cada cosa. Si las
  caracteristicas fueran dentro del mismo texto, no se podria decir cuanto
  pesan, y un producto sin caracteristicas tendria un vector distinto solo por
  eso.

### El codigo que pidio ver

#### La busqueda de productos en Elasticsearch

**Buscar con filtros y con errores** (`src/services/buscador/facetado.service.ts:99`, `buscar()`)
- La consulta la arma `construirConsulta()`, linea 178.
- Helper. `src/helpers/correccion-busqueda.ts:40`, `pedirCorreccion()`, el Tal
  vez quisiste decir.
- Si preguntan por la ruta. `GET /buscador/productos/facetado`, controller
  `src/controllers/buscador/facetado.controller.ts:30`, publica.
- Pagina. `frontend/src/routes/buscar/+page.svelte:156`, con `buscarFacetado()`
  de `frontend/src/lib/buscador.ts:397`.
- Base. Elasticsearch, indice `mesh_productos`, armado en `elastic/001_indice.json`.

```ts
multi_match: {
  query: texto,
  fields: ['nombre^3', 'descripcion', 'variantes'],
  fuzziness: 'AUTO',
},
...
query: {
  bool: {
    must: [textoQuery],
    filter: [
      { term: { estado: 'activo' } },
      ...this.clausulasDeFiltro(elegidos),
    ],
  },
},
aggs: {
  categoria: { terms: { field: 'id_categoria', size: 50 } },
  precio: { range: { field: 'precio_desde', ranges: RANGOS_PRECIO } },
  calificacion: { range: { field: 'resenas_promedio', ranges: RANGOS_NOTA } },
  disponible: { filter: { range: { stock_total: { gt: 0 } } } },
},
```

Como explicarlo, linea por linea.
- `multi_match`, linea 187. Busca lo escrito en tres campos a la vez.
- `nombre^3`, linea 189. Una coincidencia en el nombre pesa tres veces mas que
  en la descripcion, por eso los productos que se llaman asi salen primero.
- `fuzziness: 'AUTO'`, linea 190. Perdona letras de mas, de menos o cambiadas.
  Una en palabras de 3 a 5 letras y dos en las mas largas. Asi `labtop`
  encuentra laptop.
- `filter`, linea 200. Lo que tiene que cumplirse si o si, que el producto este
  activo y lo que se marco en los filtros. No cambia el orden, solo recorta.
- `aggs`, linea 206. Cuenta cuantos resultados hay por categoria, por precio,
  por calificacion y con existencias. Son los numeros del panel de la izquierda,
  y se cuentan sobre lo que ya paso el filtro.
- `suggest`, linea 196. Es el **Tal vez quisiste decir laptop**.
- Que no distinga tildes ni mayusculas lo hace el analizador `espanol_llano`,
  `elastic/001_indice.json:8`, con `lowercase` y `asciifolding`.

**La lista mientras se escribe** (`src/services/buscador/productos.service.ts:88`, `buscar()`)
- Si preguntan por la ruta. `GET /buscador/productos`, controller
  `src/controllers/buscador/productos.controller.ts:36`, publica.
- Como explicarlo. Junta la misma busqueda difusa con `bool_prefix` sobre
  `nombre.escribiendo`, linea 159, que encuentra con la palabra a medias, `lap`
  ya trae Laptop.

#### La similitud de productos, en PostgreSQL con pgvector

Se usa PostgreSQL, no Elasticsearch. Los vectores estuvieron en Elasticsearch del
4 al 16 de octubre y volvieron, porque el profesor pidio pgvector y porque al
medir contra el calculo exacto pgvector acerto 1000 de 1001 y Elasticsearch 317.

**Parecidos a este** (`src/services/productos/similares.service.ts:123`, `obtener()`)
- Los candidatos, `buscarSimilares()`, linea 152, y el puntaje, `puntuar()`,
  linea 277.
- Helper. `src/helpers/vectores-pgvector.ts:41`, `buscarCercanos()`.
- Si preguntan por la ruta. `GET /productos/:id/similares`, controller
  `src/controllers/productos/similares.controller.ts:20`, publica.
- Pagina. `traerSimilares()` de `frontend/src/routes/producto/[id]/+page.svelte:178`.
- Base. PostgreSQL con pgvector, tabla `vector_producto`,
  `migrations/040_vectores_en_postgres.sql:40`, indice HNSW en la linea 69.

Los vecinos, el bloque 2, linea 201.

```sql
SELECT id_producto_mongo, grupo, 1 - (vector <=> $1::vector) AS similitud
  FROM vector_producto
 WHERE activo
   AND id_producto_mongo <> $2
   AND grupo <> $3
 ORDER BY vector <=> $1::vector
 LIMIT $4
```

El puntaje de esos candidatos, linea 291.

```sql
SELECT v.id_producto_mongo,
       CASE WHEN v.vector_caracteristicas IS NULL OR $2::vector IS NULL
            THEN NULL
            ELSE 1 - (v.vector_caracteristicas <=> $2::vector)
       END AS parecido_caracteristicas,
       r.promedio, coalesce(r.total, 0)::int AS total
  FROM vector_producto v
  LEFT JOIN (SELECT id_producto_mongo, avg(calificacion)::float8 AS promedio,
                    count(*) AS total
               FROM resena
              WHERE id_estado_resena = 1 AND id_producto_mongo = ANY($1::bigint[])
              GROUP BY id_producto_mongo) r USING (id_producto_mongo)
 WHERE v.id_producto_mongo = ANY($1::bigint[])
```

```ts
export function puntajeDe(
  general: number,
  caracteristicas: number | null,
  promedio: number | null,
  totalResenas: number,
): number {
  const suma = (promedio ?? 0) * totalResenas;
  const nota =
    (suma + RESENAS_PREVIAS * NOTA_PREVIA) / (totalResenas + RESENAS_PREVIAS);
  return (
    PESO_GENERAL * general +
    PESO_CARACTERISTICAS * (caracteristicas ?? general) +
    PESO_NOTA * (nota / 5)
  );
}
```

Como explicarlo.
- `<=>` es la distancia coseno de pgvector. Cero es identico. `1 - distancia` es
  el parecido que se ensena.
- `ORDER BY vector <=> $1` trae primero los mas cercanos, y el indice HNSW lo
  hace sin comparar contra todos. `$1` es el vector del producto de la ficha,
  como parametro.
- `id_producto_mongo <> $2` saca al propio producto, y `grupo <> $3` saca sus
  copias, que solo cambian el sufijo del nombre.
- La del bloque 1, linea 184, es igual pero solo con los de su misma categoria.
- La segunda consulta mira solo esos candidatos, por su id, asi la primera
  sigue usando el indice. Saca el parecido de caracteristicas sin traer los
  vectores, y la nota de las resenas publicadas.
- `caracteristicas ?? general` es la regla de que si falta, vale lo mismo que el
  general. La nota suma dos resenas imaginarias de 3 estrellas.
- `buscarCercanos()` sube antes `hnsw.ef_search`, linea 50 del helper, para que
  el indice mire suficientes candidatos.

---

## Los flujos de toda la tienda, de la pagina a la base

Cada flujo tiene su titulo, la accion con el service que hace la logica, y
despues el helper, la ruta con su controller y su permiso, la pagina, la base y
como explicarlo. En el backend siempre es igual, el controller recibe, el
service trabaja y la base guarda.

**Como viaja cualquier peticion.**
1. La pagina llama `pedir()`, `frontend/src/lib/api.ts:107`, que manda la cookie
2. Pide `/api/...` y Vite le quita el `/api` y la pasa al 3000, `frontend/vite.config.ts:53`
3. Fastify la recibe, `src/main.ts:34`
4. Los guards revisan sesion y permiso, `src/guards/sesion.guard.ts:71` y `src/guards/permiso.guard.ts:41`
5. El controller, en `src/controllers/`, llama al service, en `src/services/`
6. La respuesta sale siempre con `ok`, `mensaje` y `payload`, `src/helpers/respuesta.ts:19`

### Sin sesion

#### La portada y el catalogo
Abrir la tienda (`src/services/productos/productos.service.ts:132`, `listar()`, y `:179`, `listarPaginado()`)
- Si preguntan por la ruta. `GET /productos` y `GET /productos/paginacion`,
  controller `src/controllers/productos/productos.controller.ts:28` y `:41`,
  publicas.
- Pagina. `frontend/src/routes/+page.svelte`, `buscar()` en la linea 656.
- Base. MongoDB, un `find` en la linea 148, y en la paginada un `$facet` en la 196.
- Como explicarlo. El `$facet` trae la pagina y el total en una sola consulta.

#### Lo mas vendido
Ver Lo mas vendido ahora (`src/services/productos/mas-vendidos.service.ts:57`, `obtener()`)
- Lo calcula el worker `src/services/productos/mas-vendidos-sync.service.ts:117`,
  cada 10 minutos, contando `compra_producto` de ClickHouse en la linea 195.
- Si preguntan por la ruta. `GET /productos/mas-vendidos`, controller
  `src/controllers/productos/mas-vendidos.controller.ts:25`, publica.
- Pagina. `frontend/src/routes/+page.svelte`, `cargarMasVendidos()` en la 955.
- Como explicarlo. El worker cuenta en ClickHouse y deja la lista en Redis, y la
  portada la lee de Redis al instante.

#### Buscar mientras se escribe, en la cabecera
Escribir en Buscar productos (`src/services/buscador/productos.service.ts:88`, `buscar()`)
- La consulta en `ejecutar()`, linea 132, con `bool_prefix` en la 159 y la
  difusa en la 146.
- Si preguntan por la ruta. `GET /buscador/productos`, controller
  `src/controllers/buscador/productos.controller.ts:36`, publica.
- Pagina. `frontend/src/lib/BuscadorCabecera.svelte:108`, que espera 250 ms
  despues de la ultima tecla, linea 89.
- Como explicarlo. Encuentra con la palabra a medias y con errores, desde dos
  letras.

#### La pagina de resultados, `/buscar`
Dar Enter en el buscador (`src/services/buscador/facetado.service.ts:99`, `buscar()`)
- Pagina. `frontend/src/routes/buscar/+page.svelte:156` decide que pedir.
  Siempre la facetada, la hibrida si no hay filtros marcados, y la de intencion
  si es una frase, `pareceFrase()` en `frontend/src/lib/buscador.ts:232`.
- Los filtros viajan en la direccion, `cat`, `precio`, `nota` y `disp`.
- Como explicarlo. La facetada es la del codigo que pidio ver, arriba. Las otras
  dos tienen su flujo aqui abajo.

#### Busqueda hibrida, palabras y significado
Buscar sin filtros (`src/services/buscador/hibrida.service.ts:128`, `buscar()`)
- Por palabras en Elasticsearch, `buscarPorTexto()`, linea 186. Por significado
  en PostgreSQL, `buscarPorSignificado()`, linea 247, con la consulta en la 260.
  Las junta `combinar()`, linea 352.
- Helper. `src/helpers/vectores-ollama.ts:33`, `pedirVectores()`, el vector de la
  frase.
- Si preguntan por la ruta. `GET /buscador/productos/hibrida`, controller
  `src/controllers/buscador/hibrida.controller.ts:20`, publica.
- Pagina. `buscarHibrida()` en `frontend/src/lib/buscador.ts:196`.
- Como explicarlo. Hace las dos busquedas a la vez y las junta por posicion. Si
  Ollama no contesta, sale solo por palabras.

#### Busqueda por intencion, Lo que cuentan otros compradores
Buscar una frase de tres palabras o mas (`src/services/buscador/intencion.service.ts:108`, `buscar()`)
- Si preguntan por la ruta. `GET /buscador/productos/intencion`, controller
  `src/controllers/buscador/intencion.controller.ts:22`, publica.
- Pagina. `buscarPorIntencion()` en `frontend/src/lib/buscador.ts:262`.
- Base. PostgreSQL, `vector_comentario`, linea 202.
- Como explicarlo. Compara la frase con el vector de cada resena publicada y
  ensena la resena que explica por que sale el producto. Pide al menos 0,45 de
  parecido, linea 34.

#### Cuando no encuentra nada
Buscar algo que no existe (`src/services/buscador/sugeridos.service.ts:82`, `sugerir()`)
- Primero Elasticsearch, `desdeElastic()` en la linea 117, si no por
  significado, `porSignificado()` en la 152, y si no lo mas vendido, en la 177.
- Como explicarlo. Sale **Te pueden interesar** debajo de los cero resultados.

#### La ficha de un producto
Clic en un producto (`src/services/productos/productos.service.ts:265`, `obtenerPublico()`)
- Helper. `src/helpers/catalogo-respaldo.ts:190`, `productosDesdePostgres()`, si
  MongoDB no contesta, linea 292.
- Si preguntan por la ruta. `GET /productos/:id`, controller
  `src/controllers/productos/productos.controller.ts:100`, publica.
- Pagina. `frontend/src/routes/producto/[id]/+page.svelte`, `traer()` en la 241.
- Base. MongoDB, `findOne` en la linea 282, y las ofertas con su precio y stock
  de PostgreSQL.
- Como explicarlo. El producto, sus variantes y caracteristicas salen de MongoDB,
  y quien lo vende, a que precio y cuantas quedan, de PostgreSQL.

#### Parecidos a este
Es el flujo de la similitud, arriba, en **El codigo que pidio ver**, y en la
lamina 19.

#### Quienes lo compraron tambien llevaron
Bajar en la ficha (`src/services/productos/tambien-compraron.service.ts:59`, `obtener()`)
- Si preguntan por la ruta. `GET /productos/:id/tambien-compraron`, controller
  `src/controllers/productos/tambien-compraron.controller.ts:22`, publica.
- Pagina. `traerTambienCompraron()` en la ficha, linea 198.
- Base. Neo4j, el Cypher de la linea 130.
- Como explicarlo. Va de este producto a quien lo compro y de ahi a lo que
  tambien compro. La misma categoria va primero por el `CASE WHEN` de la linea
  136.

#### Quienes vieron esto tambien vieron
Bajar en la ficha (`src/services/productos/tambien-vieron.service.ts:35`, `obtener()`)
- Lo calcula el worker `src/services/productos/tambien-vieron-sync.service.ts:94`,
  cada 15 minutos, con la consulta a ClickHouse de la linea 110.
- Si preguntan por la ruta. `GET /productos/:id/tambien-vieron`, controller
  `src/controllers/productos/tambien-vieron.controller.ts:21`, publica.
- Pagina. `traerTambienVieron()` en la ficha, linea 156.
- Como explicarlo. Cuenta en ClickHouse lo que vieron las mismas sesiones y lo
  deja listo en Redis.

#### Las resenas de la ficha
Pestana Resenas (`src/services/resenas/resenas.service.ts:112`, `listarDeProducto()`)
- Si preguntan por la ruta. `GET /productos/:id/resenas`, controller
  `src/controllers/resenas/resenas.controller.ts:53`, publica.
- Pagina. `frontend/src/lib/Resenas.svelte`.
- Base. PostgreSQL, solo las publicadas, linea 138.

#### Cada vista de producto
Abrir una ficha (`src/services/eventos/eventos.service.ts:21`, `registrarVista()`)
- Si preguntan por la ruta. `POST /eventos/vista`, controller
  `src/controllers/eventos.controller.ts:56`, publica.
- Pagina. La ficha llama `registrarVista()` en la linea 274, de
  `frontend/src/lib/eventos.ts:22`.
- Base. ClickHouse, `clickhouse.insert` en la linea 29.
- Como explicarlo. Guarda la vista como un evento. De ahi salen Lo mas visto y
  las tendencias.

### La cuenta

#### Registrarse
Crear una cuenta (`src/services/usuario.service.ts:74`, `registrar()`)
- Helper. `src/helpers/contrasena.ts:17`, `hashearContrasena()`, guarda la clave
  convertida con scrypt.
- Si preguntan por la ruta. `POST /usuario/registro`, controller
  `src/controllers/usuario.controller.ts:115`, publica.
- Pagina. `frontend/src/routes/registro/+page.svelte`, `validar()` en la 41 y
  `registrar()` en la 163.
- Base. PostgreSQL, `INSERT INTO usuarios` en la linea 82.
- Como explicarlo. Pide correo valido, usuario de hasta 50 letras, nombre y una
  clave de 8 o mas con una mayuscula y un caracter especial. No abre sesion,
  manda a `/entrar?registrado=1`.

#### Entrar
Iniciar sesion (`src/services/usuario.service.ts:120`, `iniciarSesion()`)
- Helpers. `src/helpers/contrasena.ts:31`, `compararContrasena()`, y
  `src/helpers/token.ts:48`, `firmarToken()`.
- Si preguntan por la ruta. `POST /usuario/login`, controller
  `src/controllers/usuario.controller.ts:154`, publica. La cookie la pone en la
  linea 170.
- Pagina. `frontend/src/routes/entrar/+page.svelte`, `entrar()` en la 53.
- Base. PostgreSQL, `WHERE correo_electronico = $1 OR usuario = $1`, linea 137.
- Como explicarlo. Busca la cuenta, compara la clave, firma el token y lo deja
  en la cookie `mesh_token`, httpOnly y de 2 horas, `src/helpers/token.ts:11` y
  `:25`. Sin hacer esperar, en las lineas 171 a 199 del controller, anota el
  intento en MongoDB, suma los contadores de Redis y revisa toma de cuenta y
  viaje imposible.

#### Lo que pasa en cada peticion con sesion
Cualquier clic con sesion (`src/services/acl/permisos.service.ts:106`, `tiene()`)
- `SesionGuard`, `src/guards/sesion.guard.ts:71`, sin cookie 401 en la linea 77.
  El rol de hoy en la linea 94, con `estadoDeSesion()` de
  `src/services/usuario.service.ts:247`.
- `PermisoGuard`, `src/guards/permiso.guard.ts:41`. Si no lo tiene, anota en la
  linea 74 y 403 en la 81.
- Pagina. `verificarSesion()` de `frontend/src/lib/sesion.ts:137` pregunta
  `GET /usuario/yo`, con 401 manda a entrar y con 503 no saca a nadie.
- Como explicarlo. El primero dice quien eres, el segundo que puedes.

#### Salir
Clic en Salir (`src/controllers/usuario.controller.ts:270`, sin service)
- Si preguntan por la ruta. `POST /usuario/logout`, publica. Borra la cookie en
  la linea 289.
- Pagina. `frontend/src/lib/Cabecera.svelte:139`.

### Como compradora

#### Agregar al carrito
Clic en **Agregar** junto a un vendedor (`src/services/carrito/carrito.service.ts:242`, `definirCantidad()`)
- La copia en Redis, clave `mesh:carrito:<cuenta>`,
  `src/services/carrito/carrito-redis.service.ts:90`. La verdad en PostgreSQL,
  `carritoPostgres.escribir()` en la linea 365.
- Si preguntan por la ruta. `PUT /carrito/lineas/:idOferta`, controller
  `src/controllers/carrito/carrito.controller.ts:60`, con
  `@Permiso('carrito.usar')` en la linea 42.
- Pagina. La ficha, `alPedido()` en la linea 615, la llamada en la 690.
- Como explicarlo. Guarda la linea en Redis y contesta al instante, y debajo la
  copia a PostgreSQL, que es la verdad. Si es venta relampago, antes reserva con
  el script Lua, `reservar()` en
  `src/services/inventario-limitado/inventario-limitado.service.ts:540`.

#### Ver, cambiar, quitar y vaciar el carrito
Abrir **Tu carrito** (`src/services/carrito/carrito.service.ts:202`, `verCarrito()`, `:428`, `quitarLinea()`, y `:484`, `vaciar()`)
- Si preguntan por la ruta. `GET /carrito`, `PUT` y `DELETE /carrito/lineas/:idOferta`
  y `DELETE /carrito`, controller `src/controllers/carrito/carrito.controller.ts`
  lineas 47, 60, 79 y 96, todas con `@Permiso('carrito.usar')`.
- Pagina. `frontend/src/lib/CarritoRedis.svelte`, `cargar()` 186,
  `cambiarCantidad()` 222, `quitar()` 261 y `vaciar()` 291.
- Como explicarlo. Lee de Redis, y si Redis no lo tiene lo rehace desde
  PostgreSQL, `verDesdePostgres()` en la linea 1252.

#### Pagar
Clic en **Pagar** (`src/services/carrito/carrito.service.ts:634`, `comprarCarrito()`)
- El candado del doble clic, `conCandadoCheckout()` en
  `src/services/carrito/carrito-redis.service.ts:385`, un `SET NX EX 30` en la
  396.
- La transaccion, `BEGIN` 683, `SELECT comprar_pedido($1, $2)` 851, `COMMIT`
  876, y si falla `ROLLBACK` 879.
- Si preguntan por la ruta. `POST /carrito/comprar`, controller
  `src/controllers/carrito/carrito.controller.ts:124`, con
  `@Permiso('carrito.comprar')` en la linea 123.
- Pagina. `frontend/src/lib/Checkout.svelte`, `confirmar()` en la 702, la
  llamada en la 757.
- Base. PostgreSQL, `comprar_pedido()` de `migrations/020_descuentos_oferta.sql:226`.
- Como explicarlo. `comprar_pedido()` recorre las lineas en orden de oferta,
  280, bloquea cada oferta con `FOR UPDATE`, 287, revisa el stock, 294, escribe
  el kardex, 301, resta el stock, 309, suma con el descuento, 314, registra el
  pago, 333, y pasa el pedido a comprado, 339. Todo o nada. Despues del COMMIT,
  sin poder deshacer la compra, la manda a ClickHouse, linea 905 del service,
  Neo4j la recibe por la cola de la migracion 041 y MongoDB pone al dia el stock
  de la tarjeta por la cola `evento_producto`. La pagina pasa a `/gracias`, desde
  `alComprado()` en `frontend/src/routes/+layout.svelte:48`.

#### Mis pedidos y cancelar
Mis pedidos y **Cancelar** (`src/services/compradores/pedidos.service.ts:66`, `listar()`, y `:251`, `cancelarPedido()`)
- La cancelacion la hace `ejecutarCancelacion()`, linea 352.
- Si preguntan por la ruta. `GET /comprador/pedidos` con
  `@Permiso('pedidos.ver')` y `POST /comprador/pedidos/:id/cancelar` con
  `@Permiso('pedidos.cancelar')`, controller
  `src/controllers/compradores/pedidos.controller.ts:37` y `:80`.
- Pagina. `frontend/src/lib/MisPedidos.svelte`, `cargar()` 137 y `cancelar()` 260.
- Base. PostgreSQL, `cancelar_pedido_por()` de `migrations/051_pedidos_de_la_tienda.sql:75`.
- Como explicarlo. Devuelve las unidades a cada oferta y deja el pago
  reembolsado, solo mientras esta comprado. El id se revisa antes de tocar la
  base, solo digitos, linea 20 del service.

#### Resenar
Escribir una resena (`src/services/resenas/resenas.service.ts:288`, `crear()`)
- Si preguntan por la ruta. `POST /resenas`, controller
  `src/controllers/resenas/resenas.controller.ts:119`, con
  `@Permiso('resenas.escribir')`.
- Pagina. `frontend/src/lib/Resenas.svelte`, `enviar()` 365, la llamada en la 388.
- Base. PostgreSQL, exige compra pagada en la linea 303 e inserta en la 315. Un
  trigger la encola para Neo4j, `migrations/015_outbox_grafo.sql:176`.
- Como explicarlo. Solo resena quien compro y pago. Despues, sin esperar, busca
  anillos al instante, lineas 330 y 331, y revisa el texto, linea 336.

#### Avisame si baja de precio
Clic en **Avisame si baja de precio** (`src/services/compradores/seguimientos-oferta.service.ts:120`, `crear()`)
- Cada oferta que cambia se prueba contra todos los avisos en
  `src/services/compradores/percolar-seguimientos.service.ts:38`, `percolar()`,
  con `percolate` en la linea 57.
- Si preguntan por la ruta. `POST /comprador/seguimientos`, controller
  `src/controllers/compradores/seguimientos-oferta.controller.ts:48`, con
  `@Permiso('avisos.usar')`.
- Pagina. La ficha, `seguirPrecio()` 218, con `seguirBajaDePrecio()` de
  `frontend/src/lib/seguimientos.svelte.ts:91`. Los avisos se ven en
  `frontend/src/lib/AvisosSeguimiento.svelte:37`.
- Base. PostgreSQL guarda el seguimiento y el percolator de Elasticsearch guarda
  la busqueda.
- Como explicarlo. El percolator guarda busquedas en vez de productos, y cada
  oferta nueva se prueba contra ellas.

#### Para ti
Volver a la portada con sesion (`src/services/productos/para-ti.service.ts:65`, `obtener()`)
- Si preguntan por la ruta. `GET /productos/para-ti`, controller
  `src/controllers/productos/para-ti.controller.ts:28`, con
  `@Permiso('productos.para_ti')`.
- Base. Neo4j, el Cypher de la linea 164.
- Como explicarlo. Lo que compraron quienes compraron lo mismo que tu.

### Como vendedor

#### Proponer un producto
Proponer y **Enviar a revision** (`src/services/vendedores/productos.service.ts:260`, `proponer()`)
- Antes, al salir del nombre, las sugerencias,
  `src/services/vendedores/sugerencias-propuesta.service.ts:113`, `sugerir()`.
- Si preguntan por la ruta. `POST /vendedor/productos/sugerencias`, controller
  `src/controllers/vendedores/sugerencias-propuesta.controller.ts:30`, y
  `POST /vendedor/productos/propuestas`, controller
  `src/controllers/vendedores/productos.controller.ts:218`, las dos con
  `@Permiso('catalogo.proponer')`.
- Pagina. `frontend/src/lib/PanelVendedor.svelte`, `sugerir()` 656 al salir del
  nombre y `guardar()` 680 al enviar.
- Base. MongoDB, `insertOne` en la linea 344, nace `en_revision`.
- Como explicarlo. Al escribir el nombre, lo pasa a vector y busca los mas
  parecidos. Desde 0,85 de parecido dice **Puede que ya exista**, linea 37 del
  service de sugerencias.

#### Publicar una oferta
**Publicar la oferta** (`src/services/vendedores/ofertas.service.ts:285`, `crear()`)
- Si preguntan por la ruta. `POST /vendedor/ofertas`, controller
  `src/controllers/vendedores/ofertas.controller.ts:176`, con
  `@Permiso('ofertas.publicar')`.
- Pagina. `frontend/src/lib/OfertasVendedor.svelte`, `publicar()` 1729.
- Base. PostgreSQL, tabla `oferta`.
- Como explicarlo. La de un vendedor nace `pendiente` y la de la tienda
  `activa`, linea 295.

#### Ponerle descuento
**Descuento** en una oferta (`src/services/vendedores/ofertas.service.ts:627`, `aplicarDescuento()`)
- Helper. `src/helpers/precio-descuento.ts:20`, `expresionPrecioFinal()`.
- Si preguntan por la ruta. `POST /vendedor/ofertas/:id/descuento`, controller
  `src/controllers/vendedores/ofertas.controller.ts:222`, con
  `@Permiso('ofertas.descuento')`.
- Pagina. `frontend/src/lib/OfertasVendedor.svelte`, `aplicarDescuento()` 1528.
- Como explicarlo. El precio final no se guarda, se calcula con
  `ROUND(precio * (1 - porcentaje / 100), 2)`, `migrations/020_descuentos_oferta.sql:33`.

#### Abrir una venta relampago
**Abrir venta relampago** (`src/services/vendedores/ventas-limitadas.service.ts:83`, `abrir()`)
- La abre en Redis `activar()`, en
  `src/services/inventario-limitado/inventario-limitado.service.ts:214`.
- Si preguntan por la ruta. `POST /vendedor/ofertas/:id/venta-limitada`,
  controller `src/controllers/vendedores/ventas-limitadas.controller.ts:42`, con
  `@Permiso('ofertas.venta_relampago')`.
- Pagina. `frontend/src/lib/OfertasVendedor.svelte`, `abrirRelampago()` 1373.
- Base. Redis, el script `redis/inventario_limitado.lua`, operacion `reservar`
  en la linea 272.
- Como explicarlo. Cada reserva compara y descuenta en un solo paso, y si no hay
  contesta `AGOTADO`, linea 303. Por eso nunca se vende de mas.

#### Compartir una oferta
**Compartir** (`src/services/acl/acl-ofertas.service.ts:244`, `otorgar()`)
- Si preguntan por la ruta. `POST /vendedor/ofertas/:id/permisos`, controller
  `src/controllers/vendedores/permisos-oferta.controller.ts:57`, con
  `@Permiso('ofertas.compartir')`.
- Pagina. `frontend/src/lib/CompartirOferta.svelte`, `dar()` 100.
- Base. PostgreSQL, tabla `permiso_oferta`, `migrations/049_acl_ofertas.sql:61`.
- Como explicarlo. La otra cuenta la usa en **Compartidas**. Cada ruta pasa por
  `src/guards/permiso-oferta.guard.ts:42` y `comprobar()` en
  `src/services/acl/acl-ofertas.service.ts:83`. Sin ninguna entrada 404, linea
  132, y con ver pero sin editar 403, linea 134.

#### Reglas de descuento
**Nueva regla** (`src/services/reglas-descuento-automatico/reglas-descuento-automatico.service.ts:94`, `crear()`)
- La aplica el worker
  `src/services/reglas-descuento-automatico/disparador-reglas-automatico.service.ts:85`,
  cada minuto.
- Si preguntan por la ruta. `POST /vendedor/reglas-descuento`, controller
  `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts:44`,
  con `@Permiso('reglas.administrar')`.
- Pagina. `frontend/src/lib/ReglasDescuento.svelte`.
- Como explicarlo. Cada minuto el worker mira las ventas en ClickHouse y aplica
  la regla.

#### Buscar entre sus ofertas
Buscar en **Mis ofertas** (`src/services/vendedores/buscar-ofertas.service.ts:65`, `buscar()`)
- Si preguntan por la ruta. `GET /vendedor/ofertas/buscar`, controller
  `src/controllers/vendedores/buscar-ofertas.controller.ts:28`, con
  `@Permiso('ofertas.ver')`.
- Pagina. `frontend/src/lib/BuscarOfertas.svelte`.
- Base. Elasticsearch, indice `mesh_ofertas`.

### Como admin

#### Aprobar un producto
**Aprobar** en Propuestas (`src/services/vendedores/productos.service.ts:575`, `revisarPropuesta()`)
- Si preguntan por la ruta. `PATCH /vendedor/productos/:id/revision`,
  controller `src/controllers/vendedores/productos.controller.ts:238`, con
  `@Permiso('catalogo.revisar')`.
- Pagina. `frontend/src/lib/PropuestasProducto.svelte`, `revisar()` 120.
- Base. MongoDB, pasa a `activo`.
- Como explicarlo. Al aprobarlo, los workers lo llevan al buscador y le calculan
  sus dos vectores, por eso aparece solo.

#### Aprobar una oferta
**Aprobar** en Ofertas por revisar (`src/services/vendedores/ofertas.service.ts:942`, `revisar()`)
- Si preguntan por la ruta. `PATCH /vendedor/ofertas/:id/revision`, controller
  `src/controllers/vendedores/ofertas.controller.ts:197`, con
  `@Permiso('ofertas.revisar')`.
- Pagina. `frontend/src/lib/OfertasVendedor.svelte`, `revisar()` 1928.

#### Dashboard
Pestana **Dashboard** (`src/services/dashboards/dashboard-general.service.ts:81`, `resumen()`)
- Si preguntan por la ruta. `/admin/dashboard/...`, controller
  `src/controllers/dashboards/dashboard-general.controller.ts:67` en adelante,
  con `@Permiso('dashboard.ver')` en la linea 59. **Exportar** pide
  `dashboard.exportar`, lineas 175, 200 y 225, para Excel, PDF y correo.
- Pagina. `frontend/src/lib/PanelDashboard.svelte`, `cargarTodo()` 224 y
  `exportar()` 536.
- Base. PostgreSQL.
- Como explicarlo. Cifras del periodo contra el anterior.

#### Pedidos de la tienda
La columna **Gestion** (`src/services/compradores/pedidos.service.ts:284`, `cancelarComoTienda()`, y `:315`, `marcarEnvio()`)
- Si preguntan por la ruta. `POST /admin/pedidos/:id/cancelar`, `/enviado` y
  `/entregado`, controller `src/controllers/admin/admin-pedidos.controller.ts:34`,
  `:55` y `:73`, con `@Permiso('pedidos.administrar')`.
- Pagina. `frontend/src/lib/PanelDashboard.svelte:275`.
- Base. PostgreSQL, `cancelar_pedido_por()` y `marcar_envio_pedido()` de
  `migrations/051_pedidos_de_la_tienda.sql`, lineas 75 y 186.
- Como explicarlo. Cancela cualquier pedido o lo marca enviado o entregado. Si
  cancela la tienda, no se culpa al comprador en el fraude.

#### Reportes
Pestana **Reportes** (`src/services/admin/admin-reportes.service.ts:109`, `ventas()`)
- Si preguntan por la ruta. `GET /admin/reportes/ventas`, controller
  `src/controllers/admin/admin-reportes.controller.ts:40`, con
  `@Permiso('reportes.ver')`.
- Pagina. `frontend/src/lib/PanelReportes.svelte`.
- Base. PostgreSQL.

#### Catalogo, historial a una fecha
**Historial** de un producto (`src/services/productos/productos.service.ts:398`, `reconstruirEnFecha()`)
- La ruta entra por `src/services/vendedores/productos.service.ts:1652`,
  `obtenerHistorialPropio()`, que lo llama.
- Si preguntan por la ruta. `GET /vendedor/productos/:id/historial?fecha=`,
  controller `src/controllers/vendedores/productos.controller.ts:158`, con
  `@Permiso('catalogo.ver')`.
- Pagina. `frontend/src/lib/PanelVendedor.svelte`, `reconstruir()` 824.
- Base. MongoDB, agregacion en la linea 419, con `$match` 421, `$sort` 426 y
  `$group` 428.
- Como explicarlo. Junta los eventos del producto en orden y lo rehace como era
  ese dia. El precio y el stock de ese dia salen de PostgreSQL,
  `reconstruirOfertas()` 871 en la pagina y `reconstruirOfertaEnFecha()` 501 en
  el service.

#### Catalogo, las ofertas de un producto
**Ofertas** de un producto (`src/services/vendedores/ofertas.service.ts:794`, `listarDeProducto()`, y `:840`, `administrar()`)
- Si preguntan por la ruta. `GET` y `PATCH /admin/ofertas`, controller
  `src/controllers/admin/admin-ofertas.controller.ts:40` y `:51`, con
  `@Permiso('ofertas.administrar')`.
- Pagina. `frontend/src/lib/PanelVendedor.svelte`, `traerOfertasDe()` 287 y
  `cambiarOferta()` 307.
- Como explicarlo. Pausa, retira o ajusta las unidades de la oferta de cualquier
  vendedor. El precio no lo toca.

#### Catalogo, categorias
**Categorias** (`src/services/admin/admin-categorias.service.ts:195`, `renombrar()`)
- Crear es `crear()`, linea 116, y agregar una caracteristica
  `agregarCaracteristica()`, linea 266.
- Si preguntan por la ruta. `/admin/categorias`, controller
  `src/controllers/admin/admin-categorias.controller.ts:51`, `:64` y `:81`, con
  `@Permiso('catalogo.categorias')`.
- Pagina. `frontend/src/lib/CategoriasTienda.svelte`, `crear()` 109 y
  `guardarNombre()` 141.
- Base. PostgreSQL y MongoDB, `updateMany` en la linea 233.
- Como explicarlo. Cambia el nombre de la categoria en todos sus productos con
  una sola orden.

#### Cuentas
Pestana **Cuentas** (`src/services/admin/admin-usuarios.service.ts:70`, `actualizar()`)
- Si preguntan por la ruta. `GET` y `PATCH /admin/usuarios`, controller
  `src/controllers/admin/admin-usuarios.controller.ts:27` y `:43`, con
  `@Permiso('usuarios.ver')` y `usuarios.editar`.
- Pagina. `frontend/src/lib/PanelAdmin.svelte`, `cargar()` 51 y `cambiar()` 85.
- Como explicarlo. Cambia el rol o bloquea una cuenta. No deja tocar la propia,
  linea 80.

#### Permisos
Es la lamina 25 y **El control de acceso que pregunto**, arriba.

#### Fraude
Pestana **Fraude** (`src/services/fraude/casos-fraude.service.ts:87`, `listarPaginado()`)
- Casos, `GET /admin/fraude/casos`, controller
  `src/controllers/admin/admin-casos-fraude.controller.ts:36`. Pagina,
  `cargarCasos()` 1447.
- Resenas en anillo, `src/services/fraude/fraude-anillos-persistidos.service.ts:88`,
  `GET /admin/fraude/alertas-resenas`, controller
  `src/controllers/admin/admin-fraude-anillos.controller.ts:47`. Pagina,
  `cargarAnillosPersistidos()` 876. El detector es el Cypher de
  `src/services/fraude/anillos-detector.service.ts:268`.
- Ocultar una resena, `src/services/resenas/resenas.service.ts:735`, `moderar()`,
  `PATCH /admin/resenas/:id`, controller
  `src/controllers/admin/admin-resenas.controller.ts:31`, con
  `@Permiso('resenas.moderar')`. Pagina, `moderarResena()` 998.
- Intentos de entrada, `src/services/fraude-login/fraude-login.service.ts:346`,
  `GET /admin/fraude/alertas-login`, controller
  `src/controllers/fraude/fraude.controller.ts:29`. Pagina, `cargarAlertas()` 413.
  **Marcar revisada** o **Descartar** es
  `src/services/fraude-login/fraude-login-exploracion.service.ts:228`,
  `marcarAlerta()`, `PATCH /admin/fraude/alertas-login/:id`, controller
  `src/controllers/admin/admin-fraude-login.controller.ts:61`, con
  `@Permiso('fraude.resolver')`. Pagina, `marcarAlerta()` 488.
- Las de ver piden `@Permiso('fraude.ver')`. La pagina es
  `frontend/src/lib/PanelFraude.svelte`.

#### Tendencias
Pestana **Tendencias** (`src/services/admin/admin-tendencias.service.ts:253`, `consultarRanking()`)
- Si preguntan por la ruta. `/admin/eventos/vista`, `/carrito`, `/compra`,
  `/devolucion` y `/busqueda`, controller
  `src/controllers/admin/admin-tendencias.controller.ts:48` en adelante, con
  `@Permiso('tendencias.ver')`.
- Pagina. `frontend/src/lib/PanelTendencias.svelte`, `cargar()` 264.
- Base. ClickHouse.
- Como explicarlo. Lo mas visto cuenta personas distintas, `count(DISTINCT sesion)`,
  linea 68. **Para revisar** es `enAscenso()`, en
  `src/services/admin/admin-tendencias-avanzadas.service.ts:93`.

### Lo que corre solo, de fondo

| Tarea | Cada cuanto | Donde |
|---|---|---|
| Lleva a Elasticsearch los productos que cambiaron | 10 s | `src/services/buscador/buscador-sync.service.ts:39` |
| Calcula los dos vectores de los productos que cambiaron | 10 s | `src/services/productos/vectores-sync.service.ts:159` |
| Lleva las resenas a Neo4j | 10 s | `src/services/grafo/grafo-sync.service.ts:90` |
| Lleva las compras a Neo4j | 10 s | `src/services/grafo/grafo-compras-sync.service.ts:97` |
| Indexa las ofertas y revisa los avisame | 5 s | `src/services/vendedores/evento-oferta-sync.service.ts:93` |
| Pone al dia precio y stock del producto en MongoDB | 5 s | `src/services/productos/evento-producto-sync.service.ts:57` |
| Calcula el vector de cada resena | 10 s | `src/services/resenas/evento-comentario-sync.service.ts:88` |
| Busca anillos de resenas | 15 min | `src/services/fraude/anillos-detector.service.ts:39` |
| Junta las senales en casos | 15 min | `src/services/fraude/agrupador-fraude-worker.service.ts:54` |
| Lo mas vendido, de ClickHouse a Redis | 10 min | `src/services/productos/mas-vendidos-sync.service.ts:117` |
| Se compran juntos | 30 min | `src/services/productos/combos-sync.service.ts:74` |
| Borra los carritos sin tocar en 24 horas | 10 min | `src/services/carrito/carrito-barrido.service.ts:37` |
| Aplica las reglas de descuento | 1 min | `src/services/reglas-descuento-automatico/disparador-reglas-automatico.service.ts:85` |

Son 31 en total, todas en `docs/MAPA-FUNCIONALIDADES.md`. Trabajan igual. El
cambio se anota primero en PostgreSQL, en la misma transaccion, como una cola o
una bandera, y la tarea lo lleva a la otra base despues. Si la otra base esta
caida, la cola espera y no se pierde nada.

### Los flujos que faltaban, los de menos uso

#### Mi cuenta, datos y contrasena
**Mi cuenta** (`src/services/perfil.service.ts:71`, `actualizar()`, y `:132`, `cambiarContrasena()`)
- Leer es `obtener()`, linea 36.
- Si preguntan por la ruta. `GET /perfil` con `@Permiso('cuenta.ver')`,
  `PATCH /perfil` y `PATCH /perfil/contrasena` con `cuenta.editar`, controller
  `src/controllers/perfil.controller.ts:46`, `:58` y `:76`.
- Pagina. `frontend/src/routes/panel/+page.svelte`, `cargar()` 351,
  `guardarPerfil()` 434 y `cambiarContrasena()` 477.
- Base. PostgreSQL, tabla `usuarios`.
- Como explicarlo. Cambia nombre y apellido, nada mas, y la contrasena pidiendo
  la de antes.

#### Direcciones
**Tus direcciones** (`src/services/direccion-usuario.service.ts:43`, `crear()`, y `:106`, `actualizar()`)
- Listar es `listar()`, linea 196, y la copia la guarda `guardarSnapshot()`, 294.
- Si preguntan por la ruta. `GET`, `POST` y `PATCH /direccion-usuario`,
  controller `src/controllers/direccion-usuario.controller.ts:37`, `:84` y `:101`,
  con `@Permiso('direcciones.administrar')`.
- Pagina. `frontend/src/lib/Direcciones.svelte`, `cargarDirecciones()` 128 y
  `guardar()` 353.
- Base. PostgreSQL, `direcciones` y `direccion_historial`.
- Como explicarlo. Cada cambio guarda una version nueva. El pedido apunta a la
  version del dia en que se compro, asi que si la persona cambia su direccion
  despues, el pedido sigue diciendo a donde se mando.

#### Las alertas de la propia cuenta
Panel, **Alertas** (`src/services/fraude-login/fraude-login.service.ts:450`, `listarAlertasPaginadoUsuario()`, y `:519`, `marcarLeida()`)
- Si preguntan por la ruta. `GET /perfil/alertas-fraude` y
  `PATCH /perfil/alertas-fraude/:id`, controller
  `src/controllers/perfil.controller.ts:93` y `:111`.
- Pagina. `frontend/src/lib/AlertasFraudeUsuario.svelte`, `cargar()` 90 y
  `marcarLeida()` 128.
- Base. PostgreSQL, `notificacion_fraude`.
- Como explicarlo. Ensena los avisos de seguridad de esa cuenta, por ejemplo que
  alguien probo su clave. El id sale de la sesion, nunca de la direccion, asi
  nadie ve las de otro.

#### Responder y votar una resena
**Responder**, **Util** o **No util** (`src/services/resenas/resenas.service.ts:380`, `responder()`, y `:425`, `votar()`)
- Si preguntan por la ruta. `POST /resenas/:id/respuestas` con
  `@Permiso('resenas.escribir')`, `PUT` y `DELETE /comentarios/:id/voto` con
  `resenas.votar`, controller `src/controllers/resenas/resenas.controller.ts:138`,
  `:159` y `:180`.
- Pagina. `frontend/src/lib/Resenas.svelte`, `responder()` 409 y `votar()` 434.
- Base. PostgreSQL.

#### Quitar un descuento
**Quitar descuento** (`src/services/vendedores/ofertas.service.ts:717`, `quitarDescuento()`)
- Si preguntan por la ruta. `DELETE /vendedor/ofertas/:id/descuento`,
  controller `src/controllers/vendedores/ofertas.controller.ts:244`, con
  `@Permiso('ofertas.descuento')`.
- Pagina. `frontend/src/lib/OfertasVendedor.svelte`, `quitarDescuento()` 1568.
- Base. PostgreSQL, deja una fila nueva en `precio_historial`.

#### Cerrar una venta relampago
**Cerrar venta relampago** (`src/services/vendedores/ventas-limitadas.service.ts:133`, `cerrar()`)
- Si preguntan por la ruta. `DELETE /vendedor/ofertas/:id/venta-limitada`,
  controller `src/controllers/vendedores/ventas-limitadas.controller.ts:62`, con
  `@Permiso('ofertas.venta_relampago')`.
- Pagina. `frontend/src/lib/OfertasVendedor.svelte`, `cerrarRelampago()` 1461.
- Base. Redis borra el contador y PostgreSQL devuelve las reservas en curso.

#### Quitarle a alguien el permiso de una oferta compartida
**Quitar** en Compartir (`src/services/acl/acl-ofertas.service.ts:324`, `revocar()`)
- Si preguntan por la ruta. `DELETE /vendedor/ofertas/:id/permisos/:idPermiso`,
  controller `src/controllers/vendedores/permisos-oferta.controller.ts:77`, con
  `@Permiso('ofertas.compartir')`.
- Pagina. `frontend/src/lib/CompartirOferta.svelte`, `quitar()` 124, con
  `frontend/src/lib/compartidas.ts:96`.
- Base. PostgreSQL, `permiso_oferta` y su registro en `auditoria_permiso_oferta`.
- Como explicarlo. La otra cuenta pierde ese permiso desde su peticion
  siguiente. Si era el unico que tenia, ya ni ve la oferta, 404.

#### Reglas de descuento por fecha
**Descuentos por fecha** (`src/services/reglas-descuento-periodo/reglas-descuento-periodo.service.ts:149`, `crear()`)
- Las aplica el worker
  `src/services/reglas-descuento-periodo/disparador-reglas-periodo.service.ts:79`,
  cada 15 minutos.
- Si preguntan por la ruta. `POST /vendedor/reglas-descuento-periodos`,
  controller `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts:45`,
  con `@Permiso('reglas.administrar')`.
- Pagina. `frontend/src/lib/ReglasPeriodo.svelte`, `crear()` 281, `cambiar()` 353
  y `borrar()` 379.
- Como explicarlo. Pone el descuento al empezar la fecha y lo quita al terminar.

#### Resolver un caso de fraude
**Confirmar** o **Descartar** un caso (`src/services/fraude/casos-fraude.service.ts:226`, `actualizar()`)
- Si preguntan por la ruta. `PATCH /admin/fraude/casos/:id`, controller
  `src/controllers/admin/admin-casos-fraude.controller.ts:59`, con
  `@Permiso('fraude.resolver')`.
- Pagina. `frontend/src/lib/PanelFraude.svelte`, `marcarCaso()` 1526.
- Base. PostgreSQL.
- Como explicarlo. Marca el caso revisado, confirmado o descartado, y para
  descartar pide el motivo.

#### Fraude, compras y navegacion
**Compras y navegacion** (`src/services/fraude/hallazgos-evento-fraude-persistidos.service.ts:90`, `listarPaginado()`, y `:203`, `marcarHallazgo()`)
- Los busca `src/services/fraude/hallazgos-evento-fraude-detector.service.ts:106`,
  una vez al dia, linea 101.
- Si preguntan por la ruta. `GET` y `PATCH /admin/fraude/alertas-eventos`,
  controller `src/controllers/admin/admin-fraude-eventos.controller.ts:45` y `:60`.
- Pagina. `frontend/src/lib/PanelFraude.svelte`, `cargarHallazgos()` 1185 y
  `marcarHallazgo()` 1238.
- Base. ClickHouse para buscar y PostgreSQL para guardar la senal.
- Como explicarlo. Vistas infladas, compras en rafaga, varias cuentas comprando
  desde la misma IP y devoluciones seriales. Las devoluciones que cancelo la
  tienda no cuentan, linea 332 del detector.

#### Se compran juntos
Estante **Se compran juntos** (`src/services/productos/combos.service.ts:32`, `obtener()`)
- Lo deja en Redis cada 30 minutos
  `src/services/productos/combos-sync.service.ts:74`, y si Redis no esta, lo
  cuenta en ClickHouse en el momento, `desdeClickHouse()` en la linea 59.
- Si preguntan por la ruta. `GET /productos/combos`, controller
  `src/controllers/productos/combos.controller.ts:17`, publica.
- Pagina. `frontend/src/lib/EstanteCombos.svelte:36`.

#### Viste hace poco
Estante **Viste hace poco** (`src/services/productos/vistos-recientemente.service.ts:44`, `listar()`)
- Si preguntan por la ruta. `GET /productos/vistos-recientemente`, controller
  `src/controllers/productos/vistos-recientemente.controller.ts:22`.
- Pagina. `frontend/src/routes/+page.svelte:1003`.
- Base. ClickHouse, las vistas de esa persona.

#### El grafo esta al dia con PostgreSQL
La linea gris debajo de los anillos (`src/services/grafo/grafo-sync.service.ts:350`, `conciliar()`)
- Si preguntan por la ruta. `GET /admin/grafo/conciliacion`, controller
  `src/controllers/grafo/grafo.controller.ts:30`, con `@Permiso('sistema.ver')`.
- Pagina. `frontend/src/lib/PanelFraude.svelte`, `cargarConciliacion()` 151.
- Como explicarlo. Cuenta resenas y relaciones en las dos bases y dice si
  cuadran. Sale en gris si cuadra, y en rojo si no.

#### Que base esta caida
Sin pantalla, lo usan las demos y Postman (`src/helpers/cortacircuitos.ts:27`, `Cortacircuitos`)
- Si preguntan por la ruta. `GET /db/cortacircuitos`, controller
  `src/controllers/base-datos.controller.ts:49`, con `@Permiso('sistema.ver')`.
- Como explicarlo. Dice cada base si contesta y desde cuando esta caida.

### Si se cae una base

1. Cortacircuitos, `src/helpers/cortacircuitos.ts:27`, deja descansar la base 15 segundos, linea 40
2. Sin MongoDB, el catalogo sale de `src/helpers/catalogo-respaldo.ts`
3. Sin Elasticsearch, el buscador sale de `src/helpers/buscador-respaldo.ts`
4. Sin Neo4j o ClickHouse, los estantes salen de `src/helpers/recomendaciones-respaldo.ts`
5. Sin Ollama, Parecidos a este sigue igual porque los vectores ya estan guardados, y la hibrida sale solo por palabras
6. Sin PostgreSQL se mira pero no se paga

El detalle esta en `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md`.

---

## Apoyos para las preguntas

### Donde esta el control de cada peticion de Postman

Para Jose David, si el profesor pregunta donde esta en el codigo lo que acaba de
dar 401 o 403.

**La idea en tres frases.** La pagina esconde botones segun el rol, pero eso es
solo comodidad. El que decide es el backend, en cada peticion, con dos guardias.
Postman se salta la pagina y llama directo, y por eso prueba al backend.

**Las dos guardias del backend, iguales para todas las rutas.**
1. `SesionGuard`, `src/guards/sesion.guard.ts:71`. Sin cookie o con la cookie
   vencida, 401.
2. `PermisoGuard`, `src/guards/permiso.guard.ts:41`. Lee el `@Permiso` de la
   ruta y le pregunta a la tabla `rol_permiso` si el rol lo tiene, con
   `src/services/acl/permisos.service.ts:106`. Si no, 403 en la linea 81 de la
   guard. Una ruta sin `@Permiso` tambien se niega, linea 55.

**Lo que hace la pagina.** El panel arma sus pestanas segun el rol, en
`frontend/src/routes/panel/+page.svelte:61` y `:62` (`esAdmin` y
`esVendedor`) y la lista de la linea 135. Una compradora no ve la pestana
Cuentas, pero si llama la ruta igual, la frena el backend.

| Carpeta | Peticion | Da | Su `@Permiso` en el backend | Pantalla de la pagina que la usa |
|---|---|---|---|---|
| 1 | `GET /usuario/yo` sin sesion | 401 | `cuenta.ver`, `src/controllers/usuario.controller.ts:301` | Toda la pagina, al cargar, `frontend/src/lib/sesion.ts:138` |
| 1 | `GET /admin/permisos` sin sesion | 401 | `permisos.ver`, `src/controllers/admin/admin-permisos.controller.ts:32` | Admin, pestana Permisos, `frontend/src/lib/permisos.ts:53` |
| 1 y 2 | `POST /vendedor/ofertas` | 401 y 403 | `ofertas.publicar`, `src/controllers/vendedores/ofertas.controller.ts:175` | Vendedor, **Publicar una oferta** |
| 2 | `GET /comprador/pedidos`, el control que si pasa | 200 | `pedidos.ver`, `src/controllers/compradores/pedidos.controller.ts:30` | **Mis pedidos**, `frontend/src/lib/pedido.ts:299` |
| 2 y 3 | `GET /admin/usuarios` | 403 | `usuarios.ver`, `src/controllers/admin/admin-usuarios.controller.ts:22` | Admin, pestana Cuentas |
| 2 y 3 | `PATCH /admin/usuarios/:id`, hacerse admin | 403 | `usuarios.editar`, misma ruta, linea 42 | Admin, **Bloquear**, `frontend/src/lib/BloquearCuenta.svelte:60` |
| 2 y 3 | `GET /admin/reportes/ventas` | 403 | `reportes.ver`, `src/controllers/admin/admin-reportes.controller.ts:24` | Admin, pestana Reportes |
| 2 | `GET /admin/fraude/casos` | 403 | `fraude.ver`, `src/controllers/admin/admin-casos-fraude.controller.ts:31` | Admin, Fraude, **Casos** |
| 2 | `GET /vendedor/ofertas` | 403 | `ofertas.ver`, `src/controllers/vendedores/ofertas.controller.ts:47` | Vendedor, pestana Ofertas |
| 2 y 3 | `GET /db/cortacircuitos` | 403 | `sistema.ver`, `src/controllers/base-datos.controller.ts:48` | Ninguna, es del admin y de las demos |
| 3 | `GET /vendedor/ofertas/paginado`, el control que si pasa | 200 | `ofertas.ver`, la misma linea 47 | Vendedor, **Mis ofertas** |
| 3 | `GET /admin/dashboard/resumen` | 403 | `dashboard.ver`, `src/controllers/dashboards/dashboard-general.controller.ts:59` | Admin, pestana Dashboard |
| 3 | `GET /admin/fraude/alertas-login` | 403 | `fraude.ver`, `src/controllers/fraude/fraude.controller.ts:28` | Admin, Fraude, **Intentos de entrada** |
| 3 | `GET /admin/eventos/tendencias` | 403 | `tendencias.ver`, `src/controllers/admin/admin-tendencias-avanzadas.controller.ts:27` | Admin, pestana Tendencias |
| 4 | `GET /admin/permisos` y `/admin/permisos/registro` como admin | 200 | `permisos.ver`, la misma linea 32 | Admin, pestana Permisos |
| 4 | `DELETE /admin/permisos/3/:id`, el admin se quita `permisos.administrar` | 409 | La revision de `src/services/acl/permisos.service.ts:350`, antes del borrado de la linea 359 | Admin, Permisos, la casilla en gris que no se puede desmarcar |
| 4 | `DELETE /admin/permisos/1/:id`, le quita `cuenta.ver` al comprador | 409 | La misma linea 350 | La misma casilla en gris |

**La carpeta 5 tiene una guardia mas, la de cada oferta.** Pasa por las dos de
arriba y despues por `PermisoOfertaGuard`, `src/guards/permiso-oferta.guard.ts:42`,
que le pregunta a `AclOfertasService.comprobar()` en
`src/services/acl/acl-ofertas.service.ts:83` si esa cuenta tiene una entrada para
esa oferta. Sin ninguna entrada, 404 en la linea 132. Con ver pero sin editar,
403 en la 134.

| Peticion | Da | Donde | Pantalla |
|---|---|---|---|
| `GET /compartidas/ofertas/3` sin entrada, con ver y ya quitado | 404, 200 y 404 | `@PermisoOferta('ver')`, `src/controllers/compartidas/ofertas-compartidas.controller.ts:75`, y `ofertas.usar_compartidas` en la 53 | Vendedor, pestana **Compartidas** |
| `PATCH /compartidas/ofertas/3`, cambiar el precio sin editar | 403 | `@PermisoOferta('editar')`, misma ruta, linea 95 | En **Compartidas** el boton **Editar** ni sale si no tiene editar, `frontend/src/lib/OfertasCompartidas.svelte:198` |
| `POST /vendedor/ofertas/3/permisos`, la duena le da ver | 201 | `ofertas.compartir`, `src/controllers/vendedores/permisos-oferta.controller.ts:34` | Vendedor, Ofertas, **Compartir**, `frontend/src/lib/compartidas.ts:83` |
| `DELETE /vendedor/ofertas/3/permisos/:id`, se lo quita | 200 | La misma, linea 77 | El mismo **Compartir**, `frontend/src/lib/compartidas.ts:95` |

**Las carpetas 6 y 7 no pasan por el backend.** Llaman directo a Elasticsearch y
a ClickHouse con sus usuarios de servicio. Ahi el control lo hace cada base, con
los roles de `seguridad/elastic.sh` y `seguridad/clickhouse.sql`. No hay pagina
que las use.

**La carpeta 8 no es de permisos.** Prueba que lo que se escribe no se vuelve
SQL. El login, `src/services/usuario.service.ts:137`, la pantalla **Iniciar
sesion**, `frontend/src/routes/entrar/+page.svelte:61`. El id del pedido,
`src/services/compradores/pedidos.service.ts:126`, la pantalla **Mis pedidos** y
**Ver detalle**.

### Como se conecta todo, para explicarlo facil

La pagina nunca habla con las bases. Habla solo con el backend, y el backend es
el unico que entra a las seis.

1. **La pagina.** Cada pantalla llama una ruta que empieza con `/api`, por
   ejemplo `/api/productos/7`. Eso esta en `frontend/src/lib/api.ts:14`.
2. **El paso de en medio.** Vite, el que sirve la pagina en el puerto 5173, le
   quita el `/api` y se la pasa al backend en el puerto 3000. Esta en
   `frontend/vite.config.ts:53`.
3. **El backend.** Cada ruta tiene su controller en `src/controllers/`. Si es
   privada, primero `SesionGuard` dice quien es o 401, y despues `PermisoGuard`
   dice si su rol puede o 403. Solo si pasa las dos llega al service, y el
   service es el que va a PostgreSQL, MongoDB, Redis, Neo4j, ClickHouse o
   Elasticsearch.
4. **Postman.** Llama las mismas rutas del paso 3, pero directo al puerto 3000,
   sin la pagina. Por eso sirve de prueba, si la pagina esconde un boton pero la
   ruta dejara pasar, Postman lo veria. Y no lo ve, da 403.

Ejemplo completo. La compradora da clic en **Agregar**. La ficha,
`frontend/src/routes/producto/[id]/+page.svelte:690`, llama
`PUT /api/carrito/lineas/:idOferta`. Vite la pasa a `PUT /carrito/lineas/:idOferta`.
El backend la recibe en `src/controllers/carrito/carrito.controller.ts:60`,
revisa la sesion y el permiso `carrito.usar`, y el service,
`src/services/carrito/carrito.service.ts:242`, guarda la linea en PostgreSQL y
su copia en Redis.

### La tienda entera, clic por clic

Para cuando el profesor pida ver algo que no esta en las laminas. Probado el 6
de noviembre en la tienda en vivo. Las cuentas son las de siempre.

| Cuenta | Clave | Para que |
|---|---|---|
| `compradora.norte@mesh.com` | `Comprador123` | Comprar, pedidos, avisos y resenas |
| `ventas.norte@mesh.com` | `Vendedor123` | Ofertas, descuentos, compartir y reglas |
| `admin@mesh.com` | `Admin123` | Todo el panel de administracion |
| `desarrollador1@mesh.com` | `Desarrollo123!` | La pestana Comandos, para correr las demos |

Para entrar, arriba a la derecha **Iniciar sesion**, escribir el correo y la
clave y **Entrar**. Para salir, **Salir**. Para cambiar de cuenta en la misma
ventana hay que salir primero. El service de cada ruta esta en los flujos, mas
arriba, y en `docs/MAPA-FUNCIONALIDADES.md`.

#### Sin sesion

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| Abrir `http://localhost:5173` | **Lo mas vendido ahora**, **Ventas relampago**, **Ofertas con descuento**, **Se compran juntos** y el catalogo con **Filtros** | `GET /productos/mas-vendidos`, `/productos/ofertas/venta-relampago`, `/productos/ofertas/descuento`, `/productos/combos`, `/productos` |
| Escribir en **Buscar productos** | La lista mientras se escribe, tolera errores como `labtop` | `GET /buscador/productos` |
| Enter | Resultados con filtros y sus numeros, y **Tal vez quisiste decir** | `GET /buscador/productos/facetado` y `/hibrida` |
| Una frase, como `algo para salir a pedalear` | Ademas **Lo que cuentan otros compradores** | `GET /buscador/productos/intencion` |
| Clic en un producto | La ficha con **Comprar**, **Detalles**, **Resenas**, **Parecidos a este** y **Quienes lo compraron tambien llevaron** | `GET /productos/:id`, `/similares`, `/tambien-compraron`, `/resenas` |
| **Agregar** sin sesion | No hay boton, dice **Inicia sesion para agregar al pedido** | Ninguna |

#### Como compradora

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| **Entrar** | El panel, **Hola, Ana**, con **Avisos**, **Alertas** y **Mi cuenta** | `POST /usuario/login` |
| Volver al inicio | Suman **Para ti** y **Viste hace poco**, que dice **Ya lo compraste** en lo que ya compro | `GET /productos/para-ti`, `/productos/vistos-recientemente` |
| En una ficha, **Agregar** junto a un vendedor | Se abre **Tu carrito** a la derecha con la linea, **-**, **+**, **Quitar** y **Continuar al pago** | `PUT /carrito/lineas/:idOferta` |
| **Continuar al pago** | **Confirmar la compra**, la direccion, **Lo que llevas**, el total y **Como quieres pagar**, con Tarjeta, Transferencia o Efectivo contra entrega | `GET /comprador/pedidos/metodos-pago` y `/direccion-usuario` |
| Elegir **Efectivo contra entrega** y **Pagar** | **Gracias por tu compra** con el numero de pedido | `POST /carrito/comprar`, una sola transaccion en PostgreSQL |
| Arriba **Mis pedidos** | La lista con **Todos**, **Comprado** y **Cancelado**, y en cada uno **Ver detalle** y **Cancelar** | `GET /comprador/pedidos` |
| **Cancelar** y **Si, cancelar el pedido** | **Pedido cancelado**, se devuelven las unidades y el pago queda reembolsado. Solo mientras esta **Comprado**, enviado ya no | `POST /comprador/pedidos/:id/cancelar` |
| Un pedido que cancelo la tienda | Dice **Lo cancelo la tienda** | `GET /comprador/pedidos` |
| En una ficha, **Avisame si baja de precio** | Queda en **Avisos** del panel, en **Lo que sigues** | `POST /comprador/seguimientos` |
| Pestana **Resenas** de la ficha | Las estrellas, cada resena y **Util** o **No util**. Escribir una solo se puede si ya lo compro | `GET /productos/:id/resenas`, `PUT /comentarios/:id/voto` |
| Panel, **Alertas** | **Alertas de seguridad** de su propia cuenta, con **Cambiar mi contrasena ahora** | `GET /perfil/alertas-fraude` |
| Panel, **Mi cuenta** | **Tu perfil**, **Tus direcciones** y **Tus pedidos** | `GET /perfil`, `/direccion-usuario` |

#### Como vendedor

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| **Entrar** | **Hola, Carlos** y las pestanas **Ofertas**, **Compartidas**, **Reglas**, **Proponer** y **Propuestas** | `POST /usuario/login` |
| **Ofertas** | **Mis ofertas** con **Todas**, **Activas**, **Pausadas** y las demas, y en cada una **Pausar**, **Descuento**, **Abrir venta relampago**, **Compartir** y **Editar** | `GET /vendedor/ofertas/paginado` |
| **Publicar una oferta** | Elegir un producto del catalogo y ponerle precio y unidades | `POST /vendedor/ofertas` |
| **Descuento** | Ponerle un porcentaje a esa oferta | `POST /vendedor/ofertas/:id/descuento` |
| **Abrir venta relampago** | Pocas unidades a precio especial, las aparta Redis | `POST /vendedor/ofertas/:id/venta-limitada` |
| **Compartir** | Darle a otra cuenta ver, editar o descontar esa oferta, hasta una fecha | `POST /vendedor/ofertas/:id/permisos` |
| **Compartidas** | **Compartidas contigo**, las ofertas de otros que le dejaron usar | `GET /compartidas/ofertas` |
| **Reglas** | **Descuentos automaticos** y **Descuentos por fecha**, con **Nueva regla** | `GET /vendedor/reglas-descuento/paginado` |
| **Proponer** | **Proponer un producto**, que entra al catalogo cuando el admin lo aprueba | `GET /vendedor/categorias` |
| **Propuestas** | **Mis propuestas al catalogo**, con **Reenviar a revision** si se la rechazaron | `GET /vendedor/productos/propuestas` |

#### Como admin

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| **Entrar** y arriba **Admin** | **Hola, Sofia** y las pestanas **Dashboard**, **Reportes**, **Ofertas**, **Compartidas**, **Reglas**, **Catalogo**, **Propuestas**, **Cuentas**, **Permisos**, **Fraude** y **Tendencias** | `POST /usuario/login` |
| **Dashboard** | **Ventas en el tiempo**, **Por categoria**, **Por metodo de pago**, con **Ventas**, **Clientes**, **Vendedores y productos**, **Busquedas**, **Cancelaciones** y **Pedidos**, y **Exportar** | `GET /admin/dashboard/resumen` y las demas de `/admin/dashboard` |
| **Dashboard**, **Pedidos** | El registro con la columna **Gestion**, **Enviado**, **Entregado** y **Cancelar** con su motivo. Lo que cancelo la tienda dice **por la tienda** | `POST /admin/pedidos/:id/enviado`, `/entregado` y `/cancelar` |
| **Reportes** | **Pedidos**, **Pagos**, **Como pagan** y **Pedidos sin pagar** | `GET /admin/reportes/ventas` y `/admin/reportes/reservaciones` |
| **Catalogo** | **El catalogo** con **Publicar producto**, y en cada uno **Editar**, **Historial**, **Retirar** y **Ofertas** | `GET /vendedor/productos/paginado` |
| **Catalogo**, **Ofertas** de un producto | Las ofertas de todos los vendedores, con **Pausar** o **Activar**, **Retirar** y **Ajustar** las unidades. El precio no, es del vendedor | `GET /admin/ofertas?producto=`, `PATCH /admin/ofertas/:id` |
| **Catalogo**, **Categorias** | Cada categoria con lo que pregunta, **Nueva categoria**, **Cambiar nombre** y **Agregar caracteristica** | `GET`, `POST` y `PATCH /admin/categorias` |
| **Propuestas** | **Productos por revisar**, con **Aprobar** y **Rechazar** | `GET /vendedor/productos/propuestas/sin-aprobar` |
| **Cuentas** | Todas las cuentas con su rol y su estado | `GET /admin/usuarios`, `/admin/roles`, `/admin/estados` |
| **Permisos** | La matriz por rol y **Lo ultimo que paso** | `GET /admin/permisos` y `/admin/permisos/registro` |
| **Fraude** | **Casos**, **Intentos de entrada**, **Resenas en anillo** y **Compras y navegacion**, con **Bloquear**, **Marcar revisada** y **Descartar**. Una alerta con muchas cuentas ensena 8 y **Ver las N cuentas**, y lo mismo los correos tecleados con **Ver los N** | `GET /admin/fraude/alertas-login`, `/admin/fraude/alertas-resenas` |
| **Fraude**, **Resenas en anillo**, **Ver detalle real** | Cada resena del anillo y la columna **En la tienda**, con **Ocultar** o **Publicar**. Oculta, sale de la ficha y del promedio y sigue aqui como evidencia | `PATCH /admin/resenas/:id` |
| La ficha de un producto, pestana **Resenas** | Al admin le sale **Ocultar** en cada resena | `PATCH /admin/resenas/:id` |
| **Tendencias** | **Resumen**, **Para revisar** y **Rankings**, de ClickHouse | `GET /admin/eventos/vista`, `/carrito`, `/compra`, `/devolucion`, `/busqueda` |

Lo que se marca a mano en el admin, como **Bloquear** o **Aprobar**, cambia datos
de verdad. En la presentacion se ensena sin apretarlo, salvo que el profesor lo
pida.

#### Como desarrollador, la pestana Comandos

Solo la ven las cuentas cuyo correo es `desarrollador`, un numero y
`@mesh.com`. El admin no la ve, porque corre programas en la PC.

| Clic | Lo que sale | A quien le habla |
|---|---|---|
| **Entrar** con `desarrollador1@mesh.com` | **Hola, Desarrollador 1**, con lo de un vendedor | `POST /usuario/login` |
| Arriba, **Desarrollador** | **Comandos**, con los grupos **Arrancar y parar**, **Productos de prueba**, **Reconstruir bases**, **Demos de fraude**, **Demo de descuentos**, **Caida de una base**, **Demo de Redis**, **Demos de la Entrega final** y **Demos de resenas** | Al panel de comandos en `http://127.0.0.1:5199`, no al backend |
| En un comando, **Ejecutar** | Corre la demo y ensena lo que va saliendo | El mismo panel, que corre el script en esa PC |
| En un comando, **Copiar** | Copia la orden para correrla a mano en una terminal | Ninguna |

**Donde esta.** La regla del correo es `esCuentaDesarrollador()` en
`frontend/src/lib/sesion.ts:93`. El panel agrega la pestana solo si cumple, en
`frontend/src/routes/panel/+page.svelte:71`, `:72`, `:177` y `:186`. La pestana
le habla a `http://127.0.0.1:5199`, en `frontend/src/lib/PanelComandos.svelte:65`.
Ese panel lo levanta `node panel-comandos/servidor.mjs`, escucha solo en la
misma PC y es el que decide que se puede correr. El texto de la demo de la
recomendacion, con el puntaje nuevo, esta en `panel-comandos/servidor.mjs:375`.

**Ojo.** Solo funciona en la PC donde corre el panel. Si el tunel ya estaba
prendido, cada demo lo usa y lo deja prendido. Si no lo estaba, la demo levanta
uno y lo apaga al terminar.

---

## Palabras raras, en facil

| Palabra | Que es, en facil | Donde sale |
|---|---|---|
| Controller | El que recibe la ruta y llama al service. No tiene la logica | `src/controllers/carrito/carrito.controller.ts:60` |
| Service | Donde esta la logica. Es el que va a la base | `src/services/carrito/carrito.service.ts:242` |
| Helper | Una funcion suelta que usan varios services | `src/helpers/vectores-pgvector.ts:41` |
| `fuzziness: 'AUTO'` | Busqueda que perdona errores de tecleo. Una letra mal en palabras cortas, dos en las largas | `src/services/buscador/facetado.service.ts:190` |
| `multi_match` | Buscar lo escrito en varios campos a la vez | `src/services/buscador/facetado.service.ts:187` |
| `nombre^3` | El nombre pesa el triple que la descripcion al ordenar | `src/services/buscador/facetado.service.ts:189` |
| `bool`, `must` y `filter` | `must` es lo que se busca y decide el orden. `filter` es lo que tiene que cumplirse, sin cambiar el orden | `src/services/buscador/facetado.service.ts:198` |
| `aggs`, agregaciones | Contar resultados por grupo. Son los numeros de cada filtro | `src/services/buscador/facetado.service.ts:206` |
| `terms` y `range` | `terms` cuenta por valor, como cada categoria. `range` cuenta por tramo, como de Q1,000 a Q3,000 | `src/services/buscador/facetado.service.ts:208` y `:214` |
| `post_filter` | Un filtro que corre despues de contar. Lo dejamos de usar el 20 de octubre porque los numeros no cuadraban | Pregunta 146 de `PREGUNTAS-SUSTENTACION.md` |
| Analizador `espanol_llano` | Pasa todo a minusculas y quita tildes antes de buscar | `elastic/001_indice.json:8` |
| `search_as_you_type` y `bool_prefix` | Encontrar con la palabra a medias, mientras se escribe | `elastic/001_indice.json:23`, `src/services/buscador/productos.service.ts:159` |
| `suggest` | El Tal vez quisiste decir | `src/helpers/correccion-busqueda.ts:40` |
| `minimum_should_match` | Cuantas palabras tienen que coincidir. Con frases largas, el 70 % | `src/services/buscador/hibrida.service.ts:209` |
| `keyword` y `text` | `text` se parte en palabras para buscar. `keyword` se guarda entero para filtrar y contar | `elastic/001_indice.json` |
| Percolator | Guarda busquedas en vez de productos, y cada oferta nueva se prueba contra ellas. Es el avisame | `src/services/compradores/percolar-seguimientos.service.ts:57` |
| Vector o embedding | Una lista de 768 numeros que representa de que trata un texto. Dos textos parecidos dan listas cercanas | `src/services/productos/vectores-sync.service.ts:61` |
| Vector de caracteristicas | El segundo vector de cada producto, del texto de su marca, memoria, talla o color. Desde el 8 de noviembre | `src/services/productos/vectores-sync.service.ts:98`, `migrations/055_vector_caracteristicas.sql:35` |
| Ollama y `paraphrase-multilingual` | El programa y el modelo que convierten texto en vector, en la misma PC y gratis | `src/helpers/vectores-ollama.ts:33` |
| pgvector | La extension que le ensena a PostgreSQL a guardar y comparar vectores | `migrations/024_vectores_productos.sql:56` |
| Coseno y `<=>` | Que tan parecidos son dos vectores. Cero es igual, y el parecido es uno menos eso | `src/services/productos/similares.service.ts:202` |
| HNSW | Un indice que encuentra los vecinos mas cercanos sin compararse contra todos | `migrations/040_vectores_en_postgres.sql:69` |
| `ef_search` | Cuantos candidatos mira el indice antes de contestar | `src/helpers/vectores-pgvector.ts:50` |
| Puntaje de Parecidos a este | 0,7 del parecido general, 0,2 del de caracteristicas y 0,1 de la nota. Ordena cada bloque | `src/services/productos/similares.service.ts:75` |
| Nota bayesiana | El promedio de estrellas con dos resenas imaginarias de 3, para que una sola resena de 5 no gane | `src/services/productos/similares.service.ts:26` |
| RRF | Juntar dos listas por la posicion de cada producto y no por su puntaje, porque los puntajes no se pueden comparar | `src/services/buscador/hibrida.service.ts:352` |
| Grupo | Huella de la categoria y la descripcion, para no recomendar copias del mismo producto | `src/services/productos/vectores-sync.service.ts:240` |
| Huella o md5 | Un resumen corto del texto. Si no cambia, el texto tampoco, y no se llama a Ollama | `src/services/productos/vectores-sync.service.ts:248` |
| Transaccion, `BEGIN`, `COMMIT` y `ROLLBACK` | Todo o nada. `COMMIT` guarda todo junto, `ROLLBACK` deshace todo | `src/services/carrito/carrito.service.ts:683`, `:876` y `:879` |
| `FOR UPDATE` | Bloquea la fila mientras dura la compra. Si dos compran la ultima unidad, la segunda espera y ve que ya no hay | `migrations/020_descuentos_oferta.sql:287` |
| Kardex, `stock_movimiento` | El libro de cada entrada y salida de unidades | `migrations/020_descuentos_oferta.sql:301` |
| `precio_historial` | Cada precio que tuvo una oferta. La linea del pedido apunta al precio que se cobro | `migrations/005_ofertas.sql:159` |
| Parametro `$1` | Lo que escribe la persona viaja aparte del SQL, por eso no hay inyeccion SQL | `src/services/usuario.service.ts:137` |
| Cola, outbox | Una tabla de pendientes en PostgreSQL que se escribe en la misma transaccion. Un worker la lleva despues a la otra base | `migrations/015_outbox_grafo.sql:143` |
| Worker, `@Interval` | Una tarea del backend que corre sola cada tanto tiempo | `src/services/buscador/buscador-sync.service.ts:39` |
| Bandera `pendiente_*` | Una marca en el documento de MongoDB que dice que falta llevarlo al buscador o calcular su vector | `src/services/buscador/buscador-sync.service.ts:75` |
| `findOneAndUpdate` | Bajar la bandera y leer como estaba, en un solo paso, para no perder un cambio hecho mientras tanto | `src/services/productos/vectores-sync.service.ts:402` |
| Script Lua | Codigo que Redis corre entero sin que nadie se meta en medio. Compara y descuenta en un paso | `redis/inventario_limitado.lua:272` |
| TTL y `EXPIRE` | Tiempo de vida de una clave de Redis. Al vencer, Redis la borra solo | `src/services/carrito/carrito-redis.service.ts:320` |
| `SET NX EX 30` | Poner una clave solo si no existe y que dure 30 segundos. Es el candado del doble clic | `src/services/carrito/carrito-redis.service.ts:396` |
| `INCR`, `SADD` y `SCARD` | Contar en Redis. `INCR` suma uno, `SADD` agrega a un conjunto sin repetir y `SCARD` dice cuantos hay | `src/services/fraude-login/fraude-login.service.ts:158` |
| Cortacircuitos | Si una base falla, se deja de preguntarle 15 segundos y se usa el respaldo, en vez de esperar en cada peticion | `src/helpers/cortacircuitos.ts:27` |
| Cypher y `MATCH` | El lenguaje de Neo4j. `MATCH` dibuja el camino que se busca entre nodos | `src/services/fraude/anillos-detector.service.ts:268` |
| `*4..8` | Un camino de 4 a 8 saltos que sale de una cuenta y vuelve a ella. Es el anillo | `src/services/fraude/anillos-detector.service.ts:268` |
| `ORDER BY` de ClickHouse | El orden en que se guardan las filas en el disco, por producto y fecha, para leer rapido un periodo | `clickhouse/001_esquema.sql:71` |
| `count(DISTINCT sesion)` | Contar personas distintas y no clics. Uno que recarga 40 veces cuenta una | `src/services/admin/admin-tendencias.service.ts:68` |
| Agregacion de MongoDB, `$match`, `$sort` y `$group` | Pasos que MongoDB corre por dentro, filtrar, ordenar y juntar, sin traer los datos al backend | `src/services/productos/productos.service.ts:419` |
| `$facet` | Hacer dos consultas en una, la pagina y el total | `src/services/productos/productos.service.ts:196` |
| `updateMany` | Cambiar muchos documentos de MongoDB con una sola orden | `src/services/admin/admin-categorias.service.ts:233` |
| Token y HS256 | La sesion firmada que dura 2 horas. HS256 es la forma de firmarla | `src/helpers/token.ts:48` |
| Cookie httpOnly | La cookie de la sesion. La pagina no la puede leer, asi un script malo no la roba | `src/helpers/token.ts:25` |
| scrypt | La forma de guardar la clave, convertida y con sal, nunca en claro | `src/helpers/contrasena.ts:17` |
| Guard | El portero que corre antes de cada ruta. `SesionGuard` dice quien eres y `PermisoGuard` que puedes | `src/guards/sesion.guard.ts:71` y `src/guards/permiso.guard.ts:41` |
| `@Permiso` | La etiqueta de cada ruta con el permiso que pide | `src/decorators/permiso.decorator.ts:18` |
| ACL | Una lista de quien puede que. Lo que no esta en la lista se niega | `migrations/050_permisos_por_rol.sql:70` |
| 401, 403, 404, 409 y 503 | 401 sin sesion, 403 sin permiso, 404 no existe, 409 choca con algo como sin stock, 503 una base no contesta | `src/helpers/manejar-error-http.ts` |
| `trustProxy` y `X-Forwarded-For` | Como el backend sabe la IP real de quien entra cuando pasa por el proxy | `src/main.ts:34` |
| Haversine | La formula de la distancia entre dos puntos del mapa, para el viaje imposible. Salta con mas de 800 km/h, linea 53 | `src/services/fraude-login/viaje-imposible.service.ts:139` |
| Proxy `/api` de Vite | La pagina pide `/api/...` y Vite lo pasa al backend en el 3000 | `frontend/vite.config.ts:53` |
