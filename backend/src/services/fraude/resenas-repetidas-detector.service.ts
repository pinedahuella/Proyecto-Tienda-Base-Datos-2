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

const INDICE = process.env.ELASTIC_INDICE_COMENTARIOS ?? 'mesh_comentarios';

/** Un documento de `mesh_comentarios`, con lo que necesita este detector. */
interface DocumentoComentario {
  id_usuario: number;
  id_resena: number;
  comentario: string;
  vector?: number[];
}

/** Una resena de la cuenta, lista para compararla con las demas. */
interface ResenaConVector extends VectorConNorma {
  idResena: number;
}

interface CuentaCandidata {
  key: number;
}

/**
 * Detecta cuentas que escribieron muchas resenas casi iguales: la senal de un
 * bot, o de alguien que copia y pega la misma resena. Es la senal
 * `resenas_repetidas` de la familia `patron_resenas`. Ver
 * `elementos Generales/plan pendiente/resenas-repetidas.md`.
 *
 * El texto de cada resena ya vive, con su vector, en `mesh_comentarios`
 * (Elasticsearch, `EventoComentarioSyncService`). Aca solo se LEE:
 *
 * 1. Una agregacion saca las cuentas con `MIN_RESENAS` o mas resenas en la
 *    ventana (sin contar las respuestas a otras resenas).
 * 2. De cada una se traen sus resenas con su vector, y se descartan las de
 *    menos de `MIN_CARACTERES`: un "Excelente producto" lo escribe cualquiera.
 * 3. Se comparan todas contra todas (coseno) y cada resena que tiene una
 *    "gemela" suya (otra de la misma cuenta con coseno de `UMBRAL_COSENO` o mas)
 *    se marca. No se encadena: cada una cuenta solo si tiene su propia gemela.
 * 4. Si las marcadas son `MIN_RESENAS` o mas Y son el `PORCENTAJE_MINIMO` o mas
 *    de las resenas analizadas de la cuenta, es una senal. Porcentaje y no solo
 *    cantidad (desde 2026-10-04): quien escribe mucho repite alguna frase por
 *    casualidad; lo raro es que una parte grande de lo que escribe sea copia.
 *    Una senal por cuenta (`clave` = su id), con las resenas marcadas como
 *    evidencia.
 *
 * Mismo molde que `PatronesFraudeDetectorService`: `@Interval`, una bandera
 * para que una corrida lenta no se pise con la siguiente, y un error de
 * conexion se loguea y no tumba el proceso. La senal se persiste con el mismo
 * `registrarAnilloFraude` que los demas patrones, asi que el agrupador de
 * casos y las rutas de admin la toman sin mas cambios.
 *
 * Limite conocido: ve el texto de cada resena, no el de lo que la cuenta
 * escribe en otros sitios, y no distingue una plantilla de una frase muy
 * comun entre usuarios honestos. Por eso el largo minimo y las 5 resenas.
 */
@Injectable()
export class ResenasRepetidasDetectorService {
  private readonly logger = new Logger(ResenasRepetidasDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Solo cuentan las resenas de los ultimos dias. Misma idea que
   * `PatronesFraudeDetectorService.VENTANA_DIAS`: sin ventana, una senal de
   * hace anios seguiria "confirmandose activa" para siempre. */
  private static readonly VENTANA_DIAS = 180;

  /** Resenas con gemela que hacen falta para que una cuenta sea senal (ademas
   * del porcentaje). Tambien es el minimo de resenas analizadas. */
  private static readonly MIN_RESENAS = 5;

  /** Que parte de las resenas analizadas de la cuenta deben tener gemela. */
  private static readonly PORCENTAJE_MINIMO = 30;

  /** Una resena de menos caracteres que esto no cuenta. El mismo largo que
   * usan las demas senales de texto (desde 2026-10-04: antes 40). */
  private static readonly MIN_CARACTERES = LARGO_MINIMO_VALORACION;

  /** Coseno desde el cual dos resenas se consideran casi iguales. */
  private static readonly UMBRAL_COSENO = 0.92;

  /** Tope de resenas que se miran por cuenta (las mas recientes). */
  private static readonly MAX_RESENAS_POR_CUENTA = 500;

  private static readonly MAX_CUENTAS = 1000;

  private procesando = false;

  @Interval(
    'resenas-repetidas-detector',
    ResenasRepetidasDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const cuentas = await this.cuentasCandidatas();
      let senales = 0;
      for (const cuenta of cuentas) {
        senales += await this.revisarCuenta(cuenta.key);
      }
      this.logger.log(
        `worker de resenas repetidas: ${cuentas.length} cuenta(s) revisadas, ${senales} senal(es)`,
      );
    } catch (error) {
      this.logger.warn(
        `worker de resenas repetidas interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  private filtroBase(): object[] {
    return [
      { term: { es_respuesta: false } },
      {
        range: {
          fecha_publicacion: {
            gte: `now-${ResenasRepetidasDetectorService.VENTANA_DIAS}d`,
          },
        },
      },
    ];
  }

  /** Las cuentas con al menos `MIN_RESENAS` resenas en la ventana. */
  private async cuentasCandidatas(): Promise<CuentaCandidata[]> {
    const respuesta = await elasticClient.search({
      index: INDICE,
      size: 0,
      query: { bool: { filter: this.filtroBase() } },
      aggs: {
        cuentas: {
          terms: {
            field: 'id_usuario',
            min_doc_count: ResenasRepetidasDetectorService.MIN_RESENAS,
            size: ResenasRepetidasDetectorService.MAX_CUENTAS,
          },
        },
      },
    });
    const agregado = respuesta.aggregations?.cuentas as
      { buckets: CuentaCandidata[] } | undefined;
    return agregado?.buckets ?? [];
  }

  /** Devuelve 1 si la cuenta quedo como senal, 0 si no. */
  private async revisarCuenta(idUsuario: number): Promise<number> {
    const respuesta = await elasticClient.search<DocumentoComentario>({
      index: INDICE,
      size: ResenasRepetidasDetectorService.MAX_RESENAS_POR_CUENTA,
      sort: [{ fecha_publicacion: 'desc' }],
      _source: ['id_usuario', 'id_resena', 'comentario', 'vector'],
      query: {
        bool: {
          filter: [...this.filtroBase(), { term: { id_usuario: idUsuario } }],
        },
      },
    });

    const resenas: ResenaConVector[] = [];
    for (const hit of respuesta.hits.hits) {
      const fuente = hit._source;
      if (
        fuente?.vector == null ||
        fuente.comentario.trim().length <
          ResenasRepetidasDetectorService.MIN_CARACTERES
      ) {
        continue;
      }
      resenas.push({
        idResena: fuente.id_resena,
        vector: fuente.vector,
        norma: norma(fuente.vector),
      });
    }
    if (resenas.length < ResenasRepetidasDetectorService.MIN_RESENAS) {
      return 0;
    }

    // Una resena se marca si tiene una gemela: otra con coseno sobre el umbral.
    const { conGemela, similitudes } = marcarConGemela(
      resenas.length,
      (a, b) => {
        const coseno = cosenoEntre(resenas[a], resenas[b]);
        return coseno >= ResenasRepetidasDetectorService.UMBRAL_COSENO
          ? coseno
          : null;
      },
    );
    const marcadas = resenas.filter((_, i) => conGemela[i]);
    if (
      marcadas.length < ResenasRepetidasDetectorService.MIN_RESENAS ||
      marcadas.length * 100 <
        resenas.length * ResenasRepetidasDetectorService.PORCENTAJE_MINIMO
    ) {
      return 0;
    }

    const idsResenas = marcadas.map((r) => r.idResena).sort((a, b) => a - b);
    try {
      await registrarAnilloFraude({
        tipo: 'resenas_repetidas',
        clave: String(idUsuario),
        resenas: idsResenas,
        detalle: {
          resenas_con_gemela: marcadas.length,
          resenas_analizadas: resenas.length,
          porcentaje:
            Math.round((marcadas.length / resenas.length) * 1000) / 10,
          porcentaje_minimo: ResenasRepetidasDetectorService.PORCENTAJE_MINIMO,
          min_resenas: ResenasRepetidasDetectorService.MIN_RESENAS,
          similitud_media: redondear(media(similitudes)),
          similitud_minima: redondear(Math.min(...similitudes)),
          umbral_coseno: ResenasRepetidasDetectorService.UMBRAL_COSENO,
          min_caracteres: ResenasRepetidasDetectorService.MIN_CARACTERES,
          ventana_dias: ResenasRepetidasDetectorService.VENTANA_DIAS,
        },
      });
    } catch (error) {
      this.logger.warn(
        `no se pudo persistir la senal resenas_repetidas de la cuenta ${idUsuario}: ${mensajeCorto(error)}`,
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
