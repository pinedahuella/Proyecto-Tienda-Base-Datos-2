// reconstruir.js
// Que decia este producto tal dia.
//
// Se corre dentro de mesh-mongo, igual que cargar.js:
//
//   docker exec -i mesh-mongo sh -c 'cat > /tmp/reconstruir.js' < etl/reconstruir.js
//   docker exec mesh-mongo sh -c 'mongosh --quiet \
//       -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
//       --authenticationDatabase admin "$MONGO_INITDB_DATABASE" \
//       --eval "var producto = 1, corte = \"2026-03-20\"" \
//       --file /tmp/reconstruir.js'
//
// Sin --eval reconstruye el producto 1 al dia de hoy.

const ID    = (typeof producto !== 'undefined') ? producto : 1;
const FECHA = new Date((typeof corte !== 'undefined') ? corte : Date.now());

// ============================================================
// La consulta
// ============================================================
// Reconstruir NO es tomar la creacion y encimarle la ultima modificacion. Cada
// modificacion guarda solo los campos que ella toco: si una cambio el nombre y
// otra la comision, quedarse con la ultima pierde el nombre. Hay que aplicarlas
// todas, en orden, desde la creacion hasta la fecha pedida.
//
// Eso es exactamente lo que hacen estas cinco etapas.
function reconstruir(id, fecha) {
    return db.productos_eventos.aggregate([

        // 1. Los eventos de este producto que ya habian pasado ese dia.
        { $match: { id_producto: id, fecha: { $lte: fecha } } },

        // 2. Del mas viejo al mas nuevo. El orden es lo que hace correcto todo
        //    lo demas. El indice (id_producto, fecha) sirve para las dos
        //    etapas de arriba: la base entra al producto y lee el tramo ya
        //    ordenado, sin ordenar nada en memoria.
        { $sort: { fecha: 1 } },

        // 3. De cada evento solo interesa su contenido: el estado completo si
        //    es la creacion, los campos tocados si es una modificacion.
        { $replaceWith: { $ifNull: ['$datos', '$cambios'] } },

        // 4. Encimarlos en ese orden. mergeObjects toma el valor del ultimo
        //    que traiga el campo, y deja intactos los campos que nadie volvio
        //    a tocar: la creacion pone todo y cada modificacion pisa lo suyo.
        { $group: { _id: null, estado: { $mergeObjects: '$$ROOT' } } },

        // 5. Sacar el estado del envoltorio del group.
        { $replaceWith: '$estado' }

    ]).toArray()[0] || null;
}

const estado = reconstruir(ID, FECHA);

if (estado === null) {
    print('El producto ' + ID + ' no tiene eventos hasta ' + FECHA.toISOString());
} else {
    print('Producto ' + ID + ' al ' + FECHA.toISOString());
    print(JSON.stringify(estado, null, 2));
}
