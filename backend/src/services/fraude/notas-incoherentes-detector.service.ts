import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { elasticClient } from '../../database/elastic';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';
import {
  LARGO_MINIMO_VALORACION,
  modeloValoracion,
} from '../../helpers/valoracion-texto';
import type { TipoAnilloFraude } from '../../models/anillo-fraude';

const INDICE = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

/** Un documento de `mesh_comentarios`, con lo que necesita la evidencia. */
interface DocumentoResena {
  id_resena: number;
}

/** La reseña recien escrita, con lo que hace falta para saber si es contradictoria. */
interface DocumentoNuevo {
  es_respuesta: boolean;
  valoracion_texto?: string | null;
  calificacion?: number | null;
  id_usuario: number;
  id_producto: number;
  id_vendedor?: number | null;
}

interface Candidato {
  key: number;
  doc_count: number;
  contradictorias: { doc_count: number };
}

/** Una de las tres cuentas de la regla: sobre quien se cuenta. */
interface Dimension {
  tipo: Extract<
    TipoAnilloFraude,
    | 'notas_incoherentes_cuenta'
    | 'notas_incoherentes_producto'
    | 'notas_incoherentes_vendedor'
  >;
  /** El campo de `mesh_comentarios` por el que se agrupa. */
  campo: 'id_usuario' | 'id_producto' | 'id_vendedor';
  /** Que porcentaje de sus resenas valoradas deben ser contradictorias. */
  porcentajeMinimo: number;
}

/**
 * Cuentas y vendedores al 20 %, productos al 40 % (un producto con 4 de cada 10
 * resenas contrarias a sus estrellas ya es raro; una cuenta o un vendedor
 * llega a ese 20 % con mucho menos).
 */
const DIMENSIONES: Dimension[] = [
  {
    tipo: 'notas_incoherentes_cuenta',
    campo: 'id_usuario',
    porcentajeMinimo: 20,
  },
  {
    tipo: 'notas_incoherentes_producto',
    campo: 'id_producto',
    porcentajeMinimo: 40,
  },
  {
    tipo: 'notas_incoherentes_vendedor',
    campo: 'id_vendedor',
    porcentajeMinimo: 20,
  },
];

/**
 * Una resena es CONTRADICTORIA si su texto dice una cosa y sus estrellas otra:
 * texto malo con 4 o 5 estrellas, o texto bueno con 1 o 2. Las 3 estrellas no
 * cuentan nunca, ni los textos `dudosos` (la franja del medio del modelo).
 */
const CONTRADICTORIA = {
  bool: {
    should: [
      {
        bool: {
          filter: [
            { term: { valoracion_texto: 'mala' } },
            { range: { calificacion: { gte: 4 } } },
          ],
        },
      },
      {
        bool: {
          filter: [
            { term: { valoracion_texto: 'buena' } },
            { range: { calificacion: { lte: 2 } } },
          ],
        },
      },
    ],
    minimum_should_match: 1,
  },
};

/**
 * Detecta cuentas, productos y vendedores con muchas resenas "contradictorias"
 * (texto malo con 4-5 estrellas, o texto bueno con 1-2). Son tres senales de la
 * familia `patron_resenas`, con fuente `elastic`:
 *
 * - `notas_incoherentes_cuenta`: una cuenta con 5 o mas resenas contradictorias
 *   que son el 20 % o mas de las que escribio. Entra a los casos de fraude
 *   (puntaje propio, nunca en `TIPOS_FUERTES`).
 * - `notas_incoherentes_producto`: igual, sobre las resenas que recibio un
 *   producto, con el 40 %.
 * - `notas_incoherentes_vendedor`: igual, sobre las resenas de los productos de
 *   un vendedor, con el 20 %.
 *
 * Las de producto y vendedor son solo ALERTA para el admin
 * (`GET /admin/fraude/alertas-resenas`): no forman casos ni suman puntos
 * (`TIPOS_SOLO_ALERTA` en `HallazgoFraudeAdaptadorService`), porque una resena
 * contradictoria tanto puede venir de quien compra resenas como de una campana
 * en contra del vendedor.
 *
 * Todo sale de agregaciones de Elasticsearch sobre `mesh_comentarios`, donde
 * cada resena ya trae su `valoracion_texto` (`ValoracionComentariosService`):
 * el modelo no corre aca. Solo cuentan las resenas raiz (las respuestas no
 * llevan estrellas), de los ultimos `VENTANA_DIAS` y con valoracion `mala`,
 * `buena` o `dudosa` (las de menos de `LARGO_MINIMO_VALORACION` caracteres son
 * `corta` y no se cuentan, ni como contradictorias ni en el total). El
 * porcentaje es contradictorias sobre ese total.
 *
 * Mismo molde que `ResenasRepetidasDetectorService`: `@Interval`, bandera
 * `procesando` y un error de conexion se loguea y no tumba el proceso. La
 * senal se persiste con `registrarAnilloFraude`, con las resenas contradictorias
 * como evidencia.
 *
 * Limite conocido: el modelo acierta cerca del 90 % y falla con el sarcasmo,
 * asi que una resena contradictoria puede no serlo. Por eso hacen falta 5 y un
 * porcentaje, y por eso ninguna de las tres es una senal fuerte.
 */
@Injectable()
export class NotasIncoherentesDetectorService {
  private readonly logger = new Logger(NotasIncoherentesDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Solo cuentan las resenas de los ultimos dias. Igual que
   * `ResenasRepetidasDetectorService.VENTANA_DIAS`. */
  private static readonly VENTANA_DIAS = 180;

  /** Resenas contradictorias que hacen falta, ademas del porcentaje. */
  private static readonly MIN_CONTRADICTORIAS = 5;

  /** Tope de cuentas/productos/vendedores que se revisan por corrida (los de
   * mas resenas contradictorias primero). */
  private static readonly MAX_CANDIDATOS = 1000;

  /** Tope de resenas que se guardan como evidencia de una senal (las mas
   * recientes). */
  private static readonly MAX_EVIDENCIA = 100;

  private procesando = false;

  @Interval(
    'notas-incoherentes-detector',
    NotasIncoherentesDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    // Sin modelo no hay valoraciones y no hay nada que contar.
    const modelo = modeloValoracion();
    if (modelo == null) {
      return;
    }
    this.procesando = true;
    try {
      const candidatos = await this.buscarCandidatos();
      const resumen: string[] = [];
      for (const dimension of DIMENSIONES) {
        let senales = 0;
        for (const candidato of candidatos.get(dimension.tipo) ?? []) {
          senales += await this.registrar(dimension, candidato, modelo.version);
        }
        resumen.push(`${senales} ${dimension.tipo}`);
      }
      this.logger.log(`worker de notas incoherentes: ${resumen.join(', ')}`);
    } catch (error) {
      this.logger.warn(
        `worker de notas incoherentes interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * El chequeo de UNA reseña recien escrita: la llama `ChequeoTextoInmediatoService`
   * cuando ya esta indexada y valorada. Solo si esa reseña es contradictoria (una
   * que no lo es solo puede bajar un porcentaje, no subirlo), vuelve a evaluar su
   * cuenta, su producto y su vendedor. Las agregaciones las hace Elasticsearch,
   * acotadas a esas tres llaves. Un error se loguea; lo recoge la proxima pasada
   * de `detectar()`.
   */
  async detectarInmediato(idComentario: number): Promise<void> {
    try {
      const modelo = modeloValoracion();
      if (modelo == null) {
        return;
      }
      const respuesta = await elasticClient.get<DocumentoNuevo>(
        {
          index: INDICE,
          id: String(idComentario),
          _source: [
            'es_respuesta',
            'valoracion_texto',
            'calificacion',
            'id_usuario',
            'id_producto',
            'id_vendedor',
          ],
        },
        { ignore: [404] },
      );
      const nueva = respuesta.found ? respuesta._source : undefined;
      if (nueva == null || !this.esContradictoria(nueva)) {
        return;
      }

      for (const dimension of DIMENSIONES) {
        const llave = nueva[dimension.campo];
        if (llave == null) {
          continue;
        }
        const candidatos = await this.buscarCandidatos(
          [dimension],
          [{ term: { [dimension.campo]: llave } }],
        );
        for (const candidato of candidatos.get(dimension.tipo) ?? []) {
          await this.registrar(dimension, candidato, modelo.version);
        }
      }
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de notas incoherentes interrumpido (comentario ${idComentario}): ${mensajeCorto(error)}`,
      );
    }
  }

  /** Lo mismo que `CONTRADICTORIA`, para una sola reseña ya en memoria. */
  private esContradictoria(r: DocumentoNuevo): boolean {
    if (r.es_respuesta || r.calificacion == null) {
      return false;
    }
    return (
      (r.valoracion_texto === 'mala' && r.calificacion >= 4) ||
      (r.valoracion_texto === 'buena' && r.calificacion <= 2)
    );
  }

  /** Las resenas que cuentan: raiz, en la ventana y ya valoradas. */
  private filtroBase(): object[] {
    return [
      { term: { es_respuesta: false } },
      {
        range: {
          fecha_publicacion: {
            gte: `now-${NotasIncoherentesDetectorService.VENTANA_DIAS}d`,
          },
        },
      },
      { terms: { valoracion_texto: ['mala', 'buena', 'dudosa'] } },
    ];
  }

  /**
   * Una sola consulta con una agregacion por dimension. Cada una agrupa por
   * cuenta, producto o vendedor, cuenta sus contradictorias en una sub-agregacion
   * y se queda solo con las que pasan las dos reglas (`bucket_selector`).
   * Ordenadas por contradictorias: si hubiera mas de `MAX_CANDIDATOS`, quedan
   * las peores. Con `extra` (chequeo inmediato) la consulta se acota a una llave.
   */
  private async buscarCandidatos(
    dimensiones: Dimension[] = DIMENSIONES,
    extra: object[] = [],
  ): Promise<Map<string, Candidato[]>> {
    const aggs: Record<string, object> = {};
    for (const dimension of dimensiones) {
      aggs[dimension.tipo] = {
        terms: {
          field: dimension.campo,
          min_doc_count: NotasIncoherentesDetectorService.MIN_CONTRADICTORIAS,
          size: NotasIncoherentesDetectorService.MAX_CANDIDATOS,
          order: { contradictorias: 'desc' },
        },
        aggs: {
          contradictorias: { filter: CONTRADICTORIA },
          pasan: {
            bucket_selector: {
              buckets_path: { c: 'contradictorias._count', t: '_count' },
              script: `params.c >= ${NotasIncoherentesDetectorService.MIN_CONTRADICTORIAS} && params.c * 100 >= params.t * ${dimension.porcentajeMinimo}`,
            },
          },
        },
      };
    }

    const respuesta = await elasticClient.search({
      index: INDICE,
      size: 0,
      query: { bool: { filter: [...this.filtroBase(), ...extra] } },
      aggs,
    });

    const resultado = new Map<string, Candidato[]>();
    for (const dimension of dimensiones) {
      const agregado = respuesta.aggregations?.[dimension.tipo] as
        { buckets: Candidato[] } | undefined;
      resultado.set(dimension.tipo, agregado?.buckets ?? []);
    }
    return resultado;
  }

  /** Devuelve 1 si la senal quedo registrada, 0 si no. */
  private async registrar(
    dimension: Dimension,
    candidato: Candidato,
    versionModelo: string,
  ): Promise<number> {
    const respuesta = await elasticClient.search<DocumentoResena>({
      index: INDICE,
      size: NotasIncoherentesDetectorService.MAX_EVIDENCIA,
      sort: [{ fecha_publicacion: 'desc' }],
      _source: ['id_resena'],
      query: {
        bool: {
          filter: [
            ...this.filtroBase(),
            CONTRADICTORIA,
            { term: { [dimension.campo]: candidato.key } },
          ],
        },
      },
    });
    const idsResenas = respuesta.hits.hits
      .map((hit) => hit._source?.id_resena)
      .filter((id): id is number => typeof id === 'number')
      .sort((a, b) => a - b);

    const contradictorias = candidato.contradictorias.doc_count;
    const analizadas = candidato.doc_count;
    const esProducto = dimension.campo === 'id_producto';
    try {
      await registrarAnilloFraude({
        tipo: dimension.tipo,
        // Un id de producto no es una cuenta: con la "p" `registrarAnilloFraude`
        // no lo toma por una y no inserta una cuenta que no existe.
        clave: esProducto ? `p${candidato.key}` : String(candidato.key),
        resenas: idsResenas,
        productos: esProducto ? [candidato.key] : undefined,
        detalle: {
          contradictorias,
          resenas_valoradas: analizadas,
          porcentaje: Math.round((contradictorias / analizadas) * 1000) / 10,
          porcentaje_minimo: dimension.porcentajeMinimo,
          min_contradictorias:
            NotasIncoherentesDetectorService.MIN_CONTRADICTORIAS,
          largo_minimo: LARGO_MINIMO_VALORACION,
          ventana_dias: NotasIncoherentesDetectorService.VENTANA_DIAS,
          modelo: versionModelo,
        },
      });
    } catch (error) {
      this.logger.warn(
        `no se pudo persistir la senal ${dimension.tipo} de ${dimension.campo}=${candidato.key}: ${mensajeCorto(error)}`,
      );
      return 0;
    }
    return 1;
  }
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
