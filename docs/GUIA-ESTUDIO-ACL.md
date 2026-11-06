# Guia de estudio, el control de acceso de Mesh

Para la presentacion final. Junta todos los controles de acceso que hay en el
codigo, con el archivo y la linea de cada pieza, lo que se hace clic en la tienda
para verlos, y las dos pruebas que pidio el profesor, entrar en vivo a cada base
con un usuario que no tiene el permiso y llamar al backend directo con Postman
para que las rutas sin permiso devuelvan 403. Las lineas son las del repositorio
al 5 de noviembre de 2026.

Todo lo de esta guia se corrio la noche del 5 de noviembre contra las bases de la
PC de Jose David. Los mensajes que aparecen abajo son los que contestaron las
bases esa noche.

## 1. Las tres capas

| Capa | Que pregunta | Donde vive | Si no tiene permiso | Informe |
|---|---|---|---|---|
| 1. Las bases, por servicio | Que puede hacer el backend o una herramienta dentro de cada base | Usuarios y roles de cada base, carpeta `seguridad/` y `docker-compose.yml` | La base rechaza el comando | 3.1 a 3.5, ADR-14 |
| 2. Las funciones, por rol | Que acciones de la tienda puede usar comprador, vendedor o admin | Tabla `rol_permiso`, migracion 050 | 403 con el permiso que falta | 3.6, ADR-26 |
| 3. Cada oferta, por persona | Que cuenta puede ver, editar o descontar una oferta ajena | Tabla `permiso_oferta`, migracion 049 | 404 sin ninguna entrada, 403 sin esa | 3.6, ADR-24 |

La capa 1 es la que pide el enunciado, control de acceso configurado en un
componente NoSQL. Ninguna base sabe que persona hay detras de una peticion,
porque todas llegan como `mesh_backend`, y por eso las capas 2 y 3 viven en la
aplicacion.

## 2. Capa 1, un usuario por servicio en cada base

### 2.1 Quien entra a cada base

El backend entra a cada base con su propio usuario, nunca con el dueno. Se ve en
`backend/.env`, lineas 5 (`DB_USER=mesh_backend`), 17 (`MONGO_USER`), 37
(`CLICKHOUSE_USER`), 51 (`REDIS_USER=backend`) y 52 (`ELASTIC_USER`). El dueno
de cada base queda para el arranque, las migraciones, el ETL y las pruebas.

| Base | Usuario del backend, puede y no puede | Usuario para mirar | Donde se crea |
|---|---|---|---|
| PostgreSQL | `mesh_backend` lee, agrega, cambia y borra filas, usa secuencias y funciones. No crea, cambia, borra ni vacia tablas ni crea usuarios | `mesh_lectura`, solo SELECT y su sesion es de solo lectura | `seguridad/postgres.sql` |
| MongoDB | `mesh_backend` con el rol a medida `mesh_backend_rol`, busca, inserta, cambia y borra documentos. No crea ni borra colecciones ni indices | `mesh_lectura` con el rol `read`, es el de DbGate | `seguridad/mongo.js` |
| Redis | `backend` solo sobre claves `mesh:*`, sin nada de la categoria peligrosa | `inspeccion`, solo lee, es el de RedisInsight | `docker-compose.yml:170` a `:205` |
| ClickHouse | `mesh_backend` con `mesh_backend_rol`, lee y agrega eventos. No borra, no cambia tablas, no ve usuarios | `mesh_lectura` con `mesh_lectura_rol`, solo lee | `seguridad/clickhouse.sql` |
| Elasticsearch | `mesh_backend` con `mesh_backend_rol`, lee y escribe documentos de `mesh_*`. No crea ni borra indices ni administra usuarios | `mesh_lectura`, lee `mesh_*` y en Kibana solo mira | `seguridad/elastic.sh` |
| Neo4j | El unico usuario, `neo4j`. La edicion community no trae roles | No existe | `docker-compose.yml:271` a `:280` |

### 2.2 Las lineas que importan

**PostgreSQL**, `seguridad/postgres.sql`
- `:36` y `:37`, los dos usuarios sin superusuario, sin crear bases y sin crear
  usuarios (`NOSUPERUSER NOCREATEDB NOCREATEROLE`).
- `:40`, `mesh_lectura` con `default_transaction_read_only = on`. Aunque alguien
  le diera un GRANT de mas, no puede escribir.
- `:47`, nadie mas que el dueno crea objetos en el esquema `public`.
- `:50` a `:53`, lo que puede cada uno sobre las tablas que ya existen.
- `:59` a `:68`, lo mismo para las tablas que creen las migraciones futuras
  (`ALTER DEFAULT PRIVILEGES`).

**MongoDB**, `seguridad/mongo.js`
- `:34` a `:39`, el rol `mesh_backend_rol` con solo cuatro acciones, `find`,
  `insert`, `update` y `remove`, sobre la base de la tienda.
- `:57` y `:58`, los dos usuarios. No se uso `readWrite` porque deja borrar
  colecciones y crear indices, y el backend nunca lo hace.

**Redis**, `docker-compose.yml`
- `:170` usuario `default` para los scripts, `~*` y `+@all -@dangerous`.
- `:180` usuario `backend`, `~mesh:*` (solo claves de la tienda), `+@all
  -@dangerous +info`.
- `:190` usuario `inspeccion`, `+@read +@connection -@dangerous`.
- `:200` usuario `operador`, todo, para mantenimiento.
- Cada usuario empieza con `reset`, asi no hereda nada del usuario de fabrica.

**ClickHouse**, `seguridad/clickhouse.sql`
- `:21` y `:22`, `mesh_backend_rol` pierde todo y recibe solo `SELECT, INSERT`
  sobre la base de eventos.
- `:25` y `:26`, `mesh_lectura_rol` solo `SELECT`.

**Elasticsearch**, `seguridad/elastic.sh`
- `:62` a `:67`, `mesh_backend_rol` con `read`, `write` y
  `view_index_metadata` sobre `mesh_*`. No tiene `create_index` ni
  `delete_index`.
- `:69` a `:77`, `mesh_lectura_rol`, solo `read`, y en Kibana solo mira.

**Neo4j**, `docker-compose.yml:271` a `:280`. `CREATE ROLE`, `GRANT` y `DENY` son
de la edicion enterprise, que es de pago. Lo que si se hizo es contrasena
obligatoria, el navegador del puerto 7474 solo en la misma PC y bolt como unica
puerta.

**Puertos.** Las herramientas solo escuchan en 127.0.0.1 (pgAdmin
`docker-compose.yml:55`, DbGate `:120`, RedisInsight `:254`, navegador de Neo4j
`:301`, Kibana `:473`). Las bases si escuchan hacia la red porque el modo remoto
las usa por Tailscale, y todas piden usuario y contrasena.

## 3. Capa 2, permisos por rol (ADR-26, migracion 050)

### 3.1 Las tablas

| Tabla | Linea | Que guarda |
|---|---|---|
| `modulo_permiso` | `migrations/050_permisos_por_rol.sql:43` | Los 17 modulos, por ejemplo ofertas o fraude |
| `permiso` | `migrations/050_permisos_por_rol.sql:55` | Los 38 permisos, cada uno de un modulo |
| `rol_permiso` | `migrations/050_permisos_por_rol.sql:70` | Que rol tiene que permiso. Llave primaria rol y permiso (`:78`). 76 filas |
| `auditoria_permiso` | `migrations/050_permisos_por_rol.sql:93` | Cada intento negado, y cada permiso dado o quitado (`:97`) |
| Vista `permisos_por_rol` | `migrations/050_permisos_por_rol.sql:206` | La matriz lista para leer |

Esta en tercera forma normal, el nombre del modulo esta una sola vez y el codigo
`modulo.accion` se arma al leer.

| Rol | Permisos |
|---|---|
| comprador | 12 |
| vendedor | 26 |
| admin | 38 |

Los 12 del comprador son `avisos.usar`, `carrito.comprar`, `carrito.usar`,
`cuenta.editar`, `cuenta.ver`, `direcciones.administrar`, `pedidos.cancelar`,
`pedidos.ver`, `productos.historial`, `productos.para_ti`, `resenas.escribir` y
`resenas.votar`. El vendedor suma los de `catalogo`, `ofertas` y `reglas`. Solo
el admin tiene `dashboard`, `fraude`, `permisos`, `reportes`, `sistema`,
`tendencias`, `usuarios` y `catalogo.buscar_todo`.

### 3.2 El camino de una peticion

1. **La ruta declara su permiso.** Ejemplo,
   `backend/src/controllers/admin/admin-permisos.controller.ts:31` y `:32`,
   `@UseGuards(SesionGuard, PermisoGuard)` y `@Permiso('permisos.ver')`. El
   decorador esta en `backend/src/decorators/permiso.decorator.ts:18`. Las 136
   rutas privadas lo tienen.
2. **SesionGuard dice quien es, o 401.**
   `backend/src/guards/sesion.guard.ts:71`. Lee la cookie `mesh_token` (`:73`),
   sin cookie 401 (`:75`), verifica la firma del token (`:83`), y pregunta a
   PostgreSQL si la cuenta sigue activa y cual es su rol de hoy (`:94`, la
   consulta es `estadoDeSesion()` en `backend/src/services/usuario.service.ts:247`).
   Si le cambiaron el rol, vale el nuevo desde esta peticion
   (`sesion.guard.ts:128` a `sesion.guard.ts:141`).
3. **PermisoGuard dice que puede, o 403.**
   `backend/src/guards/permiso.guard.ts:41`. Lee el `@Permiso` de la ruta
   (`:51`). Si la ruta no declara ninguno, niega igual (`:55` a `:63`), asi que
   olvidarse de declararlo no la deja abierta. Pregunta a la base (`:68`) y si no
   lo tiene anota el intento (`:74`) y contesta 403 con el permiso que falta
   (`:81`).
4. **La pregunta a la base.** `PermisosService.tiene()` en
   `backend/src/services/acl/permisos.service.ts:106`. Es un `SELECT EXISTS` sobre
   `rol_permiso` unida con `permiso` y `modulo_permiso` (`:110` a `:118`).
5. **El registro.** `registrarNegado()` en
   `backend/src/services/acl/permisos.service.ts:176` escribe en
   `auditoria_permiso` quien, su rol, el permiso, el metodo y la ruta.

Si PostgreSQL no responde, `tiene()` usa una copia de la matriz en memoria
(`permisos.service.ts:126` a `:132`) que se refresca cada 60 segundos
(`REFRESCO_COPIA_MS` en `permisos.service.ts:25`, `refrescarCopia()` en
`permisos.service.ts:71`). Asi la tienda no se queda sin control de acceso
durante una caida.

`permisos.ver` y `permisos.administrar` no se le pueden quitar al admin
(`protegidoPara()` en `permisos.service.ts:35`), para que nadie se quede fuera
de la matriz.

### 3.3 Donde se ve en la tienda

- **Panel del admin, pestana Permisos.** Es
  `frontend/src/lib/PanelPermisos.svelte`, la matriz con una casilla por rol y
  permiso (`:156`) y la lista **Lo ultimo que paso** (`:173`) con los intentos
  negados. Desmarcar una casilla llama a `POST` o `DELETE
  /admin/permisos/:idRol/:idPermiso` (`backend/src/controllers/admin/admin-permisos.controller.ts:61`
  y `:86`) y vale en la peticion siguiente, sin compilar ni reiniciar.
- `GET /usuario/yo` devuelve los permisos de la cuenta, y el frontend solo
  esconde lo que no tiene. Esconder un boton no es seguridad. Aunque alguien
  llame la ruta directo, el backend niega con 403, y eso es lo que ensena
  Postman.

## 4. Capa 3, ACL por oferta (ADR-24, migracion 049)

| Pieza | Archivo y linea | Que hace |
|---|---|---|
| Tipos de permiso | `migrations/049_acl_ofertas.sql:36` | ver, editar y descuento |
| La lista de cada oferta | `migrations/049_acl_ofertas.sql:61` | Quien puede que, quien se lo dio y hasta cuando. No se le puede dar a si mismo (`:87`) ni repetir (`:89`) |
| El registro | `migrations/049_acl_ofertas.sql:107` | Cada permiso dado, quitado, vencido o negado |
| El decorador | `backend/src/decorators/permiso-oferta.decorator.ts:26` | `@PermisoOferta('editar')` en la ruta |
| El guard | `backend/src/guards/permiso-oferta.guard.ts:42` | Le pregunta a `comprobar()` y deja la oferta resuelta para el controller |
| La pregunta | `backend/src/services/acl/acl-ofertas.service.ts:83` | Sin ninguna entrada, 404 como una oferta que no existe (`:132`). Con alguna pero no esa, 403 (`:134`) |
| Las rutas | `backend/src/controllers/compartidas/ofertas-compartidas.controller.ts:52` | `@UseGuards(SesionGuard, PermisoGuard, PermisoOfertaGuard)`, primero el rol y despues la oferta |

Por que 404 y no 403 cuando no hay ninguna entrada. Asi no se le confirma a
nadie que esa oferta existe. Cuando ya la puede ver, el 404 no tendria sentido y
contesta 403 con el permiso que le falta.

**Donde se ve.** Panel del vendedor, pestana **Ofertas**, boton **Compartir** en
una oferta (`frontend/src/lib/OfertasVendedor.svelte:2618`, el panel es
`frontend/src/lib/CompartirOferta.svelte`). La otra cuenta lo ve en la pestana
**Compartidas** (`frontend/src/lib/OfertasCompartidas.svelte:149`).

## 5. Prueba en vivo en las bases, sin script

Lo que pidio el profesor. Se entra a cada base con un usuario que no tiene el
permiso, se ensena que si puede lo suyo y que la base rechaza lo demas. Nada de
esto puede danar la tienda aunque la configuracion estuviera mal, porque lo que
borraria algo se intenta dentro de una transaccion que se deshace, sobre algo que
no existe o con una condicion que no toca ninguna fila.

Las contrasenas son las del `.env` de la PC de las bases (`PG_LECTURA_PASSWORD`,
`PG_BACKEND_PASSWORD`, `MONGO_LECTURA_PASSWORD`, `MONGO_BACKEND_PASSWORD`,
`REDIS_INSPECCION_PASSWORD`, `REDIS_BACKEND_PASSWORD`,
`CLICKHOUSE_LECTURA_PASSWORD`, `CLICKHOUSE_BACKEND_PASSWORD`,
`ELASTIC_LECTURA_PASSWORD`, `ELASTIC_BACKEND_PASSWORD` y `NEO4J_PASSWORD`).
Nunca se escriben en el repositorio. Cada cliente las pide al entrar.

### 5.1 En la PC de Jose David, donde viven las bases

En PowerShell. `docker exec -it` abre el cliente de verdad dentro de cada
contenedor.

**PostgreSQL.** Ojo, con `-h postgres` y no con `localhost`. Dentro del
contenedor `localhost` entra sin contrasena y no probaria nada.

```
docker exec -it mesh-postgres psql -h postgres -U mesh_lectura -d mesh
```

```sql
SELECT current_user, count(*) AS pedidos FROM pedido;      -- si, devuelve los datos
UPDATE pedido SET id_pedido = id_pedido WHERE false;         -- no
DELETE FROM rol_permiso WHERE false;                         -- no
```

Contesta `ERROR:  cannot execute UPDATE in a read-only transaction`. Despues,
`\q` y entrar como el backend.

```
docker exec -it mesh-postgres psql -h postgres -U mesh_backend -d mesh
```

```sql
SELECT current_user;                       -- mesh_backend
CREATE TABLE intruso (x int);              -- permission denied for schema public
CREATE ROLE intruso;                       -- permission denied to create role
BEGIN;
DROP TABLE pedido_producto;                -- must be owner of table pedido_producto
ROLLBACK;
```

**MongoDB**

```
docker exec -it mesh-mongo mongosh -u mesh_lectura -p --authenticationDatabase admin mesh
```

```js
db.productos.countDocuments()                                  // 1003, si lee
db.productos.findOne({}, { nombre: 1 })                        // si
db.productos.updateOne({ _id: -1 }, { $set: { intruso: 1 } })  // MongoServerError, not authorized on mesh to execute command update
```

Despues como `mesh_backend` (mismo comando con `-u mesh_backend`).

```js
db.productos.countDocuments()          // si
db.prueba_acl.drop()                   // not authorized on mesh to execute command drop
db.prueba_acl.createIndex({ x: 1 })    // not authorized ... createIndexes
db.getSiblingDB('admin').system.users.findOne()   // not authorized on admin
```

**Redis**

```
docker exec -it mesh-redis redis-cli --user inspeccion --askpass
```

```
DBSIZE                 -> (integer) y un numero, si puede leer
SET mesh:prueba:acl 1  -> NOPERM User inspeccion has no permissions to run the 'set' command
DEL mesh:prueba:acl    -> NOPERM ... 'del' command
```

Despues `--user backend`.

```
GET mesh:prueba:acl    -> (nil), si puede leer lo suyo
GET otra:clave         -> NOPERM No permissions to access a key
KEYS *                 -> NOPERM User backend has no permissions to run the 'keys' command
CONFIG GET maxmemory   -> NOPERM ... 'config|get' command
```

No escribir `FLUSHALL` a ciegas. Si se quiere ensenar, primero se le pregunta a
Redis con el usuario `operador`, `ACL DRYRUN backend FLUSHALL`, que contesta
`User backend has no permissions to run the 'flushall' command` sin correr nada.

**ClickHouse**

```
docker exec -it mesh-clickhouse clickhouse-client --user mesh_lectura --ask-password --database mesh_eventos
```

```sql
SELECT count() FROM vista_producto;                                         -- si
INSERT INTO vista_producto SELECT * FROM vista_producto WHERE 0;            -- Code 497 ACCESS_DENIED
```

Como `mesh_backend` el mismo INSERT si pasa (agrega cero filas), y esto no.

```sql
ALTER TABLE vista_producto DELETE WHERE 0;                 -- Code 497 ACCESS_DENIED, necesita ALTER DELETE
CREATE TABLE intruso (x UInt8) ENGINE = Memory;            -- ACCESS_DENIED, necesita CREATE TABLE
SELECT count() FROM system.users;                          -- ACCESS_DENIED
```

**Elasticsearch**, con `curl.exe`, que pide la contrasena.

```
curl.exe -u mesh_lectura http://localhost:9200/mesh_productos/_count
curl.exe -u mesh_backend -X DELETE http://localhost:9200/mesh_prueba_acl_no_existe
curl.exe -u mesh_backend http://localhost:9200/_security/user
```

El primero da `{"count":1003,...}`. Los otros dos dan 403 con
`security_exception ... is unauthorized for user [mesh_backend]`. El indice no
existe a proposito, y el superusuario `elastic` si recibe 404 por el mismo
indice, asi que el 403 es por el permiso.

**Neo4j**

```
docker exec -it mesh-neo4j cypher-shell -u neo4j -d system
```

```
CALL dbms.components() YIELD name, versions, edition;   -- "community"
CREATE ROLE lector;                                     -- Unsupported administration command: CREATE ROLE lector
SHOW ROLES;                                             -- Unsupported administration command
```

Es la prueba de que en community no hay roles, y es lo que dice el informe.

### 5.2 Desde otra PC, por el tunel

Si se presenta desde la PC de Jose Manuel, `node remoto/tunel.cjs 100.64.42.11`
lleva los puertos de las bases a `localhost`. Las mismas ordenes, con los
clientes de esa PC.

| Base | Como se entra |
|---|---|
| PostgreSQL | `& "C:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U mesh_lectura -d mesh` |
| MongoDB | `.\remoto\herramientas\bin\mongosh.exe "mongodb://localhost:27018/mesh?authSource=admin" -u mesh_lectura -p` |
| ClickHouse | En el navegador `http://localhost:8123/play`, usuario y contrasena arriba a la derecha |
| Elasticsearch | `curl.exe -u mesh_lectura http://localhost:9200/mesh_productos/_count`, o la carpeta 6 de Postman |
| Redis y Neo4j | Mejor desde la PC de Jose David. Por el tunel solo hay clientes de Node, `node remoto\clientes\redis-cli.cjs` y `node remoto\clientes\cypher-shell.cjs` |

## 6. Prueba con Postman, 401 y 403 llamando directo

Esta en `presentacion-final/postman/`.

Postman tiene que tener la sesion iniciada. Sin cuenta solo deja mandar
peticiones sueltas, sin colecciones ni ambientes.

1. Meter la coleccion y el ambiente. Hay dos formas.
   - Con el script, desde la raiz del repo,
     `powershell -ExecutionPolicy Bypass -File presentacion-final\postman\importar-a-postman.ps1`.
     Lee las cuatro claves del `.env` de la raiz, el mismo que usan las bases
     (`ELASTIC_LECTURA_PASSWORD`, `ELASTIC_BACKEND_PASSWORD`,
     `CLICKHOUSE_LECTURA_PASSWORD` y `CLICKHOUSE_BACKEND_PASSWORD`), y las sube
     con la coleccion por la API de Postman. Pide una llave de la API, que se
     saca en Postman con la foto de perfil, **Settings**, **API keys** y
     **Generate API Key**, y no se guarda. Si ya estaban, las actualiza en vez
     de duplicarlas.
   - A mano. El mismo script con `-SinPostman` solo arma
     `presentacion-final/postman/secrets/Mesh-con-claves.postman_environment.json`
     con las claves. Despues se arrastran a Postman ese archivo y
     `Mesh-ACL.postman_collection.json`. La carpeta `secrets/` no se sube a git.
2. Elegir el ambiente **Mesh, claves de las bases** arriba a la derecha.
3. Correr todo con **Run** y **Start run**, o las carpetas en orden, de arriba
   hacia abajo. Cada carpeta empieza entrando con su cuenta, y Postman guarda la
   cookie `mesh_token` y la manda en las siguientes. Cada peticion trae su
   prueba en la pestana **Scripts**, y **Test Results** dice si dio el codigo
   esperado.

| Carpeta | Que ensena | Codigos |
|---|---|---|
| 0 | Salir, por si quedo una sesion | 200 |
| 1. Sin sesion | Sin cookie el backend no deja pasar | 401 |
| 2. Comprador | Entra, ve lo suyo, y todo lo de vendedor y admin da 403 con el permiso que falta | 200 y 403 |
| 3. Vendedor | Ve sus ofertas, y todo lo de admin da 403 | 200 y 403 |
| 4. Admin | La matriz, 3 roles y 38 permisos, y el registro con los 403 de arriba | 200 |
| 5. Una oferta | Sin entrada 404, con ver 200, editar sin permiso 403, y se quita al final | 404, 201, 200, 403 |
| 6. Elasticsearch directo | Sin usuario 401, `mesh_lectura` lee pero no escribe, `mesh_backend` no crea ni borra indices ni ve usuarios | 401, 200, 403 |
| 7. ClickHouse directo | `mesh_lectura` lee pero no agrega, `mesh_backend` no borra, no crea tablas, no ve usuarios | 200 y ACCESS_DENIED |
| 8. Inyeccion SQL | `' OR '1'='1' --` en el login, `admin@mesh.com' --` para saltarse la clave, `1 OR 1=1` como id de pedido y `DROP TABLE usuario` en el buscador. Al final la cuenta se sigue leyendo de la tabla `usuario` | 401, 400 y 200 |

ClickHouse no usa 403 por HTTP. Niega con su codigo 497 `ACCESS_DENIED` y
responde HTTP 500. Las pruebas de la carpeta 7 revisan ese texto.

Cada carpeta lleva un control que si pasa. Que el comprador no pueda ver la
matriz solo dice algo si el mismo comprador si puede ver sus pedidos, y que
`mesh_backend` no pueda crear un indice solo dice algo si si puede escribir en
uno. Sin los controles, un backend caido haria pasar todas las negativas.

La carpeta 5 cambia datos y los devuelve. Usa a ventas.oriente, que no tiene
nada compartido, sobre la oferta 3 de ventas.norte, y al final le quita el
permiso. El cambio de precio manda el mismo precio que ya tiene.

La carpeta 8 no prueba permisos sino la forma de armar las consultas. El login
busca con `WHERE correo_electronico = $1 OR usuario = $1`
(`backend/src/services/usuario.service.ts:137`) y manda lo escrito aparte, como
un valor (`:138`). PostgreSQL lo compara entero y nunca lo lee como SQL, asi que
`' OR '1'='1' --` es solo un correo que no existe. Los id se revisan antes de
tocar la base, solo digitos o 400
(`backend/src/services/compradores/pedidos.service.ts:120`). En el buscador
cualquier texto vale, por eso ahi el control es la peticion siguiente, que lee
la cuenta de la tabla que el `DROP TABLE` habria borrado.

Corrida completa el 6 de noviembre con Newman, la version de terminal de
Postman, y con el Runner dentro de Postman, 62 peticiones y 62 pruebas en verde.

## 7. Las pruebas automaticas

| Prueba | Que comprueba | Ultimo resultado |
|---|---|---|
| `bash seguridad/prueba_acceso.sh` | Las cinco bases con roles y Neo4j, cada negativa con su control | 93 OK, 50 de las bases mas las 43 de Redis, el 5 de noviembre |
| `bash redis/prueba_acceso.sh` | Los cuatro usuarios de Redis | 43 OK, el 5 de noviembre |
| `bash pruebas/permisos_rol.sh` | Los tres roles contra las rutas, quitar y devolver permisos en vivo, cambio de rol con la sesion abierta | 171 OK, el 5 de noviembre |
| `node pruebas/permisos_cobertura.cjs` | Que con la tabla entran a cada ruta los mismos roles que antes de la 050 | 12 OK, el 5 de noviembre |
| `bash pruebas/acl_ofertas.sh` | Cada regla del ACL por oferta | 85 OK |
| `.\demo-entrega-final.ps1 -Parte acceso`, `-Parte permisos`, `-Parte compartir` | Las demos del panel de comandos | |

## 8. Preguntas que puede hacer el profesor

**Donde esta el control de acceso que pide el enunciado.** En la capa 1. Cada
base NoSQL tiene un usuario por servicio con lo minimo que necesita, y se
comprueba entrando con un usuario que no tiene el permiso.

**Por que el backend no entra como el dueno.** Si alguien rompe el backend, con el
dueno podria borrar tablas o crear usuarios. Con `mesh_backend` solo puede lo que
la tienda hace todos los dias.

**Que pasa si un comprador llama la ruta del admin con Postman.** `SesionGuard` lo
deja pasar porque si tiene sesion, `PermisoGuard` pregunta a `rol_permiso`, no
encuentra `permisos.ver` para el rol comprador y contesta 403 con el permiso que
falta. El intento queda en `auditoria_permiso` y el admin lo ve en Permisos.

**Que pasa si el admin le baja el rol a alguien con la sesion abierta.** Vale en su
peticion siguiente. `SesionGuard` lee el rol de la base en cada peticion, no del
token (`sesion.guard.ts:128`).

**Que pasa si una ruta nueva se olvida de declarar su permiso.** Se niega con 403
(`permiso.guard.ts:55`), y `pruebas/permisos_cobertura.cjs` avisa.

**Que pasa con los permisos si se cae PostgreSQL.** El guard usa la copia de la
matriz en memoria, refrescada cada 60 segundos, y la tienda sigue negando lo que
no se puede.

**Por que Neo4j no tiene usuario por servicio.** La edicion community no trae
roles. Se probo en vivo, `CREATE ROLE` contesta `Unsupported administration
command`.

**Es un ACL de verdad la capa 2.** Si, la lista esta en la base, lo que no esta se
niega, y se cambia sin compilar.

**Por que la capa 3 no la hace la base.** La base no conoce a las personas de la
tienda, todas las peticiones llegan como `mesh_backend`.
