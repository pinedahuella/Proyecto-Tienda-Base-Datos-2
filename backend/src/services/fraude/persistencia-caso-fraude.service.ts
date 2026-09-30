import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { GrupoFraude } from '../../models/fraude/grupo-fraude';
import { Hallazgo } from '../../models/fraude/hallazgo';
import { PuntajeFraudeService } from './puntaje-fraude.service';
import { ReglasCasiConfirmadoService } from './reglas-casi-confirmado.service';

/** Que tan grave es cada estado, solo para decidir que hereda el
 * sobreviviente de una fusion -- ver `promocionDeEstado()`. `descartada`
 * va en el medio (una decision real del admin) pero NUNCA se promociona
 * por esta via: reabrir un caso descartado es un camino aparte, ya
 * resuelto por el `seReabre` de `resolverCaso()`. */
const RANGO_ESTADO: Record<string, number> = {
  pendiente: 0,
  descartada: 1,
  revisada: 2,
  confirmada: 3,
};

interface EstadoCasoPrevio {
  id_caso_fraude: string;
  estado_alerta_fraude_nombre: string;
  motivo: string | null;
  firma_al_descartar: string | null;
}

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
   * Borra los casos `pendiente` que se quedaron sin ninguna evidencia --
   * `docs/BACKEND-PENDIENTE.md`, item C8. Puede pasar sin que sea un bug
   * de este servicio: `evidencia_caso_fraude` tiene `ON DELETE CASCADE`
   * desde `senal_fraude`, asi que si esa fila
   * se borra de verdad (una prueba que limpia, un admin que borra una
   * senal vieja), la evidencia
   * desaparece con ella, pero el caso que la tenia como unica evidencia
   * se queda huerfano -- nada mas lo revisita para notar que ya no le
   * queda nada.
   *
   * Solo `pendiente`: un caso que un admin ya revisó/confirmó/descartó no
   * se borra solo aunque se quede sin evidencia -- esa decision humana no
   * la borra un worker de mantenimiento. `caso_fraude_regla` tiene
   * `ON DELETE CASCADE` hacia `caso_fraude`, asi que no hace falta
   * borrarla aparte.
   *
   * La llama `AgrupadorFraudeWorkerService` una vez al final de cada
   * corrida completa (todos los grupos ya persistidos) -- nunca desde
   * `persistir()`, que es por-grupo y no sabe si otro grupo de la misma
   * corrida dejo un caso vacio.
   */
  async limpiarCasosVaciosPendientes(): Promise<number> {
    try {
      const resultado = await pool.query<{ id_caso_fraude: string }>(
        `DELETE FROM caso_fraude cf
          WHERE cf.id_estado_alerta_fraude = (
                  SELECT id_estado_alerta_fraude FROM estado_alerta_fraude
                   WHERE estado_alerta_fraude_nombre = 'pendiente'
                )
            AND NOT EXISTS (
                  SELECT 1 FROM evidencia_caso_fraude e
                   WHERE e.id_caso_fraude = cf.id_caso_fraude
                )
          RETURNING id_caso_fraude`,
      );
      return resultado.rowCount ?? 0;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
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
   *
   * **Bug corregido (2026-09-27, item C2):** al fusionar, sobrevive el de
   * menor id -- pero antes, si CUALQUIER otro de los que se fusionan
   * estaba `revisada`/`confirmada`, esa decision del admin se perdia sin
   * rastro (el caso sobrante se borra entero, solo su evidencia se movia).
   * Medido en vivo con `pruebas/casos_fraude_fusion.cjs`: un caso
   * `confirmada` fusionado dentro de uno `pendiente` volvia a quedar
   * `pendiente`. Ahora, antes de borrar los sobrantes, se captura el
   * estado/motivo de TODOS (sobreviviente incluido) y el sobreviviente
   * hereda el mas grave -- `revisarPromocionDeEstado()` para el porque
   * `descartada`/`pendiente` nunca "promocionan" por esta via (esas dos
   * las sigue manejando el reabre de arriba, sin cambios).
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
      const resultado = await cliente.query<{ id_caso_fraude: string }>(
        `SELECT id_caso_fraude FROM evidencia_caso_fraude WHERE id_senal_fraude = $1`,
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

    // Capturado ANTES de borrar nada -- una vez que un sobrante se borra,
    // su estado/motivo se pierden para siempre si no se guardaron ya.
    const previos = await cliente.query<EstadoCasoPrevio>(
      `SELECT cf.id_caso_fraude, eaf.estado_alerta_fraude_nombre, cf.motivo, cf.firma_al_descartar
         FROM caso_fraude cf
         JOIN estado_alerta_fraude eaf
           ON eaf.id_estado_alerta_fraude = cf.id_estado_alerta_fraude
        WHERE cf.id_caso_fraude = ANY($1)
        FOR UPDATE`,
      [[idSuperviviente, ...idsSobrantes]],
    );
    const estadoSuperviviente = previos.rows.find(
      (fila) => Number(fila.id_caso_fraude) === idSuperviviente,
    )!;

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

    const promocion = this.promocionDeEstado(previos.rows, estadoSuperviviente);
    const seReabre =
      promocion == null &&
      estadoSuperviviente.estado_alerta_fraude_nombre === 'descartada' &&
      estadoSuperviviente.firma_al_descartar !== firma;

    await cliente.query(
      `UPDATE caso_fraude
          SET id_nivel_caso_fraude = (SELECT id_nivel_caso_fraude FROM nivel_caso_fraude WHERE nivel_caso_fraude_nombre = $1),
              puntaje = $2,
              ultima_evidencia = $3,
              fecha_actualizacion = now()
        WHERE id_caso_fraude = $4`,
      [nivel, puntaje, ultimaEvidencia, idSuperviviente],
    );

    if (promocion != null) {
      await cliente.query(
        `UPDATE caso_fraude
            SET id_estado_alerta_fraude = (SELECT id_estado_alerta_fraude FROM estado_alerta_fraude WHERE estado_alerta_fraude_nombre = $1),
                motivo = $2
          WHERE id_caso_fraude = $3`,
        [
          promocion.estado_alerta_fraude_nombre,
          promocion.motivo,
          idSuperviviente,
        ],
      );
    } else if (seReabre) {
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

  /**
   * El mas grave entre `previos` (sobreviviente incluido) que sea
   * `revisada`/`confirmada` y supere al del sobreviviente -- `null` si
   * ninguno lo supera (incluye el caso comun de una sola fila, sin
   * fusion de verdad). Nunca devuelve `pendiente` ni `descartada`: esas
   * dos no "promocionan" nada, se manejan aparte (`descartada` con el
   * `seReabre` de `resolverCaso()`; `pendiente` simplemente no cambia
   * nada porque ya es el piso).
   */
  private promocionDeEstado(
    previos: EstadoCasoPrevio[],
    superviviente: EstadoCasoPrevio,
  ): EstadoCasoPrevio | null {
    const rangoActual = RANGO_ESTADO[superviviente.estado_alerta_fraude_nombre];
    const candidatos = previos.filter(
      (fila) =>
        (fila.estado_alerta_fraude_nombre === 'confirmada' ||
          fila.estado_alerta_fraude_nombre === 'revisada') &&
        RANGO_ESTADO[fila.estado_alerta_fraude_nombre] > rangoActual,
    );
    if (candidatos.length === 0) {
      return null;
    }
    return candidatos.sort(
      (a, b) =>
        RANGO_ESTADO[b.estado_alerta_fraude_nombre] -
        RANGO_ESTADO[a.estado_alerta_fraude_nombre],
    )[0];
  }

  /** Upsert de un `evidencia_caso_fraude` por hallazgo (por senal) -- el
   * `ON CONFLICT` usa el indice unico parcial de `id_senal_fraude`. Devuelve
   * el id de evidencia de cada hallazgo, para que `sincronizarCuentas` sepa
   * a cual enganchar cada cuenta. */
  private async sincronizarEvidencia(
    cliente: PoolClient,
    idCasoFraude: number,
    hallazgos: Hallazgo[],
  ): Promise<Map<Hallazgo, number>> {
    const idEvidenciaPorHallazgo = new Map<Hallazgo, number>();
    for (const hallazgo of hallazgos) {
      const puntos = this.puntajeFraudeService.puntosDeHallazgo(hallazgo);
      const resultado = await cliente.query<{
        id_evidencia_caso_fraude: string;
      }>(
        `INSERT INTO evidencia_caso_fraude (id_caso_fraude, id_senal_fraude, puntos, ultima_evidencia)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (id_senal_fraude) WHERE id_senal_fraude IS NOT NULL
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

  /**
   * Borra la membresia vieja de CADA evidencia que se esta guardando en
   * esta llamada, y la vuelve a armar entera desde las cuentas de su
   * hallazgo -- mas simple y menos propenso a dejar una fila huerfana que
   * calcular un diff a mano.
   *
   * **Bug corregido (2026-09-27):** el `DELETE` borraba la membresia de
   * TODA la evidencia del caso (`WHERE id_caso_fraude = ...`), no solo la
   * de `hallazgos` -- cuando dos grupos distintos terminaban en el mismo
   * caso (una fusion, o evidencia que ya existia de una corrida anterior),
   * el segundo `persistir()` borraba las cuentas que el primero ya habia
   * puesto, sin volver a insertarlas (`hallazgos` aca es solo lo del
   * grupo que se esta guardando ahora). Medido en vivo contra la base real
   * (`docs/BACKEND-PENDIENTE.md`, item C3): 105 evidencias sin ninguna
   * cuenta. Ahora el `DELETE` va scopeado a los ids de evidencia de
   * `idEvidenciaPorHallazgo` (exactamente lo que este `for` esta a punto
   * de reinsertar), nunca a evidencia ajena del mismo caso.
   */
  private async sincronizarCuentas(
    cliente: PoolClient,
    hallazgos: Hallazgo[],
    idEvidenciaPorHallazgo: Map<Hallazgo, number>,
    cuentas: Map<number, boolean>,
  ): Promise<void> {
    const idsEvidencia = [...idEvidenciaPorHallazgo.values()];
    await cliente.query(
      `DELETE FROM evidencia_caso_fraude_cuenta
        WHERE id_evidencia_caso_fraude = ANY($1)`,
      [idsEvidencia],
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
