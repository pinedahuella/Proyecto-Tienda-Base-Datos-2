import { Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { CORREO_TIENDA } from './constantes';
import { manejarErrorConexion } from './manejar-error-db';

/**
 * El id_usuario real de la cuenta de la tienda (tienda@mesh.com), resuelto por
 * correo contra la base -- nunca por un id fijo. Lo mismo que
 * `OfertasVendedorService.obtenerIdTienda()`, para los servicios que no son
 * ese: el buscador de ofertas y los seguimientos del comprador.
 *
 * Si no existe (no deberia pasar nunca, es parte de los datos base) falla
 * fuerte en vez de seguir con un id equivocado.
 */
export async function obtenerIdTienda(logger: Logger): Promise<string> {
  try {
    const resultado = await pool.query<{ id_usuario: string }>(
      'SELECT id_usuario FROM usuarios WHERE correo_electronico = $1',
      [CORREO_TIENDA],
    );
    const fila = resultado.rows[0];
    if (fila == null) {
      throw new Error('No existe la cuenta de la tienda (tienda@mesh.com)');
    }
    return fila.id_usuario;
  } catch (error) {
    manejarErrorConexion(logger, error);
  }
}
