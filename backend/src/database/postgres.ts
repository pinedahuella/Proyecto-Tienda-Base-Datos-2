import { Logger } from '@nestjs/common';
import { Pool } from 'pg';

const logger = new Logger('Postgres');

/**
 * Lee una variable de entorno y corta el arranque si no existe.
 *
 * Es a proposito: si la contrasena viniera con un valor por defecto escrito
 * aqui, esa contrasena quedaria en el repositorio. Mejor que el backend no
 * arranque y diga que falta, a que arranque con una credencial publicada.
 */
function obligatoria(nombre: string): string {
  const valor = process.env[nombre];
  if (!valor) {
    throw new Error(
      `Falta la variable ${nombre}. Copia backend/.env.example como backend/.env y llenalo.`,
    );
  }
  return valor;
}

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
