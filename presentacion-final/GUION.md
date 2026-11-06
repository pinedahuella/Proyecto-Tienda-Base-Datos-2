# Guion de la presentacion final

Pensado para 20 minutos, en tres partes, una por persona. La parte 3 es la mas
larga porque ensena en detalle lo de la Entrega final, los vectores y el control
de acceso, con las dos pruebas en vivo que pidio el profesor. El texto de cada
lamina es una guia para decirlo con las propias palabras, no para leerlo. Cada
cifra sale del informe final o de los anteriores.

Debajo de cada lamina va **Se hace**, lo que se ensena en la pantalla, y **Si
pregunta**, el archivo y la linea donde esta. El detalle completo esta en
`docs/GUIA-ESTUDIO-VECTORES.md` y `docs/GUIA-ESTUDIO-ACL.md`.

| Parte | Laminas | Quien | Tiempo |
|---|---|---|---|
| 1. La tienda y sus seis bases | 1 a 7, con la tienda en vivo | Jose Manuel | 6 min |
| 2. Lo que la tienda aprende y como resiste | 8 a 13 | Juan Pablo | 4 min |
| 3. La Entrega final, vectores y control de acceso | 14 a 25, con las pruebas en vivo | Jose David | 10 min |

Medido el 6 de noviembre. Lo que se dice, leido con la voz Sabina de Windows,
dura 1,4, 2,1 y 4,3 minutos. Una persona habla mas despacio, como un tercio
mas, y a eso se suma lo que se ensena en la pantalla, buscar y comprar en la
tienda unos 3 minutos y medio,
los paneles de la parte 2 uno, las bases en vivo unos 3 y Postman uno. Da unos
19 minutos y queda uno para pasar de una parte a otra. La caida en vivo de la
lamina 10 suma un minuto y va solo si se llega adelantado. Si el tiempo
aprieta, en la tienda se salta la compra, en las bases en vivo se ensenan
PostgreSQL, Redis y ClickHouse, y en Postman solo el Run de la coleccion. Conviene ensayarlo una vez con reloj.

Antes de empezar, la lista **Antes de presentar**, despues de la parte 3. Al final
van tres apoyos para las preguntas, donde esta el control de cada peticion de
Postman, como se conecta la pagina con el backend y la tienda entera clic por
clic.

---

## Parte 1. La tienda y sus seis bases (Jose Manuel, 6 min)

### 1. Portada
Buenos dias, somos Mesh. Hicimos una tienda en linea con varios vendedores y
seis bases de datos.

### 2. El equipo
Jose David hizo el backend, yo el frontend, las bases y las pruebas, y Juan
Pablo ClickHouse y Neo4j. Cada uno presenta lo suyo.

### 3. El reto
Un producto es la cosa, y una oferta es quien la vende, a que precio y cuantas
tiene. Son 93 tablas en seis bases.

### 4. Cada base, por la pregunta que contesta
PostgreSQL guarda el dinero y el stock, MongoDB el catalogo, Redis el carrito,
Neo4j las relaciones, ClickHouse los eventos y Elasticsearch la busqueda.

### 5. La regla
Lo que es dinero solo se escribe en PostgreSQL. Lo demas se puede rehacer desde
ahi.

**Si pregunta por que no todo en PostgreSQL.** Cada base contesta mejor su
pregunta, pero solo una guarda la verdad. Informe final, 4.2, la tabla de los componentes.

### 6. El diagrama
Las flechas llenas son lo que hace el backend con cada base, y las punteadas lo
que viaja de una base a otra. Cada caja dice con que usuario entra el backend.

**Se hace.** Clic sobre el diagrama para abrirlo a tamano completo, Esc para
cerrar.

**Si pregunta.** Sale de `docs/generar-arquitectura.py`. El diagrama entidad
relacion es `docs/diagrama-er.png`, el mismo de la Entrega 1 puesto al dia el 6
de noviembre con las 93 tablas y sus 117 llaves foraneas. Lo actualiza
`docs/actualizar-er.py`, que lee la base en funcionamiento y falla si una tabla
queda sin caja o una llave sin flecha. Se abre editable en draw.io con
`docs/diagrama-er.drawio`.

### 7. La tienda en vivo
Ahora la tienda. Primero buscar, despues comprar. La tarjeta de cada resultado
sale entera de Elasticsearch, con su foto, en una sola consulta.

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

**Se hace, comprar (dos minutos).** En la misma ventana.
5. Arriba a la derecha **Iniciar sesion**. Correo `compradora.norte@mesh.com`,
   clave `Comprador123`, **Entrar**. Sale **Hola, Ana**.
6. En el buscador escribir `cartas` y clic en **Cartas al puerto seco**. Ahora
   cada vendedor trae su boton **Agregar**. Clic en el primer **Agregar**. Se
   abre **Tu carrito** a la derecha con el libro.
7. **Continuar al pago**. Sale **Confirmar la compra**, con la direccion, **Lo
   que llevas** y **Como quieres pagar**.
8. Elegir **Efectivo contra entrega** y clic en **Pagar**. Sale **Gracias por tu
   compra** con el numero de pedido.
9. Arriba **Mis pedidos**. El pedido nuevo sale primero, **Comprado**.
10. En ese pedido **Cancelar** y **Si, cancelar el pedido**. Dice que se
    devolvieron las unidades y que el pago quedo reembolsado.

Lo que se dice mientras. El carrito vive en PostgreSQL con una copia rapida en
Redis. Pagar es una sola transaccion en PostgreSQL, que cobra y descuenta el
stock juntos o no hace nada. Cancelar devuelve las unidades a la oferta.

**Por dentro, si pregunta como se conecta.**
- Al escribir, la pagina llama `GET /buscador/productos`, con `buscarProductos()`
  de `frontend/src/lib/buscador.ts:107`.
- La pagina de resultados llama `GET /buscador/productos/facetado`, con
  `buscarFacetado()` de `frontend/src/lib/buscador.ts:397`. Cada filtro marcado
  vuelve a llamar la misma ruta con `categoria=7` o `precio=desde-3000`.
- La ficha llama `GET /productos/7`, y despues `/productos/7/similares`,
  `/productos/7/tambien-compraron` y `/productos/7/resenas`, cada estante por su
  lado.
- **Agregar** llama `PUT /carrito/lineas/:idOferta`, desde
  `frontend/src/routes/producto/[id]/+page.svelte:683`, y lo recibe
  `backend/src/controllers/carrito/carrito.controller.ts:60`.
- **Pagar** llama `POST /carrito/comprar`, que recibe la linea 124 del mismo
  controller, con el permiso `carrito.comprar`.
- **Cancelar** llama `POST /comprador/pedidos/:id/cancelar`, en
  `backend/src/controllers/compradores/pedidos.controller.ts:80`.

**Si pregunta por la tolerancia a errores (fuzziness).**
- La consulta de `/buscar` esta en
  `backend/src/services/buscador/facetado.service.ts:187`, un `multi_match` sobre
  `nombre^3`, `descripcion` y `variantes` con `fuzziness: 'AUTO'` en la linea
  190. AUTO permite un error en palabras de 3 a 5 letras y dos en las mas
  largas, por eso `labtop` encuentra laptop.
- El nombre pesa tres veces mas que la descripcion (`nombre^3`).
- Las tildes y mayusculas no cuentan por el analizador `espanol_llano` de
  `elastic/001_indice.json:8`, con `lowercase` y `asciifolding`.
- El buscador de la cabecera usa la misma idea en
  `backend/src/services/buscador/productos.service.ts:149`.
- En el frontend, `frontend/src/lib/buscador.ts:397` (`buscarFacetado`).

---

## Parte 2. Lo que la tienda aprende y como resiste (Juan Pablo, 4 min)

### 8. Lo que pasa en el tiempo, ClickHouse
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
3. Clic en **Dashboard**. Sale **Ventas en el tiempo**, **Por categoria** y **Por
   metodo de pago**, de este anio contra el anterior.

**Por dentro.** Cada cuadro de Tendencias llama `GET /admin/eventos/vista`,
`/admin/eventos/carrito`, `/admin/eventos/compra` y las demas, que leen ClickHouse.
El Dashboard llama `GET /admin/dashboard/resumen`, `/ventas`, `/categorias` y
`/pagos`, desde `frontend/src/lib/PanelDashboard.svelte`.

**Si pregunta.**
- Las tablas estan en `clickhouse/001_esquema.sql`. `vista_producto` en la
  linea 31 con `ORDER BY (id_producto, fecha)` en la 71. El ORDER BY de
  ClickHouse es el orden fisico en el disco, no un indice aparte.
- La consulta de ascenso es `enAscenso()` en
  `backend/src/services/admin/admin-tendencias-avanzadas.service.ts:93`, sobre el
  resumen diario `vistas_por_producto_dia`, y el embudo en `:155`.
- En la Entrega 2 respondio en 13 ms sobre un lote sembrado y separo el ascenso
  real del producto inflado, 45 vistas por persona contra 1,6.

### 9. Las relaciones que delatan, Neo4j
El fraude en resenas es un problema de relaciones. Cuentas que se califican
entre si, en circulo. La consulta principal busca un camino cerrado que sale de
una cuenta y vuelve a ella recorriendo entre cuatro y ocho relaciones, asi que
cuatro saltos son un par, seis un triangulo y ocho un cuadrado. Ninguna consulta
prueba un fraude, senalan cuentas para que una persona las revise. Y el mismo
grafo da quienes lo compraron tambien llevaron, primero los de su misma
categoria.

**Se hace.** En la ventana InPrivate del admin.
1. Clic en la pestana **Fraude** y despues en **Resenas en anillo**. Sale
   **Manipulacion de resenas** con los pendientes. Cada tarjeta dice el tipo,
   por ejemplo **Reputacion en minutos**, las cuentas, cuantas resenas y cuando
   se detecto.
2. Las otras tres son **Casos**, que junta varias senales en un caso para
   revisar, **Intentos de entrada** y **Compras y navegacion**.
3. En la ventana normal, la ficha de **Laptop Aurora 14** y bajar hasta **Quienes
   lo compraron tambien llevaron**. Las primeras son laptops, porque van primero
   las de su misma categoria.

**Por dentro.** La pestana llama `GET /admin/fraude/alertas-resenas` y
`GET /admin/fraude/alertas-login`, desde `frontend/src/lib/PanelFraude.svelte`.
El estante llama `GET /productos/7/tambien-compraron`, que lee Neo4j.

**Si pregunta por que dice revisado hace unas horas.** Esa linea dice cuando
llego al grafo la ultima resena nueva, no cuando corrio el detector. **Al dia**
quiere decir que no falta ninguna por pasar. Sale de `max(procesado_en)` en
`backend/src/services/grafo/grafo-sync.service.ts:495`.

**Si pregunta.**
- El anillo es el Cypher de `backend/src/services/fraude/anillos-detector.service.ts:268`,
  `MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)`. El
  detector corre cada 15 minutos (`:29`) y al momento cuando llega una resena
  (`detectarInmediato()` en `:84`).
- La resena es un nodo y no una arista, para poder colgarle la calificacion, la
  fecha y el producto. Informe de la Entrega 2, 5.2.
- Tambien compraron esta en
  `backend/src/services/productos/tambien-compraron.service.ts:130`. El
  `CASE WHEN` de la linea 136 pone grupo 0 a la misma categoria y el `ORDER BY
  grupo` de la 140 los pone primero. Es ADR-25.

### 10. Si se cae una base, la tienda sigue
Cada base tiene su respaldo, con un cortacircuitos. El profesor pregunto que hace
la tienda si no estan las seis, y lo medimos tambien con varias apagadas a la
vez. Mientras PostgreSQL este prendido se puede comprar, sea cual sea el resto.
Sin PostgreSQL la tienda se puede mirar pero no comprar, y lo dice con un aviso
en lugar de quedarse esperando. Al prender otra vez las bases, el backend las
vuelve a usar solo.

**Se hace (si hay tiempo).** Con `.\remoto\caidas.ps1 -Accion levantar` corrido
antes, `-Accion apagar -Base redis` y recargar la tienda. Despues `-Accion
prender -Base redis`.

**Si pregunta.**
- La justificacion esta en el informe final, 4.4, la tabla de varias bases apagadas, y en ADR-22.
- El cortacircuitos es `backend/src/helpers/cortacircuitos.ts:27`. Despues de un
  fallo pausa la base 15 segundos (`:40`) para no esperar en cada peticion.
- `node pruebas/caidas.mjs` da 51 comprobaciones con cada base apagada y otras
  51 congelada. `pruebas/caidas_varias.mjs` mide una, dos o tres a la vez.

### 11. Las 26 decisiones
Los numeros de las decisiones chocaban entre entregas y ahora hay un solo
registro, del 1 al 26. Las de fondo verde se habian hecho sin su registro y
ahora lo tienen, como comprar sin MongoDB o la verdad del carrito en
PostgreSQL.

### 12. Retrospectiva
Siete decisiones que sostendriamos y ocho que no. La mas clara, el carrito solo
en Redis, que el 17 de octubre paso a tener su verdad en PostgreSQL.

### 13. Lo aprendido
Cada dato con un solo dueno escrito. En casi todo lo que replanteariamos, una
copia termino comportandose como si fuera la verdad.

---

## Parte 3. La Entrega final, vectores y control de acceso (Jose David, 10 min)

### 14. Recomendacion semantica
El enunciado pide sugerencias por la similitud semantica de la descripcion. El
texto de cada producto se arma con su nombre, su categoria y su descripcion,
leidos de MongoDB. Ollama lo convierte en un vector de 768 numeros con el modelo
paraphrase-multilingual, en la misma maquina y sin costo. El vector se guarda en
PostgreSQL con pgvector y un indice HNSW por coseno.

**Si pregunta.**
- La tabla es `vector_producto`, `migrations/040_vectores_en_postgres.sql:40`, y
  el indice HNSW en la linea 69.
- La llamada a Ollama es `pedirVectores()` en
  `backend/src/helpers/vectores-ollama.ts:33`.
- El worker que lo mantiene al dia es `VectoresSyncService`,
  `backend/src/services/productos/vectores-sync.service.ts:66`, cada 10
  segundos. Solo llama a Ollama si cambio el md5 del texto.

### 15. Primero su categoria, despues el resto
En la ficha, el estante Parecidos a este sigue el mismo esquema que quienes lo
compraron tambien llevaron. El primer bloque trae los productos de su misma
categoria, del mas parecido al menos, y despues el resto del catalogo. Solo por
el vector, sin decirle la categoria al modelo, dos de cada tres vecinos ya son de
la misma categoria, contra seis de cada cien al azar. Y la ruta da los mismos
seis que el calculo exacto en los mil productos.

**Se hace.** En la ventana normal.
1. En el buscador de arriba escribir `maillot` y, en la lista que sale, clic en
   **Maillot de ruta Peloton**.
2. Bajar hasta **Parecidos a este**. Salen cinco de ciclismo, el candado, los
   guantes, el casco, el sillin y la bomba de piso, y al final la **Comoda
   Sendero**. La comoda tiene mas parecido que la bomba de piso, pero va despues
   porque es de otra categoria.

**Por dentro.** El estante llama `GET /productos/70/similares`, desde
`traerSimilares()` en `frontend/src/routes/producto/[id]/+page.svelte:178`.

**Si pregunta.**
- La ruta es `GET /productos/:id/similares`,
  `backend/src/controllers/productos/similares.controller.ts:20`.
- `SimilaresService` en `backend/src/services/productos/similares.service.ts`.
  El bloque 1 es la consulta de la linea 107, filtrada por la categoria. El
  bloque 2 la de la 127, con el indice HNSW. Se llenan en ese orden en las
  lineas 170 y 171. Cada resultado trae `misma_categoria`.
- El operador `<=>` es la distancia coseno, y el parecido es uno menos la
  distancia.
- `buscarCercanos()` en `backend/src/helpers/vectores-pgvector.ts:41` sube
  `hnsw.ef_search` y activa `hnsw.iterative_scan` (lineas 50 y 51), porque con
  los valores de fabrica el indice mira 40 candidatos y el filtro dejaba menos
  filas.
- En el frontend, `traerSimilares()` en
  `frontend/src/routes/producto/[id]/+page.svelte:178` y el estante en la 1204.
- La prueba es `python pruebas/recomendacion_semantica.py`, 21 en verde.

### 16. Una frase encuentra lo que nombra
Con los mismos vectores el buscador sumo dos formas de buscar. La hibrida junta
la busqueda por palabras de Elasticsearch con la busqueda por significado de
PostgreSQL. La de intencion compara la frase con el vector de las resenas y
ensena lo que cuentan otros compradores. Asi una frase encuentra un producto
aunque no comparta ninguna palabra con su nombre.

**Se hace.** En la ventana normal, en el buscador de arriba escribir `algo para
salir a pedalear` y dar Enter. En la pagina de resultados sale arriba la seccion
**Lo que cuentan otros compradores**, con resenas que hablan de eso aunque no
usen esas palabras.

**Por dentro.** Esa pagina llama tres rutas a la vez.
`GET /buscador/productos/hibrida`, con `buscarHibrida()` de
`frontend/src/lib/buscador.ts:196`, `GET /buscador/productos/intencion`, con
`buscarPorIntencion()` de la linea 262, y la facetada de siempre.

**Si pregunta.**
- La hibrida mezcla las dos listas por posicion con RRF, `combinar()` en
  `backend/src/services/buscador/hibrida.service.ts:352`, con la constante 60 de
  la linea 33. Si Ollama no contesta, responde solo por palabras.
- La de intencion es `backend/src/services/buscador/intencion.service.ts:105`,
  busca en `vector_comentario` en la linea 194.
- El vendedor tambien recibe sugerencias de categoria y de productos parecidos al
  proponer uno, `backend/src/services/vendedores/sugerencias-propuesta.service.ts:110`.
- Las resenas casi iguales para el fraude las compara PostgreSQL con
  `paresParecidos()` en `backend/src/helpers/vectores-pgvector.ts:74`, sin sacar
  los vectores de la base.

### 17. El viaje del vector
Empezo en pgvector el 25 de septiembre. El 4 de octubre se mudo a Elasticsearch,
y el 16 volvio a pgvector, porque el profesor pidio pgvector y al medir contra el
coseno exacto pgvector coincidio en 1000 de 1001 y Elasticsearch en 317. Una
decision comoda tambien hay que medirla.

### 18. Cada servicio entra con lo justo
El control de acceso empezo en Redis con un usuario por servicio, y el 23 de
octubre lo llevamos a las cinco bases que lo permiten. El backend lee y escribe
datos, pero no puede crear ni borrar tablas, colecciones o indices. Las
herramientas solo miran. Neo4j es la unica base sin usuario por servicio, porque
la edicion community no trae roles.

**Si pregunta.** Los usuarios se crean en `seguridad/postgres.sql`,
`seguridad/mongo.js`, `seguridad/clickhouse.sql`, `seguridad/elastic.sh` y, los
de Redis, en `docker-compose.yml` de la linea 170 a la 205. El backend entra con
`mesh_backend`, se ve en `backend/.env`.

### 19. Lo que encontramos
Revisando la seguridad encontramos que Elasticsearch tenia la seguridad apagada
con un comentario que decia lo contrario, que DbGate entraba a MongoDB como root,
y que Neo4j no puede tener roles. Los tres estan corregidos o explicados.

### 20. La prueba
93 bien y 0 mal. Cada negativa tiene su control, que mesh_lectura no pueda
escribir solo cuenta si mesh_backend si pudo. Lo que borraria algo se intenta en
una transaccion que se deshace o sobre algo que no existe.

**Si pregunta.** `bash seguridad/prueba_acceso.sh`, corrida otra vez el 5 de
noviembre contra las bases, 93 OK.

### 21. Permisos por rol
El profesor pidio el control de acceso tambien a nivel de funcionalidades. Cada
una de las 136 rutas privadas declara la accion que hace, por ejemplo
ofertas.publicar, y un guard del backend le pregunta a la tabla rol_permiso en
ese momento si el rol de la cuenta la tiene. Si no, 403, y el intento queda
anotado. Quitar una fila vale en la peticion siguiente, sin compilar ni
reiniciar.

**Se hace.** En la ventana InPrivate del admin, pestana **Permisos**. Arriba
**Permisos por rol**, los 38 permisos con una columna por rol, Comprador,
Vendedor y Admin. Las casillas de `cuenta.ver` y las dos de `permisos` del admin
salen en gris, porque no se pueden quitar, y al pasar el raton dicen **No se
puede quitar**. Abajo **Lo ultimo que paso**, con cuando, quien, su rol, el
permiso que le falto y la ruta que pidio. Si Postman ya corrio, ahi salen sus
403. Las casillas en gris tambien las prueba Postman, en la carpeta 4. Quitarlas
directo contesta 409 y no borra nada.

**Por dentro.** La matriz llama `GET /admin/permisos` y el registro
`GET /admin/permisos/registro`, desde `leerMatriz()` y `leerRegistro()` de
`frontend/src/lib/permisos.ts:53` y `:57`. Marcar o desmarcar una casilla llama
`POST` o `DELETE /admin/permisos/:idRol/:idPermiso`.

**Si pregunta.**
- Las tablas son de `migrations/050_permisos_por_rol.sql`, `rol_permiso` en la
  linea 70 y `auditoria_permiso` en la 93.
- `SesionGuard`, `backend/src/guards/sesion.guard.ts:71`, dice quien es o 401, y
  lee el rol de la base en cada peticion (linea 94), no del token.
- `PermisoGuard`, `backend/src/guards/permiso.guard.ts:41`, dice que puede o 403
  (linea 81). Una ruta sin `@Permiso` tambien se niega (linea 55).
- La pregunta es `PermisosService.tiene()`,
  `backend/src/services/acl/permisos.service.ts:106`.

### 22. Un ACL por oferta
Lo de arriba es por rol. Ninguna base sabe que persona pide, todo llega como
mesh_backend, asi que el permiso de cada persona vive en la aplicacion. Cada
oferta lleva su lista, quien puede verla, editarla o ponerle descuento y hasta
cuando. Sin ninguna entrada se niega con el mismo 404 de una oferta ajena, y si
la ve pero no la puede editar, 403.

**Si pregunta.** `migrations/049_acl_ofertas.sql:61`,
`backend/src/guards/permiso-oferta.guard.ts:42` y
`AclOfertasService.comprobar()` en `backend/src/services/acl/acl-ofertas.service.ts:83`,
con el 404 en la linea 132 y el 403 en la 134.

### 23. En vivo, dentro de cada base
Ahora sin ningun script. Entramos a cada base con un usuario que no tiene el
permiso, ensenamos que si puede lo suyo, y que la base le dice que no.

**Se hace, en la PC de las bases (unos 3 minutos).** Las ordenes exactas estan en
`docs/GUIA-ESTUDIO-ACL.md`, seccion 5.
1. PostgreSQL como `mesh_lectura`. `SELECT count(*) FROM pedido` devuelve los
   pedidos, y un `UPDATE` contesta `cannot execute UPDATE in a read-only
   transaction`. Como `mesh_backend`, `CREATE TABLE` contesta `permission denied
   for schema public`.
2. MongoDB como `mesh_lectura`. Cuenta los productos y un `updateOne` contesta
   `not authorized on mesh`.
3. Redis como `inspeccion`. `SET` contesta `NOPERM`. Como `backend`, `KEYS *`
   tambien.
4. ClickHouse como `mesh_lectura`. `SELECT` si, `INSERT` contesta `ACCESS_DENIED`.
5. Neo4j. `CREATE ROLE lector` contesta `Unsupported administration command`.

### 24. Postman, la ruta directo
Y el control de las funciones, llamando al backend directo, sin la pagina.
Entramos como compradora y pedimos rutas de vendedor y de admin. Todas dan 403
con el permiso que falta. Despues como vendedor, las de admin dan 403. Y al final
el admin ve en el registro cada intento negado. La ultima carpeta intenta una
inyeccion SQL en el login, en un id y en el buscador, y no pasa, porque las
consultas van con parametros.

**Se hace (1 minuto).** En Postman, la coleccion **Mesh, control de acceso en
vivo**, **Run** y **Start run**. En unos once segundos salen 64 en verde.
Despues, con **Send**, **Ver todas las cuentas** de la carpeta 2 para que se vea
el 403, y **Login con inyeccion SQL** de la carpeta 8 para que se vea el 401.

**Si pregunta.**
- Cada peticion tiene su prueba en la pestana **Scripts**, y lo que dio en
  **Test Results**. Las carpetas 0 a 7 son las 56 de permisos y la 8 las 8 de
  inyeccion.
- El login busca con `WHERE correo_electronico = $1 OR usuario = $1`,
  `backend/src/services/usuario.service.ts:137`. Lo que escribe la persona viaja
  aparte como un valor y nunca se pega al SQL. Un id con letras se corta con 400
  antes de tocar la base, `backend/src/services/compradores/pedidos.service.ts:120`.
- La coleccion completa se corrio el 6 de noviembre con Newman y en Postman, 64
  peticiones en verde. Esta en `presentacion-final/postman/`, y
  `importar-a-postman.ps1` la mete con su ambiente en el Postman de quien lo corra.

### 25. Gracias
Preguntas. Las respuestas cortas estan en `PREGUNTAS-SUSTENTACION.md`.

---

## Antes de presentar

- Las dos PC en la misma red y sin cambiarse de red durante la presentacion. Un
  cambio de red corto las bases de la PC de Jose David unos 20 minutos el 23 de
  octubre.
- Tailscale prendido en las dos, y en la PC del backend
  `.\usar-bases-remotas.ps1 -Ip 100.64.42.11` antes de prender el backend.
- `node remoto/tunel.cjs 100.64.42.11` prendido en la PC del backend, para las
  carpetas 6 y 7 de Postman y la pagina `http://localhost:8123/play`. Cada demo
  del panel de comandos lo apaga al terminar, asi que si se usa una hay que
  prenderlo otra vez antes de Postman.
- `ollama serve` prendido en la PC del backend, y una busqueda por frase de
  prueba antes de empezar.
- Postman abierto con la sesion iniciada, porque sin cuenta no deja usar
  colecciones, y con la coleccion y el ambiente **Mesh, claves de las bases**
  elegido. Una terminal abierta en la PC de las bases.
- Unos 15 minutos antes, abrir cinco o seis fichas en la tienda, porque lo mas
  visto sale con un solo producto si nadie navego.
- La matriz de permisos completa, `SELECT count(*) FROM rol_permiso;` tiene que
  dar 76.
- No correr la bateria de pruebas el mismo dia. Deja cuentas, ofertas y senales
  de fraude de prueba.
- Para apagar una base en vivo, `.\remoto\caidas.ps1 -Accion levantar` unos
  minutos antes, tarda unos 3.
- Dos ventanas de Edge con la tienda, `http://localhost:5173`. Una normal, sin
  sesion, para la parte 1 y las laminas 15 y 16. Otra InPrivate, con Ctrl Shift
  N, donde ya se entro como `admin@mesh.com` con `Admin123`, para Tendencias,
  Fraude y Permisos. Cada ventana guarda su propia sesion, asi que no se pisan.
- La carpeta 5 de Postman cambia la oferta 3 de verdad. La corre una sola
  persona a la vez, nunca dos Postman al mismo tiempo.

---

## Apoyo de la parte 3. Donde esta el control de cada peticion de Postman

Para Jose David, si el profesor pregunta donde esta en el codigo lo que acaba de
dar 401 o 403.

**La idea en tres frases.** La pagina esconde botones segun el rol, pero eso es
solo comodidad. El que decide es el backend, en cada peticion, con dos guardias.
Postman se salta la pagina y llama directo, y por eso prueba al backend.

**Las dos guardias del backend, iguales para todas las rutas.**
1. `SesionGuard`, `backend/src/guards/sesion.guard.ts:71`. Sin cookie o con la
   cookie vencida, 401.
2. `PermisoGuard`, `backend/src/guards/permiso.guard.ts:41`. Lee el `@Permiso`
   de la ruta y le pregunta a la tabla `rol_permiso` si el rol lo tiene. Si no,
   403 en la linea 81. Una ruta sin `@Permiso` tambien se niega, linea 55.

**Lo que hace la pagina.** El panel arma sus pestanas segun el rol, en
`frontend/src/routes/panel/+page.svelte:61` y `:62` (`esAdmin` y
`esVendedor`) y la lista de la linea 135. Una compradora no ve la pestana
Cuentas, pero si llama la ruta igual, la frena el backend.

| Carpeta | Peticion | Da | Su `@Permiso` en el backend | Pantalla de la pagina que la usa |
|---|---|---|---|---|
| 1 | `GET /usuario/yo` sin sesion | 401 | `cuenta.ver`, `backend/src/controllers/usuario.controller.ts:301` | Toda la pagina, al cargar, `frontend/src/lib/sesion.ts:138` |
| 1 | `GET /admin/permisos` sin sesion | 401 | `permisos.ver`, `backend/src/controllers/admin/admin-permisos.controller.ts:32` | Admin, pestana Permisos, `frontend/src/lib/permisos.ts:53` |
| 1 y 2 | `POST /vendedor/ofertas` | 401 y 403 | `ofertas.publicar`, `backend/src/controllers/vendedores/ofertas.controller.ts:175` | Vendedor, **Publicar una oferta** |
| 2 | `GET /comprador/pedidos`, el control que si pasa | 200 | `pedidos.ver`, `backend/src/controllers/compradores/pedidos.controller.ts:30` | **Mis pedidos**, `frontend/src/lib/pedido.ts:297` |
| 2 y 3 | `GET /admin/usuarios` | 403 | `usuarios.ver`, `backend/src/controllers/admin/admin-usuarios.controller.ts:22` | Admin, pestana Cuentas |
| 2 y 3 | `PATCH /admin/usuarios/:id`, hacerse admin | 403 | `usuarios.editar`, misma ruta, linea 42 | Admin, **Bloquear**, `frontend/src/lib/BloquearCuenta.svelte:60` |
| 2 y 3 | `GET /admin/reportes/ventas` | 403 | `reportes.ver`, `backend/src/controllers/admin/admin-reportes.controller.ts:24` | Admin, pestana Reportes |
| 2 | `GET /admin/fraude/casos` | 403 | `fraude.ver`, `backend/src/controllers/admin/admin-casos-fraude.controller.ts:31` | Admin, Fraude, **Casos** |
| 2 | `GET /vendedor/ofertas` | 403 | `ofertas.ver`, `backend/src/controllers/vendedores/ofertas.controller.ts:47` | Vendedor, pestana Ofertas |
| 2 y 3 | `GET /db/cortacircuitos` | 403 | `sistema.ver`, `backend/src/controllers/base-datos.controller.ts:48` | Ninguna, es del admin y de las demos |
| 3 | `GET /vendedor/ofertas/paginado`, el control que si pasa | 200 | `ofertas.ver`, la misma linea 47 | Vendedor, **Mis ofertas** |
| 3 | `GET /admin/dashboard/resumen` | 403 | `dashboard.ver`, `backend/src/controllers/dashboards/dashboard-general.controller.ts:59` | Admin, pestana Dashboard |
| 3 | `GET /admin/fraude/alertas-login` | 403 | `fraude.ver`, `backend/src/controllers/fraude/fraude.controller.ts:28` | Admin, Fraude, **Intentos de entrada** |
| 3 | `GET /admin/eventos/tendencias` | 403 | `tendencias.ver`, `backend/src/controllers/admin/admin-tendencias-avanzadas.controller.ts:27` | Admin, pestana Tendencias |
| 4 | `GET /admin/permisos` y `/admin/permisos/registro` como admin | 200 | `permisos.ver`, la misma linea 32 | Admin, pestana Permisos |
| 4 | `DELETE /admin/permisos/3/:id`, el admin se quita `permisos.administrar` | 409 | La revision de `backend/src/services/acl/permisos.service.ts:350`, antes del borrado de la linea 359 | Admin, Permisos, la casilla en gris que no se puede desmarcar |
| 4 | `DELETE /admin/permisos/1/:id`, le quita `cuenta.ver` al comprador | 409 | La misma linea 350 | La misma casilla en gris |

**La carpeta 5 tiene una guardia mas, la de cada oferta.** Pasa por las dos de
arriba y despues por `PermisoOfertaGuard`, `backend/src/guards/permiso-oferta.guard.ts:42`,
que le pregunta a `AclOfertasService.comprobar()` en
`backend/src/services/acl/acl-ofertas.service.ts:83` si esa cuenta tiene una
entrada para esa oferta. Sin ninguna entrada, 404 en la linea 132. Con ver pero
sin editar, 403 en la 134.

| Peticion | Da | Donde | Pantalla |
|---|---|---|---|
| `GET /compartidas/ofertas/3` sin entrada, con ver y ya quitado | 404, 200 y 404 | `@PermisoOferta('ver')`, `backend/src/controllers/compartidas/ofertas-compartidas.controller.ts:75`, y `ofertas.usar_compartidas` en la 53 | Vendedor, pestana **Compartidas** |
| `PATCH /compartidas/ofertas/3`, cambiar el precio sin editar | 403 | `@PermisoOferta('editar')`, misma ruta, linea 95 | En **Compartidas** el boton **Editar** ni sale si no tiene editar, `frontend/src/lib/OfertasCompartidas.svelte:198` |
| `POST /vendedor/ofertas/3/permisos`, la duena le da ver | 201 | `ofertas.compartir`, `backend/src/controllers/vendedores/permisos-oferta.controller.ts:34` | Vendedor, Ofertas, **Compartir**, `frontend/src/lib/compartidas.ts:83` |
| `DELETE /vendedor/ofertas/3/permisos/:id`, se lo quita | 200 | La misma, linea 77 | El mismo **Compartir**, `frontend/src/lib/compartidas.ts:95` |

**Las carpetas 6 y 7 no pasan por el backend.** Llaman directo a Elasticsearch y
a ClickHouse con sus usuarios de servicio. Ahi el control lo hace cada base, con
los roles de `seguridad/elastic.sh` y `seguridad/clickhouse.sql`. No hay pagina
que las use.

**La carpeta 8 no es de permisos.** Prueba que lo que se escribe no se vuelve
SQL. El login, `backend/src/services/usuario.service.ts:137`, la pantalla
**Iniciar sesion**, `frontend/src/routes/entrar/+page.svelte:61`. El id del
pedido, `backend/src/services/compradores/pedidos.service.ts:120`, la pantalla
**Mis pedidos** y **Ver detalle**.

---

## Como se conecta todo, para explicarlo facil

La pagina nunca habla con las bases. Habla solo con el backend, y el backend es
el unico que entra a las seis.

1. **La pagina.** Cada pantalla llama una ruta que empieza con `/api`, por
   ejemplo `/api/productos/7`. Eso esta en `frontend/src/lib/api.ts:14`.
2. **El paso de en medio.** Vite, el que sirve la pagina en el puerto 5173, le
   quita el `/api` y se la pasa al backend en el puerto 3000. Esta en
   `frontend/vite.config.ts:53`.
3. **El backend.** Cada ruta tiene su controller en `backend/src/controllers/`.
   Si es privada, primero `SesionGuard` dice quien es o 401, y despues
   `PermisoGuard` dice si su rol puede o 403. Solo si pasa las dos llega al
   servicio, y el servicio es el que va a PostgreSQL, MongoDB, Redis, Neo4j,
   ClickHouse o Elasticsearch.
4. **Postman.** Llama las mismas rutas del paso 3, pero directo al puerto 3000,
   sin la pagina. Por eso sirve de prueba, si la pagina esconde un boton pero la
   ruta dejara pasar, Postman lo veria. Y no lo ve, da 403.

Ejemplo completo. La compradora da clic en **Agregar**. La ficha,
`frontend/src/routes/producto/[id]/+page.svelte:683`, llama
`PUT /api/carrito/lineas/:idOferta`. Vite la pasa a `PUT /carrito/lineas/:idOferta`.
El backend la recibe en `backend/src/controllers/carrito/carrito.controller.ts:60`,
revisa la sesion y el permiso `carrito.usar`, y guarda la linea en PostgreSQL y
su copia en Redis.

---

## La tienda entera, clic por clic

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
ventana hay que salir primero.

### Sin sesion

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| Abrir `http://localhost:5173` | **Lo mas vendido ahora**, **Ventas relampago**, **Ofertas con descuento**, **Se compran juntos** y el catalogo con **Filtros** | `GET /productos/mas-vendidos`, `/productos/ofertas/venta-relampago`, `/productos/ofertas/descuento`, `/productos/combos`, `/productos` |
| Escribir en **Buscar productos** | La lista mientras se escribe, tolera errores como `labtop` | `GET /buscador/productos` |
| Enter | Resultados con filtros y sus numeros, y **Tal vez quisiste decir** | `GET /buscador/productos/facetado` y `/hibrida` |
| Una frase, como `algo para salir a pedalear` | Ademas **Lo que cuentan otros compradores** | `GET /buscador/productos/intencion` |
| Clic en un producto | La ficha con **Comprar**, **Detalles**, **Resenas**, **Parecidos a este** y **Quienes lo compraron tambien llevaron** | `GET /productos/:id`, `/similares`, `/tambien-compraron`, `/resenas` |
| **Agregar** sin sesion | No hay boton, dice **Inicia sesion para agregar al pedido** | Ninguna |

### Como compradora

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| **Entrar** | El panel, **Hola, Ana**, con **Avisos**, **Alertas** y **Mi cuenta** | `POST /usuario/login` |
| Volver al inicio | Suman **Para ti** y **Viste hace poco**, que dice **Ya lo compraste** en lo que ya compro | `GET /productos/para-ti`, `/productos/vistos-recientemente` |
| En una ficha, **Agregar** junto a un vendedor | Se abre **Tu carrito** a la derecha con la linea, **-**, **+**, **Quitar** y **Continuar al pago** | `PUT /carrito/lineas/:idOferta` |
| **Continuar al pago** | **Confirmar la compra**, la direccion, **Lo que llevas**, el total y **Como quieres pagar**, con Tarjeta, Transferencia o Efectivo contra entrega | `GET /comprador/pedidos/metodos-pago` y `/direccion-usuario` |
| Elegir **Efectivo contra entrega** y **Pagar** | **Gracias por tu compra** con el numero de pedido | `POST /carrito/comprar`, una sola transaccion en PostgreSQL |
| Arriba **Mis pedidos** | La lista con **Todos**, **Comprado** y **Cancelado**, y en cada uno **Ver detalle** y **Cancelar** | `GET /comprador/pedidos` |
| **Cancelar** y **Si, cancelar el pedido** | **Pedido cancelado**, se devuelven las unidades y el pago queda reembolsado | `POST /comprador/pedidos/:id/cancelar` |
| En una ficha, **Avisame si baja de precio** | Queda en **Avisos** del panel, en **Lo que sigues** | `POST /comprador/seguimientos` |
| Pestana **Resenas** de la ficha | Las estrellas, cada resena y **Util** o **No util**. Escribir una solo se puede si ya lo compro | `GET /productos/:id/resenas`, `POST /comentarios/:id/voto` |
| Panel, **Alertas** | **Alertas de seguridad** de su propia cuenta, con **Cambiar mi contrasena ahora** | `GET /perfil/alertas-fraude` |
| Panel, **Mi cuenta** | **Tu perfil**, **Tus direcciones** y **Tus pedidos** | `GET /perfil`, `/direccion-usuario` |

La compra de prueba del 6 de noviembre fue el pedido 1954, Cartas al puerto
seco por Q24.00, y se cancelo enseguida desde **Mis pedidos**.

### Como vendedor

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| **Entrar** | **Hola, Carlos** y las pestanas **Ofertas**, **Compartidas**, **Reglas**, **Proponer** y **Propuestas** | `POST /usuario/login` |
| **Ofertas** | **Mis ofertas** con **Todas**, **Activas**, **Pausadas** y las demas, y en cada una **Pausar**, **Descuento**, **Abrir venta relampago**, **Compartir** y **Editar** | `GET /vendedor/ofertas/paginado` |
| **Publicar una oferta** | Elegir un producto del catalogo y ponerle precio y unidades | `POST /vendedor/ofertas` |
| **Descuento** | Ponerle un porcentaje a esa oferta | `POST /vendedor/ofertas/:id/descuento` |
| **Abrir venta relampago** | Pocas unidades a precio especial, las aparta Redis | `/vendedor/ofertas/:id/venta-limitada` |
| **Compartir** | Darle a otra cuenta ver, editar o descontar esa oferta, hasta una fecha | `POST /vendedor/ofertas/:id/permisos` |
| **Compartidas** | **Compartidas contigo**, las ofertas de otros que le dejaron usar | `GET /compartidas/ofertas` |
| **Reglas** | **Descuentos automaticos** y **Descuentos por fecha**, con **Nueva regla** | `GET /vendedor/reglas-descuento/paginado` |
| **Proponer** | **Proponer un producto**, que entra al catalogo cuando el admin lo aprueba | `GET /vendedor/categorias` |
| **Propuestas** | **Mis propuestas al catalogo**, con **Reenviar a revision** si se la rechazaron | `GET /vendedor/productos/propuestas` |

### Como admin

| Clic | Lo que sale | Ruta que llama |
|---|---|---|
| **Entrar** y arriba **Admin** | **Hola, Sofia** y las pestanas **Dashboard**, **Reportes**, **Ofertas**, **Compartidas**, **Reglas**, **Catalogo**, **Propuestas**, **Cuentas**, **Permisos**, **Fraude** y **Tendencias** | `POST /usuario/login` |
| **Dashboard** | **Ventas en el tiempo**, **Por categoria**, **Por metodo de pago**, con **Ventas**, **Clientes**, **Vendedores y productos**, **Busquedas**, **Cancelaciones** y **Pedidos**, y **Exportar** | `GET /admin/dashboard/resumen` y las demas de `/admin/dashboard` |
| **Reportes** | **Pedidos**, **Pagos**, **Como pagan** y **Pedidos sin pagar** | `GET /admin/reportes/ventas` y `/admin/reportes/reservaciones` |
| **Catalogo** | **El catalogo** con **Publicar producto**, y en cada uno **Editar**, **Historial** y **Retirar** | `GET /vendedor/productos/paginado` |
| **Propuestas** | **Productos por revisar**, con **Aprobar** y **Rechazar** | `GET /vendedor/productos/propuestas/sin-aprobar` |
| **Cuentas** | Todas las cuentas con su rol y su estado | `GET /admin/usuarios`, `/admin/roles`, `/admin/estados` |
| **Permisos** | La matriz por rol y **Lo ultimo que paso** | `GET /admin/permisos` y `/admin/permisos/registro` |
| **Fraude** | **Casos**, **Intentos de entrada**, **Resenas en anillo** y **Compras y navegacion**, con **Bloquear**, **Marcar revisada** y **Descartar** | `GET /admin/fraude/alertas-login`, `/admin/fraude/alertas-resenas` |
| **Tendencias** | **Resumen**, **Para revisar** y **Rankings**, de ClickHouse | `GET /admin/eventos/vista`, `/carrito`, `/compra`, `/devolucion`, `/busqueda` |

Lo que se marca a mano en el admin, como **Bloquear** o **Aprobar**, cambia datos
de verdad. En la presentacion se ensena sin apretarlo, salvo que el profesor lo
pida.

### Como desarrollador, la pestana Comandos

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
misma PC y es el que decide que se puede correr.

**Ojo.** Solo funciona en la PC donde corre el panel. Cada demo apaga el tunel
al terminar, salvo las de caida, asi que despues de usar una hay que volver a
correr `node remoto/tunel.cjs 100.64.42.11` antes de las carpetas 6 y 7 de
Postman.
