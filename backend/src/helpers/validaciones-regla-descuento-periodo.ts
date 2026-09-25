import { ErrorValidacion } from './errores';

/**
 * Reglas de validacion propias de POST /vendedor/reglas-descuento-periodos y
 * PATCH /vendedor/reglas-descuento-periodos/:id -- las de dia/mes/anio y la
 * cascada. `id_oferta`, `es_venta_relampago`, `activa` y
 * `porcentaje_descuento` reutilizan las de
 * `validaciones-regla-descuento.ts`/`validaciones-oferta.ts` tal cual
 * (mismo campo, mismo mensaje en los dos endpoints -- no una copia con
 * reglas propias).
 */

export function validarDia(valor: unknown, nombreCampo: string): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > 31
  ) {
    throw new ErrorValidacion(
      `El ${nombreCampo} debe ser un numero entero entre 1 y 31`,
    );
  }
  return valor;
}

export function validarMes(valor: unknown, nombreCampo: string): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > 12
  ) {
    throw new ErrorValidacion(
      `El ${nombreCampo} debe ser un numero entero entre 1 y 12`,
    );
  }
  return valor;
}

const ANIO_MINIMO = 2000;
const ANIO_MAXIMO = 2100;

export function validarAnio(valor: unknown): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < ANIO_MINIMO ||
    valor > ANIO_MAXIMO
  ) {
    throw new ErrorValidacion(
      `El anio debe ser un numero entero entre ${ANIO_MINIMO} y ${ANIO_MAXIMO}`,
    );
  }
  return valor;
}

/**
 * La cascada completa (mismas dos reglas que los CHECK de
 * `regla_descuento_periodo`, validadas aca tambien para dar el mismo
 * mensaje en crear y en editar -- en editar, el llamador arma este objeto
 * mezclando lo que llega con lo que ya tenia la fila, asi que esta funcion
 * ve siempre el estado FINAL, nunca solo lo que vino en la peticion):
 * `mes_inicio`/`mes_fin` van siempre juntos (los dos o ninguno), y `anio`
 * no puede venir sin mes.
 */
export function validarCascada(estado: {
  mes_inicio: number | null;
  mes_fin: number | null;
  anio: number | null;
}): void {
  const tieneMesInicio = estado.mes_inicio != null;
  const tieneMesFin = estado.mes_fin != null;
  if (tieneMesInicio !== tieneMesFin) {
    throw new ErrorValidacion(
      'mes_inicio y mes_fin deben venir juntos, o ninguno de los dos',
    );
  }
  if (estado.anio != null && !tieneMesInicio) {
    throw new ErrorValidacion('anio no puede venir sin mes_inicio y mes_fin');
  }
}
