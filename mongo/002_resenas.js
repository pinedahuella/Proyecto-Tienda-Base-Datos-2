// 002_resenas.js
// Lo que el catalogo necesita para ordenar por calificacion.
//
// Este archivo llega despues de 001_productos.js y no repite nada de lo suyo:
// las colecciones ya existen, y aqui solo se agregan las dos cosas que hacen
// falta cuando el documento del producto empieza a llevar la calificacion.
//
// Los dos campos nuevos los escribe el ETL de etl/cargar.js dentro del
// documento de cada producto:
//
//   resenas_promedio   numero, de 1.00 a 5.00, o 0 si el producto no tiene
//                      ninguna resena
//   resenas_total      entero, cuantas resenas se promediaron
//
// "Numero" y no "double" a proposito, porque el tipo BSON de resenas_promedio
// no es uno solo: mongosh guarda un valor entero como int32 y uno con
// decimales como double, asi que el campo queda repartido entre los dos tipos
// segun lo que le toque a cada producto. Esta contado largo en el apartado OJO
// CON EL TIPO BSON de etl/cargar.js, y la consecuencia para quien consulte es
// que aqui NUNCA se pregunta por el tipo: un {$type: "double"} sobre este campo
// se dejaria fuera a la mayoria. Comparar con $gte y ordenar con $sort si
// funciona igual, porque Mongo compara entre tipos numericos.
//
// El 0 no es una calificacion: resena.calificacion en PostgreSQL es un
// smallint con CHECK BETWEEN 1 AND 5, asi que un promedio de verdad nunca
// puede dar menos de 1. El 0 es "todavia nadie ha calificado esto", y por eso
// se puede distinguir de una mala nota sin necesidad de un campo aparte.
//
// Van dentro del producto, embebidos, y no en una coleccion de resenas al
// lado. El motivo es el mismo que 001_productos.js escribio para los cinco
// numeros del precio y el stock: lo que la LISTA del catalogo pinta en cada
// tarjeta tiene que salir de un solo documento, sin una segunda consulta y sin
// un $lookup por tarjeta. Las resenas de verdad -- su texto, su autor, su
// fecha -- se quedan en PostgreSQL, que es la fuente de verdad; lo que viaja
// aqui son los dos numeros agregados.
//
// Este archivo hace dos cosas:
//
//   1. El indice catalogo_rating, para "los mejor calificados de esta
//      categoria" sin etapa de ordenamiento en memoria.
//   2. El piso de los dos campos para los productos que el ETL nunca toca.
//      Sin eso, esos productos se caen del catalogo en silencio en cuanto
//      alguien filtre por nota. Es la parte que evita un fallo que no da
//      error, y esta explicada larga mas abajo.
//
// Todo lo de aqui es idempotente y se corre en cada arranque:
//
//   - createIndex no hace nada si el indice ya existe con la misma definicion,
//     y ademas aqui se pregunta antes para poder decir por pantalla si se creo
//     o si ya estaba.
//   - el updateMany filtra por { $exists: false }, asi que un producto que ya
//     tiene los campos no lo toca ni una vez mas. Correr esto diez veces
//     seguidas deja exactamente lo mismo que correrlo una.
//
// Y nada de aqui lanza. arrancar.ps1 corre TODOS los .js de mongo/ ordenados
// por nombre en cada arranque, y si uno devuelve un codigo distinto de 0 mata
// el arranque entero con exit 1. Un indice que no se pudo crear es un problema
// de rendimiento, no una razon para dejar al proyecto sin levantar, asi que las
// dos operaciones van dentro de un try y lo que falle sale por pantalla con un
// OJO delante en vez de tumbarlo todo.


// ============================================================
// 1. El indice del catalogo ordenado por calificacion
// ============================================================
// La consulta que responde es "los mejor calificados de esta categoria, sin
// los ocultos, con al menos tal nota, paginados". O sea:
//
//   find({ 'categoria.id_categoria': X, estado: 'activo',
//          resenas_promedio: { $gte: N } })
//     .sort({ resenas_promedio: -1, _id: 1 })
//
// El orden de las cuatro claves sale de la misma regla que 001_productos.js ya
// escribio para catalogo_categoria y catalogo_precio, aplicada a este caso:
//
// PRIMERO las dos IGUALDADES. categoria.id_categoria va de primero porque el
// filtro del catalogo casi siempre trae la categoria, y estado detras porque
// el backend SIEMPRE restringe por estado.
//
// Y conviene decir COMO lo restringe, que no es un `estado: 'activo'` a secas.
// construirFiltro, en backend/src/services/productos/productos.service.ts, lo
// arma como lista blanca y de dos formas segun lo que llegue en ?estado=:
//
//   { $eq: 'activo' }   cuando no se pide estado, o se pide justamente ese
//   { $in: [] }         cuando se pide cualquier otro valor
//
// El segundo es el idiom de Mongo para "esto no hace match nunca", y esta ahi
// para que pedir un estado oculto devuelva una lista vacia en vez de un error
// o, peor, en vez de productos que no deberian verse.
//
// Para este indice da igual cual de las dos caiga, y por eso la posicion de
// estado no cambia: las dos son condiciones de IGUALDAD sobre el mismo campo
// (una con un valor, la otra con cero valores) y las dos se sirven desde el
// mismo prefijo de claves, sin obligar a recorrer un rango. Lo que no hay
// nunca es una consulta publica que deje estado libre.
//
// Una igualdad al frente del indice corta el rango de claves que hay que
// recorrer; una igualdad detras de un rango ya no corta nada.
//
// TERCERO resenas_promedio, y este es el punto entero del indice: aqui el
// campo del RANGO (la nota minima) y el campo del ORDEN son EL MISMO campo.
//
// La comparacion con catalogo_precio es la que lo explica. Alli hubo que
// renunciar al orden y pagar un ordenamiento en memoria, porque el rango caia
// sobre precio_desde y el orden sobre _id, dos campos distintos: detras de un
// rango el indice deja de entregar las claves ordenadas por lo que viene
// despues, y no queda mas remedio que ordenar el resultado aparte. Aqui no
// pasa. Como el rango y el orden caen sobre resenas_promedio, el indice sirve
// para las dos cosas a la vez y en el explain NO aparece etapa SORT.
//
// CUARTO _id, que no filtra nada: es el desempate estable para paginar. Sin el,
// dos productos con la misma nota pueden salir en distinto orden en dos
// consultas seguidas, y entonces la pagina 2 repite o se salta productos.
//
// Las DIRECCIONES tampoco son decorativas. -1 en resenas_promedio con 1 en _id
// es exactamente el sort { resenas_promedio: -1, _id: 1 } que pide el catalogo,
// mejor calificados primero. Tienen que coincidir con el sort o ser su reverso
// completo: un indice se puede recorrer al derecho o al reves entero, pero no
// mezclando -- si aqui se pusiera 1 y 1, ese sort ya no se podria servir desde
// el indice y volveria la etapa SORT que este indice existe para quitar.
//
// MEDIDO, no supuesto, con la misma vara que 001_productos.js uso para los
// suyos: explain("executionStats"), comparando la consulta contra ella misma
// con hint({$natural:1}), o sea contra no tener el indice.
//
// Esta medicion es lo unico que este archivo guarda en numeros escritos a
// mano, y es a proposito: la regla del proyecto es que un indice se gana el
// puesto midiendo, y una justificacion sin numeros no demuestra nada. Pero por
// eso mismo va
// FECHADA y con el tamano del catalogo al lado, porque una medicion sin esas
// dos cosas se lee como si valiera hoy y no vale: el catalogo crece y la
// categoria mas poblada cambia de nombre y de tamano.
//
// CORRIDA DEL 2026-09-02, sobre una coleccion de 406 productos (405 activos).
// La categoria mas poblada de ese momento era la 11, con 33 productos activos:
//
//   find({'categoria.id_categoria': 11, estado: 'activo',
//         resenas_promedio: {$gte: 0}}).sort({resenas_promedio: -1, _id: 1})
//
//     con catalogo_rating      33 documentos y 33 claves para devolver 33
//     con hint({$natural:1})  406 documentos y  0 claves para devolver los 33
//
//   la misma consulta con {$gte: 4}, o sea "de cuatro estrellas para arriba":
//
//     con catalogo_rating       4 documentos y  4 claves para devolver 4
//     con hint({$natural:1})  406 documentos y  0 claves para devolver los 4
//
// Los documentos examinados son lo que abarata el indice: abre exactamente los
// que devuelve, y sin el hay que abrir la coleccion entera. Por eso la columna
// de la derecha crece con el catalogo y la de la izquierda no.
//
// PERO LO QUE MAS IMPORTA DE LA MEDICION NO ES UN NUMERO, y por eso no caduca:
// con el indice el plan ganador es FETCH sobre IXSCAN, SIN etapa SORT; forzando
// $natural es SORT sobre COLLSCAN. Esa etapa SORT que aparece en cuanto se
// quita el indice es justamente lo que el orden de las claves existe para
// evitar, y es una propiedad del indice y del sort, no del dato: no depende de
// cuantos productos haya ni de como se repartan las notas.
//
// PARA VOLVER A MEDIRLO hay que buscar de nuevo la categoria mas poblada, que
// se mueve sola con cada producto que se publica:
//
//   db.productos.aggregate([{$match: {estado: 'activo'}},
//     {$group: {_id: '$categoria.id_categoria', n: {$sum: 1}}},
//     {$sort: {n: -1}}, {$limit: 1}])
//
// PRECAUCION, y esta conviene tenerla escrita porque a simple vista parece que
// sobra un indice: catalogo_rating NO reemplaza a catalogo_categoria. La
// navegacion normal del catalogo ordena por _id, y para eso hace falta el
// prefijo { categoria.id_categoria, estado, _id }. Aqui resenas_promedio se
// mete justo en medio de ese prefijo y lo rompe. Los dos indices tienen que
// convivir: uno sirve la navegacion por id y el otro la de mejor calificados.
const NOMBRE_INDICE = 'catalogo_rating';

// La clave esperada, serializada, solo para comparar contra la que ya este en
// la base. Se escribe como texto a proposito y no como objeto: el createIndex
// de abajo se queda con su forma literal, que es la que hay que leer, y esto
// es nada mas el espejo con el que se comprueba. Si un dia cambian las claves
// del indice, hay que cambiar las dos y el print de OJO avisa si se olvido una.
const CLAVE_ESPERADA =
    '{"categoria.id_categoria":1,"estado":1,"resenas_promedio":-1,"_id":1}';

try {
    const existente = db.productos.getIndexes().filter(function (i) {
        return i.name === NOMBRE_INDICE;
    })[0];

    if (!existente) {
        db.productos.createIndex(
            { 'categoria.id_categoria': 1, estado: 1, resenas_promedio: -1, _id: 1 },
            { name: 'catalogo_rating' }
        );
        print('indice ' + NOMBRE_INDICE + ' creado');
    } else if (JSON.stringify(existente.key) !== CLAVE_ESPERADA) {
        // El nombre esta tomado por un indice con OTRAS claves. Volver a
        // crearlo daria IndexKeySpecsConflict, y borrar por las buenas un
        // indice que alguien puso a mano seria peor. Se avisa y se sigue.
        print('OJO: ' + NOMBRE_INDICE + ' ya existe con otras claves '
            + JSON.stringify(existente.key) + ', se dejo como estaba');
    } else {
        print('indice ' + NOMBRE_INDICE + ' ya estaba');
    }
} catch (e) {
    print('OJO: no se pudo crear el indice ' + NOMBRE_INDICE + ': ' + e.message);
}


// ============================================================
// 2. El piso para los productos que el ETL nunca toca
// ============================================================
// Esta es la parte que evita un fallo silencioso, y hace falta contar por que.
//
// En Mongo hay MAS productos que filas en la tabla productos de PostgreSQL, y
// la diferencia son los que NACIERON EN MONGO, creados desde el panel del
// vendedor y sin fila en el relacional.
//
// Cuantos son no se escribe aqui, y tampoco cuales: sube cada vez que alguien
// publica algo desde el panel, asi que una lista o un numero a mano se quedan
// mintiendo sin avisar. Se cuenta en el momento, comparando
//
//   db.productos.countDocuments({})        en mongosh
//   SELECT count(*) FROM productos;        en psql
//
// y para ver cuales son, cruzando db.productos.distinct('_id') contra los
// id_producto del relacional. Lo que importa no es el numero, es que la
// diferencia existe y no baja sola.
//
// El ETL no los va a tocar nunca. Escribe con replaceOne por _id, en un bulk
// armado a partir de lo que EXTRAE de PostgreSQL (etl/cargar.js): solo puede
// escribir los _id que salieron de esa consulta. Un producto que no esta en
// PostgreSQL no aparece en esa lista, asi que ninguna corrida del ETL le va a
// poner resenas_promedio ni resenas_total. Se quedarian sin los dos campos
// para siempre.
//
// Y no basta con que su _id sea alto para salvarse de la duda al reves: estos
// productos pueden acabar con un _id POR DEBAJO del mas alto del relacional en
// cuanto PostgreSQL siga creciendo, y aun asi el ETL sigue sin verlos. Lo que
// los deja fuera es no estar en la consulta, no en que tramo de ids caigan.
//
// Y un campo AUSENTE es peor que un 0, no parecido. En MongoDB un
// { resenas_promedio: { $gte: 1 } } no hace match contra un documento que no
// tiene el campo -- ausente no es 0, es "no comparable" --, asi que en cuanto
// alguien use el filtro de nota minima esos productos DESAPARECEN del
// catalogo. Sin error, sin log, sin nada que revisar: la consulta contesta 200
// con una lista mas corta y el vendedor ve que su producto ya no aparece y no
// hay a quien preguntarle por que. Con un 0 escrito, en cambio, el producto
// existe y queda fuera del filtro por una razon que se puede explicar: no
// tiene resenas todavia.
//
// De ahi el filtro { resenas_promedio: { $exists: false } }, que es tambien lo
// que hace esto idempotente: toca solo a quien le falta el campo, y a nadie mas.
//
// SOBRE EL ORDEN DE ARRANQUE, que importa para leer el numero que imprime.
// arrancar.ps1 corre los .js de mongo/ en el paso "Creando colecciones", y el
// ETL en el paso siguiente, "El catalogo en MongoDB". Asi que este relleno pasa
// PRIMERO y el ETL despues, cuando el ETL corra.
//
// Y EL ETL NO CORRE SOLO CON -Etl, aunque el mensaje que imprime arrancar.ps1
// al saltarselo ("Para volver a migrarlo: .\arrancar.ps1 -Etl") lo haga
// parecer. Ademas de la bandera hay guardias que lo disparan solas, y basta con
// que una de ellas no cuadre:
//
//   - por cada coleccion que el ETL escribe (hoy productos y categorias)
//     compara cuantos documentos hay en Mongo contra cuantas filas hay en
//     PostgreSQL, y lo corre si Mongo tiene MENOS;
//   - lo corre tambien si alguna de esas dos cuentas no se pudo leer, porque
//     saltarselo por no poder contar seria dejar el catalogo a medias callado;
//   - y compara el _id mas alto de cada lado dentro del tramo que le pertenece
//     al ETL, y lo corre si no coinciden, que es como detecta que los ids se
//     renumeraron sin que la cuenta se moviera.
//
// O sea que agregar productos a PostgreSQL alcanza para que el ETL corra solo
// en el siguiente arranque, sin que nadie pida nada. Lo que esas guardias NO
// ven es un cambio que deje las cuentas iguales -- una resena nueva sobre un
// producto que ya existe mueve su promedio y no mueve ningun conteo --, y para
// eso si hace falta -Etl a mano.
//
// LA CONSECUENCIA PARA EL NUMERO QUE IMPRIME ESTE updateMany. Este paso alcanza
// a los productos a los que les FALTE el campo, no a los que valgan 0. En un
// arranque donde el ETL corra despues, el ETL le devuelve su promedio de verdad
// a los que vienen de PostgreSQL, y los nacidos en Mongo se quedan con el piso
// que se les escribio aqui la primera vez. Como el filtro es { $exists: false },
// una vez rellenados ya no vuelven a contar: en regimen este numero es 0.
//
// Un numero distinto de 0 significa que aparecieron productos SIN el campo
// desde el ultimo arranque -- publicados desde el panel, o insertados a mano --,
// no que el catalogo haya crecido por el lado de PostgreSQL.
//
// ESTO ES UN PISO, NO UNA VERDAD. Escribir 0 no es haber contado las resenas de
// los productos nacidos en Mongo: es dejarlos comparables para que no se caigan
// del catalogo. El dia que uno de ellos reciba resenas de verdad, quien las cuente
// tendra que escribirle los dos campos el mismo, porque el ETL no va a pasar
// por ahi -- ese producto no existe en PostgreSQL y no va a aparecer en la
// consulta que alimenta el bulk. Si algun dia un producto nacido en Mongo se
// queda con un 0 y resenas visibles, el fallo esta aqui, no en el ETL.
try {
    const rellenados = db.productos.updateMany(
        { resenas_promedio: { $exists: false } },
        { $set: { resenas_promedio: 0, resenas_total: 0 } }
    );

    print('productos rellenados con el piso de resenas: ' + rellenados.modifiedCount);
} catch (e) {
    print('OJO: no se pudo rellenar el piso de resenas: ' + e.message);
}

print('resenas al dia');
