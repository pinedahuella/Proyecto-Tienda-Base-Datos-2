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
import type { TipoAnilloFraude } from '../../models/anillo-fraude';

const MS_POR_DIA = 24 * 60 * 60 * 1000;

/** Una resena del vendedor o producto, con lo que necesita este detector. */
interface FilaResena {
  id_resena: string;
  id_comentario: string;
  id_usuario: string;
  comentario: string;
  fecha_publicacion: Date;
}

/** Una resena lista para compararla con las demas del mismo vendedor/producto. */
interface ResenaParaComparar {
  idResena: number;
  idComentario: number;
  idUsuario: number;
  fecha: number;
}

/** Sobre quien se cuenta: un vendedor o un producto. */
interface Dimension {
  tipo: Extract<
    TipoAnilloFraude,
    'resenas_parecidas_vendedor' | 'resenas_parecidas_producto'
  >;
  /** Como se nombra en los logs. */
  campo: 'id_vendedor' | 'id_producto';
  /** La columna de `resena` por la que se agrupa. */
  columna: 'id_usuario_vendedor' | 'id_producto_mongo';
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
    columna: 'id_usuario_vendedor',
    porcentajeMinimo: 20,
  },
  {
    tipo: 'resenas_parecidas_producto',
    campo: 'id_producto',
    columna: 'id_producto_mongo',
    porcentajeMinimo: 40,
  },
];

/**
 * Detecta vendedores y productos cuyas resenas son, en buena parte, copias de
 * resenas de OTRAS cuentas: la firma de resenas automatizadas o hechas con una
 * plantilla. Son dos senales de la familia `patron_resenas`, fuente `elastic`
 * (el nombre que el catalogo de senales le da al texto de las resenas):
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
 * `UMBRAL_COSENO` o mas entre sus vectores (lo calcula PostgreSQL, pgvector) y
 * no mas de `DIAS_ENTRE_RESENAS` dias de diferencia. Las de la misma cuenta no
 * cuentan: esa repeticion es la senal `resenas_repetidas`, de la cuenta. Y no
 * se encadena (cada resena cuenta solo si tiene su propia gemela) para que un
 * grupo grande no infle el porcentaje.
 *
 * El porcentaje es resenas con gemela sobre las analizadas: raiz, de los
 * ultimos `VENTANA_DIAS`, con vector (`vector_comentario`) y de al menos
 * `MIN_CARACTERES` caracteres (el mismo largo que las demas senales de texto).
 * La comparacion es de todas contra todas, con tope de `MAX_RESENAS` por
 * vendedor o producto (las mas recientes).
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
        for (const clave of candidatos) {
          senales += await this.revisar(dimension, clave);
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
   * cuando ya tiene su vector. Mira solo el vendedor y el producto de esa reseña, y
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

  /** Los vendedores o productos con al menos `MIN_RESENAS` resenas con vector
   * en la ventana: con menos no pueden llegar a la regla. Los de mas resenas
   * primero. */
  private async candidatos(dimension: Dimension): Promise<number[]> {
    const { rows } = await pool.query<{ llave: string }>(
      `SELECT r.${dimension.columna} AS llave
         FROM resena r
         JOIN comentario c ON c.id_comentario = r.id_comentario
         JOIN vector_comentario v ON v.id_comentario = r.id_comentario
        WHERE c.fecha_publicacion >= now() - make_interval(days => $1)
        GROUP BY r.${dimension.columna}
       HAVING count(*) >= $2
        ORDER BY count(*) DESC, r.${dimension.columna}
        LIMIT $3`,
      [
        ResenasParecidasDetectorService.VENTANA_DIAS,
        ResenasParecidasDetectorService.MIN_RESENAS,
        ResenasParecidasDetectorService.MAX_CANDIDATOS,
      ],
    );
    return rows.map((fila) => Number(fila.llave));
  }

  /**
   * Devuelve 1 si el vendedor o producto quedo como senal, 0 si no. Con
   * `idResenaNueva` (chequeo inmediato) corta antes de la cuenta completa si esa
   * reseña no se analiza o no tiene gemela.
   */
  private async revisar(
    dimension: Dimension,
    clave: number,
    idResenaNueva?: number,
  ): Promise<number> {
    const { rows } = await pool.query<FilaResena>(
      `SELECT r.id_resena, r.id_comentario, r.id_usuario, c.comentario,
              c.fecha_publicacion
         FROM resena r
         JOIN comentario c ON c.id_comentario = r.id_comentario
         JOIN vector_comentario v ON v.id_comentario = r.id_comentario
        WHERE r.${dimension.columna} = $1
          AND c.fecha_publicacion >= now() - make_interval(days => $2)
        ORDER BY c.fecha_publicacion DESC
        LIMIT $3`,
      [
        clave,
        ResenasParecidasDetectorService.VENTANA_DIAS,
        ResenasParecidasDetectorService.MAX_RESENAS,
      ],
    );

    const resenas: ResenaParaComparar[] = rows
      .filter(
        (fila) =>
          fila.comentario.trim().length >=
          ResenasParecidasDetectorService.MIN_CARACTERES,
      )
      .map((fila) => ({
        idResena: Number(fila.id_resena),
        idComentario: Number(fila.id_comentario),
        idUsuario: Number(fila.id_usuario),
        fecha: fila.fecha_publicacion.getTime(),
      }));
    if (resenas.length < ResenasParecidasDetectorService.MIN_RESENAS) {
      return 0;
    }

    // Gemelas: se parecen (lo dice PostgreSQL), son de cuentas distintas (una
    // cuenta repetida es la senal de la cuenta) y se escribieron con pocos dias
    // de diferencia.
    const msEntre =
      ResenasParecidasDetectorService.DIAS_ENTRE_RESENAS * MS_POR_DIA;
    const pares = (
      await paresParecidos(
        resenas.map((r) => r.idComentario),
        ResenasParecidasDetectorService.UMBRAL_COSENO,
      )
    ).filter(
      ({ a, b }) =>
        resenas[a].idUsuario !== resenas[b].idUsuario &&
        Math.abs(resenas[a].fecha - resenas[b].fecha) <= msEntre,
    );

    if (idResenaNueva != null) {
      const nueva = resenas.findIndex((r) => r.idResena === idResenaNueva);
      if (nueva < 0 || !pares.some((p) => p.a === nueva || p.b === nueva)) {
        return 0;
      }
    }

    const { conGemela, similitudes } = marcarConGemela(resenas.length, pares);
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
