import type { WithId } from 'mongodb';
import type { EventoAutenticacion } from '../../models/evento-autenticacion';

/**
 * Arma el documento que va al indice `mesh_eventos_autenticacion` de
 * Elasticsearch a partir del evento de MongoDB.
 *
 * El `_id` de Mongo se usa aparte como `_id` del documento en Elastic (ver
 * `EventosAutenticacionSyncService`), asi que aca no va. La bandera
 * `pendiente_elastic` tampoco: es estado interno de la cola, no un dato del
 * evento. Todo lo demas pasa tal cual; `fecha` se serializa a ISO 8601, que
 * es lo que espera un campo `date` de Elastic.
 *
 * Si algun dia el ETL de carga inicial (`etl/`, del companero) arma este
 * documento por su lado, las dos formas tienen que coincidir campo a campo.
 */
export function aDocumentoElastic(
  evento: WithId<EventoAutenticacion>,
): Record<string, unknown> {
  return {
    tipo: evento.tipo,
    resultado: evento.resultado,
    motivo: evento.motivo,
    id_usuario: evento.id_usuario,
    identificador_intentado: evento.identificador_intentado,
    ip: evento.ip,
    user_agent: evento.user_agent,
    huella_cliente: evento.huella_cliente,
    fecha: evento.fecha.toISOString(),
  };
}
