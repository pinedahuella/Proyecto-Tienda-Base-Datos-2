import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { elasticClient } from '../../database/elastic';
import { modeloValoracion, valorarTexto } from '../../helpers/valoracion-texto';
import { redondear } from '../../helpers/similitud-vectores';

const INDICE = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

/** Lo que se lee de un documento para valorarlo. */
interface DocumentoPorValorar {
  comentario: string;
  vector: number[];
}

/**
 * Le pone a cada resena de `mesh_comentarios` su valoracion: el campo
 * `valoracion_texto` (`mala`, `buena`, `dudosa` o `corta`) y `prob_mala`, la
 * probabilidad de que el texto sea malo. Asi las senales de notas
 * incoherentes (`NotasIncoherentesDetectorService`) cuentan con agregaciones de
 * Elasticsearch en vez de correr el modelo cientos de veces.
 *
 * Valora desde el VECTOR que ya esta en el documento (la regresion logistica es
 * una multiplicacion de 768 numeros), asi que no llama a Ollama. Busca en cada
 * corrida las resenas raiz con vector que no tienen valoracion, o que se
 * valoraron con otra version del modelo (`valoracion_modelo`): eso cubre
 * resenas nuevas, resenas cuyo texto cambio (`EventoComentarioSyncService`
 * borra la valoracion al recalcular el vector), las que ya existian antes de
 * este campo y un cambio de modelo, de umbrales o de largo minimo.
 *
 * Solo las raices: las respuestas no llevan estrellas, no hay nada que
 * contradecir.
 *
 * Si la resena cambia mientras se valora, el `update` lleva `if_seq_no` y
 * `if_primary_term` y Elasticsearch lo rechaza (409): se salta y la proxima
 * corrida la toma con su texto nuevo. Mismo molde que
 * `EventoComentarioSyncService`: `@Interval` con una bandera para que una
 * corrida lenta no se pise con la siguiente.
 */
@Injectable()
export class ValoracionComentariosService {
  private readonly logger = new Logger(ValoracionComentariosService.name);

  private static readonly INTERVALO_MS = 30000;

  /** Documentos por pasada, y pasadas por corrida: si hay mas pendientes,
   * siguen en la proxima. */
  private static readonly LOTE = 200;
  private static readonly MAX_PASADAS = 10;

  /** La pasada en curso, o `null` si no hay ninguna. */
  private pasada: Promise<void> | null = null;

  @Interval('valoracion-comentarios', ValoracionComentariosService.INTERVALO_MS)
  async valorar(): Promise<void> {
    if (this.pasada != null) {
      return;
    }
    await this.arrancarPasada();
  }

  /**
   * Valora YA lo pendiente, sin esperar el reloj de 30 s, y termina cuando la
   * valoracion ya se puede buscar. La llama el chequeo inmediato de una resena
   * recien escrita (`ChequeoTextoInmediatoService`), despues de indexarla. Si ya
   * hay una pasada en curso, espera a que termine y hace OTRA. No lanza: un
   * fallo se loguea y lo toma la proxima pasada del reloj.
   */
  async valorarAhora(): Promise<void> {
    while (this.pasada != null) {
      await this.pasada;
    }
    await this.arrancarPasada();
  }

  private arrancarPasada(): Promise<void> {
    const pasada = this.unaPasada().finally(() => {
      this.pasada = null;
    });
    this.pasada = pasada;
    return pasada;
  }

  /** Una pasada completa. No lanza: un fallo se loguea y queda para la proxima. */
  private async unaPasada(): Promise<void> {
    const modelo = modeloValoracion();
    if (modelo == null) {
      return;
    }

    try {
      let valoradas = 0;
      let saltadas = 0;
      for (let i = 0; i < ValoracionComentariosService.MAX_PASADAS; i++) {
        const respuesta = await elasticClient.search<DocumentoPorValorar>({
          index: INDICE,
          size: ValoracionComentariosService.LOTE,
          seq_no_primary_term: true,
          _source: ['comentario', 'vector'],
          query: {
            bool: {
              filter: [
                { term: { es_respuesta: false } },
                { exists: { field: 'vector' } },
              ],
              should: [
                {
                  bool: { must_not: { exists: { field: 'valoracion_texto' } } },
                },
                {
                  bool: {
                    must_not: { term: { valoracion_modelo: modelo.version } },
                  },
                },
              ],
              minimum_should_match: 1,
            },
          },
        });
        const hits = respuesta.hits.hits;
        if (hits.length === 0) {
          break;
        }

        const operaciones: object[] = [];
        for (const hit of hits) {
          const fuente = hit._source;
          if (fuente == null || !Array.isArray(fuente.vector)) {
            continue;
          }
          const { valoracion, probMala } = valorarTexto(
            modelo,
            fuente.comentario,
            fuente.vector,
          );
          operaciones.push(
            {
              update: {
                _index: INDICE,
                _id: hit._id,
                if_seq_no: hit._seq_no,
                if_primary_term: hit._primary_term,
              },
            },
            {
              doc: {
                valoracion_texto: valoracion,
                prob_mala: probMala == null ? null : redondear(probMala),
                valoracion_modelo: modelo.version,
              },
            },
          );
        }
        if (operaciones.length === 0) {
          break;
        }

        const resultado = await elasticClient.bulk({
          operations: operaciones,
          refresh: 'wait_for',
        });
        for (const item of resultado.items) {
          const error = item.update?.error;
          if (error == null) {
            valoradas++;
          } else if (item.update?.status === 409) {
            saltadas++;
          } else {
            this.logger.warn(
              `valoracion de comentarios: fallo ${item.update?._id}: ${error.reason ?? error.type}`,
            );
          }
        }
        // Si todo lo de esta pasada se salto o fallo, otra pasada traeria lo
        // mismo: se deja para la proxima corrida.
        if (valoradas === 0) {
          break;
        }
        if (hits.length < ValoracionComentariosService.LOTE) {
          break;
        }
      }

      if (valoradas > 0 || saltadas > 0) {
        this.logger.log(
          `valoracion de comentarios: ${valoradas} valorados, ${saltadas} saltados por cambiar mientras tanto`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `valoracion de comentarios: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    }
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
