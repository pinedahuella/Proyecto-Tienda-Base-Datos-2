// 001_productos.js
// Las colecciones del catalogo.
//
// Este script solo las crea vacias. Quien las llena es el ETL de etl/, que lee
// los productos de PostgreSQL y los escribe aqui. Ver etl/README.md.
//
// productos
//   Un documento por producto, con la categoria, las variantes, sus imagenes
//   y el vendedor embebidos. El _id es el id_producto de PostgreSQL, no uno
//   que genere Mongo: asi volver a correr el ETL actualiza en vez de duplicar,
//   y la traza entre las dos bases es directa.
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
// En PostgreSQL el mismo historial se guarda como snapshot, que es lo natural
// en SQL. La traduccion de snapshot a eventos la hace el ETL.

const COLECCIONES = ['productos', 'productos_eventos'];

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
