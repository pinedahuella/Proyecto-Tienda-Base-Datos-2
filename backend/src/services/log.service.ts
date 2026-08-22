import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { ID_TIPO_LOGIN, ID_TIPO_LOGOUT } from '../models/tipo-login';

/**
 * Escribe en log_registro y log_login.
 *
 * A proposito nunca lanza: guardar el log es un efecto secundario de un
 * registro, login o logout que ya tuvieron exito. Si guardarlo falla, eso
 * no puede tumbar la respuesta de algo que si funciono; el error queda
 * nada mas en el log del servidor.
 */
@Injectable()
export class LogService {
  private readonly logger = new Logger(LogService.name);

  /** Desde donde se creo la cuenta. La llama UsuarioController tras un registro exitoso. */
  async registrarRegistro(
    idUsuario: string,
    ipOrigen: string | null,
  ): Promise<void> {
    try {
      await pool.query(
        'INSERT INTO log_registro (id_usuario, ip_origen) VALUES ($1, $2)',
        [idUsuario, ipOrigen],
      );
    } catch (error) {
      this.logger.error(`No se pudo guardar el log de registro: ${error}`);
    }
  }

  /** Cada entrada. La llama UsuarioController tras un login exitoso. */
  async registrarLogin(
    idUsuario: string,
    ipOrigen: string | null,
  ): Promise<void> {
    await this.insertarLogLogin(idUsuario, ID_TIPO_LOGIN, ipOrigen, 'login');
  }

  /**
   * Cada salida. La llama UsuarioController tras cerrar sesion, solo
   * cuando el token todavia identificaba a alguien (si ya habia vencido o
   * no habia cookie, no hay a quien atribuirle el logout, y no se guarda
   * nada; cerrar sesion sigue funcionando igual).
   */
  async registrarLogout(
    idUsuario: string,
    ipOrigen: string | null,
  ): Promise<void> {
    await this.insertarLogLogin(idUsuario, ID_TIPO_LOGOUT, ipOrigen, 'logout');
  }

  private async insertarLogLogin(
    idUsuario: string,
    idTipoLogin: number,
    ipOrigen: string | null,
    etiqueta: string,
  ): Promise<void> {
    try {
      await pool.query(
        'INSERT INTO log_login (id_usuario, id_tipo_login, ip_origen) VALUES ($1, $2, $3)',
        [idUsuario, idTipoLogin, ipOrigen],
      );
    } catch (error) {
      this.logger.error(`No se pudo guardar el log de ${etiqueta}: ${error}`);
    }
  }
}
