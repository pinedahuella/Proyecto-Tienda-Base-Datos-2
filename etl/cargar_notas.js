// cargar_notas.js
// Refresca la nota del catalogo: escribe resenas_promedio y resenas_total en
// los documentos de db.productos, y APAGA los que se quedaron marcados.
//
// Es la tercera etapa del ETL y corre DESPUES de cargar.js, no antes. Tiene
// que ser despues porque cargar.js hace `replaceOne` con el documento entero
// derivado de PostgreSQL: si esta etapa corriera primero, ese replaceOne le
// pasaria por encima a todo lo que escribio.
//
// POR QUE ES UNA ETAPA APARTE Y NO UN CAMPO MAS DE cargar.js
//
// Porque cargar.js solo conoce los productos que tienen fila en la tabla
// `productos` de PostgreSQL, y la nota tiene dos casos que se le escapan a
// esa lista:
//
//   1. El producto que solo vive en Mongo. Nace en el panel del vendedor, no
//      deja fila en PostgreSQL, y aun asi tiene ofertas y se puede resenar.
//      cargar.js no lo toca nunca. Esta etapa si, porque extraer_notas.sql
//      recorre resenas y no productos.
//
//   2. El producto al que le borraron la ultima resena. Deja de salir en
//      extraer_notas.sql -- ya no tiene de donde salir -- y su documento se
//      queda con la nota vieja para siempre. Este archivo es el unico que
//      puede arreglarlo, porque es el unico que sabe cuales NO vinieron.
//
// El caso 2 no es teorico. Medido sobre la base viva el 2026-09-04: el
// producto 1 decia resenas_total 1 y resenas_promedio 4, con CERO filas en
// `resena`. Llevaba ahi desde que alguien borro esa resena.
//
// NO SE HACE UPSERT, y esa decision importa. Una nota cuyo producto no existe
// en Mongo no es un producto que haya que crear: seria un documento pelado,
// sin nombre ni categoria ni ofertas, que se colaria en el catalogo y en los
// indices. Se cuenta y se avisa, que es lo unico honesto que se puede hacer
// con una resena que apunta a un producto que no existe en ninguna de las dos
// bases.

const RUTA_NOTAS = '/tmp/mesh-notas.json';

function leerLineas(ruta) {
    return require('fs').readFileSync(ruta, 'utf8')
        .split('\n')
        .filter(linea => linea.trim().length > 0)
        .map(linea => JSON.parse(linea));
}

const notas = leerLineas(RUTA_NOTAS);
const ids = notas.map(n => n.id_producto);

// ============================================================
// 1. Escribir la nota de los que tienen resenas
// ============================================================
//
// updateOne con $set y no replaceOne: aqui solo mandan estos dos campos. El
// resto del documento es de cargar.js y no se toca.
//
// Y la nota SI la indexa el buscador (resenas_promedio y resenas_total estan en
// elastic/001_indice.json), asi que cuando cambia hay que avisarle con la misma
// bandera que usa el backend, `pendiente_busqueda: true`. Solo cuando CAMBIA: una
// bandera puesta en todos los documentos en cada corrida haria reindexar el
// catalogo entero por nada.
//
// Por eso el update es un pipeline y no un $set plano: necesita comparar contra
// lo que ya hay. `$eq` compara entre tipos numericos, asi que el int 5 y el
// double 5.0 son lo mismo y no marcan. Si la nota no cambio, el `$cond` devuelve
// la bandera que ya tenia el documento (si no tenia ninguna, no escribe nada).
// Un pipeline sigue contando en matchedCount, que es lo que detecta huerfanos.
const escrituras = notas.map(function (nota) {
    return {
        updateOne: {
            filter: { _id: nota.id_producto },
            update: [
                {
                    $set: {
                        pendiente_busqueda: {
                            $cond: [
                                {
                                    $and: [
                                        { $eq: ['$resenas_promedio', nota.resenas_promedio] },
                                        { $eq: ['$resenas_total', nota.resenas_total] }
                                    ]
                                },
                                '$pendiente_busqueda',
                                true
                            ]
                        },
                        resenas_promedio: nota.resenas_promedio,
                        resenas_total: nota.resenas_total
                    }
                }
            ]
        }
    };
});

// Cuantos documentos esperan al buscador antes y despues, para decir cuantos
// marco esta etapa. Es una resta y no un conteo exacto: el worker del backend
// puede estar limpiando la bandera al mismo tiempo.
const pendientesAntes = db.productos.countDocuments({ pendiente_busqueda: true });

let escritos = 0;
if (escrituras.length > 0) {
    escritos = db.productos.bulkWrite(escrituras).matchedCount;
}

// Los que no aparecieron son resenas apuntando a un producto que no existe en
// Mongo. No se crean (ver la cabecera): se cuentan.
const huerfanos = ids.length - escritos;

// ============================================================
// 2. Apagar los que se quedaron marcados sin tener resenas
// ============================================================
//
// El filtro lleva las DOS condiciones a proposito. `resenas_total > 0` sola
// tocaria tambien a los que si tienen resenas; el `$nin` solo recorreria los
// 1105 documentos enteros en cada corrida. Juntas, el conjunto que se examina
// es el de los que HOY dicen tener resenas, que es del mismo tamano que la
// lista de ids y no del tamano del catalogo.
const apagados = db.productos.updateMany(
    {
        resenas_total: { $gt: 0 },
        _id: { $nin: ids }
    },
    {
        // Estos si cambiaron seguro: decian tener resenas y ahora dicen cero.
        $set: { resenas_promedio: 0, resenas_total: 0, pendiente_busqueda: true }
    }
).modifiedCount;

// ============================================================
// 3. Lo que se hizo
// ============================================================
print('notas       ' + escritos + ' de ' + ids.length + ' productos con resenas');
print('apagados    ' + apagados + ' que decian tener resenas y ya no las tienen');
print('buscador    ' + Math.max(0, db.productos.countDocuments({ pendiente_busqueda: true }) - pendientesAntes) +
    ' productos marcados para reindexar (pendiente_busqueda)');

if (huerfanos > 0) {
    print('AVISO: ' + huerfanos + ' producto(s) con resenas no existen en Mongo.');
    print('       Son resenas apuntando a un id que no esta en ninguna de las dos bases.');
    print('       No se crean documentos por ellas: ver la cabecera de etl/cargar_notas.js');
}
