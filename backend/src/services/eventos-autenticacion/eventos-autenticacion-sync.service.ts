import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { mongoDb } from '../../database/mongo';
import { elasticClient } from '../../database/elastic';
import type { EventoAutenticacion } from '../../models/evento-autenticacion';
import { aDocumentoElastic } from './documento-elastic';

const INDICE =
  process.env.ELASTIC_INDICE_EVENTOS ?? 'mesh_eventos_autenticacion';

const COLECCION = 'eventos_autenticacion';

/**
 * El worker que mantiene al dia el indice de Elasticsearch
 * (`mesh_eventos_autenticacion`) a partir de la bandera `pendiente_elastic`
 * de la coleccion `eventos_autenticacion` de MongoDB.
 *
 * Mismo patron que `BuscadorSyncService`, y aun mas simple: el evento de
 * autenticacion es inmutable, asi que un documento pendiente solo se indexa
 * -- nunca se re-indexa por un cambio ni se borra. El `_id` de Mongo se
 * reutiliza como `_id` en Elastic, con lo que reindexar (si la marca se
 * perdiera y se reprocesara) es idempotente.
 *
 * Esto NO es la deteccion de ataques en tiempo real: esa va con contadores
 * en Redis en el propio camino del login, sincrona, en la misma peticion.
 * Este worker alimenta la capa de consulta/analisis retrospectiva -- "IPs
 * con N fallos en 24 h", "viaje imposible en la semana", las facetas del
 * panel de admin --, donde un retraso de unos segundos no cambia nada.
 *
 * La carga inicial del indice (todo lo que ya vive en la coleccion) la hace
 * el ETL del companero (`etl/`), igual que con el buscador de catalogo. Este
 * worker solo mantiene al dia el flujo nuevo.
 *
 * Intervalo corto (5 s) a proposito: para el buscador de catalogo 10 s
 * sobra, pero aca la frescura importa mas. Es una sola constante si hay que
 * ajustarla.
 */
@Injectable()
export class EventosAutenticacionSyncService {
  private readonly logger = new Logger(EventosAutenticacionSyncService.name);

  private static readonly INTERVALO_MS = 5000;

  /** Tope por corrida: si hay mas pendientes, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 500;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval(
    'eventos-autenticacion-pendientes',
    EventosAutenticacionSyncService.INTERVALO_MS,
  )
  async sincronizar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      const coleccion = mongoDb.collection<EventoAutenticacion>(COLECCION);
      const pendientes = await coleccion
        .find({ pendiente_elastic: true })
        .sort({ fecha: 1 })
        .limit(EventosAutenticacionSyncService.MAX_POR_CORRIDA)
        .toArray();

      if (pendientes.length === 0) {
        return;
      }

      let sincronizados = 0;
      for (const evento of pendientes) {
        try {
          await elasticClient.index({
            index: INDICE,
            id: String(evento._id),
            document: aDocumentoElastic(evento),
          });
          await coleccion.updateOne(
            { _id: evento._id },
            { $unset: { pendiente_elastic: '' } },
          );
          sincronizados++;
        } catch (error) {
          // Uno fallido (Elasticsearch caido, o este documento en concreto)
          // no debe tumbar el resto del lote. Se deja `pendiente_elastic` en
          // true: se reintenta en la proxima corrida, no se pierde.
          this.logger.warn(
            `No se pudo sincronizar el evento ${String(evento._id)} con Elasticsearch: ${mensajeCorto(error)}`,
          );
        }
      }

      if (sincronizados > 0) {
        this.logger.log(
          `worker de eventos de autenticacion: ${sincronizados} evento(s) sincronizados`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `worker de eventos de autenticacion: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }
}

/** Un mensaje de error corto para el log. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
