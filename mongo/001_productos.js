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
//   multi-vendedor dejaron de ser del producto. Solo trae cinco numeros
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
// Lo que si viaja son cinco numeros AGREGADOS dentro del producto
// (precio_tienda, stock_tienda, stock_total, total_ofertas), para que la LISTA
// del catalogo se pinte sin salir de aqui. La ficha, que necesita las ofertas
// de verdad, las pide a PostgreSQL.
//
// productos_eventos
//   El historial. Un documento por evento.
//
//   La APLICACION solo agrega: `POST /vendedor/productos` escribe el evento 1
//   y cada `PATCH` escribe el siguiente, y ninguno de los dos toca ni borra
//   los que ya estaban. Eso es lo que hace que reconstruir por fecha
//   signifique algo.
//
//   El ETL es otra cosa, y conviene no confundirlos: los eventos que el ETL
//   deriva de PostgreSQL son SUYOS y los rehace enteros en cada corrida
//   (`replaceOne` del 1 al n, y `deleteMany` de lo que pase de n, en
//   etl/cargar.js). No es que "edite el historial": es que ese tramo no es un
//   registro, es una traduccion -- si la fila de PostgreSQL de la que sale se
//   corrige, su evento tiene que corregirse con ella.
//
//   La consecuencia practica, que si hay que saber: si la tienda edita desde
//   el panel un producto que vino del ETL, ese evento nuevo lleva un numero
//   mas alto que los derivados, y una corrida de `arrancar.ps1 -Etl` se lo
//   lleva por delante. Los productos creados desde el panel no corren ese
//   riesgo: viven por encima del tope del ETL y no se tocan.
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
// Medido con explain("executionStats") sobre los 105 productos y los 118
// eventos que hay hoy, comparando cada consulta contra ella misma con
// hint({$natural:1}) -- o sea, contra no tener el indice:
//
//   catalogo_categoria          6 docs y 7 claves, contra 105 sin el
//   catalogo_precio            51 docs y 53 claves, contra 105 sin el
//   eventos_por_producto_fecha  4 docs y 4 claves, contra 118 sin el
//   catalogo_disponibilidad     examinaba casi todo para devolver casi todo  <- se quito

// "los productos de esta categoria, sin los ocultos, ordenados por id". Es la
// navegacion normal del catalogo.
//
// El orden importa: id_categoria va PRIMERO porque es igualdad; estado
// despues, que tambien es igualdad y se filtra siempre; y _id al final, que es
// por donde se ordena y asi sale ordenado del indice, sin ordenar en memoria.
//
// Sobre el estado, dos cosas que conviene tener escritas:
//
// 1. El filtro es una LISTA BLANCA, no una negra. El backend pide
//    `estado: 'activo'` y nada mas (ESTADO_PRODUCTO_VISIBLE). Antes se
//    descartaba con $nin, y este comentario decia eso; cambio, y la diferencia
//    importa: con lista blanca, un estado nuevo queda oculto por defecto en vez
//    de aparecer en el catalogo porque nadie se acordo de excluirlo.
//
// 2. El conjunto de estados crecio a CINCO -- borrador, activo, inactivo,
//    en_revision y rechazado -- desde que un vendedor puede proponer productos
//    (migracion 009). Aqui no hay validador de esquema sobre `estado`, asi que
//    la coleccion no fuerza nada: la lista completa vive en el catalogo
//    `estado_producto` de PostgreSQL, y esto queda anotado para quien lea los
//    indices y se pregunte cuantos valores distintos puede tomar el campo.
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
