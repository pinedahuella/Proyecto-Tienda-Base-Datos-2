# El motor de busqueda

Elasticsearch, la QUINTA base. Entra en la Entrega 3 y es lo que contesta
cuando alguien escribe mal el nombre de un producto.

```
localhost:9200    la API, sin contrasena y solo en local
indices           mesh_productos               el buscador del catalogo       001_indice.json
                  mesh_eventos_autenticacion   el log de logins (ver al final) 002_eventos_autenticacion.json
                  mesh_ofertas                 el buscador de ofertas         004_ofertas.json
                  mesh_seguimientos            el percolator de los avisame   005_seguimientos.json
```

El `003_comentarios.json` (`mesh_comentarios`, las resenas con su vector) ya no
existe: desde el 2026-10-16 los vectores viven en PostgreSQL (ver "Los vectores
volvieron a PostgreSQL", abajo).

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

## Filtros facetados y autocompletado (2026-09-25)

La consulta esta escrita y probada en `pruebas/facetas.py`, y el backend solo
tiene que copiarla. La funcion `consulta()` arma el cuerpo de la busqueda y
`autocompletar()` el de las sugerencias. Hay un ejemplo ya armado en
`consultas/facetas_ejemplo.json`.

Cuatro facetas, todas con agregaciones del motor.

```
categoria      terms sobre id_categoria, con su nombre
precio         range sobre precio_desde, cinco tramos sacados de los percentiles
calificacion   range sobre resenas_promedio, 4 o mas y 3 o mas
disponible     filter sobre stock_total mayor que cero
```

El texto va en el `must` de la consulta y los filtros elegidos en su `filter`,
junto con el de activo. Se filtra antes de agregar: los conteos salen de lo que
ya paso todos los filtros, y cada numero del panel es cuantos resultados hay de
verdad con esa opcion sumada a lo elegido. Dentro de una faceta las opciones se
suman, entre facetas se cruzan.

Hasta el 2026-10-20 los filtros iban en `post_filter`, que corre despues de las
agregaciones, y cada faceta se contaba con los filtros de las otras (con Laptops
elegida, la faceta seguia diciendo cuantos habia en Monitores). El profesor lo
observo en la revision de otro grupo: si el filtro ya se sabe, va en la consulta
desde el principio y no despues en los agregados. Se cambio la consulta, el
backend (`services/buscador/facetado.service.ts`) y esta prueba. La contra,
aceptada: con una categoria elegida las demas salen del panel, y para cambiar de
categoria se quita la elegida.

Sin Elasticsearch, el backend hace la misma busqueda con los mismos filtros y
las mismas facetas sobre la copia del catalogo en PostgreSQL
(`backend/src/helpers/buscador-respaldo.ts`, migracion 048). Y si una busqueda
no encuentra nada, la respuesta trae `sugeridos` aparte, para que la pagina
nunca quede vacia. Los elige Elasticsearch con una segunda consulta mas
tolerante, que ordena por parecido y, si nada se parece, por resenas, nota y
existencias (`consultaSugeridos` en `backend/src/services/buscador/sugeridos.service.ts`).
Sin Elasticsearch salen de los vectores en PostgreSQL o de lo mas vendido (ver
`docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md`).

El autocompletado usa `nombre.escribiendo` con `bool_prefix`. La busqueda de
hoy no lo usa, y con "lap" trae 507 productos de cualquier tipo. Con
`autocompletar()` trae los que empiezan por "lap".

Desde el 2026-10-20 la lista del buscador de la cabecera usa las dos juntas
(`GET /buscador/productos?escribiendo=1`): el `bool_prefix` con peso 20 y la
difusa de siempre, y un resultado por producto (sin sus copias de lote). Antes
iba solo con la difusa y "lap" daba ocho veces "El camino de las nubes" (lo
tomaba por "las") y "lapt" no daba nada. Sin Elasticsearch la copia de
PostgreSQL hace lo mismo con la opcion `prefijo` de `buscarEnCopia`. La pagina
/buscar no cambia. `node pruebas/buscador_escribiendo.mjs` da 20 OK.

```bash
python elastic/pruebas/facetas.py      # solo Elasticsearch arriba, 26 OK
```

Cada comprobacion tiene su control, y se probo rompiendo la consulta a
proposito dos veces. La prueba detecto las dos.

## Como se corre

```bash
bash etl/cargar_busqueda.sh
```

Y sale solo con `.\arrancar.ps1` cuando el indice esta vacio o desfasado: cuando
sus documentos no son los de MongoDB (TODOS, no solo los activos: hasta el
2026-10-04 se comparaba contra los activos y se rehacia en cada arranque), o
cuando todavia trae el campo `vector` del mapeo del 2026-10-02 al 10-16.

## Los vectores volvieron a PostgreSQL (2026-10-16)

Del 2026-10-02 al 10-16 el vector de cada producto iba en su documento de
`mesh_productos` (los campos `vector`, `vector_hash`, `vector_grupo` y
`vector_modelo`) y el de cada resena en un tercer indice, `mesh_comentarios`
(`003_comentarios.json`). A pedido del profesor (25f0fe0 de Jose David,
migracion 040) volvieron a PostgreSQL, a las tablas `vector_producto` y
`vector_comentario` con pgvector. El porque, medido, esta en el ADR-10 de
`docs/ARQUITECTURA.md`: con el mismo catalogo pgvector da el coseno exacto en
1000 de 1001 productos y el `int8_hnsw` de Elasticsearch en 317.

Lo que quedo de esa epoca y como se limpia solo:

- `001_indice.json` ya no trae los campos de vector. Una maquina que tenga el
  indice viejo lo rehace en el siguiente `.\arrancar.ps1`, DESPUES de que
  `etl/cargar_vectores.ps1` copie esos vectores a `vector_producto` sin Ollama
  (mismo hash, mismo modelo). Medido el 2026-10-18 en la base local: 3105 de
  3105 copiados.
- `mesh_comentarios` y `mesh_productos_vectores_previos` los borra arrancar,
  despues de encolar los comentarios para que el worker del backend calcule sus
  vectores en `vector_comentario`.

Elasticsearch se queda con lo suyo: la busqueda por palabras de
`mesh_productos` (difusa, sugerencias, facetas, "quisiste decir"), las ofertas,
el percolator y el log de autenticacion. La busqueda hibrida pide las palabras
aqui y el significado a PostgreSQL, y las junta por posicion.

## El buscador de ofertas, `mesh_ofertas` (desde el 2026-10-17)

`004_ofertas.json`. Un documento por oferta con lo justo para encontrarla:
nombre del producto y de la variante, vendedor (usuario, nombre y estado),
precio, descuento, precio final, stock y estado. No van las fechas ni la
aprobacion: el indice sirve para encontrar, lo demas se lee de PostgreSQL. Es
`dynamic: strict`, asi que un campo de mas en el worker falla en
`evento_oferta.ultimo_error` en vez de crearse adivinado.

Lo llena el worker `EventoOfertaSyncService` del backend (cada 5 s) desde la
cola `evento_oferta` (migracion 043), que alimentan cuatro triggers: la oferta,
el nombre del producto, el nombre y estado de la variante, y el nombre y estado
del vendedor. Lo lee `GET /vendedor/ofertas/buscar`, con un `resumen` hecho con
agregaciones. El worker no crea el indice: lo crea arrancar (paso 9e) y, la vez
que lo crea, encola todas las ofertas. Prueba: `bash pruebas/ofertas_y_seguimientos.sh`.

## El percolator, `mesh_seguimientos` (desde el 2026-10-17)

`005_seguimientos.json`. Al reves que los demas, aqui se guardan CONSULTAS:
cada "avisame" de un comprador (una busqueda que no encontro nada, o la baja de
precio de una variante) es una consulta guardada en el campo `consulta`, de
tipo `percolator`, con el id del seguimiento. Cada oferta que indexa el worker
de ofertas se pasa por aqui; la primera que coincide genera UN aviso en
PostgreSQL y la consulta se borra. `nombre_completo` junta producto y variante
con `copy_to` para que "laptop 16 gb" coincida aunque las palabras esten en los
dos.

La verdad es `seguimiento_oferta` de PostgreSQL (migracion 044). Si el indice se
pierde o no cuadra con los seguimientos que esperan, arrancar lo rehace y
vuelve a cargar sus consultas: las arma PostgreSQL con jsonb, con la misma forma
que `consultaDelSeguimiento()` del backend (ver `Preparar-IndiceSeguimientos`).

## Lo que NO esta aqui

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
