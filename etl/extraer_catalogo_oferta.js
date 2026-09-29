// extraer_catalogo_oferta.js
// Saca de MongoDB lo que la oferta copia del catalogo (migracion 029) y lo deja
// como una sola llamada a copiar_catalogo_a_oferta(), lista para psql.
//
// Corre dentro de mesh-mongo con mongosh, desde el paso 7e de arrancar.ps1.
// Escribe /tmp/mesh-catalogo-oferta.sql; arrancar.ps1 lo copia a mesh-postgres
// y lo corre ahi.
//
// POR QUE UN ARCHIVO SQL Y NO UN JSON
//
// PostgreSQL no puede leer MongoDB, asi que alguien tiene que llevar los datos
// de un lado al otro. Mandarlos por la tuberia de PowerShell 5.1 les pega el
// BOM y cambia la codificacion de los nombres con tilde (ver Comando-Mongo en
// arrancar.ps1). Un archivo que se copia con docker cp llega byte por byte.
//
// El arreglo va entre comillas de dolar ($catalogo$ ... $catalogo$), asi que
// ni las comillas simples ni las barras de un nombre necesitan escaparse.
//
// VAN TODAS LAS VARIANTES, no solo las que tienen oferta. Mongo no sabe cuales
// tienen oferta y la funcion ignora las que no. Son unos cientos de KB.
//
// VA TAMBIEN LO QUE NO SE VE (borradores, inactivos, variantes apagadas). Una
// oferta sobre un producto que se apago tiene que enterarse de que se apago:
// si solo mandaramos lo activo, su copia se quedaria diciendo que se puede
// comprar.

const RUTA_SALIDA = '/tmp/mesh-catalogo-oferta.sql';
const MARCA = '$catalogo$';

const entradas = [];
let productos = 0;

db.productos.find(
    {},
    {
        _id: 1,
        nombre: 1,
        estado: 1,
        'variantes.id_producto_variante': 1,
        'variantes.nombre_variante': 1,
        'variantes.estado': 1,
        'variantes.imagenes': 1
    }
).forEach(function (producto) {
    productos++;
    (producto.variantes || []).forEach(function (variante) {
        const imagenes = variante.imagenes || [];
        entradas.push({
            id_producto: producto._id,
            id_producto_variante: variante.id_producto_variante,
            nombre_producto: producto.nombre,
            nombre_variante: variante.nombre_variante,
            imagen: imagenes.length > 0 ? imagenes[0] : null,
            producto_visible: producto.estado === 'activo',
            variante_activa: variante.estado === 'activa'
        });
    });
});

const json = JSON.stringify(entradas);
if (json.indexOf(MARCA) !== -1) {
    // No deberia pasar nunca, pero si un nombre trajera la marca cerraria la
    // cadena antes de tiempo y psql correria el resto como SQL.
    print('ERROR: un nombre del catalogo contiene ' + MARCA);
    quit(1);
}

require('fs').writeFileSync(
    RUTA_SALIDA,
    'SELECT copiar_catalogo_a_oferta(' + MARCA + json + MARCA + '::jsonb);\n',
    'utf8'
);

print(productos + ' ' + entradas.length);
