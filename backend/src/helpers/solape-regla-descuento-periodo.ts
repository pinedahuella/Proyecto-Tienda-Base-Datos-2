/**
 * Si dos reglas de `regla_descuento_periodo` de la misma oferta se solapan
 * en algun dia real -- la comprobacion que faltaba desde que se decidio
 * que una oferta puede tener varias reglas de periodo activas a la vez
 * (ver `elementos Generales/plan pendiente/reglas-descuento-periodos.md`),
 * siempre que nunca coincidan en un mismo dia.
 *
 * El enfoque: representar el rango de dia/mes de cada regla como una
 * mascara de 12*31 casillas (mes 1-12, dia 1-31). Una casilla que no es un
 * dia real (el 30 de febrero) no le hace dano a nadie: nunca la marcan dos
 * reglas que de verdad compartan una fecha real por casualidad, y si una
 * regla si la marca (porque su rango la incluye), es tan valido como
 * cualquier otro dia de ese rango -- la tabla tampoco valida que el dia
 * exista dentro del mes (ver el modelo). Dos reglas se solapan si sus
 * mascaras comparten al menos una casilla Y ademas comparten al menos un
 * anio en el que las dos puedan ocurrir:
 *
 * - Las dos sin `anio` (recurrentes, por mes o por dia) -> comparten TODOS
 *   los anios, el solape de mascara alcanza solo.
 * - Una con `anio` y la otra sin -> la recurrente tambien ocurre en el
 *   anio de la otra, el solape de mascara alcanza.
 * - Las dos con `anio` -> solo si es el MISMO anio; anios distintos nunca
 *   se solapan, sin importar el rango de dia/mes.
 *
 * Una regla "con anio" se asume que NO cruza al anio siguiente (mismo
 * criterio que el ejemplo del plan pendiente, "del 2026-12-20 al
 * 2026-12-31"): el rango de dia/mes se arma dentro de ese unico anio. Solo
 * las reglas "sin anio" (recurrentes) cruzan el fin de ano libremente.
 */

const MESES = 12;
const DIAS_POR_MES = 31;

export interface RangoPeriodo {
  dia_inicio: number;
  dia_fin: number;
  mes_inicio: number | null;
  mes_fin: number | null;
  anio: number | null;
}

function indice(mes: number, dia: number): number {
  return (mes - 1) * DIAS_POR_MES + (dia - 1);
}

/** Marca un rango de dias DENTRO de un mismo mes -- con wrap si diaFin < diaInicio. */
function marcarRangoDias(
  mascara: boolean[],
  mes: number,
  diaInicio: number,
  diaFin: number,
): void {
  if (diaInicio <= diaFin) {
    for (let dia = diaInicio; dia <= diaFin; dia++) {
      mascara[indice(mes, dia)] = true;
    }
  } else {
    for (let dia = diaInicio; dia <= 31; dia++) {
      mascara[indice(mes, dia)] = true;
    }
    for (let dia = 1; dia <= diaFin; dia++) {
      mascara[indice(mes, dia)] = true;
    }
  }
}

/**
 * La mascara de dia/mes que cubre un rango -- sin mes (nivel "todos los
 * meses"), o con mes (nivel "recurrente por anio" o "un anio exacto": los
 * dos arman la mascara igual, la diferencia esta en `comparteAlgunAnio`).
 */
function mascaraDeRango(rango: RangoPeriodo): boolean[] {
  const mascara = new Array<boolean>(MESES * DIAS_POR_MES).fill(false);

  if (rango.mes_inicio == null) {
    for (let mes = 1; mes <= 12; mes++) {
      marcarRangoDias(mascara, mes, rango.dia_inicio, rango.dia_fin);
    }
    return mascara;
  }

  const mesInicio = rango.mes_inicio;
  const mesFin = rango.mes_fin as number;

  if (mesInicio === mesFin) {
    marcarRangoDias(mascara, mesInicio, rango.dia_inicio, rango.dia_fin);
    return mascara;
  }

  for (let dia = rango.dia_inicio; dia <= 31; dia++) {
    mascara[indice(mesInicio, dia)] = true;
  }
  let mes = (mesInicio % 12) + 1;
  while (mes !== mesFin) {
    for (let dia = 1; dia <= 31; dia++) {
      mascara[indice(mes, dia)] = true;
    }
    mes = (mes % 12) + 1;
  }
  for (let dia = 1; dia <= rango.dia_fin; dia++) {
    mascara[indice(mesFin, dia)] = true;
  }
  return mascara;
}

function comparteAlgunAnio(a: RangoPeriodo, b: RangoPeriodo): boolean {
  if (a.anio == null || b.anio == null) {
    return true;
  }
  return a.anio === b.anio;
}

/** true si los dos rangos comparten al menos un dia real posible. */
export function reglasDePeriodoSeSolapan(
  a: RangoPeriodo,
  b: RangoPeriodo,
): boolean {
  if (!comparteAlgunAnio(a, b)) {
    return false;
  }
  const mascaraA = mascaraDeRango(a);
  const mascaraB = mascaraDeRango(b);
  return mascaraA.some((valor, i) => valor && mascaraB[i]);
}
