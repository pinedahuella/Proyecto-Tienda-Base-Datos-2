# Guia de estudio, los vectores de Mesh

Para la presentacion final. Dice donde vive cada vector, quien lo calcula, cada
lugar donde se usa, en que linea esta y donde se hace clic en la tienda para
verlo. Las lineas son las del repositorio al 5 de noviembre de 2026. Si el
profesor pregunta por una funcion, primero se abre el archivo en esa linea y
despues se explica.

Las cifras salen de la base de la PC de Jose David, medidas la noche del 5 de
noviembre.

## 1. La idea en dos minutos

Un vector es una lista de 768 numeros que representa el significado de un
texto. Lo calcula el modelo `paraphrase-multilingual`, que corre en Ollama en la
misma PC del backend. Dos textos que dicen lo mismo con otras palabras dan
vectores cercanos. Que tan cerca estan se mide con el coseno, de -1 a 1, y en la
tienda se ensena como porcentaje de parecido.

- Se calcula un vector por producto, con el texto `nombre. Categoria X.
  descripcion`.
- Se calcula un vector por resena o respuesta, con su texto.
- Los dos se guardan en PostgreSQL con la extension pgvector, cada uno en su
  tabla y con un indice HNSW para buscar vecinos sin compararse contra todos.
- Ningun texto sale a un servicio externo y no hay costo por consulta.

| Que | Cuantos hoy |
|---|---|
| Productos con vector en `vector_producto` | 1003, de ellos 1000 activos |
| Comentarios con vector en `vector_comentario` | 787 de 787 |
| Comentarios con valoracion del clasificador | 758 |
| Modelo | `paraphrase-multilingual`, 768 dimensiones |
| Version de pgvector | 0.8.6 |

## 2. Donde viven

| Que | Archivo y linea | Para que |
|---|---|---|
| La extension `vector` | `migrations/024_vectores_productos.sql:56` | Le ensena a PostgreSQL el tipo `vector` y el operador `<=>` |
| Tabla `vector_producto` | `migrations/040_vectores_en_postgres.sql:40` | Un vector por producto, con `texto_hash`, `grupo`, `activo` y `modelo` |
| Columna `vector vector(768)` | `migrations/040_vectores_en_postgres.sql:44` | Los 768 numeros |
| Indice HNSW de productos | `migrations/040_vectores_en_postgres.sql:69` | `USING hnsw (vector vector_cosine_ops)`, vecinos por coseno |
| Tabla `vector_comentario` | `migrations/040_vectores_en_postgres.sql:75` | Un vector por comentario, mas la valoracion del texto |
| `valoracion_texto` y `prob_mala` | `migrations/040_vectores_en_postgres.sql:83` y `:85` | Lo que dijo el clasificador, mala, buena, dudosa o corta |
| La cola de comentarios | `migrations/034_evento_comentario.sql:33` | `evento_comentario`, la llenan los triggers de `:100` y `:139` |
| La bandera de productos | `backend/src/models/producto.ts:167` | `pendiente_vector` en MongoDB, avisa que hay que recalcular |

Por que tablas aparte y no una columna en `producto_catalogo`. Los triggers de
comentario encolan cada cambio del texto, y si el worker escribiera el vector en
la misma fila se volveria a encolar solo. Ademas la tabla aparte tiene la FK con
`ON DELETE CASCADE`, asi que un producto borrado se lleva su vector.

Historia, para la pregunta de por que cambio de lugar. Hasta el 2 de octubre el
vector estaba en `producto_vector` de PostgreSQL (migracion 024). Del 2 al 16
de octubre estuvo en el indice `mesh_productos` de Elasticsearch (la 036 quito la
tabla). Desde el 16 de octubre esta otra vez en PostgreSQL, en `vector_producto`
(migracion 040), porque el profesor pidio pgvector y porque medido contra el
coseno exacto pgvector acerto 1000 de 1001 y el indice de Elasticsearch 317.
Esta en el informe final, 2.2, y en ADR-13.

## 3. Quien los calcula

### 3.1 La llamada a Ollama

| Funcion | Archivo y linea | Que hace |
|---|---|---|
| `OLLAMA_URL`, `OLLAMA_MODELO` | `backend/src/database/ollama.ts:16` y `:17` | Donde esta Ollama y que modelo usar, del `backend/.env` |
| `pedirVectores()` | `backend/src/helpers/vectores-ollama.ts:33` | Hace `POST /api/embed` a Ollama con una lista de textos y devuelve un vector por texto |
| `LOTE_VECTORES = 32` | `backend/src/helpers/vectores-ollama.ts:8` | Cuantos textos van en una sola llamada |
| `DIMENSIONES_VECTOR = 768` | `backend/src/helpers/vectores-ollama.ts:12` | El largo que esperan las columnas `vector(768)` |
| `keep_alive: -1` | `backend/src/helpers/vectores-ollama.ts:44` | Que Ollama no descargue el modelo a los 5 minutos. Recargarlo hacia que la primera busqueda tardara 8 s |
| `md5()` | `backend/src/helpers/vectores-ollama.ts:58` | Huella del texto, para saber si cambio desde el ultimo vector |

### 3.2 Los productos

- **Carga completa**, `etl/cargar_vectores.ps1`. La corre `arrancar.ps1` en el
  paso 7d (`arrancar.ps1:1488`). Lee nombre, categoria y descripcion de MongoDB
  (`etl/cargar_vectores.ps1:250`), arma el texto en `:268`, calcula el md5 en
  `:263` y solo pide a Ollama los productos sin vector o cuyo texto cambio.
- **Al dia**, `VectoresSyncService` en
  `backend/src/services/productos/vectores-sync.service.ts:66`. Corre cada 10
  segundos (`:73` y `:77`). Cuando un vendedor crea o edita un producto,
  `backend/src/services/vendedores/productos.service.ts` le pone
  `pendiente_vector: true` en MongoDB (lineas 205, 327, 633, 742 y 1300). El
  worker arma el mismo texto con `construirTexto()`
  (`vectores-sync.service.ts:42`), compara su md5 con `texto_hash`, y solo si
  cambio llama a `pedirVectores()` (`vectores-sync.service.ts:180`). Si solo
  cambio el estado, actualiza `grupo` y `activo` sin Ollama
  (`vectores-sync.service.ts:158`). Al final borra la bandera
  (`vectores-sync.service.ts:226`).

El `grupo` es el md5 de la categoria y la descripcion, sin el nombre
(`etl/cargar_vectores.ps1:273` y `vectores-sync.service.ts:145`). Las copias
que hizo el generador de datos solo cambian el sufijo del nombre, asi que caen
en el mismo grupo y no salen como parecidas entre si.

### 3.3 Las resenas

- `EventoComentarioSyncService`,
  `backend/src/services/resenas/evento-comentario-sync.service.ts:67`, cada 10
  segundos (`:70` y `:88`). Lee la cola `evento_comentario`, pide los vectores
  a Ollama (`:277`) y los guarda con `INSERT ... ON CONFLICT` (`:327`). Si el
  comentario se borro, quita su vector (`:344`).
- `ValoracionComentariosService`,
  `backend/src/services/resenas/valoracion-comentarios.service.ts:41`, cada 30
  segundos (`:44` y `:54`). Con el vector ya guardado calcula si el texto suena
  bueno o malo con `valorarTexto()` (`backend/src/helpers/valoracion-texto.ts:122`)
  y lo escribe en `vector_comentario` (`valoracion-comentarios.service.ts:125`).
  No llama otra vez a Ollama.

## 4. Como se consulta un vector

Todo pasa por `backend/src/helpers/vectores-pgvector.ts`.

| Funcion | Linea | Que hace |
|---|---|---|
| `aVectorPg()` | `:16` | Convierte la lista de numeros al texto que entiende pgvector, `[0.1,0.2,...]` |
| `buscarCercanos()` | `:41` | Corre una busqueda de vecinos `ORDER BY vector <=> $1 LIMIT k` dentro de una transaccion |
| `set_config('hnsw.ef_search', ...)` | `:50` | Cuantos candidatos mira el indice HNSW. Por defecto son 40 y con filtros volvian menos filas |
| `set_config('hnsw.iterative_scan', 'strict_order', ...)` | `:51` | Si el filtro descarta candidatos, el indice sigue buscando y entrega en orden de distancia |
| `paresParecidos()` | `:74` | Los pares de comentarios cuyo coseno pasa un umbral. La cuenta la hace PostgreSQL, los vectores no salen de la base |

El operador `<=>` es la distancia coseno, de 0 a 2. El parecido que se ensena es
`1 - distancia`. Se pasa el vector como parametro y no como subconsulta, porque
con subconsulta o con JOIN el planificador no usa el indice. Eso se descubrio con
la migracion 027, que bajo de 32 ms a 3,8 ms por producto.

## 5. Cada lugar donde se usan

### 5.1 Parecidos a este (la recomendacion semantica que pide el enunciado)

- **Donde se ve.** Tienda, abrir cualquier producto, bajar al estante
  **Parecidos a este**.
- **Frontend.** `frontend/src/routes/producto/[id]/+page.svelte:178`
  (`traerSimilares`) pide la ruta y el estante esta en `:1204`.
- **Ruta.** `GET /productos/:id/similares`, publica, en
  `backend/src/controllers/productos/similares.controller.ts:20`.
- **Servicio.** `SimilaresService` en
  `backend/src/services/productos/similares.service.ts:57`.

Como decide los seis, desde el 5 de noviembre, con el mismo esquema que
"Quienes lo compraron tambien llevaron" (ADR-25).

1. Lee el vector, el grupo y la categoria del producto (`:86`, la consulta en
   `:93`).
2. **Bloque 1, su misma categoria.** Busca los mas cercanos solo entre los
   productos activos de su categoria (`:107`, el `ORDER BY` en `:119`).
3. **Bloque 2, el resto del catalogo.** La consulta de siempre con el indice
   HNSW, los 200 mas cercanos de todo el catalogo (`:127`).
4. Llena los seis en ese orden, uno por grupo, sin el propio producto ni sus
   copias, primero el bloque 1 entero y lo que falte con el bloque 2 (`:170` y
   `:171`). Cada resultado dice `misma_categoria` true o false.

Un producto de la misma categoria con 0,40 de parecido va antes que uno de otra
categoria con 0,80. Por ejemplo el Maillot de ruta Peloton (id 70) ensena cinco
de Ciclismo, la Bomba de piso Piston con 45,6 %, y despues una comoda con 65,7 %.

Cifras de la noche del 5 de noviembre.

| Medicion | Resultado |
|---|---|
| La ruta contra el mismo orden calculado sin indice, en los 1000 productos activos | 1000 de 1000 iguales, mismo orden y mismos bloques |
| Solo por el vector, sin mirar la categoria, vecinos de la misma categoria | 68,1 %, contra 6 % al azar |
| En la ficha, con la categoria primero | 84,5 % de los parecidos son de su categoria |
| Consulta del bloque 2 con el indice HNSW | 1,9 ms, contra 3,2 ms comparando contra los 1003 |

Por que el 68,1 % sigue siendo la prueba de que el modelo entiende. Al modelo
nunca se le dice la categoria como dato aparte, solo la lee dentro del texto. Si
solo con el vector dos de cada tres vecinos son de la misma categoria, contra 6
de cada cien al azar, el vector capto de que trata el producto. El 84,5 % ya
incluye la regla del bloque 1, por eso no se usa como prueba del modelo.

### 5.2 Busqueda hibrida

- **Donde se ve.** Buscar una frase en la tienda, por ejemplo `algo para salir a
  pedalear`. La pagina `/buscar` mezcla lo que encontro por palabras con lo que
  encontro por significado.
- **Frontend.** `frontend/src/lib/buscador.ts:196` (`buscarHibrida`) y el filtro
  `filtrarHibrida` en `:180`, llamados desde `frontend/src/routes/buscar/+page.svelte:197`.
- **Ruta.** `GET /buscador/productos/hibrida`,
  `backend/src/controllers/buscador/hibrida.controller.ts:20`.
- **Servicio.** `BuscadorHibridoService`,
  `backend/src/services/buscador/hibrida.service.ts:125`.
  - Por palabras en Elasticsearch, `buscarPorTexto()` en `:186`.
  - Por significado en PostgreSQL, `vectorDe()` en `:169` pide el vector de la
    frase y `buscarPorSignificado()` en `:247` busca los vecinos, con el umbral
    `UMBRAL_COSENO = 0.4` de `:39`.
  - Las dos listas se juntan por posicion con RRF, `combinar()` en `:352`, con
    `RRF_K = 60` de `:33`. Cada lista aporta `1 / (60 + posicion)`.
- Si Ollama no contesta, no falla, contesta solo con la busqueda por palabras.

### 5.3 Busqueda por intencion

- **Donde se ve.** En `/buscar`, con una frase de tres palabras o mas, sale la
  seccion **Lo que cuentan otros compradores**, con la resena que explica por que
  sale cada producto.
- **Frontend.** `frontend/src/lib/buscador.ts:262` (`buscarPorIntencion`),
  `pareceFrase()` en `:232` decide si es frase, y el filtro `vale()` en `:247`.
  La seccion esta en `frontend/src/routes/buscar/+page.svelte:311`.
- **Ruta.** `GET /buscador/productos/intencion`,
  `backend/src/controllers/buscador/intencion.controller.ts:22`.
- **Servicio.** `BuscadorIntencionService`,
  `backend/src/services/buscador/intencion.service.ts:105`. Busca en las resenas
  (`buscarResenas()` en `:194`, sobre `vector_comentario`) y en los productos
  (`buscarProductos()` en `:239`), con umbrales de `:34` y `:35`, y junta por
  producto en `juntar()` (`:265`).
- Sin Ollama da 503, porque sin el vector de la frase no hay nada que buscar.

### 5.4 Sugerencias al proponer un producto

- **Donde se ve.** Panel, pestana **Catalogo**, boton **Publicar producto**. Al
  escribir el nombre, la tienda sugiere la categoria y ensena productos
  parecidos, con el aviso **Puede que ya exista**.
- **Frontend.** `frontend/src/lib/PanelVendedor.svelte:568` (`sugerir`), el aviso
  en `:1125`.
- **Ruta.** `POST /vendedor/productos/sugerencias`, con el permiso
  `catalogo.proponer`,
  `backend/src/controllers/vendedores/sugerencias-propuesta.controller.ts:30`.
- **Servicio.** `SugerenciasPropuestaService`,
  `backend/src/services/vendedores/sugerencias-propuesta.service.ts:110`. Los
  vecinos votan por su categoria (`categoriasDe()` en `:221`), y con 0,85 o mas
  (`UMBRAL_DUPLICADO` en `:37`) se marca como posible duplicado.

### 5.5 Sugeridos cuando una busqueda no encuentra nada

- **Donde se ve.** Buscar algo sin sentido, por ejemplo `xqzwv`. La cabecera
  dice "No encontramos eso. Quizas te interesen estos"
  (`frontend/src/lib/BuscadorCabecera.svelte:340`).
- **Servicio.** `SugeridosBusquedaService`,
  `backend/src/services/buscador/sugeridos.service.ts:77`. Primero pregunta a
  Elasticsearch. **Solo si Elasticsearch no responde** usa los vectores,
  `porSignificado()` en `:152`. Despues lo mas vendido y lo mas resenado.

### 5.6 Fraude por el texto de las resenas

Los vectores de las resenas alimentan cuatro detectores. Corren cada 15 minutos
y tambien al instante cuando alguien escribe una resena.

| Senal | Servicio y linea | Que busca | Umbral |
|---|---|---|---|
| `resenas_repetidas` | `backend/src/services/fraude/resenas-repetidas-detector.service.ts:63` | Una cuenta que escribe la misma resena una y otra vez | coseno 0,92 (`:85`) |
| `resenas_parecidas_vendedor` y `_producto` | `backend/src/services/fraude/resenas-parecidas-detector.service.ts:98` | Resenas copiadas entre cuentas sobre un vendedor o un producto | coseno 0,92 (`:115`) |
| `anillo_de_texto` | `backend/src/services/fraude/anillo-de-texto-detector.service.ts:67` | Tres cuentas o mas con casi la misma resena a un vendedor | coseno 0,92 (`:84`) |
| `notas_incoherentes_*` | `backend/src/services/fraude/notas-incoherentes-detector.service.ts:123` | Estrellas que contradicen el texto, la condicion SQL en `:70` | lo decide el clasificador |

- El chequeo al instante es `ChequeoTextoInmediatoService`
  (`backend/src/services/fraude/chequeo-texto-inmediato.service.ts:53`). Lo
  llama `backend/src/services/resenas/resenas.service.ts:334` sin esperar, asi
  que no retrasa la respuesta al comprador.
- Cuanto suma cada senal al puntaje de una cuenta esta en
  `backend/src/services/fraude/puntaje-fraude.service.ts:23` a `:26`.
- **Donde se ve.** Panel del admin, pestana **Fraude**. En la base de David hay
  senales de tres de ellos, `resenas_repetidas`, `resenas_parecidas_producto` y
  `notas_incoherentes_producto`.

### 5.7 El clasificador de resenas

- Esta en `clasificador-resenas/`. `1_vectorizar.py` pide el vector de 480
  resenas escritas a mano y `2_entrenar.py` entrena una regresion logistica y una
  red neuronal hechas a mano con numpy.
- El backend solo carga los pesos de `backend/modelos/regresion_logistica.json`
  (`modeloValoracion()` en `backend/src/helpers/valoracion-texto.ts:62`) y hace
  la cuenta `sigmoide(x . w + b)` en `probabilidadMala()` (`:98`).
- Una resena de menos de 100 caracteres no se valora (`:29`), queda como `corta`.

## 6. Si se cae algo

| Si se cae | Que pasa con los vectores |
|---|---|
| Ollama | Parecidos a este sigue igual, porque los vectores ya estan guardados. La hibrida contesta solo por palabras. Intencion y sugerencias al proponer dan 503. Los vectores nuevos esperan en la cola y en la bandera |
| PostgreSQL | No hay parecidos ni busquedas por significado. Esta en la 4.4 del informe final |
| MongoDB | Los parecidos salen igual, el detalle de cada tarjeta viene de la copia del catalogo en PostgreSQL |

## 7. Como se ensena y como se prueba

| Que | Comando |
|---|---|
| Los seis parecidos de un producto, con sus dos bloques, el plan del indice y la ruta | `.\demo-entrega-final.ps1 -Parte semantica -Producto maillot` |
| Cuantos productos y resenas tienen vector y si el backend llega a Ollama | `.\demo-entrega-final.ps1 -Parte vectores` |
| La busqueda por intencion | `.\demo-entrega-final.ps1 -Parte intencion -Texto "algo para salir a pedalear"` |
| La hibrida y las sugerencias | `-Parte hibrida` y `-Parte sugerencias` |
| Como leyo el clasificador cada resena | `-Parte clasificador` |
| La prueba de la recomendacion | `python pruebas/recomendacion_semantica.py`, 21 OK |
| El worker calcula lo mismo que el ETL | `node pruebas/vectores_worker.cjs` |
| Si Ollama responde y tiene el modelo | `GET http://localhost:3000/vectores` |

`pruebas/recomendacion_semantica.py` comprueba que cada producto tiene su vector
de 768, que solo por el vector los vecinos son de la misma categoria mucho mas
que al azar (seccion 2), que la ficha va por bloques y que `misma_categoria` dice
la verdad (seccion 2b), y que nunca devuelve el propio producto, inactivos ni
copias. La seccion 2b se probo saboteandola con el orden viejo y dio 2 FALLA.

## 8. Preguntas que puede hacer el profesor

**Por que 768 numeros.** Es lo que devuelve `paraphrase-multilingual`. La columna
es `vector(768)` y `DIMENSIONES_VECTOR` lo revisa al cargar los pesos del
clasificador.

**Por que coseno y no distancia euclidiana.** El modelo se entreno para que dos
frases con el mismo sentido apunten en la misma direccion, sin importar el largo
del texto. El indice se crea con `vector_cosine_ops` y la consulta usa `<=>`.

**Que es HNSW.** Un grafo de vecinos en capas. La busqueda baja por las capas
saltando a vecinos cada vez mas cercanos y no compara contra todos. Es
aproximado, por eso se midio contra el calculo exacto.

**Que es `ef_search`.** Cuantos candidatos mira el indice en cada busqueda. Con
el valor de fabrica, 40, el filtro de activos dejaba menos filas de las pedidas.
`buscarCercanos()` lo sube solo dentro de su transaccion.

**Como sabe el worker que un texto cambio.** Guarda el md5 del texto en
`texto_hash`. Si el md5 nuevo es igual, no llama a Ollama.

**Que es el grupo.** El md5 de la categoria y la descripcion, sin el nombre.
Junta las copias del generador de datos, que solo cambian el sufijo del nombre,
para que no salgan como parecidas entre si.

**Por que primero la misma categoria.** Se pidio el mismo esquema que "Quienes lo
compraron tambien llevaron" para que en la ficha de una laptop salgan primero
laptops. El vector sigue decidiendo el orden dentro de cada bloque.

**Por que no se guarda el vector en MongoDB o Elasticsearch.** Se probo en
Elasticsearch del 2 al 16 de octubre. El profesor pidio pgvector y medido contra
el coseno exacto pgvector acerto 1000 de 1001 y Elasticsearch 317, por la
cuantizacion de su indice `int8_hnsw`.

**Donde se calcula el vector de una frase que escribe el comprador.** En el
momento, con el mismo modelo, `vectorDe()` de cada servicio de busqueda, que
llama a `pedirVectores()` con un limite de tiempo corto.
