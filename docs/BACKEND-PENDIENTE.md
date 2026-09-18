# Lo que falta del backend

Para Jose David. Todo lo de abajo es `backend/`, que nadie mas toca.

---

## LO NUEVO DEL 2026-09-15: una sola linea para que el login salga con la IP real

Ya se puede entrar a Mesh desde un celular (con VPN o sin ella) por un tunel de
Cloudflare, con `.\tunel-celular.ps1`. Lo que no es `backend/` esta hecho y
probado; la guia es `docs/ENTRAR-DESDE-EL-CELULAR.md`.

**Lo tuyo es esto, en `src/main.ts`, y nada mas:**

```ts
  const app = await NestFactory.create<NestFastifyApplication>(
    AppModule,
    new FastifyAdapter({ trustProxy: 'loopback' }),
  );
```

Sin esa linea, todo el que entra por el tunel queda como `127.0.0.1`: en
`eventos_autenticacion`, en Elasticsearch y en `alerta_fraude`. Tus contadores
por IP juntan a todo el mundo en uno solo, y cuatro personas distintas desde
sus celulares ya dan una alerta de `multi_cuenta_ip`. Medido el 2026-09-15.

### Por que `'loopback'` y no `true`, que es lo que se pedia en la seccion 5b

Con `true`, Fastify se queda con la IP de **mas a la izquierda** de
`X-Forwarded-For`, y esa la escribe el cliente. Cloudflare no borra la que trae
la peticion: le agrega la real al final. Medido detras de un tunel de verdad,
con tu misma version de Fastify, mandando `X-Forwarded-For: 1.2.3.4` desde un
nodo de Tor:

```
lo que llega:  x-forwarded-for: 1.2.3.4,192.42.116.59    socket: 127.0.0.1
trustProxy: true        -> request.ip = 1.2.3.4           (la inventada)
trustProxy: 'loopback'  -> request.ip = 192.42.116.59     (la real)
```

Con `'loopback'` Fastify solo cree lo que le llega de esta misma maquina
(`127.0.0.0/8` y `::1`, que son el tunel y el proxy de vite) y se detiene en la
primera IP de fuera. Asi resuelve tambien el cuidado de seguridad de la 5b:
alguien que llegue directo al puerto 3000 desde otra maquina no puede
inventarse la IP, porque su conexion no viene de loopback y su cabecera no se
lee. En local no cambia nada: el navegador y los arneses siguen saliendo como
`127.0.0.1`.

### Lo que YA NO hace falta

Lo que se pedia en la 5b para el celular, CORS con la direccion del tunel, ya
no hace falta. El frontend ahora pide a `/api` del mismo sitio y vite se lo
pasa al backend, asi que para el navegador la pagina y la API son el mismo
origen. Por eso tampoco hay que tocar la cookie: `sameSite: 'lax'` sirve tal
cual. El `enableCors` de `localhost:5173` puede quedarse como esta.

### Como comprobar que te quedo bien

1. Pon la linea y levanta tu backend normal en el 3000.
2. `.\tunel-celular.ps1` (sin `-ConCopia`), y abre el link desde tu celular con
   los datos moviles, no con el wifi de la casa.
3. Entra con una contrasena mala. En el panel del admin, pestana Fraude, o en
   Mongo:

   ```js
   db.eventos_autenticacion.find().sort({ fecha: -1 }).limit(1)
   ```

   tiene que salir la IP publica de tu celular. Si sale `127.0.0.1`, la linea
   no esta en el backend que contesta: mira que no haya otro proceso viejo
   escuchando en el 3000.

Cuando la pongas, `-ConCopia` sobra y los dos scripts (`tunel-celular.ps1` y
`demo-fraude-pais.ps1`) usan tu linea tal cual: si `src/main.ts` ya trae
`trustProxy`, la copia no le cambia nada.

---

## LO NUEVO DEL 2026-09-11: el fraude del login, y lo que le falta

Tu commit `e38e9a3` ya funciona fuera de tu maquina. Lo que no era `backend/`
esta hecho y medido: `migrations/016_alerta_fraude.sql` (tus tres tablas,
copiadas columna por columna de tu `fraude-login-eventos.sql`, con un candado
que falla la migracion si los ids no son los que fija `models/alerta-fraude.ts`),
`mongo/003_eventos_autenticacion.js` (la coleccion y seis indices, uno parcial
para tu worker), `elastic/002_eventos_autenticacion.json` (la PLANTILLA del
indice, que el arranque sube antes de que tu `index()` lo autocree con `ip` de
tipo `text`, que es lo que paso el primer dia), la tarjeta del panel y dos
arneses. Corre `bash pruebas/alertas_login.sh`: 51 OK el 2026-09-11.

Lo que queda es tuyo, en orden de lo que mas pesa.

### 1. Rutas que consulten Elasticsearch (lo que pidio el profesor)

El indice `mesh_eventos_autenticacion` se llena con cada login y **ninguna ruta
lo lee**. Los unicos `search` y `count` de `backend/src` son sobre
`mesh_productos`, y agregaciones hay cero. Investigar el fraude en
Elasticsearch son rutas de agregacion, y los contadores de Redis no lo son:
detectan en el momento y olvidan a los 60 o 300 segundos.

Que el indice contesta ya esta demostrado. Es la parte 6 de
`pruebas/alertas_login.sh` (`Ctrl+F` por `"aggs"`): un `terms` por `ip` con una
`cardinality` de `identificador_intentado.minusculas` adentro, que es "desde
que IP se tecleo mas de una cuenta". Usa `.minusculas` y no el campo a secas,
porque tu servicio guarda el identificador tal cual se tecleo y
`Admin@Mesh.com` y `admin@mesh.com` saldrian como dos.

Las preguntas que se ven desde aqui, como ejemplo y no como contrato:

```
desde que IP se probaron mas cuentas          terms ip + cardinality identificador
contra que cuenta se fallo mas                terms identificador.minusculas, resultado fallo
como fueron los fallos por hora               date_histogram fecha, resultado fallo
que navegador entro a mas cuentas             terms huella_cliente + cardinality id_usuario
```

Los nueve campos que arma tu `aDocumentoElastic` estan mapeados en la
plantilla, y `ip` es de tipo `ip`, asi que
acepta rangos como `127.0.0.0/8`. Si agregas un campo al evento, entra igual
pero no se puede consultar hasta mapearlo: la plantilla lleva `dynamic: false`.
Avisame y lo agrego.

### 2. El PATCH de la alerta

La tabla tiene `id_estado_alerta_fraude`, `id_usuario_reviso` y
`fecha_revision`, y el panel ya filtra por pendiente, revisada y descartada.
Falta la ruta para cambiarla: sin ella toda alerta se queda pendiente para
siempre. El panel pone los botones el dia que exista.

### 3. Los filtros de `GET /vendedor/ofertas/paginado`

La ruta funciona y pesa 12 KB la pagina de 20 contra 612 KB la lista entera de
`ventas.norte` (976 ofertas), medido el 2026-09-11. **Pero la pantalla no se
puede pasar a ella**: solo filtra `activo=true|false`, y el panel tiene una
pestana por cada uno de los cinco estados con su numero, y un buscador por
nombre, y los dos filtran en memoria sobre la lista entera. Con paginas de 20,
el buscador solo buscaria en la pagina que se ve.

Lo que haria falta: `estado` (uno de los cinco), `nombre` (producto o
variante), y en la misma respuesta los conteos por estado, que son los numeros
de las pestanas. La cola de pendientes no hace falta: hoy tiene una oferta y la
version paginada pesa mas que la entera.

### 4. Las senales que faltan

- **Muchas cuentas CREADAS desde una IP.** El registro ya guarda su ip, asi que
  el dato esta.
- **Inicios a intervalos fijos**, que es como entra un script.
- **Salto de ubicacion.** Pide geolocalizar la IP. La salida recomendada es el
  procesador `geoip` de Elasticsearch en un pipeline por defecto del indice: se
  pone en la plantilla, del lado de `elastic/`, y no toca tu codigo. En local no
  va a dar ubicacion, porque `127.0.0.1` no tiene.

### 5. Los detalles de `FraudeLoginService`

Con el trafico de una clase no se notan. Muerden el dia que haya trafico de
verdad, o el dia que alguien los busque a proposito.

- **El identificador no se normaliza.** Las mayusculas parten la cuenta:
  `fuerza_bruta_cuenta` cuenta aparte a `Admin@Mesh.com` y a `admin@mesh.com`.
- **No tiene tope de largo.** `alerta_fraude.clave` es `varchar(255)`: un
  identificador de mas hace fallar el `INSERT` y la alerta se pierde, con un
  warn en el log. Y en `multi_cuenta_ip` entran hasta 20 identificadores de
  cualquier largo al `jsonb` del detalle.
- **`INCR` y `EXPIRE` van en dos comandos.** Si el proceso cae entre los dos,
  la clave se queda sin vencimiento hasta el siguiente intento, y ese intento
  hereda la cuenta vieja: una ventana de 60 s puede acabar juntando fallos de
  horas. Un `MULTI` o un Lua los hace uno.
- **Pasado el umbral, cada intento escribe en PostgreSQL.** Un ataque sostenido
  es un `UPSERT` por intento.
- **El `ON CONFLICT` quema un id de la secuencia en cada choque.** Es inofensivo,
  pero los ids de `alerta_fraude` van a saltar.
- **`multi_cuenta_ip` cuenta textos tecleados, entradas buenas incluidas.** En
  local todo sale de `127.0.0.1`, porque el navegador, los arneses y el servidor
  corren en la misma maquina, asi que cuatro cuentas distintas en cinco minutos
  desde el mismo equipo ya dan una alerta. En local eso no cambia con nada.
  Desde el 2026-09-15 el frontend pasa por el proxy de vite y hay un tunel
  para entrar desde fuera, asi que `trustProxy` ya hace falta: ver la seccion
  de arriba del todo.
- **Un identificador vacio da 400 y cuenta igual como fallo.** Medido el
  2026-09-12: cinco `POST /usuario/login` con `"identificador": ""` contestan
  400 y dejan una alerta `fuerza_bruta_cuenta` con la clave vacia. Pasa porque
  `registrarLoginFallido` manda a los contadores tambien el `ErrorValidacion`,
  y `''` es un string y no `null`. Si una peticion mal formada no es un intento
  contra nadie, lo limpio es no contarla para la cuenta, o normalizar `''` a
  `null` antes de llamar a `registrarIntento`.
- **Con Mongo caido hay alertas sin su evidencia.** Visto el 2026-09-11: Mongo
  dejo de contestar a mitad de una prueba, los intentos no quedaron en
  `eventos_autenticacion` (el log es best-effort) y sus alertas si llegaron a
  `alerta_fraude`, porque Redis y PostgreSQL seguian arriba. El admin ve una
  alerta y no encuentra los intentos que la dispararon. No hace falta cambiarlo,
  pero conviene que el detalle de la alerta diga lo suficiente por si solo, o
  decirlo en la pantalla.

### 5b. Probado con IPs reales de tres paises (2026-09-13)

Es la prueba del tunel que pediste. Se hizo sobre una COPIA de `backend/`
fuera del repo (el tuyo no se toco), con una sola linea cambiada en
`src/main.ts`:

```ts
new FastifyAdapter({ trustProxy: true }),
```

La copia se expuso con un tunel rapido de Cloudflare
(`cloudflared tunnel --url http://localhost:3100`), y se le mandaron logins
fallidos desde tres contenedores de Tor con salida en Alemania, Japon y Estados
Unidos. Resultado, identico en Mongo, en Elasticsearch y en `alerta_fraude`:

```
185.220.100.253 (Alemania)  8 fallos, 2 correos   -> fuerza_bruta_ip
172.234.92.148  (Japon)     4 correos distintos   -> multi_cuenta_ip
204.8.96.189    (EE. UU.)   3 correos distintos   -> ninguna, no llega al umbral
```

O sea: **los tres detectores funcionan con IPs de verdad y cada IP se cuenta
aparte.** Sin `trustProxy`, detras del tunel todo habria llegado como
`127.0.0.1`, porque `cloudflared` se conecta desde la misma maquina. Si el
portal se ensena por un tunel o un proxy, esa linea hace falta. Y conviene que
el proxy sea el unico que pueda hablarle al backend: con `trustProxy: true`,
cualquiera que llegue directo puede inventarse su IP con `X-Forwarded-For`.

Un detalle para quien lo repita en esta maquina: el `~/.cloudflared/config.yml`
del tunel de LEDKID se impone sobre el tunel rapido y lo deja en 404. Se evita
pasandole `--config` con un archivo vacio.

**Corregido el 2026-09-15.** Aqui se pedia `trustProxy: true`, y para el
celular ademas CORS con la direccion del tunel. Las dos cosas quedaron
superadas: `true` deja inventarse la IP aunque se entre por el tunel, y el CORS
ya no hace falta porque el frontend va por `/api`. Lo que vale es la seccion de
arriba del todo, con `trustProxy: 'loopback'`. La demo esta en
`docs/DEMO-OTRO-PAIS.md` y el celular en `docs/ENTRAR-DESDE-EL-CELULAR.md`.

### 6. Mongo caido en el checkout

Tu `prueba-falla-mongo-checkout.md` pedia la fila 11 en
`docs/CONSISTENCIA-CHECKOUT.md`. Ya esta, citando tu documento y el arnes. Las
tres salidas siguen por decidir con el profesor.

---

## LO NUEVO DEL 2026-09-06: la base columnar ya existe y le faltan TRES rutas

Entro **ClickHouse**, la sexta base, y es lo que el profesor pidio para tendencias
y para fraude. Todo lo que no es `backend/` ya esta hecho y medido: el contenedor,
el esquema, el ETL que copia los logueos, el generador de datos de prueba, el arnes
y la pantalla. La pantalla **ya esta escrita contra las firmas de abajo**, asi que
el dia que existan se enciende sola sin tocar el frontend.

Mira `clickhouse/README.md` antes de escribir nada. Y para consultar la base a mano
hay consola web en **http://localhost:8123/play**, sin instalar nada.

Las tablas que te esperan, todas vivas y con datos:

```
vista_producto            el clic en la ficha       fecha, id_producto, id_usuario,
                                                    sesion, ip, origen, lote
evento_login              copia de log_login        fecha, id_usuario, ip, tipo,
                                                    lote, id_log_login
evento_registro           copia de log_registro     fecha, id_usuario, ip,
                                                    id_log_registro, lote
vistas_por_producto_dia   el resumen por dia        se mantiene SOLO, no hay ETL
```

**La columna `lote` no es un adorno y hay que respetarla.** Vale `real` o
`generado-<semilla>`. Hoy casi todas las vistas estan generadas, porque el portal
todavia no manda ninguna. Un panel de fraude que acusa a cuentas de la semilla por
un patron que dibujo un script es peor que no tener panel, asi que **las tres rutas
reciben el lote y lo devuelven**, para que la pantalla pueda decir de donde salen
los numeros.

### Ruta 1 -- `POST /eventos/vista` (publica, sin sesion)

Es la mas importante de las tres, porque sin ella la tabla que sostiene todo lo
demas **no se llena nunca**. La ficha del producto la llama al abrirse.

```
body  { id_producto: number, sesion: string, origen: string }
      origen es uno de: catalogo, buscador, directo
      la sesion la genera el navegador, no tiene que ser una cuenta
      si hay cookie de sesion, saca el id_usuario de ahi; si no, va null

202   no devuelve cuerpo
```

Tres cosas que conviene decidir bien porque no se ven hasta que duelen:

**No la pongas detras de la sesion.** La ficha es publica y la mitad de las visitas
interesantes son de gente sin cuenta. Exigir sesion deja fuera justo el trafico que
mas dice sobre si un producto se esta calentando.

**Contesta 202 y no 200, y no esperes a escribir.** Es un evento, no un dato de
negocio. Si ClickHouse no contesta, que se pierda esa vista y siga la pagina. Una
ficha de producto que tarda mas porque hay que anotar la visita es un mal negocio.

**Escribe por lotes si te da tiempo, pero no es lo primero.** ClickHouse prefiere
un INSERT de mil filas antes que mil INSERT de una fila. Con el trafico de una
clase da igual, pero esta anotado para el dia del millon de productos.

### Ruta 2 -- `GET /admin/eventos/tendencias` (solo admin)

```
query   dias   por defecto 7
        lote   real | generado | todo     por defecto real

200 ->  {
          desde: string, hasta: string, lote: string,
          productos: [ { id_producto: number, nombre: string | null,
                         ahora: number, antes: number, veces: number,
                         personas: number } ]
        }
```

`ahora` son las vistas de los ultimos `dias`, `antes` las del tramo anterior del
mismo largo, y `veces` es cuanto subio. `personas` son sesiones distintas, que es
lo que separa un producto de moda de uno inflado.

**Leelo de `vistas_por_producto_dia` y no de `vista_producto`.** El resumen ya esta
agregado por la vista materializada y contesta en milisegundos. Los contadores se
leen con `countMerge` y `uniqMerge`, que es la parte que sorprende a quien nunca ha
tocado un `AggregatingMergeTree`. La consulta ya escrita y medida esta en
`clickhouse/README.md`.

El `nombre` sale del catalogo de Mongo, no de ClickHouse. Si no lo encuentras, manda
`null` y la pantalla ensena el id.

### Ruta 3 -- `GET /admin/eventos/fraude/ip` (solo admin)

```
query   dias   por defecto 30

200 ->  {
          ips: [ { ip: string, cuentas: number, entradas: number,
                   registros: number, primera: string, ultima: string,
                   usuarios: string[] } ]
        }
```

Cuentas distintas que entran desde la misma IP, y cuantas nacieron ahi.

**Esta es la senal que el grafo no puede ver, y ahi esta su gracia.** Neo4j sabe que
dos cuentas se califican entre si; no sabe que las dos entran desde la misma casa a
la misma hora. Las dos senales juntas son mucho mas fuertes que cualquiera sola, y
eso es lo que hay que contar el dia de la presentacion.

**Un aviso medido, para que no te pille:** los 317 logueos REALES de `log_login`
comparten **una sola IP**, `127.0.0.1`, porque todo es desarrollo local. Filtrando
por `lote = 'real'` esta ruta va a decir que las doce cuentas del sistema son un
anillo de fraude. No esta rota, es que el dato de verdad no tiene variacion. Para
verla funcionar hace falta el lote generado, que si trae IP variadas.

**Y desde el 2026-09-10 esta ruta leeria datos congelados.** `evento_login` se
copia de `log_login`, y tu `LogService` ya no escribe ahi: los logueos van a
`eventos_autenticacion` de Mongo. El 2026-09-11 habia 24 logins en Mongo que
ClickHouse no ve. Antes de escribirla hay que decidir con el profesor si la
copia se repunta a Mongo o si el fraude por IP se hace entero en Elasticsearch
(el punto 1 de "LO NUEVO DEL 2026-09-11", al principio de este archivo) y
ClickHouse se queda solo con las vistas. Esta en
`docs/PENDIENTES.md`, punto 16.

### Protegelas como ya proteges el panel de fraude

Las dos de admin llevan `SesionGuard` mas `@Roles(ID_ROL_ADMIN)`, igual que
`GET /admin/fraude/anillos`. Ni la tienda: es un vendedor mas. La de la vista es
publica y no lleva guarda.

### Como comprobar que te quedo bien

```bash
bash pruebas/eventos.sh          el ETL y las tablas
bash pruebas/falla_checkout.sh   la prueba de falla de la Entrega 3
```

Y la pantalla: entra como `admin@mesh.com` a `/panel` y abre Tendencias. Hoy dice
"Esa opcion todavia no esta disponible en el servidor", que es el 404 de tus tres
rutas traducido. El dia que existan, se llena sola.

Lo que YA esta hecho y te espera: las tablas, los datos, los scripts de Redis,
el grafo de Neo4j y las pantallas. Nada de eso hay que escribirlo otra vez.
Lo unico que falta son las rutas HTTP que las unen.

Este documento dice **exactamente** que ruta, que recibe y que devuelve. Las
pantallas ya estan escritas contra estas firmas: si las respetas, funcionan sin
tocar el frontend.

---

## AL DIA 2026-09-04, tarde: de las cuatro de abajo ya cerraste TRES

Probadas contra el backend vivo, no leidas de tu documento:

```
409 en el PATCH con la venta relampago abierta   contesta 409 con su mensaje
apagar es_inventario_limitado al vencer          la columna pasa a false sola
resenar desde el pedido                          los dos campos llegan por linea
```

Y el frontend de esa ultima **ya esta enchufado** (boton "Resenar esta compra"
en `/pedidos`). Estuvo unas horas sin consumir, que es la tercera vez que pasa
en este proyecto.

**Lo unico que queda de la lista de abajo es el punto 2**, el del id de
producto. Tu propuesta del contador global es la buena, y ojo que ahora corre
prisa por otra razon: para la Entrega 3 se quiere probar el buscador con un
millon de productos, y generar en masa es exactamente lo que hace chocar los dos
repartidores. Hoy quedan 22 numeros de margen.

---

## LO DE HOY, al 2026-09-04 -- son cuatro cosas y la primera es de tres lineas

Lo de mas abajo en este archivo es el historial completo por bloques, y casi
todo ya esta hecho. Esto de aqui es lo que queda vivo, en orden de lo que mas
duele. El detalle largo de cada una esta en `docs/PENDIENTES.md`.

**1. Cerrar el `PATCH` de ofertas durante una venta relampago** (pendiente 8, es
lo mas urgente y es lo mas corto). Hoy `PATCH /vendedor/ofertas/:id` acepta
`ajuste_stock` con la venta relampago abierta, y ahi Redis y PostgreSQL se
separan. Si el vendedor BAJA el stock, Redis ya le prometio unidades a gente con
un ticket vivo: esa persona aparta, espera, paga, y el cobro le revienta con un
error que no explica nada. Se pide un **409 cuando venga `ajuste_stock` y la
oferta este en venta relampago**, diciendo que cierre la venta, reponga y la
vuelva a abrir. `precio` y `estado` NO hay que bloquearlos, y el porque esta
escrito en el pendiente.

**2. Decidir quien reparte el id de producto** (pendiente 5). Hay dos
numeradores sobre el mismo espacio de id -- el `bigserial` de PostgreSQL y el
"maximo de Mongo mas uno" del panel -- y cuando se crucen el ETL machaca un
producto entero **sin dar un solo error**. Desde el 2026-09-04 el arranque ya
avisa cuando el margen se acaba, asi que dejo de ser invisible, pero avisar no es
arreglar. La decision es tuya: si el id sale de una sola fuente, y de cual.

**3. Apagar `es_inventario_limitado` cuando la venta vence sola** (pendiente 7,
baja). El `EXPIRE` se lleva las claves de Redis y la columna se queda en `true`
para siempre, asi que el panel ensena "Venta relampago abierta" sobre algo que ya
no existe. Al comprador no le pasa nada y se sale con un clic en "Cerrar la
venta", por eso es baja. Las dos salidas posibles estan en el pendiente.

**4. Resenar desde el pedido** (bloque 5, mas abajo). Son DOS campos en tu
consulta de `pedidos.service.ts`, no una ruta nueva.

Y una quinta que no es un bug, por si te sobra un rato: **la nota del catalogo no
se refresca sola**. Ya alcanza a todos los productos y se apaga bien -- eso se
cerro el 2026-09-04 con una etapa nueva del ETL --, pero una resena nueva no la
mueve hasta que alguien corre el ETL. Lo barato es que tu worker del grafo, que
ya se dispara cuando se toca una resena, corra tambien `bash etl/correr.sh
--notas`. Los dos escuchan exactamente el mismo evento.

---

## Antes de nada: como comprobar que tienes con que trabajar

```bash
docker ps                        # los 6 contenedores tienen que estar arriba
docker exec -i mesh-postgres psql -U meme -d mesh -tAc "SELECT count(*) FROM resena;"
docker exec mesh-redis    redis-cli -a "$REDIS_PASSWORD" --no-auth-warning PING
docker exec mesh-neo4j    cypher-shell -u neo4j -p "$NEO4J_PASSWORD" "MATCH (n) RETURN count(n);"
```

Credenciales: **todas salen del `.env` de la raiz, que no se sube al repositorio.**
Ninguna esta escrita en este documento a proposito -- si aparecieran aqui estarian
en GitHub. Cargalas antes de correr lo de arriba:

```bash
set -a; . ./.env; set +a
```


| | usuario | contrasena | puerto |
|---|---|---|---|
| PostgreSQL | `DB_USER` del .env | `DB_PASSWORD` del .env | 5432 |
| Redis | -- | `REDIS_PASSWORD` del .env | 6379 |
| Neo4j | `neo4j` (fijo) | `NEO4J_PASSWORD` del .env | 7687 (bolt), 7474 (navegador) |

Visores en el navegador: **RedisInsight** en `localhost:5540` (ensena el TTL de
cada clave contando hacia atras) y **Neo4j Browser** en `localhost:7474` (dibuja
el grafo).

Si te falta `REDIS_PASSWORD` o `NEO4J_PASSWORD` en tu `.env`, copialas de
`.env.example`.

---

# BLOQUE 1 -- Las resenas (Entrega 1, completa el modelo)

Las tres tablas existen desde la migracion `011_resenas.sql`. Hay **90 resenas,
118 comentarios y 62 votos** sembrados, y desde el 2026-08-30 **las 90 tienen
detras una compra pagada a ese mismo vendedor** -- antes solo 2 la tenian, asi
que el boton de escribir no aparecia casi en ningun producto. Lo vigilan las
comprobaciones 10 y 11 de `001_catalogo.sql`, que fallan la migracion entera.

**Cuatro de esas 90 son el anillo de fraude** (`anillo.*@mesh.com`): tres
cuentas que se compran entre si para poder calificarse 5 estrellas en circulo.
Estan sembradas a proposito para que `GET /admin/fraude/anillos` tenga algo real
que devolver. No son un error del conjunto de datos.

## Lo que hay que saber del modelo antes de escribir la ruta

**La resena es de un VENDEDOR sobre un PRODUCTO.** No del producto solo. El
catalogo es compartido y un producto no es de nadie, asi que la resena apunta a
las dos cosas:

```
resena(id_resena, id_usuario, id_usuario_vendedor, id_producto_mongo,
       calificacion, id_comentario)
```

**El texto NO esta en `resena`.** Esta en su comentario RAIZ. `resena.id_comentario`
apunta a una fila de `comentario` con `id_comentario_padre IS NULL`, y ahi viven
el texto y la fecha. Las respuestas cuelgan de esa raiz.

**Los votos van contra `id_comentario`, no contra `id_resena`.** Asi la misma
tabla sirve para votar una resena y para votar una respuesta.

**Los contadores `cantidad_likes` y `cantidad_dislikes` no se tocan a mano.**
Los mantiene el trigger `trg_likes_recontar`, que RECUENTA en cada insert,
update y delete de `likes`. Si los actualizas desde el backend vas a pelearte
con el trigger. Solo leelos.

## `GET /productos/:id/resenas`

Publica, sin sesion. `:id` es el `id_producto_mongo`.

Pantalla que la consume: `frontend/src/lib/Resenas.svelte`.

```jsonc
{
  "ok": true,
  "mensaje": "Resenas obtenidas",
  "payload": {
    "resenas": [
      {
        "id_resena": 12,
        "id_comentario": 40,          // la RAIZ. es contra este id que se vota
        "calificacion": 5,
        "comentario": "Llego en dos dias y bien empacado.",
        "fecha_publicacion": "2026-04-18T16:02:00.000Z",
        "autor_usuario": "compradora_norte",
        "autor_correo": "compradora.norte@mesh.com",
        "vendedor_usuario": "ventas_norte",
        "vendedor_correo": "ventas.norte@mesh.com",
        "vendedor_nombre": "Carlos Ramirez",
        "voto": { "mio": 1, "a_favor": 3, "en_contra": 0 },
        "respuestas": [
          {
            "id_comentario": 41,
            "autor_usuario": "ventas_norte",
            "autor_correo": "ventas.norte@mesh.com",
            "comentario": "Gracias por la compra.",
            "fecha_publicacion": "2026-04-18T18:02:00.000Z",
            "voto": { "mio": null, "a_favor": 0, "en_contra": 0 }
          }
        ]
      }
    ],
    "resumen": {
      "total": 4,
      "promedio": 4.25,
      "reparto": { "1": 0, "2": 1, "3": 0, "4": 1, "5": 2 }
    },
    "puede_calificar": [
      { "correo": "ventas.sur@mesh.com", "usuario": "ventas_sur", "nombre": "Lucia Morales" }
    ]
  }
}
```

Tres cosas de esa forma que importan:

**`voto.mio`** es lo que voto **quien esta pidiendo**: `1`, `-1` o `null`. Sin
sesion siempre `null`. Es lo que pinta el boton encendido; sin ese campo el
usuario no ve lo que ya voto y vota dos veces.

**`resumen.reparto`** son las barras de la ficha, con las cinco claves `"1"` a
`"5"` **siempre presentes**, aunque valgan 0. Si omites una, la barra
desaparece en vez de salir vacia.

**`puede_calificar`** es la lista de vendedores de ese producto a los que **esta
cuenta todavia no ha calificado**. Es lo que llena el select del formulario.
Sale de restar: los que tienen oferta activa del producto, menos los que ya
tienen una fila en `resena` con este usuario, menos el propio usuario (el CHECK
de la tabla prohibe autocalificarse). Sin sesion, lista vacia.

Consulta de arranque:

```sql
SELECT r.id_resena, r.calificacion, r.id_comentario,
       c.comentario, c.fecha_publicacion, c.cantidad_likes, c.cantidad_dislikes,
       ua.usuario AS autor_usuario, ua.correo_electronico AS autor_correo,
       uv.usuario AS vendedor_usuario, uv.correo_electronico AS vendedor_correo,
       uv.nombre || ' ' || COALESCE(uv.apellido, '') AS vendedor_nombre
FROM resena r
JOIN comentario c ON c.id_comentario = r.id_comentario
JOIN usuarios  ua ON ua.id_usuario   = r.id_usuario
JOIN usuarios  uv ON uv.id_usuario   = r.id_usuario_vendedor
WHERE r.id_producto_mongo = $1
ORDER BY c.fecha_publicacion DESC;
```

## `POST /resenas`

Pide sesion.

```jsonc
// entra
{
  "id_producto": 12,
  "correo_vendedor": "ventas.norte@mesh.com",
  "calificacion": 5,
  "comentario": "Llego en dos dias."
}
```

Son **dos INSERT y tienen que ir en la misma transaccion**: primero el
comentario raiz, y con el id que devuelve, la resena. Si se parten, un fallo en
el segundo deja un comentario huerfano que nadie va a ver nunca.

```sql
WITH raiz AS (
  INSERT INTO comentario (id_usuario, comentario)
  VALUES ($1, $2) RETURNING id_comentario
)
INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo,
                    calificacion, id_comentario)
SELECT $1, $3, $4, $5, raiz.id_comentario FROM raiz;
```

Errores que la base ya rechaza sola, y el mensaje que conviene devolver:

| Lo que pasa | Codigo de PostgreSQL | Que contestar |
|---|---|---|
| Ya calificaste a ese vendedor por ese producto | `23505` unique_violation | 409 "Ya calificaste a este vendedor por este producto" |
| Te estas calificando a vos mismo | `23514` check_violation | 400 "No puedes calificarte a ti mismo" |
| Calificacion fuera de 1..5 | `23514` check_violation | 400 "La calificacion va de 1 a 5" |
| Comentario en blanco | `23514` check_violation | 400 "El comentario no puede estar vacio" |

**Lo que la base NO comprueba y te toca a vos:** que ese vendedor de verdad
venda ese producto. `id_producto_mongo` no tiene llave foranea porque el
catalogo vive en MongoDB -- es el mismo trato que ya tiene `oferta`, y esta
escrito en el comentario de la migracion 011. La comprobacion es:

```sql
SELECT 1 FROM oferta o
JOIN estado_oferta eo USING (id_estado_oferta)
WHERE o.id_usuario = $vendedor
  AND o.id_producto_mongo = $producto
  AND eo.estado_oferta_nombre = 'activa'
LIMIT 1;
```

**Lo que NO hay que exigir: que haya comprado.** No hay FK a `pedido` y es a
proposito -- la resena sin compra detras es la senal de fraude mas fuerte que
existe, y exigir la compra la borraria del modelo. Esta argumentado en la
cabecera de `migrations/011_resenas.sql`.

## `POST /resenas/:id/respuestas`

Pide sesion. **Solo el vendedor calificado puede contestar** (`403` a los
demas). El frontend ya apaga el boton para quien no es, pero el permiso es
tuyo.

```jsonc
{ "comentario": "Gracias por la compra." }
```

```sql
INSERT INTO comentario (id_usuario, id_comentario_padre, comentario)
SELECT $1, r.id_comentario, $2
FROM resena r WHERE r.id_resena = $3;
```

## `PUT /comentarios/:id/voto` y `DELETE /comentarios/:id/voto`

Pide sesion. `:id` es **`id_comentario`**, no `id_resena`.

```jsonc
// PUT
{ "valor": 1 }    // 1 a favor, -1 en contra
```

Cambiar de opinion es un **UPDATE**, no una fila nueva: la llave primaria es
`(id_usuario, id_comentario)`.

```sql
INSERT INTO likes (id_usuario, id_comentario, valor)
VALUES ($1, $2, $3)
ON CONFLICT (id_usuario, id_comentario) DO UPDATE SET valor = EXCLUDED.valor;
```

`DELETE` quita el voto. Los contadores se actualizan solos: el trigger.

**El rango de `valor` lo validas vos.** La columna no tiene CHECK, por decision
del equipo. El trigger cuenta exactamente `1` y `-1`, asi que un valor fuera de
rango no suma en ningun lado en vez de sumar donde no debe -- pero tampoco
tendria por que llegar.

---

# BLOQUE 2 -- Redis: el carrito (1.5 pts)

La capa de Redis esta escrita y probada en `redis/`. Leete `redis/README.md`:
tiene el diseno de claves, el TTL y la explicacion que va al informe.

Lo que falta es cambiar de donde sale el carrito.

## Como funciona hoy, y por que hay que cambiarlo

Hoy el carrito **es una fila de `pedido` en estado `pendiente`** de PostgreSQL,
y su id vive en `localStorage`. Eso tiene dos problemas que la rubrica senala:

1. **No caduca nunca.** El enunciado pide expiracion **por inactividad**. El JWT
   de 2 horas no sirve como respuesta: son 2 horas FIJAS, no inactividad. Un TTL
   de Redis que se renueva en cada toque si es exactamente lo que piden.
2. **Exige tener cuenta.** Sin usuario no hay fila de `pedido`.

## El cambio

| | Hoy | Con Redis |
|---|---|---|
| Abrir carrito | `crear_pedido()` -> fila en `pedido` | una clave en Redis |
| Agregar / quitar | `agregar_linea()` / `quitar_linea()` | operacion sobre la clave + renovar TTL |
| Pagar | `comprar_pedido()` | **`comprar_carrito()`**, con las lineas leidas de Redis |

**`comprar_carrito()` ya existe**, en `migrations/012_comprar_carrito.sql`. Hace
crear + agregar + comprar en **una sola transaccion**, y esta probada: en una
compra fallida por falta de stock no queda ni un pedido a medias (verificado con
conexiones separadas: 27 pedidos antes, error, 27 despues).

```sql
SELECT comprar_carrito(
  $id_usuario,
  $id_direccion_historial,
  $lineas::jsonb,     -- el mismo arreglo que ya recibe agregar_linea
  $metodo_pago
);
```

Devuelve lo mismo que `comprar_pedido` mas `id_pedido`.

**Las tres funciones de la 007 siguen intactas.** `comprar_carrito` las compone,
no las reemplaza: podes migrar cuando quieras y lo viejo sigue andando.

## Lo que hay que documentar del efecto sobre el checkout

Ya esta resuelto y te ahorra trabajo: **agregar al carrito NUNCA reservo stock**
(esta en `docs/base-de-datos.md`). Entonces **cuando un carrito caduca no hay
que liberar nada**. Eso es la respuesta completa a lo que pide el enunciado.

## LA TRAMPA, y hay que decidirla antes de escribir la ruta

`agregar_linea()` **congela el precio en el momento de agregar al carrito**. La
migracion 007 lo dice textual: *"si el vendedor lo sube despues, este pedido
conserva el que se le mostro a la persona"*.

Si el carrito vive en Redis, agregar y comprar pasan en el mismo instante, asi
que **el precio que se congela es el del momento de PAGAR**, no el que la
persona vio. Si el vendedor lo subio en el medio, se le cobra el nuevo, **sin
ningun error y sin que nadie se entere**.

La salida: que el carrito de Redis guarde tambien el `id_precio_historial` de
cada linea, y poder pasarselo a `agregar_linea` en vez de que ella lo busque.
Eso es un cambio en la 007 (mio) y en la ruta (tuyo): **avisame y la escribo**.
No lo dejes para despues: es un cobro incorrecto.

---

# BLOQUE 3 -- Redis: la oferta de inventario limitado (3 pts)

Es lo que mas pesa de la entrega, y es donde el enunciado es mas exigente:
*"operaciones atomicas del almacen clave-valor, con evidencia de que el
mecanismo se sostiene bajo solicitudes concurrentes simuladas y **sin recurrir a
bloqueos a nivel de aplicacion**"*.

## Por que no sirve lo que hay

`comprar_pedido()` usa `SELECT ... FOR UPDATE` (linea 469 de la 007). Funciona
perfecto, pero **es exactamente el bloqueo que el enunciado pide no usar**.

## Lo que hay que hacer

El script Lua esta en `redis/inventario_limitado.lua`, con su prueba de
concurrencia. La idea, para que la puedas defender en la presentacion:

**Comprobar y descontar tienen que ser UN solo paso.** `DECRBY` y despues
compensar si quedo negativo son dos pasos, y en el medio ya vendiste de mas. Un
script Lua corre entero y atomico dentro de Redis: nada se cuela a la mitad. Ese
es el argumento.

Devuelve algo que distinga **vendido** de **agotado**, y la ruta traduce eso a
200 o 409.

## Lo que la rubrica paga es la EVIDENCIA

No el codigo: la prueba. `redis/prueba_concurrencia.sh` pone un stock conocido,
lanza muchas mas solicitudes concurrentes que unidades, y comprueba que se
vendieron exactamente las que habia. **Esa salida va al informe.**

Corrila vos tambien antes de la entrega, para poder contestar preguntas sobre
ella.

---

# BLOQUE 4 -- Neo4j: el panel de fraude (3 pts)

El grafo esta cargado y las consultas escritas. Falta **una sola ruta**.

## El modelo, en tres lineas

```
(:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
                        (:Resena)-[:SOBRE]->(:Producto)
```

**No hay nodo `:Vendedor`.** Es el mismo `:Usuario`, y es obligatorio: en Mesh
comprar no pide rol, un vendedor tambien compra. Si fueran dos etiquetas, la
misma cuenta serian dos nodos distintos y el anillo **nunca cerraria**.

Las consultas estan en `neo4j/consultas/` y se corren con `bash neo4j/correr_fraude.sh`. Podes verlas dibujadas en
`localhost:7474`.

## `GET /admin/fraude/anillos`

**Solo admin.** No la tienda: la tienda es un vendedor mas, y ensenarle quien lo
esta calificando de forma sospechosa le entrega justo la lista que no deberia
ver.

Pantalla que la consume: `frontend/src/lib/PanelFraude.svelte`.

```jsonc
{
  "ok": true,
  "mensaje": "Analisis completado",
  "payload": {
    "anillos": [
      {
        "id": "ciclo-101-102-103",
        "tipo": "ciclo",              // ciclo | mutuo | reiterado | direccion
        "saltos": 6,
        "cuentas": [
          { "id_usuario": 101, "usuario": "ventas_altiplano",
            "correo_electronico": "ventas.altiplano@mesh.com",
            "nombre": "Rodrigo", "apellido": "Similox" }
        ],
        "productos": [ { "id_producto": 12, "nombre": "Laptop Ambar Campus 14" } ],
        "resenas": [
          { "id_resena": 901, "autor": "ventas_altiplano",
            "vendedor": "ventas_bocacosta", "producto": "Laptop Ambar Campus 14",
            "calificacion": 5, "fecha": "2026-05-11T14:02:00.000Z" }
        ],
        "senales": [
          "Las tres calificaciones son de 5 estrellas",
          "Las tres se escribieron en un intervalo de 13 minutos"
        ]
      }
    ],
    "analizado": { "cuentas": 8, "resenas": 86, "relaciones": 258 }
  }
}
```

## Los dos campos que parecen de adorno y no lo son

**`analizado`** es el denominador, y es obligatorio. Los datos sembrados **no
tienen anillo** (verificado: 0 pares mutuos, 0 autocalificaciones), asi que la
consulta va a devolver **cero**, y eso es lo correcto. Una pantalla que ante
cero dice "no hay datos" hace pensar que esta rota. Con `analizado`, la pantalla
dice *"se recorrieron 8 cuentas, 86 resenas y 258 relaciones sin encontrar
nada"*, que es un resultado y no una duda. **Sin ese campo el panel se ve roto
justo el dia de la presentacion.**

**`senales`** son las frases ya redactadas que explican la sospecha. Las arma el
backend a partir de lo que devuelve la consulta (las notas, las fechas, si hubo
compra). Sin ellas el panel ensena una lista de nombres sin decir por que.

## Para la demostracion

Como no hay anillo real, hay que **sembrar uno a proposito** antes de presentar.
`neo4j/README.md` explica como sembrarlo y como borrarlo despues.

Mientras la ruta no exista, el panel **no se rompe**: dice que el analisis no
esta conectado y tiene un boton "Ver con datos de ejemplo" para revisar el
diseno, con un aviso que no se puede quitar mientras haya datos inventados en
pantalla.

---

# Resumen: 8 rutas

| Ruta | Sesion | Bloque |
|---|---|---|
| `GET /productos/:id/resenas` | no | 1 |
| `POST /resenas` | si | 1 |
| `POST /resenas/:id/respuestas` | si, y ser el vendedor | 1 |
| `PUT /comentarios/:id/voto` | si | 1 |
| `DELETE /comentarios/:id/voto` | si | 1 |
| el carrito sobre Redis (varias) | no hace falta | 2 |
| la oferta limitada sobre Redis | si | 3 |
| `GET /admin/fraude/anillos` | si, admin | 4 |

Si algo de esto no cuadra con como tenes armado el backend, decilo y se cambia
la forma **antes** de que escribas la ruta: cambiar el frontend es barato,
cambiar las dos mitades cuando ya estan hechas no.

---

# BLOQUE 5 -- Resenar desde el pedido (agregado el 2026-08-29)

## Por que

Con la regla de compra verificada, la ficha del producto es un mal sitio para
escribir una resena: se llega ahi ANTES de comprar, y el boton solo aparece
despues. Hay que volver al producto a proposito, que es al reves de como pasa.

El sitio natural es **el pedido**: ahi esta lo que compraste y a quien.

## Lo que hay que agregar: DOS campos, no una ruta

`GET /comprador/pedidos/:id` ya devuelve por linea `id_producto_mongo`,
`id_usuario_vendedor`, `nombre_producto` y `nombre_vendedor`. Eso ya identifica
el par (producto, vendedor), que es lo que se resena. **Solo falta saber si ya
esta escrita.**

Cada objeto de `detalles` suma:

```jsonc
"id_resena": null,        // el id si ya la escribio; null si no
"puede_resenar": true     // true = se le puede ofrecer el boton
```

## El cambio, sobre tu consulta de `pedidos.service.ts`

```sql
 SELECT pp.id_pedido_producto, pp.id_pedido, pp.id_precio_historial,
        pp.id_producto_mongo, pp.id_producto_variante_mongo, pp.cantidad,
        pp.nombre_producto, pp.nombre_variante, pp.nombre_vendedor,
        ph.precio AS precio_unitario, ph.id_oferta,
        o.id_usuario AS id_usuario_vendedor,
+       r.id_resena,
+       (r.id_resena IS NULL AND o.id_usuario <> $2) AS puede_resenar
   FROM pedido_producto pp
   JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
   JOIN oferta o ON o.id_oferta = ph.id_oferta
+  LEFT JOIN resena r
+         ON r.id_usuario          = $2
+        AND r.id_usuario_vendedor = o.id_usuario
+        AND r.id_producto_mongo   = pp.id_producto_mongo
  WHERE pp.id_pedido = $1
  ORDER BY pp.id_pedido_producto
```

y pasarle `[idPedidoParametro, idUsuario]` en vez de solo `[idPedidoParametro]`.

`LEFT JOIN` y no `EXISTS` porque ademas del si/no queremos el `id_resena`.

## Cuatro trampas, y la cuarta es la que muerde

**1. Hay que exigir tambien que el pedido este PAGADO y no cancelado.** Es la
misma condicion que ya aplica tu `puede_calificar`. Sin ella, un pedido
`pendiente` ofreceria el boton y `POST /resenas` lo rechazaria despues: el
frontend habria prometido algo que el servidor niega.

Como el estado del pedido ya lo tienes en la primera consulta, lo mas simple es
calcular un booleano del pedido entero y multiplicarlo por linea al armar la
respuesta -- no hace falta meter el `JOIN pago` a la consulta de detalles.

**2. Nadie se resena a si mismo.** De ahi el `o.id_usuario <> $2`. La tabla
tiene `CHECK (id_usuario <> id_usuario_vendedor)`, asi que sin esto el boton
aparece y el POST revienta.

**3. `$2` es el comprador del PEDIDO, no "el usuario logueado" en abstracto.**
Son el mismo (la ruta ya filtra `p.id_usuario = $2`), pero si algun dia un admin
puede ver pedidos ajenos, `puede_resenar` tiene que seguir siendo "puede el
DUENO del pedido", o le ofreceras a un admin resenar la compra de otro.

**4. LA IMPORTANTE: la resena es del par (producto, vendedor), no de la linea.**
Un pedido puede traer dos lineas del mismo producto y el mismo vendedor -- dos
variantes, dos tallas -- y esas dos lineas comparten UNA sola resena. En el
conjunto de datos ya pasa: el pedido 1 tiene 2 lineas y 1 solo producto.

Con el campo por linea, esas dos lineas dirian las dos `puede_resenar: true`, el
frontend pintaria dos botones para la misma resena, y al usar uno el otro
quedaria mintiendo hasta recargar.

No hace falta que lo arregles en el backend -- el frontend agrupa por
(`id_producto_mongo`, `id_usuario_vendedor`) y pinta un boton por par. Pero
tenlo presente si algun dia devuelves un resumen contado: contar lineas daria de
mas.

## Opcional, si te sobra un rato

En la LISTA `GET /comprador/pedidos`, un `resenas_pendientes: 2` por pedido.
Sirve para poner un aviso en `/pedidos` sin abrir cada uno. Es un `count` con la
misma condicion. Si no esta, la pantalla simplemente no lo muestra.

---

# BLOQUE 6 -- `POST /carrito/comprar` (lo unico que bloquea el frontend)

Las cuatro rutas del carrito estan hechas y probadas (25 comprobaciones en
`pruebas/carrito.sh`). Falta la quinta, y **hasta que exista el frontend no
puede migrar**.

## Por que bloquea

El carrito viejo es una fila de `pedido` en `pendiente`, con el `id_pedido` en
`localStorage`, y el checkout va por ahi. El carrito de Redis **no tiene
id_pedido**. No hay forma de migrar a medias: si el frontend pasa a Redis sin
esta ruta, se llena un carrito que no se puede comprar.

Son ocho archivos del frontend los que cuelgan del carrito viejo, asi que el
cambio se hace de una sola vez, cuando esto exista.

## Lo que hace

```
POST /carrito/comprar
{ "id_direccion_historial": 12, "metodo_pago": "tarjeta" }
```

1. Lee el carrito de Redis (`HGETALL`)
2. Lo arma como el arreglo `p_lineas` que ya recibe `agregar_linea`
3. Llama a **`comprar_carrito()`** -- migracion `012_comprar_carrito.sql`, ya
   existe y esta probada: hace crear + agregar + comprar en UNA transaccion,
   y un intento fallido no deja ni un pedido a medias (verificado con
   conexiones separadas: 27 pedidos antes, error, 27 despues)
4. Si salio bien: `DEL` de la clave del carrito
5. Devuelve el `id_pedido` que trae la funcion

```sql
SELECT comprar_carrito($id_usuario, $id_direccion_historial, $lineas::jsonb, $metodo_pago);
```

Cada elemento de `$lineas` es el mismo objeto que ya usa `agregar_linea`:

```jsonc
{ "id_oferta": 12, "cantidad": 2, "id_producto": 5,
  "id_producto_variante": 9, "nombre_producto": "...", "nombre_variante": "..." }
```

## Tres cosas que decidir antes de escribirla

**1. El `DEL` va DESPUES del COMMIT, nunca antes.** Si se borra el carrito y la
compra falla, la persona pierde el carrito y no compro nada. Al reves -- comprar
y que el `DEL` falle -- solo deja un carrito repetido que se puede vaciar a
mano. De los dos errores posibles, hay que elegir el que se puede deshacer.

**2. Que hacer con las lineas que no se pueden comprar.** `GET /carrito` ya las
marca (`disponible: false`). Al comprar hay dos opciones y hay que elegir una:
rechazar la compra entera diciendo cuales, o comprar las que si y dejar las
otras en el carrito. **Rechazar entera es mas facil de explicar** y no sorprende
a nadie con un total distinto al que vio.

**3. EL PRECIO. Esto no es un detalle.**

`agregar_linea()` congela el precio en el momento de agregar al carrito -- la
007 lo dice textual: *"si el vendedor lo sube despues, este pedido conserva el
que se le mostro a la persona"*.

Con el carrito en Redis, agregar y comprar pasan **en el mismo instante**, asi
que el precio que se congela es el del momento de PAGAR. Si el vendedor lo subio
mientras el carrito esperaba, **se le cobra el nuevo, sin ningun error y sin que
nadie se entere**.

La salida: que el carrito de Redis guarde tambien el `id_precio_historial` de
cada linea y poder pasarselo a `agregar_linea` en vez de que ella lo busque.
Eso es un cambio en la 007 (mio) y en esta ruta (tuyo): **avisame y lo escribo**.

Mientras no se resuelva, `GET /carrito` esta devolviendo un precio que puede no
ser el que se cobre. Es un cobro incorrecto, no un detalle de presentacion.

---

# BLOQUE 7 -- El filtro por calificacion en el catalogo -- CERRADO el 2026-09-03

> **YA NO FALTA NADA.** Jose David lo implemento, y con una API mas completa
> que la que este bloque pedia: en vez de un solo `resenas_min` quedaron cuatro
> parametros, `resenas_promedio_min`, `resenas_promedio_max`,
> `resenas_total_min` y `resenas_total_max`, con la guardia de
> `resenas_total >= 1` incluida.
>
> El frontend ya lo consume: el catalogo tiene el selector "Calificacion", y
> los cuatro nombres estan en la copia de `CLAVES_RESERVADAS` de
> `+page.svelte`. Medido contra la API viva: sin filtro 1104 productos, con
> nota >= 4 salen 44 en 4 paginas, y los mismos numeros se ven en la pantalla.
>
> Se deja escrito entero porque explica POR QUE cada decision es la que es, y
> eso sigue valiendo el dia que alguien toque ese filtro.

## Por que

El catalogo ya puede filtrar por precio y por stock, pero no por lo que la
gente mira primero cuando hay veinte vendedores del mismo producto: la nota.
Lo de este lado ya esta hecho y desplegado, asi que lo unico que falta para
que sirva es un query param.

## Lo que ya esta hecho y te espera

El documento de cada producto en Mongo trae **dos campos nuevos** que escribe
el ETL de `etl/cargar.js`:

```jsonc
"resenas_promedio": 4.33,   // numero, de 1.00 a 5.00. 0 si no tiene resenas.
                            // El tipo BSON no es siempre el mismo: mira el
                            // apartado del tipo mas abajo antes de filtrar
"resenas_total": 3          // entero, cuantas resenas se promediaron
```

Y el indice que los sirve ya existe, en `mongo/002_resenas.js`:

```
catalogo_rating  { categoria.id_categoria: 1, estado: 1, resenas_promedio: -1, _id: 1 }
```

Ese archivo ademas **rellena con 0 los dos campos** en todo producto que no
los tenga, y ese relleno importa mas de lo que parece. Esta explicado abajo,
en la trampa del campo ausente.

## El contrato: un query param, `resenas_min`

```
GET /productos?resenas_min=4
GET /productos?id_categoria=9&resenas_min=4.5&limite=12
```

Decimal de **1 a 5**. Es un minimo, sin maximo: nadie busca "productos de
hasta 3 estrellas".

Se llama `resenas_min` y no `rating_min` por dos motivos que van juntos. El
primero es que casa con el campo del documento (`resenas_promedio`,
`resenas_total`), asi que quien lea el query param sabe contra que se compara
sin abrir el codigo. El segundo es que la convencion del catalogo ya esta
puesta y es en espanol: `precio_min`, `precio_max`, `stock_min`,
`stock_tienda_min`. Un `rating_min` seria el unico filtro en ingles de la
lista.

## Hay que declararlo en CUATRO sitios, no en uno

Esta es la parte que se olvida. `resenas_min` tiene que aparecer en los
cuatro:

Los cuatro se localizan con `Ctrl+F` por el texto que va en la columna del
medio, como hace `docs/GUIA-PRESENTACION.txt`, y no por numero de linea: los
cuatro archivos se estan tocando y un numero se cae solo.

| Archivo | `Ctrl+F` | Que se agrega | De quien es |
|---|---|---|---|
| `backend/src/services/productos/productos.service.ts` | `const CLAVES_RESERVADAS = new Set([` | `'resenas_min'` al Set | tuyo |
| `backend/src/dto/listar-productos.ts` | `export interface ListarProductosQuery {` | `resenas_min?: string;` | tuyo |
| `backend/src/dto/paginar-productos.ts` | `export interface PaginarProductosQuery {` | `resenas_min?: string;` | tuyo |
| `frontend/src/routes/+page.svelte` | `const CLAVES_RESERVADAS = new Set([` | `'resenas_min'` al Set | mio |

Los dos DTO son dos archivos distintos y **ya vienen desincronizados**, asi
que no vale mirar uno y suponer el otro: `ListarProductosQuery` declara
`despues_de`, `precio_tienda_min` y `precio_tienda_max`, y
`PaginarProductosQuery` no declara ninguno de los tres, aunque las dos rutas
comparten `construirFiltro` y `CLAVES_RESERVADAS`. El comentario de
`CLAVES_RESERVADAS` dice que la lista es una sola para las dos rutas; los DTO
no lo son.

La copia del frontend es mia y la actualizo yo, pero conviene que sepas para
que sirve: la lista esta ahi para que una caracteristica personalizada que se
llame igual que un filtro fijo no se mande cruda. Quien publica un producto le
pone el nombre que quiera a sus caracteristicas personalizadas, y el dia que
alguien cree una llamada `resenas_min`, si el frontend no sabe que ese nombre
esta reservado la manda tal cual y el backend la toma por el filtro fijo del
mismo nombre. Devuelve otra cosa y no da ningun error.

## EL FALLO MAS CARO: si falta en CLAVES_RESERVADAS, no da error

Esto es lo unico de este bloque que hay que leer dos veces.

Si `resenas_min` llega y **no** esta en `CLAVES_RESERVADAS`, no revienta nada.
El bucle de `construirFiltrosDinamicos` se salta las claves reservadas y trata
todo lo demas como una caracteristica adicional, asi que `resenas_min=4` se
convierte en esto:

```jsonc
{ "$or": [
  { "caracteristicas_adicionales":            { "$elemMatch": { "nombre": "resenas_min", "valor": 4 } } },
  { "caracteristicas_personalizadas":         { "$elemMatch": { "nombre": "resenas_min", "valor": 4 } } },
  { "variantes.caracteristicas_adicionales":  { "$elemMatch": { "nombre": "resenas_min", "valor": 4 } } },
  { "variantes.caracteristicas_personalizadas": { "$elemMatch": { "nombre": "resenas_min", "valor": 4 } } }
]}
```

O sea, la busqueda de una caracteristica llamada `resenas_min` que ningun
producto del catalogo tiene. `esNombreCaracteristicaValido` la deja pasar sin
quejarse, porque solo mira que no este vacia y que quepa en el `varchar(100)`.

**Resultado: 200 con la lista vacia.** El filtro parece funcionar y parece
decir que no hay ni un producto bien calificado. No hay excepcion, no hay log,
no hay nada que revisar. Es exactamente la misma clase de fallo que el campo
ausente de mas abajo, y las dos veces la respuesta es una lista corta que nadie
sabe leer como un error.

Si escribes el filtro y la primera prueba devuelve vacio, mira esa lista antes
que cualquier otra cosa.

## El filtro tiene que exigir ADEMAS `resenas_total > 0`

```jsonc
{ "resenas_promedio": { "$gte": 4 }, "resenas_total": { "$gt": 0 } }
```

El `resenas_total` no es adorno. `resena.calificacion` en PostgreSQL es un
`smallint` con `CHECK BETWEEN 1 AND 5`, asi que un promedio de verdad nunca
baja de 1. El **0 de `resenas_promedio` significa "todavia nadie ha
calificado esto"**, y sin la segunda condicion ese 0 entra a la comparacion
como si fuera una nota.

Con un `resenas_min` alto no se nota, porque el 0 queda fuera igual. Se nota
el dia que se ordene por nota o que alguien pida `resenas_min=0`: un producto
sin ninguna opinion quedaria por debajo de uno con una sola estrella, cuando
lo que pasa es que no se sabe nada de el. Poner la condicion desde el
principio cuesta una linea; descubrirlo despues cuesta explicar por que el
catalogo ordena mal.

## El tipo NO es `Decimal128`, y tampoco es `double` en todos los documentos

Aqui habia escrito que `resenas_promedio` se guarda como `double`. **Es falso**,
y conviene saber por que antes de escribir el filtro.

**El mecanismo.** El ETL corre dentro de `mesh-mongo` con `mongosh`, y `mongosh`
guarda un numero de JavaScript segun su **valor**, no segun su significado. Un
promedio que sale entero (un producto con una sola resena de 5, o el 0 del
relleno) se escribe como **int32**; uno con decimales (4.33) se escribe como
**double**. Como el promedio de cada producto cae de un lado o del otro segun
sus resenas, **el campo queda repartido entre los dos tipos dentro de la misma
coleccion**, y esa mezcla no es un fallo que alguien vaya a arreglar: es como se
comporta el escritor. `resenas_total` no tiene el problema porque un conteo
siempre es entero.

El reparto se recuenta cuando haga falta, y esta es la consulta:

```js
db.productos.aggregate([{ $group: { _id: { $type: "$resenas_promedio" },
                                    n: { $sum: 1 } } }])
```

**Ejemplo de una corrida concreta, la del 2026-09-02:** 395 documentos con el
campo en `int` y 11 en `double`. O sea que **la mayoria son `int`**, no
`double`.

### Lo que eso significa para tu filtro, en tres reglas

**1. Compara con un numero normal de JavaScript, y ya.** Mongo compara ENTRE
tipos numericos: un `$gte: 4` encuentra igual el `int` 5 y el `double` 4.67, y
un `$sort` los ordena juntos. No hay que hacer nada especial por la mezcla.

```ts
// asi
{ resenas_promedio: { $gte: 4.5 } }
```

**2. NO construyas el extremo con `Decimal128.fromString`.** Eso es lo que hace
`construirRangoDecimal` para el precio, porque el precio SI se guarda como
`Decimal128`. Reutilizarlo aqui seria copiar la precaucion del dinero a un campo
que no la necesita, y meter un tercer tipo en una comparacion que ya funciona:

```ts
// asi NO
{ resenas_promedio: { $gte: Decimal128.fromString('4.5') } }
```

El motivo de que el dinero sea `Decimal128` y la nota no es que el dinero tiene
centavos que no se pueden perder, y la nota es un promedio que ya se calculo y
que cabe exacto en un double con sus dos decimales.

**3. NO filtres por `$type` sobre este campo.** Es la trampa que la mezcla deja
puesta. Un `{ resenas_promedio: { $type: "double" } }` parece una precaucion
razonable y **deja fuera a la mayoria de los productos**, sin dar ningun error:
la respuesta es 200 con una lista mas corta, igual que los otros dos fallos
silenciosos de este bloque.

Medido el 2026-09-02, sobre la misma base del ejemplo de arriba: `$gte: 4` a
secas devolvia 43 productos, y el mismo `$gte: 4` con el `$type: "double"`
pegado devolvia 9. Los 34 que faltaban tenian su nota entera, guardada como
`int`.

Esto vale tambien para cualquier prueba que escribas: verificar el filtro
preguntando por el tipo del campo te va a dar un resultado que no es el que ve
el catalogo.

## Un `$gte` sobre un campo AUSENTE no hace match

Regla de Mongo, y es la razon de que `mongo/002_resenas.js` rellene con 0.

Un documento que **no tiene** `resenas_promedio` no cumple
`{ resenas_promedio: { $gte: 1 } }`. Ausente no se compara como 0, no se
compara con nada. Y el ETL solo escribe los productos que extrae de
PostgreSQL, asi que los productos que nacieron en Mongo desde el panel del
vendedor nunca reciben esos dos campos por su cuenta.

Sin el relleno, esos productos **desaparecen del catalogo** en cuanto alguien
use el filtro. Sin error. El vendedor ve que su producto ya no aparece y no
hay a quien preguntarle.

El relleno ya esta hecho y es idempotente (filtra por `$exists: false`). Pero
**no cierra el agujero entero**, y eso hay que leerlo en el apartado siguiente
antes de dar el filtro por terminado: el relleno vive en `mongo/002_resenas.js`
y corre **en cada arranque**, o sea que lo que se publica entre dos arranques
se queda fuera hasta el siguiente.

## Los DOS agujeros que quedan abiertos, y no son teoricos

Esto lo encontro la verificacion del bloque, no estaba escrito en ningun lado,
y los dos te tocan a vos porque los dos se cierran del lado del backend.

### a) Un producto creado desde el panel nace SIN los dos campos

`backend/src/services/vendedores/productos.service.ts` tiene **dos**
`insertOne` sobre `db.productos`: uno en `crear()` y otro en `proponer()` (se
buscan con `Ctrl+F` por `await coleccionProductos.insertOne(producto);`, que
aparece exactamente dos veces; no doy numero de linea porque en ese archivo se
mueven). Los dos arman el literal `producto` con `_id`, `nombre`,
`descripcion`, `fecha_creacion`, `estado`, `categoria`, los calculados que
nacen en cero (`precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total`,
`total_ofertas`), `variantes` y las caracteristicas. **Ni `resenas_promedio` ni
`resenas_total` aparecen en ninguno de los dos.** Comprobado ademas sobre todo
el arbol: `grep -rn "resenas_promedio" backend/src` no devuelve nada, o sea que
el backend no escribe ese campo en ninguna parte.

El relleno de `mongo/002_resenas.js` solo corre al arrancar (`arrancar.ps1`,
paso "Creando colecciones", que recorre todos los `.js` de `mongo/`). Junta las
dos cosas y sale esto:

> **Entre dos arranques, cada producto publicado desde el panel es invisible
> para cualquier filtro por nota.**

Y es invisible por la regla de arriba, la del campo ausente: no es que salga
con nota 0 y quede por debajo, es que **no hace match** y desaparece de la
lista. No hay excepcion, no hay log, no hay nada. El vendedor publica, entra al
catalogo, filtra por nota y no encuentra su producto. Otra vez la misma forma de
fallo que recorre todo este bloque: un 200 con una lista mas corta de la cuenta,
que nadie sabe leer como un error.

Lo que lo cierra es una linea en cada uno de los dos literales:
`resenas_promedio: 0, resenas_total: 0`. Es exactamente el piso que ya escribe
`mongo/002_resenas.js`, puesto en el momento en que el documento nace en vez de
en el siguiente arranque.

### b) Los productos que viven SOLO en Mongo no actualizan NUNCA su nota

Este es mas hondo que el anterior y no se arregla con dos lineas.

`etl/extraer.sql` calcula los dos campos con dos subconsultas sobre `resena`,
pero la consulta entera itera `FROM productos p`, o sea **la tabla de
PostgreSQL** (se busca con `Ctrl+F` por `FROM productos p`, que aparece una
sola vez, al final del archivo). Un producto que solo existe en Mongo no tiene
fila ahi, asi que nunca entra en esa consulta, nunca aparece en el bulk de
`etl/cargar.js`, y **su nota se queda en el 0 del relleno para siempre**,
corra el ETL las veces que corra.

**Y esto no es teorico, esta medido.** Estas son las dos consultas que lo
comprueban, y hay que volver a correrlas antes de creerle un numero a este
parrafo:

```sql
-- productos que viven solo en Mongo pero YA tienen oferta en PostgreSQL
SELECT DISTINCT o.id_producto_mongo
  FROM oferta o
 WHERE NOT EXISTS (SELECT 1 FROM productos p
                    WHERE p.id_producto = o.id_producto_mongo);

-- y de esos, los que ya se VENDIERON, o sea los que ya se pueden resenar:
-- es el mismo JOIN que usa el candado de `comprado()` en resenas.service.ts
SELECT pp.id_producto_mongo, pp.nombre_producto, count(*)
  FROM pedido pe
  JOIN pago            pg  ON pg.id_pedido         = pe.id_pedido
  JOIN estado_pago     epa ON epa.id_estado_pago   = pg.id_estado_pago
  JOIN estado_pedido   epe ON epe.id_estado_pedido = pe.id_estado_pedido
  JOIN pedido_producto pp  ON pp.id_pedido         = pe.id_pedido
 WHERE NOT EXISTS (SELECT 1 FROM productos p
                    WHERE p.id_producto = pp.id_producto_mongo)
   AND epa.estado_pago_nombre    = 'pagado'
   AND epe.estado_pedido_nombre <> 'cancelado'
 GROUP BY 1, 2;
```

**Ejemplo de una corrida concreta, la del 2026-09-02:** cuatro productos vivian
solo en Mongo; tres de ellos tenian oferta en PostgreSQL, y dos --
`barbuchin` y `crepas` -- tenian pedidos **pagados y no cancelados**. O sea que
sus compradores pasan hoy el candado de `comprado()` y pueden publicar una
resena ahora mismo. Esa resena entraria en `resena` de PostgreSQL, y el
promedio de esos productos en Mongo seguiria en 0 despues de cualquier ETL.

**El arreglo de fondo, y no es un parche.** El promedio tiene que calcularse
desde `resena` **agrupando por `id_producto_mongo`**, con independencia de que
ese producto tenga o no fila en `productos`. `resena.id_producto_mongo` es un
`bigint` sin llave foranea a `productos` (se ve en `\d resena`), asi que
agrupar por ahi es legal y cubre a los huerfanos igual que a los demas. Eso no
cabe en la consulta de extraccion actual, que esta armada producto a producto
desde el relacional: es **una etapa nueva del ETL**, que escriba los dos campos
con un `updateOne` por cada `id_producto_mongo` que aparezca en `resena`, sea
cual sea la base donde vive el producto.

### La pregunta que te toca a vos, y no la decido yo

**Deberia el backend escribir `resenas_promedio` y `resenas_total` en el
documento de Mongo cada vez que se publica una resena?**

Es lo unico que cerraria el agujero de verdad, y por eso la pregunta es tuya:
`POST /resenas` ya existe y es tuya (`resenas.service.ts`), y hoy escribe
**solo en PostgreSQL** -- un `INSERT INTO resena` y nada mas. El documento de
Mongo no se entera, asi que la nota que ve el catalogo es la de la ultima
corrida del ETL, no la de ahora.

Las dos caras, para que las peses vos:

- Si el backend los escribe, la nota del catalogo queda al dia al instante y
  los productos huerfanos dejan de ser un caso aparte, porque el que escribe la
  resena si sabe a que `id_producto_mongo` va. El costo es que el promedio pasa
  a tener **dos escritores** -- el backend y el ETL -- y hay que decidir cual
  manda cuando no coincidan, que es exactamente la clase de cosa que ya
  reconoce `etl/extraer.sql` sobre el redondeo.
- Si no los escribe, el promedio sigue teniendo un solo escritor, pero entonces
  la etapa nueva del ETL del punto (b) es obligatoria y hay que decir cada
  cuanto corre, porque la nota del catalogo va a ir siempre por detras.

Lo que no es una opcion es dejarlo asi y que nadie lo sepa, que era la
situacion antes de este apartado.

## El ORDEN no viene con el filtro, y no es cosmetico

Hoy `listar()` de `productos.service.ts` ordena **fijo por `_id` ascendente**
(`Ctrl+F` por `.sort({ _id: 1 })`) y la paginacion por cursor **depende de ese
orden**: el cursor es un `$gt` sobre `_id` (`Ctrl+F` por
`filtro._id = { $gt: despuesDe };`, unas lineas mas arriba, en el mismo
metodo). Las dos cosas son la misma cosa.

Un "ordenar por mejor calificado" cambia el orden y por lo tanto **rompe el
contrato del cursor**: con `sort({ resenas_promedio: -1, _id: 1 })`, un
`despues_de` que es un `_id` ya no significa "lo que viene despues", porque lo
que viene despues ya no va por `_id`. La pagina 2 repetiria productos o se
saltaria otros, sin dar error.

Por eso el orden se decide **aparte del filtro** y no se cuela en el mismo
cambio. El filtro no toca el cursor y se puede escribir hoy. El orden hay que
disenarlo con su cursor propio (el par `resenas_promedio` mas `_id`, que es
justamente por lo que el indice lleva `_id` de ultimo desempate) y eso es otra
conversacion.

El indice `catalogo_rating` ya soporta las dos, el filtro y el orden, sin etapa
`SORT`. Esta ahi para el dia que se quiera, no porque haga falta ahora.

## No reutilices `validarPrecio` para la nota

Tentador, porque `resenas_min` es un decimal igual que `precio_min`. No sirve,
por dos razones y las dos muerden:

**1. Su regex no tiene tope superior.** Es `/^\d+(\.\d{1,2})?$/`, asi que un
`resenas_min=9` pasa la validacion entera. El filtro sale contra Mongo, ningun
producto tiene un promedio de 9, y la respuesta es 200 con lista vacia. Otra
vez el mismo fallo silencioso: la nota SI tiene un maximo y la validacion
tiene que decirlo.

**2. Devuelve `string`, no `number`.** `validarPrecio` devuelve el texto tal
cual para que `Decimal128.fromString` lo reciba. Aqui hace falta un numero,
asi que aunque el rango se validara bien habria que convertirlo, y una
conversion implicita es justo lo que pone un `string` dentro de un `$gte` de
un campo `double`.

Lo que hace falta es un validador propio, en la linea de los que ya estan en
`backend/src/helpers/validaciones-productos.ts`: opcional, decimal, **entre 1
y 5 inclusive**, devuelve `number | null`, y lanza `ErrorValidacion` con el
rango escrito en el mensaje cuando no cuadra. Un 400 que dice "la calificacion
minima va de 1 a 5" se arregla solo; un 200 vacio hay que ir a buscarlo.

---

# BLOQUE 8 -- AVISO: dos asignadores distintos para el id de producto

Esto **no lo pidio nadie y no es una tarea**. Salio de medir las dos bases
mientras se preparaba otra cosa, y existe aunque no se toque nada mas. Es tu
area, asi que va escrito como lo que es: los hechos medidos y la pregunta que
te toca a vos decidir.

## Los hechos, medidos contra el ambiente vivo

**1.** `backend/src/services/vendedores/productos.service.ts` lo dice por
escrito en el comentario de la clase (`Ctrl+F` por `Todo vive en MongoDB:`):

> Todo vive en MongoDB: los productos ya no se registran en PostgreSQL (las
> migraciones de productos fueron solo para el ETL que cargo los datos de
> prueba). Por eso el id del producto y el de cada variante no salen de un
> bigserial: se calculan como "el maximo que ya existe, mas 1"

La funcion es `siguienteIdProducto` -- se busca con `Ctrl+F` por ese nombre y
no por numero de linea, que en ese archivo se mueve -- y **lee el maximo de
MONGO**: un `find().sort({ _id: -1 }).limit(1)` sobre `db.productos`.

**2.** PostgreSQL sigue teniendo su `bigserial` en `productos.id_producto`, y
esta vivo: cada `INSERT INTO productos` consume un numero de esa secuencia, sin
enterarse de lo que Mongo haya repartido.

**3.** La forma de la divergencia, que es lo que no caduca: **Mongo va por
delante de la secuencia de PostgreSQL en exactamente tantos numeros como
productos se hayan publicado desde el panel**, porque cada uno de esos gasta un
`_id` de Mongo y ninguno del `bigserial`. El hueco solo puede crecer, y nada lo
cierra solo. Lo mismo pasa con las variantes.

Aqui se mide, y son las consultas que hay que correr antes de creerle un numero
a este bloque:

```sql
-- PostgreSQL
SELECT last_value FROM productos_id_producto_seq;
SELECT last_value FROM productos_variantes_id_producto_variante_seq;
SELECT count(*)   FROM productos;
```

```js
// MongoDB
db.productos.countDocuments({})
db.productos.aggregate([{ $group: { _id: null, m: { $max: "$_id" } } }])
db.productos.aggregate([{ $unwind: "$variantes" },
    { $group: { _id: null, m: { $max: "$variantes.id_producto_variante" } } }])
```

**Ejemplo de una corrida concreta, la del 2026-09-02**, y vale como ejemplo de
la forma, no como el estado de la base de hoy:

```
PostgreSQL   secuencia de productos en 102, de variantes en 202, 102 filas
MongoDB      106 productos, max id_producto_variante 206
             los _id 103, 104, 105 y 106 nacieron en el panel
             (tecnokid, barbuchin, "PRUEBA candado propuesta", crepas)
             y no tienen fila en PostgreSQL
```

## La consecuencia, que es lo que importa

Los dos asignadores ya divergieron. El siguiente `INSERT INTO productos` de
PostgreSQL entrega un numero que en Mongo **ya es de otro** -- en el ejemplo de
arriba, el 103, que es tecnokid.

Cuando el ETL corra despues de ese insert, `etl/cargar.js` escribe con

```js
replaceOne: { filter: { _id: doc._id }, replacement: doc, upsert: true }
```

y **machaca el documento del vendedor entero**, sin un solo error. `replaceOne`
reemplaza el documento completo, asi que no queda ni un campo del original. El
vendedor abre su producto y encuentra otro.

**Y nada avisa.** `etl/cargar.js` tiene `deleteMany` sobre `db.categorias` y
sobre `db.productos_eventos`, pero **no sobre `db.productos`**. Es a proposito
y esta comentado alli mismo: un producto nacido en Mongo no tiene fila en
PostgreSQL y el barrido lo borraria. Lo que ese comentario cubre es el
BORRADO. El `replaceOne` por `_id` se cuela por debajo de esa proteccion:
respeta al producto huerfano solo mientras nadie de PostgreSQL reclame su
numero.

## Esto no es la carrera que ya esta reconocida

Ese mismo comentario de la clase reconoce un riesgo y lo acepta:

> el riesgo aceptado es que dos creaciones en el mismo instante choquen y una
> falle, recuperable con solo reintentar

Esa carrera es aceptable tal como dice: falla ruidosamente y se arregla
reintentando. La divergencia entre las dos bases es otra cosa y no esta
reconocida en ningun lado: no falla, no se puede reintentar, y el dato que se
pierde no vuelve.

## Como lo esquiva el generador de lotes, y por que eso no es el arreglo

`migrations/lote/generar_lote.sql` (ver su `README.md`) tiene que insertar
productos en PostgreSQL, asi que se encuentra con esto de frente. Lo que hace
es alinear las dos secuencias con `setval` contra el maximo de las DOS bases
antes de insertar, usando los maximos de Mongo que se le pasan por variable.
Deja un hueco de ids en PostgreSQL -- los numeros que van desde su propio
maximo hasta el de Mongo no van a tener nunca una fila de este lado -- y ese
hueco es correcto: son numeros que ya estan ocupados del otro lado.

Eso es **un parche del lado de las migraciones**, no un arreglo. Solo protege
a los inserts que pasan por ese archivo. Cualquier otro `INSERT INTO productos`
(a mano, desde otra migracion, desde el backend si algun dia vuelve a escribir
ahi) sigue entregando el id que le toque a la secuencia.

## La pregunta que te toca decidir

**De donde sale el id de un producto: de una sola fuente, o de dos?**

Y si es de una sola, cual. No la contesto yo porque es tu area y las opciones
tienen costos distintos segun como tengas armado el backend. Las que se ven
desde aqui:

- Que PostgreSQL siga siendo el asignador y el panel pida el id alla antes de
  escribir en Mongo. Es la que respeta que PostgreSQL sea la fuente de verdad,
  y es la que mas toca tu codigo.
- Que Mongo sea el asignador y PostgreSQL deje de tener secuencia para
  productos. Es la que menos toca el panel, y obliga a decidir que pasa con
  las filas que la tabla `productos` ya tiene y con todo lo que cuelga de
  ellas por `id_producto_mongo`.
- Que haya un contador aparte, en una coleccion o en una tabla, que las dos
  consulten. Es la unica que no depende de que el otro lado exista, y es la
  que agrega una pieza nueva.

Lo que no es una opcion es dejarlo como esta y no escribirlo en ningun sitio,
que era la situacion antes de este bloque.

---

# BLOQUE 10 -- Un 409 al editar el stock durante una venta relampago (2026-09-04)

**Es lo mas grave que queda del inventario limitado, y son tres lineas.**

`PATCH /vendedor/ofertas/:id` sigue aceptando `ajuste_stock` con la venta
relampago abierta. `activar()` siembra Redis con una FOTO del stock, asi que
desde ese momento son dos contadores que nadie vuelve a comparar.

Subir el stock deja unidades inertes, que es feo pero no rompe. **Bajarlo si
rompe, y del lado del comprador:** Redis ya le prometio unidades a alguien con
un ticket vivo, y al pagar `comprar_pedido` levanta

```
No hay suficiente stock de "%" (%): quedan % y se pidieron %
```

La persona aparto, espero, pago, y el cobro le revienta con un error que no
explica nada porque desde su lado no cambio nada.

**Lo que pido:** rechazar con **409** un `PATCH` que traiga `ajuste_stock`
cuando `oferta.es_inventario_limitado` sea true, con un mensaje del estilo
"cierra la venta relampago, repone y vuelve a abrirla". El frontend lo pinta
como aviso en la fila, igual que los otros 409.

**Los otros dos campos NO los bloquees:**

- `precio` ya esta cubierto por `lineas_precio_visto`.
- `estado` no, porque un vendedor tiene que poder pausar. Si acaso, que pausar
  cierre la venta relampago primero.

Detalle entero en el pendiente 8 de `docs/PENDIENTES.md`.

---

# BLOQUE 9 -- Las dos rutas para abrir la venta relampago -- CERRADO el 2026-09-03

> **HECHO, y el boton ya las llama.** Jose David escribio las dos rutas esa misma
> noche, con los nombres exactos que pedia este bloque, y de paso resolvio un
> hueco que este texto no habia visto (ver "Lo que hizo de mas", al final). El
> boton esta en `frontend/src/lib/OfertasVendedor.svelte`, en las DOS vistas del
> panel. Todo el ciclo esta medido en `docs/TRASPASO.md`, seccion "La venta
> relampago, ya completa de punta a punta".
>
> Lo de abajo se deja escrito entero porque es el contrato que se pidio y sirve
> para comparar lo pedido con lo entregado, que es la unica forma de saber si
> una peticion se cumplio.

**Esto era lo unico que bloqueaba el frontend del inventario limitado.** Todo lo
demas ya funcionaba y estaba probado en el navegador: reservar al agregar,
redimensionar, soltar al quitar, el 409 cuando no alcanza, la etiqueta naranja
en la linea del carrito y el aviso de reserva vencida.

Lo que no existe es **el interruptor para encenderla**. Medido con grep sobre
`backend/src/`:

```
rutas HTTP que abran una venta limitada .... ninguna
quien llama a activar() .................... nadie
```

`activar()` y `revertir()` estan escritos y funcionan (los ejercite a mano
llamando al Lua directamente), pero son metodos huerfanos: no hay controlador
que los invoque. Sin ruta no puedo poner el boton en el panel del vendedor,
porque no tendria a que llamar.


## Lo que necesito, en concreto

Dos rutas, en el controlador de vendedores.

### `POST /vendedor/ofertas/:id/venta-limitada`

Abre la venta. Por dentro es una llamada a `inventarioLimitadoService.activar(idOferta, ttlSegundos)`.

Cuerpo:

```json
{ "duracion_segundos": 3600 }
```

`duracion_segundos` opcional. Si no viene, que `activar` use su valor por
defecto (hoy 0, o sea sin vencimiento de la venta entera).

Respuesta 201 con lo que ya devuelve `activar`:

```json
{ "stock_sembrado": 33 }
```

### `DELETE /vendedor/ofertas/:id/venta-limitada`

La cierra. Por dentro, `revertir(idOferta)`. Respuesta 200 sin cuerpo, o con un
resumen si te resulta util.


## Los errores que el frontend necesita distinguir

`activar` ya lanza estos dos y los quiero tal cual, porque el boton tiene que
decir cosas distintas:

- La oferta no esta activa -> **409**, mensaje ya escrito en el servicio.
- La oferta YA esta en modo venta limitada -> **409**, mensaje ya escrito.
  Este importa: es lo que evita que un segundo clic borre las reservas vivas.

Y hace falta uno mas, que hoy no esta:

- La oferta no es de quien la pide -> **403**, o el 404 disfrazado que usa el
  resto del panel. Un vendedor no puede abrir una venta relampago sobre la
  oferta de otro.


## Lo que hare yo en cuanto existan

En `frontend/src/lib/OfertasVendedor.svelte`, en la fila de cada oferta:

- Un boton "Abrir venta relampago" cuando la oferta esta activa y no marcada.
- Un campo para la duracion.
- Cuando ya esta abierta, la fila la marca y el boton pasa a "Cerrar la venta".
- Los dos 409 se pintan como aviso en la fila, no como error de pantalla.

Son unas pocas lineas y no dependen de nada mas.


## Si preferis otros nombres de ruta

Sin problema, decime cuales y ajusto. Lo unico que pido es que **no cambien
despues de que yo escriba el boton**, porque el boton llama por nombre y un
cambio silencioso da un 404 que en la pantalla se ve como "no pasa nada al
hacer clic".

---

## Lo que se entrego, comparado con lo que se pidio

Medido contra el servidor vivo el 2026-09-03 por la noche.

| Lo que pedia este bloque | Lo que llego |
|---|---|
| Los dos nombres de ruta | **Los mismos.** El boton no tuvo que cambiar nada |
| 201 con `{ stock_sembrado }` | `{ id_oferta, stock_sembrado }`. Un campo de mas |
| Los dos 409 tal cual | Estan, con el mismo texto. Y agrego un tercero para el `DELETE` |
| 403 **o** el 404 disfrazado | Eligio el **404 generico**, que era una de las dos opciones |
| Un campo para la duracion | `duracion_segundos`, 0 por defecto, tope 7 dias |

### Lo que hizo de mas, y hacia falta

Este bloque pedia un boton que dijera "Abrir" cuando la oferta no estuviera
marcada, y **no existia ningun campo que dijera si lo estaba**. El contrato
estaba incompleto y no se noto al escribirlo. Jose David agrego
`es_inventario_limitado` a los tres GET (`/vendedor/ofertas`,
`/vendedor/ofertas/producto/:id` dentro de `mi_oferta`, y `/productos/:id`
publico), que es lo que hace posible el boton.

### Tres cosas que aparecieron al escribir el boton

1. **Un `POST` con `Content-Type: application/json` y cuerpo vacio da un 400 de
   Fastify**, no el sobre `{ ok, mensaje, payload }` del resto de la API: trae
   `message` y no `mensaje`, asi que `mensajeUtil` se queda sin texto. El boton
   manda `{}` siempre.
2. **El 404 dice "No existe una oferta con ese id" tambien cuando la oferta es
   de otra cuenta**, y esta bien que lo haga. Lo que no sirve es repetir ese
   texto dentro del panel de quien es dueno de la fila, asi que el frontend lo
   traduce.
3. **`sembrar` acepta un stock de cero y contesta 201.** Abrir una venta sin
   unidades no falla hoy: falla despues y en silencio, porque lo sembrado es una
   foto y reponer existencias mas tarde sube PostgreSQL y deja Redis en cero. El
   boton lo corta antes de llamar. Si algun dia se quiere cerrar por el lado
   correcto, el sitio es `activar()`.
