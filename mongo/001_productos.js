// 001_productos.js
// Las colecciones del catalogo y sus indices.
//
// Este script las crea vacias y les pone los indices. Quien las llena es el
// ETL de etl/, que lee de PostgreSQL y escribe aqui. Ver etl/README.md.
//
// productos
//   Un documento por producto, con la categoria, las variantes, sus imagenes y
//   sus caracteristicas embebidas. El _id es el id_producto de PostgreSQL, no
//   uno que genere Mongo: asi volver a correr el ETL actualiza en vez de
//   duplicar, y la traza entre las dos bases es directa.
//
//   NO trae vendedor, ni precio, ni stock por vendedor: al volverse
//   multi-vendedor dejaron de ser del producto. Solo trae cuatro numeros
//   calculados, que son los que la LISTA del catalogo necesita en cada tarjeta:
//   precio_tienda, stock_tienda, stock_total y total_ofertas. Los de stock van
//   SUMADOS sobre todas sus variantes, y cuentan solo ofertas activas.
//
// ofertas
//   Un documento por oferta: quien vende esa variante, a como y con cuantas
//   unidades. El _id es el id_oferta de PostgreSQL.
//
//   Van aparte y no embebidas dentro del producto, y es LA decision de modelado
//   de esta entrega. El motivo no es el tamano: es la tasa de cambio. El stock
//   cambia en cada venta y Mongo reescribe el documento entero en cada
//   actualizacion, asi que embeberlas haria que comprar una camisa reescribiera
//   el documento completo de la camisa, con sus variantes, sus caracteristicas
//   y sus imagenes. Y dos vendedores vendiendo a la vez pelearian por el mismo
//   documento, que es justo lo contrario de lo que pide la Entrega 2.
//
// productos_eventos
//   El historial. Un documento por evento, y los eventos solo se agregan:
//   ninguno se edita ni se borra.
//     el mas viejo    operacion "creacion",     lleva "datos" con todo
//     los siguientes  operacion "modificacion", llevan "cambios" con solo lo
//                     que cambio respecto del estado anterior
//   Reconstruir un producto a una fecha es aplicar la creacion y despues TODAS
//   las modificaciones en orden hasta esa fecha. Quedarse con la ultima pierde
//   los cambios intermedios que tocaron otros campos.
//
// categorias
//   La paleta: que caracteristicas ofrece cada categoria, con su tipo y su
//   unidad. Es lo que arma el formulario de publicar. No lleva valores.
//
// En PostgreSQL el mismo historial se guarda como snapshot, que es lo natural
// en SQL. La traduccion de snapshot a eventos la hace el ETL.

const COLECCIONES = ['productos', 'ofertas', 'productos_eventos', 'categorias'];

// createCollection revienta si la coleccion ya existe, y esto se corre en cada
// arranque. Por eso se pregunta primero.
const existentes = db.getCollectionNames();

COLECCIONES.forEach(function (nombre) {
    if (existentes.indexOf(nombre) === -1) {
        db.createCollection(nombre);
        print(nombre + ' creada');
    } else {
        print(nombre + ' ya existia');
    }
});


// ============================================================
// Los indices
// ============================================================
// createIndex es idempotente: si el indice ya existe con la misma definicion,
// no hace nada. Por eso se puede correr en cada arranque.
//
// Cada uno responde a una consulta concreta de la aplicacion, no a la idea
// general de que "conviene tener indices".

// El catalogo se navega filtrando por categoria, escondiendo lo que no esta
// activo y, muy seguido, dejando solo lo que tiene existencias. Es un indice
// COMPUESTO y en ese orden porque el estado se filtra siempre, la categoria a
// veces, y stock_total va al final por ser un rango: un campo de rango detras
// de otro deja de servir para filtrar dentro del indice.
//
// Si existe la version anterior de este indice (sin stock_total), se cambia.
// createIndex con el mismo nombre y otras llaves da IndexOptionsConflict.
if (db.productos.getIndexes().some(function (i) { return i.name === 'catalogo_categoria_estado'; })) {
    db.productos.dropIndex('catalogo_categoria_estado');
}

db.productos.createIndex(
    { 'categoria.nombre': 1, estado: 1, stock_total: 1 },
    { name: 'catalogo_categoria_estado_stock' }
);

// "las ofertas de esta variante, de la mas barata a la mas cara". Es la
// consulta de la ficha del producto, y con este indice sale ordenada sin
// ordenar nada: el indice ya viene en ese orden.
db.ofertas.createIndex(
    { id_producto_variante: 1, precio: 1 },
    { name: 'ofertas_por_variante_precio' }
);

// "todas las ofertas de este producto", para la ficha completa
db.ofertas.createIndex(
    { id_producto: 1, estado: 1 },
    { name: 'ofertas_por_producto_estado' }
);

// "las ofertas de este vendedor": su panel
db.ofertas.createIndex(
    { 'vendedor.id_usuario': 1 },
    { name: 'ofertas_por_vendedor' }
);

// "el estado de este producto el 3 de marzo": se leen sus eventos hasta esa
// fecha, en orden. El compuesto sirve para las dos cosas a la vez, filtrar por
// producto y recorrer por fecha.
db.productos_eventos.createIndex(
    { id_producto: 1, fecha: 1 },
    { name: 'eventos_por_producto_fecha' }
);

// El formulario de publicar busca la categoria por nombre
db.categorias.createIndex(
    { nombre: 1 },
    { name: 'categorias_por_nombre' }
);

print('indices al dia');
