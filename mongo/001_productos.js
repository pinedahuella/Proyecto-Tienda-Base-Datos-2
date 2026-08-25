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
//   precio_tienda, precio_desde, stock_tienda, stock_total y total_ofertas.
//   Los de stock van SUMADOS sobre todas sus variantes, y cuentan solo ofertas
//   activas.
//
//   precio_tienda es el que se ENSENA (regla del profesor) y precio_desde el
//   mas barato que se puede PAGAR. Son dos porque contestan dos preguntas: la
//   tarjeta usa el primero y el filtro del buscador el segundo.
//
// LAS OFERTAS NO ESTAN AQUI, y es LA decision de modelado de esta entrega.
//
// Se quedan en PostgreSQL. El motivo no es el tamano: es la tasa de cambio.
// Precio, stock y estado cambian en cada venta, y copiarlos a la base
// documental obligaria a sostenerlos al dia en dos bases a la vez -- justo el
// riesgo de inconsistencia que el proyecto quiere evitar. Ademas Mongo
// reescribe el documento entero en cada actualizacion, asi que embeberlas
// dentro del producto haria que comprar una camisa reescribiera su catalogo
// completo, y dos vendedores vendiendo a la vez pelearian por el mismo
// documento: lo contrario de lo que pide la Entrega 2.
//
// Lo que si viaja son cuatro numeros AGREGADOS dentro del producto
// (precio_tienda, stock_tienda, stock_total, total_ofertas), para que la LISTA
// del catalogo se pinte sin salir de aqui. La ficha, que necesita las ofertas
// de verdad, las pide a PostgreSQL.
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

const COLECCIONES = ['productos', 'productos_eventos', 'categorias'];

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

// Los dos indices del catalogo salieron de MEDIR, no de suponer. Se probaron
// tres y solo dos se ganaron el puesto: un indice que nunca se usa no es
// gratis, cuesta en cada escritura.
//
//   catalogo_categoria      examina 3 documentos para devolver 3
//   catalogo_precio         examina 21 claves en vez de 34
//   catalogo_disponibilidad examinaba 34 para devolver 33  <- se quito

// "los productos de esta categoria, sin los ocultos, ordenados por id". Es la
// navegacion normal del catalogo.
//
// El orden importa: id_categoria va PRIMERO porque es igualdad; estado
// despues, que se filtra siempre pero con $nin y no descarta casi nada; y _id
// al final, que es por donde se ordena y asi sale ordenado del indice, sin
// ordenar en memoria.
//
// Va sobre categoria.id_categoria y NO sobre categoria.nombre: el backend
// filtra por id. Un indice sobre el campo equivocado se ve igual de bien en la
// lista de indices y no lo usa nadie.
db.productos.createIndex(
    { 'categoria.id_categoria': 1, estado: 1, _id: 1 },
    { name: 'catalogo_categoria' }
);

// "los productos entre tal y tal precio". Va sobre precio_desde, que es el mas
// barato que se puede pagar, y no sobre precio_tienda: quien busca "hasta
// Q4000" quiere lo que puede pagar con eso, aunque la tarjeta ensene otro
// numero.
//
// Aqui el _id no puede ir al final: detras de un rango, un indice ya no sirve
// para ordenar. Se paga un orden en memoria a cambio de leer solo lo que
// coincide, y medido conviene.
db.productos.createIndex(
    { estado: 1, precio_desde: 1 },
    { name: 'catalogo_precio' }
);

// Los indices de versiones anteriores, si quedaron, se van
['catalogo_categoria_estado', 'catalogo_categoria_estado_stock', 'catalogo_disponibilidad']
    .forEach(function (viejo) {
        if (db.productos.getIndexes().some(function (i) { return i.name === viejo; })) {
            db.productos.dropIndex(viejo);
            print('indice ' + viejo + ' eliminado');
        }
    });

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

// Si quedo de una version anterior, se va: las ofertas viven en PostgreSQL y
// una copia vieja aqui es peor que no tenerla, porque parece al dia.
if (db.getCollectionNames().indexOf('ofertas') !== -1) {
    db.ofertas.drop();
    print('ofertas: coleccion vieja eliminada, ahora viven solo en PostgreSQL');
}

print('indices al dia');
