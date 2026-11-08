# Seguridad y control de acceso

Son tres capas, y cada una contesta una pregunta distinta:

| Capa | La pregunta | Donde vive | Quien la hace cumplir | Si no | Decision |
|---|---|---|---|---|---|
| Las bases, por servicio | Que puede hacer el backend (o una herramienta) en cada base | Usuarios y roles de cada base | Cada base | La base rechaza el comando | ADR-14 |
| Las funciones, por rol | Que acciones de la tienda puede usar cada rol | `rol_permiso` en PostgreSQL (migracion 050) | `PermisoGuard` en cada ruta privada | 403 con el permiso que falta | ADR-26 |
| Cada oferta, por persona | Que cuenta puede ver, editar o descontar una oferta ajena | `permiso_oferta` en PostgreSQL (migracion 049) | `PermisoOfertaGuard` en `/compartidas/ofertas` | 404 sin ninguna entrada, 403 sin esa | ADR-24 |

Antes de las tres, `SesionGuard` dice quien es la cuenta (401 si nadie, si el
token es falso o vencio, o si la cuenta ya no esta activa). Se probo llamando a
las rutas DIRECTO, sin la pagina: `bash pruebas/permisos_rol.sh` y la demo
`.\demo-entrega-final.ps1 -Parte permisos`.

## Las bases

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

## Las funciones, por rol

Lo de arriba es por SERVICIO, y lo hacen cumplir las bases. Ninguna base sabe
que persona esta detras de una peticion: todas llegan como `mesh_backend`. Lo
que puede hacer cada cuenta dentro de la tienda lo decide la aplicacion. Hasta
el 28 de octubre la lista de que rol puede que estaba escrita en el codigo, con
`@Roles(...)` en cada controller. Desde la migracion 050 (ADR-26) vive en
PostgreSQL y el backend la consulta en cada peticion.

- **Las acciones.** `modulo_permiso` (17 modulos: ofertas, carrito, fraude...) y
  `permiso` (38 acciones, cada una en su modulo). El codigo de una accion es
  `modulo.accion`, por ejemplo `ofertas.publicar`.
- **La lista.** `rol_permiso`: una fila por rol y accion, con quien la dio y
  cuando. Lo que no esta se niega. `SELECT * FROM permisos_por_rol;` la ensena
  como matriz, una fila por accion y una columna por rol.
- **Quien la revisa.** `PermisoGuard`, despues de `SesionGuard`, en cada una de
  las 146 rutas privadas. Cada ruta declara su accion con `@Permiso(...)` y el
  guard le pregunta a `rol_permiso` en ese momento si el rol de la cuenta la
  tiene. Si no, 403 con el codigo que falta ("No tienes permiso para hacer esto
  (falta ofertas.publicar)"). Una ruta privada sin `@Permiso` tambien se niega.
- **Al instante.** Quitar o poner una fila vale en la peticion siguiente, sin
  compilar ni reiniciar. Se puede hacer con SQL o desde el panel del admin,
  seccion Permisos (`/admin/permisos`).
- **Lo que no se quita.** Por la API, `cuenta.ver` a nadie (la sesion no abriria)
  ni `permisos.ver` y `permisos.administrar` al admin (nadie podria devolverlos).
  Con SQL a mano si.
- **El registro.** `auditoria_permiso` guarda cada intento negado con su metodo
  y su ruta, y cada permiso dado o quitado con quien lo hizo.
- **Sin PostgreSQL.** El guard usa la ultima matriz que leyo entera (al arrancar
  y cada minuto), igual que la sesion se cree a su token cuando PostgreSQL esta
  caido.

La semilla de la 050 deja pasar exactamente a los mismos roles que los `@Roles`
de antes, ruta por ruta. `node pruebas/permisos_cobertura.cjs` lo comprueba
contra la matriz guardada antes del cambio (`pruebas/permisos_matriz_antes_050.json`),
y tambien que cada ruta privada lleve el guard y un permiso que exista.
`bash pruebas/permisos_rol.sh` llama a las rutas directo con los tres roles, los
42 permisos cada uno, quita y devuelve permisos en vivo, y le cambia el rol a una
cuenta con la sesion abierta para ver que vale en la peticion siguiente (171
comprobaciones el 2026-11-02, con las bases de la PC de Meme).

Desde el 2026-11-07 hay cuatro permisos mas, los dos solo del admin, para lo que la
tienda gestiona en el panel: `pedidos.administrar` (051, cancelar cualquier pedido y
marcarlo enviado o entregado), `resenas.moderar` (052, ocultar una resena sin
borrarla), `ofertas.administrar` (053, pausar, retirar o ajustar la oferta de
cualquier vendedor) y `catalogo.categorias` (054, crear categorias, renombrarlas y
agregarles caracteristicas). Se reparten igual que los de la 050, solo la primera vez
que se crean, y `rol_permiso` pasa de 76 a 80 filas. Son diez rutas mas, de 136 a 146.
Las prueban `pruebas/pedidos_tienda.mjs`, `resenas_moderar.mjs`, `ofertas_tienda.mjs`
y `categorias_tienda.mjs`, cada una con su 401 y su 403.

## Cada oferta, por persona

Los roles dicen que puede hacer una cuenta con lo suyo. Que otra cuenta pueda
tocar una oferta ajena lo dice un ACL de verdad por oferta (ADR-24, migracion
049), desde el 26 de octubre.

- **La lista.** `permiso_oferta`: una fila por oferta, cuenta y permiso (`ver`,
  `editar` o `descuento`), con quien lo dio y hasta cuando. Pegada al objeto,
  como un ACL clasico. Lo que no esta se niega.
- **Quien la revisa.** `PermisoOfertaGuard`, despues de `SesionGuard` y de
  `PermisoGuard` (el rol tiene que tener `ofertas.usar_compartidas`), en cada
  ruta de `/compartidas/ofertas`. Busca una entrada vigente de esa cuenta, esa
  oferta y ese permiso. Sin ninguna entrada contesta 404, el mismo de una oferta
  ajena, para no confirmar que existe. Con alguna, pero no la que pide la ruta
  (ve la oferta pero no puede editarla), 403 con el permiso que falta. Los dos
  quedan anotados. Tambien a un admin: negar por defecto no tiene excepciones.
- **Cada permiso por separado.** Cualquier entrada deja ver; `editar` cambia
  precio y existencia (no el estado); `descuento` pone y quita el descuento.
- **Quien reparte.** Solo el dueno de la oferta, o un admin a nombre de la
  tienda, en `/vendedor/ofertas/:id/permisos`. Nadie se da permisos a si mismo
  (tambien es un CHECK de la tabla) y solo se comparte con cuentas de vendedor o
  de admin.
- **Lo propio no cambia.** `/vendedor/ofertas` sigue con su regla de dueno. Un
  permiso compartido no la abre; lo compartido va solo por sus rutas.
- **El registro.** `auditoria_permiso_oferta` guarda cada permiso dado o
  quitado, cada cambio hecho por la via compartida (a nombre del dueno, con
  quien lo hizo de verdad) y cada intento negado con su motivo. El dueno lo ve
  en el panel de compartir.

En la tienda: boton Compartir en cada oferta de Ofertas, y la seccion
Compartidas para quien recibe. Pruebas: `bash pruebas/acl_ofertas.sh` (85
comprobaciones, cada regla una vez) y `node pruebas/acl_ofertas_azar.mjs`
(cientos de vueltas al azar contra un modelo de lo que deberia contestar).

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
todas las contrasenas. Nadie las sabe de memoria porque las genero el arranque,
asi que en la otra PC, en la carpeta del proyecto, se copian todas de una vez:

```powershell
Select-String -Path .env -Pattern '_PASSWORD=' | ForEach-Object Line | Set-Clipboard
```

El backend necesita las seis `*_BACKEND_PASSWORD` y `ELASTIC_PASSWORD`. Las de
`mesh_lectura`, `KIBANA_PASSWORD` y las de `inspeccion` y `operador` de Redis las
usan la prueba de acceso y las demos. Despues se vuelve a correr
`usar-bases-remotas.ps1 -Ip ...`.

Medido el 23 de octubre contra la PC de Jose David: el backend entra con
`mesh_backend` (y `backend` en Redis) en las cinco bases, y `seguridad/prueba_acceso.sh`
en modo remoto da 93 OK, 0 FALLA.

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
- El rol que cuenta en el ACL de funciones es el de la base, no el del token
  (desde el 2026-11-02). `SesionGuard` lo trae en la misma consulta con que
  revisa que la cuenta siga activa, asi que si el admin le cambia el rol a una
  cuenta, vale en su peticion siguiente. Solo con PostgreSQL caido se usa el
  rol del token, el ultimo que se conoce, igual que la sesion se cree a su
  token. Antes valia el del token y el cambio tardaba hasta 2 horas.
- Sin TLS: entre PC el trafico va dentro de Tailscale, que ya va cifrado. Si las
  bases salieran a una red sin Tailscale, el siguiente paso es TLS en cada una.
- pgAdmin entra con el dueno de PostgreSQL, porque es la herramienta de
  administracion del equipo. Lo protegen su login y que solo escucha en la misma
  PC.
