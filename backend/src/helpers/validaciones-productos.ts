import { ErrorValidacion } from './errores';

/**
 * Reglas de validacion y saneamiento de GET /productos: la paginacion por
 * cursor, los filtros fijos (nombre, estado, categoria, vendedor, precio,
 * estado de variante) y los filtros dinamicos de caracteristicas_adicionales.
 */

export const LIMITE_PRODUCTOS_DEFECTO = 20;
export const LIMITE_PRODUCTOS_MAXIMO = 100;

const REGEX_ENTERO = /^\d+$/;
const REGEX_PRECIO = /^\d+(\.\d{1,2})?$/;
/**
 * Nombre de una caracteristica adicional: letras, numeros y guion bajo, con
 * puntos opcionales para entrar un nivel en un campo anidado (por ejemplo
 * memoria_ram.valor). Nunca admite "$": como siempre se antepone
 * "caracteristicas_adicionales.", esto evita que alguien intente inyectar un
 * operador de Mongo a traves del nombre del query param.
 */
const REGEX_CLAVE_ATRIBUTO = /^[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*$/;

/** limite es opcional: si no viene, se usa el valor por defecto. */
export function validarLimite(valor: string | undefined): number {
  if (valor == null || valor === '') {
    return LIMITE_PRODUCTOS_DEFECTO;
  }
  if (!REGEX_ENTERO.test(valor) || Number(valor) < 1) {
    throw new ErrorValidacion('El limite debe ser un numero entero mayor a 0');
  }
  return Math.min(Number(valor), LIMITE_PRODUCTOS_MAXIMO);
}

/** despues_de es el cursor: el _id del ultimo producto visto. Opcional. */
export function validarDespuesDe(valor: string | undefined): number | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!REGEX_ENTERO.test(valor)) {
    throw new ErrorValidacion('despues_de debe ser un numero entero');
  }
  return Number(valor);
}

/** pagina es el numero de pagina (1 es la primera). Opcional, por defecto 1. */
export function validarPagina(valor: string | undefined): number {
  if (valor == null || valor === '') {
    return 1;
  }
  if (!REGEX_ENTERO.test(valor) || Number(valor) < 1) {
    throw new ErrorValidacion('La pagina debe ser un numero entero mayor a 0');
  }
  return Number(valor);
}

/** Para id_categoria e id_vendedor: enteros positivos, opcionales. */
export function validarEnteroPositivo(
  valor: string | undefined,
  nombreCampo: string,
): number | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!REGEX_ENTERO.test(valor)) {
    throw new ErrorValidacion(`${nombreCampo} debe ser un numero entero`);
  }
  return Number(valor);
}

/** Para precio_min y precio_max: numeros con hasta 2 decimales, opcionales. */
export function validarPrecio(
  valor: string | undefined,
  nombreCampo: string,
): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!REGEX_PRECIO.test(valor)) {
    throw new ErrorValidacion(
      `${nombreCampo} debe ser un numero valido, con hasta 2 decimales`,
    );
  }
  return valor;
}

/** true si el nombre de un query param es seguro para usar como campo de Mongo. */
export function esClaveAtributoValida(clave: string): boolean {
  return REGEX_CLAVE_ATRIBUTO.test(clave);
}

/**
 * Convierte el valor de texto de un query param al tipo que probablemente
 * tiene guardado en Mongo: "true"/"false" a boolean, numeros a Number, y el
 * resto se queda como string. Sin esto, comparar contra un campo numerico
 * (ram: 16) con el texto "16" nunca haria match.
 */
export function coercionarValorAtributo(
  valor: string,
): string | number | boolean {
  if (valor === 'true') {
    return true;
  }
  if (valor === 'false') {
    return false;
  }
  if (/^-?\d+(\.\d+)?$/.test(valor)) {
    return Number(valor);
  }
  return valor;
}

/** Escapa caracteres especiales de regex antes de usar un texto en un $regex. */
export function escaparRegex(texto: string): string {
  return texto.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
