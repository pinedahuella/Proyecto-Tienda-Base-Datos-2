import { ErrorValidacion } from './errores';

/**
 * Reglas de validacion de POST /vendedor/reglas-descuento y
 * PATCH /vendedor/reglas-descuento/:id. `porcentaje_descuento` reutiliza
 * `validarPorcentajeDescuento` de `validaciones-oferta.ts` -- mismo campo,
 * mismo rango de negocio (1 a 90) y mismo mensaje que
 * `POST /vendedor/ofertas/:id/descuento`, no una copia con reglas propias.
 */

export function validarIdOfertaCuerpo(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor <= 0) {
    throw new ErrorValidacion(
      'El id_oferta debe ser un numero entero mayor a 0',
    );
  }
  return valor;
}

/** Tope de sanidad: mas unidades que esto en una sola ventana huele a error de tipeo, no a una regla real. */
const UMBRAL_UNIDADES_MAXIMO = 100000;

export function validarUmbralUnidades(valor: unknown): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > UMBRAL_UNIDADES_MAXIMO
  ) {
    throw new ErrorValidacion(
      `El umbral_unidades debe ser un numero entero entre 1 y ${UMBRAL_UNIDADES_MAXIMO}`,
    );
  }
  return valor;
}

/** Tope de sanidad: 7 dias en minutos. */
const VENTANA_MINUTOS_MAXIMO = 7 * 24 * 60;

export function validarVentanaMinutos(valor: unknown): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > VENTANA_MINUTOS_MAXIMO
  ) {
    throw new ErrorValidacion(
      `El ventana_minutos debe ser un numero entero entre 1 y ${VENTANA_MINUTOS_MAXIMO}`,
    );
  }
  return valor;
}

export function validarEsVentaRelampago(valor: unknown): boolean {
  if (typeof valor !== 'boolean') {
    throw new ErrorValidacion('El es_venta_relampago debe ser true o false');
  }
  return valor;
}

/**
 * Mismo tope (7 dias) que `duracion_segundos` de
 * `POST /vendedor/ofertas/:id/venta-limitada`, pero sin admitir `0`: ahi
 * `0` significa "sin vencimiento" (hay que cerrarla a mano); aca la regla
 * siempre tiene que vencer sola, `0` no tiene sentido.
 */
const DURACION_SEGUNDOS_MAXIMO = 7 * 24 * 60 * 60;

export function validarDuracionSegundos(valor: unknown): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > DURACION_SEGUNDOS_MAXIMO
  ) {
    throw new ErrorValidacion(
      `El duracion_segundos debe ser un numero entero entre 1 y ${DURACION_SEGUNDOS_MAXIMO}`,
    );
  }
  return valor;
}

export function validarActiva(valor: unknown): boolean {
  if (typeof valor !== 'boolean') {
    throw new ErrorValidacion('El activa debe ser true o false');
  }
  return valor;
}
