import { Injectable, Logger } from '@nestjs/common';
import { elasticClient } from '../database/elastic';
import { exito, fallo, RespuestaApi } from '../helpers/respuesta';
import { conLimiteDeTiempo } from '../helpers/limite-tiempo';
import { InfoConexionBuscador } from '../dto/info-conexion-buscador';

const LIMITE_MS = 6000;

/** El indice del buscador. Mismo nombre y mismo default que usan
 * etl/cargar_busqueda.sh y pruebas/busqueda.sh (`INDICE=mesh_productos`). */
const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

/**
 * Servicio que comprueba si el backend puede hablar con Elasticsearch (el
 * buscador). El equivalente de BaseDatosDocumentalService/ClaveValorService/
 * GrafoService pero para la Entrega 3.
 */
@Injectable()
export class BaseDatosBuscadorService {
  private readonly logger = new Logger(BaseDatosBuscadorService.name);

  /**
   * Verifica que el cluster conteste y de paso cuenta los documentos del
   * indice. El conteo NO es adorno: el indice es una proyeccion que carga
   * el ETL (etl/cargar_busqueda.sh), y uno vacio (0) es un fallo comun -- el
   * backend conecta pero no hay nada que buscar.
   *
   * Que el indice todavia no exista (antes de la primera corrida del ETL)
   * NO se trata como una caida de Elasticsearch: el cluster si contesto, asi
   * que el conteo cae a 0 en vez de tumbar toda la respuesta.
   */
  async verificarConexion(): Promise<
    RespuestaApi<InfoConexionBuscador | null>
  > {
    try {
      const { info, salud } = await conLimiteDeTiempo(
        (async () => ({
          info: await elasticClient.info(),
          salud: await elasticClient.cluster.health(),
        }))(),
        LIMITE_MS,
        'Elasticsearch',
      );

      return exito(
        {
          version: info.version?.number ?? 'desconocida',
          estado_cluster: salud.status ?? 'desconocido',
          documentos: await this.contarDocumentos(),
        },
        'Conexion establecida con Elasticsearch',
      );
    } catch (error) {
      // El detalle tecnico va al log del servidor, no a la respuesta.
      this.logger.error(error instanceof Error ? error.message : String(error));
      return fallo('No se pudo conectar con Elasticsearch');
    }
  }

  /**
   * Cuenta los documentos del indice del buscador. Si el indice todavia no
   * existe (404, antes de la primera corrida del ETL) devuelve 0 en vez de
   * lanzar: el cluster esta bien, solo falta cargarlo.
   */
  private async contarDocumentos(): Promise<number> {
    try {
      const { count } = await elasticClient.count({ index: INDICE });
      return count;
    } catch (error) {
      this.logger.warn(
        `No se pudo contar el indice ${INDICE}: ${error instanceof Error ? error.message : String(error)}`,
      );
      return 0;
    }
  }
}
