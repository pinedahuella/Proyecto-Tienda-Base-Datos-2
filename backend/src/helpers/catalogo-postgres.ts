import { Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { manejarErrorConexion } from './manejar-error-db';

/**
 * Lo minimo de un producto de Mongo que se copia a PostgreSQL. Desde la 047
 * tambien el estado, la categoria, la descripcion y la fecha de creacion: con
 * eso el respaldo (`catalogo-respaldo.ts`) muestra el catalogo y la ficha
 * cuando Mongo no responde.
 */
export interface ProductoParaCatalogo {
  _id: number;
  nombre: string;
  estado: string;
  descripcion: string | null;
  categoria: { id_categoria: number };
  fecha_creacion: Date;
  variantes: {
    id_producto_variante: number;
    nombre_variante: string;
    estado: string;
    imagenes: string[];
  }[];
}

/**
 * Deja `producto_catalogo` y `variante_catalogo` como el producto de Mongo
 * (UPSERT), dentro de la transaccion `cliente`. Una variante que ya no esta
 * en el producto se borra de la copia; si alguna oferta todavia la usa, se
 * deja `inactiva` en vez de borrarla (oferta apunta a ella por el par).
 */
export async function sincronizarCatalogo(
  cliente: PoolClient,
  producto: ProductoParaCatalogo,
): Promise<void> {
  await cliente.query(
    `INSERT INTO producto_catalogo
       (id_producto_mongo, nombre, estado, descripcion, id_categoria, fecha_creacion)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (id_producto_mongo)
     DO UPDATE SET nombre = EXCLUDED.nombre,
                   estado = EXCLUDED.estado,
                   descripcion = EXCLUDED.descripcion,
                   id_categoria = EXCLUDED.id_categoria,
                   fecha_creacion = EXCLUDED.fecha_creacion,
                   fecha_actualizacion = now()`,
    [
      producto._id,
      producto.nombre,
      producto.estado,
      producto.descripcion ?? null,
      producto.categoria.id_categoria,
      producto.fecha_creacion,
    ],
  );

  const ids = producto.variantes.map((v) => v.id_producto_variante);

  await cliente.query(
    `INSERT INTO variante_catalogo
       (id_producto_mongo, id_producto_variante_mongo, nombre_variante, estado, imagen)
     SELECT $1, t.id, t.nombre, t.estado, t.imagen
       FROM unnest($2::bigint[], $3::text[], $4::text[], $5::text[])
            AS t(id, nombre, estado, imagen)
     ON CONFLICT (id_producto_mongo, id_producto_variante_mongo)
     DO UPDATE SET nombre_variante = EXCLUDED.nombre_variante,
                   estado = EXCLUDED.estado,
                   imagen = EXCLUDED.imagen,
                   fecha_actualizacion = now()`,
    [
      producto._id,
      ids,
      producto.variantes.map((v) => v.nombre_variante),
      producto.variantes.map((v) => v.estado),
      producto.variantes.map((v) => v.imagenes?.[0] ?? null),
    ],
  );

  await cliente.query(
    `DELETE FROM variante_catalogo vc
      WHERE vc.id_producto_mongo = $1
        AND vc.id_producto_variante_mongo <> ALL($2::bigint[])
        AND NOT EXISTS (
              SELECT 1 FROM oferta o
               WHERE o.id_producto_mongo = vc.id_producto_mongo
                 AND o.id_producto_variante_mongo = vc.id_producto_variante_mongo)`,
    [producto._id, ids],
  );
  await cliente.query(
    `UPDATE variante_catalogo
        SET estado = 'inactiva', fecha_actualizacion = now()
      WHERE id_producto_mongo = $1
        AND id_producto_variante_mongo <> ALL($2::bigint[])
        AND estado <> 'inactiva'`,
    [producto._id, ids],
  );
}

/**
 * Solo el estado del producto en la copia, dentro de la transaccion `cliente`.
 * Lo usan revisar y reenviar una propuesta, que cambian el estado en Mongo y
 * ya tienen su propia transaccion de PostgreSQL (la compensacion de Mongo es
 * la suya). Aprobar es lo que vuelve publico un producto: sin esto el respaldo
 * no lo mostraria.
 */
export async function actualizarEstadoCatalogo(
  cliente: PoolClient,
  idProducto: number,
  estado: string,
): Promise<void> {
  await cliente.query(
    `UPDATE producto_catalogo
        SET estado = $2, fecha_actualizacion = now()
      WHERE id_producto_mongo = $1`,
    [idProducto, estado],
  );
}

/**
 * Escribe en Mongo y en la copia del catalogo de PostgreSQL "como una
 * transaccion". No lo es de verdad (son dos bases, sin commit en dos fases);
 * el orden es lo que la acerca:
 *
 *   1. BEGIN en PostgreSQL y UPSERT de la copia (todavia sin commit)
 *   2. `escribirMongo(cliente)` -- la escritura de Mongo, y lo que deba ir
 *      en la misma transaccion de PostgreSQL
 *   3. COMMIT de PostgreSQL
 *
 * - Falla el paso 1 o el 2: ROLLBACK de PostgreSQL y `compensarMongo()`
 *   (debe ser idempotente: puede correr sin que Mongo haya cambiado).
 * - Falla el COMMIT (paso 3): Mongo ya cambio, asi que se compensa.
 *
 * Ventana que queda: el proceso muere entre el paso 2 y el 3, o falla la
 * propia compensacion -- Mongo cambiado y la copia no. Se registra en el log.
 *
 * Los errores de PostgreSQL de los pasos 1 y 3 salen ya clasificados
 * (ErrorConexion -> 503); los de Mongo salen tal cual para que el llamador
 * los clasifique.
 */
export async function escribirConCatalogoPostgres(
  logger: Logger,
  producto: ProductoParaCatalogo,
  escribirMongo: (cliente: PoolClient) => Promise<void>,
  compensarMongo: () => Promise<void>,
): Promise<void> {
  let cliente: PoolClient;
  try {
    cliente = await pool.connect();
  } catch (error) {
    manejarErrorConexion(logger, error);
  }

  try {
    try {
      await cliente.query('BEGIN');
      await sincronizarCatalogo(cliente, producto);
      await escribirMongo(cliente);
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      await compensar(logger, producto._id, compensarMongo);
      // Convierte una caida de PostgreSQL en ErrorConexion (503) y deja pasar
      // cualquier otro error tal cual -- los de Mongo los clasifica el llamador.
      manejarErrorConexion(logger, error);
    }

    try {
      await cliente.query('COMMIT');
    } catch (error) {
      await compensar(logger, producto._id, compensarMongo);
      manejarErrorConexion(logger, error);
    }
  } finally {
    cliente.release();
  }
}

async function compensar(
  logger: Logger,
  idProducto: number,
  compensarMongo: () => Promise<void>,
): Promise<void> {
  try {
    await compensarMongo();
  } catch (error) {
    logger.error(
      `No se pudo compensar Mongo del producto ${idProducto}: Mongo y la copia en PostgreSQL pueden haber quedado distintos. ` +
        (error instanceof Error ? error.message : String(error)),
    );
  }
}
