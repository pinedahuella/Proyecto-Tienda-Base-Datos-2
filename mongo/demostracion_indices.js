// demostracion_indices.js
// Los indices del catalogo, PROBADOS contra la base viva.
//
// Corre los cuatro pasos que Jose David mando al grupo, mide cada uno con
// explain("executionStats") y, lo que de verdad importa, corre CADA UNO otra
// vez con hint({$natural:1}) -- o sea, obligando a no usar ningun indice --
// para poder ensenar los dos numeros juntos.
//
// Por que la comparacion y no solo el explain
// -------------------------------------------
// Un explain suelto dice "uso el indice catalogo_categoria" y suena a que algo
// bueno paso, pero no dice cuanto. El numero que significa algo es
// totalDocsExamined: cuantos documentos hubo que abrir para devolver los que
// se pidieron. Sin indice hay que abrirlos TODOS, con indice solo los que
// coinciden, y esa resta es el indice. 001_productos.js dice que los indices
// se eligieron midiendo asi; esto es esa medicion, hecha delante de quien mire.
//
// No escribe nada. Solo lee y mide, asi que se puede correr en medio de una
// demostracion sin miedo.
//
// Se corre solo:   .\mongo\demostracion_indices.ps1
// o a mano:        mongosh ... mesh mongo/demostracion_indices.js

// ------------------------------------------------------------
// Sacar el nombre del indice de un plan
// ------------------------------------------------------------
// El plan es un arbol y el IXSCAN no siempre esta en la raiz: en las consultas
// de aqui va debajo de un FETCH, y en el paso 3 debajo de un SORT que esta
// debajo de un FETCH. Por eso se busca en profundidad en vez de mirar
// winningPlan.inputStage y cruzar los dedos.
function buscarIndice(plan) {
    if (plan == null || typeof plan !== 'object') return null;
    if (plan.indexName) return plan.indexName;
    const hijos = [];
    if (plan.inputStage) hijos.push(plan.inputStage);
    if (plan.inputStages) hijos.push.apply(hijos, plan.inputStages);
    for (let i = 0; i < hijos.length; i++) {
        const encontrado = buscarIndice(hijos[i]);
        if (encontrado) return encontrado;
    }
    return null;
}

/** Todas las etapas del plan, de la raiz hacia abajo. */
function etapas(plan, acumulado) {
    acumulado = acumulado || [];
    if (plan == null || typeof plan !== 'object') return acumulado;
    if (plan.stage) acumulado.push(plan.stage);
    const hijos = [];
    if (plan.inputStage) hijos.push(plan.inputStage);
    if (plan.inputStages) hijos.push.apply(hijos, plan.inputStages);
    for (let i = 0; i < hijos.length; i++) etapas(hijos[i], acumulado);
    return acumulado;
}

/**
 * Lo unico que interesa de un explain, en cinco numeros.
 *
 * `executionTimeMillis` se recoge pero NO se usa para aprobar ni reprobar
 * nada: con 102 documentos las dos versiones dan 0 ms, y colgar la prueba de
 * un cronometro con esa resolucion seria aprobar por casualidad. Lo que se
 * juzga son los documentos examinados, que no dependen de lo ocupada que este
 * la maquina.
 */
function medir(explicacion) {
    const est = explicacion.executionStats || {};
    const plan = (explicacion.queryPlanner || {}).winningPlan || {};
    return {
        devueltos: est.nReturned,
        clavesExaminadas: est.totalKeysExamined,
        documentosExaminados: est.totalDocsExamined,
        milisegundos: est.executionTimeMillis,
        indice: buscarIndice(plan),
        etapas: etapas(plan)
    };
}

/**
 * Lo que la consulta DEVUELVE, tal cual.
 *
 * El `explain` mide el esfuerzo y no ensena ni un documento, asi que una
 * pagina hecha solo con explains demuestra que la consulta fue barata sin
 * demostrar que contesta lo que se pregunto.
 *
 * Se devuelven los documentos COMPLETOS, sin elegir campos ni renombrar nada:
 * es la salida de la misma consulta corrida sin `.explain()`, la misma que
 * saldria pegandola en `mongosh`. Aqui hubo antes una version que armaba una
 * tabla con tres columnas escogidas a mano, y eso ya no es el resultado de la
 * consulta: es un resumen de alguien. Lo que se ensena tiene que poder
 * comprobarse corriendo la consulta al lado.
 */
// El texto se arma AQUI, con JSON.stringify, y no del lado de PowerShell:
// `ConvertTo-Json` de PowerShell 5.1 sangra los arreglos anidados de una forma
// rarisima -- las variantes salian empujadas media pantalla a la derecha -- y
// ademas hay que acordarse de subirle el `-Depth` o los arreglos se convierten
// en "System.Object[]". Con dos espacios se lee igual que en mongosh.
function resultadosDe(cursor) {
    const documentos = cursor.toArray();
    return {
        cuantos: documentos.length,
        texto: JSON.stringify(documentos, null, 2)
    };
}

/**
 * Corre la consulta con indice y sin el, y devuelve las dos medidas MAS el
 * explain entero de cada una.
 *
 * El explain crudo va completo y sin tocar. Los cinco numeros que saca
 * `medir()` sirven para las barras y las comprobaciones, pero son una lectura
 * MIA: quien revisa esto tiene que poder ver la salida de MongoDB tal como
 * sale y comprobar que dice lo que digo que dice. Es la diferencia entre
 * ensenar la prueba y ensenar el resumen de la prueba.
 */
function comparar(hacerConsulta) {
    const conIndice = hacerConsulta().explain('executionStats');
    // $natural obliga a recorrer la coleccion entera: es "como si el indice
    // no existiera", sin tener que borrarlo de verdad en medio de una demo.
    const sinIndice = hacerConsulta().hint({ $natural: 1 }).explain('executionStats');
    return {
        conIndice: medir(conIndice),
        sinIndice: medir(sinIndice),
        explicacionConIndice: JSON.stringify(conIndice, null, 2),
        explicacionSinIndice: JSON.stringify(sinIndice, null, 2)
    };
}

const totalProductos = db.productos.countDocuments({});
const pasos = [];

// ------------------------------------------------------------
// Paso 1 -- cuantos documentos hay
// ------------------------------------------------------------
// No mide ningun indice: es la referencia contra la que se leen los otros
// tres. Sin este numero, "examino 7 documentos" no dice nada -- podrian ser 7
// de 7. Con el, son 7 de 102.
pasos.push({
    numero: 1,
    titulo: 'Cuantos documentos hay en total',
    consulta: 'db.productos.countDocuments({})',
    proposito:
        'La referencia. Los otros tres pasos se leen contra este numero: examinar 7 ' +
        'documentos solo significa algo si se sabe que hay ' + totalProductos + '.',
    esReferencia: true,
    total: totalProductos,
    comprobaciones: [
        {
            nombre: 'La coleccion tiene documentos',
            detalle: 'Un catalogo vacio haria pasar los otros tres pasos examinando cero.',
            pasa: totalProductos > 0,
            medido: totalProductos + ' documentos'
        }
    ]
});

// ------------------------------------------------------------
// Paso 2 -- el indice compuesto, con su orden
// ------------------------------------------------------------
const CATEGORIA = 7;
const filtro2 = { 'categoria.id_categoria': CATEGORIA, estado: 'activo', _id: { $gt: 0 } };
const m2 = comparar(function () {
    return db.productos.find(filtro2).sort({ _id: 1 });
});
const nombreCategoria = (function () {
    const uno = db.productos.findOne({ 'categoria.id_categoria': CATEGORIA }, { categoria: 1 });
    return uno && uno.categoria ? uno.categoria.nombre : 'id ' + CATEGORIA;
})();

pasos.push({
    numero: 2,
    titulo: 'Los productos de una categoria, ordenados',
    consulta:
        'db.productos.find({\n' +
        '  "categoria.id_categoria": ' + CATEGORIA + ',\n' +
        '  estado: "activo",\n' +
        '  _id: { $gt: 0 }\n' +
        '}).sort({ _id: 1 }).explain("executionStats")',
    proposito:
        'La navegacion normal del catalogo, sobre la categoria "' + nombreCategoria + '". ' +
        'El indice catalogo_categoria lleva los tres campos en el orden en que se usan: ' +
        'las dos igualdades primero y el _id al final, que es por donde se ordena. Por eso ' +
        'los resultados salen YA ordenados del indice y no hay que ordenarlos en memoria.',
    indiceEsperado: 'catalogo_categoria',
    total: totalProductos,
    medidas: m2,
    // La consulta EXACTA que devolvio lo de abajo: la misma del paso, sin
    // `.explain()`. Se escribe aparte para que en la pagina se pueda leer y
    // pegar en mongosh a comprobarlo.
    consultaCruda: 'db.productos.find({ "categoria.id_categoria": ' + CATEGORIA + ', estado: "activo", _id: { $gt: 0 } }).sort({ _id: 1 })',
    resultados: resultadosDe(db.productos.find(filtro2).sort({ _id: 1 })),
    comprobaciones: [
        {
            nombre: 'Usa el indice catalogo_categoria',
            detalle: 'Si usara otro, o ninguno, el indice no estaria sirviendo para esta consulta.',
            pasa: m2.conIndice.indice === 'catalogo_categoria',
            medido: 'uso ' + (m2.conIndice.indice || 'ninguno')
        },
        {
            nombre: 'No abre ni un documento de mas',
            detalle:
                'documentosExaminados igual a devueltos: no hubo que descartar nada. ' +
                'Es la senal de que el filtro entero lo resolvio el indice.',
            pasa: m2.conIndice.documentosExaminados === m2.conIndice.devueltos,
            medido: m2.conIndice.documentosExaminados + ' abiertos para ' + m2.conIndice.devueltos + ' devueltos'
        },
        {
            nombre: 'No ordena en memoria',
            detalle:
                'Una etapa SORT significaria que el orden se pago aparte. Aqui el _id va ' +
                'al final del indice justamente para no pagarlo.',
            pasa: m2.conIndice.etapas.indexOf('SORT') === -1,
            medido: m2.conIndice.etapas.join(' > ')
        },
        {
            nombre: 'Sin el indice habria que abrirlos todos',
            detalle: 'La comparacion contra hint({$natural:1}). Esto es lo que ahorra el indice.',
            pasa: m2.sinIndice.documentosExaminados > m2.conIndice.documentosExaminados,
            medido: m2.sinIndice.documentosExaminados + ' sin indice, ' + m2.conIndice.documentosExaminados + ' con el'
        }
    ]
});

// ------------------------------------------------------------
// Paso 3 -- un rango, donde el indice ya no puede ordenar
// ------------------------------------------------------------
const DESDE = 4000;
const filtro3 = { estado: 'activo', precio_desde: { $gte: DESDE } };
const m3 = comparar(function () {
    return db.productos.find(filtro3);
});

pasos.push({
    numero: 3,
    titulo: 'Los productos desde cierto precio',
    consulta:
        'db.productos.find({\n' +
        '  estado: "activo",\n' +
        '  precio_desde: { $gte: ' + DESDE + ' }\n' +
        '}).explain("executionStats")',
    proposito:
        'El filtro del buscador. Va sobre precio_desde, que es lo mas barato que se puede ' +
        'PAGAR, y no sobre precio_tienda, que es lo que se ensena: quien busca "desde Q' +
        DESDE + '" pregunta por lo que puede pagar. Aqui el _id no puede ir al final del ' +
        'indice, porque detras de un RANGO un indice ya no sirve para ordenar.',
    indiceEsperado: 'catalogo_precio',
    total: totalProductos,
    medidas: m3,
    consultaCruda: 'db.productos.find({ estado: "activo", precio_desde: { $gte: ' + DESDE + ' } })',
    resultados: resultadosDe(db.productos.find(filtro3)),
    comprobaciones: [
        {
            nombre: 'Usa el indice catalogo_precio',
            detalle: 'El de la categoria no sirve aqui: no empieza por estado ni lleva el precio.',
            pasa: m3.conIndice.indice === 'catalogo_precio',
            medido: 'uso ' + (m3.conIndice.indice || 'ninguno')
        },
        {
            nombre: 'Lee menos de la mitad del catalogo',
            detalle:
                'Un indice que examina casi todo para devolver casi todo no se gana el puesto: ' +
                'catalogo_disponibilidad se quito de este proyecto por exactamente eso.',
            pasa: m3.conIndice.documentosExaminados < totalProductos / 2,
            medido: m3.conIndice.documentosExaminados + ' de ' + totalProductos
        },
        {
            nombre: 'Sin el indice habria que abrirlos todos',
            detalle: 'La comparacion contra hint({$natural:1}).',
            pasa: m3.sinIndice.documentosExaminados > m3.conIndice.documentosExaminados,
            medido: m3.sinIndice.documentosExaminados + ' sin indice, ' + m3.conIndice.documentosExaminados + ' con el'
        }
    ]
});

// ------------------------------------------------------------
// Paso 4 -- el caso especial: un indice que reduce, y un $or que filtra
// ------------------------------------------------------------
// Este es el que Jose David explico en el grupo: el primer filtro deja N
// documentos de T, y el $or -- que NINGUN indice puede resolver, porque va
// contra arrays embebidos de las variantes -- se aplica solo sobre esos N.
//
// Ojo con un detalle que solo se ve mirando los datos: "Memoria RAM" existe
// unicamente dentro de las VARIANTES, no en las caracteristicas del producto.
// Las dos primeras ramas del $or no encuentran nada nunca; estan escritas
// igual porque otras caracteristicas (Marca, Garantia) si viven arriba, y la
// consulta busca en los dos sitios sin tener que saber en cual esta cada una.
const RASGO = 'Memoria RAM';
const VALOR = 8;
const filtro4 = {
    'categoria.id_categoria': CATEGORIA,
    estado: 'activo',
    $or: [
        { caracteristicas_adicionales: { $elemMatch: { nombre: RASGO, valor: VALOR } } },
        { caracteristicas_personalizadas: { $elemMatch: { nombre: RASGO, valor: VALOR } } },
        { 'variantes.caracteristicas_adicionales': { $elemMatch: { nombre: RASGO, valor: VALOR } } },
        { 'variantes.caracteristicas_personalizadas': { $elemMatch: { nombre: RASGO, valor: VALOR } } }
    ]
};
const m4 = comparar(function () {
    return db.productos.find(filtro4);
});
const enLaCategoria = db.productos.countDocuments({
    'categoria.id_categoria': CATEGORIA,
    estado: 'activo'
});

pasos.push({
    numero: 4,
    titulo: 'Filtrar por una caracteristica, dentro de una categoria',
    consulta:
        'db.productos.find({\n' +
        '  "categoria.id_categoria": ' + CATEGORIA + ',\n' +
        '  estado: "activo",\n' +
        '  $or: [\n' +
        '    { caracteristicas_adicionales:              { $elemMatch: { nombre: "' + RASGO + '", valor: ' + VALOR + ' } } },\n' +
        '    { caracteristicas_personalizadas:           { $elemMatch: { nombre: "' + RASGO + '", valor: ' + VALOR + ' } } },\n' +
        '    { "variantes.caracteristicas_adicionales":    { $elemMatch: { nombre: "' + RASGO + '", valor: ' + VALOR + ' } } },\n' +
        '    { "variantes.caracteristicas_personalizadas": { $elemMatch: { nombre: "' + RASGO + '", valor: ' + VALOR + ' } } }\n' +
        '  ]\n' +
        '}).explain("executionStats")',
    proposito:
        'El caso especial. Ningun indice puede resolver ese $or: son cuatro arrays embebidos ' +
        'y cuatro $elemMatch. Lo que hace el indice es OTRA cosa, y es la que vale: reduce el ' +
        'problema de ' + totalProductos + ' documentos a los ' + enLaCategoria + ' de la ' +
        'categoria, y el $or se evalua solo sobre esos. El indice no contesta la pregunta, ' +
        'la hace pequena.',
    indiceEsperado: 'catalogo_categoria',
    total: totalProductos,
    medidas: m4,
    consultaCruda: 'db.productos.find({ "categoria.id_categoria": ' + CATEGORIA + ', estado: "activo", $or: [ ...los cuatro $elemMatch de arriba... ] })',
    resultados: resultadosDe(db.productos.find(filtro4)),
    comprobaciones: [
        {
            nombre: 'El primer filtro lo resuelve el indice',
            detalle: 'Aunque el $or no pueda indexarse, la parte de igualdad si.',
            pasa: m4.conIndice.indice === 'catalogo_categoria',
            medido: 'uso ' + (m4.conIndice.indice || 'ninguno')
        },
        {
            nombre: 'El $or se evalua solo sobre la categoria',
            detalle:
                'documentosExaminados igual a los ' + enLaCategoria + ' de la categoria, no a ' +
                'los ' + totalProductos + ' del catalogo: esa es la reduccion, y es todo lo ' +
                'que el indice puede hacer aqui.',
            pasa: m4.conIndice.documentosExaminados === enLaCategoria,
            medido: m4.conIndice.documentosExaminados + ' examinados, ' + enLaCategoria + ' en la categoria'
        },
        {
            nombre: 'Devuelve menos de los que examina',
            detalle:
                'Si devolviera todos los que examina, el $or no estaria filtrando nada y la ' +
                'consulta estaria mintiendo. ' + m4.conIndice.devueltos + ' de ' +
                m4.conIndice.documentosExaminados + ' cumplen el ' + RASGO + ' = ' + VALOR + '.',
            pasa: m4.conIndice.devueltos < m4.conIndice.documentosExaminados,
            medido: m4.conIndice.devueltos + ' devueltos de ' + m4.conIndice.documentosExaminados + ' examinados'
        },
        {
            nombre: 'Sin el indice se examina el catalogo entero',
            detalle: 'Sin nada que reduzca, el $or se evalua sobre los ' + totalProductos + '.',
            pasa: m4.sinIndice.documentosExaminados > m4.conIndice.documentosExaminados,
            medido: m4.sinIndice.documentosExaminados + ' sin indice, ' + m4.conIndice.documentosExaminados + ' con el'
        }
    ]
});

// ------------------------------------------------------------
// La salida
// ------------------------------------------------------------
// Una sola linea de JSON detras de un marcador, para que el generador del HTML
// la encuentre sin tener que interpretar el resto de lo que imprima mongosh.
const salida = {
    generado: new Date().toISOString(),
    base: db.getName(),
    totalProductos: totalProductos,
    indices: db.productos.getIndexes().map(function (i) {
        return { nombre: i.name, llave: JSON.stringify(i.key) };
    }),
    pasos: pasos
};

print('===DEMOSTRACION_JSON===');
print(JSON.stringify(salida));
