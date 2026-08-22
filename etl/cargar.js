// cargar.js
// Toma lo que saco extraer.sql y lo escribe en Mongo. Corre dentro de
// mesh-mongo con mongosh, que trae Node adentro: no hay nada que instalar.
//
// Escribe dos colecciones:
//
//   productos          un documento por producto, con la categoria, las
//                      variantes, las imagenes y el vendedor embebidos.
//                      El _id es el id_producto del relacional.
//
//   productos_eventos  el historial, un documento por evento. El primero es
//                      la creacion y lleva el estado completo; los demas son
//                      modificaciones y llevan solo lo que cambio.
//
// El _id de los dos es determinista, asi que correr esto dos veces actualiza
// en vez de duplicar.
//
// El ETL es el unico dueno de estas dos colecciones: cada documento se
// reemplaza entero, porque PostgreSQL manda. Un campo que la aplicacion
// escriba aqui por su cuenta se pierde en la siguiente corrida.

const RUTA = '/tmp/mesh-productos.json';

// ============================================================
// El historial: de fotos completas a eventos
// ============================================================
// En el relacional cada fila de historial es una foto completa de esa entidad
// en esa fecha. Aqui hace falta lo contrario: una lista de cambios.
//
// Y son tres historiales que corren por separado y con fechas distintas: el
// del producto, el de cada variante y el de la categoria. Un cambio de
// comision no escribe nada en el historial del producto.
//
// Por eso el evento no sale de una tabla: sale de juntar las fechas de las
// tres, y en cada fecha volver a armar el estado completo del producto.

// La fila que regia en la fecha t: la ultima con fecha <= t. Las filas ya
// vienen ordenadas de extraer.sql.
function vigenteEn(filas, t) {
    let encontrada = null;
    for (const fila of filas) {
        if (Date.parse(fila.fecha) <= t) {
            encontrada = fila;
        }
    }
    return encontrada;
}

// El estado completo del producto en la fecha t, con los campos que si tienen
// historial. El estado (activo, agotado) no esta: en el modelo relacional los
// historiales no lo guardan, vive solo en la fila viva. Esta anotado en
// docs/base-de-datos.md y en el README de esta carpeta.
function estadoEn(producto, t) {
    const p = vigenteEn(producto.historial_producto, t);
    const c = vigenteEn(producto.historial_categoria, t);

    // Las variantes se agrupan por id: cada una tiene su propia linea de
    // tiempo. Una variante que todavia no existia en t no aparece.
    const porVariante = new Map();
    for (const fila of producto.historial_variantes) {
        if (Date.parse(fila.fecha) > t) continue;
        porVariante.set(fila.id_producto_variante, fila);
    }

    const variantes = [...porVariante.values()]
        .sort((a, b) => a.id_producto_variante - b.id_producto_variante)
        .map(v => ({
            id_producto_variante: v.id_producto_variante,
            nombre_variante:      v.nombre_variante,
            precio:               v.precio,
            descripcion:          v.descripcion
        }));

    return {
        nombre:      p ? p.nombre : null,
        descripcion: p ? p.descripcion : null,
        categoria:   c ? { nombre: c.nombre, porcentaje_comision: c.porcentaje_comision } : null,
        variantes:   variantes
    };
}

// Los campos del estado que cambiaron entre una fecha y la siguiente.
//
// La comparacion es por campo de primer nivel, y a proposito: la consulta de
// reconstruccion junta los eventos con mergeObjects, que mezcla superficial.
// Si un evento guardara media categoria, al mezclarla borraria la otra mitad.
// Por eso cuando algo de la categoria cambia se guarda la categoria entera, y
// cuando algo de una variante cambia se guarda el arreglo de variantes entero.
function diferencias(antes, ahora) {
    const cambios = {};
    for (const campo of Object.keys(ahora)) {
        if (JSON.stringify(antes[campo]) !== JSON.stringify(ahora[campo])) {
            cambios[campo] = ahora[campo];
        }
    }
    return cambios;
}

function eventosDe(producto) {
    // La categoria casi siempre es mas vieja que el producto: se creo antes y
    // ya cambio de comision alguna vez. Esas fechas anteriores no son eventos
    // de este producto, todavia no existia; si se cuentan, el primer evento
    // sale con el nombre en null y sin variantes.
    //
    // El producto nace con su primera fila de historial. Si no tiene ninguna,
    // se usa la fecha de la fila viva.
    const nacimiento = producto.historial_producto.length > 0
        ? Date.parse(producto.historial_producto[0].fecha)
        : Date.parse(producto.fecha_creacion);

    // Todas las fechas de los tres historiales, sin repetir y en orden. Se
    // comparan como numero y no como texto: asi da igual con que zona horaria
    // se haya extraido.
    const fechas = [
        ...producto.historial_producto,
        ...producto.historial_variantes,
        ...producto.historial_categoria
    ].map(f => Date.parse(f.fecha));

    const orden = [...new Set(fechas)]
        .filter(t => t >= nacimiento)
        .sort((a, b) => a - b);

    const eventos = [];
    let anterior = null;

    for (const t of orden) {
        const actual = estadoEn(producto, t);
        const numero = eventos.length + 1;
        const base = {
            _id:         producto.id_producto + '-' + numero,
            id_producto: producto.id_producto,
            numero:      numero,
            fecha:       new Date(t)
        };

        if (anterior === null) {
            eventos.push(Object.assign(base, { operacion: 'creacion', datos: actual }));
        } else {
            const cambios = diferencias(anterior, actual);
            // Dos historiales pueden coincidir en fecha y describir el mismo
            // estado. Un evento vacio no aporta nada y ademas correria la
            // numeracion de los que vienen despues.
            if (Object.keys(cambios).length === 0) continue;
            eventos.push(Object.assign(base, { operacion: 'modificacion', cambios: cambios }));
        }
        anterior = actual;
    }

    return eventos;
}

// ============================================================
// El documento del producto
// ============================================================
function documentoDe(producto) {
    return {
        _id:            producto.id_producto,
        nombre:         producto.nombre,
        descripcion:    producto.descripcion,
        fecha_creacion: new Date(producto.fecha_creacion),
        estado:         producto.estado,
        vendedor:       producto.vendedor,
        categoria:      producto.categoria,
        variantes:      producto.variantes.map(v => Object.assign({}, v, {
            fecha_creacion: new Date(v.fecha_creacion)
        }))
    };
}

// El dinero se guarda como decimal, no como el numero de JavaScript, que es
// punto flotante y redondea. Postgres lo mando como texto justo para esto: se
// compara como texto mientras se calculan los cambios, y se convierte una sola
// vez al final, cuando ya no queda nada que comparar.
const CAMPOS_DECIMALES = ['precio', 'porcentaje_comision'];

function aDecimal(valor) {
    if (Array.isArray(valor)) return valor.map(aDecimal);
    if (valor === null || typeof valor !== 'object') return valor;
    if (valor instanceof Date) return valor;

    const salida = {};
    for (const campo of Object.keys(valor)) {
        const v = valor[campo];
        salida[campo] = (CAMPOS_DECIMALES.indexOf(campo) !== -1 && typeof v === 'string')
            ? NumberDecimal(v)
            : aDecimal(v);
    }
    return salida;
}

// ============================================================
// Cargar
// ============================================================
const texto = require('fs').readFileSync(RUTA, 'utf8');

// extraer.sql devuelve una linea por producto, no un arreglo
const productos = texto.split('\n')
    .filter(linea => linea.trim().length > 0)
    .map(linea => JSON.parse(linea));

const escrituraProductos = [];
const escrituraEventos = [];
let sinHistorial = 0;

for (const producto of productos) {
    const doc = aDecimal(documentoDe(producto));
    escrituraProductos.push({
        // replaceOne y no updateOne con set: el documento se deriva entero de
        // PostgreSQL, asi que un campo que ya no exista alla tampoco debe
        // quedar aqui.
        replaceOne: { filter: { _id: doc._id }, replacement: doc, upsert: true }
    });

    const eventos = eventosDe(producto);
    if (eventos.length === 0) {
        // Sin historial no hay nada que reconstruir. Pasa si alguien inserto
        // el producto sin escribir su fila de historial; se avisa en vez de
        // dejarlo pasar callado.
        sinHistorial++;
    }
    for (const evento of eventos) {
        escrituraEventos.push({
            replaceOne: { filter: { _id: evento._id }, replacement: aDecimal(evento), upsert: true }
        });
    }

    // Si el historial encogio, por ejemplo porque se corrigio una fila mal
    // fechada, los eventos sobrantes de la corrida anterior seguirian ahi con
    // su _id viejo.
    db.productos_eventos.deleteMany({
        id_producto: producto.id_producto,
        numero: { $gt: eventos.length }
    });
}

if (escrituraProductos.length > 0) {
    db.productos.bulkWrite(escrituraProductos);
}
if (escrituraEventos.length > 0) {
    db.productos_eventos.bulkWrite(escrituraEventos);
}

// El unico indice que hace falta. La reconstruccion pide los eventos de un
// producto hasta una fecha y los ordena por fecha: con este indice la base
// entra directo al producto, lee el tramo que le toca y ya sale ordenado, sin
// recorrer la coleccion ni ordenar en memoria.
db.productos_eventos.createIndex({ id_producto: 1, fecha: 1 });

// El indice del catalogo. El patron de consulta es el que nombra el documento
// del curso: "consulta del catalogo por parte del cliente, con filtros por
// categoria". Sin el, filtrar por categoria recorre la coleccion entera.
db.productos.createIndex({ 'categoria.nombre': 1, estado: 1 });

print('productos: ' + escrituraProductos.length);
print('eventos:   ' + escrituraEventos.length);
if (sinHistorial > 0) {
    print('AVISO: ' + sinHistorial + ' producto(s) sin historial, no generaron eventos');
}
