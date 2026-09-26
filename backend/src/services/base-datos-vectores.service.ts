import { Injectable, Logger } from '@nestjs/common';
import { OLLAMA_URL, OLLAMA_MODELO } from '../database/ollama';
import { exito, fallo, RespuestaApi } from '../helpers/respuesta';
import { conLimiteDeTiempo } from '../helpers/limite-tiempo';
import { InfoConexionVectores } from '../dto/info-conexion-vectores';

const LIMITE_MS = 6000;

interface RespuestaTags {
  models?: { name: string }[];
}

/**
 * Servicio que comprueba si el backend puede hablar con Ollama (la
 * recomendacion semantica de la Entrega final). El equivalente de
 * BaseDatosBuscadorService pero para el servicio de embeddings.
 *
 * Solo pregunta `/api/tags` (los modelos ya descargados) -- no calcula
 * ningun vector. Eso lo hace `etl/cargar_vectores.ps1` (o, si se construye
 * mas adelante, un worker aparte); esta ruta solo confirma que la conexion
 * existe y que el modelo que hace falta ya esta ahi.
 */
@Injectable()
export class BaseDatosVectoresService {
  private readonly logger = new Logger(BaseDatosVectoresService.name);

  async verificarConexion(): Promise<
    RespuestaApi<InfoConexionVectores | null>
  > {
    try {
      const respuesta = await conLimiteDeTiempo(
        fetch(`${OLLAMA_URL}/api/tags`),
        LIMITE_MS,
        'Ollama',
      );
      if (!respuesta.ok) {
        throw new Error(`Ollama respondio ${respuesta.status}`);
      }

      const cuerpo = (await respuesta.json()) as RespuestaTags;
      const modelos = (cuerpo.models ?? []).map((modelo) => modelo.name);
      const modeloDescargado = modelos.some((nombre) =>
        nombre.startsWith(OLLAMA_MODELO),
      );

      return exito(
        {
          url: OLLAMA_URL,
          modelo: OLLAMA_MODELO,
          modelo_descargado: modeloDescargado,
          modelos_disponibles: modelos,
        },
        modeloDescargado
          ? 'Conexion establecida con Ollama'
          : `Ollama conecto, pero el modelo ${OLLAMA_MODELO} no esta descargado`,
      );
    } catch (error) {
      this.logger.error(error instanceof Error ? error.message : String(error));
      return fallo('No se pudo conectar con Ollama');
    }
  }
}
