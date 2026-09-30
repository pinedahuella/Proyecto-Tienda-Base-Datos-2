import type { PoolClient } from 'pg';

/**
 * Deja una IP en `direccion_ip` (una fila por IP) y la enlaza a una senal en
 * `senal_fraude_ip`. Devuelve `true` si la senal NO la tenia todavia: eso es
 * la "IP nueva" de la regla de reabrir (ver `registrarSenalDeLaAlerta`).
 *
 * `ip` tiene que ser una IP valida (quien llama la filtra con `isIP`): un
 * texto malo reventaria el `::inet` y con eso la transaccion de la alerta o
 * del hallazgo entera.
 */
export async function vincularIpASenalFraude(
  cliente: PoolClient,
  idSenal: string,
  ipOriginal: string,
): Promise<boolean> {
  // ClickHouse guarda las IPv4 como IPv6 "mapeadas" (::ffff:1.2.3.4) y el
  // login las guarda como 1.2.3.4. Es la misma maquina; se normaliza a IPv4
  // para que `direccion_ip` tenga UNA fila y se pueda cruzar por IP.
  const ip = ipOriginal.replace(/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i, '$1');
  const resultado = await cliente.query(
    `WITH d AS (
       INSERT INTO direccion_ip (ip) VALUES ($1::inet)
       ON CONFLICT (ip) DO UPDATE SET ip = EXCLUDED.ip
       RETURNING id_direccion_ip
     )
     INSERT INTO senal_fraude_ip (id_senal_fraude, id_direccion_ip)
     SELECT $2::bigint, id_direccion_ip FROM d
     ON CONFLICT (id_senal_fraude, id_direccion_ip) DO NOTHING`,
    [ip, idSenal],
  );
  return (resultado.rowCount ?? 0) > 0;
}
