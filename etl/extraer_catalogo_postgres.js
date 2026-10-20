// extraer_catalogo_postgres.js
// Saca de MongoDB lo que PostgreSQL copia del catalogo (migracion 029,
// producto_catalogo y variante_catalogo) y lo deja como un archivo SQL listo
// para psql.
//
// Corre dentro de mesh-mongo con mongosh, desde el paso 7e de arrancar.ps1.
// Escribe /tmp/mesh-catalogo-postgres.sql; arrancar.ps1 lo copia a
// mesh-postgres y lo corre ahi. Hace lo mismo que el
// catalogo-en-postgres-sembrar.cjs de Jose David, pero sin pedirle node ni el
// .env del backend a la maquina: todo pasa dentro de los contenedores.
//
// POR QUE UN ARCHIVO SQL Y NO UN JSON
//
// PostgreSQL no puede leer MongoDB, asi que alguien tiene que llevar los datos
// de un lado al otro. Mandarlos por la tuberia de PowerShell 5.1 les pega el
// BOM y cambia la codificacion de los nombres con tilde (ver Comando-Mongo en
// arrancar.ps1). Un archivo que se copia con docker cp llega byte por byte.
//
// El catalogo va entre comillas de dolar ($catalogo$ ... $catalogo$), asi que
// ni las comillas simples ni las barras de un nombre necesitan escaparse.
//
// SOLO ESCRIBE LO QUE CAMBIO. Cada UPSERT lleva un WHERE ... IS DISTINCT FROM,
// asi que en un arranque normal no toca ninguna fila y fecha_actualizacion
// sigue diciendo cuando cambio de verdad. Imprime cuantos productos y cuantas
// variantes escribio.
//
// VA TODO, tambien lo que no se ve (borradores, inactivos, variantes apagadas).
// Una oferta sobre una variante que se apago tiene que enterarse de que se
// apago.

const RUTA_SALIDA = '/tmp/mesh-catalogo-postgres.sql';
const MARCA = '$catalogo$';

const productos = [];
const variantes = [];

db.productos.find(
    {},
    {
        _id: 1,
        nombre: 1,
        estado: 1,
        descripcion: 1,
        'categoria.id_categoria': 1,
        fecha_creacion: 1,
        'variantes.id_producto_variante': 1,
        'variantes.nombre_variante': 1,
        'variantes.estado': 1,
        'variantes.imagenes': 1
    }
).forEach(function (producto) {
    // Desde la 047 tambien estado, categoria, descripcion y fecha de creacion:
    // lo que el respaldo del backend necesita para ensenar el producto sin Mongo.
    productos.push({
        id: producto._id,
        nombre: producto.nombre,
        estado: producto.estado,
        descripcion: producto.descripcion == null ? null : producto.descripcion,
        id_categoria: producto.categoria ? producto.categoria.id_categoria : null,
        fecha_creacion: producto.fecha_creacion || null
    });
    (producto.variantes || []).forEach(function (variante) {
        const imagenes = variante.imagenes || [];
        variantes.push({
            id: producto._id,
            id_variante: variante.id_producto_variante,
            nombre: variante.nombre_variante,
            estado: variante.estado,
            imagen: imagenes.length > 0 ? imagenes[0] : null
        });
    });
});

const json = JSON.stringify({ productos: productos, variantes: variantes });
if (json.indexOf(MARCA) !== -1) {
    // No deberia pasar nunca, pero si un nombre trajera la marca cerraria la
    // cadena antes de tiempo y psql correria el resto como SQL.
    print('ERROR: un nombre del catalogo contiene ' + MARCA);
    quit(1);
}

const sql = [
    'BEGIN;',
    'CREATE TEMP TABLE catalogo_mongo ON COMMIT DROP AS SELECT ' + MARCA + json + MARCA + '::jsonb AS j;',
    '',
    'WITH escritos AS (',
    '    INSERT INTO producto_catalogo',
    '           (id_producto_mongo, nombre, estado, descripcion, id_categoria, fecha_creacion)',
    "    SELECT (p->>'id')::bigint, p->>'nombre', p->>'estado', p->>'descripcion',",
    "           (p->>'id_categoria')::bigint, (p->>'fecha_creacion')::timestamptz",
    "      FROM catalogo_mongo, jsonb_array_elements(j->'productos') p",
    '    ON CONFLICT (id_producto_mongo) DO UPDATE',
    '       SET nombre = EXCLUDED.nombre, estado = EXCLUDED.estado,',
    '           descripcion = EXCLUDED.descripcion, id_categoria = EXCLUDED.id_categoria,',
    '           fecha_creacion = EXCLUDED.fecha_creacion, fecha_actualizacion = now()',
    '     WHERE (producto_catalogo.nombre, producto_catalogo.estado, producto_catalogo.descripcion,',
    '            producto_catalogo.id_categoria, producto_catalogo.fecha_creacion)',
    '           IS DISTINCT FROM (EXCLUDED.nombre, EXCLUDED.estado, EXCLUDED.descripcion,',
    '                             EXCLUDED.id_categoria, EXCLUDED.fecha_creacion)',
    '    RETURNING 1)',
    'SELECT count(*) FROM escritos;',
    '',
    'WITH escritas AS (',
    '    INSERT INTO variante_catalogo',
    '           (id_producto_mongo, id_producto_variante_mongo, nombre_variante, estado, imagen)',
    "    SELECT (v->>'id')::bigint, (v->>'id_variante')::bigint, v->>'nombre', v->>'estado', v->>'imagen'",
    "      FROM catalogo_mongo, jsonb_array_elements(j->'variantes') v",
    '    ON CONFLICT (id_producto_mongo, id_producto_variante_mongo) DO UPDATE',
    '       SET nombre_variante = EXCLUDED.nombre_variante, estado = EXCLUDED.estado,',
    '           imagen = EXCLUDED.imagen, fecha_actualizacion = now()',
    '     WHERE (variante_catalogo.nombre_variante, variante_catalogo.estado, variante_catalogo.imagen)',
    '           IS DISTINCT FROM (EXCLUDED.nombre_variante, EXCLUDED.estado, EXCLUDED.imagen)',
    '    RETURNING 1)',
    'SELECT count(*) FROM escritas;',
    '',
    'COMMIT;',
    ''
].join('\n');

require('fs').writeFileSync(RUTA_SALIDA, sql, 'utf8');

print(productos.length + ' ' + variantes.length);
