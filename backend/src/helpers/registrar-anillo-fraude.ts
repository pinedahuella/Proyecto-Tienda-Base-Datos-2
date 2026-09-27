import { pool } from '../database/postgres';
import { ID_ESTADO_ALERTA_FRAUDE_PENDIENTE } from '../models/alerta-fraude';
import {
  ID_TIPO_ANILLO_FRAUDE_ANILLO_EN_EL_TIEMPO,
  ID_TIPO_ANILLO_FRAUDE_CADENA_ABIERTA,
  ID_TIPO_ANILLO_FRAUDE_CICLO,
  ID_TIPO_ANILLO_FRAUDE_COORDINADOS,
  ID_TIPO_ANILLO_FRAUDE_FAVOR_DEVUELTO,
  ID_TIPO_ANILLO_FRAUDE_MUTUO,
  ID_TIPO_ANILLO_FRAUDE_PERSISTENTE,
  ID_TIPO_ANILLO_FRAUDE_REITERADO,
  ID_TIPO_ANILLO_FRAUDE_REPUTACION_EXPRES,
  ID_TIPO_ANILLO_FRAUDE_SATELITES,
  TipoAnilloFraude,
} from '../models/anillo-fraude';

// `anillo_en_el_tiempo` (B.4) tiene entrada aqui solo para que el Record
// siga exhaustivo -- no se persiste como fila propia (ver
// models/anillo-fraude.ts), asi que `registrarAnilloFraude` nunca deberia
// llamarse con ese tipo.
const ID_TIPO_ANILLO_FRAUDE: Record<TipoAnilloFraude, number> = {
  mutuo: ID_TIPO_ANILLO_FRAUDE_MUTUO,
  ciclo: ID_TIPO_ANILLO_FRAUDE_CICLO,
  reiterado: ID_TIPO_ANILLO_FRAUDE_REITERADO,
  cadena_abierta: ID_TIPO_ANILLO_FRAUDE_CADENA_ABIERTA,
  satelites: ID_TIPO_ANILLO_FRAUDE_SATELITES,
  persistente: ID_TIPO_ANILLO_FRAUDE_PERSISTENTE,
  anillo_en_el_tiempo: ID_TIPO_ANILLO_FRAUDE_ANILLO_EN_EL_TIEMPO,
  favor_devuelto: ID_TIPO_ANILLO_FRAUDE_FAVOR_DEVUELTO,
  coordinados: ID_TIPO_ANILLO_FRAUDE_COORDINADOS,
  reputacion_expres: ID_TIPO_ANILLO_FRAUDE_REPUTACION_EXPRES,
};

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
const IDS_TIPO_CICLO_RESENAS = [
  ID_TIPO_ANILLO_FRAUDE_MUTUO,
  ID_TIPO_ANILLO_FRAUDE_CICLO,
  ID_TIPO_ANILLO_FRAUDE_REITERADO,
];

/**
 * El UPSERT que deja (o refresca) una fila de `anillo_fraude`, y de paso
 * asegura que `anillo_fraude_resena` tenga una fila por cada resena que hoy
 * forma parte de la evidencia. La llama `AnillosDetectorService`
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
  /** Las metricas del hallazgo (horas, minutos de vida, regularidad, etc.)
   * -- solo `favor_devuelto`/`reputacion_expres`/`persistente` la traen hoy
   * (ver `PatronesFraudeDetectorService`); el resto se queda con el `{}` por
   * defecto de la columna. */
  detalle?: Record<string, unknown>;
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    const idTipo = ID_TIPO_ANILLO_FRAUDE[datos.tipo];
    let idAnilloFraude: string;

    if (TIPOS_CICLO_RESENAS.has(datos.tipo)) {
      const existente = await cliente.query<{ id_anillo_fraude: string }>(
        `SELECT id_anillo_fraude FROM anillo_fraude
          WHERE clave = $1 AND id_tipo_anillo_fraude = ANY ($2)
          FOR UPDATE`,
        [datos.clave, IDS_TIPO_CICLO_RESENAS],
      );
      if (existente.rows.length > 0) {
        idAnilloFraude = existente.rows[0].id_anillo_fraude;
        await cliente.query(
          `UPDATE anillo_fraude
              SET id_tipo_anillo_fraude = $2, ultima_vez_confirmado_activo = now()
            WHERE id_anillo_fraude = $1`,
          [idAnilloFraude, idTipo],
        );
      } else {
        const insertado = await cliente.query<{ id_anillo_fraude: string }>(
          `INSERT INTO anillo_fraude (id_tipo_anillo_fraude, clave, id_estado_alerta_fraude)
           VALUES ($1, $2, $3)
           RETURNING id_anillo_fraude`,
          [idTipo, datos.clave, ID_ESTADO_ALERTA_FRAUDE_PENDIENTE],
        );
        idAnilloFraude = insertado.rows[0].id_anillo_fraude;
      }
    } else {
      const resultado = await cliente.query<{ id_anillo_fraude: string }>(
        `INSERT INTO anillo_fraude (id_tipo_anillo_fraude, clave, id_estado_alerta_fraude, detalle)
         VALUES ($1, $2, $3, $4::jsonb)
         ON CONFLICT (id_tipo_anillo_fraude, clave)
         DO UPDATE SET ultima_vez_confirmado_activo = now(), detalle = $4::jsonb
         RETURNING id_anillo_fraude`,
        [
          idTipo,
          datos.clave,
          ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
          JSON.stringify(datos.detalle ?? {}),
        ],
      );
      idAnilloFraude = resultado.rows[0].id_anillo_fraude;
    }

    for (const idResena of datos.resenas) {
      await cliente.query(
        `INSERT INTO anillo_fraude_resena (id_anillo_fraude, id_resena)
         VALUES ($1, $2)
         ON CONFLICT (id_anillo_fraude, id_resena) DO NOTHING`,
        [idAnilloFraude, idResena],
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
