import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { GrupoFraude } from '../../models/fraude/grupo-fraude';
import { Hallazgo } from '../../models/fraude/hallazgo';
import { construirClave } from './hallazgo-fraude-adaptador.service';
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
    const firma = this.construirFirma(grupo.hallazgos, grupo.cuentas);

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
   * FUSIONA (se queda el de menor id y los demas se borran; su evidencia
   * la vuelve a escribir `sincronizarEvidencia`) -- el ejemplo del Caso 2 del documento original: dos
   * anillos separados que una evidencia nueva conecta.
   *
   * Los hallazgos de login no cuentan para esta busqueda: la misma senal de
   * login puede ser evidencia de varios casos a la vez, y si contara,
   * fusionaria lo que el agrupador dejo separado (item C1 de
   * `docs/BACKEND-PENDIENTE.md`).
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
    const { rows: existentes } = await cliente.query<{
      id_caso_fraude: string;
    }>(
      `SELECT DISTINCT id_caso_fraude FROM evidencia_caso_fraude
        WHERE id_senal_fraude = ANY($1::bigint[])`,
      [
        hallazgos
          .filter((hallazgo) => hallazgo.fuente !== 'login')
          .map((hallazgo) => hallazgo.idOrigen),
      ],
    );
    const idsExistentes = new Set(
      existentes.map((fila) => Number(fila.id_caso_fraude)),
    );

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

    // La evidencia de los sobrantes no se mueve: `sincronizarEvidencia`
    // escribe la del grupo entera en el sobreviviente.
    for (const idSobrante of idsSobrantes) {
      await cliente.query(
        `DELETE FROM evidencia_caso_fraude WHERE id_caso_fraude = $1`,
        [idSobrante],
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

  /**
   * Deja la evidencia del caso IGUAL a los hallazgos del grupo: upsert de
   * uno por hallazgo (unico por caso y senal) y borra la que ya no esta.
   *
   * Lo que se borra es evidencia que ya no es vigente (el admin la
   * descarto) o que es de otro grupo: un caso que una version vieja junto
   * de mas se parte asi. El primer grupo que lo toca se queda con el caso
   * (y su estado); los demas ya no encuentran ahi su evidencia y abren uno
   * nuevo, `pendiente`.
   *
   * Devuelve el id de evidencia de cada hallazgo, para que
   * `sincronizarCuentas` sepa a cual enganchar cada cuenta.
   */
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
         ON CONFLICT (id_caso_fraude, id_senal_fraude)
         DO UPDATE SET
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
    await cliente.query(
      `DELETE FROM evidencia_caso_fraude
        WHERE id_caso_fraude = $1
          AND id_senal_fraude <> ALL($2::bigint[])`,
      [idCasoFraude, hallazgos.map((hallazgo) => hallazgo.idOrigen)],
    );
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
      // `cuentas` son las del caso: de un hallazgo de login solo se
      // enganchan las que ya estan por otra evidencia.
      for (const cuenta of hallazgo.cuentas.filter((c) => cuentas.has(c))) {
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
   * corridas, la evidencia ya no es la misma que cuando se descarto. La
   * clave sale de las cuentas que se guardan con la evidencia (las del
   * caso), igual que `CasosFraudeService.construirFirmaActual` al
   * descartar: en login no son todas las de la senal. */
  private construirFirma(
    hallazgos: Hallazgo[],
    cuentas: Map<number, boolean>,
  ): string {
    return hallazgos
      .map(
        (hallazgo) =>
          `${hallazgo.fuente}:${hallazgo.tipo}:${construirClave(hallazgo.cuentas.filter((c) => cuentas.has(c)))}`,
      )
      .sort()
      .join('|');
  }
}
