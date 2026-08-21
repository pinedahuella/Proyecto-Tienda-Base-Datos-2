import { Logger } from '@nestjs/common';
import { Pool } from 'pg';
import { obligatoria } from '../helpers/entorno';

const logger = new Logger('Postgres');

/**
 * La conexion a PostgreSQL. Todo el backend consulta la base por aqui.
 *
 * Es un "pool": un grupo de conexiones ya abiertas que se reutilizan. Abrir una
 * conexion nueva en cada consulta seria lento, asi que el pool las mantiene
 * listas y las va prestando.
 *
 * Las credenciales salen de backend/.env, que no se sube al repositorio.
 */
export const pool = new Pool({
  host: process.env.DB_HOST ?? 'localhost',
  port: Number(process.env.DB_PORT ?? 5432),
  user: obligatoria('DB_USER'),
  password: obligatoria('DB_PASSWORD'),
  database: obligatoria('DB_NAME'),
});

/**
 * Cuando una conexion que estaba en reposo se cae (por ejemplo, se apago
 * PostgreSQL), el pool avisa con un evento "error".
 *
 * Este listener es obligatorio: en Node, un evento "error" que nadie escucha
 * mata el proceso. Sin estas lineas, apagar la base tumba el backend completo
 * en vez de que solo falle la consulta.
 */
pool.on('error', (error) => {
  logger.warn(`Se perdio una conexion en reposo: ${error.message}`);
});
