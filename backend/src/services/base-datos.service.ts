import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../database/postgres';
import { exito, fallo, RespuestaApi } from '../helpers/respuesta';
import { InfoConexion } from '../models/info-conexion';

/**
 * Servicio que comprueba si el backend puede hablar con PostgreSQL.
 */
@Injectable()
export class BaseDatosService {
  private readonly logger = new Logger(BaseDatosService.name);

  /**
   * Le manda a PostgreSQL una consulta minima y devuelve si respondio.
   *
   * A proposito no consulta ninguna tabla: solo interesa saber si la base
   * contesta, no si tiene datos. Si contesta hay conexion; si lanza error,
   * no la hay.
   */
  async verificarConexion(): Promise<RespuestaApi<InfoConexion | null>> {
    try {
      const resultado = await pool.query<InfoConexion>(
        'SELECT current_database() AS base, now() AS hora, version() AS version',
      );

      const fila = resultado.rows[0];

      return exito(
        {
          base: fila.base,
          hora: fila.hora,
          // version() devuelve un texto largo; solo se muestran las dos primeras
          // palabras, que son "PostgreSQL 18.6"
          version: fila.version.split(' ').slice(0, 2).join(' '),
        },
        'Conexion establecida con PostgreSQL',
      );
    } catch (error) {
      // El detalle tecnico va al log del servidor, no a la respuesta: decirle a
      // cualquiera que el puerto 5432 esta abierto es informacion de mas.
      this.logger.error(this.describirError(error));
      return fallo('No se pudo conectar con PostgreSQL');
    }
  }

  /**
   * Convierte un error del driver en un texto legible para el log.
   *
   * Hace falta porque cuando PostgreSQL esta apagado el driver lanza un
   * AggregateError con el mensaje vacio y las causas reales escondidas dentro
   * de errors[]. Sin desempaquetarlas, el log queda en blanco.
   */
  private describirError(error: unknown): string {
    if (error instanceof AggregateError) {
      const causas = error.errors
        .map((e) => this.describirError(e))
        .filter(Boolean);
      return causas.join(' | ') || 'No se pudo conectar con PostgreSQL';
    }

    if (error instanceof Error) {
      const codigo = (error as NodeJS.ErrnoException).code;
      if (error.message) {
        return codigo ? `${codigo}: ${error.message}` : error.message;
      }
      return codigo ?? error.name;
    }

    return String(error);
  }
}
