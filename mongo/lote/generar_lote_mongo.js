// ============================================================
// generar_lote_mongo.js -- productos que nacen EN MONGO
// ============================================================
// Crea N productos directamente en el catalogo de MongoDB, sin fila en
// PostgreSQL, que es exactamente como nacen los productos que publica un
// vendedor desde el panel.
//
//
// POR QUE EXISTE, SI YA HAY UN GENERADOR
// ============================================================
// `migrations/lote/generar_lote.sql` crea productos en PostgreSQL y el ETL los
// lleva a Mongo. Este hace lo contrario, y no es lo mismo:
//
//   generar_lote.sql   producto en PostgreSQL -> ETL -> documento en Mongo.
//                      Tiene historial, ofertas, kardex. Es reconstruible por
//                      fecha. Es como nacio el catalogo curado.
//
//   este archivo       documento en Mongo y nada mas. NO tiene fila en
//                      `productos` de PostgreSQL, asi que el ETL no lo mira
//                      nunca. Es como nace hoy un producto publicado desde el
//                      panel de vendedor.
//
// El backend lo dice por escrito en
// `backend/src/services/vendedores/productos.service.ts`: "los productos ya no
// se registran en PostgreSQL". O sea que ESTE es el camino por el que van a
// nacer los productos de verdad, y hasta ahora no habia forma de generar
// muchos para probarlo.
//
// Sirve para dos cosas que el otro no puede:
//
//   1. Llenar Mongo rapido, sin pasar por el ETL. Para medir consultas e
//      indices con volumen, el viaje por PostgreSQL es tiempo perdido.
//   2. Probar que la mezcla funciona: un catalogo con productos de los dos
//      origenes conviviendo es justo donde aparecio el fallo de los ids.
//
//
// EL FALLO QUE ESTE ARCHIVO TIENE QUE ESQUIVAR, Y NO ES TEORICO
// ============================================================
// Hay DOS repartidores de id de producto que no se hablan:
//
//   PostgreSQL   `productos.id_producto` es un bigserial con su propia cuenta.
//   el panel     lee el mayor `_id` de Mongo y le suma uno.
//
// Ya divergieron una vez: Mongo tenia los _id 103 a 106 de productos del panel
// y la secuencia de PostgreSQL seguia en 102, a punto de entregar el 103. Si
// eso hubiera pasado, el ETL habria hecho `replaceOne` sobre el _id 103 y
// habria MACHACADO al producto del panel, sin un solo error: `etl/cargar.js` no
// tiene barrido ni aviso para `db.productos`.
//
// Por eso este archivo NO empieza en el mayor _id de Mongo mas uno. Empieza
// despues del mayor de LAS DOS BASES, que llega en LOTE_MAX_PG_PRODUCTO. Un
// producto creado aqui con un id que PostgreSQL todavia puede repartir es una
// bomba con temporizador: no falla hoy, falla la proxima vez que corra el ETL.
//
//
// PARAMETROS, por variable de entorno
// ============================================================
// mongosh no tiene el `-v` de psql, asi que van por el entorno. Se leen una
// sola vez, aqui arriba, para que un valor mal puesto falle antes de escribir
// nada y no a la mitad.
//
//   LOTE_PRODUCTOS          cuantos crear. De 1 a 9999.
//   LOTE_SEMILLA            el CID. La misma semilla da el mismo lote.
//   LOTE_MAX_PG_PRODUCTO    mayor id_producto que hay en PostgreSQL.
//   LOTE_MAX_PG_VARIANTE    mayor id_producto_variante que hay en PostgreSQL.
//
// Los dos ultimos no se pueden averiguar desde aqui -- este script solo habla
// con Mongo -- y por eso los pasa quien lo invoca. `arrancar.ps1 -ProductosMongo`
// los consulta y los pone.
//
//
// LO QUE DEJA PARA EL PASO SIGUIENTE
// ============================================================
// Escribe /tmp/mesh-lote-mongo.csv con una linea por oferta a crear:
//
//   id_producto,id_variante,correo_vendedor,precio,stock
//
// Las ofertas viven en PostgreSQL (es el ADR-2: el descuento de stock tiene que
// ser atomico y eso lo sostiene un SELECT ... FOR UPDATE), asi que este archivo
// no las puede crear. Las crea `migrations/lote/ofertas_mongo.sql` leyendo ese
// csv.
//
// Y los precios los elige ESTE archivo, no aquel, a proposito. Si cada lado
// sorteara los suyos harian falta dos implementaciones del mismo azar que
// tienen que coincidir exactamente, y el dia que una cambie el documento diria
// un precio y la oferta otro. Aqui se sortea una vez y el numero VIAJA. Un dato
// compartido no se puede desincronizar; dos algoritmos si.

const PRODUCTOS = Number(process.env.LOTE_PRODUCTOS);
const MAX_PG_PRODUCTO = Number(process.env.LOTE_MAX_PG_PRODUCTO);
const MAX_PG_VARIANTE = Number(process.env.LOTE_MAX_PG_VARIANTE);

// La semilla se puede omitir, y entonces se elige una LIBRE aqui dentro.
//
// La busqueda vive en este archivo y no en quien lo llama a proposito: el dato
// que hay que mirar son los nombres de los productos de MongoDB, y este es el
// unico que los ve. Hacerlo desde PowerShell obligaria a mandar una consulta de
// agregacion por la linea de comandos, con sus comillas anidadas, para
// averiguar algo que aqui es una linea.
//
// Sin semilla, quien corre esto esta pidiendo mas productos y no un lote
// reproducible. Pero la elegida se IMPRIME igual, porque un lote irrepetible no
// serviria para lo que la bandera existe.
const SEMILLA = (function () {
    const puesta = process.env.LOTE_SEMILLA;
    if (puesta !== undefined && puesta !== null && String(puesta).trim() !== '') {
        return Number(puesta);
    }
    // El mayor numero de semilla que ya se uso, mas uno. Se saca del nombre:
    // " M<semilla>-<n>". Los lotes salen M1, M2, M3 y nunca chocan.
    let mayor = 0;
    db.productos
        .find({ nombre: / M[0-9]+-[0-9]{4}$/ }, { nombre: 1 })
        .forEach(function (d) {
            const m = d.nombre.match(/ M([0-9]+)-[0-9]{4}$/);
            if (m) {
                const s = Number(m[1]);
                if (s > mayor) mayor = s;
            }
        });
    return mayor + 1;
})();
const SEMILLA_ELEGIDA =
    process.env.LOTE_SEMILLA === undefined ||
    process.env.LOTE_SEMILLA === null ||
    String(process.env.LOTE_SEMILLA).trim() === '';

const RUTA_CSV = '/tmp/mesh-lote-mongo.csv';

function morir(mensaje, pista) {
    print('ERROR: ' + mensaje);
    if (pista) print('HINT:  ' + pista);
    quit(3);
}

if (!Number.isInteger(PRODUCTOS) || PRODUCTOS < 1 || PRODUCTOS > 9999) {
    morir(
        'LOTE_PRODUCTOS tiene que ser un entero de 1 a 9999 (llego: ' +
            process.env.LOTE_PRODUCTOS + ')',
        'El tope sale del marcador del nombre, que lleva cuatro digitos.'
    );
}
if (!Number.isInteger(SEMILLA) || SEMILLA < 0) {
    morir('LOTE_SEMILLA tiene que ser un entero de cero para arriba (llego: ' +
        process.env.LOTE_SEMILLA + ')');
}
if (!Number.isInteger(MAX_PG_PRODUCTO) || MAX_PG_PRODUCTO < 0) {
    morir(
        'LOTE_MAX_PG_PRODUCTO no llego o no es un entero (llego: ' +
            process.env.LOTE_MAX_PG_PRODUCTO + ')',
        'Es el mayor id_producto de PostgreSQL. Sin el no se puede saber desde ' +
            'donde numerar sin pisar lo que PostgreSQL todavia puede repartir.'
    );
}
if (!Number.isInteger(MAX_PG_VARIANTE) || MAX_PG_VARIANTE < 0) {
    morir('LOTE_MAX_PG_VARIANTE no llego o no es un entero (llego: ' +
        process.env.LOTE_MAX_PG_VARIANTE + ')');
}

// ============================================================
// El azar, con semilla
// ============================================================
// mulberry32, el mismo que usa migrations/datos/generador.js. Se copia el
// algoritmo y no se importa porque mongosh no ve esa carpeta, y porque son
// treinta caracteres: una dependencia entre dos motores para ahorrarse eso
// costaria mas de lo que ahorra.
//
// La semilla se mezcla con una constante para que el lote M7 y el lote L7 --
// el de este archivo y el de generar_lote.sql -- NO salgan iguales. Comparten
// el numero que teclea la persona, pero son catalogos distintos y verlos
// identicos haria pensar que uno piso al otro.
function crearAzar(semilla) {
    let a = (semilla ^ 0x9e3779b9) >>> 0;
    return function () {
        a = (a + 0x6d2b79f5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
const azar = crearAzar(SEMILLA);
const entre = (min, max) => min + Math.floor(azar() * (max - min + 1));

// ============================================================
// El marcador del nombre
// ============================================================
// Misma idea que en generar_lote.sql y por los mismos dos motivos: que correr
// dos veces la misma semilla choque de frente en vez de duplicar en silencio, y
// que se vea de un vistazo que producto es generado.
//
// La letra es M y no L para poder distinguir los dos generadores. Importa mas
// de lo que parece: los de L tienen fila en PostgreSQL y los de M no, asi que
// se borran de formas distintas y el ETL trata a unos y no a otros.
const MARCADOR = new RegExp(' M' + SEMILLA + '-[0-9]{4}$');

// Reconoce los marcadores de LOS DOS generadores, y la L no es un adorno.
//
// Se descubrio probando: con la expresion mirando solo la M, este archivo
// clonaba productos que habia creado generar_lote.sql y el nombre acumulaba
// marcadores, "La casa de los relojes detenidos L1-0493 M77-0002". Dos vueltas
// mas y el nombre se pasa del varchar(200) por el que despues viaja la oferta.
//
// Y hay un motivo peor que el largo: clonar un clon copia el clon, no el
// original. El catalogo generado convergeria hacia los pocos productos que el
// primer lote eligio, y dejaria de parecerse al catalogo de verdad.
const MARCADOR_CUALQUIERA = / [LM][0-9]+-[0-9]{4}$/;

const yaHay = db.productos.countDocuments({ nombre: MARCADOR });
if (yaHay > 0) {
    morir(
        'La semilla ' + SEMILLA + ' ya genero ' + yaHay + ' productos en MongoDB',
        'Corre con otra semilla, o borra antes los que terminan en el marcador ' +
            'de esa semilla. El procedimiento esta en mongo/lote/README.md'
    );
}

// ============================================================
// Desde donde numerar
// ============================================================
// El mayor de las DOS bases, no el de Mongo. Ver la cabecera.
const maxMongoProducto = (function () {
    const d = db.productos.find({}, { _id: 1 }).sort({ _id: -1 }).limit(1).toArray();
    return d.length > 0 ? d[0]._id : 0;
})();

const maxMongoVariante = (function () {
    const r = db.productos
        .aggregate([
            { $unwind: '$variantes' },
            { $group: { _id: null, m: { $max: '$variantes.id_producto_variante' } } }
        ])
        .toArray();
    return r.length > 0 && r[0].m != null ? r[0].m : 0;
})();

const desdeProducto = Math.max(maxMongoProducto, MAX_PG_PRODUCTO) + 1;
const desdeVariante = Math.max(maxMongoVariante, MAX_PG_VARIANTE) + 1;

// ============================================================
// Las plantillas
// ============================================================
// Cada producto nuevo CLONA uno del catalogo. Es la misma decision que toma
// generar_lote.sql y por el mismo motivo, que aqui pesa incluso mas: el
// documento de Mongo lleva la categoria embebida y las caracteristicas con su
// tipo ya resuelto (`valor: 8` es un entero, no el texto "8"). Inventarlos
// desde cero seria escribir a mano lo que la base ya sabe, y un tipo
// equivocado no da error: rompe las consultas del catalogo, que es donde se
// nota tarde.
//
// Se excluyen los productos generados por cualquier lote (M o L) para que el
// nombre no acumule marcadores y para no clonar un clon.
const plantillas = db.productos
    .find({
        nombre: { $not: MARCADOR_CUALQUIERA },
        estado: 'activo',
        'categoria.id_categoria': { $ne: null },
        'variantes.0': { $exists: true }
    })
    .toArray();

if (plantillas.length === 0) {
    morir(
        'No hay ningun producto del catalogo que sirva de plantilla',
        'Hace falta al menos un producto activo, con categoria y con variantes. ' +
            'Con la base recien creada hay mas de cien.'
    );
}

// ============================================================
// Armar el lote
// ============================================================
// Los vendedores que ofertan. Salen de la semilla y no de PostgreSQL porque
// este script no lo ve; son los correos fijos del conjunto de datos y estan
// escritos en migrations/datos/generador.js.
const TIENDA = 'tienda@mesh.com';
const VENDEDORES = [
    'ventas.norte@mesh.com',
    'ventas.sur@mesh.com',
    'ventas.oriente@mesh.com',
    'ventas.poniente@mesh.com'
];

const ahora = new Date();
const documentos = [];
const eventos = [];
const filasCsv = [];

for (let n = 0; n < PRODUCTOS; n++) {
    const plantilla = plantillas[Math.floor(azar() * plantillas.length)];
    const idProducto = desdeProducto + n;
    const idVariante = desdeVariante + n;

    const marca = ' M' + SEMILLA + '-' + String(n + 1).padStart(4, '0');
    // El varchar de PostgreSQL para el nombre es de 200, y aunque aqui no hay
    // esa restriccion, la oferta que se crea despues si viaja por alla. Se
    // recorta la BASE y nunca el marcador: al reves, dos productos del mismo
    // lote podrian terminar llamandose igual.
    const nombre = plantilla.nombre.slice(0, 200 - marca.length) + marca;

    const varPlantilla = plantilla.variantes[0];

    // El precio de la tienda sale del de la plantilla, movido, para que el
    // catalogo generado no salga todo al mismo numero. Se redondea a centavos
    // porque es dinero y porque asi entra igual en el decimal de PostgreSQL.
    const precioBase = Number(
        (varPlantilla.precio_tienda && varPlantilla.precio_tienda.toString()) ||
            (plantilla.precio_tienda && plantilla.precio_tienda.toString()) ||
            500
    );
    const precioTienda = Math.round(precioBase * (0.85 + azar() * 0.3) * 100) / 100;
    const stockTienda = azar() < 0.1 ? 0 : entre(3, 40);

    // Las ofertas de este producto. La tienda SIEMPRE, que es lo que garantiza
    // que la tarjeta tenga un precio que ensenar; los demas con probabilidad,
    // igual que en el conjunto de datos.
    const ofertas = [{ correo: TIENDA, precio: precioTienda, stock: stockTienda }];
    for (const correo of VENDEDORES) {
        if (azar() > 0.42) continue;
        const precio = Math.round(precioTienda * (0.92 + azar() * 0.16) * 100) / 100;
        const suerte = azar();
        ofertas.push({
            correo,
            precio: Math.max(1, precio),
            stock: suerte < 0.16 ? 0 : entre(1, 25)
        });
    }

    // Los cinco numeros calculados, con la MISMA definicion que etl/extraer.sql
    // les da. No se inventan: si aqui contaran otra cosa, el mismo campo
    // significaria dos cosas distintas segun de donde vino el producto, y las
    // consultas del catalogo darian resultados que nadie puede explicar.
    //
    //   precio_tienda   el de la tienda, que es el que se ensena
    //   precio_desde    el mas barato de cualquier vendedor, mire o no el stock
    //   stock_tienda    unidades de la tienda
    //   stock_total     unidades entre todos
    //   total_ofertas   cuantos vendedores distintos la tienen
    //
    // Y hay_descuento, que aqui es siempre false: las ofertas del lote nacen
    // sin descuento (el CSV no trae porcentaje), asi que los dos precios son
    // los de lista y ninguna oferta activa tiene uno puesto.
    const precioDesde = Math.min.apply(null, ofertas.map((o) => o.precio));
    const stockTotal = ofertas.reduce((s, o) => s + o.stock, 0);

    const variante = {
        id_producto_variante: idVariante,
        nombre_variante: varPlantilla.nombre_variante,
        descripcion: varPlantilla.descripcion || null,
        fecha_creacion: ahora,
        estado: 'activa',
        // Las imagenes se copian de la plantilla: son urls ya comprobadas, y
        // reusarlas es exactamente para lo que existe imagen_producto en el
        // relacional -- la foto es del catalogo, no del vendedor.
        imagenes: (varPlantilla.imagenes || []).slice(0, 1),
        precio_tienda: NumberDecimal(precioTienda.toFixed(2)),
        precio_desde: NumberDecimal(precioDesde.toFixed(2)),
        stock_tienda: stockTienda,
        stock_total: stockTotal,
        total_ofertas: ofertas.length,
        hay_descuento: false
    };
    if (varPlantilla.caracteristicas_adicionales) {
        variante.caracteristicas_adicionales = varPlantilla.caracteristicas_adicionales;
    }

    const doc = {
        _id: idProducto,
        nombre: nombre,
        descripcion: plantilla.descripcion || null,
        fecha_creacion: ahora,
        estado: 'activo',
        categoria: plantilla.categoria,
        precio_tienda: NumberDecimal(precioTienda.toFixed(2)),
        precio_desde: NumberDecimal(precioDesde.toFixed(2)),
        stock_tienda: stockTienda,
        stock_total: stockTotal,
        total_ofertas: ofertas.length,
        hay_descuento: false,
        // El piso de las resenas. Va explicito y no se deja ausente: en Mongo
        // un $gte sobre un campo AUSENTE no hace match, asi que un producto sin
        // estos campos DESAPARECE del catalogo en cuanto alguien filtra por
        // nota, sin ningun error. Es el mismo motivo por el que
        // mongo/002_resenas.js rellena a los productos del panel.
        resenas_promedio: 0,
        resenas_total: 0,
        variantes: [variante]
    };
    if (plantilla.caracteristicas_adicionales) {
        doc.caracteristicas_adicionales = plantilla.caracteristicas_adicionales;
    }

    documentos.push(doc);

    // El evento de creacion, con la misma forma que escribe el panel:
    // _id "<producto>-<numero>", y `datos` con el estado completo. Sin el, el
    // producto no se puede reconstruir por fecha y la consulta de historial lo
    // deja fuera en silencio.
    eventos.push({
        _id: idProducto + '-1',
        id_producto: idProducto,
        numero: 1,
        fecha: ahora,
        operacion: 'creacion',
        datos: {
            nombre: doc.nombre,
            descripcion: doc.descripcion,
            fecha_creacion: doc.fecha_creacion,
            estado: doc.estado,
            categoria: doc.categoria,
            precio_tienda: doc.precio_tienda,
            precio_desde: doc.precio_desde,
            stock_tienda: doc.stock_tienda,
            stock_total: doc.stock_total,
            total_ofertas: doc.total_ofertas,
            variantes: doc.variantes
        }
    });

    for (const o of ofertas) {
        filasCsv.push(
            [idProducto, idVariante, o.correo, o.precio.toFixed(2), o.stock].join(',')
        );
    }
}

// ============================================================
// Escribir
// ============================================================
// Todo junto y al final, no dentro del bucle. MongoDB no tiene transaccion aqui
// (el despliegue es de un nodo, sin replica set), asi que no hay forma de
// deshacer a medias; lo que si se puede es reducir la ventana a un solo
// bulkWrite en vez de N inserciones sueltas.
db.productos.insertMany(documentos, { ordered: false });
db.productos_eventos.insertMany(eventos, { ordered: false });

fs.writeFileSync(RUTA_CSV, filasCsv.join('\n') + '\n');

// ============================================================
// Comprobarse
// ============================================================
const creados = db.productos.countDocuments({ nombre: MARCADOR });
if (creados !== PRODUCTOS) {
    morir(
        'Se pidieron ' + PRODUCTOS + ' productos y quedaron ' + creados,
        'Alguno choco por _id repetido. Revisa que LOTE_MAX_PG_PRODUCTO sea el ' +
            'mayor id_producto real de PostgreSQL.'
    );
}
const sinNota = db.productos.countDocuments({
    nombre: MARCADOR,
    resenas_promedio: { $exists: false }
});
if (sinNota > 0) {
    morir(sinNota + ' productos quedaron sin resenas_promedio');
}

if (SEMILLA_ELEGIDA) {
    print('Sin -Semilla: se usa la ' + SEMILLA + ', que esta libre');
    print(
        'Para volver a generar ESTE mismo lote:  .\\arrancar.ps1 -ProductosMongo ' +
            PRODUCTOS + ' -Semilla ' + SEMILLA
    );
}
print('LOTE_SEMILLA_USADA=' + SEMILLA);
print('LOTE_DESDE=' + desdeProducto);
print('LOTE_HASTA=' + (desdeProducto + PRODUCTOS - 1));
print('LOTE_OFERTAS=' + filasCsv.length);
print(
    'Lote M' + SEMILLA + ' verificado. ' + creados + ' productos (_id ' +
        desdeProducto + ' al ' + (desdeProducto + PRODUCTOS - 1) + '), ' +
        filasCsv.length + ' ofertas anotadas en ' + RUTA_CSV + '.'
);
print(
    'FALTA POSTGRESQL: los productos ya estan en el catalogo pero sus ofertas no ' +
        'existen todavia. Las crea migrations/lote/ofertas_mongo.sql con ese csv.'
);
