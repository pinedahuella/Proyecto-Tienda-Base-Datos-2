import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import type { estypes } from '@elastic/elasticsearch';
import { pool } from '../../database/postgres';
import { elasticClient } from '../../database/elastic';
import { esFalloDeConexion } from '../../helpers/manejar-error-db';
import { expresionPrecioFinal } from '../../helpers/precio-descuento';
import type { DocumentoOferta } from '../../dto/buscar-ofertas';
import { PercolarSeguimientosService } from '../compradores/percolar-seguimientos.service';

export const INDICE_OFERTAS =
  process.env.ELASTIC_INDICE_OFERTAS ?? 'mesh_ofertas';

/** Una fila pendiente de `evento_oferta`. `fecha` va como texto para no perder microsegundos. */
interface EventoPendiente {
  id_evento: string;
  id_oferta: string;
  fecha: string;
}

/** Una oferta con lo que va en su documento. Los numeric llegan como texto. */
interface FilaOferta {
  id_oferta: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  nombre_producto: string | null;
  nombre_variante: string | null;
  estado_variante: string | null;
  id_usuario: string;
  usuario: string;
  nombre: string;
  apellido: string | null;
  estado_vendedor: string;
  precio: string;
  porcentaje_descuento: string | null;
  precio_final: string;
  stock: number;
  estado: string;
}

/**
 * El worker que mantiene al dia el indice de ofertas (Elasticsearch,
 * `mesh_ofertas`), el que consulta `GET /vendedor/ofertas/buscar`. Vacia la
 * cola `evento_oferta`, que llenan los triggers de `oferta`,
 * `producto_catalogo`, `variante_catalogo` y `usuarios` en la misma
 * transaccion del cambio. Ver `elementos Generales/plan pendiente/evento-oferta.md`.
 *
 * Como `EventoComentarioSyncService`, no guarda "alta" ni "baja" en el
 * evento: mira si la oferta todavia existe. Existe -> se indexa tal como esta
 * hoy en PostgreSQL; no existe -> se borra su documento.
 *
 * El indice lo crea `elastic/` (el mapping esta en
 * `plan pendiente/ofertas-indice.json`). Si no existe, la corrida se salta:
 * indexar sobre un indice que no esta lo crearia con un mapping adivinado.
 *
 * Mismo patron que `EventoProductoSyncService`: `@Interval` con una bandera
 * para que una corrida lenta no se pise con la siguiente, y la fila se marca
 * procesada solo si `fecha` sigue siendo la que se leyo. Las escrituras van
 * en un solo `bulk`, pero cada oferta se anota por separado: una que falla
 * suma `intentos` y no frena a las demas.
 *
 * Despues de indexar, pasa las ofertas por el percolator de los seguimientos
 * del comprador (`PercolarSeguimientosService`): es el momento en que una
 * oferta llega o baja de precio.
 */
@Injectable()
export class EventoOfertaSyncService {
  private readonly logger = new Logger(EventoOfertaSyncService.name);

  private static readonly INTERVALO_MS = 5000;

  /** Tope por corrida: si hay mas pendientes, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 500;

  /**
   * Fallos (que no sean de conexion) tras los cuales una oferta se aparta:
   * deja de reintentarse hasta que un cambio nuevo la reactive (el trigger
   * pone `intentos` en 0), para que no frene a las demas.
   */
  private static readonly MAX_INTENTOS = 5;

  private procesando = false;

  /** Para avisar una sola vez, y no cada 5 s, que falta el indice. */
  private avisoSinIndice = false;

  constructor(
    private readonly percolarSeguimientos: PercolarSeguimientosService,
  ) {}

  @Interval('evento-oferta', EventoOfertaSyncService.INTERVALO_MS)
  async sincronizar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      const { rows: eventos } = await pool.query<EventoPendiente>(
        `SELECT id_evento, id_oferta, fecha::text AS fecha
           FROM evento_oferta
          WHERE procesado_en IS NULL AND intentos < $1
          ORDER BY id_evento
          LIMIT $2`,
        [
          EventoOfertaSyncService.MAX_INTENTOS,
          EventoOfertaSyncService.MAX_POR_CORRIDA,
        ],
      );
      if (eventos.length === 0) {
        return;
      }

      if (!(await elasticClient.indices.exists({ index: INDICE_OFERTAS }))) {
        if (!this.avisoSinIndice) {
          this.logger.warn(
            `worker de ofertas: no existe el indice ${INDICE_OFERTAS}, las ofertas quedan pendientes`,
          );
          this.avisoSinIndice = true;
        }
        return;
      }
      this.avisoSinIndice = false;

      const filas = await this.leerOfertas(eventos.map((e) => e.id_oferta));

      const operaciones: (estypes.BulkOperationContainer | DocumentoOferta)[] =
        [];
      const documentos = new Map<string, DocumentoOferta>();
      for (const evento of eventos) {
        const fila = filas.get(evento.id_oferta);
        if (fila == null) {
          operaciones.push({
            delete: { _index: INDICE_OFERTAS, _id: evento.id_oferta },
          });
        } else {
          const documento = aDocumentoOferta(fila);
          documentos.set(evento.id_oferta, documento);
          operaciones.push(
            { index: { _index: INDICE_OFERTAS, _id: evento.id_oferta } },
            documento,
          );
        }
      }

      const respuesta = await elasticClient.bulk({ operations: operaciones });

      const hechos: EventoPendiente[] = [];
      const fallidos: { evento: EventoPendiente; motivo: string }[] = [];
      const indexados: DocumentoOferta[] = [];
      let borrados = 0;
      respuesta.items.forEach((item, i) => {
        const evento = eventos[i];
        const resultado = item.index ?? item.delete;
        // Borrar un documento que ya no estaba (404) tambien deja todo al dia.
        if (
          resultado?.error == null ||
          (item.delete && resultado.status === 404)
        ) {
          hechos.push(evento);
          if (item.delete) {
            borrados++;
          } else {
            indexados.push(documentos.get(evento.id_oferta)!);
          }
        } else {
          fallidos.push({
            evento,
            motivo: resultado.error.reason ?? resultado.error.type,
          });
        }
      });

      // Antes de marcar: si percolar falla, la corrida se corta y las ofertas
      // quedan pendientes, asi que ningun seguimiento se pierde.
      const cumplidos = await this.percolarSeguimientos.percolar(indexados);

      await this.marcarProcesados(hechos);
      await this.marcarFallidos(fallidos);

      this.logger.log(
        `worker de ofertas: ${eventos.length} evento(s), ${hechos.length - borrados} indexada(s), ${borrados} borrada(s), ${fallidos.length} con error, ${cumplidos} seguimiento(s) cumplido(s)`,
      );
    } catch (error) {
      // Elasticsearch o PostgreSQL caidos: no es culpa de las ofertas, no
      // suma intentos. Todo queda pendiente para la proxima corrida.
      this.logger.warn(
        `worker de ofertas: corrida interrumpida${esFalloDeConexion(error) ? ' (sin conexion)' : ''} -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /** Las ofertas que existen, con los nombres que viven en otras tablas. Una
   * que no sale es que se borro. */
  private async leerOfertas(ids: string[]): Promise<Map<string, FilaOferta>> {
    const { rows } = await pool.query<FilaOferta>(
      `SELECT o.id_oferta, o.id_producto_mongo, o.id_producto_variante_mongo,
              pc.nombre AS nombre_producto,
              vc.nombre_variante, vc.estado AS estado_variante,
              o.id_usuario, u.usuario, u.nombre, u.apellido,
              eu.estado_usuario_nombre AS estado_vendedor,
              o.precio, o.porcentaje_descuento,
              ${expresionPrecioFinal('o')}::text AS precio_final,
              o.stock, eo.estado_oferta_nombre AS estado
         FROM oferta o
         JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
         JOIN usuarios u ON u.id_usuario = o.id_usuario
         JOIN estado_usuario eu ON eu.id_estado_usuario = u.id_estado_usuario
         LEFT JOIN producto_catalogo pc
                ON pc.id_producto_mongo = o.id_producto_mongo
         LEFT JOIN variante_catalogo vc
                ON vc.id_producto_mongo = o.id_producto_mongo
               AND vc.id_producto_variante_mongo = o.id_producto_variante_mongo
        WHERE o.id_oferta = ANY($1::bigint[])`,
      [ids],
    );
    return new Map(rows.map((fila) => [fila.id_oferta, fila]));
  }

  /** Solo si `fecha` sigue siendo la que se leyo: si la oferta cambio
   * mientras se indexaba, la fila queda pendiente y se vuelve a hacer. */
  private async marcarProcesados(eventos: EventoPendiente[]): Promise<void> {
    if (eventos.length === 0) {
      return;
    }
    await pool.query(
      `UPDATE evento_oferta e SET procesado_en = now()
         FROM unnest($1::bigint[], $2::timestamptz[]) AS t (id, fecha)
        WHERE e.id_evento = t.id AND e.fecha = t.fecha
          AND e.procesado_en IS NULL`,
      [eventos.map((e) => e.id_evento), eventos.map((e) => e.fecha)],
    );
  }

  private async marcarFallidos(
    fallidos: { evento: EventoPendiente; motivo: string }[],
  ): Promise<void> {
    for (const { evento, motivo } of fallidos) {
      await pool.query(
        `UPDATE evento_oferta
            SET intentos = intentos + 1, ultimo_error = $2
          WHERE id_evento = $1`,
        [evento.id_evento, motivo.slice(0, 300)],
      );
      this.logger.warn(
        `worker de ofertas: fallo la oferta ${evento.id_oferta}: ${motivo}`,
      );
    }
  }
}

/**
 * El documento del indice, con la MISMA forma que el mapping de
 * `plan pendiente/ofertas-indice.json` (que es `dynamic: strict`: un campo
 * de mas hace fallar la oferta). Si cambia uno, cambian los dos.
 */
function aDocumentoOferta(fila: FilaOferta): DocumentoOferta {
  return {
    id_oferta: Number(fila.id_oferta),
    id_producto: Number(fila.id_producto_mongo),
    id_producto_variante: Number(fila.id_producto_variante_mongo),
    nombre_producto: fila.nombre_producto,
    nombre_variante: fila.nombre_variante,
    estado_variante: fila.estado_variante,
    id_vendedor: Number(fila.id_usuario),
    vendedor_usuario: fila.usuario,
    vendedor_nombre: [fila.nombre, fila.apellido]
      .filter((p) => p != null && p.trim() !== '')
      .join(' '),
    estado_vendedor: fila.estado_vendedor,
    precio: Number(fila.precio),
    porcentaje_descuento:
      fila.porcentaje_descuento == null
        ? null
        : Number(fila.porcentaje_descuento),
    precio_final: Number(fila.precio_final),
    stock: fila.stock,
    estado: fila.estado,
  };
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
