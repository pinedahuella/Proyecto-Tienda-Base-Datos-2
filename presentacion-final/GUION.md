# Guion de la presentacion final

Entre 20 y 25 minutos, en tres partes, una por persona. La parte 3 es la mas
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
| 2. Lo que la tienda aprende y como resiste | 8 a 13 | Juan Pablo | 5 min |
| 3. La Entrega final, vectores y control de acceso | 14 a 25, con las pruebas en vivo | Jose David | 12 min |

Medido el 5 de noviembre. Lo que se dice, leido con la voz Sabina de Windows,
dura 2,2, 2,1 y 4,1 minutos. A ritmo de persona y con lo que se ensena en la
pantalla (la tienda unos 2 minutos, las bases en vivo unos 3 y Postman unos 2)
da unos 23 minutos. Si el tiempo aprieta, en la parte 2 se salta la caida en
vivo y en la parte 3 Postman se queda en las carpetas 1 a 4.

Antes de empezar, la lista del final de este archivo.

---

## Parte 1. La tienda y sus seis bases (Jose Manuel, 6 min)

### 1. Portada
Buenos dias. Somos Mesh. Hicimos TiendaYa, una tienda en linea donde varios
vendedores comparten un mismo catalogo, con seis bases de datos, y cada una entro
por la forma de la pregunta que contesta.

### 2. El equipo
Mantuvimos el reparto de todo el semestre. Jose David se encargo del backend. Yo
del frontend, las migraciones, los ETL, los scripts de cada base, las pruebas y
el arranque. Juan Pablo de los modulos de ClickHouse y Neo4j. Cada uno va a
presentar su parte.

### 3. El reto
Un producto describe una cosa del mundo y no es de nadie. Quien lo vende, a que
precio y con cuantas unidades es una oferta. Al cerrar el semestre son seis
bases, 93 tablas de 50 migraciones, 26 decisiones con su registro y 93
comprobaciones del control de acceso, ninguna mal.

### 4. Cada base, por la pregunta que contesta
PostgreSQL es la fuente de verdad del dinero y del stock. MongoDB guarda el
catalogo, porque cada categoria trae atributos distintos y la ficha se lee
entera. Redis guarda el carrito y la venta relampago, con operaciones atomicas.
Neo4j las relaciones entre cuentas y resenas. ClickHouse los eventos en el
tiempo. Y Elasticsearch el indice de busqueda.

### 5. La regla
PostgreSQL es la verdad y lo demas se puede rehacer. El dinero, el stock, los
pedidos y el carrito solo se escriben ahi, en una transaccion. Cada copia en
otra base tiene de donde reconstruirse.

**Si pregunta por que no todo en PostgreSQL.** Cada base contesta mejor su
pregunta, pero solo una guarda la verdad. Informe final, 4.2, la tabla de los componentes.

### 6. El diagrama
Las flechas continuas son lo que hace el backend con cada base, y las punteadas
y numeradas son datos que viajan de una base a otra. El flujo 11 lleva el texto
de cada producto de MongoDB a Ollama y guarda su vector en PostgreSQL. Cada caja
dice con que usuario entra el backend.

**Se hace.** Clic sobre el diagrama para abrirlo a tamano completo, Esc para
cerrar.

**Si pregunta.** Sale de `docs/generar-arquitectura.py`. El diagrama entidad
relacion sale de `docs/generar-er.py`, que lee la base en funcionamiento y falla
si una tabla queda sin dibujar.

### 7. La tarjeta sale entera de Elasticsearch, y la tienda en vivo
El buscador tolera errores de tecleo y ordena por relevancia. El profesor pidio
la foto en el resultado, y la foto viaja en el mismo documento que el nombre y
el precio, guardada sin indexar, asi que una sola consulta pinta la tarjeta.

**Se hace, en la tienda (unos 2 minutos).**
1. Escribir `labtop` en el buscador de arriba. Salen las laptops.
2. Enter, y en `/buscar` marcar una faceta, por ejemplo la categoria Laptops y
   un rango de precio. Los numeros de cada filtro salen de la misma consulta.
3. Abrir una laptop. La ficha trae sus variantes y sus caracteristicas de
   MongoDB, y abajo los estantes de recomendaciones.

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

## Parte 2. Lo que la tienda aprende y como resiste (Juan Pablo, 5 min)

### 8. Lo que pasa en el tiempo, ClickHouse
Cada vista, carrito, busqueda, compra y devolucion queda como un evento en
ClickHouse. Lo elegimos porque guarda cada columna por separado y compara
periodos sin definir cada pregunta antes de guardar el dato. La consulta de
productos en ascenso compara las vistas de los ultimos siete dias contra las
anteriores, y cuenta cuantas personas distintas hay detras, para que un producto
inflado con clics repetidos no parezca una tendencia.

**Se hace.** Panel del admin, pestana **Tendencias**, y despues **Dashboard**.

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

**Se hace.** Panel del admin, pestana **Fraude**, y en una ficha el estante
**Quienes lo compraron tambien llevaron**.

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

## Parte 3. La Entrega final, vectores y control de acceso (Jose David, 12 min)

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

**Se hace.** Abrir el Maillot de ruta Peloton y bajar a **Parecidos a este**.
Salen cinco de Ciclismo y despues una comoda. La comoda tiene mas parecido que
la bomba de piso, pero va despues porque es de otra categoria.

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

**Se hace.** Buscar `algo para salir a pedalear`. Sale la seccion **Lo que
cuentan otros compradores**.

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

**Se hace.** Panel del admin, pestana **Permisos**. La matriz, y abajo **Lo
ultimo que paso** con los intentos negados.

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
el admin ve en el registro cada intento negado.

**Se hace.** En Postman, la coleccion **Mesh, control de acceso en vivo**,
carpetas 1, 2, 3 y 4, con **Send** una por una. Si hay tiempo, la 5 (una oferta
compartida, 404, 200 y 403) y la 6 (Elasticsearch directo, 403).

**Si pregunta.** Cada peticion tiene su prueba en la pestana **Test Results**.
La coleccion completa se corrio el 5 de noviembre, 54 peticiones en verde. Esta
en `presentacion-final/postman/`.

### 25. Gracias
Preguntas. Las respuestas cortas estan en `PREGUNTAS-SUSTENTACION.md`.

---

## Antes de presentar

- Las dos PC en la misma red y sin cambiarse de red durante la presentacion. Un
  cambio de red corto las bases de la PC de Jose David unos 20 minutos el 23 de
  octubre.
- Tailscale prendido en las dos, y en la PC del backend
  `.\usar-bases-remotas.ps1 -Ip 100.64.42.11` antes de prender el backend.
- `node remoto/tunel.cjs 100.64.42.11` prendido en la PC del backend, para la
  carpeta 6 de Postman y la pagina `http://localhost:8123/play`.
- `ollama serve` prendido en la PC del backend, y una busqueda por frase de
  prueba antes de empezar.
- Postman abierto con la coleccion y el ambiente **Mesh, claves de las bases**
  elegido, y una terminal abierta en la PC de las bases.
- Unos 15 minutos antes, abrir cinco o seis fichas en la tienda, porque lo mas
  visto sale con un solo producto si nadie navego.
- La matriz de permisos completa, `SELECT count(*) FROM rol_permiso;` tiene que
  dar 76.
- No correr la bateria de pruebas el mismo dia. Deja cuentas, ofertas y senales
  de fraude de prueba.
- Para apagar una base en vivo, `.\remoto\caidas.ps1 -Accion levantar` unos
  minutos antes, tarda unos 3.
