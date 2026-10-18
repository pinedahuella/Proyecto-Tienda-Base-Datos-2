import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { modeloValoracion, valorarTexto } from '../../helpers/valoracion-texto';
import { redondear } from '../../helpers/similitud-vectores';
import { deVectorPg } from '../../helpers/vectores-pgvector';

/** Lo que se lee de una resena para valorarla. */
interface FilaPorValorar {
  id_comentario: string;
  comentario: string;
  vector: string;
  texto_hash: string;
}

/**
 * Le pone a cada resena su valoracion en `vector_comentario`: la columna
 * `valoracion_texto` (`mala`, `buena`, `dudosa` o `corta`) y `prob_mala`, la
 * probabilidad de que el texto sea malo. Asi las senales de notas
 * incoherentes (`NotasIncoherentesDetectorService`) cuentan con una agregacion
 * en vez de correr el modelo cientos de veces.
 *
 * Valora desde el VECTOR que ya esta guardado (la regresion logistica es una
 * multiplicacion de 768 numeros), asi que no llama a Ollama. Busca en cada
 * corrida las resenas raiz con vector que no tienen valoracion, o que se
 * valoraron con otra version del modelo (`valoracion_modelo`): eso cubre
 * resenas nuevas, resenas cuyo texto cambio (`EventoComentarioSyncService`
 * borra la valoracion al recalcular el vector), y un cambio de modelo, de
 * umbrales o de largo minimo.
 *
 * Solo las raices: las respuestas no llevan estrellas, no hay nada que
 * contradecir.
 *
 * Si el vector cambia mientras se valora, el `UPDATE` exige el mismo
 * `texto_hash` que se leyo y no toca la fila: se salta y la proxima corrida la
 * toma con su vector nuevo. Mismo molde que `EventoComentarioSyncService`:
 * `@Interval` con una bandera para que una corrida lenta no se pise con la
 * siguiente.
 */
@Injectable()
export class ValoracionComentariosService {
  private readonly logger = new Logger(ValoracionComentariosService.name);

  private static readonly INTERVALO_MS = 30000;

  /** Resenas por pasada, y pasadas por corrida: si hay mas pendientes, siguen
   * en la proxima. */
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
   * valoracion ya esta guardada. La llama el chequeo inmediato de una resena
   * recien escrita (`ChequeoTextoInmediatoService`), despues de calcular su
   * vector. Si ya hay una pasada en curso, espera a que termine y hace OTRA. No
   * lanza: un fallo se loguea y lo toma la proxima pasada del reloj.
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
        // Sin valorar o con otra version: `valoracion_modelo` es NULL justo
        // cuando falta la valoracion.
        const { rows } = await pool.query<FilaPorValorar>(
          `SELECT v.id_comentario, c.comentario, v.vector::text AS vector,
                  v.texto_hash
             FROM vector_comentario v
             JOIN resena r ON r.id_comentario = v.id_comentario
             JOIN comentario c ON c.id_comentario = v.id_comentario
            WHERE v.valoracion_modelo IS DISTINCT FROM $1
            ORDER BY v.id_comentario
            LIMIT $2`,
          [modelo.version, ValoracionComentariosService.LOTE],
        );
        if (rows.length === 0) {
          break;
        }

        const valoraciones = rows.map((fila) => {
          const { valoracion, probMala } = valorarTexto(
            modelo,
            fila.comentario,
            deVectorPg(fila.vector),
          );
          return {
            fila,
            valoracion,
            probMala: probMala == null ? null : redondear(probMala),
          };
        });
        const { rowCount } = await pool.query(
          `UPDATE vector_comentario v
              SET valoracion_texto = t.valoracion,
                  prob_mala = t.prob_mala,
                  valoracion_modelo = $5
             FROM unnest($1::bigint[], $2::text[], $3::numeric[], $4::text[])
                    AS t (id_comentario, valoracion, prob_mala, texto_hash)
            WHERE v.id_comentario = t.id_comentario
              AND v.texto_hash = t.texto_hash`,
          [
            valoraciones.map((x) => x.fila.id_comentario),
            valoraciones.map((x) => x.valoracion),
            valoraciones.map((x) => x.probMala),
            valoraciones.map((x) => x.fila.texto_hash),
            modelo.version,
          ],
        );
        const enEstaPasada = rowCount ?? 0;
        valoradas += enEstaPasada;
        saltadas += rows.length - enEstaPasada;
        // Si todo lo de esta pasada se salto, otra pasada traeria lo mismo: se
        // deja para la proxima corrida.
        if (enEstaPasada === 0) {
          break;
        }
        if (rows.length < ValoracionComentariosService.LOTE) {
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
