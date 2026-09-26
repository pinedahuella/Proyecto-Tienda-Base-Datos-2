import { pool } from '../database/postgres';
import { ID_ESTADO_ALERTA_FRAUDE_PENDIENTE } from '../models/alerta-fraude';

/**
 * El UPSERT que deja (o engorda) una fila de `hallazgo_evento_fraude`, y de
 * paso deja una fila en `hallazgo_evento_fraude_cuenta` por cada cuenta
 * involucrada -- normalizado, en vez de una lista dentro de `detalle`
 * (mismo patron que `docs/fraude-entrega3/02-reglas-backend.md` propone
 * para su `hallazgo_fraude_cuenta`, la version grande sin construir).
 *
 * La llave de conflicto de `hallazgo_evento_fraude` es
 * (tipo, clave, ventana_inicio): si el detector vuelve a encontrar el mismo
 * hallazgo dentro de la misma ventana, suma `contador` y refresca `detalle`
 * con la evidencia mas reciente en vez de duplicar la fila; si el patron
 * sigue en la ventana siguiente, nace una fila nueva a proposito (son
 * momentos de deteccion distintos). NO pisa `id_estado_alerta_fraude` en el
 * conflicto: si un admin ya marco el hallazgo revisado/descartado dentro de
 * esa misma ventana, un cruce mas del umbral no debe reabrirlo solo.
 *
 * `cuentas` se inserta SIEMPRE, tambien cuando el hallazgo ya existia (el
 * conflicto solo actualiza `hallazgo_evento_fraude`): la evidencia puede
 * crecer entre corridas, y `ON CONFLICT DO NOTHING` hace que repetir una
 * cuenta ya guardada no cueste nada. Sin cuentas (vistas_infladas, que es
 * de un producto) simplemente no inserta ninguna fila en el pivote.
 *
 * Sin notificacion a ninguna cuenta -- mismo criterio que
 * `registrarAnilloFraude`: las cuentas de un hallazgo de F1-F6 son las
 * SOSPECHOSAS, no victimas, avisarles daria oportunidad de evadir la
 * deteccion.
 */
export async function registrarHallazgoEventoFraude(datos: {
  idTipoHallazgo: number;
  clave: string;
  cuentas: string[];
  idProductoMongo: number | null;
  detalle: Record<string, unknown>;
  ventanaInicio: Date;
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    const resultado = await cliente.query<{
      id_hallazgo_evento_fraude: string;
    }>(
      `INSERT INTO hallazgo_evento_fraude
         (id_tipo_hallazgo_evento, clave, id_producto_mongo, detalle,
          ventana_inicio, id_estado_alerta_fraude)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6)
       ON CONFLICT (id_tipo_hallazgo_evento, clave, ventana_inicio)
       DO UPDATE SET
         contador = hallazgo_evento_fraude.contador + 1,
         detalle = $4::jsonb,
         fecha_actualizacion = now()
       RETURNING id_hallazgo_evento_fraude`,
      [
        datos.idTipoHallazgo,
        datos.clave,
        datos.idProductoMongo,
        JSON.stringify(datos.detalle),
        datos.ventanaInicio,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
      ],
    );
    const idHallazgo = resultado.rows[0].id_hallazgo_evento_fraude;

    for (const idUsuario of datos.cuentas) {
      await cliente.query(
        `INSERT INTO hallazgo_evento_fraude_cuenta
           (id_hallazgo_evento_fraude, id_usuario)
         VALUES ($1, $2)
         ON CONFLICT (id_hallazgo_evento_fraude, id_usuario) DO NOTHING`,
        [idHallazgo, idUsuario],
      );
    }

    await cliente.query('COMMIT');
  } catch (error) {
    await cliente.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    cliente.release();
  }
}
