# Seguridad y control de acceso

Quien entra a cada base, con que usuario y que puede hacer. Es el ADR-14 del
registro unico (`docs/DECISIONES.md`), y la prueba de todo esto es

```
bash seguridad/prueba_acceso.sh
```

que el 23 de octubre de 2026 dio 93 comprobaciones bien y ninguna mal (50 de
PostgreSQL, MongoDB, ClickHouse, Elasticsearch y Neo4j, y 43 de Redis, que corre
al final con `redis/prueba_acceso.sh`).

## La idea

Cada servicio entra a cada base con un usuario que solo puede lo que ese
servicio necesita. El backend lee y escribe datos, y nada mas: no crea ni borra
tablas, colecciones ni indices, no administra usuarios y no ve otras bases. Las
herramientas de inspeccion solo miran. El dueno de cada base (el usuario del
`.env`, o root en MongoDB) queda para `arrancar.ps1`, las migraciones, el ETL y
las pruebas.

Redis tiene usuarios de ACL desde el 25 de septiembre. PostgreSQL, MongoDB,
ClickHouse y Elasticsearch desde el 23 de octubre. Neo4j no puede, y abajo esta
por que.

## Los usuarios

| Base | Backend | Para mirar | Lo define |
|---|---|---|---|
| PostgreSQL | `mesh_backend`: SELECT, INSERT, UPDATE y DELETE en las tablas, secuencias y funciones. Sin DDL, sin TRUNCATE, sin crear usuarios | `mesh_lectura`: solo SELECT, sesion de solo lectura | `seguridad/postgres.sql` |
| MongoDB | `mesh_backend` con el rol a medida `mesh_backend_rol`: find, insert, update y remove en la base de la tienda | `mesh_lectura` con `read` en la base de la tienda. Lo usa DbGate | `seguridad/mongo.js` |
| Redis | `backend`: solo claves y canales `mesh:*`, sin la categoria peligrosa salvo INFO | `inspeccion`: solo lectura. Lo usa RedisInsight | `docker-compose.yml` |
| ClickHouse | `mesh_backend` con `mesh_backend_rol`: SELECT e INSERT en `mesh_eventos` | `mesh_lectura` con `mesh_lectura_rol`: solo SELECT | `seguridad/clickhouse.sql` |
| Elasticsearch | `mesh_backend` con `mesh_backend_rol`: read, write y view_index_metadata en `mesh_*`, monitor del cluster | `mesh_lectura` con `mesh_lectura_rol`: read en `mesh_*` y Kibana en solo lectura | `seguridad/elastic.sh` |
| Neo4j | `neo4j`, el unico | no existe | `docker-compose.yml` |

Redis tiene ademas `default` (los scripts y las pruebas, cualquier clave, sin la
categoria peligrosa) y `operador` (todo, para mantenimiento). Elasticsearch tiene
`elastic` (superusuario, para el arranque y el ETL) y `kibana_system` (con el que
Kibana habla con Elasticsearch).

Por que el backend de MongoDB no usa el rol de fabrica `readWrite`: tambien deja
borrar colecciones y crear indices, y el backend no lo hace nunca. Se reviso el
codigo antes de recortar: ninguna ruta crea tablas, colecciones ni indices en
ninguna base.

## Por que Neo4j no

La edicion community de Neo4j, la que usa el proyecto (`neo4j:5-community`), no
tiene control de acceso por roles. `CREATE ROLE`, `GRANT` y `DENY` son de la
edicion enterprise, que es de pago. En community todo usuario puede todo, asi
que un segundo usuario no limitaria nada. La prueba lo intenta y guarda la
respuesta:

```
Unsupported administration command: CREATE ROLE mesh_backend_rol
```

Lo que si se hizo: contrasena obligatoria (sin ella no entra nadie, tambien
probado), el navegador del 7474 solo en `127.0.0.1` y bolt (7687) como unica
puerta. Si el grafo guardara algo que no se puede reconstruir, la salida seria
la edicion enterprise o poner la consulta detras del backend; hoy es una
proyeccion de PostgreSQL que se rehace entera.

## Como se crean

Todo dentro de `.\arrancar.ps1`, paso 9f "Usuarios por servicio", en cada
arranque. Crea lo que falta y vuelve a poner contrasenas y permisos, asi que una
base que alguien cambio a mano queda igual otra vez.

- Las contrasenas nuevas (`PG_BACKEND_PASSWORD`, `MONGO_LECTURA_PASSWORD`,
  `ELASTIC_PASSWORD` y las demas, ver `.env.example`) se agregan solas al `.env`
  con un valor al azar si faltan. Nadie las escribe a mano.
- Viajan al contenedor en un archivo que se copia y se borra enseguida, nunca en
  la linea de comandos.
- Los de Elasticsearch los crea el contenedor de un solo uso `elastic-usuarios`
  del compose, porque Kibana no arranca sin la contrasena de `kibana_system` y un
  `docker compose up` a secas tambien tiene que dejarlo andando.
- Si el backend usa las bases de esta PC, el paso escribe en `backend\.env` los
  usuarios del backend. Si apunta a otra PC no lo toca.

## Modo remoto

Cada PC genera sus propias contrasenas. `usar-bases-remotas.ps1 -Ip ...` toma las
de la otra PC de `remoto\.env.remoto` (no se sube a git). Si ese archivo todavia
no trae las de los usuarios nuevos (la otra PC no corrio el arranque nuevo), usa
el dueno de cada base, como antes, para que el backend arranque igual. Cuando la
otra PC corra `arrancar.ps1`, hay que copiar de su `.env` a `remoto\.env.remoto`
estas lineas:

```
PG_BACKEND_PASSWORD  MONGO_BACKEND_PASSWORD  REDIS_BACKEND_PASSWORD
CLICKHOUSE_BACKEND_PASSWORD  ELASTIC_PASSWORD  ELASTIC_BACKEND_PASSWORD
```

y volver a correr `usar-bases-remotas.ps1 -Ip ...`.

## Puertos

| Puerto | Que | Hacia donde |
|---|---|---|
| 5432, 27018, 6379, 7687, 9200, 8123 | Las seis bases | La red, porque el modo remoto las usa por Tailscale. Todas piden usuario y contrasena. `preparar-pc-bases.ps1` abre el firewall solo para 100.64.0.0/10 |
| 5050, 3001, 5540, 5601, 7474, 9010, 11435 | pgAdmin, DbGate, RedisInsight, Kibana, navegador de Neo4j, ClickHouse nativo, Ollama en contenedor | Solo `127.0.0.1` |

Hasta el 23 de octubre Elasticsearch tenia la seguridad apagada con un comentario
que decia "solo escucha en localhost", y su puerto se publicaba a toda la red.
DbGate, sin login, entraba a MongoDB como root, tambien abierto a la red.

## Imagenes

Todas con version fija: `pgvector/pgvector:pg18`, `mongo:8`, `redis:8-alpine`,
`neo4j:5-community`, Elasticsearch y Kibana 8.15.3, `clickhouse-server:25.3`,
pgAdmin 9.17 (fijada tambien por su digest), DbGate 7.2.5, RedisInsight 3.8.0 y
Ollama 0.40.5. Antes cuatro usaban `latest` y dos PC podian correr versiones
distintas sin saberlo.

## Lo que queda

- Neo4j con un solo usuario (arriba).
- Sin TLS: entre PC el trafico va dentro de Tailscale, que ya va cifrado. Si las
  bases salieran a una red sin Tailscale, el siguiente paso es TLS en cada una.
- pgAdmin entra con el dueno de PostgreSQL, porque es la herramienta de
  administracion del equipo. Lo protegen su login y que solo escucha en la misma
  PC.
