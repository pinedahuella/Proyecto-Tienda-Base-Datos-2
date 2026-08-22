import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { RolUsuario } from '../../models/rol-usuario';
import { EstadoUsuario } from '../../models/estado-usuario';

/**
 * Servicio de las rutas /admin/roles y /admin/estados.
 *
 * Solo lectura de los dos catalogos: le sirven al frontend para armar los
 * selects de "cambiar rol" / "cambiar estado" en el panel de admin, con
 * los ids reales en vez de tenerlos escritos a mano ahi.
 */
@Injectable()
export class AdminCatalogosService {
  private readonly logger = new Logger(AdminCatalogosService.name);

  async listarRoles(): Promise<RolUsuario[]> {
    try {
      const resultado = await pool.query<RolUsuario>(
        'SELECT id_rol_usuario, rol_usuario_nombre FROM rol_usuario ORDER BY id_rol_usuario',
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  async listarEstados(): Promise<EstadoUsuario[]> {
    try {
      const resultado = await pool.query<EstadoUsuario>(
        'SELECT id_estado_usuario, estado_usuario_nombre FROM estado_usuario ORDER BY id_estado_usuario',
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
