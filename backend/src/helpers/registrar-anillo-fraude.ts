import { pool } from '../database/postgres';
import { ID_ESTADO_ALERTA_FRAUDE_PENDIENTE } from '../models/alerta-fraude';
import {
  ID_TIPO_ANILLO_FRAUDE_CICLO,
  ID_TIPO_ANILLO_FRAUDE_MUTUO,
  ID_TIPO_ANILLO_FRAUDE_REITERADO,
  TipoAnilloFraude,
} from '../models/anillo-fraude';

const ID_TIPO_ANILLO_FRAUDE: Record<TipoAnilloFraude, number> = {
  mutuo: ID_TIPO_ANILLO_FRAUDE_MUTUO,
  ciclo: ID_TIPO_ANILLO_FRAUDE_CICLO,
  reiterado: ID_TIPO_ANILLO_FRAUDE_REITERADO,
};

/**
 * El UPSERT que deja (o refresca) una fila de `anillo_fraude`, y de paso
 * asegura que `anillo_fraude_resena` tenga una fila por cada resena que hoy
 * forma parte de la evidencia. La llama `AnillosDetectorService`
 * (`detectar()`/`detectarInmediato()`) por cada grupo que encuentran A.1/A.2.
 *
 * `datos.clave` es SOLO los ids de cuenta ordenados (ver el comentario de la
 * columna en el `.sql` de referencia) -- NO lleva el tipo. Por eso el UPSERT
 * sobreescribe `id_tipo_anillo_fraude` con el tipo de ESTA corrida (ya es el
 * "ganador" entre mutuo/reiterado, resuelto por
 * `AnillosDetectorService.agrupar()`): un mismo par/grupo puede subir de
 * `mutuo` a `reiterado`, o bajar de vuelta si la resena que sostenia el
 * `reiterado` sale de la ventana de dias -- sigue siendo el mismo caso, no
 * una fila nueva.
 *
 * NO pisa `id_estado_alerta_fraude` en el conflicto: si un admin ya marco el
 * anillo revisado/descartado, que el worker lo siga encontrando no debe
 * reabrirlo solo -- mismo criterio que `registrarAlertaFraude`.
 *
 * Los ids de resena se insertan SIEMPRE, tambien cuando el anillo ya
 * existia: la evidencia puede crecer entre corridas (mas resenas reciprocas
 * escritas despues de la primera deteccion), y `ON CONFLICT DO NOTHING`
 * hace que repetir un id ya guardado no cueste nada.
 *
 * Sin notificacion a ninguna cuenta -- a diferencia de `registrarAlertaFraude`,
 * aca las cuentas del anillo son las SOSPECHOSAS, no victimas (ver
 * `elementos Generales/plan pendiente/anillos-fraude-persistencia.md`).
 */
export async function registrarAnilloFraude(datos: {
  tipo: TipoAnilloFraude;
  clave: string;
  resenas: number[];
}): Promise<void> {
  const cliente = await pool.connect();
  try {
    await cliente.query('BEGIN');

    const resultado = await cliente.query<{ id_anillo_fraude: string }>(
      `INSERT INTO anillo_fraude (id_tipo_anillo_fraude, clave, id_estado_alerta_fraude)
       VALUES ($1, $2, $3)
       ON CONFLICT (clave)
       DO UPDATE SET
         id_tipo_anillo_fraude = $1,
         ultima_vez_confirmado_activo = now()
       RETURNING id_anillo_fraude`,
      [
        ID_TIPO_ANILLO_FRAUDE[datos.tipo],
        datos.clave,
        ID_ESTADO_ALERTA_FRAUDE_PENDIENTE,
      ],
    );
    const idAnilloFraude = resultado.rows[0].id_anillo_fraude;

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
