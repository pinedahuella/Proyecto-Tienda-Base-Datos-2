import { isIP } from 'node:net';
import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { vincularIpASenalFraude } from './vincular-ip-a-senal-fraude';
import {
  ID_ESTADO_ALERTA_FRAUDE_DESCARTADA,
  ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
  ID_ESTADO_ALERTA_FRAUDE_REVISADA,
  TipoAlertaFraude,
} from '../models/alerta-fraude';

/**
 * Deja (o engorda) la senal de una alerta de login en `senal_fraude`: ahi se
 * guardan las cuentas afectadas y se les avisa por `notificacion_fraude`,
 * una fila por (senal, cuenta) con su propio "ya la vi" (ver
 * `registrarSenalDeLaAlerta`). Compartido por los cuatro
 * servicios que escriben alertas: `FraudeLoginService` (Redis, ventana
 * truncada al minuto), `TomaCuentaService`/`ViajeImposibleService`
 * (Elasticsearch, puntuales) y `FraudeLoginRetrospectivoService`
 * (Elasticsearch, truncada a la hora -- ver ese servicio para el porque).
 *
 * Desde la etapa 8 del refactor ya no escribe en `alerta_fraude`. La senal es
 * una por (tipo, clave), no una por ventana, y una senal ya revisada solo se
 * reabre con evidencia nueva (ver `registrarSenalDeLaAlerta`).
 *
 * A quien le llega el aviso, segun la forma de la alerta:
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
  tipo: TipoAlertaFraude;
  clave: string;
  idUsuario: string | null;
  detalle: Record<string, unknown>;
  ventanaInicio: Date;
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    // Se resuelven en CADA llamada: la senal (abajo) necesita saber si aparecio
    // una cuenta nueva para avisarle y para decidir si se reabre.
    const idsUsuarioDestino = await resolverCuentasDestino(
      cliente,
      datos.idUsuario,
      datos.detalle,
    );

    await registrarSenalDeLaAlerta(cliente, datos, idsUsuarioDestino);

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

/**
 * La metrica del `detalle` que dice "cuanta evidencia hay" en cada tipo, para
 * la regla de reabrir de `registrarSenalDeLaAlerta`. `toma_cuenta` no tiene:
 * su evidencia nueva es la IP nueva, que ya cuenta como IP del pivote.
 */
const METRICA_PRINCIPAL: Partial<Record<TipoAlertaFraude, string>> = {
  fuerza_bruta_ip: 'fallos',
  fuerza_bruta_cuenta: 'fallos',
  fuerza_bruta_cuenta_lenta: 'fallos',
  multi_cuenta_ip: 'cuentas_distintas',
  multi_cuenta_ip_lenta: 'cuentas_distintas',
  ip_rotacion_cuenta: 'ips_distintas',
  ip_rotacion_cuenta_lenta: 'ips_distintas',
  viaje_imposible: 'velocidad_kmh',
};

/**
 * Los tipos de ventana corta (Redis por minuto y los dos puntuales por
 * login): sus contadores se reinician y empiezan de cero, asi que un ataque
 * nuevo dias despues NO supera la ultima lectura de la metrica. Para ellos,
 * pasar mas de una hora sin verlos cuenta como evidencia nueva. Los `_lenta`
 * miran 24 horas moviles y se comportan como F1-F6: no lo necesitan.
 */
const TIPOS_DE_EPISODIO_CORTO: ReadonlySet<TipoAlertaFraude> =
  new Set<TipoAlertaFraude>([]);
const SEPARACION_DE_EPISODIOS_MS = 60 * 60 * 1000;

/**
 * Las IP involucradas, segun donde la trae cada tipo: la `clave` en los que
 * nacen de una IP, `detalle.ips` en la rotacion y `detalle.ip_nueva` en
 * `toma_cuenta`. `fuerza_bruta_cuenta` y `viaje_imposible` no traen IP. Solo
 * devuelve textos que son una IP de verdad: una IP mala no debe tumbar la
 * transaccion de la alerta.
 */
function ipsDeLaAlerta(
  tipo: TipoAlertaFraude,
  clave: string,
  detalle: Record<string, unknown>,
): string[] {
  let candidatas: unknown[] = [];
  if (
    tipo === 'fuerza_bruta_ip' ||
    tipo === 'multi_cuenta_ip' ||
    tipo === 'multi_cuenta_ip_lenta'
  ) {
    candidatas = [clave];
  } else if (
    tipo === 'ip_rotacion_cuenta' ||
    tipo === 'ip_rotacion_cuenta_lenta'
  ) {
    candidatas = Array.isArray(detalle.ips) ? detalle.ips : [];
  } else if (tipo === 'toma_cuenta') {
    candidatas = [detalle.ip_nueva];
  }
  return [
    ...new Set(
      candidatas.filter(
        (valor): valor is string =>
          typeof valor === 'string' && isIP(valor) !== 0,
      ),
    ),
  ];
}

/**
 * La escritura de la etapa 4 del refactor (ver
 * `elementos Generales/plan pendiente/refactor-fraude-senales.md`): deja la
 * senal en `senal_fraude`, `senal_fraude_cuenta` (rol `victima`) y
 * `senal_fraude_ip`, en la transaccion de `registrarAlertaFraude`.
 *
 * La senal es UNA por (tipo, clave), no una por ventana: cada llamada suma 1
 * a `total_detecciones` y refresca `detalle` y `ultima_deteccion`. Las
 * notificaciones (`notificacion_fraude`) cuelgan de la senal: una por cuenta,
 * que nace la primera vez que la cuenta aparece en la senal, y cuando la senal
 * se reabre vuelve a quedar sin leer.
 *
 * Regla de reabrir: una senal `revisada` o `descartada` vuelve a `pendiente`
 * SOLO si la llamada trae evidencia nueva: una cuenta o una IP que la senal
 * no tenia, que la metrica principal del tipo (ver `METRICA_PRINCIPAL`) suba
 * respecto a la ultima lectura, o, en los tipos de ventana corta, que haya
 * pasado mas de una hora desde la ultima vez (un episodio nuevo). Reabrir
 * limpia quien y cuando la reviso y mueve `fecha_actualizacion`. Una
 * `confirmada` nunca se reabre.
 */
async function registrarSenalDeLaAlerta(
  cliente: PoolClient,
  datos: {
    tipo: TipoAlertaFraude;
    clave: string;
    detalle: Record<string, unknown>;
    ventanaInicio: Date;
  },
  idsCuentas: string[],
): Promise<void> {
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
    ultima_deteccion: Date;
  }>(
    `SELECT id_senal_fraude, id_estado_alerta_fraude, detalle, ultima_deteccion
       FROM senal_fraude
      WHERE id_tipo_senal_fraude = $1 AND clave = $2
      FOR UPDATE`,
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
    idSenal = previa.rows[0].id_senal_fraude;
    await cliente.query(
      `UPDATE senal_fraude
          SET detalle = $2::jsonb,
              ultima_deteccion = $3,
              total_detecciones = total_detecciones + 1
        WHERE id_senal_fraude = $1`,
      [idSenal, JSON.stringify(datos.detalle), datos.ventanaInicio],
    );
  }

  // Cuentas (todas victimas) e IP. Cada INSERT dice si la fila era nueva:
  // eso es la "cuenta nueva" o la "IP nueva" de la regla de reabrir.
  let hayEvidenciaNueva = false;
  for (const idUsuario of idsCuentas) {
    const resultado = await cliente.query(
      `INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal)
       SELECT $1::bigint, $2::bigint, id_rol_cuenta_senal
         FROM rol_cuenta_senal WHERE rol_cuenta_senal_nombre = 'victima'
       ON CONFLICT (id_senal_fraude, id_usuario) DO NOTHING`,
      [idSenal, idUsuario],
    );
    hayEvidenciaNueva ||= (resultado.rowCount ?? 0) > 0;

    // Se le avisa a la cuenta la PRIMERA vez que aparece en la senal, no en
    // cada ventana (una notificacion por senal y cuenta).
    await cliente.query(
      `INSERT INTO notificacion_fraude (id_senal_fraude, id_usuario)
       VALUES ($1, $2)
       ON CONFLICT (id_senal_fraude, id_usuario)
         WHERE id_senal_fraude IS NOT NULL
       DO NOTHING`,
      [idSenal, idUsuario],
    );
  }
  for (const ip of ipsDeLaAlerta(datos.tipo, datos.clave, datos.detalle)) {
    hayEvidenciaNueva ||= await vincularIpASenalFraude(cliente, idSenal, ip);
  }

  if (previa.rows.length === 0) {
    return;
  }
  const anterior = previa.rows[0];
  if (
    anterior.id_estado_alerta_fraude !== ID_ESTADO_ALERTA_FRAUDE_REVISADA &&
    anterior.id_estado_alerta_fraude !== ID_ESTADO_ALERTA_FRAUDE_DESCARTADA
  ) {
    return;
  }

  const metrica = METRICA_PRINCIPAL[datos.tipo];
  const metricaCrece =
    metrica != null &&
    Number(datos.detalle[metrica]) > Number(anterior.detalle[metrica]);
  const episodioNuevo =
    TIPOS_DE_EPISODIO_CORTO.has(datos.tipo) &&
    datos.ventanaInicio.getTime() -
      new Date(anterior.ultima_deteccion).getTime() >
      SEPARACION_DE_EPISODIOS_MS;

  if (hayEvidenciaNueva || metricaCrece || episodioNuevo) {
    await cliente.query(
      `UPDATE senal_fraude
          SET id_estado_alerta_fraude = $2,
              id_usuario_reviso = NULL,
              fecha_revision = NULL,
              fecha_actualizacion = now()
        WHERE id_senal_fraude = $1`,
      [idSenal, ID_ESTADO_ALERTA_FRAUDE_PENDIENTE],
    );

    // Al reabrirse se les vuelve a avisar: la notificacion vuelve a "sin
    // leer" y sube en su lista.
    await cliente.query(
      `UPDATE notificacion_fraude
          SET fecha_lectura = NULL, fecha_creacion = now()
        WHERE id_senal_fraude = $1`,
      [idSenal],
    );
  }
}
