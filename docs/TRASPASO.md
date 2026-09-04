# TRASPASO -- Mesh (Bases de Datos 2)

**Para quien retome el proyecto: leete esto entero antes de tocar nada.**
Son cinco minutos y te ahorra el dia.

Ultima actualizacion: **2026-09-04**.

---

## Pegale esto a la IA que vaya a trabajar

> Proyecto Mesh, de Bases de Datos 2 (Universidad del Istmo). El repo esta en
> `C:\Users\memit\OneDrive - Universidad del Istmo\BASE DE DATOS 2\Proyecto-Tienda-Base-Datos-2`.
>
> **Antes de proponer nada, lee en este orden:**
> 1. `docs/TRASPASO.md` -- que esta hecho y como se levanta (empieza aqui)
> 2. `docs/PENDIENTES.md` -- lo que falta, con su urgencia
> 3. `docs/BACKEND-PENDIENTE.md` -- lo que le toca a Jose David
> 4. `docs/base-de-datos.md` -- por que el modelo es como es
> 5. `migrations/README.md` -- las reglas de las migraciones
>
> **REGLAS QUE NO SE ROMPEN:**
> - Yo (Meme) hago `frontend/`, `migrations/`, `etl/`, `mongo/`, `neo4j/`,
>   `redis/`, `pruebas/`, `docs/` y `arrancar.ps1`. Jose David hace `backend/`.
>   **NUNCA toques `backend/`, ni un comentario.** Leelo: es la fuente de verdad.
> - Todo en `main`, sin ramas. No commitees ni pushees si yo no lo pido.
> - **NUNCA firmes un commit con `Co-Authored-By: Claude` ni menciones IA.**
>   Mensajes de una linea, planos.
> - `migrations/README.md` manda: una migracion ya corrida no se edita (se hace
>   la siguiente), ningun id se escribe a mano (todo por nombre o correo), y el
>   SQL va en ASCII puro.
> - Ninguna contrasena real en un archivo que se suba. Salen del `.env`.
>
> **Antes de decir que algo funciona, MIDELO.** Este proyecto tiene SIETE arneses:
> `bash pruebas/resenas.sh`, `bash pruebas/carrito.sh`, `bash pruebas/notas.sh`,
> `bash redis/prueba_carrito.sh`, `bash redis/prueba_concurrencia.sh`,
> `bash neo4j/correr_fraude.sh`, `.\mongo\demostracion_indices.ps1`.
>
> Y `prueba_concurrencia.sh` mide TIEMPOS con 50 clientes a la vez: en una
> maquina ahogada de memoria da rojo sin que nada este roto. Si sale mal,
> correlo solo antes de creerle.
> Y antes de creerle a un arnes, **rompe el codigo a proposito y comprueba que
> falla**: aqui ya aparecio un arnes que validaba copias pegadas de las
> consultas en vez de las consultas de la entrega.

---

## Que es esto

Tienda multi-vendedor con arquitectura poliglota. **Cuatro entregas
acumulativas: 5 + 10 + 15 + 20 pts.** Equipo de tres: Meme (frontend, datos,
migraciones), Jose David (`backend/`) y zapatoazul.

**El modelo, en una linea:** un producto describe una cosa del mundo y **no es
de nadie**; quien lo vende, a que precio y con cuanto stock es una fila de
`oferta`. `tienda@mesh.com` oferta todo y su precio es el que se ensena.

---

## Como se levanta

```powershell
.\arrancar.ps1              # los 7 contenedores, migraciones, semilla y ETL
.\arrancar.ps1 -Reiniciar   # desde cero (borra los volumenes)
```

Despues, en dos terminales:

```
cd backend  ; npm run start:dev     # :3000
cd frontend ; npm run dev           # :5173
```

**Si `arrancar.ps1` se queja de variables que faltan**, tu `.env` es tuyo y no
viene en el pull: copia de `.env.example` las que falten. Y ojo, **son DOS
`.env`**: el de la raiz (contenedores) y `backend/.env` (la aplicacion).

### Puertos

| | Puerto | |
|---|---|---|
| PostgreSQL | 5432 | pgAdmin en **5050** |
| MongoDB | **27018** | dbgate en **3001** |
| Redis | 6379 | RedisInsight en **5540** |
| Neo4j | 7687 (bolt) | Browser en **7474** |
| backend / frontend | 3000 / 5173 | |

Mongo es 27018 por fuera a proposito: Windows puede tener un MongoDB de servicio
ocupando el 27017, y ese contestaria primero con una base vacia.

---

## Que esta HECHO y probado

### Entrega 1 -- cerrada

Las **42 tablas** del diagrama (43 desde la migracion 015, que agrega
`evento_grafo` y NO esta en el ER porque no es del modelo de negocio: es la cola
de sincronizacion con Neo4j), el catalogo en MongoDB con su ETL, el historial
por eventos, los indices y las agregaciones. El informe lo hizo el equipo.

### Entrega 2 -- lo construido

| Pieza | Estado | Como se comprueba |
|---|---|---|
| **Carrito sobre Redis** | funcionando de punta a punta | `bash pruebas/carrito.sh` (25 OK) |
| **Resenas, comentarios y likes** | 7 rutas, pantalla completa | `bash pruebas/resenas.sh` (15 OK) |
| **Inventario limitado (Lua)** | **enchufado de punta a punta** | `bash redis/prueba_concurrencia.sh` |
| **Venta relampago, el interruptor** | boton en el panel del vendedor | entra como `ventas.norte@` a `/panel` |
| **Grafo de fraude (Neo4j)** | ETL + 5 consultas | `bash neo4j/correr_fraude.sh` |
| **Panel de fraude, de punta a punta** | `GET /admin/fraude/anillos` + `PanelFraude.svelte` | entra como `admin@mesh.com` a `/panel` |
| **Reportes de admin** | ventas y reservaciones + `PanelReportes.svelte` | lo mismo |
| **Los indices de Mongo, demostrados** | 4 pasos, 12 comprobaciones | `.\mongo\demostracion_indices.ps1` |
| **El pedido reconstruido, completo** | modal con lo pagado + precio y stock de ese dia | entra como `compradora.norte@` a `/pedidos` |
| **La nota en el catalogo de Mongo** | `resenas_promedio` y `resenas_total` en cada documento, con su indice | `.\arrancar.ps1 -Etl` y mirar un producto en Mongo |
| **La nota alcanza a los de Mongo, y se apaga** | tercera etapa del ETL, con `--notas` | `bash pruebas/notas.sh` (10 OK) |
| **Resenar desde el pedido** | boton en `/pedidos`, lleva a la ficha con el formulario abierto | entra como `compradora.norte@` a `/pedidos` y abre un pedido pagado |
| **El choque de los dos repartidores de id, visible** | un paso mas en el arranque | sale solo en `.\arrancar.ps1` |
| **Generador incremental de productos** | lotes reproducibles por semilla | `.\arrancar.ps1 -Productos 300 -Semilla 7` |

### La venta relampago, ya completa de punta a punta

Cerrada el **2026-09-03 por la noche**, y son tres piezas de tres personas
distintas que por fin encajan:

```
migrations/014_inventario_limitado.sql   la columna oferta.es_inventario_limitado
redis/inventario_limitado.lua            sembrar / reservar / redimensionar /
                                         confirmar / devolver, todo atomico
backend  POST|DELETE /vendedor/ofertas/:id/venta-limitada   el interruptor
frontend OfertasVendedor.svelte          el boton que lo pulsa
```

Hasta esa noche faltaba el interruptor, y sin el las otras tres no servian de
nada: el mecanismo entero estaba escrito y probado y **no habia forma de
encenderlo desde la aplicacion**. Jose David escribio las dos rutas (su
propuesta esta en `backend/cambio_propuestas/2026-09-03_2300-venta-relampago-rutas-vendedor.md`)
y de paso agrego `es_inventario_limitado` a los tres GET de ofertas, que es el
campo sin el cual el panel no podria saber si pintar "Abrir" o "Cerrar".

**Como se ve:** entra como `ventas.norte@mesh.com` a `/panel`. Cada oferta
activa tiene un boton naranja "Abrir venta relampago". Al pulsarlo se despliega
un panel con el numero de unidades que se van a apartar y un campo de duracion;
al abrirla, la fila se marca con la pastilla "Venta relampago abierta" y el
boton pasa a "Cerrar la venta".

**Medido en el navegador, y comprobado contra las dos bases:**

```
antes                PG es_inventario_limitado = false   Redis EXISTS = 0
abrir con 3600 s     PG = true   Redis stock 8, reservado 0, TTL 3578
                     la fila se marca y el boton cambia solo
cerrar               PG = false  Redis sin ninguna clave  stock intacto en 8
```

Tres cosas de esta pantalla que no son obvias y que costaron:

**1. Cerrar descarta las reservas en curso.** El `DELETE` borra las dos claves
de Redis de la oferta. Las unidades no se pierden (vuelven al stock de
PostgreSQL), pero quien tuviera unidades apartadas se queda sin ellas, y cerrar
**no confirma** ninguna compra. Por eso el boton no cierra directo: pide un clic
mas y lo dice antes, en el propio panel.

**2. El plazo de la venta y el plazo del comprador son cosas distintas.**
`duracion_segundos` es cuando cierra la venta ENTERA (0 es sin vencimiento, tope
7 dias). Lo que cada persona tiene apartado antes de pagar son 15 minutos y es
fijo. Se confunden solos, y confundirlos sale caro: quien quiere "quince
minutos" escribe 900 pensando en lo segundo y cierra su propia venta en quince
minutos. El panel lo dice con todas sus letras debajo del campo.

**3. Abrir con stock 0 es una bomba de tiempo, y el backend NO lo impide.**
`sembrar` acepta un stock de cero y contesta 201. Lo que se siembra es una FOTO
del stock en ese instante y ya no se vuelve a mirar PostgreSQL, asi que si
despues se reponen existencias con Editar, PostgreSQL sube y Redis se queda en
cero: la oferta pasa a ser incomprable **sin ningun error, sin ninguna marca y
sin nada que lo explique**. Salio pulsando el boton sobre una oferta agotada de
la tienda. El panel lo corta antes de llamar.

**4. Una venta que vence sola deja la columna marcada para siempre.** Es un
hallazgo del 2026-09-03 y no estaba escrito en ningun sitio. Medido:

```
abrir con duracion_segundos 5   PG es_inventario_limitado = true   Redis TTL 2
esperar a que venza             claves de Redis = 0
                                PG es_inventario_limitado = TRUE   <-- sigue marcada
                                y el panel sigue diciendo "Venta relampago abierta"
```

La razon es de una linea: **Redis no puede escribir en PostgreSQL**. El `EXPIRE`
se lleva las dos claves y nadie apaga la columna. El resultado es una oferta que
el panel ensena como en venta relampago cuando esa venta ya no existe.

Lo que **no** rompe, y conviene saberlo antes de asustarse: al comprador no le
pasa nada. `CarritoService` decide el camino con `existeVentaLimitada()`, que es
un `EXISTS` contra **Redis** y no la columna, asi que sin claves la oferta se
compra por el flujo normal de PostgreSQL. El que miente es el panel del vendedor.

Y se sale del atasco con el mismo boton: pulsar "Cerrar la venta" sobre una
oferta en ese estado contesta 200 y deja la columna en `false`. Medido. O sea que
hay recuperacion y no hace falta tocar la base a mano.

El arreglo de fondo no es del frontend: o la columna se deduce de Redis en vez de
guardarse, o alguien tiene que apagarla al vencer. Queda anotado.

**Y el boton esta en las DOS vistas del panel**, no solo en la lista. Un
vendedor normal entra por "Mis ofertas"; la tienda y el admin entran por "Tus
ofertas, por producto", que es otra rama del marcado. Ponerlo solo en la lista
habria dejado a la cuenta con mas ofertas sin poder abrir ni una. Las dos
comparten el mismo `{#snippet panelRelampago}`, que es el primer snippet del
proyecto y existe para que no haya dos copias que corregir.

Lo unico que queda del bloque, y nunca fue del alcance, es la activacion
automatica por "calor" que propuso el profesor.

### El stock de verdad ya llega a la pantalla

**Hecho el 2026-09-03, y arregla una mentira que se veia en la ficha.**

Mientras una venta relampago esta abierta, `oferta.stock` de PostgreSQL **queda
congelado** en el valor que tenia al abrirla: quien manda es el contador de
Redis. La ficha ensenaba el de PostgreSQL, asi que decia "7 unidades" con el
boton Agregar habilitado y al pulsarlo contestaba "pediste 1 y hay 0
disponibles". La persona no hacia nada mal.

Jose David agrego **`stock_disponible`** a los tres GET de ofertas
(`/productos/:id`, `/vendedor/ofertas` y `mi_oferta`), leido con la operacion
`estado` del `.lua`. Es un campo APARTE y no pisa a `stock`, que es lo correcto:
si un dia Redis no contesta, un `7` a secas no diria de cual de los dos numeros
viene.

El frontend ya lo consume, y son dos pantallas:

```
la ficha        el numero sale de unidades(), que es stock_disponible ?? stock
                y lleva la insignia naranja "Venta relampago"
el panel        "2 de 7 sin vender", los DOS numeros: con cuantas abrio la venta
                y cuantas le quedan
```

Medido en el navegador con la venta abierta y 5 de 7 apartadas: la ficha pasa a
decir **2 unidades** en vez de 7, y el boton se deshabilita solo al llegar a 0.

`stock_disponible` es `null` en TRES casos que se tratan igual a proposito --
oferta normal, venta ya cerrada, y Redis sin contestar -- porque en los tres el
numero bueno es el de PostgreSQL. Un `??` los cubre los tres sin distinguirlos.

### La ficha del producto ahora tiene pestanas

**Hecho el 2026-09-03.** Era una sola columna larguisima: foto, precio,
detalles, presentaciones, y las resenas hasta el fondo. El sintoma de que estaba
mal es que alguien del propio equipo abrio la pagina y **no encontro las
resenas**.

Ahora son tres pestanas, con las mismas clases que las del panel del vendedor
para que se reconozcan: `Comprar` (por defecto), `Detalles` y `Resenas`, cada
una con su numero.

Dos decisiones que no son obvias:

**"Comprar" es la primera y sale por defecto.** Es a lo que se entra a un
producto, y meterla detras de un clic seria arreglar un problema creando otro
peor.

**Las tres se MONTAN siempre y se esconden con `hidden`, no con `{#if}`.** Es lo
que hace posible el numero de la pestana de resenas: con un `{#if}` la seccion
no existiria hasta el primer clic, o sea que el contador solo aparecia DESPUES
de entrar, justo cuando ya no sirve para invitarte a entrar. Y de paso cambiar
de pestana no vuelve a pedir nada.

El numero de resenas lo reporta la propia seccion (`alContar`), que lo cuenta
contra PostgreSQL. **No** sale de `resenas_total` del documento de Mongo, que es
la copia del ETL y esta vieja hasta la proxima corrida.

### El grafo ya sabe que le falta: la cola del outbox

**Hecho el 2026-09-03, y es la mitad de abajo del pendiente 4.**

`migrations/015_outbox_grafo.sql` crea `evento_grafo` y un trigger sobre
`resena` que encola el id de cada resena que se toca **en la misma transaccion
que la resena**. Esa palabra es todo el diseno: la alternativa obvia -- que el
backend le escriba a Neo4j despues de commitear -- tiene un hueco que no se
puede cerrar, porque si el proceso se cae entre el `COMMIT` y esa escritura la
resena existe, no esta en el grafo, y no queda constancia de que falte.

`etl/cargar_grafo.sh` la vacia al terminar y estrena un modo `--cola` que
proyecta solo lo pendiente. Medido de punta a punta:

```
resena creada    -> 1 evento pendiente, el grafo sigue en 90
--cola           -> el nodo :Resena aparece con sus 3 relaciones
resena borrada   -> 1 evento pendiente, el grafo sigue en 91
--cola           -> el nodo desaparece, el grafo vuelve a 90
```

Y respeta la transaccion, que es el punto: dentro de un `BEGIN`, crear una
resena deja 1 pendiente y borrarla deja 2; tras el `ROLLBACK` quedan **0**.

**Lo que `--cola` NO hace es correr mas rapido**, y decir lo contrario seria
inventar. Baja el Cypher generado de 22 KB a 5 KB, pero el script entero tarda
lo mismo (21.8 s contra 22.6 s): esos segundos son casi todos arranques de la
JVM de `cypher-shell`. Hoy `--cola` vale porque es **el unico modo que sabe
aplicar las BAJAS** -- antes una resena borrada se quedaba en el grafo para
siempre y la unica salida era `--limpiar`, que borra el grafo entero.

**Y el 2026-09-04 se cerro el circulo entero.** Jose David escribio el worker
(`@Interval` cada 10 s) y la conciliacion (`GET /admin/grafo/conciliacion`), y
yo puse el aviso en el panel. Ahora **el grafo se mantiene al dia solo**:

```
resena creada  ->  ~10 s despues  ->  el nodo y sus 3 relaciones estan en Neo4j
resena borrada ->  ~10 s despues  ->  el nodo desaparece
```

Medido, con el log del backend diciendo "worker del grafo: 3 evento(s)
aplicados" sin que nadie corriera nada.

**Y el panel de fraude ya no calla.** Debajo de su introduccion sale una linea
que dice de cuando son los datos que se acaban de analizar: en gris "Grafo al
dia con PostgreSQL, sincronizado hace 9 minutos", y en rojo "Este analisis
puede estar incompleto" con la sugerencia del backend cuando no cuadra. Se
probo borrando un nodo `:Resena` a mano y viendo el aviso rojo aparecer.

Eso cierra el pendiente 4 entero, que llevaba dias escrito.

El plan completo, con las cinco trampas del worker, esta en
`backend/elementos Generales/plan pendiente/outbox-grafo.md`.

### La nota del producto, embebida en el catalogo

Cada documento de MongoDB trae ahora dos campos mas, que calcula `etl/extraer.sql`
desde la tabla `resena` de PostgreSQL:

```
resenas_promedio   la nota media, 0 cuando no tiene ninguna resena
resenas_total      cuantas resenas la sostienen
```

**Son el sexto y el septimo numero derivado que se embebe**, y existen por lo
mismo que los cinco de precio y stock que ya estaban: la lista del catalogo los
necesita en cada tarjeta, y sin ellos habria que consultar PostgreSQL una vez por
producto de la pagina. Comparten tambien su contrapartida, que es una copia que
envejece hasta la proxima corrida del ETL.

Van **dos campos y no uno** por una razon que no es obvia: `calificacion` es
`CHECK BETWEEN 1 AND 5`, asi que un promedio real nunca puede dar 0. El 0
significa "no tiene resenas", y quien filtre por nota minima tiene que exigir
ademas `resenas_total > 0` o los productos sin opiniones se ordenarian por debajo
de los de una estrella.

El indice es `catalogo_rating` y esta en `mongo/002_resenas.js`. Su gracia, y es
lo que conviene saber contar: como el RANGO y el ORDEN caen sobre el mismo campo,
el indice sirve para las dos cosas y **no aparece etapa SORT**. En
`catalogo_precio` no se pudo, porque ahi el rango cae sobre `precio_desde` y el
orden sobre `_id`, que son dos campos distintos.

Medido el 2026-09-03 con el catalogo en **1105** productos: filtrando por nota
minima dentro de una categoria, **3 documentos examinados para 3 devueltos** con
el indice y **sin etapa SORT**, contra **1105 documentos y un SORT** sin ninguno.
Ese numero cambia con el catalogo que tenga quien lo corra; lo que no cambia es
que el indice sirve para el rango y para el orden a la vez.

**El filtro del catalogo todavia no existe**: el campo esta y el indice esta,
pero ninguna ruta del backend lo consume. El contrato de lo que falta esta en
`docs/BACKEND-PENDIENTE.md`.

### Y esa nota ya alcanza a los productos que el ETL no veia

**Hecho el 2026-09-04, y cierra el pendiente 6.**

El calculo de arriba vive dentro de `extraer.sql`, que recorre `FROM productos p`
en PostgreSQL. Todo lo que no tenga fila ahi le es invisible, y hay dos clases de
producto que caen justo en ese hueco:

```
el que solo vive en Mongo    nace en el panel del vendedor, no deja fila en
                             PostgreSQL, y su nota se quedaba en 0 para siempre
                             aunque lo resenaran. En la base viva son CUATRO,
                             los _id 103 a 106

al que le borran la ultima   la fila se va de `resena` y el documento conserva
resena                       la nota vieja, sin nada que la apague
```

El segundo se encontro midiendo, no leyendo: el producto 1 decia **1 resena con
nota 4** y PostgreSQL tenia **cero** filas suyas en `resena`. Mongo sostenia 52
productos con nota donde PostgreSQL solo respaldaba 51.

La etapa nueva son dos archivos y un enganche:

```
etl/extraer_notas.sql   agrupa `resena` por id_producto_mongo, SIN join contra
                        productos. Ese join es exactamente lo que dejaba fuera
                        a los de Mongo
etl/cargar_notas.js     escribe los dos campos y apaga los que dicen tener
                        resenas y ya no salen en la lista
etl/correr.sh           la corre como TERCERA etapa
```

**Va DESPUES de `cargar.js`, nunca antes.** `cargar.js` reemplaza el documento
entero con `replaceOne`, asi que al reves le pasaria por encima a todo lo que
esta etapa escribio. Esta dicho en la cabecera de los dos archivos para que a
nadie le tiente reordenarlas.

**Y estrena `--notas`**, que corre solo esa etapa, igual que `--cola` en el del
grafo. Tarda **4 segundos contra 13**, y sirve cuando lo unico que se movio son
resenas:

```
bash etl/correr.sh            las tres etapas
bash etl/correr.sh --notas    solo la nota
```

Se comprueba con `bash pruebas/notas.sh`, que da **10 OK** y **rompe el problema
antes de medirlo**: su primera parte corre `extraer.sql` de verdad y comprueba
que el producto elegido NO sale en su resultado. Sin ese paso, el arnes podria
estar aprobando algo que ya funcionaba antes del cambio.

Medido de punta a punta sobre el producto 103:

```
resena sembrada de 5 estrellas   ->  el documento sigue en 0|0
correr --notas                   ->  el documento dice 1|5
resena borrada, correr --notas   ->  vuelve a 0|0
```

Y al arnes se le rompio el codigo a proposito para ver si se daba cuenta: con el
`$gt: 0` del apagado cambiado por `$gt: 999999`, pasa de **10 OK** a **7 OK y 3
FALLA**, en tres sitios distintos.

**Lo que sigue sin hacer** es que la nota se refresque sola. Una resena nueva no
la mueve hasta que alguien corre el ETL. Es el pendiente 4 aplicado a otro dato:
el grafo tiene cola y worker, y la nota de Mongo no.

### Resenar desde el pedido, ya de punta a punta

**Hecho el 2026-09-04.** Jose David sumo `puede_resenar` y `ya_reseno` por linea
a `GET /comprador/pedidos/:id`, y esos dos campos estuvieron unas horas **sin
que nada los consumiera**: se buscaron en todo `frontend/src` y salian en CERO
archivos. Es la tercera vez en este proyecto que el backend arma bien una pieza
y la pantalla no se entera, asi que conviene buscarlo a proposito.

En `/pedidos`, cada linea de un pedido pagado tiene ahora "Resenar esta compra",
y las que ya se resenaron dicen "Ya la resenaste" en gris en vez de quedarse sin
nada, que se lee como que algo fallo.

**Es un ENLACE y no un formulario, y esa es la decision.** `POST /resenas` pide
el **correo** del vendedor, y la linea del pedido solo trae su nombre y su id.
Desde ahi no se puede publicar. La ficha del producto si tiene la lista de
calificables con sus correos, y ademas ya tiene el formulario entero escrito y
probado. El boton lleva alli:

```
/producto/1?resenar=1&vendedor=Carlos%20Ramirez
```

La ficha abre la pestana de resenas con el formulario desplegado y preselecciona
al vendedor.

**Por que viaja el nombre del vendedor, y no es un adorno.** Un producto se le
puede comprar a varios. En el pedido 17 de la semilla, el producto 1 tiene
**TRES** vendedores calificables (Andres Castillo, Carlos Ramirez y Lucia
Morales) y la compra fue a uno solo. Sin esa pista, la persona entra al
formulario y puede calificar sin querer a otro. Medido, la pista resuelve
`Carlos Ramirez` a `ventas.norte@mesh.com`.

Se compara por NOMBRE porque es lo unico que comparten la linea del pedido y la
lista de calificables. La linea guarda el nombre copiado del dia de la compra
(esta dicho en `LineaPedido`), asi que un vendedor que se haya cambiado el
nombre desde entonces no va a coincidir. Cuando no coincide **no se
preselecciona a nadie**, que es lo correcto: elegir al equivocado es peor que no
elegir, porque desde la pantalla no se deshace.

Dos cosas mas que no son obvias:

**`puede_resenar` y `ya_reseno` son opcionales en el tipo.** Un backend anterior
a hoy no los manda, y sin ellos el boton simplemente no sale. Falla hacia el
lado bueno: ofrecerlo y que el `POST` conteste 403 seria peor que no ofrecerlo.

**`ya_reseno` mira el trio completo** (comprador, vendedor, producto), el mismo
que protege el `UNIQUE` de `resena`. Mirando solo el producto, resenar a un
vendedor apagaria el boton del otro sobre el mismo producto comprado dos veces.

### El choque de los dos repartidores de id ya no es invisible

**Hecho el 2026-09-04.** No decide el pendiente 5 -- quien reparte el id de
producto sigue siendo cosa de Jose David -- pero borra la frase que decia que
**no habia nada que avisara**, que era lo peor de ese punto: el arranque quedaba
en verde, las cuentas cuadraban, y lo que se perdia era un producto entero.

`arrancar.ps1` corre ahora un paso mas despues del ETL:

```
>> Comprobando que los id de producto no se pisan
   sin cruce: PostgreSQL reparte el 1127 y el mayor de Mongo es 1105 (22 de margen)
```

**Pregunta por la SECUENCIA, no por `max(id_producto)`**, y ahi esta todo el
valor del aviso. No son el mismo numero: un `nextval` que se llevo una
transaccion con `ROLLBACK` no vuelve. Ese dia la secuencia iba en 1126 con un
maximo real de 1105, o sea que preguntar por el maximo habria prometido 21
numeros de margen que no existen.

Cuando hay cruce lo dice, y se probo bajando la secuencia a mano:

```
5 documento(s) de MongoDB ocupan un id que PostgreSQL va a repartir
  PostgreSQL entregara el 1101 en el proximo INSERT INTO productos
```

**No corta el arranque**, a proposito: un choque futuro no rompe nada de lo que
esta cargado hoy, y parar la maquina por algo que aun no ha pasado seria peor que
el problema.

### El generador de lotes

`migrations/lote/generar_lote.sql` agrega productos y ofertas **sobre una base ya
cargada**, en cualquier momento. Es lo contrario de `migrations/datos/001_catalogo.sql`,
que solo entra en una base vacia.

```powershell
.\arrancar.ps1 -Productos 300 -Semilla 7
```

Misma semilla, mismo catalogo, en cualquier maquina, sin guardar nada. Cada
producto se genera **clonando** uno del catalogo curado, asi que hereda una
categoria valida, caracteristicas del tipo correcto y una foto que carga. Las
imagenes se reusan por la tabla puente y **no se inserta ni una URL nueva**.

Su documentacion entera esta en `migrations/lote/README.md`, incluido como se
deshace un lote, que son dos mitades: el SQL de PostgreSQL **y un borrado aparte
en MongoDB**, porque correr el ETL no los quita.

Y lo que destapo construirlo esta en el pendiente 5, que es lo mas grave que
salio hoy: **hay dos asignadores de id de producto que no se hablan.**

### Y hay un SEGUNDO generador, por el otro extremo

```powershell
.\arrancar.ps1 -ProductosMongo 200
.\arrancar.ps1 -BorrarMongo 7
```

Crea productos que viven **solo en MongoDB**, sin fila en `productos`. La
diferencia con el otro no es de tamano, es de ORIGEN:

| | `-Productos` (marcador `L`) | `-ProductosMongo` (marcador `M`) |
|---|---|---|
| Nace en | PostgreSQL | MongoDB |
| Fila en `productos` | si | **no** |
| El ETL lo reescribe | en cada corrida | **nunca** |

**El de Mongo es como nacen hoy los productos de verdad.** El backend lo dice
por escrito: *"los productos ya no se registran en PostgreSQL"*. Un vendedor que
publica desde el panel crea exactamente eso, y hasta ahora no habia forma de
tener muchos para probarlo.

Son dos escrituras en dos bases: el documento en Mongo y sus ofertas en
PostgreSQL, porque el descuento de stock tiene que ser atomico (ADR-2). El
precio lo sortea el generador de Mongo y **viaja en un csv** hasta el SQL que
crea las ofertas, en vez de sortearse dos veces con la misma semilla: un dato
compartido no se puede desincronizar, dos implementaciones del mismo azar si.

Todo esta en `mongo/lote/README.md`.

**El carrito ya compra de verdad.** Verificado contra la base: pedido creado,
pago `pagado`, kardex con el motivo `venta`, stock descontado, y la clave de
Redis borrada. Una compra fallida no deja ni un pedido a medias **y no borra el
carrito**.

### Los indices de Mongo, para ensenarlos

```powershell
.\mongo\demostracion_indices.ps1     # mide y abre la pagina
```

Corre los cuatro pasos que Jose David mando al grupo, mide cada uno con
`explain("executionStats")` y **corre cada uno otra vez con
`hint({$natural:1})`**, que obliga a MongoDB a no usar ningun indice. Con eso
arma `demostracion_indices.html` (en la raiz): una pagina suelta, sin internet, con
los dos numeros uno encima del otro.

La comparacion es el punto entero. Un `explain` a secas dice "uso
`catalogo_categoria`" y suena bien, pero no dice cuanto; lo que significa algo
es **cuantos documentos hubo que abrir**:

**Los numeros son los de la base que tenga quien lo corra**, y por eso la pagina
no se versiona. Estos son los del 2026-09-03, con el catalogo en 1105 productos:

| Paso | Con indice | Sin ninguno |
|---|---|---|
| 2 -- categoria + orden | 79 | 1105 |
| 3 -- rango de precio | 96 | 1105 |
| 4 -- categoria + `$or` de caracteristicas | 79 | 1105 |

Con el catalogo curado a secas (102 productos) eran 7, 9 y 7 contra 102. La
proporcion es lo que hay que contar, no el numero.

**El paso 4 es el que hay que saber contar.** Ese `$or` son cuatro
`$elemMatch` sobre arrays embebidos y **ningun indice puede resolverlo**. Lo
que hace el indice es otra cosa: baja el problema de 102 documentos a los 7 de
la categoria, y el `$or` se evalua solo sobre esos. El indice no contesta la
pregunta, **la hace pequena**.

Dos cosas medidas que conviene no olvidar:

- **`Memoria RAM` solo existe dentro de las VARIANTES**, no en las
  caracteristicas del producto. Las dos primeras ramas del `$or` no encuentran
  nada nunca. Estan escritas igual porque otras caracteristicas (`Marca`,
  `Garantia`) si viven arriba, y la consulta busca en los dos sitios sin tener
  que saber en cual esta cada una.
- **El valor es un entero, no texto.** Con `valor: 8` salen 3 productos; con
  `valor: "8"`, cero y sin ningun error.

El arnes se probo rompiendolo: quitando `catalogo_categoria` a mano, 6 de las
12 comprobaciones se ponen en rojo y el paso 3 -- que usa el otro indice --
sigue en verde. Un arnes que no distingue eso no esta midiendo nada. El indice
se devuelve corriendo `mongo/001_productos.js`, que es idempotente.

La pagina **no se sube al repositorio** (esta en `.gitignore`): sus cifras son
de la base que tenga quien la corra, y una copia versionada envejeceria en
silencio.

### El pedido reconstruido ensena todo

En `/pedidos`, cada linea abre un modal con **lo que se pago** (presentacion,
vendedor, precio unitario, cantidad, subtotal), **el precio y el stock que
tenia esa oferta ese dia**, y el producto reconstruido del catalogo con su
categoria, sus caracteristicas y todas sus presentaciones, marcando la que se
compro.

Los dos precios salen de sitios distintos y **pueden diferir sin que ninguno
este mal**: el de la linea se congelo al comprar, el reconstruido es el ultimo
precio de ese dia. Cuando no coinciden, el modal lo dice.

Ojo con la trampa que tenia esto y que no daba ningun error: el tipo de
`traerProductoEnFecha` declaraba solo `nombre` y `descripcion`, asi que se
guardaban dos campos de los cinco que manda la ruta. El marcado de la
categoria y las caracteristicas ya estaba escrito y **no se ejecutaba nunca**.
Si esa ruta empieza a mandar un campo mas, se agrega en `ProductoEnFecha`
(`frontend/src/lib/pedido.ts`), que es de donde cuelgan las pantallas.

---

## Las cinco cosas que hay que saber, y no son obvias

**1. La resena es de un VENDEDOR sobre un PRODUCTO.** No del producto solo.
`resena(id_usuario, id_usuario_vendedor, id_producto_mongo, ...)`. Colgaba de
`oferta` y se cambio: `oferta` es unica por (usuario, producto, **variante**), y
nadie resena una variante.

**2. No hay FK de `resena` a `pedido`, a proposito.** La resena sin compra es la
senal de fraude mas fuerte; exigir la compra la borra del modelo. Jose David SI
la exige **en la aplicacion** (compra verificada, y **al mismo vendedor**), y eso
es reversible. Desde el 2026-08-30 **la semilla cumple esa regla**: las **90**
resenas tienen su compra pagada detras, y las comprobaciones 10 y 11 de
`001_catalogo.sql` fallan la migracion si alguna deja de tenerla. Antes solo 2 la
tenian y el boton de escribir no aparecia casi nunca.

Eran 86 cuando se arreglo y son 90 desde que entro el anillo de fraude. Vuelto a
medir el 2026-09-03 con los mismos JOIN de la comprobacion 10: **0 resenas sin
compra pagada a ese vendedor y 0 fechadas antes de su compra**.

**3. El grafo tiene TRES nodos, no cuatro.** `:Usuario`, `:Resena`, `:Producto`
(mas `:Direccion`). **No hay `:Vendedor`**: en Mesh comprar no pide rol, asi que
partirlo dejaria la misma cuenta como dos nodos y **el anillo nunca cerraria**.
La resena es NODO porque conecta TRES cosas.

**4. El carrito de Redis guarda intencion, no precios.** Es
`id_oferta -> cantidad` y nada mas. El precio, el stock y el nombre se resuelven
al leerlo. **Consecuencia: el precio que se cobra es el de pagar.** Es el
pendiente #1.

**5. La semilla NO es idempotente.** **17 de sus 26** `INSERT` de primer nivel no
tienen guardia, asi que `001_catalogo.sql` solo carga contra una base vacia. Los
9 guardados son los tres del principio (cuentas, direcciones e historial de
direccion) y los seis del tramo del anillo de fraude del final. Se recuenta
mirando cada `INSERT` entero, no con un `grep` de `NOT EXISTS`, que cuenta de mas
porque los hay dentro de bloques `DO`.

---

## Las trampas del entorno, que ya mordieron

**Git Bash convierte las rutas** que empiezan con `/` al pasarlas a `docker`.
`docker exec ... -f /migrations/x.sql` falla con una ruta de Windows. Solucion:
`export MSYS_NO_PATHCONV=1`.

**La imagen de Neo4j trata cualquier `NEO4J_*` como ajuste de `neo4j.conf`.** Una
variable `NEO4J_PASSWORD` se traduce al ajuste `PASSWORD`, que no existe, y el
contenedor se reinicia en bucle. Por eso la del healthcheck se llama
`MESH_NEO4J_PASSWORD`.

**El generador es determinista y `azar()` es UNA secuencia global.** Un sorteo
nuevo metido antes de la **linea 1717** de `migrations/datos/generador.js` --
que es la ultima llamada a `azar()`, comprobada con
`grep -n "azar(" migrations/datos/generador.js | tail` -- reescribe las **556**
ofertas. La parte social tiene su propia semilla (`azarSocial`) justamente para
no arrastrarse con eso.

**Tras varios recargados de HMR la pestana de Chrome se congela** y
`Runtime.evaluate` da timeout. Se cierra y se abre otra.

**Un `as` de TypeScript es una promesa de quien escribe, no una comprobacion.**
Un cast de las lineas del carrito a `LineaPedido` compilaba limpio y ensenaba
"Pagar QNaN": sumaba un campo que no existia.

---

### El precio del carrito ya avisa antes de cobrar

`POST /carrito/comprar` acepta `lineas_precio_visto`: el frontend manda el
precio que ENSENO y el backend lo compara contra el de hoy **dentro de la misma
peticion que cobra**. Si no cuadra, no cobra nada y contesta `comprado: false`
con los avisos; reenviar con `confirmar_cambios: true` acepta el nuevo.

Que la comparacion viaje en la misma peticion es lo que la hace valer: entre
mirar y cobrar no queda ninguna ventana. Comprobarlo desde el frontend antes de
llamar dejaba milisegundos abiertos, y se probo asi antes de cambiarlo.

El precio todavia NO se congela -- si se confirma, se cobra el de hoy -- pero ya
no se cobra en silencio, que era el dano. Ver el pendiente 1.

**Medido el 2026-09-03 contra el backend vivo:** con el precio real en Q6,263 se
manda `precio_visto: "1.00"` y contesta `comprado: false` con el aviso que trae
los dos precios; los pedidos siguen en 32 antes y despues, y el carrito queda
entero.

Y una condicion que conviene saber, porque la proteccion **es opcional del lado
del cliente**: `detectarAvisosPrecio` devuelve una lista vacia si
`lineas_precio_visto` no viene o viene vacia, o sea que quien no mande el campo
cobra el de hoy en silencio igual que antes. `Checkout.svelte` si lo manda, asi
que la aplicacion esta cubierta; cualquier otro cliente, y cualquier linea que se
quede fuera de ese array, no lo esta.

## Que falta

En `docs/PENDIENTES.md`, con su urgencia. **Al 2026-09-04 no queda nada abierto
de este lado**: los cuatro puntos vivos se deciden o se escriben en `backend/`,
y la lista corta para Jose David esta arriba del todo en
`docs/BACKEND-PENDIENTE.md`.

Lo mas urgente de esos cuatro es el **409 en el `PATCH` de ofertas durante una
venta relampago**, que son tres lineas y hoy deja que Redis prometa unidades que
PostgreSQL no puede entregar. Y lo mas grave sigue siendo que **el precio se
congela al pagar y no al agregar**: ya no se cobra en silencio, pero tampoco se
respeta el precio que se enseno.

Lo unico que queda sin comprobar es la revision a ojo en el navegador, que pide
entrar con una cuenta.

**Los 2.5 puntos de la Entrega 2 que no dependian de nadie ya estan escritos**
(2026-09-03):

| Que | Donde |
|---|---|
| Comparativa grafos vs columnar, con las condiciones bajo las cuales SI habria que incorporar la columnar | `docs/DECISION-GRAFOS-VS-COLUMNAR.md` |
| Diagrama de arquitectura, que no es el ER | `docs/ARQUITECTURA.md` y `docs/diagrama-arquitectura.drawio` |

La comparativa **no descarta Cassandra, la aplaza**, y con cinco condiciones
medibles contra este mismo sistema. Y dice de frente lo que hay que decir antes
que nada: a 32 pedidos y 14 aristas de calificacion **ninguna de las dos familias
hace falta por rendimiento**. Se midio el analisis de fraude escrito entero en
SQL con `WITH RECURSIVE` y encuentra exactamente los mismos anillos que Neo4j, en
28.7 ms. Lo que decide no es la velocidad, es que la version en SQL **sin la
guardia de nodos repetidos convierte 2 anillos reales en 7**, y eso tambien esta
medido.

---

## Donde esta cada cosa

```
migrations/          el esquema (la 015 es la ultima, 016 sera la siguiente)
                     y el generador de datos
etl/                 PostgreSQL -> MongoDB, y PostgreSQL -> Neo4j
neo4j/               el modelo del grafo y las 5 consultas de fraude
redis/               el carrito, el Lua del inventario limitado y sus arneses
pruebas/             arneses de las rutas: resenas.sh y carrito.sh
docs/                base-de-datos.md manda sobre el modelo;
                     ARQUITECTURA.md es el diagrama de arquitectura (no el ER);
                     DECISION-GRAFOS-VS-COLUMNAR.md es el ADR-3 de la Entrega 2;
                     GUIA-PRESENTACION.txt es el guion para defenderlo
backend/             de Jose David. NO SE TOCA. Su doc buena esta en
                     "elementos Generales/endpoints-*.md"
```
