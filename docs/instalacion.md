# Instalacion y ambiente

Como dejar Mesh corriendo en una PC nueva.

## Programas que hay que instalar

| Programa | Version | Donde |
|---|---|---|
| Node.js | 24 LTS | https://nodejs.org |
| Docker Desktop | ultima | https://www.docker.com/products/docker-desktop |
| Git | ultima | https://git-scm.com/downloads |

Nada mas. Ninguna de las seis bases se instala -- ni PostgreSQL, ni MongoDB, ni
Redis, ni Neo4j, ni Elasticsearch, ni ClickHouse -- y tampoco sus ventanas: los
once contenedores estan en el `docker-compose.yml` y Docker los baja solos.

Tampoco hace falta instalar Ollama, que calcula los vectores de la
recomendacion semantica ("Parecidos a este" en la ficha). `arrancar.ps1` (paso
7d, por `etl/cargar_vectores.ps1`) lo resuelve solo, en este orden:

1. Si la PC ya tiene Ollama y responde en `localhost:11434`, usa ese.
2. Si esta instalado pero apagado, lo enciende oculto con `ollama serve`.
3. Si la PC no lo tiene, levanta el contenedor `mesh-ollama` del compose, en
   `localhost:11435`. Va en el perfil `ollama`, asi que un `docker compose up -d`
   normal no lo arranca.

En los tres casos, si falta el modelo `paraphrase-multilingual` (unos 560 MB) lo
baja solo. La primera vez en una PC sin nada baja tambien la imagen de Ollama y
calcula los 3105 vectores en la CPU: son varios minutos, una sola vez. Despues
solo se calcula lo que cambio. El modelo del contenedor vive en el volumen
externo `mesh-ollama-modelos`, que `-Reiniciar` no borra.

Si nada de eso funciona (por ejemplo, sin internet la primera vez), el arranque
sigue: la tienda funciona entera y solo falta el estante de productos parecidos.

Si la PC ya tiene PostgreSQL instalado, hay que detener su servicio antes de
empezar. Usa el puerto 5432 y se pelea con el contenedor. En PowerShell como
administrador:

```powershell
Get-Service postgresql* | Stop-Service -Force
Get-Service postgresql* | Set-Service -StartupType Manual
```

Lo segundo es para que no vuelva solo al reiniciar la PC. Si hace falta para otra
clase, se levanta a mano con `Start-Service postgresql*`.

Esto no da un error claro y cuesta encontrarlo. Esta explicado abajo, en
"El backend dice que la contrasena esta mal".

## Pasos

```bash
git clone https://github.com/pinedahuella/Proyecto-Tienda-Base-Datos-2.git
cd Proyecto-Tienda-Base-Datos-2
```

Las contrasenas no vienen en el repositorio. Hay que crear dos archivos `.env`
a partir de sus plantillas y llenarlos con los valores que use el equipo:

```powershell
copy .env.example .env
copy backend\.env.example backend\.env
```

Los dos archivos deben tener el mismo usuario y la misma contrasena, porque el
de la raiz es el que crea la base y el de `backend` es con el que la API se
conecta a ella.

Despues:

```bash
cd backend && npm install
cd ../frontend && npm install
```

## Levantar el proyecto

En Windows, un solo comando deja las bases listas:

```powershell
.\arrancar.ps1
```

El script arranca Docker si esta apagado, levanta los once contenedores, espera
a que **los seis motores** respondan -- PostgreSQL, MongoDB, ClickHouse,
Elasticsearch, Redis y Neo4j --,
corre las migraciones pendientes y carga lo que les falte a las dos bases
derivadas: el catalogo de MongoDB y el grafo de Neo4j. Se puede correr las veces
que quieras.

Las banderas:

| Bandera | Que hace |
|---|---|
| *(ninguna)* | levanta, migra, y corre los ETL solo si detecta que falta algo |
| `-Reiniciar` | borra los datos y empieza de cero |
| `-Etl` | fuerza los DOS ETL: el catalogo de Mongo y el grafo de Neo4j |
| `-ReiniciarMongo` | rehace solo MongoDB, sin tocar PostgreSQL |
| `-ReiniciarGrafo` | rehace solo el grafo de Neo4j, desde cero |
| `-Mongo` | abre la consola de MongoDB y ya |

`-Etl` fuerza los dos a proposito, en vez de tener una bandera por destino: quien
la teclea sabe que cambio algo en PostgreSQL, pero no si ese dato viaja a Mongo,
a Neo4j o a los dos. Los dos ETL son idempotentes, asi que correr de mas es
gratis y correr de menos es el fallo de verdad.

Despues, en dos terminales mas:

```bash
cd backend && npm run start:dev   # http://localhost:3000
cd frontend && npm run dev        # http://localhost:5173
```

A mano, sin el script:

```bash
docker compose up -d
docker exec mesh-postgres psql -U $DB_USER -d $DB_NAME -f /migrations/001_usuarios.sql
```

## Las dos clases de migracion

```
migrations/*.sql        el esquema: las tablas y los catalogos de estado
migrations/datos/*.sql  los conjuntos de datos de prueba
```

`arrancar.ps1` las corre en dos pasos: primero el esquema y despues los datos,
cada paso en orden de nombre. Los estados de producto y de variante van con el
esquema y no con los datos, porque sin ellos no se puede insertar un producto.

El conjunto de datos lo escribe un generador, no se edita a mano:

```bash
node migrations/datos/generador.js
```

El contenido (que categorias, que productos, que caracteristicas) se escribe a
mano dentro del generador; el reparto (que vendedor oferta que, con cuanto stock
y a que precio) lo calcula el, con una semilla fija para que dos corridas den el
mismo archivo. Las reglas estan en
[migrations/README.md](../migrations/README.md).

**Los dos pasos no se tratan igual, y hay que saberlo.** El esquema se reejecuta
en cada arranque sin problema: si una migracion ya estaba aplicada, el script lo
avisa y sigue. Los conjuntos de datos no: `datos/001_catalogo.sql` **no es
idempotente** -- 17 de sus 20 `INSERT` no llevan ninguna guardia -- y una segunda
pasada muere en la linea 99 con `duplicate key value violates unique constraint
"idx_categorias_nombre_raiz"`.

Por eso `arrancar.ps1` se los salta si la base ya tiene productos, y lo avisa en
amarillo:

```
>> Corriendo conjuntos de datos
   La base ya tiene 102 productos: me salto migrations/datos/
   Esos archivos no son idempotentes y solo entran en una base vacia.
   Para recargarlos desde cero:  .\arrancar.ps1 -Reiniciar
```

No se pierde nada por eso: el archivo abre con `BEGIN;` y cierra con `COMMIT;`,
asi que una pasada que falla se deshace entera y una base ya cargada no se
ensucia. El motivo largo esta en
[migrations/README.md](../migrations/README.md), en "El conjunto de datos solo
entra una vez".

## Contenedores

Son **once**: seis motores, cuatro ventanas para mirarlos y un contenedor de un
solo uso. Diez se quedan corriendo; `mesh-kibana-vistas` termina en `Exited (0)`,
que es lo esperado.

| Servicio | Contenedor | Imagen | Puerto | Para que |
|---|---|---|---|---|
| PostgreSQL | mesh-postgres | pgvector/pgvector:pg18 | 5432 | la base relacional: cuentas, ofertas, pedidos y la parte social |
| pgAdmin | mesh-pgadmin | dpage/pgadmin4 | 5050 | la ventana de PostgreSQL |
| MongoDB | mesh-mongo | mongo:8 | 27018 | el catalogo de productos |
| DbGate | mesh-dbgate | dbgate/dbgate:latest | 3001 | la ventana de MongoDB |
| Redis | mesh-redis | redis:8-alpine | 6379 | Entrega 2: el carrito con expiracion y la oferta de inventario limitado |
| RedisInsight | mesh-redisinsight | redis/redisinsight:latest | 5540 | la ventana de Redis, con el TTL contando hacia atras |
| Neo4j | mesh-neo4j | neo4j:5-community | 7474 y 7687 | Entrega 2: el grafo de cuentas, resenas y productos |
| Elasticsearch | mesh-elastic | elasticsearch:8.15.3 | 9200 | Entrega 3: el indice del buscador y el de eventos de autenticacion |
| Kibana | mesh-kibana | kibana:8.15.3 | 5601, solo en `127.0.0.1` | la ventana de Elasticsearch |
| Vistas de Kibana | mesh-kibana-vistas | kibana:8.15.3 | -- | de un solo uso: crea las vistas de datos de Kibana y termina |
| ClickHouse | mesh-clickhouse | clickhouse/clickhouse-server:25.3 | 8123 y 9010 | los eventos en el tiempo, con su consola en `/play` |

Las filas de Redis y Neo4j son de la Entrega 2 y estan explicadas mas abajo, cada
una en su seccion. Las imagenes de Elasticsearch y Kibana son
`docker.elastic.co/elasticsearch/elasticsearch` y `docker.elastic.co/kibana/kibana`,
y llevan la misma version a proposito.

Apagar todo:

```bash
docker compose --profile ollama down
```

Con `-v` ademas borra los datos de la base. El `--profile ollama` es para que
tambien apague `mesh-ollama` si se levanto; sin el, ese contenedor se queda
prendido. El volumen del modelo es externo y no lo borra ni `-v`.

**Cuatro carpetas del repositorio van montadas dentro de su contenedor**, para
poder correr los scripts sin copiarlos a mano:

| Carpeta | Contenedor | Ruta adentro | Que hay ahi |
|---|---|---|---|
| `migrations/` | mesh-postgres | `/migrations` | el esquema y los conjuntos de datos |
| `mongo/` | mesh-mongo | `/mongo` | los scripts que crean las colecciones |
| `neo4j/` | mesh-neo4j | `/neo4j` | el esquema del grafo y las consultas de fraude |
| `docker/kibana/` | mesh-kibana-vistas | `/init` | `vistas.sh`, el que crea las vistas de datos de Kibana |

Redis no tiene carpeta montada, y no es un olvido: sus dos scripts Lua se cargan
por la entrada estandar (`redis-cli -x SCRIPT LOAD < redis/carrito.lua`), asi que
no hace falta que el contenedor los vea. El ETL del grafo hace lo mismo con
`docker cp` y con stdin, para no depender de que ese montaje siga en pie.

## El catalogo en MongoDB

Los productos se disenan y se cargan en PostgreSQL, y de ahi se migran a MongoDB
con el ETL de `etl/`. En Mongo quedan **tres colecciones**:

| Coleccion | Que trae |
|---|---|
| `productos` | un documento por producto, con sus variantes y caracteristicas |
| `categorias` | la paleta: que caracteristicas ofrece cada categoria |
| `productos_eventos` | el historial del catalogo, como eventos |

**Las ofertas NO se migran**: se quedan en `oferta`, en PostgreSQL. Precio,
stock y estado cambian en cada venta, y copiarlos obligaria a sostenerlos al
dia en dos bases a la vez. Lo que si viaja son cinco numeros agregados dentro
del producto (`precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total` y
`total_ofertas`),
para que la lista del catalogo se pinte sin salir de Mongo. La ficha de un
producto pide sus ofertas a PostgreSQL.

`arrancar.ps1` lo corre cuando **alguna** de esas colecciones tiene menos
documentos que su tabla en PostgreSQL, o sea cuando quedo algo sin migrar: una
maquina recien montada, o datos nuevos en `migrations/datos/`. Si ya estan todos
no lo vuelve a correr, para no pisar lo que haya en Mongo en cada arranque.

La comparacion va contra una **lista** de colecciones y no coleccion por
coleccion escrita a mano: ese chequeo ya fallo dos veces por mirar de menos, y
la segunda dejo maquinas sin la coleccion de categorias diciendo "ya cargado".

Un cambio que no mueva la cuenta, como corregir el precio de un producto que ya
existe, no lo detecta. Para eso se pide a mano:

```powershell
.\arrancar.ps1 -Etl
```

El detalle esta en [etl/README.md](../etl/README.md).

## Redis: el carrito y la oferta de inventario limitado

Es el almacen clave-valor de la Entrega 2. Guarda dos cosas, y las dos son
efimeras a proposito:

- **el carrito**, en `mesh:carrito:<id_usuario>`, un HASH con expiracion por
  inactividad. Al pagar se llama a `comprar_carrito()` de PostgreSQL y solo si
  salio bien se vacia.
- **la oferta de inventario limitado**, en `mesh:oferta:<id>` mas su ZSET de
  reservas, con un script Lua atomico que compara contra la cantidad pedida
  antes de descontar.

**Lleva contrasena aunque sea local**, y no es ceremonia: Redis sin
contrasena acepta a cualquiera que alcance el puerto, y el 6379 es de los mas
barridos que hay.

Desde el 2026-09-25 no es una contrasena sola sino **tres usuarios de ACL**,
declarados en el `command` de Redis en `docker-compose.yml`:

| Usuario | Quien lo usa | Contrasena en el `.env` | Puede |
|---|---|---|---|
| `default` | el backend y los arneses | `REDIS_PASSWORD` | todo menos los comandos peligrosos (`FLUSHALL`, `CONFIG`, `ACL`, `SHUTDOWN`, `DEBUG`) |
| `inspeccion` | RedisInsight | `REDIS_INSPECCION_PASSWORD` | solo leer: claves, TTL, `SCAN`, `INFO` |
| `operador` | mantenimiento a mano | `REDIS_OPERADOR_PASSWORD` | todo |

Como `default` sigue siendo el usuario por defecto, todo lo que antes entraba
con `-a $REDIS_PASSWORD` entra igual. Si faltan las otras dos contrasenas en el
`.env`, `arrancar.ps1` las agrega solo con un valor al azar. El `command` va
escrito como LISTA a proposito: en una sola linea, Compose corta la contrasena
en el `>` que la precede. La prueba es `bash redis/prueba_acceso.sh` y el detalle
esta en la seccion 4b de [redis/README.md](../redis/README.md).

```bash
docker exec mesh-redis redis-cli -a $REDIS_PASSWORD --no-auth-warning PING
# PONG
```

El `--no-auth-warning` solo calla el aviso de que la contrasena va en la linea de
comando; sin el funciona igual.

**Nace vacio y se queda vacio hasta que alguien lo use.** `arrancar.ps1` espera a
que Redis este sano y nada mas: no hay migraciones ni ETL que correr, porque el
carrito y los contadores son datos de la sesion, no un conjunto que se siembre.

El backend carga `redis/inventario_limitado.lua` solo, con `defineCommand` de
ioredis (`inventario-limitado.service.ts`): si Redis se reinicio y contesta
`NOSCRIPT`, reenvia el script y sigue. El carrito ya no usa Lua; desde el
2026-09-23 es un HASH con una foto en JSON por linea, y `redis/carrito.lua` queda
solo para su arnes. Para probar el script a mano, sin el backend:

```bash
docker exec -i mesh-redis redis-cli -a $REDIS_PASSWORD --no-auth-warning   -x SCRIPT LOAD < redis/inventario_limitado.lua
```

Ojo con lo que eso implica: **un arranque en verde NO prueba que la capa de Redis
funcione.** Eso lo prueban sus dos arneses, que hay que correr a mano:

```bash
bash redis/prueba_concurrencia.sh    # sobreventa bajo carga
bash redis/prueba_carrito.sh         # la expiracion y el checkout
```

El detalle esta en [redis/README.md](../redis/README.md).

## RedisInsight: la ventana de Redis

Redis no trae ninguna de fabrica -- `redis-cli` es todo lo que hay. RedisInsight
es lo que pgAdmin es para PostgreSQL: http://localhost:5540. La pagina no pide
usuario, y por dentro se conecta a Redis como `inspeccion`, el usuario de solo
lectura: mirar el TTL de un carrito no necesita poder borrarlo.

**Se eligio esta y no una conexion de Redis en dbgate (que tambien sabe) por una
razon concreta de la entrega:** RedisInsight ensena el TTL de cada clave y lo
cuenta hacia atras. La Entrega 2 pide "un tiempo de expiracion configurado
explicitamente", y esa pantalla **es** la evidencia -- se ve el carrito perdiendo
segundos y desapareciendo solo. En un listado de filas eso no se ve.

La conexion ya viene cargada, sin tener que agregarla a mano: las variables
`RI_*` del `docker-compose.yml` hacen aqui lo que `servers.json` en pgAdmin.
Apuntan a `redis:6379`, el nombre del servicio y el puerto de ADENTRO, porque
RedisInsight esta en la misma red de Docker y para el `localhost` es el mismo
RedisInsight.

## Neo4j: el grafo de cuentas, resenas y productos

Es la base de grafos de la Entrega 2. El corazon del modelo son tres tipos de
nodo:

```
(:Usuario)-[:ESCRIBIO]->(:Resena)
(:Resena)-[:CALIFICA_A]->(:Usuario)
(:Resena)-[:SOBRE]->(:Producto)
```

**No hay un nodo `:Vendedor`**, y es obligatorio que no lo haya: en Mesh comprar
no pide rol, asi que un vendedor tambien compra. Si se partiera en `:Usuario` y
`:Vendedor`, la misma cuenta serian dos nodos distintos y el anillo de fraude
nunca cerraria. Hay un cuarto tipo, `:Direccion`, con
`(:Usuario)-[:VIVE_EN]->(:Direccion)`, para que "dos cuentas en la misma casa" sea
literalmente un vecino compartido. El por que de cada decision esta en
`neo4j/README.md`.

Y es una **proyeccion** de PostgreSQL, no una fuente de verdad: se puede borrar
entero y reconstruir. Nada se escribe ahi que no exista en PostgreSQL.

**Dos puertos, y hacen falta los dos:**

| Puerto | Que es |
|---|---|
| 7474 | la ventana del navegador, que Neo4j trae adentro. No hay que montar un visor aparte |
| 7687 | bolt, el protocolo por el que hablan `cypher-shell` y el ETL, y por el que hablaria el backend |

Abrir solo uno deja la mitad sin servir. Y la ventana del 7474 importa mas de lo
normal aqui: **dibuja** el grafo, nodos y flechas. Un anillo de cuentas que se
califican entre si no se ve en una tabla de filas.

**El usuario es siempre `neo4j`**: en la edicion community no se puede cambiar.
Por eso el `.env` solo pide la contrasena, `NEO4J_PASSWORD`, y tiene que tener al
menos 8 caracteres o Neo4j no arranca.

```bash
docker exec mesh-neo4j cypher-shell -u neo4j -p $NEO4J_PASSWORD "RETURN 1;"
```

**Tarda en arrancar, y es normal.** Neo4j se toma unos 40 segundos en aceptar
Cypher; su healthcheck tiene `start_period: 40s` con 10 reintentos cada 15 s, o
sea que el propio Compose se da hasta ~190 segundos antes de declararlo enfermo.
`arrancar.ps1` lo espera hasta 240 s por eso mismo: un plazo mas corto declararia
muerto un contenedor que esta arrancando bien.

El healthcheck usa `cypher-shell` y no un HTTP contra el 7474 a proposito: el
7474 contesta antes de que la base acepte consultas, asi que daria "sano" con
Neo4j todavia arrancando y el ETL fallaria contra un contenedor en verde.

APOC viene instalado (`NEO4J_PLUGINS: '["apoc"]'`).

**A diferencia de Redis, aqui si hay un ETL**, y `arrancar.ps1` lo corre solo
cuando detecta que el grafo tiene menos de lo que dice PostgreSQL, igual que con
el catalogo de Mongo:

```powershell
.\arrancar.ps1                    # carga el grafo si falta algo
.\arrancar.ps1 -Etl               # fuerza los DOS ETL, el de Mongo y el del grafo
.\arrancar.ps1 -ReiniciarGrafo    # borra el grafo entero y lo reconstruye
```

Las consultas de fraude se corren aparte:

```bash
bash neo4j/correr_fraude.sh
```

El detalle esta en [neo4j/README.md](../neo4j/README.md) y en
[etl/README.md](../etl/README.md).

## Kibana: la ventana de Elasticsearch

No es una base, es el visor de Elasticsearch, igual que pgAdmin lo es de PostgreSQL:
http://localhost:5601, sin usuario ni contrasena. Sirve para mirar `mesh_productos`
y `mesh_eventos_autenticacion` con el buscador (Discover), los campos y las
agregaciones, sin escribir `curl`. Mesh funciona igual sin el.

- **Misma version que Elasticsearch, 8.15.3.** Kibana se niega a hablar con un
  Elasticsearch de otra version mayor.
- **Solo en local.** El puerto es `127.0.0.1:5601`: Elasticsearch corre con la
  seguridad apagada y Kibana puede leer y borrar sus indices.
- **Memoria acotada.** `NODE_OPTIONS` con tope de 640 MB y `mem_limit` de 1 GB. Gasta
  cerca de 0.7 GB reales.

Las dos vistas de datos las crea solo `mesh-kibana-vistas`, un contenedor de un solo
uso que corre `docker/kibana/vistas.sh` cada vez que se hace `docker compose up`.
Espera a Kibana y a que existan los indices, crea **Productos** (`mesh_productos`)
y **Eventos de autenticacion** (`mesh_eventos_autenticacion`, con el campo de fecha
`fecha`), y deja el rango por defecto de Discover en 60 dias. Termina en
`Exited (0)`, que es lo esperado, y se puede repetir sin miedo: una vista que ya
existe no se duplica.

`arrancar.ps1` tiene el paso 9d, "Vistas de Kibana", que espera hasta 3 minutos a
ese contenedor y muestra su log. Las vistas viven en el volumen de Elasticsearch y
no en el repositorio, asi que `.\arrancar.ps1 -Reiniciar` las borra y se recrean
solas.

## Accesos de desarrollo

| Servicio | Donde entra | Usuario | Contrasena |
|---|---|---|---|
| PostgreSQL | `localhost:5432`, base `mesh` | `DB_USER` del .env | `DB_PASSWORD` del .env |
| pgAdmin | http://localhost:5050 | `PGADMIN_EMAIL` del .env | `PGADMIN_PASSWORD` del .env |
| MongoDB | `localhost:27018`, base `mesh` | `MONGO_USER` del .env | `MONGO_PASSWORD` del .env |
| DbGate | http://localhost:3001 | sin usuario ni contrasena | |
| Redis | `localhost:6379` | `default` (se puede omitir), `inspeccion` u `operador` | `REDIS_PASSWORD`, `REDIS_INSPECCION_PASSWORD` o `REDIS_OPERADOR_PASSWORD` del .env |
| RedisInsight | http://localhost:5540 | la pagina no pide nada; entra a Redis como `inspeccion` | |
| Ollama | `localhost:11434` el de la PC, o `localhost:11435` el contenedor `mesh-ollama` | sin usuario ni contrasena | |
| Neo4j | http://localhost:7474 y bolt `localhost:7687` | `neo4j`, fijo | `NEO4J_PASSWORD` del .env |
| Elasticsearch | `localhost:9200` | sin usuario ni contrasena, solo en local | |
| Kibana | http://localhost:5601 | sin usuario ni contrasena, solo desde esta maquina | |
| ClickHouse | `localhost:8123`, consola en `/play` | `CLICKHOUSE_USER` del .env | `CLICKHOUSE_PASSWORD` del .env |

Las dos variables que agrego la Entrega 2 al `.env` son **`REDIS_PASSWORD`** y
**`NEO4J_PASSWORD`**. Ya estan en `.env.example`: quien tenga un `.env` de antes
tiene que agregarlas a mano, o Compose se detiene con "falta REDIS_PASSWORD en
.env" en vez de arrancar con valores en blanco.

Redis tiene tres usuarios (ver "Redis" arriba), pero `default` se puede omitir:
`redis-cli -a $REDIS_PASSWORD` entra con el. Neo4j si lo tiene y no se puede cambiar: en la edicion community es
siempre `neo4j`, y por eso el `.env` solo pide la contrasena.

**Ninguna contrasena de servicio esta escrita en el repositorio.** Todas viven
en el archivo `.env`, que git ignora. Por eso el primer paso de la instalacion es
copiar `.env.example` y llenarlo.

### Las cuentas de prueba

Estas si estan en el repositorio, a proposito: las crea el conjunto de datos y
existen para poder entrar en una maquina recien montada. No son de nadie y no
dan acceso a nada real.

| Correo | Rol | Contrasena |
|---|---|---|
| `tienda@mesh.com` | vendedor | `Vendedor123` |
| `ventas.norte@mesh.com` | vendedor | `Vendedor123` |
| `ventas.sur@mesh.com` | vendedor | `Vendedor123` |
| `ventas.oriente@mesh.com` | vendedor | `Vendedor123` |
| `ventas.poniente@mesh.com` | vendedor | `Vendedor123` |
| `compradora.norte@mesh.com` | comprador | `Comprador123` |
| `comprador.sur@mesh.com` | comprador | `Comprador123` |
| `admin@mesh.com` | admin | `Admin123` |

**Todas entran.** Antes los vendedores del catalogo no podian: el conjunto de
datos les dejaba un hash de bcrypt y el backend usa scrypt, en formato
`salt:hash`, asi que la comparacion los descartaba antes de mirar nada y esa
contrasena no existia para nadie. Habia que ponersela a mano despues de cada
`-Reiniciar`.

Ahora los hashes los genera el mismo scrypt que usa
`backend/src/helpers/contrasena.ts`, con un salt fijo para que el generador
escriba siempre el mismo archivo. Ya no hay nada que hacer despues de reiniciar.

Es una de esas cosas que no daban ningun error: el login simplemente decia que
la contrasena estaba mal, para siempre.

**`tienda@mesh.com` es la cuenta de la pagina.** Tiene oferta de todas las
variantes del catalogo, y su precio es el que se ensena: lo pidio el profesor,
el primero siempre es el de la pagina. Los otros cuatro vendedores ofertan un
subconjunto, asi que hay productos con un solo precio y otros con cinco.

pgAdmin entra directo en http://localhost:5050 y el servidor `Mesh` ya viene
registrado y conectado. Los dos archivos que lo logran, `servers.json` y
`pgpass`, los genera `arrancar.ps1` a partir del `.env` cada vez que corre; por
eso tampoco estan en el repositorio.

Si algun dia hay que conectarlo a mano, el host es `postgres`, no `localhost`.
pgAdmin corre dentro de Docker y para el `localhost` es el mismo pgAdmin.

## Que hay instalado en el backend

```
NestJS 11                  framework
@nestjs/platform-fastify   servidor
TypeScript 5.7
pg 8.23                    driver de PostgreSQL
```

El driver `pg` se usa con SQL directo. No hay ORM.

## Que hay instalado en el frontend

```
SvelteKit 2.63
Svelte 5.56
Vite 8
TypeScript
```

## Comandos del backend

| Comando | Que hace |
|---|---|
| `npm run start:dev` | arranca y se reinicia solo al guardar |
| `npm run start:prod` | corre el compilado de `dist/` |
| `npm run build` | compila TypeScript a `dist/` |
| `npm run lint` | revisa el codigo |
| `npm run format` | formatea el codigo |

Los scripts con nombre propio siempre llevan `run`. `npm start:dev` no existe.

## Errores comunes

**Compass o el backend ven una base de Mongo vacia y sin contrasena**

Windows puede tener un MongoDB instalado como servicio, y ese ya ocupa el
27017. Los dos pueden escuchar a la vez sin dar ningun error, pero el que
contesta en `localhost` es el de Windows: Compass conecta, no pide contrasena, y
ensena una base que no es la del proyecto.

Por eso el contenedor publica el **27018**, no el 27017. La cadena de conexion
del proyecto es:

```
mongodb://<MONGO_USER>:<MONGO_PASSWORD>@localhost:27018/mesh?authSource=admin
```

Para saber con cual estas hablando, mira la version y si te pide contrasena:

```bash
docker exec mesh-mongo mongosh --quiet --eval "db.adminCommand({buildInfo:1}).version"
```

Si una conexion no pide contrasena, no es la del proyecto.

Dentro de la red de Docker no cambia nada: DbGate y cualquier otro contenedor
siguen usando `mongo:27017`.


**npm no corre en PowerShell**

```
npm : File C:\Program Files\nodejs\npm.ps1 cannot be loaded because
running scripts is disabled on this system.
```

Solucion:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
```

Comprobar con `Get-ExecutionPolicy -Scope CurrentUser`, debe decir
`RemoteSigned`.

**El puerto 3000 esta ocupado**

```
Error: listen EADDRINUSE: address already in use 0.0.0.0:3000
```

Solucion:

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
```

**El contenedor de PostgreSQL se reinicia en bucle**

```
Counter to that, there appears to be PostgreSQL data in:
/var/lib/postgresql/data (unused mount/volume)
```

PostgreSQL 18 cambio la ruta de los datos. El volumen va montado en
`/var/lib/postgresql`, no en `/var/lib/postgresql/data`. Ya esta corregido en el
`docker-compose.yml`; no revertirlo.

**El contenedor de Neo4j se reinicia en bucle y el error no menciona Docker**

```
Failed to read config: Unrecognized setting. No declared setting with name:
PASSWORD. Cleanup the config or disable
'server.config.strict_validation.enabled' to continue.
```

Esta ya nos costo tiempo, y no se deduce leyendo el mensaje. **La imagen de Neo4j
trata CUALQUIER variable de entorno que empiece con `NEO4J_` como un ajuste de
`neo4j.conf`.** Asi que una variable llamada `NEO4J_PASSWORD` no le llega a Neo4j
como una contrasena: se traduce al ajuste `PASSWORD`, que no existe, la validacion
estricta lo rechaza y el contenedor muere antes de arrancar. Con
`restart: unless-stopped`, muere para siempre.

Se reproduce en diez segundos, y vale la pena verlo una vez:

```bash
docker run --rm -e NEO4J_AUTH=neo4j/TU_CONTRASENA -e NEO4J_PASSWORD=TU_CONTRASENA neo4j:5-community
```

Fijate en el detalle que hace dificil encontrarlo: `NEO4J_AUTH` **si** es una
variable legitima de la imagen, asi que "una variable NEO4J_ mas no puede hacer
dano" es exactamente el razonamiento equivocado.

**Por eso la variable que usa el healthcheck se llama `MESH_NEO4J_PASSWORD` y no
`NEO4J_PASSWORD`.** El healthcheck corre `cypher-shell -u neo4j -p ...` y necesita
la contrasena SOLA, mientras que `NEO4J_AUTH` la trae pegada al usuario
(`neo4j/loquesea`); hacia falta una segunda variable con el mismo valor, y el
unico nombre que sirve es uno que no empiece con `NEO4J_`. En el `.env` la
variable si se llama `NEO4J_PASSWORD` -- eso es seguro, porque el `.env` lo lee
Compose y no la imagen; lo que no puede pasar es que ese nombre entre al
contenedor.

**El backend dice que la contrasena esta mal**

```
ERROR [BaseDatosService] 28P01: la autentificacion password fallo para el usuario "meme"
```

Casi siempre es una de estas tres, en este orden.

*Hay otro PostgreSQL escuchando en el 5432.* Es la mas dificil de ver, porque
todo lo demas funciona: el contenedor arranca, las migraciones corren y
`docker exec ... psql` entra sin problema. Pasa que el PostgreSQL instalado en
Windows se ata a `127.0.0.1` y el contenedor a `0.0.0.0`; cuando el backend pide
`localhost`, Windows le da el mas especifico, o sea el nativo. El backend nunca
llega al contenedor. Se ve asi:

```powershell
Get-NetTCPConnection -LocalPort 5432 -State Listen |
  ForEach-Object { Get-Process -Id $_.OwningProcess } |
  Select-Object -Unique Id, ProcessName
```

Si ademas de `com.docker.backend` aparece `postgres`, es eso. Se detiene el
servicio con los comandos del inicio de este archivo.

Para confirmarlo, este comando sale al 5432 del host igual que el backend:

```powershell
$p = (Get-Content backend\.env | Select-String '^DB_PASSWORD=').ToString().Split('=')[1]
docker exec -e PGPASSWORD=$p mesh-postgres psql -h host.docker.internal -p 5432 -U meme -d mesh -c "select current_database();"
```

Tiene que responder `mesh`. Si da 28P01, esta llegando a otro servidor.

Ojo con el mensaje: PostgreSQL responde "password fallo" **tambien cuando el
usuario no existe**, a proposito, para no delatar que usuarios tiene. Asi que
28P01 no significa que la contrasena este mal; significa que ese servidor no te
deja entrar.

*Los dos .env no dicen lo mismo.* Son dos archivos: el de la raiz crea la base y
`backend/.env` es con el que la API se conecta. Se comprueba sin ensenar la
contrasena:

```powershell
$a = (Get-Content .env         | Select-String '^DB_PASSWORD=').ToString()
$b = (Get-Content backend\.env | Select-String '^DB_PASSWORD=').ToString()
if ($a -eq $b) { "COINCIDEN" } else { "NO COINCIDEN" }
```

*El backend quedo con el valor viejo en memoria.* `npm run start:dev` se
reinicia al guardar un `.ts`, pero no al cambiar el `.env`. Despues de editarlo
hay que cortar con Ctrl+C y volver a levantarlo.

**En pgAdmin no aparece ningun servidor**

pgAdmin lee `servers.json` una sola vez, cuando crea su base de configuracion en
el volumen `pgadmin-data`. Si el volumen ya existe, `arrancar.ps1` regenera el
archivo pero pgAdmin ni lo mira. Para que un cambio surta efecto hay que recrear
ese volumen:

```powershell
docker compose rm -sf pgadmin
docker volume rm proyecto-tienda-base-datos-2_pgadmin-data
docker compose up -d pgadmin
```

Primero `.\arrancar.ps1`, que regenera el `servers.json`, y despues el borrado.
Al reves no sirve. Esto no toca la base de datos: el volumen de pgAdmin solo
guarda sus preferencias.

Para ver si lo cargo bien:

```powershell
docker logs mesh-pgadmin | Select-String "Loading servers", "servers.json"
```

**En pgAdmin no se ven las tablas**

Estan en la base `mesh`, en `Databases > mesh > Schemas > public > Tables`. La
base `postgres`, que es la que pgAdmin abre por defecto, esta vacia de verdad.

**pgAdmin no conecta**

Se puso `localhost` como host. Va `postgres`.
