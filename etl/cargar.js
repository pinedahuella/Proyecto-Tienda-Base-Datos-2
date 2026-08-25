// cargar.js
// Toma lo que sacaron los tres extraer_*.sql y lo escribe en Mongo. Corre
// dentro de mesh-mongo con mongosh, que trae Node adentro: no hay nada que
// instalar.
//
// Escribe cuatro colecciones:
//
//   productos          un documento por producto, con la categoria, las
//                      variantes, sus imagenes y sus caracteristicas
//                      embebidas. El _id es el id_producto del relacional.
//
//   ofertas            un documento por oferta: quien vende esa variante, a
//                      como y con cuantas unidades. El _id es el id_oferta.
//                      NO van embebidas en el producto: el stock cambia en
//                      cada venta y Mongo reescribe el documento entero, asi
//                      que comprar una camisa reescribiria el catalogo de la
//                      camisa. Ver el encabezado de extraer_ofertas.sql.
//
//   productos_eventos  el historial, un documento por evento. El primero es
//                      la creacion y lleva el estado completo; los demas son
//                      modificaciones y llevan solo lo que cambio.
//
//   categorias         la paleta: que caracteristicas ofrece cada categoria,
//                      con su tipo y su unidad. Es lo que arma el formulario
//                      de publicar. No lleva valores.
//
// Dos cosas NO entran en productos_eventos, y las dos por el mismo motivo: no
// se pueden reconstruir porque no se guardaron.
//
//   Las caracteristicas. En el relacional no tienen historial, asi que no hay
//   de donde sacar como estaban en una fecha anterior.
//
//   El PRECIO. Dejo de ser del catalogo al volverse multi-vendedor: ahora es
//   de cada oferta, y su historia vive en precio_historial, en PostgreSQL. Un
//   producto ya no tiene "un precio" que reconstruir; tiene tantos como
//   vendedores. Esto hay que decirlo en el informe: el enunciado pide
//   reconstruir "precio, descripcion y disponibilidad", y el precio ahora se
//   contesta desde el otro lado.
//
// El _id de las cuatro es determinista, asi que correr esto dos veces
// actualiza en vez de duplicar.
//
// El ETL es el unico dueno de estas colecciones: cada documento se reemplaza
// entero, porque PostgreSQL manda. Un campo que la aplicacion escriba aqui por
// su cuenta se pierde en la siguiente corrida.

const RUTA = '/tmp/mesh-productos.json';
const RUTA_CATEGORIAS = '/tmp/mesh-categorias.json';
const RUTA_OFERTAS = '/tmp/mesh-ofertas.json';

// ============================================================
// El historial: de fotos completas a eventos
// ============================================================
// En el relacional cada fila de historial es una foto completa de esa entidad
// en esa fecha. Aqui hace falta lo contrario: una lista de cambios.
//
// Y son dos historiales que corren por separado y con fechas distintas: el del
// producto y el de cada variante. Renombrar el producto no escribe nada en el
// historial de sus variantes.
//
// Por eso el evento no sale de una tabla: sale de juntar las fechas de las
// dos, y en cada fecha volver a armar el estado completo del producto.

// La fila que regia en la fecha t: la ultima con fecha <= t. Las filas ya
// vienen ordenadas de extraer.sql.
function vigenteEn(filas, t) {
    let salida = null;
    for (const fila of filas) {
        if (Date.parse(fila.fecha) <= t) salida = fila;
        else break;
    }
    return salida;
}

// El estado completo del producto en la fecha t, con los campos que si tienen
// historial.
//
// El estado (activo, inactivo) no esta: en el modelo relacional los historiales
// no lo guardan, vive solo en la fila viva. Esta anotado en
// docs/base-de-datos.md y en el README de esta carpeta.
//
// La CATEGORIA si esta, y es nueva: productos_historial ahora guarda en cual
// estaba el producto ese dia. Antes no, y por eso mover un producto de
// categoria reescribia su pasado.
function estadoEn(producto, t) {
    const p = vigenteEn(producto.historial_producto, t);

    // Una variante puede haber nacido despues: solo entran las que ya existian
    // en t. Se agrupa por id para quedarse con la ultima version de cada una.
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
            descripcion:          v.descripcion
        }));

    return {
        nombre:      p ? p.nombre : null,
        descripcion: p ? p.descripcion : null,
        categoria:   p ? p.categoria : null,
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
    // El producto nace con su primera fila de historial. Si no tiene ninguna,
    // se usa la fecha de la fila viva.
    const nacimiento = producto.historial_producto.length > 0
        ? Date.parse(producto.historial_producto[0].fecha)
        : Date.parse(producto.fecha_creacion);

    // Todas las fechas de los dos historiales, sin repetir y en orden. Se
    // comparan como numero y no como texto: asi da igual con que zona horaria
    // se haya extraido.
    const fechas = [
        ...producto.historial_producto,
        ...producto.historial_variantes
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
    const doc = {
        _id:            producto.id_producto,
        nombre:         producto.nombre,
        descripcion:    producto.descripcion,
        fecha_creacion: new Date(producto.fecha_creacion),
        estado:         producto.estado,
        categoria:      producto.categoria,

        // Los dos calculados. Son una COPIA de lo que dicen las ofertas, y hay
        // que recalcularlos cuando una oferta cambie de precio, se quede sin
        // unidades o se pause. Si no, la tarjeta va a decir un precio y la
        // ficha otro.
        precio_tienda:  producto.precio_tienda,
        total_ofertas:  producto.total_ofertas,

        variantes:      producto.variantes.map(v => Object.assign({}, v, {
            fecha_creacion: new Date(v.fecha_creacion)
        }))
    };

    // Las llaves se vuelven a armar en orden: nombre, valor, unidad. jsonb no
    // conserva el orden en que se escribieron, las devuelve ordenadas por
    // longitud, y el documento saldria con el valor antes que el nombre. No
    // cambia lo que se puede consultar, pero el documento se lee y se compara
    // contra lo que dice productos_subproductos.md.
    const enOrden = lista => lista.map(c => ({
        nombre: c.nombre,
        valor:  c.valor,
        unidad: c.unidad
    }));

    // Las caracteristicas se copian solo si el producto tiene alguna. Escribir
    // un arreglo vacio obligaria a quien lee el documento a distinguir "sin
    // caracteristicas" de "caracteristicas vacias", y son la misma cosa.
    if (producto.caracteristicas_adicionales &&
        producto.caracteristicas_adicionales.length > 0) {
        doc.caracteristicas_adicionales = enOrden(producto.caracteristicas_adicionales);
    }
    for (const variante of doc.variantes) {
        if (!variante.caracteristicas_adicionales ||
            variante.caracteristicas_adicionales.length === 0) {
            delete variante.caracteristicas_adicionales;
        } else {
            variante.caracteristicas_adicionales = enOrden(variante.caracteristicas_adicionales);
        }
    }

    return doc;
}

// El dinero se guarda como decimal, no como el numero de JavaScript, que es
// punto flotante y redondea. Postgres lo mando como texto justo para esto: se
// compara como texto mientras se calculan los cambios, y se convierte una sola
// vez al final, cuando ya no queda nada que comparar.
const CAMPOS_DECIMALES = ['precio', 'precio_tienda'];

function aDecimal(valor) {
    if (Array.isArray(valor)) return valor.map(aDecimal);
    if (valor === null || typeof valor !== 'object') return valor;
    if (valor instanceof Date) return valor;

    const salida = {};
    for (const campo of Object.keys(valor)) {
        const v = valor[campo];
        if (CAMPOS_DECIMALES.indexOf(campo) !== -1 && typeof v === 'string') {
            salida[campo] = NumberDecimal(v);
        } else {
            salida[campo] = aDecimal(v);
        }
    }
    return salida;
}

function leerLineas(ruta) {
    return require('fs').readFileSync(ruta, 'utf8')
        .split('\n')
        .filter(linea => linea.trim().length > 0)
        .map(linea => JSON.parse(linea));
}

// ============================================================
// Cargar los productos y sus eventos
// ============================================================
const productos = leerLineas(RUTA);

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

// ============================================================
// Las ofertas
// ============================================================
const ofertas = leerLineas(RUTA_OFERTAS);

const escrituraOfertas = ofertas.map(function (o) {
    const doc = {
        _id:                  o.id_oferta,
        id_producto:          o.id_producto,
        id_producto_variante: o.id_producto_variante,
        nombre_producto:      o.nombre_producto,
        nombre_variante:      o.nombre_variante,
        vendedor:             o.vendedor,
        es_tienda:            o.es_tienda,
        precio:               o.precio,
        stock:                o.stock,
        estado:               o.estado,
        fecha_creacion:       new Date(o.fecha_creacion),
        fecha_actualizacion:  new Date(o.fecha_actualizacion)
    };
    return {
        replaceOne: { filter: { _id: doc._id }, replacement: aDecimal(doc), upsert: true }
    };
});

// ============================================================
// La paleta de las categorias
// ============================================================
// Se escribe entera en cada corrida, igual que los productos: PostgreSQL es el
// dueno. El _id es el id_categoria del relacional, asi que volver a correr
// actualiza en vez de duplicar.
const categorias = leerLineas(RUTA_CATEGORIAS);

const escrituraCategorias = categorias.map(function (categoria) {
    const doc = {
        _id:                      categoria.id_categoria,
        nombre:                   categoria.nombre,
        categoria_padre:          categoria.categoria_padre,
        es_raiz:                  categoria.es_raiz,
        fecha_creacion:           new Date(categoria.fecha_creacion),
        caracteristicas:          categoria.caracteristicas,
        caracteristicas_variante: categoria.caracteristicas_variante
    };
    return {
        replaceOne: { filter: { _id: doc._id }, replacement: aDecimal(doc), upsert: true }
    };
});

// ============================================================
// Escribir, y barrer lo que sobro
// ============================================================
if (escrituraProductos.length > 0)  db.productos.bulkWrite(escrituraProductos);
if (escrituraOfertas.length > 0)    db.ofertas.bulkWrite(escrituraOfertas);
if (escrituraCategorias.length > 0) db.categorias.bulkWrite(escrituraCategorias);
if (escrituraEventos.length > 0)    db.productos_eventos.bulkWrite(escrituraEventos);

// Un upsert actualiza y agrega, pero NO borra: un documento que ya no existe
// en PostgreSQL se quedaria aqui para siempre, y las cuentas seguirian
// cuadrando porque nadie las mira. Ya paso una vez con 47 productos fantasma.
//
// Solo se barren los documentos cuyo _id viene del relacional. Un producto que
// nacio en Mongo (publicado desde el panel) no tiene fila alla y no se toca.
const idsProductos  = productos.map(p => p.id_producto);
const idsOfertas    = ofertas.map(o => o.id_oferta);
const idsCategorias = categorias.map(c => c.id_categoria);

const borradas = db.ofertas.deleteMany({
    _id: { $nin: idsOfertas, $lte: Math.max(0, ...idsOfertas) }
});
const catBorradas = db.categorias.deleteMany({
    _id: { $nin: idsCategorias, $lte: Math.max(0, ...idsCategorias) }
});

print('productos   ' + productos.length);
print('ofertas     ' + ofertas.length + (borradas.deletedCount ? '  (' + borradas.deletedCount + ' borradas)' : ''));
print('categorias  ' + categorias.length + (catBorradas.deletedCount ? '  (' + catBorradas.deletedCount + ' borradas)' : ''));
print('eventos     ' + escrituraEventos.length);
if (sinHistorial > 0) {
    print('AVISO: ' + sinHistorial + ' productos sin ninguna fila de historial: no se pueden reconstruir');
}
