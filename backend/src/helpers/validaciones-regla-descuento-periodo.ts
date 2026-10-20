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

const NOMBRES_MES = [
  'Enero',
  'Febrero',
  'Marzo',
  'Abril',
  'Mayo',
  'Junio',
  'Julio',
  'Agosto',
  'Septiembre',
  'Octubre',
  'Noviembre',
  'Diciembre',
];

/** Los dias del mes. Febrero sin anio tiene 29, porque la regla se repite y algun anio es bisiesto. */
export function diasDelMes(mes: number, anio: number | null): number {
  if (mes === 2) {
    if (anio == null) return 29;
    const bisiesto = (anio % 4 === 0 && anio % 100 !== 0) || anio % 400 === 0;
    return bisiesto ? 29 : 28;
  }
  return [4, 6, 9, 11].includes(mes) ? 30 : 31;
}

/** El dia de hoy en Guatemala como AAAA-MM-DD, que se compara como texto. */
function hoyEnGuatemala(): string {
  return new Date().toLocaleDateString('en-CA', {
    timeZone: 'America/Guatemala',
  });
}

const dosCifras = (n: number) => String(n).padStart(2, '0');

/**
 * Que las fechas de la regla existan y puedan ocurrir (Meme, 2026-10-20).
 * Antes se guardaba el 31 de febrero, o "del 20 de diciembre al 5 de enero de
 * 2026", que con un solo anio el disparador arma como diciembre y enero del
 * mismo 2026 (ver solape-regla-descuento-periodo.ts).
 *
 *   - Con mes, cada dia existe en su mes (febrero 29 sin anio, 28 o 29 con).
 *   - Con anio, la regla no pasa al anio siguiente: para cruzar el fin de anio
 *     se deja sin anio y se repite.
 *   - Con anio, la regla no termina antes de hoy, porque nunca se aplicaria.
 *     `exigirQueNoHayaPasado` es false al editar sin tocar las fechas, para
 *     poder pausar o borrar una regla vieja.
 *
 * Sin mes la regla es "del X al Y de cada mes" y puede dar la vuelta (del 25
 * al 5); un dia 31 solo cae en los meses que lo tienen.
 */
export function validarFechasPosibles(
  estado: {
    dia_inicio: number;
    dia_fin: number;
    mes_inicio: number | null;
    mes_fin: number | null;
    anio: number | null;
  },
  exigirQueNoHayaPasado: boolean,
): void {
  const { dia_inicio, dia_fin, mes_inicio, mes_fin, anio } = estado;
  if (mes_inicio == null || mes_fin == null) return;

  for (const [dia, mes] of [
    [dia_inicio, mes_inicio],
    [dia_fin, mes_fin],
  ]) {
    const tope = diasDelMes(mes, anio);
    if (dia > tope) {
      const cual =
        anio == null
          ? NOMBRES_MES[mes - 1]
          : `${NOMBRES_MES[mes - 1]} de ${anio}`;
      throw new ErrorValidacion(
        `${cual} tiene ${tope} dias, el ${dia} no existe`,
      );
    }
  }

  if (anio == null) return;
  if (
    mes_fin < mes_inicio ||
    (mes_fin === mes_inicio && dia_fin < dia_inicio)
  ) {
    throw new ErrorValidacion(
      'Con un anio fijo la regla no puede pasar al anio siguiente. Para que cruce el fin de anio, dejala para todos los anios',
    );
  }
  const fin = `${anio}-${dosCifras(mes_fin)}-${dosCifras(dia_fin)}`;
  if (exigirQueNoHayaPasado && fin < hoyEnGuatemala()) {
    throw new ErrorValidacion(`Esas fechas de ${anio} ya pasaron`);
  }
}
