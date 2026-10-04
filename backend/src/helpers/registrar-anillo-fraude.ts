import type { PoolClient } from 'pg';
import { pool } from '../database/postgres';
import { ID_ESTADO_ALERTA_FRAUDE_PENDIENTE } from '../models/alerta-fraude';
import type { TipoAnilloFraude } from '../models/anillo-fraude';

/**
 * `mutuo`/`ciclo`/`reiterado` son el MISMO fenomeno (A.1/A.2) escalando o
 * bajando de confianza sobre el mismo par/grupo de cuentas -- por eso
 * comparten fila (ver el comentario mas abajo). Los tipos de B.1-B.7 no
 * escalan entre si: cada uno es un patron distinto, aunque coincida en el
 * mismo par de cuentas que otro.
 */
const TIPOS_CICLO_RESENAS: ReadonlySet<TipoAnilloFraude> = new Set([
  'mutuo',
  'ciclo',
  'reiterado',
]);

/**
 * El UPSERT que deja (o refresca) la senal de un anillo en `senal_fraude`, y
 * de paso asegura que `senal_fraude_resena` tenga una fila por cada resena que
 * hoy forma parte de la evidencia. Desde la etapa 8 del refactor ya no escribe
 * en `anillo_fraude` ni en `anillo_fraude_resena`. La llama `AnillosDetectorService`
 * (`detectar()`/`detectarInmediato()`) por cada grupo que encuentran A.1/A.2,
 * y `PatronesFraudeDetectorService` por cada hallazgo de B.1/B.2/B.3/B.5/B.6/B.7
 * (ver `elementos Generales/plan pendiente/anillos-fraude-familia-b.md`).
 *
 * `datos.clave` es SOLO los ids de cuenta ordenados (ver el comentario de la
 * columna en el `.sql` de referencia) -- NO lleva el tipo. La unicidad real
 * en la base es sobre (tipo, clave): dos tipos DISTINTOS sobre el mismo par
 * de cuentas son casos separados, con su propia fila. La excepcion es
 * `mutuo`/`ciclo`/`reiterado`, que SI comparten fila -- son el mismo caso
 * escalando de confianza -- asi que para esos tres se busca primero si ya
 * existe una fila de CUALQUIERA de los tres para esta `clave` y se actualiza
 * esa, en vez de dejar que el `INSERT` cree una fila nueva por cada tipo.
 *
 * NO pisa `id_estado_alerta_fraude` en el conflicto: si un admin ya marco el
 * caso revisado/descartado, que el worker lo siga encontrando no debe
 * reabrirlo solo -- mismo criterio que `registrarAlertaFraude`.
 *
 * Los ids de resena se insertan SIEMPRE, tambien cuando el caso ya existia:
 * la evidencia puede crecer entre corridas (mas resenas escritas despues de
 * la primera deteccion), y `ON CONFLICT DO NOTHING` hace que repetir un id
 * ya guardado no cueste nada.
 *
 * Sin notificacion a ninguna cuenta -- a diferencia de `registrarAlertaFraude`,
 * aca las cuentas del caso son las SOSPECHOSAS, no victimas (ver
 * `elementos Generales/plan pendiente/anillos-fraude-persistencia.md`).
 */
export async function registrarAnilloFraude(datos: {
  tipo: TipoAnilloFraude;
  clave: string;
  resenas: number[];
  /** Los productos de la senal (`senal_fraude_producto`), si es de un
   * producto. Su `clave` no debe ser solo digitos (`p12`): las cuentas salen de
   * los numeros de la `clave`, y un id de producto no es una cuenta. */
  productos?: number[];
  /** Las metricas del hallazgo (horas, minutos de vida, regularidad, etc.)
   * -- solo `favor_devuelto`/`reputacion_expres`/`persistente` la traen hoy
   * (ver `PatronesFraudeDetectorService`); el resto se queda con el `{}` por
   * defecto de la columna. */
  detalle?: Record<string, unknown>;
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    await registrarSenalDelAnillo(cliente, datos);

    await cliente.query('COMMIT');
  } catch (error) {
    await cliente.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    cliente.release();
  }
}

/**
 * Deja la senal del anillo en `senal_fraude`, `senal_fraude_resena` y
 * `senal_fraude_cuenta` (ver
 * `elementos Generales/plan pendiente/refactor-fraude-senales.md`). Va en la
 * transaccion de `registrarAnilloFraude`: si una escritura falla, ninguna
 * queda a medias.
 *
 * Cada deteccion sube `total_detecciones` y avanza `ultima_deteccion`. NO toca
 * `id_estado_alerta_fraude` ni `fecha_actualizacion` (son de la revision del
 * admin), mismo criterio que la escritura de arriba.
 *
 * Igual que arriba, `mutuo`/`ciclo`/`reiterado` comparten senal: se busca
 * cualquiera de los tres por `clave` y se le cambia el tipo, en vez de dejar
 * que nazca una senal nueva por cada tipo.
 */
async function registrarSenalDelAnillo(
  cliente: PoolClient,
  datos: {
    tipo: TipoAnilloFraude;
    clave: string;
    resenas: number[];
    productos?: number[];
    detalle?: Record<string, unknown>;
  },
): Promise<void> {
  let idSenal: string;

  if (TIPOS_CICLO_RESENAS.has(datos.tipo)) {
    const existente = await cliente.query<{ id_senal_fraude: string }>(
      `SELECT s.id_senal_fraude
         FROM senal_fraude s
         JOIN tipo_senal_fraude t
           ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
        WHERE s.clave = $1 AND t.tipo_senal_fraude_nombre = ANY ($2)
        FOR UPDATE OF s`,
      [datos.clave, [...TIPOS_CICLO_RESENAS]],
    );
    if (existente.rows.length > 0) {
      idSenal = existente.rows[0].id_senal_fraude;
      await cliente.query(
        `UPDATE senal_fraude
            SET id_tipo_senal_fraude = (SELECT id_tipo_senal_fraude
                                          FROM tipo_senal_fraude
                                         WHERE tipo_senal_fraude_nombre = $2),
                ultima_deteccion = now(),
                total_detecciones = total_detecciones + 1
          WHERE id_senal_fraude = $1`,
        [idSenal, datos.tipo],
      );
    } else {
      const insertada = await cliente.query<{ id_senal_fraude: string }>(
        `INSERT INTO senal_fraude (id_tipo_senal_fraude, clave, id_estado_alerta_fraude)
         SELECT id_tipo_senal_fraude, $2, $3
           FROM tipo_senal_fraude WHERE tipo_senal_fraude_nombre = $1
         RETURNING id_senal_fraude`,
        [datos.tipo, datos.clave, ID_ESTADO_ALERTA_FRAUDE_PENDIENTE],
      );
      idSenal = insertada.rows[0].id_senal_fraude;
    }
  } else {
    const resultado = await cliente.query<{ id_senal_fraude: string }>(
      `INSERT INTO senal_fraude (id_tipo_senal_fraude, clave, id_estado_alerta_fraude, detalle)
       SELECT id_tipo_senal_fraude, $2, $3, $4::jsonb
         FROM tipo_senal_fraude WHERE tipo_senal_fraude_nombre = $1
       ON CONFLICT (id_tipo_senal_fraude, clave)
       DO UPDATE SET ultima_deteccion = now(),
                     total_detecciones = senal_fraude.total_detecciones + 1,
                     detalle = $4::jsonb
       RETURNING id_senal_fraude`,
      [
        datos.tipo,
        datos.clave,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
        JSON.stringify(datos.detalle ?? {}),
      ],
    );
    idSenal = resultado.rows[0].id_senal_fraude;
  }

  for (const idResena of datos.resenas) {
    await cliente.query(
      `INSERT INTO senal_fraude_resena (id_senal_fraude, id_resena)
       VALUES ($1, $2)
       ON CONFLICT (id_senal_fraude, id_resena) DO NOTHING`,
      [idSenal, idResena],
    );
  }

  for (const idProducto of datos.productos ?? []) {
    await cliente.query(
      `INSERT INTO senal_fraude_producto (id_senal_fraude, id_producto_mongo)
       VALUES ($1, $2)
       ON CONFLICT DO NOTHING`,
      [idSenal, idProducto],
    );
  }

  // Las cuentas, todas 'autor' (en un anillo de resenas la cuenta senalada es
  // la sospechosa, nunca la victima). Salen de la `clave`, que es EXACTAMENTE
  // el conjunto de cuentas que detecto el detector: no de un join con las
  // resenas, que metia al vendedor en `coordinados` (B.6), donde es un
  // tercero ajeno al patron y no un sospechoso.
  const idsCuentas = datos.clave.split('-').filter((id) => /^\d+$/.test(id));
  await cliente.query(
    `INSERT INTO senal_fraude_cuenta (id_senal_fraude, id_usuario, id_rol_cuenta_senal)
     SELECT $1::bigint, u.id_usuario, rol.id_rol_cuenta_senal
       FROM usuarios u
       JOIN rol_cuenta_senal rol ON rol.rol_cuenta_senal_nombre = 'autor'
      WHERE u.id_usuario = ANY ($2::bigint[])
     ON CONFLICT DO NOTHING`,
    [idSenal, idsCuentas],
  );
}
