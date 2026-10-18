import { isIP } from 'node:net';
import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { vincularIpASenalFraude } from './vincular-ip-a-senal-fraude';
import {
  ID_ESTADO_ALERTA_FRAUDE_DESCARTADA,
  ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
  ID_ESTADO_ALERTA_FRAUDE_REVISADA,
} from '../models/alerta-fraude';
import type { TipoHallazgoEvento } from '../models/hallazgo-evento-fraude';

/**
 * Deja (o engorda) la senal de un hallazgo de F1-F6 en `senal_fraude`, con sus
 * cuentas, productos, pedidos e IP en sus pivotes (ver
 * `registrarSenalDelHallazgo`). Desde la etapa 8 del refactor ya no escribe en
 * `hallazgo_evento_fraude` ni en `hallazgo_evento_fraude_cuenta`.
 *
 * Sin notificacion a ninguna cuenta -- mismo criterio que
 * `registrarAnilloFraude`: las cuentas de un hallazgo de F1-F6 son las
 * SOSPECHOSAS, no victimas, avisarles daria oportunidad de evadir la
 * deteccion.
 */
export async function registrarHallazgoEventoFraude(datos: {
  tipo: TipoHallazgoEvento;
  clave: string;
  cuentas: string[];
  /** Los ids de pedido de la evidencia (F2, F3 y F5), para `senal_fraude_pedido`. */
  pedidos?: string[];
  idProductoMongo: number | null;
  detalle: Record<string, unknown>;
  ventanaInicio: Date;
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    await registrarSenalDelHallazgo(cliente, datos);

    await cliente.query('COMMIT');
  } catch (error) {
    await cliente.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    cliente.release();
  }
}

/**
 * La metrica del `detalle` que dice "cuanta evidencia hay" en cada tipo. Sirve
 * para la regla de reabrir de `registrarSenalDelHallazgo`: si crece, hay
 * evidencia nueva. Las claves son las que escribe
 * `HallazgosEventoFraudeDetectorService`.
 */
const METRICA_PRINCIPAL: Record<TipoHallazgoEvento, string> = {
  vistas_infladas: 'vistas_por_sesion',
  compras_en_rafaga: 'pedidos_en_la_peor_rafaga',
  ip_multicuenta_compras: 'cuentas_distintas',
  devoluciones_seriales: 'devueltas',
  granja_de_registros: 'cuentas_en_la_peor_ventana',
};

/** Los tipos cuya `clave` es una direccion IP (F3 y F6). */
const TIPOS_CON_IP_EN_LA_CLAVE: ReadonlySet<TipoHallazgoEvento> =
  new Set<TipoHallazgoEvento>([
    'ip_multicuenta_compras',
    'granja_de_registros',
  ]);

/**
 * La escritura de la etapa 3 del refactor (ver
 * `elementos Generales/plan pendiente/refactor-fraude-senales.md`), en la
 * transaccion de `registrarHallazgoEventoFraude`.
 *
 * La senal es UNA por (tipo, clave), no una por dia: cada corrida suma 1 a
 * `total_detecciones` y refresca `detalle` y `ultima_deteccion`. Como el
 * detector mira los ultimos 30 dias en cada corrida, la evidencia de un dia
 * y la del siguiente casi coinciden; por eso no se reabre por solo volver a
 * verla.
 *
 * Regla de reabrir: una senal `revisada` o `descartada` vuelve a `pendiente`
 * SOLO si la deteccion trae evidencia nueva -- una cuenta, un producto o un pedido que
 * la senal no tenia, o que la metrica principal del tipo (ver
 * `METRICA_PRINCIPAL`) suba respecto a la ultima lectura. Reabrir limpia
 * quien y cuando la reviso, y mueve `fecha_actualizacion` para que suba en el
 * listado, igual que hoy lo hace la fila nueva del dia siguiente. Una
 * `confirmada` nunca se reabre.
 */
async function registrarSenalDelHallazgo(
  cliente: PoolClient,
  datos: {
    tipo: TipoHallazgoEvento;
    clave: string;
    cuentas: string[];
    pedidos?: string[];
    idProductoMongo: number | null;
    detalle: Record<string, unknown>;
    ventanaInicio: Date;
  },
): Promise<void> {
  const pedidos = datos.pedidos ?? [];
  const tipo = await cliente.query<{ id_tipo_senal_fraude: number }>(
    `SELECT id_tipo_senal_fraude
       FROM tipo_senal_fraude
      WHERE tipo_senal_fraude_nombre = $1`,
    [datos.tipo],
  );
  const idTipoSenal = tipo.rows[0].id_tipo_senal_fraude;

  const previa = await cliente.query<{
    id_senal_fraude: string;
    id_estado_alerta_fraude: number;
    detalle: Record<string, unknown>;
    cuentas: string[];
    productos: string[];
  }>(
    `SELECT s.id_senal_fraude, s.id_estado_alerta_fraude, s.detalle,
            COALESCE((SELECT array_agg(c.id_usuario::text)
                        FROM senal_fraude_cuenta c
                       WHERE c.id_senal_fraude = s.id_senal_fraude), '{}') AS cuentas,
            COALESCE((SELECT array_agg(p.id_producto_mongo::text)
                        FROM senal_fraude_producto p
                       WHERE p.id_senal_fraude = s.id_senal_fraude), '{}') AS productos
       FROM senal_fraude s
      WHERE s.id_tipo_senal_fraude = $1 AND s.clave = $2
      FOR UPDATE OF s`,
    [idTipoSenal, datos.clave],
  );

  let idSenal: string;
  if (previa.rows.length === 0) {
    const insertada = await cliente.query<{ id_senal_fraude: string }>(
      `INSERT INTO senal_fraude
         (id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle,
          primera_deteccion, ultima_deteccion)
       VALUES ($1, $2, $3, $4::jsonb, $5, $5)
       RETURNING id_senal_fraude`,
      [
        idTipoSenal,
        datos.clave,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
        JSON.stringify(datos.detalle),
        datos.ventanaInicio,
      ],
    );
    idSenal = insertada.rows[0].id_senal_fraude;
  } else {
    const fila = previa.rows[0];
    idSenal = fila.id_senal_fraude;

    const hayCuentaNueva = datos.cuentas.some(
      (cuenta) => !fila.cuentas.includes(String(cuenta)),
    );
    const hayProductoNuevo =
      datos.idProductoMongo != null &&
      !fila.productos.includes(String(datos.idProductoMongo));
    // Un pedido nuevo es uno que EXISTE en `pedido` y la senal todavia no
    // tiene. Los ids que no existen (eventos de prueba o pedidos borrados) no
    // cuentan, o la senal se reabriria en cada corrida por algo que nunca se
    // puede enlazar.
    const pedidosNuevos =
      pedidos.length === 0
        ? 0
        : Number(
            (
              await cliente.query<{ nuevos: string }>(
                `SELECT count(*) AS nuevos
                   FROM pedido p
                  WHERE p.id_pedido = ANY ($1::bigint[])
                    AND NOT EXISTS (SELECT 1 FROM senal_fraude_pedido sp
                                     WHERE sp.id_senal_fraude = $2
                                       AND sp.id_pedido = p.id_pedido)`,
                [pedidos, idSenal],
              )
            ).rows[0].nuevos,
          );
    const metrica = METRICA_PRINCIPAL[datos.tipo];
    const metricaCrece =
      Number(datos.detalle[metrica]) > Number(fila.detalle[metrica]);
    const reabrir =
      (fila.id_estado_alerta_fraude === ID_ESTADO_ALERTA_FRAUDE_REVISADA ||
        fila.id_estado_alerta_fraude === ID_ESTADO_ALERTA_FRAUDE_DESCARTADA) &&
      (hayCuentaNueva || hayProductoNuevo || pedidosNuevos > 0 || metricaCrece);

    await cliente.query(
      `UPDATE senal_fraude
          SET detalle = $2::jsonb,
              ultima_deteccion = $3,
              total_detecciones = total_detecciones + 1,
              id_estado_alerta_fraude = CASE WHEN $4 THEN $5
                                             ELSE id_estado_alerta_fraude END,
              id_usuario_reviso = CASE WHEN $4 THEN NULL
                                       ELSE id_usuario_reviso END,
              fecha_revision = CASE WHEN $4 THEN NULL
                                    ELSE fecha_revision END,
              fecha_actualizacion = CASE WHEN $4 THEN now()
                                         ELSE fecha_actualizacion END
        WHERE id_senal_fraude = $1`,
      [
        idSenal,
        JSON.stringify(datos.detalle),
        datos.ventanaInicio,
        reabrir,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
      ],
    );
  }

  // Todas 'autor': en F1-F6 la cuenta senalada es la sospechosa, nunca la
  // victima. Sin cuentas (vistas_infladas) no inserta ninguna.
  for (const idUsuario of datos.cuentas) {
    await cliente.query(
      `INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal)
       SELECT $1::bigint, $2::bigint, id_rol_cuenta_senal
         FROM rol_cuenta_senal WHERE rol_cuenta_senal_nombre = 'autor'
       ON CONFLICT (id_senal_fraude, id_usuario) DO NOTHING`,
      [idSenal, idUsuario],
    );
  }
  // Los pedidos: solo los que existen en `pedido` (la llave foranea revienta
  // con un id que no esta).
  if (pedidos.length > 0) {
    await cliente.query(
      `INSERT INTO senal_fraude_pedido (id_senal_fraude, id_pedido)
       SELECT $1::bigint, p.id_pedido
         FROM pedido p WHERE p.id_pedido = ANY ($2::bigint[])
       ON CONFLICT (id_senal_fraude, id_pedido) DO NOTHING`,
      [idSenal, pedidos],
    );
  }
  if (datos.idProductoMongo != null) {
    await cliente.query(
      `INSERT INTO senal_fraude_producto (id_senal_fraude, id_producto_mongo)
       VALUES ($1, $2)
       ON CONFLICT (id_senal_fraude, id_producto_mongo) DO NOTHING`,
      [idSenal, datos.idProductoMongo],
    );
  }
  // En F3 y F6 la `clave` ES la IP. Es siempre la misma de la senal, asi que
  // nunca cuenta como evidencia nueva para reabrir; se enlaza para poder ir
  // de una IP a las senales donde aparece.
  if (TIPOS_CON_IP_EN_LA_CLAVE.has(datos.tipo) && isIP(datos.clave)) {
    await vincularIpASenalFraude(cliente, idSenal, datos.clave);
  }
}
