# El motor de busqueda

Elasticsearch, la QUINTA base. Entra en la Entrega 3 y es lo que contesta
cuando alguien escribe mal el nombre de un producto.

```
localhost:9200    la API, sin contrasena y solo en local
indices           mesh_productos               el buscador del catalogo
                  mesh_eventos_autenticacion   el log de logins (ver al final)
```

## Por que hace falta, si ya hay cuatro bases

Por una cosa concreta que ninguna de las otras hace bien: escribir **labtop** y
que aparezca **Laptop**.

- MongoDB Community tiene `$text`, pero **no tiene busqueda difusa**. Encuentra
  la palabra o no la encuentra.
- PostgreSQL **si** la hace, con `pg_trgm`, y hay que decirlo en vez de fingir
  que no habia alternativa. Lo que no da es lo demas de un motor dedicado
  (escribir a medias, relevancia, resaltado, sugerencias) sin construirlo a
  mano.

Medido contra este mismo indice, con tres nombres del catalogo:

```
buscando "labtop"   ->  Laptop Ambar Campus 14
                        Laptop Vireo Air 12
                        (el teclado NO sale)
```

## SE ALIMENTA DE MONGO, NO DE POSTGRESQL

Es la decision que mas importa de este ETL y va en mayusculas porque ya se
equivoco una vez, en otro sitio, el mismo dia.

El catalogo vive en MongoDB. **Hay productos que existen SOLO ahi**: los que
publica un vendedor desde el panel nacen en Mongo y no dejan fila en
PostgreSQL. Al 2026-09-04 son cuatro, los `_id` 103 a 106, y se pueden comprar
y resenar como cualquier otro.

Un indice construido desde `productos` de PostgreSQL no los tendria, y el
sintoma seria el peor posible: **un producto que existe, que se vende, y que el
buscador jura que no existe**. Sin ningun error, sin nada en el log.

Es exactamente el mismo agujero que tenia la nota del catalogo hasta esa
manana (ver `docs/PENDIENTES.md`, punto 6). Aparecio dos veces en un dia por la
misma razon, asi que conviene desconfiar de cualquier consulta nueva que
empiece por `FROM productos`.

## El indice se tira entero y se reconstruye

`001_indice.json` trae el mapeo. `etl/cargar_busqueda.sh` borra el indice y lo
vuelve a crear en cada corrida, y eso **no es pereza**: este indice es una
proyeccion, igual que el grafo de Neo4j. No guarda nada que no este en las
otras bases, asi que reconstruirlo entero siempre deja el mismo resultado y no
hay que razonar sobre que sobra ni que falta.

Reconstruir tambien es la unica forma de que **desaparezca** lo que dejo de ser
publico. Un producto que pasa de `activo` a `rechazado` simplemente no vuelve a
entrar.

## Solo entra lo que esta ACTIVO

El indice es para quien compra. Un producto rechazado no se busca.

Se filtra al EXTRAER y no al consultar, a proposito. Filtrar al consultar deja
la puerta a que una ruta se olvide del filtro y ensene productos rechazados a
un comprador; asi, aunque se olvide, no hay nada que ensenar. Cuesta que un
administrador no pueda buscarlos, y ese cambio se hace en
`etl/extraer_busqueda.js`, en una linea.

## El analizador, y por que no lleva raices

`espanol_llano` es `standard` + `lowercase` + `asciifolding`, y nada mas.

`asciifolding` es el que importa. Sin el, buscar **camara** no encuentra
**Camara** con tilde, y esa es la mitad de las busquedas reales en un catalogo
escrito en espanol.

**No** se usa el analizador `spanish` que trae Elasticsearch, aunque suene a que
si. Ese hace raices (stemming), y estos son nombres de producto: marcas y
modelos inventados, no prosa. Cortarle la raiz a "Vireo" o "Ambar" no ayuda a
encontrarlos y si mete ruido. Con difusa activada, ademas, las dos cosas se
pisan.

Tampoco se quitan palabras vacias. "La Cumbre" es un nombre, y un filtro de
palabras vacias se comeria "La".

## Los tres campos de `nombre`

```
nombre               para buscar normal, con difusa
nombre.escribiendo   search_as_you_type, para el buscador predictivo
nombre.exacto        keyword, para ordenar y agrupar sin analizar
```

El de en medio es el que pidio el buscador "de texto predictivo": con el se
puede contestar mientras la persona todavia escribe, sin esperar a que termine
la palabra.

## Como se corre

```bash
bash etl/cargar_busqueda.sh
```

Y sale solo con `.\arrancar.ps1` cuando el indice esta vacio o desfasado.

## Lo que NO esta aqui

**La ruta que lo consulta.** Es de `backend/` y todavia no existe. Hasta que
exista, este indice se prueba con `curl` contra el 9200 y con
`bash pruebas/busqueda.sh`, que es como se documenta en la entrega.

**El millon de productos.** El indice aguanta de sobra; lo que hay que resolver
antes es de donde salen esos ids sin pisar los que reparte PostgreSQL (ver
`docs/PENDIENTES.md`, punto 5). Generar en masa con el margen de hoy machaca
productos.

## El indice guarda TODOS los estados (desde el 2026-09-04)

Antes `etl/extraer_busqueda.js` filtraba `{ estado: 'activo' }` al extraer, y
el razonamiento era bueno: si el filtro vive en el extractor, una ruta que se
olvide de ponerlo no puede ensenarle un producto rechazado a un comprador,
porque no hay nada que ensenar. El precio era que un administrador tampoco los
podia buscar.

Ese precio dejo de ser aceptable: el admin necesita encontrar justo lo que NO
circula, que es lo que va a revisar. Asi que el filtro se mudo al backend:

| Ruta | Filtro de estado | Quien entra |
|---|---|---|
| `GET /buscador/productos` | `activo`, FIJO en el codigo | cualquiera, sin sesion |
| `GET /buscador/productos/admin` | ninguno | solo rol admin, 403 al resto |

El filtro fijo no es un query param: no se le puede pedir lo contrario desde
fuera. Un olvido ahora seria un cambio a proposito en una linea que se ve, no
una omision silenciosa.

**Ojo con reconstruir el indice.** El worker del backend
(`BuscadorSyncService`) indexa todos los estados producto por producto a
medida que se editan. Mientras `extraer_busqueda.js` filtrara por estado, una
reconstruccion completa DESHACIA ese trabajo y dejaba fuera todo lo que no
estuviera activo, sin dar ningun error. Por eso las dos piezas tienen que
mirar el mismo catalogo.

Comprobado despues del cambio, con `bash etl/cargar_busqueda.sh`:

```
total 1105
  activo     1104
  rechazado     1
```

Y el rechazado (`_id` 105) responde 200 en `GET /mesh_productos/_doc/105` con
`"estado": "rechazado"` adentro.

## El segundo indice: eventos de autenticacion (desde el 2026-09-10)

`mesh_eventos_autenticacion` guarda cada intento de entrar -- login bueno o
malo, logout y registro -- para las consultas de fraude del admin. No es una
proyeccion del catalogo: sale de la coleccion `eventos_autenticacion` de
MongoDB, y lo llena **el worker del backend**
(`EventosAutenticacionSyncService`), no un ETL. Cada 5 segundos copia los
eventos con `pendiente_elastic: true`, usando el `_id` de Mongo como `_id`
aqui, asi que copiar dos veces el mismo evento lo sobrescribe.

### Es una PLANTILLA, no un indice

`002_eventos_autenticacion.json` se sube con
`PUT _index_template/mesh_eventos_autenticacion`, para `mesh_eventos_autenticacion*`.

El motivo es que el worker escribe con `index()`, que **autocrea** el indice si
no existe, con mapeo dinamico: `ip` sale como `text` y deja de ser una IP. Paso
de verdad el mismo 2026-09-10, con el primer login del dia. La plantilla actua
sobre cualquier indice que nazca con ese nombre, lo cree quien lo cree, asi que
el orden entre el backend y `arrancar.ps1` deja de importar.

### El mapeo

```
tipo, resultado, motivo,
id_usuario, huella_cliente   keyword, y .keyword (version 2 de la plantilla, 2026-09-20)
identificador_intentado      keyword, y .keyword y .minusculas con un normalizer lowercase
ip                           ip, con ignore_malformed, y .keyword (version 2)
user_agent                   keyword, ignore_above 512
fecha                        date, con ignore_malformed
geo_punto                    geo_point (agregado 2026-09-18)
geo_pais, geo_ciudad         text con .keyword, ignore_above 256 (agregado 2026-09-18)
dynamic                      false
```

- **Los `.keyword` de la version 2** (2026-09-20). Las consultas del backend
  (`fraude-login/viaje-imposible.service.ts`, `toma-cuenta.service.ts` y los servicios
  retrospectivo y de exploracion) piden `id_usuario.keyword`, `tipo.keyword`,
  `resultado.keyword`, `ip.keyword`, `huella_cliente.keyword` e
  `identificador_intentado.keyword`. Con el mapeo de antes esos campos no existian
  (eran `keyword` puros), asi que las consultas daban CERO resultados sin ningun
  error, y por eso la alerta de viaje imposible no podia saltar nunca. Se vio con un
  login real desde Singapur y otro desde Alemania a los dos minutos: los dos estaban
  en el indice, con su pais y su punto, y la consulta exacta del servicio devolvia 0.
  Probado en un indice aparte: con los subcampos devuelve los dos. Los campos sin
  `.keyword` siguen funcionando igual (`term tipo = login`, `term ip = 1.2.3.4`), asi
  que quien consulte de cualquiera de las dos maneras acierta. El arreglo es de este
  lado y no de las consultas para no tocar `backend/`; si Jose David prefiere quitar el
  `.keyword` de sus consultas tambien vale, y los subcampos sobran sin estorbar.
  `arrancar.ps1` detecta un indice sin `id_usuario.keyword`, lo rehace desde la
  plantilla y vuelve a copiar los eventos desde Mongo, igual que con `ip` o `geo_punto`.
- **`ip` es de tipo `ip` y no `keyword`**: acepta rangos CIDR
  (`127.0.0.0/8`) y deja la puerta abierta a geoip. Medido: `::ffff:127.0.0.1`
  entra y se encuentra buscando `127.0.0.1`, y `null` entra sin error.
- **`ignore_malformed` en `ip` y `fecha`**: un valor raro se guarda en `_source`
  y no se indexa, en vez de rechazar el documento. Rechazarlo seria peor que
  perder el campo: el worker lo reintentaria cada 5 segundos para siempre, y
  con 500 de esos la cola se para entera.
- **`.minusculas`** existe para agregar por cuenta sin que las mayusculas la
  partan. El backend guarda el identificador tal cual se tecleo; medido,
  `Admin@Mesh.com`, `admin@mesh.com` y `ADMIN@MESH.COM` son tres cubetas en el
  campo normal y una en `.minusculas`.
- **`dynamic: false`**: si el backend agrega un campo, el documento entra igual
  y el campo queda en `_source`, pero no se busca hasta que alguien lo mapee
  aqui. Con `strict` el documento se rechazaria y pasaria lo del punto de
  arriba.
- **`geo_punto` es SOLO `lat`/`lon`, `geo_pais`/`geo_ciudad` van sueltos y
  aparte, NO anidados dentro de `geo_punto`**: un `geo_point` de Elasticsearch
  solo acepta coordenadas -- el backend lo probo con los tres campos juntos
  dentro de un mismo objeto `geo` y fallo en vivo con
  `document_parsing_exception: field [pais] not supported`. `geo_pais`/
  `geo_ciudad` llevan `.keyword` (no son `keyword` puro, como `ip`/`tipo`)
  porque el backend filtra con `geo_pais.keyword` -- mismo patron que el
  mapeo dinamico les habria dado por defecto, solo que declarado a mano para
  que sobreviva bajo `dynamic: false`. Los tres son `null` cuando la IP es
  privada/local o `geoip-lite` no la resuelve.

### Lo que hace arrancar.ps1

El paso "Indice de eventos de autenticacion", despues del buscador:

1. sube la plantilla (idempotente: un PUT la reemplaza);
2. si el indice no existe, lo crea;
3. si existe pero `ip` no es de tipo `ip`, o `geo_punto` no es de tipo
   `geo_point` -- nacio antes que la plantilla (o antes de que la plantilla
   trajera `geo_punto`), o a mano --, lo tira y lo rehace;
4. en los casos 2 y 3 marca TODOS los eventos de Mongo con `pendiente_elastic`
   para que el worker los vuelva a copiar. Tambien en el 2: un indice que falta
   perdio lo que tenia, y sin marcar se queda vacio para siempre (medido);
5. dice cuantos eventos hay en Mongo, cuantos en el indice y cuantos faltan;
6. si el indice mas los pendientes no llegan a lo que hay en Mongo, marca todo
   igual. Cubre el indice que el worker recreo solo con la plantilla y el
   arranque que se cayo entre tirar el indice y marcar: en los dos casos el
   indice existe, tiene `ip` de tipo `ip` y le faltan eventos. Copiar dos veces
   no duplica, porque el `_id` es el de Mongo.

No corta el arranque si falla. El login no depende de este indice.
