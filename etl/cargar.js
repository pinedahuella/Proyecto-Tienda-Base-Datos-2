// cargar.js
// Toma lo que sacaron los dos extraer_*.sql y lo escribe en Mongo. Corre
// dentro de mesh-mongo con mongosh, que trae Node adentro: no hay nada que
// instalar.
//
// Escribe tres colecciones:
//
//   productos          un documento por producto, con la categoria, las
//                      variantes, sus imagenes y sus caracteristicas
//                      embebidas. El _id es el id_producto del relacional.
//
//   productos_eventos  el historial, un documento por evento. El primero es
//                      la creacion y lleva el estado completo; los demas son
//                      modificaciones y llevan solo lo que cambio.
//
//   categorias         la paleta: que caracteristicas ofrece cada categoria,
//                      con su tipo y su unidad. Es lo que arma el formulario
//                      de publicar. No lleva valores.
//
// Las CARACTERISTICAS si entran, pero solo en el evento de creacion. En el
// relacional no tienen historial, asi que el ETL solo conoce las de hoy: las
// escribe iguales en todas las fotos que arma y por eso salen enteras en la
// creacion y nunca como un cambio. Reconstruir a una fecha devuelve las de HOY,
// y eso hay que decirlo.
//
// Lo que NO entra:
//
//   El PRECIO. Dejo de ser del catalogo al volverse multi-vendedor: ahora es
//   de cada oferta, y su historia vive en precio_historial, en PostgreSQL. Un
//   producto ya no tiene "un precio" que reconstruir; tiene tantos como
//   vendedores. Esto hay que decirlo en el informe: el enunciado pide
//   reconstruir "precio, descripcion y disponibilidad", y el precio ahora se
//   contesta desde el otro lado.
//
// LAS OFERTAS NO SE COPIAN AQUI, y es deliberado. Precio, stock y estado
// cambian en cada venta; sostenerlos al dia en dos bases a la vez es
// exactamente el riesgo de inconsistencia que el proyecto quiere evitar. Se
// quedan en PostgreSQL, que es donde ademas se decide si alcanza para vender.
//
// Lo unico que viaja de ellas son cinco numeros AGREGADOS por producto
// (precio_tienda, precio_desde, stock_tienda, stock_total y total_ofertas),
// que los calcula extraer.sql. La lista tiene que decir los cinco: contarlos
// mal aqui hace creer que sobra o falta uno al comparar con la consulta. Esos
// si son copias, pero de un dato agregado y para pintar una tarjeta: si quedan
// viejos la lista miente un rato, no se vende de mas.
//
// La ficha del producto, que si necesita las ofertas de verdad, las pide a
// PostgreSQL.
//
// El _id de las tres es determinista, asi que correr esto dos veces actualiza
// en vez de duplicar.
//
// El ETL es el unico dueno de estas colecciones: cada documento se reemplaza
// entero, porque PostgreSQL manda. Un campo que la aplicacion escriba aqui por
// su cuenta se pierde en la siguiente corrida.

const RUTA = '/tmp/mesh-productos.json';
const RUTA_CATEGORIAS = '/tmp/mesh-categorias.json';

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

    // Las caracteristicas NO tienen historial en el relacional: solo se conocen
    // las de hoy. Se ponen iguales en todas las fotos que arma el ETL, y por eso
    // salen enteras en el evento de creacion y NUNCA como un cambio: diferencias()
    // nunca las ve moverse.
    //
    // Es a proposito, y hay que decirlo en el informe: reconstruir un producto a
    // una fecha devuelve las caracteristicas de HOY, no las de ese dia. Para que
    // una modificacion las mostrara harian falta dos tablas de historial que no
    // estan en el ER.
    const caracteristicasHoy = new Map();
    for (const v of producto.variantes) {
        caracteristicasHoy.set(v.id_producto_variante, v.caracteristicas_adicionales || []);
    }

    const variantes = [...porVariante.values()]
        .sort((a, b) => a.id_producto_variante - b.id_producto_variante)
        .map(v => {
            const salida = {
                id_producto_variante: v.id_producto_variante,
                nombre_variante:      v.nombre_variante,
                descripcion:          v.descripcion
            };
            const cars = caracteristicasHoy.get(v.id_producto_variante);
            if (cars && cars.length > 0) salida.caracteristicas_adicionales = cars;
            return salida;
        });

    const estado = {
        nombre:      p ? p.nombre : null,
        descripcion: p ? p.descripcion : null,
        categoria:   p ? p.categoria : null,
        variantes:   variantes
    };

    if (producto.caracteristicas_adicionales &&
        producto.caracteristicas_adicionales.length > 0) {
        estado.caracteristicas_adicionales = producto.caracteristicas_adicionales;
    }

    return estado;
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

        // Los cinco calculados. Son una COPIA de lo que dicen las ofertas, y
        // hay que recalcularlos cuando una oferta cambie de precio, se quede
        // sin unidades o se pause. Si no, la tarjeta va a decir un precio y la
        // ficha otro.
        //
        // Los dos de stock van SUMADOS sobre todas las variantes, porque la
        // tarjeta del catalogo ensena un producto y no una variante. Y solo
        // cuentan ofertas activas: las dos significan "unidades que se pueden
        // comprar hoy".
        precio_tienda:  producto.precio_tienda,
        precio_desde:   producto.precio_desde,
        stock_tienda:   producto.stock_tienda,
        stock_total:    producto.stock_total,
        total_ofertas:  producto.total_ofertas,

        // Las dos de resenas se quedan FUERA de CAMPOS_DECIMALES, y es a
        // proposito. Esa lista convierte por NOMBRE del campo y solo cuando el
        // valor llega como string; estas dos vienen ya como numero desde
        // extraer.sql, asi que pasan intactas. Tienen que quedarse numero: el
        // catalogo VA A FILTRAR con $gte y a ORDENAR con $sort sobre
        // resenas_promedio -- para eso existe ya el indice catalogo_rating de
        // mongo/002_resenas.js --, y Mongo compara un campo de texto contra un
        // numero sin dar ningun error, devolviendo resultados equivocados en
        // silencio.
        //
        // EN FUTURO Y NO EN PRESENTE, que la diferencia importa: esa consulta
        // TODAVIA NO EXISTE. No hay una sola linea en backend/ ni en frontend/
        // que lea resenas_promedio, y se comprueba en un comando:
        //
        //   grep -rn resenas_promedio backend/ frontend/
        //
        // que hoy no devuelve nada. El campo se escribe con el tipo correcto y
        // se indexa ANTES de que la consulta llegue, y es deliberado: el dia en
        // que alguien conecte el filtro, un campo de texto no daria error, solo
        // listas equivocadas en silencio, y para entonces ya llevaria un rato
        // mintiendo. El argumento vale entero; lo que no vale es contarlo como
        // algo que ya esta pasando.
        //
        // El dinero es el caso contrario y por eso si entra en esa lista.
        // Postgres lo manda como texto justo para que el double de JavaScript
        // no le redondee los centavos, y aqui se convierte a NumberDecimal. Un
        // promedio y un conteo no cargan plata, asi que no necesitan ese
        // cuidado y si necesitan comparar como numero.
        //
        // OJO CON EL TIPO BSON, porque no es el que uno supone. mongosh escribe
        // un numero de JavaScript segun su VALOR y no segun su significado: un
        // valor con parte decimal como 4.67 se guarda como double, y un valor
        // entero como 5 o como 0 se guarda como int32. Y el promedio de una
        // nota de 1 a 5 sale entero unas veces y con decimales otras, asi que
        // este campo queda REPARTIDO entre los dos tipos dentro de la misma
        // coleccion, con un reparto que se mueve solo cada vez que alguien
        // escribe una resena.
        //
        // Cuantos hay de cada tipo NO se escribe aqui, porque cambia sin avisar
        // y un numero a mano se queda mintiendo. Se cuenta cuando haga falta:
        //
        //   db.productos.countDocuments({resenas_promedio: {$type: "int"}})
        //   db.productos.countDocuments({resenas_promedio: {$type: "double"}})
        //
        // Se deja asi A PROPOSITO, y la alternativa se probo y es PEOR.
        // Envolver el valor en new Double() parece lo correcto y rompe el campo
        // entero. El motivo es mecanico y no depende de los datos: para
        // JavaScript new Double(4.67) es un objeto, y aDecimal recorre el
        // documento reconstruyendo campo por campo todo lo que sea objeto y no
        // sea Date. Asi que lo desarma y lo vuelve a montar como un objeto
        // plano {value: 4.67}, que ya no tiene tipo BSON numerico ninguno. Con
        // eso TODOS los productos quedan con tipo "object" y el $gte del
        // catalogo deja de encontrar absolutamente nada, sin un solo error.
        //
        // Que el tipo este repartido NO afecta a lo que este campo tiene que
        // hacer: Mongo compara entre tipos numericos, asi que un $gte de 4
        // encuentra igual el int 5 y el double 4.67, y el $sort los ordena
        // juntos. Lo unico que hay que no hacer nunca es preguntar por el tipo:
        // un {$type: "double"} sobre este campo se dejaria fuera la mayoria de
        // los productos.
        //
        // resenas_total es siempre int, y ahi si es lo correcto: es un conteo,
        // y un conteo con parte decimal no significa nada.
        resenas_promedio: producto.resenas_promedio,
        resenas_total:    producto.resenas_total,

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
const CAMPOS_DECIMALES = ['precio', 'precio_tienda', 'precio_desde'];

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
if (escrituraCategorias.length > 0) db.categorias.bulkWrite(escrituraCategorias);
if (escrituraEventos.length > 0)    db.productos_eventos.bulkWrite(escrituraEventos);

// Un upsert actualiza y agrega, pero NO borra: un documento que ya no existe
// en PostgreSQL se quedaria aqui para siempre, y las cuentas seguirian
// cuadrando porque nadie las mira. Ya paso una vez con 47 productos fantasma.
//
// Solo se barren los documentos cuyo _id viene del relacional. Un producto que
// nacio en Mongo (publicado desde el panel) no tiene fila alla y no se toca.
const idsCategorias = categorias.map(c => c.id_categoria);

const catBorradas = db.categorias.deleteMany({
    _id: { $nin: idsCategorias, $lte: Math.max(0, ...idsCategorias) }
});

print('productos   ' + productos.length);
print('categorias  ' + categorias.length + (catBorradas.deletedCount ? '  (' + catBorradas.deletedCount + ' borradas)' : ''));
print('eventos     ' + escrituraEventos.length);
if (sinHistorial > 0) {
    print('AVISO: ' + sinHistorial + ' productos sin ninguna fila de historial: no se pueden reconstruir');
}
