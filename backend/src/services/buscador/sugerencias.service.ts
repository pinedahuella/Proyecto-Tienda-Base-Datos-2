import { Injectable, Logger } from '@nestjs/common';
import { elasticClient, OPCIONES_BUSQUEDA } from '../../database/elastic';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import { ErrorValidacion } from '../../helpers/errores';
import {
  autocompletarDesdeCopia,
  conRespaldoDeElastic,
} from '../../helpers/buscador-respaldo';
import { Sugerencia } from '../../dto/buscar-sugerencias';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';
const LIMITE_DEFECTO = 8;
const LIMITE_MAXIMO = 20;

interface DocumentoNombre {
  nombre: string;
}

/**
 * El autocompletado del buscador (Entrega 3) -- puerto de
 * `elastic/pruebas/facetas.py::autocompletar()`. A diferencia de
 * `BuscadorProductosService`/`BuscadorFacetadoService` (busqueda con
 * `fuzziness`, para cuando ya se termino de escribir), esta consulta
 * corre MIENTRAS se escribe: `multi_match` con `type: bool_prefix` sobre
 * `nombre.escribiendo` (campo `search_as_you_type` que el mapeo ya trae,
 * sin usar hasta ahora) y sus variantes `_2gram`/`_3gram`, que le dan mas
 * relevancia a una coincidencia de varias palabras.
 *
 * Siempre filtra `estado: activo`, igual que la busqueda publica -- no
 * tiene sentido sugerir un producto que no circula.
 */
@Injectable()
export class BuscadorSugerenciasService {
  private readonly logger = new Logger(BuscadorSugerenciasService.name);

  async sugerir(
    prefijo: string | undefined,
    limite: string | undefined,
  ): Promise<Sugerencia[]> {
    const texto = (prefijo ?? '').trim();
    if (!texto) {
      throw new ErrorValidacion('Escribe al menos una letra para sugerir');
    }

    const tope = this.aLimite(limite);
    try {
      // Sin Elasticsearch, el principio de los nombres de la copia del
      // catalogo en PostgreSQL (buscador-respaldo.ts).
      return await conRespaldoDeElastic(
        async () => {
          const respuesta = await elasticClient.search<DocumentoNombre>(
            {
              index: INDICE,
              size: tope,
              _source: ['nombre'],
              query: {
                bool: {
                  must: [
                    {
                      multi_match: {
                        query: texto,
                        type: 'bool_prefix',
                        fields: [
                          'nombre.escribiendo',
                          'nombre.escribiendo._2gram',
                          'nombre.escribiendo._3gram',
                        ],
                      },
                    },
                  ],
                  filter: [{ term: { estado: 'activo' } }],
                },
              },
            },
            OPCIONES_BUSQUEDA,
          );

          return respuesta.hits.hits.map((hit) => ({
            id_producto: Number(hit._id),
            nombre: hit._source?.nombre ?? '',
          }));
        },
        () => autocompletarDesdeCopia(texto, tope),
      );
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }

  /** `limite` sin validar puede venir vacio, negativo o gigante: se acota.
   * Tope mas bajo que el buscador normal (20, no 50) -- es una lista
   * desplegable, no una pagina de resultados. */
  private aLimite(valor: string | undefined): number {
    const numero = Number(valor);
    if (!Number.isFinite(numero) || numero <= 0) {
      return LIMITE_DEFECTO;
    }
    return Math.min(Math.trunc(numero), LIMITE_MAXIMO);
  }
}
