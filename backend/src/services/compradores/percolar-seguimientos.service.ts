import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { elasticClient } from '../../database/elastic';
import type { DocumentoOferta } from '../../dto/buscar-ofertas';
import { INDICE_SEGUIMIENTOS } from './seguimientos-oferta.service';

/** Tope de seguimientos que puede cumplir un solo lote de ofertas. */
const MAXIMO_COINCIDENCIAS = 10000;

/**
 * El lado "se cumplio" de los seguimientos del comprador. Lo llama
 * `EventoOfertaSyncService` con las ofertas que acaba de indexar: las pasa
 * TODAS juntas por el percolator `mesh_seguimientos` (una sola consulta
 * `percolate` con varios documentos) y Elasticsearch responde que
 * seguimientos coinciden con cuales.
 *
 * Por cada seguimiento que coincide, UN aviso y nada mas:
 *
 *   1. En PostgreSQL, en una transaccion: se crea el aviso con la oferta mas
 *      barata de las que coincidieron, y se pone `fecha_cumplido`. El
 *      `UNIQUE (id_seguimiento)` del aviso y el `fecha_cumplido IS NULL` hacen
 *      imposible un segundo aviso aunque el seguimiento vuelva a coincidir.
 *   2. Se borra la consulta del percolator, para que no vuelva a coincidir.
 *
 * Si el paso 2 falla, la consulta sigue ahi y puede volver a coincidir: el
 * paso 1 no hace nada (ya esta cumplido) y se reintenta el borrado. Si el
 * paso 1 falla, se lanza: el worker no marca las ofertas como procesadas y
 * todo se repite en la proxima corrida.
 */
@Injectable()
export class PercolarSeguimientosService {
  private readonly logger = new Logger(PercolarSeguimientosService.name);

  /** Para avisar una sola vez, y no cada 5 s, que falta el indice. */
  private avisoSinIndice = false;

  /** Devuelve cuantos seguimientos se cumplieron. */
  async percolar(documentos: DocumentoOferta[]): Promise<number> {
    if (documentos.length === 0) {
      return 0;
    }
    if (!(await elasticClient.indices.exists({ index: INDICE_SEGUIMIENTOS }))) {
      if (!this.avisoSinIndice) {
        this.logger.warn(
          `no existe el indice ${INDICE_SEGUIMIENTOS}: los seguimientos no se revisan`,
        );
        this.avisoSinIndice = true;
      }
      return 0;
    }
    this.avisoSinIndice = false;

    const respuesta = await elasticClient.search<{ id_seguimiento: number }>({
      index: INDICE_SEGUIMIENTOS,
      size: MAXIMO_COINCIDENCIAS,
      _source: ['id_seguimiento'],
      query: { percolate: { field: 'consulta', documents: documentos } },
    });

    let cumplidos = 0;
    for (const hit of respuesta.hits.hits) {
      const idSeguimiento = hit._id;
      // `_percolator_document_slot`: las posiciones (en `documentos`) de las
      // ofertas que coincidieron con este seguimiento.
      const posiciones = (hit.fields?._percolator_document_slot ??
        []) as number[];
      const ofertas = posiciones
        .map((i) => documentos[i])
        .filter((d): d is DocumentoOferta => d != null);
      if (idSeguimiento == null || ofertas.length === 0) {
        continue;
      }
      const masBarata = ofertas.reduce((a, b) =>
        b.precio_final < a.precio_final ? b : a,
      );

      if (await this.cumplir(idSeguimiento, masBarata)) {
        cumplidos++;
      }
      await elasticClient.delete(
        { index: INDICE_SEGUIMIENTOS, id: idSeguimiento },
        { ignore: [404] },
      );
    }

    if (cumplidos > 0) {
      this.logger.log(`${cumplidos} seguimiento(s) cumplido(s)`);
    }
    return cumplidos;
  }

  /** `true` si este es el que lo cumplio; `false` si ya estaba cumplido o se borro. */
  private async cumplir(
    idSeguimiento: string,
    oferta: DocumentoOferta,
  ): Promise<boolean> {
    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      const { rowCount } = await cliente.query(
        `UPDATE seguimiento_oferta SET fecha_cumplido = now()
          WHERE id_seguimiento = $1 AND fecha_cumplido IS NULL`,
        [idSeguimiento],
      );
      if (rowCount === 0) {
        await cliente.query('ROLLBACK');
        return false;
      }
      await cliente.query(
        `INSERT INTO aviso_seguimiento_oferta (id_seguimiento, id_oferta, precio_final)
         VALUES ($1, $2, $3)
         ON CONFLICT (id_seguimiento) DO NOTHING`,
        [idSeguimiento, oferta.id_oferta, oferta.precio_final],
      );
      await cliente.query('COMMIT');
      return true;
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      throw error;
    } finally {
      cliente.release();
    }
  }
}
