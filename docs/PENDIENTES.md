# Pendientes

Lo que se sabe que falta. Un solo sitio para mirar.

**Al 2026-09-28.** Lo que esta hecho y probado no esta aqui: esta en
`docs/TRASPASO.md`.

| # | Que | De quien | Cuanto | Urgencia |
|---|---|---|---|---|
| 1 | El precio se congela al PAGAR, no al agregar | -- | -- | **resuelto de otra forma el 2026-09-23 (commit e7f1e02 de David)**: cada linea del carrito en Redis es una foto en JSON con su precio (ya con descuento), y al pagar el backend compara esa foto con el precio de hoy el solo. `lineas_precio_visto` se quito. Si cambio, contesta `comprado:false` con avisos; con `confirmar_cambios:true` cobra el de hoy. Sigue cobrando el de pagar, pero nunca en silencio |
| ~~2~~ | ~~La semilla no respalda con compras las 86 resenas~~ | -- | -- | **CERRADO el 2026-08-30** |
| ~~3~~ | ~~`Carrito.svelte` quedo muerto~~ | -- | -- | **CERRADO el 2026-08-30** |
| ~~4~~ | ~~El grafo se queda viejo y el ETL relee todo~~ | -- | -- | **CERRADO el 2026-09-04.** La cola (015) es mia, el worker y la conciliacion son de Jose David, y el aviso del panel es mio. El grafo se mantiene solo |
| 5 | Dos asignadores de id de producto que no se hablan | -- | -- | **sin prioridad (decidido el 2026-09-19)**: "da igual". El arranque sigue avisando si hay cruce |
| ~~6~~ | ~~La nota no llega al catalogo hasta que corre el ETL~~ | -- | -- | **CERRADO el 2026-09-04.** Etapa nueva del ETL, con `bash pruebas/notas.sh` (10 OK) |
| ~~7~~ | ~~Una venta relampago que vence sola deja `es_inventario_limitado` en true~~ | -- | -- | **CERRADO el 2026-09-04.** `revisarVencidas()`, un `@Interval` en `inventario-limitado.service.ts`, apaga la columna solo |
| ~~8~~ | ~~Editar el stock durante una venta relampago desincroniza las dos bases~~ | -- | -- | **CERRADO el 2026-09-04.** El `PATCH` contesta 409 cuando viene `ajuste_stock` con la venta abierta |
| ~~9~~ | ~~Las tres rutas de la base columnar~~ | -- | -- | **CERRADO el 2026-09-18**, pero con otra forma: `POST /eventos/vista|carrito|busqueda-clic`, seis rankings `GET /admin/eventos/*` y `GET /productos/mas-vendidos`. El panel y el estante de la portada estan hechos, con `bash pruebas/tendencias.sh` (50 OK desde que solo cuentan `lote = 'real'`). David decidio el 2026-09-19 que las seis rutas cuentan solo lote real, sin parametro: no queda nada pendiente ahi |
| ~~10~~ | ~~Los filtros facetados del buscador, con agregaciones~~ | -- | -- | **CERRADO el 2026-09-26 por Jose David (ced29f5)**: `GET /buscador/productos/facetado`, puerto a TypeScript de `facetas.py`, con la misma forma que espera `/buscar`. Tambien acepta `nombre` vacio para navegar solo por facetas. El clic de `/buscar` manda las facetas activas y el admin tiene tres rankings nuevos en Tendencias. Las columnas de ClickHouse quedaron en `clickhouse/001_esquema.sql`. Falta verlo en vivo |
| ~~11~~ | ~~La prueba de falla simulada del checkout~~ | -- | -- | **CERRADO el 2026-09-06.** `bash pruebas/falla_checkout.sh`, 31 OK y 0 FALLA, con su evidencia en `CONSISTENCIA-CHECKOUT.md`. Vuelto a correr el 2026-09-11: 31 OK |
| 12 | El checkout no compra con MongoDB caido, y esa base no esta en el COMMIT | Entrega 3 | ver abajo | **en curso (2026-09-29), salida 2 elegida, decision 5**. La base ya esta, migraciones 029 (copia en oferta) y 030 (outbox evento_catalogo) y paso 7e de arrancar, probadas. Falta el backend, pasos 3.1 a 3.9 de `docs/PLAN-COMPRAR-SIN-MONGO.md`, y despues ajustar el escenario B de `pruebas/falla_checkout.sh` |
| 13 | La lista de ofertas del vendedor viene entera, sin paginar | Jose David la ruta, yo la pantalla | ver `BACKEND-PENDIENTE.md` | **cerrado en lo que importa el 2026-09-19**: David agrego el filtro `estado` y el panel ya pagina con contadores exactos. El `q` de busqueda por texto **no importa (decidido el mismo dia)**; mientras, el buscador pide la lista completa |
| ~~14~~ | ~~Elasticsearch se llena con cada login y ninguna ruta lo consulta~~ | -- | -- | **CERRADO el 2026-09-18 por Jose David (10b8fe5)**: `fraude-login-retrospectivo.service.ts` y `toma-cuenta.service.ts` hacen agregaciones `terms` y `cardinality` sobre el indice de login |
| 15 | Los detectores que faltan del fraude del login, y los detalles de los tres que hay | Jose David | ver abajo | media: lo que hay funciona; lo que falta son senales y bordes |
| ~~16~~ | ~~La copia de logueos a ClickHouse lee `log_login`, que no recibe filas~~ | -- | -- | **CERRADO por decision (2026-09-19)**: ClickHouse ya no maneja registros de login, los lleva Elasticsearch. La copia queda congelada a proposito |
| ~~17~~ | ~~Medir en vivo lo que se toco despues de la corrida del 2026-09-11~~ | -- | -- | **CERRADO el 2026-09-12.** Medido contra las bases y roto a proposito; los numeros estan en `docs/TRASPASO.md` |
| ~~20~~ | ~~`comprarPedido` no anota la compra en ClickHouse~~ | -- | -- | **DESCARTADO el 2026-09-19 por Jose David**: es codigo viejo que ninguna pantalla usa (el checkout paga por el carrito). `etl/cargar_compras.sh` lo cubre si alguien lo llama a mano |
| ~~21~~ | ~~El lote de eventos de demo no se renueva solo~~ | -- | -- | **YA NO APLICA (2026-09-19)**: los rankings cuentan solo lote real y lo sembrado no se ve en Tendencias. Para una demo hay que generar eventos REALES usando la app |
| 22 | `rechazo_oferta` queda en cero y no tiene script | mia | -- | baja: medida en 0 el 2026-09-18. Se llena rechazando una oferta desde la aplicacion, no hay generador. `anillo_fraude` y `anillo_fraude_resena` ya no estan en cero, el 2026-09-19 quedaron con 3 y 8 filas de las demos de `demo-anillo-resenas.ps1` |
| ~~23~~ | ~~Busquedas y clics de busqueda reales en cero~~ | -- | -- | **CERRADO el 2026-09-19.** Ya hay eventos reales (5 busquedas y 2 clics). Con cuenta de ADMIN no subian por diseno: el buscador de la cabecera usaba la ruta de admin, sin `sesion` y sin registrar el clic. Ahora es el mismo buscador para todos (solo lo activo, y registra busqueda y clic); lo especializado del admin vive solo en el panel de Catalogo |
| ~~18~~ | ~~Las tablas de la 015 a la 019 no estan en el diagrama ER~~ | -- | -- | **CERRADO el 2026-09-19.** `docs/diagrama-general.drawio` se genera ahora con `python docs/generar-er.py` desde la base viva: 50 cajas y 66 lineas, y el script falla si una tabla o una llave no tiene su dibujo. El de la Entrega 1 quedo en `docs/diagrama-general-entrega1.drawio` |
| ~~19~~ | ~~`trustProxy: 'loopback'` en `backend/src/main.ts`~~ | -- | -- | **CERRADO el 2026-09-19**: David lo agrego. `copia-backend.ps1` ya lo preveia |
| 24 | El estante de mas vendidos tarda hasta 10 minutos en ver un descuento o un precio nuevo | Jose David | ver `BACKEND-PENDIENTE.md` | **a medias el 2026-09-26 (37ad2e6)**: ya se arma al arrancar; al cambiar un precio sigue la ventana de 10 minutos |
| ~~25~~ | ~~El buscador no sabe si un producto tiene descuento~~ | -- | -- | **CERRADO el 2026-09-26**: David lo manda en la sincronizacion (37ad2e6) y de este lado va en `etl/extraer_busqueda.js` y el mapeo; la cabecera y /buscar ensenan "Con descuento" |
| ~~26~~ | ~~El historial de precio de una oferta no trae el % de descuento~~ | -- | -- | **CERRADO el 2026-09-26** por David (37ad2e6); Mis pedidos y el historial del vendedor ya lo ensenan |
| ~~27~~ | ~~"Parecidos a este" no pinta nada, falta `GET /productos/:id/similares`~~ | -- | -- | **CERRADO el 2026-09-26 por Jose David (ced29f5)**, con la misma forma que `tambien-vieron`. Suma `VectoresSyncService`, que cada 3 horas recalcula los productos marcados con `pendiente_vector` usando el mismo texto y hash que `cargar_vectores.ps1`. `cargar_vectores.ps1` le deja escrito en `backend/.env` el Ollama que eligio. Falta verlo en vivo |
| 31 | Los casos de fraude: falta decidir si una IP compartida une casos (C1) | Jose David y el equipo | ver `BACKEND-PENDIENTE.md` | **media, Entrega 3.** C2, C3, C5 y C8 arreglados por David el 2026-09-26 (14e5084), C6 y C7 el mismo 26 (de5de2a), comprobados con `pruebas/casos_fraude_fusion.cjs` y `pruebas/casos_fraude_granja.cjs`, 0 FALLA. Quedan C4 y C9 |
| 32 | Revision del profesor: decisiones genericas, dependencias entre bases y fraude | el equipo | `docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md` | **alta, para decidir antes de implementar (2026-09-28).** Modelo unico de senales y detecciones con historia en ClickHouse, doce consultas nuevas en las cinco bases, nombre en `oferta` para comprar sin MongoDB (cierra la fila 12), carrito con la foto del cliente, Elasticsearch mas alla de las facetas, busqueda hibrida con el vector, y reescribir las decisiones del informe. La seccion 1.6 junta lo pendiente del panel de fraude |
| ~~30~~ | ~~En el facetado, ClickHouse guarda en `resultados` los que se mostraron y no el total~~ | -- | -- | **CERRADO el 2026-09-26** por David (37ad2e6) |
| 29 | `GET /buscador/productos/sugerencias` existe y ninguna pantalla la usa | mia, si se quiere | -- | baja: era opcional. La cabecera sigue con la busqueda difusa, que ya ensena precio y nota. Se ve con `.\demo-entrega-final.ps1 -Parte facetas` |
| ~~28~~ | ~~El worker de descuentos borra los que nunca tuvieron clave en Redis~~ | -- | -- | **CERRADO el 2026-09-26** por David (37ad2e6): el vencimiento vive en PostgreSQL, migracion 028. Probado con `pruebas/descuentos.sh` 98 OK y la demo de descuentos |

---

# 17. Lo que se toco despues de la corrida del 2026-09-11 -- CERRADO el 2026-09-12

Las once cosas que se arreglaron con Docker caido se midieron al dia siguiente
contra las bases, y los dos arreglos de `arrancar.ps1` se rompieron a proposito
para ver que cortan. `alertas_login.sh` dio 52 OK dos veces seguidas y
`ofertas_paginadas.sh` 26 OK con 3 SIN MEDIR. Los numeros estan en
`docs/TRASPASO.md`, "Lo que se toco DESPUES de esa corrida".

Queda una cosa que no depende del codigo: para que la parte 2 de
`ofertas_paginadas.sh` mida de verdad hacen falta al menos 2 ofertas
pendientes, y hoy hay 1. Se consigue publicando otra con un vendedor normal,
porque desde la 010 esas nacen pendientes.

---

# 14. Elasticsearch se llena y ninguna ruta lo consulta

**Medido el 2026-09-11 leyendo el backend.** El worker copia cada evento de
`eventos_autenticacion` al indice `mesh_eventos_autenticacion`, y ahi se queda.
Los unicos `search` y `count` de Elasticsearch en `backend/src` son sobre
`mesh_productos`. Agregaciones, cero.

Lo que pidio el profesor es investigar el fraude en Elasticsearch, y eso son
rutas de agregacion. Los tres contadores de Redis no lo son: detectan en el
momento y olvidan a los 60 o 300 segundos.

**El indice ya contesta la pregunta, y esta demostrado.** La parte 6 de
`pruebas/alertas_login.sh` hace una agregacion `terms` por `ip` con una
`cardinality` de `identificador_intentado.minusculas` adentro, y encuentra la IP
que probo muchas cuentas. Lo que falta es que eso sea una ruta. El detalle, con
la consulta, esta en `docs/BACKEND-PENDIENTE.md`.

---

# 15. El fraude del login: las senales que faltan y los bordes de las que hay

Todo es de `backend/` y esta escrito para Jose David en
`docs/BACKEND-PENDIENTE.md`. Aqui va el resumen y por que importa.

**Faltan senales.** Muchas cuentas CREADAS desde una IP (el registro ya se
guarda con su ip, asi que el dato esta), inicios a intervalos fijos, y salto de
ubicacion. El tercero pide geolocalizar la IP, y la salida recomendada es el
procesador `geoip` de Elasticsearch en un pipeline por defecto del indice, que
no toca el backend. En local no va a dar ubicacion: `127.0.0.1` no tiene.

**`multi_cuenta_ip` cuenta textos tecleados, no ataques.** Suma tambien las
entradas buenas, y en local todo sale de `127.0.0.1`. Cuatro cuentas distintas
en cinco minutos desde el mismo equipo ya dan una alerta. En la corrida del
2026-09-11 no salto porque ninguna ventana fija de 300 s junto cuatro, no
porque no pueda pasar.

**Y hay bordes en el servicio.** El identificador no se normaliza (las
mayusculas parten una cuenta en dos), no tiene tope de largo (uno de mas de 255
hace fallar el `INSERT` y la alerta se pierde), `INCR` y `EXPIRE` van en dos
comandos, y falta el `PATCH` para marcar una alerta revisada o descartada.

---

# 16. La copia de logueos a ClickHouse esta congelada

Desde el 2026-09-10 el backend escribe los logueos en `eventos_autenticacion`
de MongoDB y no en `log_login`. Pero `etl/extraer_eventos.sql` y
`etl/cargar_eventos.sh` siguen leyendo `log_login`, asi que ClickHouse no recibe
un logueo nuevo desde entonces. **El 2026-09-11 habia 24 logins en Mongo que
ClickHouse no ve.** `pruebas/eventos.sh` lo imprime al empezar, con esos
numeros.

`pruebas/eventos.sh` sigue en verde, y es correcto: lo que mide es que la copia
funciona, y la copia funciona con lo que le den. Lo unico que le llega ya es lo
que siembra el propio arnes.

Hay dos salidas y hay que decidirlas con el profesor, porque cambian lo que se
entrega:

1. **Repuntar la copia a MongoDB.** Es trabajo de `etl/`, o sea mio, y no es
   cambiar un nombre de tabla: la marca de agua de hoy es el mayor
   `id_log_login` copiado, y los eventos de Mongo no traen ese id. Hay que
   pensar la marca de nuevo antes de escribir nada.
2. **Que ClickHouse deje los logueos** y se quede con las vistas de producto
   para tendencias. El fraude por IP pasaria entero a Elasticsearch (punto 14),
   y la ruta `GET /admin/eventos/fraude/ip`, que se penso y no se escribio, ya no
   hace falta.

Mientras no se decida, cualquier lectura de logins en ClickHouse veria logueos
que se quedaron en el 2026-09-10.

---

# 13. La respuesta de ofertas viene entera, sin paginar

## AL DIA 2026-09-11: la ruta paginada existe, y la pantalla no la puede usar todavia

Jose David publico `GET /vendedor/ofertas/paginado` y
`GET /vendedor/ofertas/pendientes/paginado` (commit `e38e9a3`). Las dos se miden
con `bash pruebas/ofertas_paginadas.sh`, que las recorre enteras y las compara
oferta por oferta contra las rutas viejas: 29 OK el 2026-09-11.

Lo que pesa, medido ese dia:

```
tienda@mesh.com        /vendedor/ofertas                         1243494 bytes
                       /vendedor/ofertas/paginado?limite=20        11455 bytes
ventas.norte@mesh.com  /vendedor/ofertas             976 ofertas  612062 bytes
                       /vendedor/ofertas/paginado?limite=20        12409 bytes
tienda@mesh.com        /vendedor/ofertas/pendientes      1 oferta    362 bytes
                       /vendedor/ofertas/pendientes/paginado       433 bytes
```

**La lista del vendedor NO se migro a la paginada, y es a proposito.** La ruta
nueva solo filtra por `activo=true|false`. El panel tiene una pestana por cada
uno de los cinco estados, con su numero, y un buscador por nombre, y las dos
cosas filtran en memoria sobre la lista entera. Pasar a paginas sin esos
filtros en el servidor romperia el buscador (solo buscaria en la pagina de 20
que se ve) y dejaria las pestanas sin sus numeros.

Lo que se le pide a la ruta, y esta escrito en `docs/BACKEND-PENDIENTE.md`: un
filtro por los cinco estados, uno por nombre, y los conteos por estado en la
misma respuesta. Con eso la pantalla se migra.

**La cola de pendientes tampoco se migro**, por otra razon: tiene una oferta, y
la version paginada pesa mas que la entera. Tiene sentido el dia que la cola
crezca.

Lo de abajo es como estaba el 2026-09-06, y el numero sigue valiendo.

Medido el 2026-09-06 con la sesion de `admin@mesh.com`:

```
GET /vendedor/ofertas    200    1243494 bytes    1.36 s    2243 ofertas
```

Pasa porque `resolverIdEfectivo()` cambia el id de un admin por el de la tienda, y
`tienda@mesh.com` oferta TODO el catalogo. Las demas rutas del panel se portan
bien, y estan medidas al lado para que se vea la diferencia:

```
/admin/reportes/ventas           948 bytes    0.36 s
/admin/reportes/reservaciones    179 bytes    0.22 s
/admin/grafo/conciliacion        875 bytes    0.77 s
/admin/fraude/anillos           3915 bytes    8.40 s   <-- lento, pero pequeno
```

**Hoy no rompe nada** y por eso no es alta. Se abre la seccion, tarda un momento y
funciona. Lo que la pone en esta lista es que el catalogo va a crecer: la prueba
del buscador con un millon de productos que se quiere para la Entrega 3 llevaria
esta misma ruta a cientos de megabytes.

Son dos mitades. La ruta tiene que aceptar paginacion, que es de `backend/`, y la
pantalla tiene que pedirla por paginas, que es mia. El catalogo de `/` ya lo hace
de las dos formas, por cursor y por numero de pagina, asi que el patron ya existe
en la casa y no hay que inventarlo.

**Y de paso, los 8.4 s de `/admin/fraude/anillos`** merecen una mirada. Son cinco
consultas de varios saltos contra Neo4j y el panel las espera todas, asi que esa
pantalla tarda ocho segundos en pintar aunque devuelva menos de 4 KB.

**Los dos cierres de arriba llevaban dos dias hechos y esta tabla seguia
dandolos por abiertos.** Salio releyendo el codigo el 2026-09-06, no porque
alguien se acordara. Comprobado antes de tacharlos: el `@Interval`
`revisarVencidas()` hace `UPDATE oferta SET es_inventario_limitado = false`, y
`ofertas.service.ts` lanza `ErrorConflicto`. Una lista de pendientes que se
queda vieja es peor que no tenerla, porque manda a trabajar en algo que ya esta
hecho.

---

# 10. Los filtros facetados del buscador -- ABIERTO, y es de la Entrega 3

El enunciado lo pide DOS veces, y con estas palabras:

> Filtros facetados sobre los resultados de busqueda, calculados mediante las
> capacidades de agregacion del motor de busqueda.

> Al menos una agregacion empleada para los filtros facetados.

**Hoy no existe.** Medido el 2026-09-06 con un `grep` de `aggs` y de
`aggregation` sobre el repo entero, `backend/` incluido: **cero resultados**. La
consulta del buscador es un `multi_match` dentro de un `bool` y devuelve solo
`hits`.

Desde el 2026-09-11 hay UNA en el repo, en `pruebas/alertas_login.sh`, y no
cambia nada de este punto: va contra el indice de eventos de login, no contra
el catalogo, y es un arnes, no una ruta. En `backend/` siguen siendo cero.

Lo bueno es que el terreno ya esta puesto y no hay que reindexar nada.
`elastic/001_indice.json` mapea `categoria_nombre.exacto` y `categoria_padre`
como `keyword` y `precio_desde` como `double`, que es exactamente lo que una
faceta necesita. Eso se hizo bien el dia que se escribio el mapeo.

Falta la agregacion en la consulta, que es de `backend/`, y la columna de
filtros con su numero al lado, que es mia.

---

# 12. El checkout no compra con MongoDB caido

Lo encontro la prueba de falla del 2026-09-06 y lo confirmo Jose David el
2026-09-07 con su propia prueba: las dos rutas de compra LEEN Mongo antes del
`COMMIT` (el nombre del producto y el estado de la variante), y si Mongo no
contesta, la compra no sale. No se cobra nada ni queda nada a medias; es una
dependencia de disponibilidad, no de consistencia.

Lo que ya se hizo: Jose David bajo el timeout del driver de Mongo a 3 s, y la
compra falla con 503 en unos 5 s en vez de 32. Y desde el 2026-09-11 es la fila
11 de `docs/CONSISTENCIA-CHECKOUT.md`, que era lo que su documento pedia.

Lo que falta es elegir entre las tres salidas que el propone (aceptarlo y
documentarlo, copiar el estado de la variante a PostgreSQL, o degradar y seguir
sin Mongo), y eso se decide con el profesor. Estan en
`backend/elementos Generales/prueba-falla-mongo-checkout.md`.

---

# 11. La prueba de falla simulada del checkout -- CERRADO el 2026-09-06

El texto de abajo es el de antes de cerrarlo. Se deja porque dice por que hacia
falta; la prueba y su evidencia estan en `docs/CONSISTENCIA-CHECKOUT.md`,
seccion 4 bis.

El enunciado lo pide asi:

> Evidencia de al menos una prueba de falla simulada sobre el flujo de checkout
> y el comportamiento resultante del sistema.

`docs/CONSISTENCIA-CHECKOUT.md` enumera diez puntos de falla, pero **ninguno
esta provocado ni medido**. Su seccion 5 lista cuatro arneses y ninguno de los
cuatro tumba nada: `carrito.sh` mide el camino feliz, y los de Redis miden
concurrencia y vencimiento, no caidas.

Medido el 2026-09-06: `grep` de `docker stop`, `docker pause` y `docker kill`
sobre `pruebas/`, `redis/`, `neo4j/` y `etl/` da **cero**.

Es de las pocas cosas de esta lista que no dependen de nadie mas.

---

# 5. Dos asignadores de id de producto que no se hablan

**Se encontro midiendo, no leyendo, y existe aunque nadie haga nada mas.**

`backend/src/services/vendedores/productos.service.ts` deja escrito que los
productos ya no se registran en PostgreSQL y que su id sale de "el maximo que ya
existe, mas uno". Ese maximo lo lee de **MongoDB**, en `siguienteIdProducto`.
Mientras tanto `productos.id_producto` de PostgreSQL sigue siendo un `bigserial`
con su propia cuenta.

Son dos numeradores independientes sobre el mismo espacio de ids, y **ya habian
divergido**: MongoDB tenia cuatro productos publicados desde el panel cuya fila
no existe en PostgreSQL, y la secuencia de PostgreSQL estaba a punto de entregar
justo esos numeros. El primer producto insertado en PostgreSQL se habria llevado
un id que en MongoDB ya era de otro producto, y el `replaceOne` del ETL lo
habria machacado **sin un solo error**.

Y no hay nada que avise: `etl/cargar.js` barre sobrantes en `categorias` y en
`productos_eventos`, pero **no tiene ningun barrido para `db.productos`**. El
verificador del arranque tampoco lo ve, porque solo se queja si Mongo tiene
MENOS documentos que PostgreSQL, y aqui tendria de mas.

**Lo que hay hoy es un parche, no un arreglo.** `migrations/lote/generar_lote.sql`
recibe los dos maximos de MongoDB, comprueba que sean creibles y alinea las dos
secuencias con `setval` antes de insertar. Eso resuelve el caso del generador y
deja los dos numeradores de acuerdo hacia adelante, pero **solo para ese
camino**. Cualquier otro `INSERT` en `productos` de PostgreSQL sigue expuesto.

La decision de fondo le toca a Jose David y esta escrita en
`docs/BACKEND-PENDIENTE.md`: si el id de producto debe salir de una sola fuente,
y cual.

## Y hay una TERCERA cuenta que nadie mira (medido el 2026-09-03)

Los dos generadores no se pisan entre si. Eso se comprobo y esta bien: los dos
arrancan por encima del maximo de LAS DOS bases, asi que corridos en cualquier
orden cada uno ve el rastro del otro.

Lo que no mira ninguno de los dos es **la secuencia**. Los tres sitios que
reparten leen `max(id_producto)`, que no es lo mismo que lo que el `bigserial`
va a entregar:

```
arrancar.ps1        SELECT coalesce(max(id_producto),0) FROM productos
generar_lote.sql    GREATEST(max(id_producto), max_mongo_producto)
generar_lote_mongo  Math.max(maxMongoProducto, MAX_PG_PRODUCTO) + 1
```

Medido en la base viva ese mismo dia:

```
                       last_value | max_real | hueco
 productos             |     1126 |     1105 |    21
 productos_variantes   |     2290 |     2246 |    44
```

Los 21 numeros del 1106 al 1126 ya los consumio la secuencia -- un `nextval` no
vuelve con el `ROLLBACK` -- y no tienen fila. Los dos generadores creen que "el
maximo de los dos mundos" es 1105 y empezarian en 1106.

**La consecuencia concreta:** `.\arrancar.ps1 -ProductosMongo 22` o mas crearia
documentos hasta el `_id` 1127, que es justo el numero que la secuencia entregara
al siguiente `INSERT INTO productos` que no pase por el lote. Con
`-ProductosMongo 300` la ventana expuesta serian 279 documentos.

Y hay una vuelta mas: `setval(GREATEST(1105, 1105))` **hace retroceder** la
secuencia de 1126 a 1105. Hoy no rompe nada porque esos 21 numeros estan vacios,
pero significa que la defensa contra los dos repartidores esta construida sobre
un numero distinto del que la base va a repartir.

El arreglo no es cambiar `max(id_producto)` por `last_value` en tres sitios --
eso solo mueve el parche -- sino la decision de fondo que ya esta planteada
arriba. Se deja escrito para que quien la tome sepa que son TRES cuentas y no
dos.

## Lo que SI se cerro, el 2026-09-04: el choque ya no es invisible

La decision sigue siendo de Jose David y este punto sigue abierto. Lo que se
arreglo es la frase de mas arriba que decia **"y no hay nada que avise"**, que
era lo peor del asunto: el arranque quedaba en verde, las cuentas cuadraban, y
lo que se perdia era un producto entero.

`arrancar.ps1` estrena un paso, **"Comprobando que los id de producto no se
pisan"**, que corre en cada arranque despues del ETL:

```
sin cruce: PostgreSQL reparte el 1127 y el mayor de Mongo es 1105 (22 de margen)
```

**Pregunta por la SECUENCIA y no por `max(id_producto)`**, que es lo unico que
hace util a este aviso. Los dos numeros no son el mismo: un `nextval` consumido
por una transaccion que despues hizo `ROLLBACK` no vuelve. El dia que se midio,
la secuencia iba en 1126 con un maximo real de 1105 -- 21 de diferencia --, asi
que preguntar por el maximo habria prometido 21 numeros de margen que no
existen.

Y fijate en el 22 de esa linea: es exactamente el numero que este documento
predijo mas arriba, cuando decia que `-ProductosMongo 22` o mas se meteria en el
1127. El aviso mide lo mismo que el pendiente describe.

**Cuando hay cruce lo dice y no se calla.** Probado bajando la secuencia a mano
a 1100 y volviendo a arrancar:

```
5 documento(s) de MongoDB ocupan un id que PostgreSQL va a repartir
  PostgreSQL entregara el 1101 en el proximo INSERT INTO productos
  y en MongoDB ya hay documentos de ese numero para arriba.
  El ETL los machacaria sin dar ningun error. Ver docs/PENDIENTES.md, punto 5.
```

La secuencia se devolvio a 1126 al terminar la prueba.

**No corta el arranque, y es deliberado.** Un choque futuro no rompe nada de lo
que esta cargado hoy, y parar la maquina entera por algo que todavia no ha pasado
seria peor que el problema. Avisa, dice cuanto margen queda, y sigue.

---

# 6. La nota del catalogo no se refresca sola -- CERRADO el 2026-09-04

**El arreglo es el que estaba escrito aqui**: una etapa nueva del ETL que agrupa
`resena` por `id_producto_mongo`, sin pasar por la tabla `productos`.

## Que pasaba, y eran dos huecos

**Un producto que solo vive en MongoDB nunca actualizaba su nota.**
`etl/extraer.sql` itera sobre la tabla `productos` de PostgreSQL, asi que un
producto publicado desde el panel no pasa por ahi jamas y su nota se quedaba en
el 0 con que lo rellena `mongo/002_resenas.js`. No era teorico: esos productos
tienen ofertas, se pueden comprar y se pueden resenar hoy. En la base viva son
CUATRO, los `_id` 103, 104, 105 y 106.

**Y el caso simetrico, que aparecio midiendo y no estaba escrito.** Cuando se
borra la ultima resena de un producto, la fila desaparece de `resena` y el
documento se queda con la nota vieja. Medido el 2026-09-04, antes de tocar nada:

```
producto 1   Mongo dice resenas_total 1, promedio 4
             PostgreSQL tiene CERO filas en resena para ese producto
```

Ese 4 llevaba ahi desde que alguien borro esa resena. Mongo tenia 52 productos
con nota y PostgreSQL solo sostenia 51.

## Como quedo

Tres archivos, y ninguno toca `backend/`:

```
etl/extraer_notas.sql   agrupa resena por id_producto_mongo. SIN join contra
                        productos, que es justo lo que dejaba fuera a los de
                        Mongo. El redondeo es el mismo texto que el de
                        extraer.sql, a proposito
etl/cargar_notas.js     escribe los dos campos, y APAGA los que dicen tener
                        resenas y ya no salen en la lista. Es el unico que
                        puede cerrar el segundo hueco, porque es el unico que
                        sabe cuales NO vinieron
etl/correr.sh           la engancha como TERCERA etapa, despues de cargar.js
```

**Va despues de `cargar.js` y no antes.** `cargar.js` hace `replaceOne` con el
documento entero, asi que al reves le pasaria por encima a todo. Se dice en la
cabecera de los dos archivos para que nadie lo reordene.

**Y estrena `--notas`**, que corre solo esa etapa, igual que `--cola` en el del
grafo:

```
bash etl/correr.sh            las tres etapas    13 s
bash etl/correr.sh --notas    solo la nota        4 s
```

## Como se comprueba, y el arnes se rompio a proposito

`bash pruebas/notas.sh` -- **10 OK, 0 FALLA**. Son cuatro partes y la primera es
la que sostiene a las otras tres: comprueba corriendo `extraer.sql` de verdad que
el producto elegido NO sale en su resultado. Sin eso, el arnes podria estar
aprobando algo que ya funcionaba antes del cambio.

Medido de punta a punta sobre el producto 103, que vive solo en Mongo:

```
resena sembrada (5 estrellas)  ->  el documento sigue en 0|0
correr --notas                 ->  el documento dice 1|5
resena borrada                 ->  correr --notas  ->  vuelve a 0|0
```

Y se rompio el apagado a proposito para ver si el arnes se daba cuenta: con el
`$gt: 0` del `updateMany` cambiado por un `$gt: 999999`, el arnes pasa de **10
OK** a **7 OK y 3 FALLA**, y lo detecta en tres sitios distintos. Al restaurarlo
la corrida siguiente dijo `apagados 1`, que es la etapa arreglando de verdad el
documento que la version rota habia dejado sucio.

## Lo que sigue faltando, y ya no es de este punto

La nota **sigue sin refrescarse sola**. Una resena nueva no la mueve hasta que
alguien corre el ETL, y eso es el pendiente 4 aplicado a otro dato: hoy el grafo
tiene su cola (`evento_grafo`) y su worker, y la nota de Mongo no. Mientras
tanto la ficha del producto y la lista del catalogo pueden ensenar dos numeros
distintos, y eso **es correcto y esta decidido**: la ficha calcula en vivo contra
PostgreSQL y la lista lee la copia de Mongo, que es la que se usa para FILTRAR y
ORDENAR. Esta escrito en `etl/extraer.sql`.

Lo barato, si alguien lo quiere cerrar, es que `--notas` corra tambien cuando el
worker del grafo vacia la cola: los dos se disparan por lo mismo, que es que se
toco una resena.

---

# 8. Editar el stock durante una venta relampago desincroniza las dos bases

**Medido el 2026-09-03 leyendo el codigo, y visto en la base el 2026-09-04.**

`activar()` siembra Redis con una FOTO del stock de ese instante. A partir de
ahi son dos contadores que se mueven por caminos distintos y nadie los vuelve a
comparar. `PATCH /vendedor/ofertas/:id` sigue aceptando `ajuste_stock` con la
venta abierta.

**Si el vendedor SUBE el stock**, las unidades nuevas quedan inertes: PostgreSQL
dice 17, Redis sigue en 4, y nadie puede comprar esas 10 por ningun camino
mientras la venta este abierta. Confuso, pero no rompe.

**Si BAJA el stock, si rompe, y del lado del comprador.** Redis ya le prometio
unidades a gente que tiene un ticket vivo. Al pagar, `comprar_pedido` hace esto
(`migrations/007_flujo_pedido.sql:481`):

```sql
IF v_oferta.stock < v_linea.cantidad THEN
    RAISE EXCEPTION 'No hay suficiente stock de "%" (%): quedan % y se pidieron %'
```

O sea: **Redis promete lo que PostgreSQL no puede entregar.** La persona aparto
sus unidades, espero, pago, y el cobro le revienta con un error que no explica
nada, porque desde su lado no cambio nada. Su reserva se queda colgada hasta el
TTL.

**Y no es teorico.** El 2026-09-04 la oferta 52615 aparecio con stock 15 y una
`reposicion` de +8 en el kardex hecha con la venta relampago abierta.

## Lo que se pide, y es chico

Un **409 en `PATCH /vendedor/ofertas/:id` solo cuando venga `ajuste_stock` y la
oferta este en venta relampago**, con un mensaje que diga que cierre la venta,
reponga y la vuelva a abrir. Tres lineas.

**Los otros dos campos NO hay que bloquearlos:**

- `precio` ya esta cubierto: al pagar, el backend compara la foto del carrito
  en Redis con el precio de hoy y avisa dentro de la misma peticion que cobra. Bloquearlo seria resolver dos veces lo
  mismo.
- `estado` no, porque un vendedor tiene que poder dejar de vender algo. Lo
  razonable es que **pausar cierre la venta relampago primero**, o que lo avise.

---

# 7. Una venta relampago que vence sola deja la columna marcada

**Encontrado el 2026-09-03 midiendo, y no estaba escrito en ningun sitio.**

`duracion_segundos` pone un `EXPIRE` sobre las dos claves de Redis de la oferta.
Cuando ese plazo se cumple, las claves desaparecen solas y
`oferta.es_inventario_limitado` **se queda en `true` para siempre**, porque Redis
no puede escribir en PostgreSQL y nadie mas la apaga.

Medido:

```
POST .../venta-limitada {"duracion_segundos":5}
   PG es_inventario_limitado = true    Redis TTL = 2
esperar
   claves de Redis = 0
   PG es_inventario_limitado = TRUE       <-- sigue marcada
   GET /vendedor/ofertas dice es_inventario_limitado = True
```

## Por que es baja y no alta

**Al comprador no le pasa nada.** `CarritoService` decide el camino con
`existeVentaLimitada()`, que es un `EXISTS` contra **Redis**, no contra la
columna. Sin claves, la oferta se compra por el flujo normal de PostgreSQL. La
columna no manda sobre nada del checkout.

**Y hay recuperacion, con un clic.** Pulsar "Cerrar la venta" sobre una oferta en
ese estado contesta 200 y la deja en `false`. Medido. No hace falta tocar la base
a mano.

Lo que queda mal es el panel del vendedor: ensena "Venta relampago abierta" y
ofrece "Cerrar la venta" sobre algo que ya no existe.

## Las dos salidas, y ninguna es del frontend

1. **Que la columna se deduzca de Redis** en vez de guardarse. Es la mas honesta
   -- la verdad sobre si hay una venta abierta ya vive en Redis -- y el precio es
   una llamada a Redis por cada oferta que se lista, o sea un `EXISTS` masivo en
   `GET /vendedor/ofertas`, que devuelve 976 filas para un vendedor normal.
2. **Que alguien la apague al vencer.** Redis publica eventos de expiracion de
   claves, pero esos avisos se pierden si nadie esta suscrito en ese momento, que
   es justo el argumento por el que `inventario_limitado.lua` NO los usa para
   cosechar reservas (ver `redis/README.md`). La alternativa seria un barrido
   periodico, que es otra pieza que mantener.

**No se decide aqui.** Es del backend, y hasta que se decida el estado es
alcanzable, invisible y recuperable con un clic.

---

Y de la **Entrega 2** falta trabajo que no es un bug:

| Que | Puntos | De quien |
|---|---|---|
| ~~Oferta de inventario limitado enchufada~~ | ~~3~~ | **CERRADA el 2026-09-03 por la noche.** Jose David escribio las dos rutas del paso 2 (`POST` y `DELETE /vendedor/ofertas/:id/venta-limitada`) y agrego `es_inventario_limitado` a los tres GET; el boton del panel del vendedor ya las llama, en las dos vistas. Medido en el navegador y contra las dos bases: ver `docs/TRASPASO.md`, "La venta relampago". Solo queda fuera de alcance la activacion automatica por calor |
| ~~`GET /admin/fraude/anillos`~~ | ~~parte de 3~~ | **HECHA el 2026-08-30, y el panel ya la consume** |
| Resenar desde el pedido (bloque 5 de BACKEND-PENDIENTE) | -- | Jose David |
| ~~**Comparativa grafos vs columnar**, con la defensa de la NO elegida~~ | ~~1.5~~ | **ESCRITA el 2026-09-03**: `docs/DECISION-GRAFOS-VS-COLUMNAR.md` |
| ~~**Diagrama de arquitectura** (el ER no lo es)~~ | ~~parte de 1~~ | **HECHO el 2026-09-03**: `docs/ARQUITECTURA.md` y `docs/diagrama-arquitectura.drawio` |

**Los 2.5 puntos que no dependian de nadie ya estan.** La comparativa sigue la
estructura de registro de decision que pide el enunciado (contexto, alternativas,
decision, justificacion, consecuencias) y cierra con las cinco condiciones
medibles bajo las cuales SI habria que incorporar la base columnar, que es la
parte que se olvida. Todos sus numeros salen de una corrida contra la base viva y
los comandos para repetirla estan en el propio documento.

Jose David agrego ademas **dos reportes de admin** que nadie habia pedido y que
suman: `GET /admin/reportes/ventas` y `GET /admin/reportes/reservaciones`. Su
pantalla es `frontend/src/lib/PanelReportes.svelte`, hecha el 2026-08-30.

---

# 1. El precio se congela al PAGAR, no al agregar

## AL DIA 2026-09-03: el dano ya esta cubierto, por un camino distinto

Lo que hacia grave a este pendiente era el SILENCIO: la pantalla ensenaba un
total, la persona decidia con ese numero, y si el vendedor lo movia antes del
clic se le cobraba otro sin que nada lo dijera. **Eso ya no pasa.**

Jose David no siguio el camino que esta seccion proponia -- guardar el
`id_precio_historial` en el carrito de Redis -- y eligio otro que resuelve el
mismo dano sin tocar la forma del carrito:

Primero fue `lineas_precio_visto`, una lista de `{ id_oferta, precio_visto }`
que mandaba el frontend. **Desde el 2026-09-23 (e7f1e02) ya no hace falta:** el
carrito de Redis guarda por linea una foto en JSON con el precio que se
enseno (ya con descuento), y el backend compara esa foto contra el de hoy
**dentro de la misma peticion que cobra**. El cliente no manda precios.
Si no cuadra, no cobra nada -- ni Redis, ni PostgreSQL, ni Mongo -- y contesta
`comprado: false` con la lista de `avisos`. Reenviar con
`confirmar_cambios: true` acepta el precio de hoy.

Que la comparacion pase dentro del mismo viaje es lo que la hace valer: entre
mirar y cobrar no queda ninguna ventana. Una comprobacion hecha desde el
frontend antes de llamar dejaba milisegundos abiertos.

**El frontend YA esta** (`Checkout.svelte` pinta los avisos y reenvia con
`confirmar_cambios:true`, con el texto distinto segun el modo porque en el carrito se cobra el de
hoy y en el pedido el congelado). Probado en el navegador: con el checkout
abierto en Q1,103.62 se sube el precio a Q2,500 y al pagar no cobra, avisa.

### Lo que sigue faltando, y por que ya no es urgente

El precio **sigue sin congelarse**. Si la persona confirma, se le cobra el de
hoy, no el que vio. La migracion 013 deja hacerlo desde la base y lo comprueba
`redis/prueba_carrito.sh`, pero el carrito de Redis todavia no manda el
`id_precio_historial`.

La diferencia entre lo que hay y lo que falta es la diferencia entre **avisar**
y **respetar**: hoy se le dice a la persona que el precio cambio y se le deja
decidir; con la 013 conectada se le podria cobrar el que se le prometio.

Lo de abajo se deja escrito entero porque es el camino que cierra eso.

---

**Era lo mas urgente de esta lista porque era un cobro incorrecto**, no un
detalle de presentacion.

## Que pasa

`agregar_linea()` congela el precio al agregar al carrito. La migracion 007 lo
dice textual: *"si el vendedor lo sube despues, este pedido conserva el que se le
mostro a la persona"*.

Con el carrito en Redis, agregar y comprar pasan **en el mismo instante** --
`POST /carrito/comprar` llama a `comprar_carrito()`, que hace las tres cosas de
una. Asi que el precio que se congela es el del momento de PAGAR.

Si el vendedor lo sube mientras el carrito espera, **se le cobra el nuevo, sin
ningun error y sin que nadie se entere**. Y el carrito puede esperar 24 horas.

Peor: `GET /carrito` ya ensena un precio, la persona decide con ese numero, y
puede no ser el que se cobre. El endpoint del carrito lo reconoce por escrito
(*"cerrar la ventana de carrera entre ver y pagar es la fase 2"*).

## El arreglo, y son dos mitades

**La de Meme: HECHA el 2026-08-30, es `migrations/013_precio_del_carrito.sql`.**
`agregar_linea()` acepta un `id_precio_historial` DENTRO de `p_linea` y lo usa
en vez de buscar el vigente. La firma no cambio, asi que la 012 no se toco y el
campo viaja solo. Sin el campo se comporta igual que antes, para que la
migracion pudiera correr antes que el backend y para que la semilla siguiera
cargando.

Ademas exige que ese precio sea **de esa misma oferta**: sin ese filtro,
mandar el id de una fila de otra oferta seria elegir el precio a voluntad. Y no
bloquea la compra cuando el precio ya no es el vigente: **cobra el congelado y
lo dice**, con `precio_cambio`, `precio_congelado` y `precio_actual` en lo que
devuelve. La base informa; la politica la decide la aplicacion.

Medido en una transaccion con ROLLBACK: precio visto Q6,263, el vendedor lo
sube a Q31,315, se compran 3 unidades -> **cobra Q18,789** (3 x 6,263) en vez de
Q93,945. Con un precio de otra oferta o un id inventado, levanta excepcion.

**La de Jose David, que es lo que FALTA:** que el carrito de Redis guarde
tambien el `id_precio_historial` de cada linea -- desde el 2026-09-23 el hash ya
es `id_oferta -> JSON` con el precio, pero sin ese id -- que `POST /carrito/comprar`
lo mande, y que mire `precio_cambio` para armar los `avisos`. Un cambio de descuento
solo tambien saldria ahi: el trigger de la 020 escribe una fila nueva de
`precio_historial` cuando cambia el %, y `precio_cambio` compara ids de fila. Los tres pasos estan
escritos al final de la 013.

**Hasta que eso exista, el precio se sigue congelando al pagar.** La 013 lo
habilita, no lo termina.

## La trampa, que sigue SIN decidirse

Un `id_precio_historial` de hace 24 horas puede apuntar a un precio que ya no
rige, y la persona tiene derecho a ese precio... hasta cierto punto. Hay que
decidir **cuanto vale un precio congelado**: si es para siempre mientras el
carrito viva, o si pasadas N horas se recalcula avisando.

La 013 **no la decide a proposito**: cobra el congelado y marca `precio_cambio`.
Cuanto vale la palabra que se le dio a un cliente es una decision comercial y no
le toca a la base -- le toca a quien escriba el paso 3 del backend.

`POST /comprador/pedidos/:id/comprar` ya resuelve esto con `confirmar_cambios` y
una lista de `avisos`. **Lo mismo sirve aqui**: si el precio cambio, el checkout
lo dice y pide confirmar. No hay que inventar nada, hay que portarlo.

---

# 2. Las 86 resenas sembradas no tienen compra detras -- CERRADO el 2026-08-30

**Ya no aplica.** Se deja escrito porque el arreglo cambio numeros que otros
documentos citan, y porque el candado que lo cierra hay que saber que existe.

## Que pasaba

Jose David decidio, y lo dejo escrito en su servicio, que **solo se puede
calificar a un vendedor al que se le compro y se le pago** -- y al MISMO
vendedor, por la cadena `pedido_producto -> precio_historial -> oferta ->
oferta.id_usuario`. Es su decision y se queda: es la "compra verificada" de
Amazon y es defendible.

El problema no era la regla: era que **la semilla no la cumplia**. Solo 2 de las
86 resenas tenian una compra detras, asi que 84 describian algo que el propio
sistema habria rechazado al escribirlo, y el boton "Escribir una resena" no
aparecia casi en ningun producto.

## Como quedo, medido contra una base recien creada

```
  resenas ......................................... 86
  de esas, con compra pagada a ESE vendedor ....... 86   (antes 2)
  resenas fechadas antes de su compra .............  0
  pedidos sembrados ...............................  10  (antes 2)
  lineas de pedido ................................  97  (antes 3)
  pares comprados y AUN sin resenar ...............  11
```

**Esos numeros son de ese momento.** Ese mismo dia, mas tarde, se sembro el
anillo de fraude y subieron a **90 resenas, 13 pedidos y 101 lineas** (11
usuarios, 556 ofertas). Se dejan como se midieron: lo que la medicion demuestra
-- que las 86 pasaron de 2 a 86 respaldadas -- no cambia.

Los 11 sin resenar son a proposito: `pruebas/resenas.sh` busca un par comprado
y todavia sin calificar, y hace `exit 1` si no queda ninguno. Si cada compra
llevara su resena encima, **el arnes moriria antes de probar las 5 rutas** y su
mapa de "donde SI se puede resenar" saldria vacio. Hoy imprime 8 productos.

## Como se hizo, y las cuatro decisiones que no son obvias

Todo en `migrations/datos/generador.js`; no se toco ninguna migracion numerada.

1. **Se compra con `comprar_carrito()` de la 012**, no con `INSERT` a mano: ella
   congela el `id_precio_historial` y arma `nombre_vendedor` desde la base, dos
   cosas que a mano se copian mal y que `pedido_producto` no protege con ningun
   UNIQUE.
2. **Las fechas se corrigen despues de comprar.** `crear_pedido` usa `now()`, asi
   que la compra saldria HOY y la resena en abril -- resenada antes de comprada,
   sin que nada falle. Se hace `UPDATE` de `pedido.fecha_creacion`,
   `pago.fecha_cancelacion` y `stock_movimiento.fecha_movimiento`; se comprobo
   que no hay ningun trigger sobre esas tres tablas.
3. **Los pedidos se agrupan por el mes de la OFERTA, no por el de la resena.**
   Agrupando por la resena, la oferta mas nueva del grupo queda posterior a la
   resena mas vieja y el pedido no se puede fechar sin quedar antes de que la
   oferta existiera.
4. **El sorteo nuevo va DESPUES de la linea 1718 del generador**, que es la
   ultima extraccion de la secuencia global `azar()`. Uno metido antes reescribe
   las 552 ofertas enteras. Comprobado con un `diff`: todo lo anterior a la parte
   social quedo bit a bit igual.

## El candado, que es lo que impide que vuelva

Dos comprobaciones nuevas en el `DO` final de `001_catalogo.sql`, la **10** y la
**11**: que toda resena tenga una compra pagada a ese vendedor, y que ninguna
este fechada antes de su compra. Fallan la migracion entera.

**Los JOIN de la 10 son calcados de `exigirCompraPagada` del backend**, con su
`estado_pedido_nombre <> 'cancelado'` incluido. El SQL que este mismo documento
proponia antes **no miraba el vendedor ni el cancelado**: habria aprobado una
resena de Ana a Carlos por algo que Ana le compro a Lucia. Un candado que valida
algo distinto de lo que el sistema exige es peor que no tenerlo.

## Lo que cambio de numeros, y donde estaba escrito

`115 comentarios / 46 votos / 29 respuestas` pasaron a **118 / 62 / 28**: los
pares elegidos cambian (ahora se filtran por stock y por precio quieto) y
`azarSocial` reparte distinto. Se actualizaron `docs/base-de-datos.md`,
`docs/BACKEND-PENDIENTE.md`, `migrations/README.md`, `neo4j/README.md`,
`etl/README.md` y `etl/extraer_grafo.sql`.

**Este parrafo decia 114 y estaba mal**, corregido el 2026-09-03. El 114 era
correcto el dia que se escribio (86 resenas + 28 respuestas) y caduco esa misma
tarde, cuando el anillo de fraude subio las resenas a 90 sin que nadie volviera
aqui. Contado contra la base: 118 comentarios, de los cuales 90 son la raiz de
una resena y 28 son respuestas. `migrations/README.md` y
`docs/BACKEND-PENDIENTE.md` ya decian 118.

## Y una afirmacion que hay que dejar de repetir

Este documento decia que **"el anillo de fraude tiene que comprarse entre si
antes de calificarse"**. No es cierto para el anillo que existe: se siembra en
**Neo4j**, con cuentas de id negativo y etiqueta `:Prueba`, y no pasa por
`POST /resenas` ni toca PostgreSQL. Solo aplicaria si algun dia se sembrara en
la fuente de verdad, que `neo4j/README.md` ya descarto por escrito.

---

# 3. `Carrito.svelte` quedo muerto -- CERRADO el 2026-08-30

Borrado. 937 lineas que ya no importaba nadie: el panel lateral es
`CarritoRedis.svelte` desde la mudanza a Redis. Se comprobo primero que ningun
archivo lo importara.

## Y la lista que traia este pendiente estaba MAL

Decia que con el se podian borrar ocho funciones de `pedido.ts`
(`leerPedidoAbierto`, `guardarPedidoAbierto`, `olvidarPedidoAbierto`,
`crearPedido`, `agregarLinea`, `restarLinea`, `quitarLinea`,
`cambiarDireccionPedido`). **Siete de esas ocho siguen vivas**, medido buscando
cada nombre por todo el frontend:

| Funcion | Quien la usa todavia |
|---|---|
| `leerPedidoAbierto` | `Pedido.svelte`, `producto/[id]` |
| `guardarPedidoAbierto` | `Pedido.svelte`, `producto/[id]` |
| `olvidarPedidoAbierto` | `Pedido.svelte`, `sesion.ts`, `+layout.svelte`, `producto/[id]` |
| `crearPedido` | `Pedido.svelte`, `producto/[id]` |
| `agregarLinea` | `Pedido.svelte`, `producto/[id]` |
| `quitarLinea` | `Pedido.svelte` |
| `cambiarDireccionPedido` | `Checkout.svelte` |

Borrar las ocho habria roto cinco archivos. Lo que si estaba muerto son **tres**,
y dos ni figuraban en la lista: `restarLinea` (con su interfaz `LineaRestada`),
`leerDesmarcadas` y `guardarDesmarcadas`. Esas tres se fueron.

`LLAVE_MARCADAS` se queda: ya nadie la escribe, pero `olvidarPedidoAbierto` la
sigue BORRANDO a proposito, porque en los navegadores que usaron el carrito
viejo quedo escrita y solo se va por ahi.

**La leccion, que es la de siempre en este proyecto:** una lista de codigo
muerto escrita a mano caduca sin avisar. Antes de borrar, se mide -- un `grep`
por nombre cuesta un minuto y aqui evito romper cinco archivos.

---

# 4. El grafo se queda viejo y el ETL relee todo

## AL DIA 2026-09-03, noche: la mitad de abajo ya esta

El diseno largo sigue en **`docs/PENDIENTE-OUTBOX.md`**, pero **la cola ya
existe** y el ETL ya la usa. Y el pendiente cambio de dueno: Jose David escribio
`backend/elementos Generales/plan pendiente/outbox-grafo.md` y su equipo se queda
con el worker, la conciliacion y el aviso de "ultima sincronizacion".

**Lo que YA esta hecho, y es mio:**

| Pieza | Donde | Estado |
|---|---|---|
| La tabla `evento_grafo` y su trigger sobre `resena` | `migrations/015_outbox_grafo.sql` | HECHO |
| Vaciar la cola al cargar el grafo | `etl/cargar_grafo.sh`, paso 3b | HECHO |
| Modo incremental del ETL | `bash etl/cargar_grafo.sh --cola` | HECHO |
| Quitar del grafo las resenas borradas | `etl/extraer_grafo.sql`, seccion 6 | HECHO |

Medido de punta a punta contra las dos bases:

```
resena creada    -> 1 evento pendiente, y el grafo sigue en 90
--cola           -> el nodo :Resena 111 aparece con sus 3 relaciones
                    1 evento marcado como proyectado
resena borrada   -> 1 evento pendiente, y el grafo sigue en 91
--cola           -> el nodo desaparece; el grafo vuelve a 90
```

Y el evento respeta la transaccion, que es el punto entero del outbox: dentro de
un `BEGIN`, crear una resena deja 1 pendiente y borrarla deja 2; tras el
`ROLLBACK` quedan **0**.

**Ojo con lo que el modo `--cola` NO ahorra**, porque es facil venderlo mal. Se
midio, y no baja el tiempo:

```
              extraccion   Cypher generado   script entero
completo         1.9 s        22 055 bytes       21.8 s
--cola           1.3 s         4 958 bytes       22.6 s
```

Lo que baja es el TRABAJO (el Cypher pasa de 22 KB a 5 KB), no el reloj: los 22
segundos son casi todos arranques de la JVM de `cypher-shell`, que el script
invoca cuatro veces y son los mismos en los dos modos. A 90 resenas el volumen
no es el cuello. El modo incremental paga el dia que lo sea, y hoy sirve sobre
todo porque es el unico que sabe aplicar las BAJAS.

**Y una cifra que hay que corregir:** aqui decia "14 s medidos". Hoy, con 90
resenas, el script completo tarda **21.8 s**.

## Y el resto se cerro esa misma noche

Jose David escribio **el worker** (`GrafoSyncService.vaciarCola()`, un
`@Interval` cada 10 s) y **la conciliacion**
(`GET /admin/grafo/conciliacion`), y yo puse el aviso en el panel de fraude.

Medido de punta a punta, sin que nadie corriera nada a mano:

```
resena creada en PostgreSQL
  -> el trigger la encola
  -> ~10 s despues el log dice "worker del grafo: 3 evento(s) aplicados"
  -> el nodo :Resena 114 esta en Neo4j con sus 3 relaciones
resena borrada
  -> el worker hace DETACH DELETE y el nodo desaparece
```

Y la conciliacion detecta una deriva sembrada a mano. Borrando UN nodo
`:Resena` del grafo:

```
cuadra: false
sugerencia: "Al grafo le faltan datos: 1 en resenas, 1 en relacion ESCRIBIO,
             1 en relacion CALIFICA_A, 1 en relacion SOBRE.
             Corre `etl/cargar_grafo.sh --limpiar` ..."
```

**El panel de fraude ya no calla.** `PanelFraude.svelte` pide la conciliacion
despues de pintar los anillos y ensena una linea debajo de la introduccion:
gris cuando cuadra ("Grafo al dia con PostgreSQL, sincronizado hace 9
minutos") y **roja cuando no** ("Este analisis puede estar incompleto"), con
la sugerencia del backend. Los eventos apartados se dicen siempre, cuadre o
no: un evento que fallo cinco veces no se reintenta solo y es lo unico de este
mecanismo que necesita a una persona.

Va en una peticion aparte y **sin `await`**: es informacion SOBRE el analisis,
no parte de el. Si esa ruta falla, el panel ensena sus anillos igual y no
pinta nada, porque "no se pudo comprobar si esta al dia" al lado de un
analisis correcto asusta mas de lo que informa.

**Lo mas barato de ese documento es la conciliacion** -- cuatro `count` que
comparan PostgreSQL contra Neo4j y avisan. Se puede hacer hoy y ya seria util.

**Y paga dos veces:** el outbox es la respuesta al documento de estrategia de
consistencia de la Entrega 3, que son 5 puntos de puro texto.
