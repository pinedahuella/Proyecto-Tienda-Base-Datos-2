import { MongoClient } from 'mongodb';
import { obligatoria } from '../helpers/entorno';

/**
 * La conexion a MongoDB (la base documental, para los productos). El
 * equivalente de src/database/postgres.ts pero para Mongo.
 *
 * Las credenciales salen de backend/.env, que no se sube al repositorio.
 */
const host = process.env.MONGO_HOST ?? 'localhost';
const port = Number(process.env.MONGO_PORT ?? 27018);
const usuario = obligatoria('MONGO_USER');
const contrasena = obligatoria('MONGO_PASSWORD');
const nombreBase = obligatoria('MONGO_DB');

const uri = `mongodb://${encodeURIComponent(usuario)}:${encodeURIComponent(contrasena)}@${host}:${port}/?authSource=admin`;

/**
 * `serverSelectionTimeoutMS` / `connectTimeoutMS` en 3 s (el driver trae 30 s
 * por defecto). Sin esto, con Mongo caido cualquier consulta se queda
 * colgada 30 s antes de rendirse -- y como el checkout consulta Mongo antes
 * de cerrar la venta (nombre de producto y estado de variante no viven en
 * PostgreSQL), un `POST /carrito/comprar` o `POST /comprador/pedidos/:id/comprar`
 * tardaba ~32 s en devolver el 503, con la request HTTP y una conexion del
 * pool tomadas todo ese rato. Con 3 s falla rapido y libera. No cambia la
 * consistencia: la venta ya era atomica en PostgreSQL y Mongo nunca estuvo
 * en el COMMIT (ver `elementos Generales/prueba-falla-mongo-checkout.md`).
 * Mismo criterio que el limite de 3 s del health-check del grafo.
 */
export const mongoClient = new MongoClient(uri, {
  serverSelectionTimeoutMS: 3000,
  connectTimeoutMS: 3000,
});
export const mongoDb = mongoClient.db(nombreBase);
