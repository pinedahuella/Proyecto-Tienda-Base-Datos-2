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

export const mongoClient = new MongoClient(uri);
export const mongoDb = mongoClient.db(nombreBase);
