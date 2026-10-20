# remoto

El **modo remoto**: correr las pruebas, los ETL y las demos desde esta PC con
las bases en otra (la de Jose David, por Tailscale, `100.64.42.11`), sin
cambiarles una linea. La laptop de Meme no siempre aguanta las seis bases; asi
el backend, el frontend y las pruebas corren aqui y las bases alla. Hecho el
2026-10-19 (el 08-10 se hizo lo mismo en una carpeta temporal y se perdio) y
medido entero contra la PC de Jose David esa misma noche (ver Medido, abajo).

## Como funciona

Las pruebas hablan con las bases por `docker exec mesh-<base> <cliente>` y
algunas directo con `localhost` (curl al 9200, python al 8123). Aqui no hay
contenedores, asi que:

- **`tunel.cjs`** lleva los puertos de localhost a la otra PC: 5432, 27018,
  6379, 7687, 8123 y 9200, y ademas el 27017 (el de Mongo DENTRO de su
  contenedor) al 27018 de alla.
- **`bin/docker`** es un docker falso. `docker exec mesh-postgres psql ...`
  corre psql AQUI, con el mismo ambiente que tendria dentro del contenedor
  (`POSTGRES_USER`, `MONGO_INITDB_ROOT_USERNAME`...), y el cliente va a
  localhost, que el tunel lleva alla. Lo que trae cualquier contenedor (`true`
  para ver si esta, `cat`, `rm`, `ls`...) tambien corre aqui. `docker cp` copia
  a `/tmp` de Git Bash, y las carpetas que monta el docker-compose
  (`/migrations`, `/mongo`, `/neo4j`) se traducen a las del repo. `docker ps`
  (tambien con `--filter name=^mesh-redis$`) e `inspect` dicen que los seis
  estan arriba; `docker compose up` no hace nada. En PowerShell lo mismo, por
  `bin/docker.ps1`.
- **Los clientes** de `bin/`:

| Cliente | Que es |
|---|---|
| `psql`, `pg_isready` | Los de verdad de PostgreSQL para Windows (`C:\Program Files\PostgreSQL\<version>\bin`). psql le quita los `\r` a la salida, pasa por un archivo un `-c` con acentos (Windows se los cambia a la pagina ANSI) y, en un guion por stdin, cambia `\o /dev/null` por `NUL` y `\o /tmp/...` por el `/tmp` de aqui |
| `mongosh`, `mongodump`, `mongorestore` | Los oficiales para Windows, que baja `instalar.sh` a `herramientas/` (no se sube). mongosh cambia cada `'/tmp/` de un guion (`--file`) o de un `--eval` por el `/tmp` de aqui, en una copia: `etl/cargar.js` lee `'/tmp/mesh-productos.json'` y para el mongosh de Windows eso es `C:\tmp` |
| `redis-cli` | `clientes/redis-cli.cjs`: RESP directo por el socket |
| `redis-benchmark` | `clientes/redis-benchmark.cjs`: abre las `-c` conexiones de verdad (y la de la configuracion, como el de verdad), una peticion en el aire por conexion, `__rand_int__` y `-r`. Lo usa `redis/prueba_concurrencia.sh` |
| `clickhouse-client` | `clientes/clickhouse-client.cjs`: por HTTP (8123) |
| `cypher-shell` | `clientes/cypher-shell.cjs`: con el driver del backend |

Los de Node se midieron contra los del contenedor y escriben lo mismo, byte a
byte, en lo que usan las pruebas: redis-cli en crudo (el nil como linea vacia,
el error con su texto y una linea vacia, la salida con 0), el formato `plain`
de cypher-shell (textos entre comillas, `TRUE`/`NULL`, los mapas en el orden de
un HashMap de Java, la hora como la escribe Java), lo de clickhouse-client
(parametros, `--multiquery` por stdin, INSERT con datos por stdin, el codigo
del error como salida) y la cuenta de conexiones de redis-benchmark (50
conexiones de la carga con `-c 50`, igual que el del contenedor).

## Una vez

```bash
bash remoto/instalar.sh
```

Baja mongosh 2.3.8 y las MongoDB Database Tools 100.10.0 (unos 180 MB). Hace
falta tambien el cliente de PostgreSQL para Windows (con el instalador de
PostgreSQL basta; el servicio puede quedar parado).

## Cada vez

1. Tailscale prendido en las dos PC, y las bases arriba en la otra
   (`.\arrancar.ps1` alla).
2. El Docker local apagado: el tunel necesita sus puertos. Si Docker Desktop
   esta abierto, cerrarlo y `wsl --shutdown`.
3. El backend apuntando alla y arriba aqui:

   ```
   .\usar-bases-remotas.ps1 -Ip 100.64.42.11
   cd backend ; npm run start:dev
   ```

   y `ollama serve` (la busqueda hibrida, la de intencion y los vectores de las
   resenas lo piden en localhost).

4. En Git Bash, para las pruebas:

   ```bash
   source remoto/activar.sh
   bash pruebas/correr_todas.sh
   source remoto/desactivar.sh
   ```

   En PowerShell, para las demos:

   ```
   . .\remoto\activar.ps1
   .\demo-evento-fraude.ps1 -Tipo viaje_imposible
   . .\remoto\desactivar.ps1
   ```

Activar pone ademas `SIN_CAIDA=1`: las pruebas que tumban una base a proposito
se saltan esa parte (ver abajo). Desactivar la quita.

5. El panel de comandos (`.\panel-comandos.ps1`, y la pestana Comandos de las
   cuentas `desarrollador*`) lo hace solo: si `backend/.env` apunta a otra PC,
   cada demo corre con el modo remoto puesto y se quita al terminar, el estado
   de las seis bases se mira en esa PC, y lo que arranca o rehace bases (y las
   demos de otro pais, que usan los contenedores de Tor de aqui) se niega con un
   aviso. La cuenta `desarrollador1@mesh.com` la crea `demo-anillo-resenas.ps1`
   en la base que se use: en una base nueva hay que crearla otra vez.

## Apagar una base para el backend (el interruptor)

Desde el 2026-10-20, para mostrar en vivo que la tienda sigue con una base caida
(lo pidio el profesor) sin tocar la PC que la tiene:

```
.\remoto\caidas.ps1 -Accion levantar            interruptor + backend apuntado a el (~3 min)
.\remoto\caidas.ps1 -Accion apagar   -Base redis
.\remoto\caidas.ps1 -Accion congelar -Base mongo
.\remoto\caidas.ps1 -Accion prender  -Base redis
.\remoto\caidas.ps1 -Accion estado
.\remoto\caidas.ps1 -Accion quitar               backend directo a las bases otra vez
```

`interruptor.cjs` reenvia un puerto de aqui a cada base (los de siempre mas
10000, Mongo al 37018) y se controla por HTTP en `127.0.0.1:5198`. El backend se
arranca con `DB_HOST`, `MONGO_PORT`, etc. apuntando a esos puertos (dotenv no
pisa lo que ya esta en el ambiente, `backend/.env` no se toca). **Apagada** deja
de escuchar y corta las conexiones (como un `docker stop`); **congelada** acepta y
no contesta (la red cortada, lo que se vio el 19-10 con la PC de Jose David). El
destino es el `DB_HOST` de `backend/.env`, asi que sirve igual con el Docker de
aqui. Lo mismo esta en el panel de comandos, grupo Caida de una base, y
`node pruebas/caidas.mjs [--congeladas]` lo recorre solo (47 OK en las dos formas
el 20-10). Lo que pasa con cada base: `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md`.

## arrancar.ps1 y el panel en remoto (desde el 2026-10-20)

`arrancar.ps1` corre entero contra las bases de la otra PC, igual que alla:
migraciones, catalogo en MongoDB, copia del catalogo, ClickHouse, vectores,
indices de Elasticsearch y grafo. El docker falso hace sus `docker exec`;
`compose up`, `info` y `volume create` no hacen nada. Asi se siembran y se
borran productos desde esta PC:

```powershell
. .\remoto\activar.ps1
.\arrancar.ps1 -Productos 5               # o -ProductosMongo 5, -Borrar todos -Semilla 2, -Etl
. .\remoto\desactivar.ps1
```

El panel de comandos (cuenta desarrollador) hace lo mismo solo: activa el modo
remoto, corre el comando y lo desactiva. Probado el 20-10 con 5 y con 3
productos, generados y borrados, en PostgreSQL, MongoDB y el buscador.

Se niegan `-Reiniciar` y `-ReiniciarMongo` (en el panel, rehacer MongoDB y
borrar todo): borran volumenes de Docker, y eso se hace en la PC que tiene las
bases. El docker falso tambien niega `compose down/rm/stop`, `volume rm`, `rm`
y `run`.

## Lo que no se puede en remoto

- **Parar una base de la otra PC.** `docker stop` y `docker start` salen con 1
  (para el backend, el interruptor de arriba hace lo mismo).
  Con `SIN_CAIDA=1`, `pruebas/grafo_compras.sh` y
  `pruebas/ofertas_y_seguimientos.sh` se saltan su parte de la caida, y
  `pruebas/falla_checkout.sh`, que no es otra cosa, dice SIN MEDIR y sale con 0.
  Esas partes son de la base local.
- **Las contrasenas que alla son otras.** El arranque de la otra PC genero sus
  propias contrasenas de los usuarios `inspeccion` y `operador` de Redis, y
  `redis/prueba_acceso.sh` da FALLA en todo lo de esos dos usuarios. Van en
  `remoto/.env.remoto` (mismo formato que el `.env`, no se sube): `activar.sh`
  lo carga y pisa al `.env` de la raiz, y `desactivar.sh` lo quita. Sin ese
  archivo se pueden pasar por el ambiente antes de activar:

  ```bash
  export REDIS_INSPECCION_PASSWORD=... REDIS_OPERADOR_PASSWORD=...
  ```

## Medido

El 2026-10-19 en la noche, desde la PC de Meme contra `100.64.42.11` (directo
por Tailscale, 22 a 30 ms), con el Docker local apagado y el backend de aqui
apuntando alla. Las 38 de `pruebas/correr_todas.sh`, despues de los arreglos:

```
en verde        etl_compras 29, grafo_compras 25, recomendaciones 29, carrito 42, carrito_vencimiento 25,
                oferta_limitada 33, descuentos 98, reglas_descuento 44, reglas_periodo 61,
                ofertas_paginadas 40, ofertas_y_seguimientos 50, busquedas_sin_resultados 13,
                busqueda 10, alertas_login 52, anillos 27, anillos_familia_b 40, eventos 31,
                tendencias 53, tendencias_avanzadas 28, etl_mongo 21, resenas 15,
                casos_fraude_fusion 0 FALLA, casos_fraude_granja 6, correr_detectores_resenas,
                correr_detectores_fraude, vectores_worker 5, clasificador_en_postgres 5, facetas.py 19,
                prueba_carrito, prueba_restaurar 20, prueba_concurrencia (50 conexiones, sin
                sobreventa), mas_vendidos, neo4j/correr_patrones, clickhouse/correr_consultas
SIN MEDIR       falla_checkout (todo es tumbar bases), las devoluciones de etl_compras (alla todas las
                escribio el backend con su IP, ninguna el ETL), busqueda parte 4, los 3 de siempre de
                ofertas_paginadas. notas.sh se dio aqui por SIN MEDIR "porque alla no hay productos
                solo en Mongo", y no era eso: si hay (1103 y 1104); el mongosh falso no traducia el
                /tmp de un guion pasado suelto. Arreglado el 20-10: 10 OK
de la otra PC   prueba_acceso 12 OK y 19 FALLA, las contrasenas de inspeccion y operador
de sus datos    recomendacion_semantica dio 14 OK y 1 FALLA: producto_catalogo tenia 102 productos (1001
                a 1102) que ya no estaban en Mongo ni tenian vector, de un -Borrar 102 en esa PC.
                migrations/lote/borrar_lote.sql no borraba de producto_catalogo (es anterior a las
                migraciones 029 y 040). Arreglado el archivo, borrados los 102 alla con permiso de Meme,
                y la prueba otra vez: 15 OK, 0 FALLA
```

Y una demo en PowerShell, `demo-evento-fraude.ps1 -Tipo multi_cuenta_ip_lenta`:
`docker ps` anclado, `docker cp` a Mongo, el historial con mongosh, el intento en
vivo y la senal confirmada en PostgreSQL.

`neo4j/correr_patrones.sh` puede dar "el grafo no quedo igual" si corre justo
detras de pruebas que crean cuentas: el backend las pasa al grafo en medio de la
prueba. Sola, o a la segunda, sale en verde. Pasa igual con la base local.

Lo que se arreglo esa noche al medir: los clientes de Node no arrancaban (node
recibia `/c/Proyectos/...` sin traducir y lo leia como `C:\c\Proyectos`; ahora
`comun.sh` le da la ruta como `C:/...`), `docker exec x true` y los demas
comandos comunes, `docker ps` con `^nombre$`, `pg_isready`, `redis-benchmark`,
el `\o` de psql y el `/tmp` de los guiones de mongosh. Fuera de `remoto/`:
`pruebas/recomendacion_semantica.py` llama al docker falso por el bash de Git
(Python en Windows no corre un script de bash, y un `bash` suelto puede ser el
de WSL), `pruebas/carrito.sh` ya no elige dos veces la misma oferta (en una base
donde la primera con stock 5 o mas tiene 8 o menos), `pruebas/etl_compras.sh`
mide las compras aunque no haya devoluciones que medir, y
`pruebas/correr_todas.sh` ya no le pasa `SALIDA` a las pruebas
(`pruebas/eventos.sh` usa una variable con ese nombre y se caia entera).
