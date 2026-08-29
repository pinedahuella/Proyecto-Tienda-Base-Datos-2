import { Injectable, Logger } from '@nestjs/common';
import { redis } from '../database/redis';
import { exito, fallo, RespuestaApi } from '../helpers/respuesta';
import { conLimiteDeTiempo } from '../helpers/limite-tiempo';
import { InfoConexionClaveValor } from '../dto/info-conexion-clave-valor';

const LIMITE_MS = 5000;

/**
 * Servicio que comprueba si el backend puede hablar con Redis (el almacen
 * clave-valor). El equivalente de BaseDatosService pero para Redis.
 */
@Injectable()
export class BaseDatosClaveValorService {
  private readonly logger = new Logger(BaseDatosClaveValorService.name);

  /**
   * Le manda a Redis un PING y devuelve si respondio. A proposito no lee ni
   * escribe ninguna clave: solo interesa saber si el servidor contesta.
   *
   * De `INFO server` se sacan la version y el modo, para que la respuesta
   * diga algo util (igual que `GET /db` devuelve la version de PostgreSQL).
   */
  async verificarConexion(): Promise<
    RespuestaApi<InfoConexionClaveValor | null>
  > {
    try {
      // Si Redis no contesta, esto lanza (timeout o conexion cerrada) y cae
      // al catch. `conLimiteDeTiempo` garantiza que la ruta responda rapido
      // aunque el cliente se quede reintentando.
      const info = await conLimiteDeTiempo(
        redis.ping().then(() => redis.info('server')),
        LIMITE_MS,
        'Redis',
      );
      return exito(
        {
          version: this.leerCampo(info, 'redis_version') ?? 'desconocida',
          modo: this.leerCampo(info, 'redis_mode') ?? 'standalone',
        },
        'Conexion establecida con Redis',
      );
    } catch (error) {
      // El detalle tecnico va al log del servidor, no a la respuesta: decir
      // que el 6379 esta abierto es informacion de mas.
      this.logger.error(error instanceof Error ? error.message : String(error));
      return fallo('No se pudo conectar con Redis');
    }
  }

  /** Saca `campo:valor` del texto que devuelve `INFO`. */
  private leerCampo(info: string, campo: string): string | null {
    const linea = info.split('\n').find((l) => l.startsWith(`${campo}:`));
    return linea ? linea.slice(campo.length + 1).trim() : null;
  }
}
