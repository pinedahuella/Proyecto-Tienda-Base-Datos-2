GUIA DE PRESENTACION - MESH (Bases de Datos 2)
Respuestas con archivo, linea y texto exacto para buscar con Ctrl+F.
====================================================================

ACTUALIZADA EL 2026-08-30. Se escribio para la Entrega 1 y sigue valiendo
entera; lo que cambio desde entonces esta marcado con [AL DIA 30-AGO] y
resumido al final, en la PARTE 9. Los numeros de esta guia se remidieron
contra una base recien creada con  .rrancar.ps1 -Reiniciar

INDICE DE ESTA GUIA
  PARTE 1 - EL ETL (esta la explicas vos, va desarrollada)
  PARTE 2 - Indice compuesto
  PARTE 3 - Como se relacionan las dos bases
  PARTE 4 - Que guardamos en Mongo y por que
  PARTE 5 - Donde esta el codigo de Mongo
  PARTE 6 - Sincronizacion (la pregunta trampa)
  PARTE 7 - Como probamos que usamos los dos modelos
  PARTE 8 - Extras: contenedores, transparencia, numeros


####################################################################
PARTE 1 - EL ETL          <<<<  ESTA LA EXPLICAS VOS
####################################################################

--------------------------------------------------------------------
1.1  LA IDEA EN UNA FRASE (arranca con esto)
--------------------------------------------------------------------
"El ETL toma los productos que estan en PostgreSQL, les cambia la forma
para que sean documentos, y los escribe en MongoDB. Lo dificil no es
mover los datos: es que en PostgreSQL el historial son FOTOS y en Mongo
necesitamos EVENTOS."

Esa ultima frase es la clave de toda la explicacion. Si la dicen bien,
lo demas se entiende solo.

Que quiere decir:

  En PostgreSQL       productos_historial guarda, por cada cambio, una
  (FOTOS)             fila con el estado COMPLETO del producto ese dia.
                      Es lo natural en SQL.

  En MongoDB          productos_eventos guarda, por cada cambio, SOLO
  (EVENTOS)           lo que cambio. El primero es la creacion y lleva
                      todo; los siguientes solo el campo tocado.

  Ejemplo real, producto 19 (la camisa de lino):
    evento 1  12 ene  creacion       nombre + descripcion + variantes
    evento 2   4 mar  modificacion   solo la descripcion
    evento 3  12 mar  modificacion   solo las variantes
    evento 4   4 may  modificacion   solo el nombre

  Reconstruir al 1 de junio = aplicar los cuatro EN ORDEN.
  Si tomaras solo la creacion + la ultima modificacion, tendrias el
  nombre correcto pero la descripcion vieja. Ese es el punto.


--------------------------------------------------------------------
1.2  LOS ARCHIVOS (carpeta etl/)
--------------------------------------------------------------------
  extraer.sql             348 lineas   E - saca un JSON por producto
  extraer_categorias.sql   66 lineas   E - saca la paleta de categorias
  cargar.js               389 lineas   T y L - transforma y escribe
  reconstruir.js           76 lineas   la consulta de "como estaba tal dia"
  correr.sh                52 lineas   los encadena (solo Linux/Mac)

Dato para decir: NO HAY NADA QUE INSTALAR. PostgreSQL arma el JSON el
solo con jsonb_build_object, y mongosh ya viene dentro del contenedor
de Mongo. El ETL no tiene dependencias.


--------------------------------------------------------------------
1.3  EXTRACCION  ->  archivo etl/extraer.sql
--------------------------------------------------------------------
Ctrl+F:   jsonb_build_object          (linea 71 y 85)
Ctrl+F:   CASE td.tipo_dato           (linea 186)
Ctrl+F:   WHEN 'lista'                (linea 187)

Que decir: "la extraccion es SQL puro. PostgreSQL nos entrega el
producto YA con forma de documento, no filas sueltas."

Y OJO CON ESTO, es lo mas tecnico y lo que mas puntos da:
LA CONVERSION DE TIPOS SE HACE EN EL SQL, NO EN JAVASCRIPT.

  extraer.sql, linea 186 en adelante:

      'valor',  CASE td.tipo_dato
          WHEN 'lista'    THEN jsonb_agg(to_jsonb(pc.valor) ...)
          WHEN 'entero'   THEN to_jsonb((array_agg(pc.valor))[1]::bigint)
          WHEN 'decimal'  THEN to_jsonb((array_agg(pc.valor))[1]::numeric)
          WHEN 'booleano' THEN to_jsonb((array_agg(pc.valor))[1]::boolean)
          ELSE                 to_jsonb((array_agg(pc.valor))[1])
      END

  POR QUE HACE FALTA:
  En PostgreSQL la columna producto_caracteristica.valor es 'text' para
  los cuatro tipos a la vez, porque una sola columna no puede tener un
  tipo distinto por fila. Eso es una atadura del modelo relacional.
  Mongo NO la hereda: ahi el 10 se guarda como numero 10, no como "10".
  Si no se convirtiera, filtrar por rango (min_/max_) no funcionaria.

  Y EL CASO 'lista' ES EL MEJOR EJEMPLO DE LA DIFERENCIA ENTRE MODELOS:
  una caracteristica de tipo lista, por la Primera Forma Normal, en el
  relacional son VARIAS FILAS repetidas con el mismo nombre. En el
  documento es UNA entrada con un arreglo adentro. Eso es exactamente
  lo que un documento puede y una tabla normalizada no.


--------------------------------------------------------------------
1.4  TRANSFORMACION  ->  archivo etl/cargar.js   (EL CORAZON)
--------------------------------------------------------------------
Son tres funciones que se llaman en cascada. Explicalas en este orden:

  Ctrl+F:   function vigenteEn        (linea 73)
  Ctrl+F:   function estadoEn         (linea 92)
  Ctrl+F:   function diferencias      (linea 152)
  Ctrl+F:   function eventosDe        (linea 162)


  a) vigenteEn(filas, t)      linea 73
     "de todas las filas de historial, dame la que regia en la fecha t"
     O sea: la ultima con fecha <= t. Nada mas.

  b) estadoEn(producto, t)    linea 92
     Arma el estado COMPLETO del producto en la fecha t.
     Dos detalles que puedes citar:
       - una variante que nacio despues de t NO entra
       - se agrupa por id para quedarse con la ultima version de cada una

  c) diferencias(antes, ahora)   linea 152
     Compara dos estados campo por campo:

         if (JSON.stringify(antes[campo]) !== JSON.stringify(ahora[campo]))

     LA COMPARACION ES POR CAMPO DE PRIMER NIVEL, y es a proposito.
     Si cambia algo DENTRO de la categoria, se guarda la CATEGORIA
     ENTERA. Si cambia algo en una variante, se guarda el ARREGLO DE
     VARIANTES ENTERO.
     POR QUE: porque la reconstruccion usa $mergeObjects, que mezcla
     superficial. Si guardaramos media categoria, al fusionar borraria
     la otra mitad.

  d) eventosDe(producto)      linea 162   <- el algoritmo completo

     Ctrl+F:  const orden = [...new Set(fechas)]     (linea 178)

     Pasos, en orden:
       1. calcula el nacimiento (primera fila de historial)
       2. junta las fechas de LOS DOS historiales:
          producto.historial_producto + producto.historial_variantes
       3. las convierte a numero con Date.parse, quita repetidas con
          new Set y las ordena
       4. para cada fecha llama a estadoEn() y compara con la anterior
       5. la PRIMERA genera operacion 'creacion' con el campo datos
          Ctrl+F:  operacion: 'creacion'      (linea 191)
       6. las demas generan 'modificacion' con el campo cambios
          Ctrl+F:  operacion: 'modificacion'  (linea 198)

     UN DETALLE FINO QUE IMPRESIONA:
     Ctrl+F:  if (Object.keys(cambios).length === 0) continue;   (linea 197)
     Si dos historiales coinciden en fecha y describen el mismo estado,
     el evento saldria VACIO. No solo no aporta nada: ademas correria la
     numeracion de todos los que vienen despues. Por eso se salta.

     POR QUE SE JUNTAN DOS HISTORIALES:
     porque son independientes. Renombrar el producto no escribe nada en
     el historial de sus variantes, y renombrar una variante no escribe
     nada en el del producto. El evento no sale de una tabla: sale de
     juntar las fechas de las dos y rearmar el estado en cada una.
     (Esta explicado en el comentario de cargar.js linea 68.)


--------------------------------------------------------------------
1.5  CARGA  ->  etl/cargar.js, parte final
--------------------------------------------------------------------
  Ctrl+F:   replaceOne: { filter:      (lineas 317, 329, 361)
  Ctrl+F:   bulkWrite                  (lineas 368, 369, 370)
  Ctrl+F:   deleteMany                 (lineas 336, 380)

  Se escribe con replaceOne + upsert: true, en bulkWrite (una sola ida
  a la base por coleccion, no una escritura por producto).

  POR QUE replaceOne Y NO updateOne CON $set:
  el comentario esta en el codigo, linea 314:
      "el documento se deriva entero de PostgreSQL, asi que un campo que
       ya no exista alla tampoco debe quedar aqui"
  Con $set, un campo borrado en el origen se quedaria para siempre en
  Mongo. Consecuencia: EL ETL ES EL UNICO DUENO DE ESAS COLECCIONES.

  POR QUE CORRERLO DOS VECES NO DUPLICA (te lo van a preguntar):
  los _id NO los genera Mongo, se CALCULAN.
      producto -> _id = id_producto            (ej. 19)
      evento   -> _id = id_producto + "-" + n  (ej. "19-3")
  Como el _id es el mismo, el upsert cae siempre sobre el mismo
  documento: lo actualiza, no crea otro. Eso se llama idempotente.

  Y EL deleteMany DE LA LINEA 336, QUE ES EL DETALLE FINO:
      db.productos_eventos.deleteMany({
          id_producto: producto.id_producto,
          numero: { $gt: eventos.length }
      });
  Un upsert actualiza y agrega, pero NO BORRA. Si el historial ENCOGIO
  (por ejemplo porque se corrigio una fila mal fechada), los eventos
  sobrantes de la corrida anterior seguirian ahi con su _id viejo. Por
  eso se borran los que tengan numero mayor a los que toca.


--------------------------------------------------------------------
1.6  EL LIMITE DEL ETL  (esto casi seguro lo preguntan)
--------------------------------------------------------------------
El ETL solo manda sobre SU TRAMO: del id 1 al mas alto que trajo de
PostgreSQL. Lo de mas arriba ni lo toca ni lo borra.

POR QUE: un producto publicado desde el panel nace SOLO en MongoDB y no
tiene fila en PostgreSQL. Si el ETL borrara "todo lo que no esta alla",
la primera corrida se llevaria lo que la gente publico.
Y NO ES TEORICO: paso de verdad en pruebas, desaparecieron dos productos.

Por eso puede haber mas documentos en Mongo que filas en PostgreSQL, y
esta bien asi.

[AL DIA 30-AGO] Sobre una base RECIEN CREADA son 102 y 102: nadie ha
publicado nada desde el panel todavia. El 107 de antes venia de una base
ya usada. Los dos numeros son correctos; lo que hay que saber decir es
POR QUE pueden diferir, no cual es la cifra.


--------------------------------------------------------------------
1.7  DONDE VIVE EL ETL Y QUIEN LO LLAMA   <<< TE LO VAN A PREGUNTAR
--------------------------------------------------------------------
DONDE VIVE:
  En la carpeta etl/, en la RAIZ del proyecto. NO esta dentro del
  backend. Y eso es a proposito: LA APLICACION NUNCA LLAMA AL ETL.
  El backend escribe en Mongo por su cuenta (insertOne/updateOne); el
  ETL solo sirve para reconstruir el catalogo desde PostgreSQL cuando
  hace falta, por ejemplo en una maquina recien montada.

QUIEN LO LLAMA:
  arrancar.ps1, el script de arranque del proyecto.

  Ctrl+F:  function Correr-Etl      arrancar.ps1:421   <- la funcion
  Ctrl+F:  Correr-Etl               arrancar.ps1:668   <- la llamada
  Ctrl+F:  [switch]$Etl             arrancar.ps1:14    <- el flag

  La decision, arrancar.ps1:665

      if (-not $Etl -and $alDia) {
          Ok "Ya cargado (...). Para volver a migrarlo: .\arrancar.ps1 -Etl"
      } else {
          Correr-Etl
      }

  O sea: corre si lo pediste con -Etl, o si NO esta al dia.

  COMO DECIDE SI ESTA AL DIA ($alDia), dos comprobaciones:
    arrancar.ps1:616-626  compara el numero de documentos de cada
                          coleccion contra su tabla en PostgreSQL
    arrancar.ps1:657-663  compara el id mas ALTO dentro del tramo del
                          ETL en las dos bases

  Lo segundo es fino: si mirara el maximo absoluto de Mongo, un producto
  publicado desde el panel (id mas alto, sin fila en PostgreSQL) lo haria
  creerse desfasado y volveria a migrar en cada arranque.

COMO CORRE, PASO A PASO (funcion Correr-Etl, lineas 421-478):
   1. docker cp del .sql al contenedor de PostgreSQL
   2. docker exec ... psql -f /tmp/extraer.sql > /tmp/mesh-productos.json
   3. docker cp del .json de vuelta al host
   4. comprueba que NO este vacio  (si lo esta, aborta)
   5. docker cp del .json al contenedor de Mongo
   6. docker cp de cargar.js al contenedor de Mongo
   7. docker exec ... mongosh --file /tmp/cargar.js
  Lo hace dos veces: una para productos y otra para categorias.

TRES DETALLES TECNICOS QUE VALEN PUNTOS:

  a) LA REDIRECCION OCURRE DENTRO DEL CONTENEDOR.
     Fijate en el paso 2: el "> /tmp/salida.json" va DENTRO del sh -c.
     Comentario en el codigo:
       "asi la salida nunca pasa por PowerShell y no se le cambia la
        codificacion por el camino"

  b) SE MUEVE CON docker cp, NO POR TUBERIA.
     PowerShell 5.1 le pega un BOM (EF BB BF) al principio de lo que
     manda por tuberia, y del otro lado el SQL y el JavaScript llegan
     rotos. docker cp copia los bytes tal cual.

  c) SI LA CONSULTA DEVUELVE VACIO, ABORTA.
     Ctrl+F:  no devolvio ni una fila
     Cargar un archivo vacio dejaria Mongo vacio SIN UN SOLO ERROR, que
     es justo el fallo que esa comprobacion existe para evitar.

Y OJO CON ESTO, POR SI PREGUNTAN POR correr.sh:
  correr.sh existe en etl/ pero arrancar.ps1 NO lo llama. Hace los
  mismos pasos en PowerShell. Antes si lo llamaba, a traves del bash de
  Git, y cuando no lo encontraba SE SALTABA EL ETL CON UN AVISO Y EL
  SCRIPT TERMINABA EN VERDE: los productos quedaban en PostgreSQL y el
  catalogo de Mongo vacio. Paso de verdad en la maquina de un companero.
  correr.sh se queda para quien trabaje en Linux o Mac.


--------------------------------------------------------------------
1.8  PREGUNTAS QUE TE PUEDEN HACER SOBRE EL ETL
--------------------------------------------------------------------
P: Por que el _id no es un ObjectId?
R: Porque usamos el id_producto de PostgreSQL. Asi la traza entre las dos
   bases es directa (un entero apunta de un lado al otro, sin tabla de
   mapeo) y el ETL es idempotente.

P: Y el precio historico, tambien esta en los eventos?
R: No, y es deliberado. Al volverse multi-vendedor el precio dejo de ser
   del producto: es de cada oferta. Su historial vive en precio_historial,
   en PostgreSQL. Meterlo en los eventos ademas los llenaria de ruido,
   porque cambia en cada venta, y haria lenta la reconstruccion.

P: Y las caracteristicas se reconstruyen bien?
R: No del todo, y lo documentamos. En el relacional las caracteristicas
   NO tienen historial, asi que el ETL solo conoce las de hoy y las
   escribe iguales en el evento de creacion. Reconstruir a cualquier
   fecha devuelve las caracteristicas actuales. Es una limitacion
   conocida, esta escrita en el informe y en etl/README.md.

P: Y el estado (activo/inactivo)?
R: Tampoco esta en los eventos, por la misma razon: los historiales de
   PostgreSQL no guardan estado, vive solo en la fila viva.

P: Cuanto tarda?
R: Es una pasada por producto y tres bulkWrite. Sobre 102 productos es
   inmediato.


####################################################################
PARTE 2 - INDICE COMPUESTO
####################################################################
Archivo: mongo/001_productos.js
  Ctrl+F:  catalogo_categoria             (linea 123)
  Ctrl+F:  catalogo_precio                (linea 136)
  Ctrl+F:  eventos_por_producto_fecha     (linea 153)
  Ctrl+F:  categorias_por_nombre          (linea 159)  <- este es simple

  db.productos.createIndex(
      { 'categoria.id_categoria': 1, estado: 1, _id: 1 },
      { name: 'catalogo_categoria' } );

POR QUE ESE ORDEN: id_categoria primero porque va en igualdad; estado
despues porque siempre se filtra; _id al final porque es por lo que se
ordena, y asi el resultado sale ordenado del propio indice sin ordenar
en memoria.

POR QUE SOBRE id_categoria Y NO SOBRE categoria.nombre: porque el backend
filtra por el id. Un indice sobre el campo equivocado se ve igual de bien
en la lista de indices y no lo usa nadie.

POR QUE ESTAN EN mongo/ Y NO EN EL ETL: son parte de la DEFINICION de la
base, igual que un CREATE INDEX vive en la migracion y no en el INSERT.

EL DE EVENTOS sirve para las dos primeras etapas del pipeline a la vez:
filtrar por id_producto y recorrer por fecha en orden.


####################################################################
PARTE 3 - COMO SE RELACIONAN LAS DOS BASES
####################################################################
Con identificadores compartidos. El _id del documento en Mongo ES el
id_producto de PostgreSQL.

  Ctrl+F:  id_producto_mongo
    migrations/005_ofertas.sql:90    en la tabla oferta
    migrations/006_pedidos.sql:150   en la tabla pedido_producto

  Ctrl+F:  NO es llave foranea
    migrations/005_ofertas.sql:122
    'Del catalogo en MongoDB. NO es llave foranea: PostgreSQL no puede
     garantizarla contra otra base'

  Ctrl+F:  UNIQUE (id_usuario, id_producto_mongo
    migrations/005_ofertas.sql:118
    Lleva TRES columnas, no dos. Por que: en Mongo las variantes van
    embebidas y no hay indice unico sobre variantes.id_producto_variante,
    asi que dos productos distintos PUEDEN tener una variante con el mismo
    id. El par producto+variante si es inequivoco.

EL CRUCE EN VIVO:
  backend/src/services/productos/productos.service.ts:471 y :548
  Ctrl+F:  WHERE o.id_producto_mongo = $1
  La ficha de un producto sale del documento de Mongo MAS este SELECT a
  PostgreSQL para traer las ofertas.


####################################################################
PARTE 4 - QUE GUARDAMOS EN MONGO Y POR QUE
####################################################################
Tres colecciones (mongo/001_productos.js:78-82):
  productos          categoria, variantes, imagenes y caracteristicas embebidas
  categorias         la paleta: que caracteristicas ofrece cada categoria
  productos_eventos  el historial

QUE SE EMBEBE Y POR QUE (criterios del enunciado: frecuencia de acceso
conjunto, volumen, tasa de cambio):
  Categoria   embebida   se lee siempre con el producto, 3 campos, casi no cambia
  Variantes   embebidas  no se consultan solas, son pocas, cambian lento
  Imagenes    embebidas EN LA VARIANTE, no en el producto: la camisa azul y
                        la blanca no comparten foto. Y desaparece numero_orden
                        porque en un arreglo la posicion YA es el orden
  Ofertas     NO van     precio, stock y estado cambian en cada venta
  Resenas     NO van     volumen sin techo, y cada una reescribiria el
                         producto entero

PRUEBA EN CODIGO DE QUE LAS OFERTAS NO DEBEN ESTAR:
  Ctrl+F:  ofertas          mongo/001_productos.js:166
  Si quedo una coleccion 'ofertas' de una version anterior, la BORRA.
  Comentario: "una copia vieja aqui es peor que no tenerla, porque parece
  al dia".

POR QUE MONGO (el dato que convence):
  Medido sobre el conjunto: ningun producto llena el 100% de lo que su
  categoria ofrece, y el promedio es 59%. Una tabla de columnas fijas
  quedaria mayoritariamente nula. Y en el relacional esos atributos caian
  en 'descripcion' como texto libre, o sea que NO SE PODIA FILTRAR POR
  ATRIBUTO, que es funcionalidad que el enunciado pide.


####################################################################
PARTE 5 - DONDE ESTA EL CODIGO DE MONGO
####################################################################
  backend/src/database/mongo.ts:18    new MongoClient(uri)
  backend/src/database/mongo.ts:19    mongoClient.db(nombreBase)

  LA AGREGACION (la que pide el enunciado):
  backend/src/services/productos/productos.service.ts:326
  Ctrl+F:  .aggregate(
  Ctrl+F:  $mergeObjects        (linea 343)

  Comentario de la linea 279: corre DENTRO de Mongo, no trayendo los
  eventos a Node.js para fusionarlos ahi.

  ESCRITURAS:
  backend/src/services/vendedores/productos.service.ts:153   insertOne (producto)
  backend/src/services/vendedores/productos.service.ts:366   insertOne (evento)
  backend/src/services/vendedores/productos.service.ts:572   updateOne


####################################################################
PARTE 6 - SINCRONIZACION   <<< LA PREGUNTA TRAMPA
####################################################################
NO tenemos un proceso que sincronice cada dos minutos, y DECIRLO ES LA
RESPUESTA CORRECTA. El diseno hace que no haga falta. Tres razones:

(1) LA APLICACION ESCRIBE DIRECTO EN MONGO
    services/vendedores/productos.service.ts:153  insertOne
    services/vendedores/productos.service.ts:572  updateOne
    Publicar o editar un producto escribe en MongoDB, NO en PostgreSQL.
    No hay nada que sincronizar porque no hay dos escrituras. Las tablas
    productos de PostgreSQL son el ORIGEN de la migracion, no un espejo.

(2) LO UNICO QUE ES COPIA SON CINCO NUMEROS, y se recalculan EN EL MISMO
    MOMENTO, no en dos minutos:
    Ctrl+F:  recalcularCamposCalculados
      services/compradores/pedidos.service.ts:603   tras comprar
      services/compradores/pedidos.service.ts:653   tras cancelar
      services/vendedores/ofertas.service.ts:239    al crear/editar oferta
    Definida en services/productos/productos.service.ts:509
    Los cinco: precio_tienda, precio_desde, stock_tienda, stock_total,
    total_ofertas.

(3) EL ETL SOLO RECONSTRUYE DESDE CERO
      arrancar.ps1:616-626   la lista de colecciones que compara
      arrancar.ps1:668       dispara Correr-Etl
    Solo si alguna coleccion tiene MENOS documentos que su tabla.
    A mano:  .\arrancar.ps1 -Etl

SI PREGUNTAN "Y SI NO COINCIDEN":
  Que no coincidan es LO NORMAL Y ESPERADO. Hoy: 102 en PostgreSQL, 107 en
  Mongo. Los cinco de mas se crearon desde el panel y viven solo en Mongo.
  No es un desajuste: es la prueba de que la migracion se completo.

SI PREGUNTAN POR EL RIESGO REAL:
  Lo asumimos y esta documentado. Si el recalculo de los cinco numeros
  fallara, la lista mostraria un precio viejo un rato. Pero NO SE VENDE DE
  MAS, porque quien decide si alcanza el inventario es PostgreSQL dentro
  de la transaccion: comprar_pedido con SELECT ... FOR UPDATE sobre la
  fila de la oferta (migrations/007_flujo_pedido.sql).


####################################################################
PARTE 7 - COMO PROBAMOS QUE USAMOS LOS DOS MODELOS
####################################################################
De mas fuerte a mas debil:

  a) UNA SOLA PANTALLA CRUZA LAS DOS BASES
     GET /productos/:id : documento de Mongo + ofertas de PostgreSQL
     (productos.service.ts:471 y :548). Si apagas cualquiera de las dos,
     la ficha no se puede armar.

  b) EL FLUJO DE COMPRA ES 100% RELACIONAL
     migrations/007_flujo_pedido.sql: crear_pedido, agregar_linea,
     restar_linea, quitar_linea, cambiar_direccion_pedido, comprar_pedido,
     cancelar_pedido, reponer_stock. Ocho funciones dentro de PostgreSQL.
     [AL DIA 30-AGO] Son DIEZ: la 012 agrego comprar_carrito (crear +
     agregar + comprar en una sola transaccion, para el carrito de Redis)
     y la 013 reemplazo el cuerpo de agregar_linea. Ver PARTE 9.

  c) EL KARDEX Y EL HISTORIAL DE PRECIOS SON RELACIONALES
     stock_movimiento y precio_historial. [AL DIA 30-AGO] Remedido sobre
     556 ofertas: CERO descuadres contra la suma con signo de todos los
     movimientos. La consulta es la comprobacion 1 del DO final de
     migrations/datos/001_catalogo.sql -- ojo, la suma va multiplicada por
     motivo_movimiento.valor, que es donde vive el signo. Sumando cantidad
     a secas salen 89 falsos descuadres.

  d) LAS DOS VENTANAS ESTAN LEVANTADAS
     pgAdmin en :5050 y DbGate en :3001. Se pueden abrir en vivo.


####################################################################
PARTE 8 - EXTRAS
####################################################################

POR QUE 7 CONTENEDORES     [AL DIA 30-AGO: eran 4, la Entrega 2 sumo 3]
  postgres      pgvector/pgvector:pg18   5432    la base relacional
  mongo         mongo:8                  27018   la base documental
  redis         redis                    6379    el carrito           (E2)
  neo4j         neo4j:5-community        7687    el grafo de fraude   (E2)
  pgadmin       dpage/pgadmin4           5050    ventana de PostgreSQL
  dbgate        dbgate/dbgate            3001    ventana de MongoDB
  redisinsight  redis/redisinsight       5540    ventana de Redis     (E2)
Solo CUATRO son bases. pgAdmin, DbGate y RedisInsight no los usa la
aplicacion (Neo4j trae su propia ventana en :7474, sin contenedor aparte).
La imagen es pgvector y no postgres:18 porque trae la extension de
vectores ya incluida, que la entrega final pide para busqueda semantica.
Mongo publica el 27018 y no el 27017 porque Windows puede tener un
MongoDB instalado como servicio: los dos escuchan sin dar error y el que
contesta en localhost seria el de Windows, con una base vacia y sin
contrasena.

TRANSPARENCIA DE LOS DATOS
  frontend/src/lib/api.ts:7    const API = 'http://localhost:3000'
  frontend/src/lib/api.ts:39   pedir()  <- unica funcion que habla con el backend
  backend/src/helpers/respuesta.ts   exito() y fallo()
  Todas las rutas devuelven { ok, mensaje, payload }, siempre los tres.
  El frontend nunca sabe de que base salio un dato.

NUMEROS PARA CITAR   [AL DIA 30-AGO, contra una base recien creada]
  42 tablas de 42 del diagrama: la 011 agrego Resena, Comentario y Likes,
     asi que YA NO FALTA NINGUNA. (Antes decia 36 de 39.)
  102 productos en PostgreSQL / 102 documentos en Mongo / 112 eventos
     (en una base ya usada Mongo tiene mas: ver 1.6)
  23 categorias
  202 variantes, 556 ofertas, 11 cuentas
  90 resenas, 118 comentarios, 62 likes
  59% de llenado promedio de caracteristicas
  0 descuadres de stock sobre 556 ofertas
  60 paginas el informe

  OJO AL CITAR: el informe de la Entrega 1 dice 8 cuentas y 552 ofertas.
  La base de hoy dice 11 y 556 -- son las 3 cuentas del anillo de fraude
  de la Entrega 2 y sus 4 ofertas. No es un error del informe ni de la
  base: es que el conjunto de datos crecio despues de entregarlo.


####################################################################
PARTE 9 - LO QUE CAMBIO DESPUES DE LA ENTREGA 1   [30-AGO-2026]
####################################################################
Todo lo de arriba sigue valiendo. Esto es lo que se agrego encima, por si
preguntan por algo que la guia vieja no cubre.

--------------------------------------------------------------------
9.0  LA PREGUNTA QUE YA FALLAMOS UNA VEZ
--------------------------------------------------------------------
P: Que archivo pasa los id de producto a _id en Mongo?
R: etl/cargar.js, linea 215.

   Ctrl+F:  _id:         producto.id_producto     (cargar.js:215)
   Ctrl+F:  _id:         producto.id_producto + '-' + numero   (:188)
   Ctrl+F:  _id                                   (:346, categorias)

   El reparto exacto, que es lo que hay que decir:
     etl/extraer.sql          saca las filas de PostgreSQL, con su
                              id_producto. NO menciona _id.
     etl/cargar.js:215        AQUI se hace el mapeo id_producto -> _id
     mongo/001_productos.js   SOLO createCollection y createIndex.
                              NO inserta documentos, ni en blanco ni de
                              ningun tipo. Comprobado: 0 insert en todo
                              el archivo.

   Y el remate: el _id se CALCULA, no lo genera Mongo. Por eso el ETL es
   idempotente -- el replaceOne con upsert cae siempre sobre el mismo
   documento (cargar.js:317).

--------------------------------------------------------------------
9.1  LAS TRES TABLAS QUE FALTABAN: YA ESTAN
--------------------------------------------------------------------
migrations/011_resenas.sql cerro el diagrama: comentario, resena y likes.
Son 42 de 42. La guia vieja decia "36 de 39, faltan las sociales".

Dos decisiones de modelo que preguntan seguro:
  a) La resena es de un VENDEDOR sobre un PRODUCTO, no del producto solo:
     resena(id_usuario, id_usuario_vendedor, id_producto_mongo, ...).
     Colgaba de oferta y se cambio: oferta es unica por (usuario,
     producto, VARIANTE), y nadie resena una variante.
  b) El texto NO esta en resena: esta en su comentario RAIZ
     (id_comentario_padre IS NULL). Los votos van contra id_comentario,
     asi la misma tabla sirve para votar una resena y una respuesta.

--------------------------------------------------------------------
9.2  REDIS: EL CARRITO      (Entrega 2)
--------------------------------------------------------------------
El carrito dejo de ser una fila de pedido y es una clave de Redis con
expiracion por inactividad. Guarda INTENCION, no precios:
id_oferta -> cantidad, y nada mas.

Consecuencia que hay que saber decir: el pedido nace ENTERO al pagar. Por
eso existe migrations/012_comprar_carrito.sql: comprar_carrito() compone
crear_pedido + agregar_linea + comprar_pedido en una transaccion. No las
copia: las llama, para que no existan dos versiones de las mismas reglas.

--------------------------------------------------------------------
9.3  NEO4J: EL GRAFO DE FRAUDE      (Entrega 2)
--------------------------------------------------------------------
El enunciado pide senalar "conjuntos de cuentas que se califican entre si
de forma reiterada sobre los mismos productos". Eso es recorrer
relaciones, no leer filas.

EL MODELO, TRES NODOS Y NO CUATRO:
  (:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
                          (:Resena)-[:SOBRE]->(:Producto)
  (:Usuario)-[:VIVE_EN]->(:Direccion)

  NO hay :Vendedor, y es el punto fino: en Mesh comprar no pide rol, asi
  que partirlo dejaria la misma cuenta como dos nodos y EL ANILLO NUNCA
  CERRARIA.
  Y la resena es NODO, no relacion, porque conecta TRES cosas.

EL GRAFO ES UNA PROYECCION, no una fuente de verdad: se borra entero y se
reconstruye desde PostgreSQL con etl/cargar_grafo.sh.

LA DIRECCION SE NORMALIZA, y esa es la parte que luce:
  etl/extraer_grafo.sql, funcion clave_direccion()
  minusculas + sin tildes (translate, no unaccent: es una extension) +
  espacios colapsados. El resultado ES LA IDENTIDAD del nodo :Direccion.
  Se calcula en el ETL y no en la consulta: normalizar al vuelo obligaria
  a leer todas las direcciones para comparar dos.
  Y lleva tiene_calle: una direccion sin calle identifica una ciudad, no
  una casa. Sin eso, las 4 cuentas que solo declararon ciudad salian como
  "misma casa" -- eran dos falsos positivos y estan documentados.

--------------------------------------------------------------------
9.4  EL ANILLO DE FRAUDE ES REAL, NO UN MOCK
--------------------------------------------------------------------
Tres cuentas anillo.*@mesh.com sembradas en PostgreSQL que SE COMPRAN
ENTRE SI y despues se califican 5 estrellas en circulo, desde la misma
casa escrita de tres formas distintas.

  POR QUE tienen que comprarse primero: el backend exige compra pagada AL
  MISMO VENDEDOR para poder calificar. O sea que la regla del sistema
  OBLIGA al anillo a comprarse a si mismo -- que es como opera uno de
  verdad, y el costo de esas compras es lo que lo hace detectable.

  GET /admin/fraude/anillos devuelve 3 grupos: ciclo, reiterado y
  direccion. Sin sembrar nada a mano, sin datos de ejemplo en el
  frontend.

--------------------------------------------------------------------
9.5  LA MIGRACION 013 Y EL COBRO INCORRECTO
--------------------------------------------------------------------
Con el carrito en Redis, agregar y pagar pasan en el mismo instante, asi
que el precio que se congela es el de PAGAR. Si el vendedor lo sube
mientras el carrito espera, se cobra el nuevo sin avisar.

migrations/013_precio_del_carrito.sql deja que agregar_linea reciba un
id_precio_historial DENTRO de p_linea y lo use en vez del vigente.
  - La firma NO cambia, asi que la 012 no se toco.
  - Exige que ese precio sea DE ESA MISMA OFERTA: sin ese filtro, pasar
    el id de otra fila seria elegir el precio a voluntad. Es dinero.
  - No bloquea: cobra el congelado y AVISA, con precio_cambio,
    precio_congelado y precio_actual. La base informa, la aplicacion
    decide la politica.

  HONESTIDAD: la 013 lo HABILITA, no lo termina. Falta que el carrito de
  Redis guarde el id_precio_historial. Hasta entonces el precio se sigue
  congelando al pagar, y el checkout lo dice tal cual en pantalla.

--------------------------------------------------------------------
9.6  QUE SE PUEDE ENSENAR EN VIVO
--------------------------------------------------------------------
  .\arrancar.ps1 -Reiniciar     todo desde cero, y el anillo aparece solo
  http://localhost:5173/panel   como admin@mesh.com / Admin123:
                                  - Reportes (ventas y reservaciones)
                                  - Manipulacion de resenas: 3 anillos
  http://localhost:7474         Neo4j Browser, para dibujar el grafo
  http://localhost:5540         RedisInsight, ensena el TTL del carrito
                                contando hacia atras

  ARNESES, por si piden pruebas:
    bash pruebas/carrito.sh            25 OK
    bash pruebas/resenas.sh            15 OK
    bash neo4j/correr_fraude.sh        las 5 consultas, sembrando y
                                       limpiando un anillo de mentira
    bash redis/prueba_concurrencia.sh  cero sobreventa con 1000
                                       solicitudes / 50 clientes
