// Siembra producto_catalogo y variante_catalogo desde MongoDB.
// Uso (desde backend/):  node "elementos Generales/plan pendiente/catalogo-en-postgres-sembrar.cjs"
// Es idempotente (UPSERT): se puede correr las veces que haga falta.
// Lee las credenciales de backend/.env, igual que el backend.
require('dotenv').config({ path: require('path').join(__dirname, '../../.env') });
const { MongoClient } = require('mongodb');
const { Pool } = require('pg');

(async () => {
  const mongo = new MongoClient(
    `mongodb://${encodeURIComponent(process.env.MONGO_USER)}:${encodeURIComponent(process.env.MONGO_PASSWORD)}@${process.env.MONGO_HOST}:${process.env.MONGO_PORT}/?authSource=admin`,
  );
  const pool = new Pool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
  });
  await mongo.connect();
  const docs = await mongo
    .db(process.env.MONGO_DB)
    .collection('productos')
    .find({}, { projection: { nombre: 1, 'variantes.id_producto_variante': 1, 'variantes.nombre_variante': 1, 'variantes.estado': 1, 'variantes.imagenes': 1 } })
    .toArray();

  const cliente = await pool.connect();
  let productos = 0;
  let variantes = 0;
  try {
    await cliente.query('BEGIN');
    for (const doc of docs) {
      await cliente.query(
        `INSERT INTO producto_catalogo (id_producto_mongo, nombre) VALUES ($1, $2)
         ON CONFLICT (id_producto_mongo) DO UPDATE SET nombre = EXCLUDED.nombre, fecha_actualizacion = now()`,
        [doc._id, doc.nombre],
      );
      productos++;
      for (const v of doc.variantes ?? []) {
        await cliente.query(
          `INSERT INTO variante_catalogo (id_producto_mongo, id_producto_variante_mongo, nombre_variante, estado, imagen)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (id_producto_mongo, id_producto_variante_mongo)
           DO UPDATE SET nombre_variante = EXCLUDED.nombre_variante, estado = EXCLUDED.estado, imagen = EXCLUDED.imagen, fecha_actualizacion = now()`,
          [doc._id, v.id_producto_variante, v.nombre_variante, v.estado, v.imagenes?.[0] ?? null],
        );
        variantes++;
      }
    }
    await cliente.query('COMMIT');
  } catch (error) {
    await cliente.query('ROLLBACK');
    throw error;
  } finally {
    cliente.release();
  }
  console.log(`sembrados: ${productos} productos, ${variantes} variantes`);
  await mongo.close();
  await pool.end();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
