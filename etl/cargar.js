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
// QUIEN MANDA DEPENDE DE DONDE SE EDITO EL PRODUCTO
//
// Hasta el 2026-09-18 esta cabecera decia "el ETL es el unico dueno de estas
// colecciones, PostgreSQL manda". Ya no es cierto, y cargar.js dejo de
// comportarse como si lo fuera. El backend edita el catalogo SOLO en Mongo
// (PATCH /vendedor/productos/:id, un updateOne sobre db.productos) y anota cada
// edicion como un evento nuevo en productos_eventos, con el siguiente numero.
// No escribe nada en las tablas de PostgreSQL. O sea que en cuanto alguien edita
// un producto, la fila relacional queda vieja y el documento de Mongo pasa a ser
// el que dice la verdad.
//
// Con el replaceOne de antes, la siguiente corrida de este archivo:
//
//   - devolvia el nombre, la descripcion, el estado y las variantes a lo que dice
//     PostgreSQL, o sea DESHACIA la edicion;
//   - borraba los eventos de esa edicion (el deleteMany de abajo, con numero >
//     eventos.length), y con ellos la reconstruccion del producto a una fecha;
//   - se llevaba caracteristicas_personalizadas, que el ETL no conoce;
//   - se llevaba pendiente_busqueda, y el buscador ya no se enteraba del cambio.
//
// Medido el 2026-09-18 sobre la base viva: 16 eventos de modificacion repartidos
// en 10 productos, seis de ellos con fila en PostgreSQL. Esos seis eran justo los
// que la corrida siguiente iba a pisar.
//
// LA REGLA. Un producto cuyo historial en Mongo llega mas lejos que el que
// deriva PostgreSQL (un evento con numero mayor que los que el ETL arma) fue
// editado desde la aplicacion. Ese producto NO se reemplaza:
//
//   - se refrescan solo los agregados que si vienen de las ofertas (los cinco,
//     tambien dentro de cada variante que ya existia);
//   - no se toca ningun evento ajeno;
//   - se cuenta y se dice al final.
//
// Los demas siguen como siempre: el documento se deriva entero de PostgreSQL. Si
// un dia el historial relacional ENCOGE (una fila mal fechada que se corrige), sus
// eventos sobrantes se ven iguales a una edicion del backend y el producto cae en
// la rama conservadora. Se acepta a proposito: el error va hacia conservar de mas
// y no hacia borrar.
//
// Y pendiente_busqueda. Cuando el ETL cambia algo que el buscador indexa (nombre,
// descripcion, estado, categoria, precios, stock, nota, variantes), marca el
// documento con `pendiente_busqueda: true`, la misma bandera que pone el backend,
// y el worker BuscadorSyncService lo copia a Elasticsearch solo. Antes el ETL
// dejaba el indice viejo hasta que alguien corriera etl/cargar_busqueda.sh.

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
const idsEtl = productos.map(p => p.id_producto);

// Lo que YA hay en Mongo de estos productos, para decidir antes de escribir.
// Dos lecturas en bloque y no una por producto: son mil consultas de menos.
const existentes = new Map();
db.productos.find({ _id: { $in: idsEtl } }).forEach(d => existentes.set(d._id, d));

const ultimoEvento = new Map();
db.productos_eventos.aggregate([
    { $match: { id_producto: { $in: idsEtl } } },
    { $group: { _id: '$id_producto', ultimo: { $max: '$numero' } } }
]).forEach(g => ultimoEvento.set(g._id, g.ultimo));

// Los cinco agregados que viajan de las ofertas, en la raiz y en cada variante.
const AGREGADOS = ['precio_tienda', 'precio_desde', 'stock_tienda', 'stock_total', 'total_ofertas'];

// String() y no ===: un NumberDecimal es un objeto y dos iguales no son ===.
// Las dos caras (lo que hay y lo que se va a escribir) pasan por la misma
// funcion, asi que da igual como se imprima.
const igualesAgregados = (a, b) => AGREGADOS.every(c => String(a[c]) === String(b[c]));

// Lo que el buscador indexa (elastic/001_indice.json). Si esta firma cambia, el
// indice de Elasticsearch quedo viejo.
function firmaBusqueda(d) {
    const c = d.categoria || {};
    return JSON.stringify([
        d.nombre, d.descripcion, d.estado,
        [c.id_categoria, c.nombre, c.categoria_padre],
        String(d.precio_desde), String(d.precio_tienda),
        d.stock_total, d.total_ofertas, d.resenas_promedio, d.resenas_total,
        (d.variantes || []).map(v => [v.nombre_variante, v.descripcion])
    ]);
}

const escrituraProductos = [];
const escrituraEventos = [];
let sinHistorial = 0;
let editadosEnMongo = 0;
let marcadosParaBuscador = 0;

for (const producto of productos) {
    const doc = aDecimal(documentoDe(producto));
    const eventos = eventosDe(producto);
    const previo = existentes.get(doc._id);

    // Un evento con numero mayor que los que arma el ETL no salio de PostgreSQL.
    const editadoEnMongo = previo !== undefined &&
        (ultimoEvento.get(doc._id) || 0) > eventos.length;

    if (editadoEnMongo) {
        editadosEnMongo++;

        // Solo los agregados. Cada variante se busca por su id: una que el
        // vendedor agrego o quito desde el panel no tiene pareja y no se toca.
        const conjunto = {};
        const filtros = [];
        let cambio = !igualesAgregados(previo, doc);
        for (const c of AGREGADOS) conjunto[c] = doc[c];

        (doc.variantes || []).forEach(function (v, i) {
            const enMongo = (previo.variantes || [])
                .find(x => x.id_producto_variante === v.id_producto_variante);
            if (!enMongo) return;
            const marcador = 'v' + i;
            for (const c of AGREGADOS) conjunto['variantes.$[' + marcador + '].' + c] = v[c];
            filtros.push({ [marcador + '.id_producto_variante']: v.id_producto_variante });
            if (!igualesAgregados(enMongo, v)) cambio = true;
        });

        if (cambio) {
            conjunto.pendiente_busqueda = true;
            if (previo.pendiente_busqueda !== true) marcadosParaBuscador++;
        }

        const operacion = { filter: { _id: doc._id }, update: { $set: conjunto } };
        if (filtros.length > 0) operacion.arrayFilters = filtros;
        escrituraProductos.push({ updateOne: operacion });
    } else {
        // Nuevo, o con algo indexable distinto, o con la bandera ya puesta por el
        // backend y todavia sin copiar: en los tres casos sale marcado. replaceOne
        // se lleva la bandera si no se reescribe, y ese ultimo caso perderia un
        // aviso que el worker aun no ha atendido.
        if (previo === undefined ||
            previo.pendiente_busqueda === true ||
            firmaBusqueda(previo) !== firmaBusqueda(doc)) {
            doc.pendiente_busqueda = true;
            if (previo === undefined || previo.pendiente_busqueda !== true) marcadosParaBuscador++;
        }
        escrituraProductos.push({
            // replaceOne y no updateOne con set: aqui el documento se deriva
            // entero de PostgreSQL, asi que un campo que ya no exista alla
            // tampoco debe quedar aqui.
            replaceOne: { filter: { _id: doc._id }, replacement: doc, upsert: true }
        });
    }

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
    // su _id viejo. NUNCA en un producto editado desde la aplicacion: ahi los
    // que sobran son las ediciones, y son lo unico que no se puede recuperar.
    if (!editadoEnMongo) {
        db.productos_eventos.deleteMany({
            id_producto: producto.id_producto,
            numero: { $gt: eventos.length }
        });
    }
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
if (editadosEnMongo > 0) {
    print('CONSERVADOS ' + editadosEnMongo + ' productos editados desde la aplicacion: solo se refrescaron sus agregados');
}
print('buscador    ' + marcadosParaBuscador + ' productos marcados para reindexar (pendiente_busqueda)');
if (sinHistorial > 0) {
    print('AVISO: ' + sinHistorial + ' productos sin ninguna fila de historial: no se pueden reconstruir');
}
