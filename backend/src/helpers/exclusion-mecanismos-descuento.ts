import { Logger } from '@nestjs/common';
import type { QueryResult, QueryResultRow } from 'pg';
import { ErrorConflicto } from './errores';
import { manejarErrorConexion } from './manejar-error-db';

/**
 * Un objeto capaz de correr `query` con la misma forma que `pool` o un
 * `PoolClient` de una transaccion ya abierta -- estructural a proposito,
 * para poder reusar el mismo chequeo dentro de una transaccion existente
 * (`OfertasVendedorService.aplicarDescuento()`) sin abrir una conexion
 * aparte, o con el `pool` de siempre en el resto de los casos.
 */
export interface EjecutorConsulta {
  query<T extends QueryResultRow = QueryResultRow>(
    texto: string,
    valores?: unknown[],
  ): Promise<QueryResult<T>>;
}

export type MecanismoDescuento =
  | 'descuento_manual'
  | 'venta_relampago_manual'
  | 'regla_automatica'
  | 'regla_periodo';

const NOMBRE_MECANISMO: Record<MecanismoDescuento, string> = {
  descuento_manual: 'un descuento manual activo',
  venta_relampago_manual: 'una venta relampago activa',
  regla_automatica: 'una regla de descuento automatico activa',
  regla_periodo: 'una regla de descuento por periodo activa',
};

interface FilaMecanismos extends QueryResultRow {
  descuento_manual: boolean;
  venta_relampago_manual: boolean;
  regla_automatica: boolean;
  regla_periodo: boolean;
}

/**
 * Contra que otros mecanismos choca cada uno al activarse. NO es una
 * matriz simetrica a proposito: `descuento_manual` y
 * `venta_relampago_manual` NO se excluyen entre si -- una venta relampago
 * manual EXIGE un descuento manual ya puesto (`abrir()` en
 * `VentasLimitadasService` da 409 si falta), asi que son la misma "pista
 * manual", no dos mecanismos en competencia. Las dos reglas (automatica y
 * por periodo) si excluyen a los cuatro restantes -- incluida la otra
 * regla y las dos manuales.
 */
const EXCLUYE: Record<MecanismoDescuento, readonly MecanismoDescuento[]> = {
  descuento_manual: ['regla_automatica', 'regla_periodo'],
  venta_relampago_manual: ['regla_automatica', 'regla_periodo'],
  regla_automatica: [
    'descuento_manual',
    'venta_relampago_manual',
    'regla_periodo',
  ],
  regla_periodo: [
    'descuento_manual',
    'venta_relampago_manual',
    'regla_automatica',
  ],
};

/**
 * Los cuatro mecanismos que pueden poner un descuento o abrir una venta
 * relampago en una oferta -- descuento manual (`POST .../descuento`),
 * venta relampago manual (`POST .../venta-limitada`), regla de descuento
 * automatico y regla de descuento por periodo -- son mutuamente
 * excluyentes (ver `EXCLUYE` arriba para la unica excepcion: descuento +
 * venta relampago manuales, que son la misma pista). "Activo" para las
 * dos reglas es su columna `activa = true` -- una regla pausada (`activa:
 * false`) no cuenta y no bloquea nada.
 *
 * `mecanismoQueEntra` es el que se esta por activar (crear o reactivar).
 * `regla_descuento_periodo` puede tener VARIAS reglas activas entre si
 * (contra su propio tipo no se compara aqui) siempre que sus rangos de
 * dias no se solapen -- esa comprobacion es aparte y todavia no esta
 * construida (ver `elementos Generales/plan pendiente/reglas-descuento-periodos.md`).
 * `regla_descuento_automatico` ya tiene su propio `UNIQUE(id_oferta)` para
 * lo mismo.
 *
 * Se usa ANTES de activar cualquiera de los cuatro -- crear una regla
 * (nace `activa: true`), reactivarla por `PATCH { activa: true }`,
 * `POST .../descuento` o `POST .../venta-limitada`. Nunca hace falta al
 * apagar/pausar nada.
 */
export async function exigirSinOtroMecanismoActivo(
  logger: Logger,
  ejecutor: EjecutorConsulta,
  idOferta: number,
  mecanismoQueEntra: MecanismoDescuento,
): Promise<void> {
  let fila: FilaMecanismos;
  try {
    const resultado = await ejecutor.query<FilaMecanismos>(
      `SELECT
         o.porcentaje_descuento IS NOT NULL AS descuento_manual,
         o.es_inventario_limitado AS venta_relampago_manual,
         EXISTS (
           SELECT 1 FROM regla_descuento_automatico
            WHERE id_oferta = $1 AND activa
         ) AS regla_automatica,
         EXISTS (
           SELECT 1 FROM regla_descuento_periodo
            WHERE id_oferta = $1 AND activa
         ) AS regla_periodo
       FROM oferta o
       WHERE o.id_oferta = $1`,
      [idOferta],
    );
    fila = resultado.rows[0] ?? {
      descuento_manual: false,
      venta_relampago_manual: false,
      regla_automatica: false,
      regla_periodo: false,
    };
  } catch (error) {
    manejarErrorConexion(logger, error);
  }

  for (const mecanismo of EXCLUYE[mecanismoQueEntra]) {
    if (fila[mecanismo]) {
      throw new ErrorConflicto(
        `Esta oferta ya tiene ${NOMBRE_MECANISMO[mecanismo]}: los mecanismos de descuento/venta relampago son mutuamente excluyentes, hay que desactivar ese primero`,
      );
    }
  }
}
