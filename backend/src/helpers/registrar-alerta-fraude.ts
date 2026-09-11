import { pool } from '../database/postgres';
import { ID_ESTADO_ALERTA_FRAUDE_PENDIENTE } from '../models/alerta-fraude';

/**
 * El UPSERT que deja (o engorda) una fila de `alerta_fraude`. Compartido por
 * los tres servicios que escriben alertas: `FraudeLoginService` (Redis,
 * ventana truncada al minuto), `TomaCuentaService` (Elasticsearch, tambien
 * al minuto) y `FraudeLoginRetrospectivoService` (Elasticsearch, truncada a
 * la hora -- ver ese servicio para el porque).
 *
 * La llave de conflicto es (tipo, clave, ventana_inicio): varios cruces del
 * umbral dentro de la misma ventana suman `contador` en una sola fila en vez
 * de duplicar; si el patron sigue en la ventana siguiente, nace una fila
 * nueva a proposito (son momentos de deteccion distintos, y una alerta ya
 * revisada no debe reabrirse silenciosamente).
 *
 * NO pisa `id_estado_alerta_fraude` en el conflicto: si un admin ya la marco
 * revisada/descartada dentro de esa misma ventana, un cruce mas del umbral
 * no debe reabrirla sola.
 */
export async function registrarAlertaFraude(datos: {
  idTipoAlerta: number;
  clave: string;
  idUsuario: string | null;
  detalle: Record<string, unknown>;
  ventanaInicio: Date;
}): Promise<void> {
  await pool.query(
    `INSERT INTO alerta_fraude
       (id_tipo_alerta_fraude, clave, id_usuario, detalle, ventana_inicio,
        id_estado_alerta_fraude)
     VALUES ($1, $2, $3, $4::jsonb, $5, $6)
     ON CONFLICT (id_tipo_alerta_fraude, clave, ventana_inicio)
     DO UPDATE SET
       contador = alerta_fraude.contador + 1,
       detalle = $4::jsonb,
       fecha_actualizacion = now()`,
    [
      datos.idTipoAlerta,
      datos.clave,
      datos.idUsuario,
      JSON.stringify(datos.detalle),
      datos.ventanaInicio,
      ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
    ],
  );
}
