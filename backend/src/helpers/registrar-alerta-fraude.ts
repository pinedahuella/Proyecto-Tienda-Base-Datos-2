import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { ID_ESTADO_ALERTA_FRAUDE_PENDIENTE } from '../models/alerta-fraude';

/**
 * El UPSERT que deja (o engorda) una fila de `alerta_fraude`, y de paso deja
 * una fila en `notificacion_fraude` por cada cuenta a la que le corresponde
 * ver la alerta -- una alerta, N afectados, cada uno con su propio "ya la
 * vi" (`notificacion_fraude.fecha_lectura`). Compartido por los cuatro
 * servicios que escriben alertas: `FraudeLoginService` (Redis, ventana
 * truncada al minuto), `TomaCuentaService`/`ViajeImposibleService`
 * (Elasticsearch, puntuales) y `FraudeLoginRetrospectivoService`
 * (Elasticsearch, truncada a la hora -- ver ese servicio para el porque).
 *
 * La llave de conflicto de `alerta_fraude` es (tipo, clave, ventana_inicio):
 * varios cruces del umbral dentro de la misma ventana suman `contador` en
 * una sola fila en vez de duplicar; si el patron sigue en la ventana
 * siguiente, nace una fila nueva a proposito (son momentos de deteccion
 * distintos, y una alerta ya revisada no debe reabrirse silenciosamente).
 *
 * NO pisa `id_estado_alerta_fraude` en el conflicto: si un admin ya la marco
 * revisada/descartada dentro de esa misma ventana, un cruce mas del umbral
 * no debe reabrirla sola.
 *
 * Las notificaciones SOLO se crean cuando la alerta nace (INSERT), nunca
 * cuando el conflicto solo suma `contador` -- si no, cada cruce sucesivo del
 * umbral dentro de la misma ventana generaria una notificacion nueva para la
 * misma alerta. Se distingue con el truco `xmax = 0` de Postgres: en una fila
 * recien insertada `xmax` vale 0; en una fila tocada por el `DO UPDATE` del
 * `ON CONFLICT`, no.
 *
 * A quien le llega la notificacion, segun la forma de la alerta:
 *   - Si `idUsuario` viene resuelto (fuerza_bruta_cuenta, ip_rotacion_cuenta
 *     y sus `_lenta`, toma_cuenta, viaje_imposible) -- esa UNA cuenta.
 *   - Si `idUsuario` es null pero `detalle.identificadores` es una lista de
 *     texto (multi_cuenta_ip, multi_cuenta_ip_lenta -- la evidencia de que
 *     cuentas probo esa IP) -- se resuelve cada identificador contra
 *     `usuarios` y le llega a TODAS las cuentas reales que aparezcan (los
 *     identificadores que no correspondan a ninguna cuenta real, porque el
 *     intento fue contra un correo inventado, simplemente no generan fila).
 *     Es generico a proposito -- no se hardcodea el tipo de alerta, solo se
 *     mira la FORMA de `detalle` -- para que cualquier senal futura con la
 *     misma forma (una lista de identificadores en vez de una cuenta unica)
 *     quede cubierta sin tocar este archivo.
 *   - Si ninguna de las dos (fuerza_bruta_ip: fallos repetidos desde una IP,
 *     sin una lista de cuentas objetivo) -- nadie, la alerta queda solo para
 *     el panel de admin, igual que hoy.
 *
 * Todo en una sola transaccion: si la resolucion de afectados fallara, no se
 * deja la alerta a medio notificar.
 */
export async function registrarAlertaFraude(datos: {
  idTipoAlerta: number;
  clave: string;
  idUsuario: string | null;
  detalle: Record<string, unknown>;
  ventanaInicio: Date;
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    const resultado = await cliente.query<{
      id_alerta_fraude: string;
      fue_insertada: boolean;
    }>(
      `INSERT INTO alerta_fraude
         (id_tipo_alerta_fraude, clave, id_usuario, detalle, ventana_inicio,
          id_estado_alerta_fraude)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6)
       ON CONFLICT (id_tipo_alerta_fraude, clave, ventana_inicio)
       DO UPDATE SET
         contador = alerta_fraude.contador + 1,
         detalle = $4::jsonb,
         fecha_actualizacion = now()
       RETURNING id_alerta_fraude, (xmax = 0) AS fue_insertada`,
      [
        datos.idTipoAlerta,
        datos.clave,
        datos.idUsuario,
        JSON.stringify(datos.detalle),
        datos.ventanaInicio,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
      ],
    );

    const { id_alerta_fraude: idAlertaFraude, fue_insertada: fueInsertada } =
      resultado.rows[0];

    if (fueInsertada) {
      const idsUsuarioDestino = await resolverCuentasDestino(
        cliente,
        datos.idUsuario,
        datos.detalle,
      );
      for (const idUsuarioDestino of idsUsuarioDestino) {
        await cliente.query(
          `INSERT INTO notificacion_fraude (id_alerta_fraude, id_usuario)
           VALUES ($1, $2)
           ON CONFLICT (id_alerta_fraude, id_usuario) DO NOTHING`,
          [idAlertaFraude, idUsuarioDestino],
        );
      }
    }

    await cliente.query('COMMIT');
  } catch (error) {
    await cliente.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    cliente.release();
  }
}

/**
 * A que cuentas reales les corresponde una notificacion, segun la forma de
 * `detalle` -- ver el comentario de la funcion de arriba.
 */
async function resolverCuentasDestino(
  cliente: PoolClient,
  idUsuario: string | null,
  detalle: Record<string, unknown>,
): Promise<string[]> {
  if (idUsuario != null) {
    return [idUsuario];
  }

  const identificadores = detalle.identificadores;
  if (!Array.isArray(identificadores) || identificadores.length === 0) {
    return [];
  }
  const textos = identificadores.filter(
    (valor): valor is string => typeof valor === 'string',
  );
  if (textos.length === 0) {
    return [];
  }

  const { rows } = await cliente.query<{ id_usuario: string }>(
    `SELECT DISTINCT id_usuario
       FROM usuarios
      WHERE usuario = ANY($1) OR correo_electronico = ANY($1)`,
    [textos],
  );
  return rows.map((fila) => fila.id_usuario);
}
