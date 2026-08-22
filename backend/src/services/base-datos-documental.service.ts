import { Injectable, Logger } from '@nestjs/common';
import { mongoClient, mongoDb } from '../database/mongo';
import { exito, fallo, RespuestaApi } from '../helpers/respuesta';
import { InfoConexionDocumental } from '../dto/info-conexion-documental';

/**
 * Servicio que comprueba si el backend puede hablar con MongoDB (la base
 * documental). El equivalente de BaseDatosService pero para Mongo.
 */
@Injectable()
export class BaseDatosDocumentalService {
  private readonly logger = new Logger(BaseDatosDocumentalService.name);

  /**
   * Le manda a MongoDB un ping y devuelve si respondio.
   *
   * A proposito no consulta ninguna coleccion: solo interesa saber si la base
   * contesta, no si tiene datos.
   */
  async verificarConexion(): Promise<
    RespuestaApi<InfoConexionDocumental | null>
  > {
    try {
      await mongoClient.connect();
      const info = await mongoDb.command({ buildInfo: 1 });

      return exito(
        {
          base: mongoDb.databaseName,
          version: `MongoDB ${info.version}`,
        },
        'Conexion establecida con MongoDB',
      );
    } catch (error) {
      // El detalle tecnico va al log del servidor, no a la respuesta.
      this.logger.error(error instanceof Error ? error.message : String(error));
      return fallo('No se pudo conectar con MongoDB');
    }
  }
}
