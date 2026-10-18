import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';
import {
  marcarConGemela,
  media,
  redondear,
} from '../../helpers/similitud-vectores';
import { LARGO_MINIMO_VALORACION } from '../../helpers/valoracion-texto';
import { paresParecidos } from '../../helpers/vectores-pgvector';

/** Una resena de la cuenta, con lo que necesita este detector. */
interface FilaResena {
  id_resena: string;
  id_comentario: string;
  comentario: string;
  tiene_vector: boolean;
}

/** Una resena de la cuenta que entra a la comparacion. */
interface ResenaAnalizada {
  idResena: number;
  idComentario: number;
}

/**
 * Detecta cuentas que escribieron muchas resenas casi iguales: la senal de un
 * bot, o de alguien que copia y pega la misma resena. Es la senal
 * `resenas_repetidas` de la familia `patron_resenas`. Ver
 * `elementos Generales/plan pendiente/resenas-repetidas.md`.
 *
 * El vector de cada resena ya esta en `vector_comentario` (pgvector,
 * `EventoComentarioSyncService`). Aca solo se LEE:
 *
 * 1. Se sacan las cuentas con `MIN_RESENAS` o mas resenas en la ventana (sin
 *    contar las respuestas a otras resenas).
 * 2. De cada una se traen sus resenas, y se descartan las que no tienen vector
 *    y las de menos de `MIN_CARACTERES`: un "Excelente producto" lo escribe
 *    cualquiera.
 * 3. PostgreSQL las compara todas contra todas (coseno) y cada resena que tiene
 *    una "gemela" suya (otra de la misma cuenta con coseno de `UMBRAL_COSENO` o
 *    mas) se marca. No se encadena: cada una cuenta solo si tiene su propia
 *    gemela.
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
      for (const idUsuario of cuentas) {
        senales += await this.revisarCuenta(idUsuario);
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

  /**
   * El chequeo de UNA reseña recien escrita: la llama `ChequeoTextoInmediatoService`
   * cuando ya tiene su vector. Solo mira a su autor, y solo hace la cuenta completa
   * si la reseña nueva tiene una gemela: sin ella, el porcentaje de la cuenta no
   * pudo subir y no hay nada nuevo que evaluar. Un error se loguea; lo recoge la
   * proxima pasada de `detectar()`.
   */
  async revisarInmediato(idUsuario: number, idResena: number): Promise<void> {
    try {
      await this.revisarCuenta(idUsuario, idResena);
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de resenas repetidas interrumpido (resena ${idResena}): ${mensajeCorto(error)}`,
      );
    }
  }

  /** Las cuentas con al menos `MIN_RESENAS` resenas en la ventana, las de mas
   * resenas primero. */
  private async cuentasCandidatas(): Promise<number[]> {
    const { rows } = await pool.query<{ id_usuario: string }>(
      `SELECT r.id_usuario
         FROM resena r
         JOIN comentario c ON c.id_comentario = r.id_comentario
        WHERE c.fecha_publicacion >= now() - make_interval(days => $1)
        GROUP BY r.id_usuario
       HAVING count(*) >= $2
        ORDER BY count(*) DESC, r.id_usuario
        LIMIT $3`,
      [
        ResenasRepetidasDetectorService.VENTANA_DIAS,
        ResenasRepetidasDetectorService.MIN_RESENAS,
        ResenasRepetidasDetectorService.MAX_CUENTAS,
      ],
    );
    return rows.map((fila) => Number(fila.id_usuario));
  }

  /**
   * Devuelve 1 si la cuenta quedo como senal, 0 si no. Con `idResenaNueva`
   * (chequeo inmediato) corta antes de la cuenta completa si esa reseña no se
   * analiza (corta, sin vector) o no tiene gemela.
   */
  private async revisarCuenta(
    idUsuario: number,
    idResenaNueva?: number,
  ): Promise<number> {
    const { rows } = await pool.query<FilaResena>(
      `SELECT r.id_resena, r.id_comentario, c.comentario,
              EXISTS (SELECT 1 FROM vector_comentario v
                       WHERE v.id_comentario = r.id_comentario) AS tiene_vector
         FROM resena r
         JOIN comentario c ON c.id_comentario = r.id_comentario
        WHERE r.id_usuario = $1
          AND c.fecha_publicacion >= now() - make_interval(days => $2)
        ORDER BY c.fecha_publicacion DESC
        LIMIT $3`,
      [
        idUsuario,
        ResenasRepetidasDetectorService.VENTANA_DIAS,
        ResenasRepetidasDetectorService.MAX_RESENAS_POR_CUENTA,
      ],
    );

    const resenas: ResenaAnalizada[] = rows
      .filter(
        (fila) =>
          fila.tiene_vector &&
          fila.comentario.trim().length >=
            ResenasRepetidasDetectorService.MIN_CARACTERES,
      )
      .map((fila) => ({
        idResena: Number(fila.id_resena),
        idComentario: Number(fila.id_comentario),
      }));
    if (resenas.length < ResenasRepetidasDetectorService.MIN_RESENAS) {
      return 0;
    }

    // Una resena se marca si tiene una gemela: otra con coseno sobre el umbral.
    const pares = await paresParecidos(
      resenas.map((r) => r.idComentario),
      ResenasRepetidasDetectorService.UMBRAL_COSENO,
    );

    if (idResenaNueva != null) {
      const nueva = resenas.findIndex((r) => r.idResena === idResenaNueva);
      if (nueva < 0 || !pares.some((p) => p.a === nueva || p.b === nueva)) {
        return 0;
      }
    }

    const { conGemela, similitudes } = marcarConGemela(resenas.length, pares);
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
