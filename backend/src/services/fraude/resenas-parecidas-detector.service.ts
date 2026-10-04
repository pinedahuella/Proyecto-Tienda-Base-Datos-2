import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { elasticClient } from '../../database/elastic';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';
import {
  cosenoEntre,
  marcarConGemela,
  media,
  norma,
  redondear,
  VectorConNorma,
} from '../../helpers/similitud-vectores';
import { LARGO_MINIMO_VALORACION } from '../../helpers/valoracion-texto';
import type { TipoAnilloFraude } from '../../models/anillo-fraude';

const INDICE = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

const MS_POR_DIA = 24 * 60 * 60 * 1000;

/** Un documento de `mesh_comentarios`, con lo que necesita este detector. */
interface DocumentoComentario {
  id_resena: number;
  id_usuario: number;
  comentario: string;
  fecha_publicacion: string;
  vector?: number[];
}

/** Una resena lista para compararla con las demas del mismo vendedor/producto. */
interface ResenaParaComparar extends VectorConNorma {
  idResena: number;
  idUsuario: number;
  fecha: number;
}

interface Candidato {
  key: number;
}

/** Sobre quien se cuenta: un vendedor o un producto. */
interface Dimension {
  tipo: Extract<
    TipoAnilloFraude,
    'resenas_parecidas_vendedor' | 'resenas_parecidas_producto'
  >;
  /** El campo de `mesh_comentarios` por el que se agrupa. */
  campo: 'id_vendedor' | 'id_producto';
  /** Que parte de sus resenas analizadas deben tener una gemela de otra cuenta. */
  porcentajeMinimo: number;
}

/**
 * Vendedor al 20 %, producto al 40 % -- los mismos porcentajes que las notas
 * incoherentes. Valores de partida, a calibrar con datos reales.
 */
const DIMENSIONES: Dimension[] = [
  {
    tipo: 'resenas_parecidas_vendedor',
    campo: 'id_vendedor',
    porcentajeMinimo: 20,
  },
  {
    tipo: 'resenas_parecidas_producto',
    campo: 'id_producto',
    porcentajeMinimo: 40,
  },
];

/**
 * Detecta vendedores y productos cuyas resenas son, en buena parte, copias de
 * resenas de OTRAS cuentas: la firma de resenas automatizadas o hechas con una
 * plantilla. Son dos senales de la familia `patron_resenas`, fuente `elastic`:
 *
 * - `resenas_parecidas_vendedor`: el 20 % o mas de las resenas de sus productos.
 * - `resenas_parecidas_producto`: el 40 % o mas de las resenas del producto.
 *
 * Ambas piden ademas `MIN_RESENAS` o mas resenas con gemela, y son solo ALERTA
 * para el admin (`GET /admin/fraude/alertas-resenas`): no forman casos ni suman
 * puntos (`TIPOS_SOLO_ALERTA` en `HallazgoFraudeAdaptadorService`). El vendedor
 * y el producto pueden ser tanto quien compra resenas como la victima de una
 * campana.
 *
 * Una resena tiene "gemela" si existe otra, de OTRA cuenta, con coseno de
 * `UMBRAL_COSENO` o mas entre sus vectores y no mas de `DIAS_ENTRE_RESENAS`
 * dias de diferencia. Las de la misma cuenta no cuentan: esa repeticion es la
 * senal `resenas_repetidas`, de la cuenta. Y no se encadena (cada resena cuenta
 * solo si tiene su propia gemela) para que un grupo grande no infle el
 * porcentaje.
 *
 * El porcentaje es resenas con gemela sobre las analizadas: raiz, de los
 * ultimos `VENTANA_DIAS`, con vector y de al menos `MIN_CARACTERES` caracteres
 * (el mismo largo que las demas senales de texto). Todo sale de
 * `mesh_comentarios`, que ya trae cuenta, vendedor, producto y fecha: no se
 * consulta PostgreSQL. La comparacion es de todas contra todas, con tope de
 * `MAX_RESENAS` por vendedor o producto (las mas recientes).
 *
 * Mismo molde que `ResenasRepetidasDetectorService`: `@Interval`, bandera
 * `procesando` y un error de conexion se loguea y no tumba el proceso.
 */
@Injectable()
export class ResenasParecidasDetectorService {
  private readonly logger = new Logger(ResenasParecidasDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Solo cuentan las resenas de los ultimos dias. Igual que las demas senales
   * de texto. */
  private static readonly VENTANA_DIAS = 180;

  /** Resenas con gemela que hacen falta, ademas del porcentaje. Tambien es el
   * minimo de resenas analizadas. */
  private static readonly MIN_RESENAS = 5;

  /** Una resena de menos caracteres que esto no cuenta. */
  private static readonly MIN_CARACTERES = LARGO_MINIMO_VALORACION;

  /** Coseno desde el cual dos resenas se consideran casi iguales. */
  private static readonly UMBRAL_COSENO = 0.92;

  /** Dos resenas solo son gemelas si se escribieron con tan pocos dias de
   * diferencia: una frase comun a lo largo de meses es otra cosa. */
  private static readonly DIAS_ENTRE_RESENAS = 30;

  /** Tope de resenas que se comparan por vendedor o producto (las mas
   * recientes): la comparacion es de todas contra todas. */
  private static readonly MAX_RESENAS = 1000;

  private static readonly MAX_CANDIDATOS = 1000;

  /** Tope de resenas que se guardan como evidencia de una senal. */
  private static readonly MAX_EVIDENCIA = 100;

  private procesando = false;

  @Interval(
    'resenas-parecidas-detector',
    ResenasParecidasDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const resumen: string[] = [];
      for (const dimension of DIMENSIONES) {
        const candidatos = await this.candidatos(dimension);
        let senales = 0;
        for (const candidato of candidatos) {
          senales += await this.revisar(dimension, candidato.key);
        }
        resumen.push(
          `${candidatos.length} ${dimension.campo} revisados, ${senales} senal(es)`,
        );
      }
      this.logger.log(`worker de resenas parecidas: ${resumen.join('; ')}`);
    } catch (error) {
      this.logger.warn(
        `worker de resenas parecidas interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * El chequeo de UNA reseña recien escrita: la llama `ChequeoTextoInmediatoService`
   * cuando ya esta indexada. Mira solo el vendedor y el producto de esa reseña, y
   * solo hace la cuenta completa si la reseña nueva tiene una gemela de otra
   * cuenta: sin ella el porcentaje no pudo subir. Un error se loguea; lo recoge
   * la proxima pasada de `detectar()`.
   */
  async revisarInmediato(
    idVendedor: number,
    idProducto: number,
    idResena: number,
  ): Promise<void> {
    try {
      for (const dimension of DIMENSIONES) {
        const clave =
          dimension.campo === 'id_vendedor' ? idVendedor : idProducto;
        await this.revisar(dimension, clave, idResena);
      }
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de resenas parecidas interrumpido (resena ${idResena}): ${mensajeCorto(error)}`,
      );
    }
  }

  private filtroBase(): object[] {
    return [
      { term: { es_respuesta: false } },
      { exists: { field: 'vector' } },
      {
        range: {
          fecha_publicacion: {
            gte: `now-${ResenasParecidasDetectorService.VENTANA_DIAS}d`,
          },
        },
      },
    ];
  }

  /** Los vendedores o productos con al menos `MIN_RESENAS` resenas en la
   * ventana: con menos no pueden llegar a la regla. */
  private async candidatos(dimension: Dimension): Promise<Candidato[]> {
    const respuesta = await elasticClient.search({
      index: INDICE,
      size: 0,
      query: { bool: { filter: this.filtroBase() } },
      aggs: {
        candidatos: {
          terms: {
            field: dimension.campo,
            min_doc_count: ResenasParecidasDetectorService.MIN_RESENAS,
            size: ResenasParecidasDetectorService.MAX_CANDIDATOS,
          },
        },
      },
    });
    const agregado = respuesta.aggregations?.candidatos as
      { buckets: Candidato[] } | undefined;
    return agregado?.buckets ?? [];
  }

  /**
   * Devuelve 1 si el vendedor o producto quedo como senal, 0 si no. Con
   * `idResenaNueva` (chequeo inmediato) corta antes de la cuenta de todas contra
   * todas si esa reseña no se analiza o no tiene gemela.
   */
  private async revisar(
    dimension: Dimension,
    clave: number,
    idResenaNueva?: number,
  ): Promise<number> {
    const respuesta = await elasticClient.search<DocumentoComentario>({
      index: INDICE,
      size: ResenasParecidasDetectorService.MAX_RESENAS,
      sort: [{ fecha_publicacion: 'desc' }],
      _source: [
        'id_resena',
        'id_usuario',
        'comentario',
        'fecha_publicacion',
        'vector',
      ],
      query: {
        bool: {
          filter: [
            ...this.filtroBase(),
            { term: { [dimension.campo]: clave } },
          ],
        },
      },
    });

    const resenas: ResenaParaComparar[] = [];
    for (const hit of respuesta.hits.hits) {
      const fuente = hit._source;
      if (
        fuente?.vector == null ||
        fuente.comentario.trim().length <
          ResenasParecidasDetectorService.MIN_CARACTERES
      ) {
        continue;
      }
      resenas.push({
        idResena: fuente.id_resena,
        idUsuario: fuente.id_usuario,
        fecha: new Date(fuente.fecha_publicacion).getTime(),
        vector: fuente.vector,
        norma: norma(fuente.vector),
      });
    }
    if (resenas.length < ResenasParecidasDetectorService.MIN_RESENAS) {
      return 0;
    }

    const msEntre =
      ResenasParecidasDetectorService.DIAS_ENTRE_RESENAS * MS_POR_DIA;
    const sonGemelas = (
      ra: ResenaParaComparar,
      rb: ResenaParaComparar,
    ): number | null => {
      if (ra.idUsuario === rb.idUsuario) {
        return null; // una cuenta repetida es la senal de la cuenta
      }
      if (Math.abs(ra.fecha - rb.fecha) > msEntre) {
        return null;
      }
      const coseno = cosenoEntre(ra, rb);
      return coseno >= ResenasParecidasDetectorService.UMBRAL_COSENO
        ? coseno
        : null;
    };

    if (idResenaNueva != null) {
      const nueva = resenas.find((r) => r.idResena === idResenaNueva);
      if (nueva == null || !resenas.some((r) => sonGemelas(nueva, r) != null)) {
        return 0;
      }
    }

    const { conGemela, similitudes } = marcarConGemela(resenas.length, (a, b) =>
      sonGemelas(resenas[a], resenas[b]),
    );
    // `resenas` viene de la mas reciente a la mas vieja: la evidencia se queda
    // con las mas recientes.
    const marcadas = resenas.filter((_, i) => conGemela[i]);
    if (
      marcadas.length < ResenasParecidasDetectorService.MIN_RESENAS ||
      marcadas.length * 100 < resenas.length * dimension.porcentajeMinimo
    ) {
      return 0;
    }

    const esProducto = dimension.campo === 'id_producto';
    try {
      await registrarAnilloFraude({
        tipo: dimension.tipo,
        // Un id de producto no es una cuenta: con la "p" `registrarAnilloFraude`
        // no lo toma por una y no inserta una cuenta que no existe.
        clave: esProducto ? `p${clave}` : String(clave),
        resenas: marcadas
          .slice(0, ResenasParecidasDetectorService.MAX_EVIDENCIA)
          .map((r) => r.idResena)
          .sort((a, b) => a - b),
        productos: esProducto ? [clave] : undefined,
        detalle: {
          resenas_con_gemela: marcadas.length,
          resenas_analizadas: resenas.length,
          porcentaje:
            Math.round((marcadas.length / resenas.length) * 1000) / 10,
          porcentaje_minimo: dimension.porcentajeMinimo,
          min_resenas: ResenasParecidasDetectorService.MIN_RESENAS,
          cuentas_con_gemela: new Set(marcadas.map((r) => r.idUsuario)).size,
          similitud_media: redondear(media(similitudes)),
          similitud_minima: redondear(Math.min(...similitudes)),
          umbral_coseno: ResenasParecidasDetectorService.UMBRAL_COSENO,
          min_caracteres: ResenasParecidasDetectorService.MIN_CARACTERES,
          dias_entre_resenas:
            ResenasParecidasDetectorService.DIAS_ENTRE_RESENAS,
          ventana_dias: ResenasParecidasDetectorService.VENTANA_DIAS,
        },
      });
    } catch (error) {
      this.logger.warn(
        `no se pudo persistir la senal ${dimension.tipo} de ${dimension.campo}=${clave}: ${mensajeCorto(error)}`,
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
