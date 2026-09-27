import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { GrupoFraude } from '../../models/fraude/grupo-fraude';
import { FuenteHallazgo, Hallazgo } from '../../models/fraude/hallazgo';
import { PuntajeFraudeService } from './puntaje-fraude.service';
import { ReglasCasiConfirmadoService } from './reglas-casi-confirmado.service';

const COLUMNA_POR_FUENTE: Record<FuenteHallazgo, string> = {
  grafo: 'id_anillo_fraude',
  eventos: 'id_hallazgo_evento_fraude',
  login: 'id_alerta_fraude',
};

/**
 * Paso 4 del agrupador de casos de fraude: reconcilia UN `GrupoFraude` ya
 * armado (`AgrupadorFraudeService`) y puntuado (`PuntajeFraudeService`/
 * `ReglasCasiConfirmadoService`) con lo que ya exista en Postgres.
 *
 * Asume que `grupo` trae el conjunto COMPLETO de hallazgos vigentes para
 * esas cuentas (los adaptadores no filtran "solo lo nuevo"): la evidencia
 * y la membresia de cuentas del caso se REEMPLAZAN enteras en cada
 * corrida, no se acumulan -- mas simple y correcto que llevar un delta a
 * mano. La optimizacion de "solo sobre los casos que un detector tocó"
 * (seccion 6 del documento) es una decision de CUANDO se llama a esto,
 * no de esta funcion.
 */
@Injectable()
export class PersistenciaCasoFraudeService {
  private readonly logger = new Logger(PersistenciaCasoFraudeService.name);

  constructor(
    private readonly puntajeFraudeService: PuntajeFraudeService,
    private readonly reglasCasiConfirmadoService: ReglasCasiConfirmadoService,
  ) {}

  /** Devuelve el id del caso resultante (nuevo o ya existente). */
  async persistir(grupo: GrupoFraude): Promise<number> {
    const puntaje = this.puntajeFraudeService.calcular(grupo);
    const reglas = await this.reglasCasiConfirmadoService.evaluar(grupo);
    const nivel = this.calcularNivel(puntaje, reglas);
    const ultimaEvidencia = this.ultimaEvidenciaDe(grupo.hallazgos);
    const firma = this.construirFirma(grupo.hallazgos);

    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');

      const idCasoFraude = await this.resolverCaso(
        cliente,
        grupo.hallazgos,
        nivel,
        puntaje,
        ultimaEvidencia,
        firma,
      );

      const idEvidenciaPorHallazgo = await this.sincronizarEvidencia(
        cliente,
        idCasoFraude,
        grupo.hallazgos,
      );
      await this.sincronizarCuentas(
        cliente,
        idCasoFraude,
        grupo.hallazgos,
        idEvidenciaPorHallazgo,
        grupo.cuentas,
      );
      await this.sincronizarReglas(cliente, idCasoFraude, reglas);

      await cliente.query('COMMIT');
      return idCasoFraude;
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }

  /**
   * Busca que casos existentes ya tocan alguno de estos hallazgos.
   * Ninguno -> crea uno nuevo. Uno -> lo actualiza. Dos o mas -> los
   * FUSIONA (se queda el de menor id, mueve la evidencia de los demas y
   * los borra) -- el ejemplo del Caso 2 del documento original: dos
   * anillos separados que una evidencia nueva conecta.
   *
   * Si el caso resultante estaba `descartada` y la firma de evidencia
   * cambio, lo reabre como `pendiente` con una nota -- si la firma es
   * identica, se queda descartado (misma evidencia, misma decision).
   */
  private async resolverCaso(
    cliente: PoolClient,
    hallazgos: Hallazgo[],
    nivel: string,
    puntaje: number,
    ultimaEvidencia: Date,
    firma: string,
  ): Promise<number> {
    const idsExistentes = new Set<number>();
    for (const hallazgo of hallazgos) {
      const columna = COLUMNA_POR_FUENTE[hallazgo.fuente];
      const resultado = await cliente.query<{ id_caso_fraude: string }>(
        `SELECT id_caso_fraude FROM evidencia_caso_fraude WHERE ${columna} = $1`,
        [hallazgo.idOrigen],
      );
      if (resultado.rows[0] != null) {
        idsExistentes.add(Number(resultado.rows[0].id_caso_fraude));
      }
    }

    if (idsExistentes.size === 0) {
      const resultado = await cliente.query<{ id_caso_fraude: string }>(
        `INSERT INTO caso_fraude
           (id_nivel_caso_fraude, puntaje, id_estado_alerta_fraude, ultima_evidencia)
         VALUES (
           (SELECT id_nivel_caso_fraude FROM nivel_caso_fraude WHERE nivel_caso_fraude_nombre = $1),
           $2,
           (SELECT id_estado_alerta_fraude FROM estado_alerta_fraude WHERE estado_alerta_fraude_nombre = 'pendiente'),
           $3
         )
         RETURNING id_caso_fraude`,
        [nivel, puntaje, ultimaEvidencia],
      );
      return Number(resultado.rows[0].id_caso_fraude);
    }

    const [idSuperviviente, ...idsSobrantes] = [...idsExistentes].sort(
      (a, b) => a - b,
    );
    for (const idSobrante of idsSobrantes) {
      await cliente.query(
        `UPDATE evidencia_caso_fraude SET id_caso_fraude = $1 WHERE id_caso_fraude = $2`,
        [idSuperviviente, idSobrante],
      );
      await cliente.query(
        `DELETE FROM caso_fraude_regla WHERE id_caso_fraude = $1`,
        [idSobrante],
      );
      await cliente.query(`DELETE FROM caso_fraude WHERE id_caso_fraude = $1`, [
        idSobrante,
      ]);
    }

    const actual = await cliente.query<{
      estado_alerta_fraude_nombre: string;
      firma_al_descartar: string | null;
    }>(
      `SELECT eaf.estado_alerta_fraude_nombre, cf.firma_al_descartar
         FROM caso_fraude cf
         JOIN estado_alerta_fraude eaf
           ON eaf.id_estado_alerta_fraude = cf.id_estado_alerta_fraude
        WHERE cf.id_caso_fraude = $1
        FOR UPDATE`,
      [idSuperviviente],
    );
    const seReabre =
      actual.rows[0].estado_alerta_fraude_nombre === 'descartada' &&
      actual.rows[0].firma_al_descartar !== firma;

    await cliente.query(
      `UPDATE caso_fraude
          SET id_nivel_caso_fraude = (SELECT id_nivel_caso_fraude FROM nivel_caso_fraude WHERE nivel_caso_fraude_nombre = $1),
              puntaje = $2,
              ultima_evidencia = $3,
              fecha_actualizacion = now()
        WHERE id_caso_fraude = $4`,
      [nivel, puntaje, ultimaEvidencia, idSuperviviente],
    );

    if (seReabre) {
      await cliente.query(
        `UPDATE caso_fraude
            SET id_estado_alerta_fraude = (SELECT id_estado_alerta_fraude FROM estado_alerta_fraude WHERE estado_alerta_fraude_nombre = 'pendiente'),
                motivo = 'Reabierto: llego evidencia nueva despues del descarte.',
                firma_al_descartar = NULL
          WHERE id_caso_fraude = $1`,
        [idSuperviviente],
      );
    }

    return idSuperviviente;
  }

  /** Upsert de un `evidencia_caso_fraude` por hallazgo -- el `ON CONFLICT`
   * usa el indice unico parcial de la columna que le toca segun la
   * fuente. Devuelve el id de evidencia de cada hallazgo, para que
   * `sincronizarCuentas` sepa a cual enganchar cada cuenta. */
  private async sincronizarEvidencia(
    cliente: PoolClient,
    idCasoFraude: number,
    hallazgos: Hallazgo[],
  ): Promise<Map<Hallazgo, number>> {
    const idEvidenciaPorHallazgo = new Map<Hallazgo, number>();
    for (const hallazgo of hallazgos) {
      const columna = COLUMNA_POR_FUENTE[hallazgo.fuente];
      const puntos = this.puntajeFraudeService.puntosDeHallazgo(hallazgo);
      const resultado = await cliente.query<{
        id_evidencia_caso_fraude: string;
      }>(
        `INSERT INTO evidencia_caso_fraude (id_caso_fraude, ${columna}, puntos, ultima_evidencia)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (${columna}) WHERE ${columna} IS NOT NULL
         DO UPDATE SET
           id_caso_fraude = EXCLUDED.id_caso_fraude,
           puntos = EXCLUDED.puntos,
           ultima_evidencia = EXCLUDED.ultima_evidencia
         RETURNING id_evidencia_caso_fraude`,
        [idCasoFraude, hallazgo.idOrigen, puntos, hallazgo.ultimaEvidencia],
      );
      idEvidenciaPorHallazgo.set(
        hallazgo,
        Number(resultado.rows[0].id_evidencia_caso_fraude),
      );
    }
    return idEvidenciaPorHallazgo;
  }

  /** Borra la membresia vieja del caso y la vuelve a armar entera desde
   * las cuentas de cada hallazgo -- mas simple y menos propenso a dejar
   * una fila huerfana que calcular un diff a mano. */
  private async sincronizarCuentas(
    cliente: PoolClient,
    idCasoFraude: number,
    hallazgos: Hallazgo[],
    idEvidenciaPorHallazgo: Map<Hallazgo, number>,
    cuentas: Map<number, boolean>,
  ): Promise<void> {
    await cliente.query(
      `DELETE FROM evidencia_caso_fraude_cuenta
        WHERE id_evidencia_caso_fraude IN (
          SELECT id_evidencia_caso_fraude
            FROM evidencia_caso_fraude
           WHERE id_caso_fraude = $1
        )`,
      [idCasoFraude],
    );

    for (const hallazgo of hallazgos) {
      const idEvidencia = idEvidenciaPorHallazgo.get(hallazgo)!;
      for (const cuenta of hallazgo.cuentas) {
        await cliente.query(
          `INSERT INTO evidencia_caso_fraude_cuenta (id_evidencia_caso_fraude, id_usuario, es_nucleo)
           VALUES ($1, $2, $3)`,
          [idEvidencia, cuenta, cuentas.get(cuenta) ?? false],
        );
      }
    }
  }

  private async sincronizarReglas(
    cliente: PoolClient,
    idCasoFraude: number,
    reglas: string[],
  ): Promise<void> {
    await cliente.query(
      `DELETE FROM caso_fraude_regla WHERE id_caso_fraude = $1`,
      [idCasoFraude],
    );
    if (reglas.length === 0) {
      return;
    }
    await cliente.query(
      `INSERT INTO caso_fraude_regla (id_caso_fraude, id_regla_casi_confirmado)
       SELECT $1, id_regla_casi_confirmado
         FROM regla_casi_confirmado
        WHERE regla_casi_confirmado_nombre = ANY($2)`,
      [idCasoFraude, reglas],
    );
  }

  private calcularNivel(puntaje: number, reglas: string[]): string {
    if (reglas.length > 0) return 'casi_confirmado';
    if (puntaje >= 50) return 'prioritario';
    if (puntaje >= 20) return 'revisar';
    return 'informativo';
  }

  private ultimaEvidenciaDe(hallazgos: Hallazgo[]): Date {
    return hallazgos.reduce(
      (maxima, hallazgo) =>
        hallazgo.ultimaEvidencia > maxima ? hallazgo.ultimaEvidencia : maxima,
      hallazgos[0].ultimaEvidencia,
    );
  }

  /** Tipo+clave de cada hallazgo, ordenado y unido -- si cambia entre dos
   * corridas, la evidencia ya no es la misma que cuando se descarto. */
  private construirFirma(hallazgos: Hallazgo[]): string {
    return hallazgos
      .map(
        (hallazgo) => `${hallazgo.fuente}:${hallazgo.tipo}:${hallazgo.clave}`,
      )
      .sort()
      .join('|');
  }
}
