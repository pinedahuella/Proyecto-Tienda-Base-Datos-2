// 001_productos.js
// La coleccion productos.
//
// El catalogo vive aqui, no en el relacional. Un solo documento por
// producto, con todo lo suyo embebido:
//
//   {
//     _id,                          lo genera Mongo
//     nombre, descripcion, fecha_creacion,
//     id_usuario,                   el vendedor, que sigue en PostgreSQL
//     estado,                       estado del producto
//     categoria: { nombre, porcentaje_comision, estado },
//     variantes: [
//       { nombre_variante, precio, descripcion, fecha_creacion, estado }
//     ]
//   }
//
// Los estados de producto, de variante y de categoria eran tablas de
// catalogo del modelo relacional. Ya no: son un campo del documento.
//
// El _id de este documento es lo que guardan las tablas de historial que
// se quedaron en PostgreSQL. No hay una llave foranea de verdad entre los
// dos sistemas: la base no la puede exigir, la aplicacion la sostiene.

const NOMBRE = 'productos';

// createCollection revienta si la coleccion ya existe, y este script se
// corre en cada arranque. Por eso se pregunta primero.
if (db.getCollectionNames().indexOf(NOMBRE) === -1) {
    db.createCollection(NOMBRE);
    print('creada');
} else {
    print('ya existia');
}
