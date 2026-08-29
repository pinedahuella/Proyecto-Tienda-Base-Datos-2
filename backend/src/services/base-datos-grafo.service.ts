import { Injectable, Logger } from '@nestjs/common';
import neo4jInt from 'neo4j-driver';
import { consultarGrafo, neo4jDriver } from '../database/neo4j';
import { exito, fallo, RespuestaApi } from '../helpers/respuesta';
import { conLimiteDeTiempo } from '../helpers/limite-tiempo';
import { InfoConexionGrafo } from '../dto/info-conexion-grafo';

const LIMITE_MS = 6000;

/**
 * Servicio que comprueba si el backend puede hablar con Neo4j (el grafo).
 * El equivalente de BaseDatosService pero para la base de grafos.
 */
@Injectable()
export class BaseDatosGrafoService {
  private readonly logger = new Logger(BaseDatosGrafoService.name);

  /**
   * Verifica la conexion Bolt y, de paso, cuenta los nodos del grafo. El
   * conteo NO es adorno: el grafo es una proyeccion que carga el ETL, y uno
   * vacio significa "conecta pero no hay nada que consultar".
   */
  async verificarConexion(): Promise<RespuestaApi<InfoConexionGrafo | null>> {
    try {
      const { servidor, filas } = await conLimiteDeTiempo(
        (async () => ({
          servidor: await neo4jDriver.getServerInfo(),
          filas: await consultarGrafo<{ nodos: unknown }>(
            'MATCH (n) RETURN count(n) AS nodos',
          ),
        }))(),
        LIMITE_MS,
        'Neo4j',
      );
      const [fila] = filas;

      return exito(
        {
          // `agent` viene como "Neo4j/5.26.0"; se deja tal cual.
          version: servidor.agent ?? 'desconocida',
          nodos: this.aNumero(fila?.nodos),
        },
        'Conexion establecida con Neo4j',
      );
    } catch (error) {
      // El detalle tecnico va al log del servidor, no a la respuesta.
      this.logger.error(error instanceof Error ? error.message : String(error));
      return fallo('No se pudo conectar con Neo4j');
    }
  }

  /**
   * Neo4j devuelve los enteros como su propio tipo `Integer` (para no perder
   * precision con numeros de 64 bits). Aca los conteos son chicos, asi que
   * se pasan a `number` sin riesgo.
   */
  private aNumero(valor: unknown): number {
    if (neo4jInt.isInt(valor)) {
      return valor.toNumber();
    }
    return typeof valor === 'number' ? valor : 0;
  }
}
