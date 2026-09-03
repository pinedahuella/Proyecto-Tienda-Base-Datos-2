// ============================================================
// borrar_lote_mongo.js -- deshace lo que hizo generar_lote_mongo.js
// ============================================================
// Borra de MongoDB los productos de un lote M y sus eventos, y escribe la
// lista de ids para que PostgreSQL borre despues sus ofertas.
//
// SON DOS MITADES, igual que al crear, y por el mismo motivo: el producto vive
// en Mongo y sus ofertas en PostgreSQL. Correr solo esta deja ofertas
// apuntando a un producto que ya no existe. `arrancar.ps1 -BorrarMongo` hace
// las dos.
//
//
// PARAMETROS, por variable de entorno
// ============================================================
//   LOTE_SEMILLA   la del lote a borrar. Obligatoria: no hay "borra todos"
//                  aqui, y es a proposito -- ver abajo.
//
//
// POR QUE NO HAY UN "BORRA TODOS LOS DE MONGO"
// ============================================================
// Porque no se puede distinguir con seguridad un producto de lote de uno que
// publico una persona de verdad desde el panel. Los dos viven solo en Mongo,
// los dos tienen la misma forma, y lo unico que los separa es el marcador del
// nombre -- que alguien puede haber editado.
//
// Con el lote de PostgreSQL la pregunta tiene respuesta exacta: o hay fila en
// `productos` o no la hay. Aqui no. Asi que se borra un lote nombrado, que es
// una peticion concreta, y no "todo lo que parezca generado", que es una
// suposicion sobre el trabajo de otra persona.

const SEMILLA = Number(process.env.LOTE_SEMILLA);
const RUTA_IDS = '/tmp/mesh-lote-mongo-borrados.csv';

function morir(mensaje, pista) {
    print('ERROR: ' + mensaje);
    if (pista) print('HINT:  ' + pista);
    quit(3);
}

if (!Number.isInteger(SEMILLA) || SEMILLA < 0) {
    morir('LOTE_SEMILLA tiene que ser un entero de cero para arriba (llego: ' +
        process.env.LOTE_SEMILLA + ')');
}

const MARCADOR = new RegExp(' M' + SEMILLA + '-[0-9]{4}$');

const ids = db.productos
    .find({ nombre: MARCADOR }, { _id: 1 })
    .toArray()
    .map((d) => d._id);

if (ids.length === 0) {
    morir(
        'La semilla ' + SEMILLA + ' no genero ningun producto en MongoDB',
        'Mira que lotes hay:  db.productos.distinct("nombre", {nombre: / M[0-9]+-[0-9]{4}$/})'
    );
}

// La lista se escribe ANTES de borrar. Despues del deleteMany ya no habria
// forma de saber cuales eran, y PostgreSQL se quedaria con las ofertas
// huerfanas sin nadie que supiera de quien eran.
fs.writeFileSync(RUTA_IDS, ids.join('\n') + '\n');

const prod = db.productos.deleteMany({ _id: { $in: ids } });
const evt = db.productos_eventos.deleteMany({ id_producto: { $in: ids } });

const quedan = db.productos.countDocuments({ nombre: MARCADOR });
if (quedan > 0) {
    morir(quedan + ' productos del lote M' + SEMILLA + ' siguen ahi');
}

print('LOTE_BORRADOS=' + prod.deletedCount);
print(
    'Lote M' + SEMILLA + ' borrado de MongoDB: ' + prod.deletedCount +
        ' productos y ' + evt.deletedCount + ' eventos. Quedan ' +
        db.productos.countDocuments({}) + ' documentos.'
);
print(
    'FALTA POSTGRESQL: sus ofertas siguen ahi. Las borra ' +
        'migrations/lote/borrar_ofertas_mongo.sql con ' + RUTA_IDS + '.'
);
