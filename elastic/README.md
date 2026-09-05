# El motor de busqueda

Elasticsearch, la QUINTA base. Entra en la Entrega 3 y es lo que contesta
cuando alguien escribe mal el nombre de un producto.

```
localhost:9200    la API, sin contrasena y solo en local
indice            mesh_productos
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
