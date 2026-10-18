import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';
import {
  LARGO_MINIMO_VALORACION,
  modeloValoracion,
} from '../../helpers/valoracion-texto';
import type { TipoAnilloFraude } from '../../models/anillo-fraude';

/** La reseña recien escrita, con lo que hace falta para saber si es contradictoria. */
interface FilaNueva {
  valoracion_texto: string | null;
  calificacion: number;
  id_usuario: string;
  id_producto_mongo: string;
  id_usuario_vendedor: string;
}

/** Una cuenta, producto o vendedor que pasa la regla. */
interface Candidato {
  llave: number;
  valoradas: number;
  contradictorias: number;
}

/** Una de las tres cuentas de la regla: sobre quien se cuenta. */
interface Dimension {
  tipo: Extract<
    TipoAnilloFraude,
    | 'notas_incoherentes_cuenta'
    | 'notas_incoherentes_producto'
    | 'notas_incoherentes_vendedor'
  >;
  /** La columna de `resena` por la que se agrupa. */
  columna: 'id_usuario' | 'id_producto_mongo' | 'id_usuario_vendedor';
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
    columna: 'id_usuario',
    porcentajeMinimo: 20,
  },
  {
    tipo: 'notas_incoherentes_producto',
    columna: 'id_producto_mongo',
    porcentajeMinimo: 40,
  },
  {
    tipo: 'notas_incoherentes_vendedor',
    columna: 'id_usuario_vendedor',
    porcentajeMinimo: 20,
  },
];

/**
 * Una resena es CONTRADICTORIA si su texto dice una cosa y sus estrellas otra:
 * texto malo con 4 o 5 estrellas, o texto bueno con 1 o 2. Las 3 estrellas no
 * cuentan nunca, ni los textos `dudosos` (la franja del medio del modelo).
 * Necesita los alias `r` (`resena`) y `v` (`vector_comentario`).
 */
const SQL_CONTRADICTORIA = `((v.valoracion_texto = 'mala' AND r.calificacion >= 4)
     OR (v.valoracion_texto = 'buena' AND r.calificacion <= 2))`;

/**
 * Las resenas que cuentan: raiz, en la ventana (`$1`, en dias) y ya valoradas.
 * Las de menos de `LARGO_MINIMO_VALORACION` caracteres son `corta` y no se
 * cuentan, ni como contradictorias ni en el total.
 */
const SQL_RESENAS_VALORADAS = `resena r
       JOIN comentario c ON c.id_comentario = r.id_comentario
       JOIN vector_comentario v ON v.id_comentario = r.id_comentario
      WHERE c.fecha_publicacion >= now() - make_interval(days => $1)
        AND v.valoracion_texto IN ('mala', 'buena', 'dudosa')`;

/**
 * Detecta cuentas, productos y vendedores con muchas resenas "contradictorias"
 * (texto malo con 4-5 estrellas, o texto bueno con 1-2). Son tres senales de la
 * familia `patron_resenas`, con fuente `elastic` (el nombre que el catalogo de
 * senales le da al texto de las resenas):
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
 * Todo sale de una agregacion de PostgreSQL sobre `resena` y
 * `vector_comentario`, donde cada resena ya trae su `valoracion_texto`
 * (`ValoracionComentariosService`): el modelo no corre aca. Solo cuentan las
 * resenas raiz (las respuestas no llevan estrellas), de los ultimos
 * `VENTANA_DIAS` y con valoracion `mala`, `buena` o `dudosa` (las de menos de
 * `LARGO_MINIMO_VALORACION` caracteres son `corta` y no se cuentan, ni como
 * contradictorias ni en el total). El porcentaje es contradictorias sobre ese
 * total.
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
      const resumen: string[] = [];
      for (const dimension of DIMENSIONES) {
        let senales = 0;
        for (const candidato of await this.buscarCandidatos(dimension)) {
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
   * cuando ya tiene su vector y su valoracion. Solo si esa reseña es contradictoria
   * (una que no lo es solo puede bajar un porcentaje, no subirlo), vuelve a evaluar
   * su cuenta, su producto y su vendedor, acotando la agregacion a esas tres llaves.
   * Un error se loguea; lo recoge la proxima pasada de `detectar()`.
   */
  async detectarInmediato(idComentario: number): Promise<void> {
    try {
      const modelo = modeloValoracion();
      if (modelo == null) {
        return;
      }
      // Solo una raiz tiene resena: una respuesta no devuelve fila.
      const { rows } = await pool.query<FilaNueva>(
        `SELECT v.valoracion_texto, r.calificacion, r.id_usuario,
                r.id_producto_mongo, r.id_usuario_vendedor
           FROM resena r
           JOIN vector_comentario v ON v.id_comentario = r.id_comentario
          WHERE r.id_comentario = $1`,
        [idComentario],
      );
      const nueva = rows[0];
      if (nueva == null || !this.esContradictoria(nueva)) {
        return;
      }

      for (const dimension of DIMENSIONES) {
        const llave = Number(nueva[dimension.columna]);
        for (const candidato of await this.buscarCandidatos(dimension, llave)) {
          await this.registrar(dimension, candidato, modelo.version);
        }
      }
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de notas incoherentes interrumpido (comentario ${idComentario}): ${mensajeCorto(error)}`,
      );
    }
  }

  /** Lo mismo que `SQL_CONTRADICTORIA`, para una sola reseña ya en memoria. */
  private esContradictoria(r: FilaNueva): boolean {
    return (
      (r.valoracion_texto === 'mala' && r.calificacion >= 4) ||
      (r.valoracion_texto === 'buena' && r.calificacion <= 2)
    );
  }

  /**
   * Agrupa por cuenta, producto o vendedor, cuenta sus resenas valoradas y sus
   * contradictorias, y se queda solo con los que pasan las dos reglas.
   * Ordenados por contradictorias: si hubiera mas de `MAX_CANDIDATOS`, quedan
   * los peores. Con `llave` (chequeo inmediato) se acota a esa sola.
   */
  private async buscarCandidatos(
    dimension: Dimension,
    llave?: number,
  ): Promise<Candidato[]> {
    const { rows } = await pool.query<{
      llave: string;
      valoradas: number;
      contradictorias: number;
    }>(
      `SELECT r.${dimension.columna} AS llave,
              count(*)::int AS valoradas,
              count(*) FILTER (WHERE ${SQL_CONTRADICTORIA})::int AS contradictorias
         FROM ${SQL_RESENAS_VALORADAS}
          AND ($2::bigint IS NULL OR r.${dimension.columna} = $2)
        GROUP BY r.${dimension.columna}
       HAVING count(*) FILTER (WHERE ${SQL_CONTRADICTORIA}) >= $3
          AND count(*) FILTER (WHERE ${SQL_CONTRADICTORIA}) * 100
              >= count(*) * $4
        ORDER BY contradictorias DESC, r.${dimension.columna}
        LIMIT $5`,
      [
        NotasIncoherentesDetectorService.VENTANA_DIAS,
        llave ?? null,
        NotasIncoherentesDetectorService.MIN_CONTRADICTORIAS,
        dimension.porcentajeMinimo,
        NotasIncoherentesDetectorService.MAX_CANDIDATOS,
      ],
    );
    return rows.map((fila) => ({
      llave: Number(fila.llave),
      valoradas: fila.valoradas,
      contradictorias: fila.contradictorias,
    }));
  }

  /** Devuelve 1 si la senal quedo registrada, 0 si no. */
  private async registrar(
    dimension: Dimension,
    candidato: Candidato,
    versionModelo: string,
  ): Promise<number> {
    const { rows } = await pool.query<{ id_resena: string }>(
      `SELECT r.id_resena
         FROM ${SQL_RESENAS_VALORADAS}
          AND ${SQL_CONTRADICTORIA}
          AND r.${dimension.columna} = $2
        ORDER BY c.fecha_publicacion DESC
        LIMIT $3`,
      [
        NotasIncoherentesDetectorService.VENTANA_DIAS,
        candidato.llave,
        NotasIncoherentesDetectorService.MAX_EVIDENCIA,
      ],
    );
    const idsResenas = rows
      .map((fila) => Number(fila.id_resena))
      .sort((a, b) => a - b);

    const { contradictorias, valoradas } = candidato;
    const esProducto = dimension.columna === 'id_producto_mongo';
    try {
      await registrarAnilloFraude({
        tipo: dimension.tipo,
        // Un id de producto no es una cuenta: con la "p" `registrarAnilloFraude`
        // no lo toma por una y no inserta una cuenta que no existe.
        clave: esProducto ? `p${candidato.llave}` : String(candidato.llave),
        resenas: idsResenas,
        productos: esProducto ? [candidato.llave] : undefined,
        detalle: {
          contradictorias,
          resenas_valoradas: valoradas,
          porcentaje: Math.round((contradictorias / valoradas) * 1000) / 10,
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
        `no se pudo persistir la senal ${dimension.tipo} de ${dimension.columna}=${candidato.llave}: ${mensajeCorto(error)}`,
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
