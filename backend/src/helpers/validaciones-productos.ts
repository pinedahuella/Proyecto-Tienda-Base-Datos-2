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

/** Igual al varchar(100) de caracteristica.nombre / caracteristica_variante.nombre en PostgreSQL. */
const LONGITUD_MAXIMA_NOMBRE_CARACTERISTICA = 100;

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

/**
 * true si un nombre de caracteristica es razonable para buscarlo. Ya no hay
 * que restringir que caracteres trae: el nombre nunca se usa para armar una
 * ruta de campo de Mongo (eso exigia la restriccion de antes), se compara
 * como un valor de texto normal dentro de un $elemMatch (`{ nombre: clave }`),
 * asi que "Memoria RAM" o "Pais de origen" son tan validos como "marca". Solo
 * se descarta lo que no podria ser un nombre real: vacio, o mas largo que la
 * columna que lo guarda en PostgreSQL.
 */
export function esNombreCaracteristicaValido(clave: string): boolean {
  const limpio = clave.trim();
  return (
    limpio.length > 0 && limpio.length <= LONGITUD_MAXIMA_NOMBRE_CARACTERISTICA
  );
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

/**
 * Arma la condicion de "valor" para el $elemMatch de una caracteristica: si
 * el texto del query param se pudo convertir a Number o Boolean, busca
 * contra ese valor convertido Y contra el texto tal cual con $in, porque la
 * carga actual todavia guarda todo como string (ver
 * pendientes-etl-caracteristicas.md) y no hay que asumir que ya esta
 * corregido. Si no se pudo convertir (ya es texto), no hace falta el $in:
 * son el mismo valor.
 */
export function valorParaBuscarCaracteristica(
  valorCrudo: string,
): string | number | boolean | { $in: (string | number | boolean)[] } {
  const valorCoercionado = coercionarValorAtributo(valorCrudo);
  if (valorCoercionado === valorCrudo) {
    return valorCrudo;
  }
  return { $in: [valorCoercionado, valorCrudo] };
}

const PREFIJO_MIN = 'min_';
const PREFIJO_MAX = 'max_';
const PREFIJO_CONTIENE = 'contiene_';

/** Lo que interpretarFiltroCaracteristica saca de un query param dinamico. */
export interface FiltroCaracteristica {
  nombreCaracteristica: string;
  condicionValor: unknown;
}

/**
 * Interpreta un query param dinamico de GET /productos como un filtro
 * "universal" sobre una caracteristica: el prefijo dice el operador
 * (min_/max_/contiene_), el resto del nombre es la caracteristica, y sin
 * prefijo es igualdad (como siempre). El operador se aplica tal cual contra
 * lo que haya en Mongo -- si el tipo guardado no calza con el operador (por
 * ejemplo min_ sobre una caracteristica de texto), simplemente no hace
 * match, no es un error: el filtro se aplica igual a caracteristicas
 * adicionales y personalizadas, sin necesidad de saber su tipo_dato de
 * antemano.
 */
export function interpretarFiltroCaracteristica(
  clave: string,
  valorCrudo: string,
): FiltroCaracteristica {
  if (clave.startsWith(PREFIJO_MIN)) {
    return {
      nombreCaracteristica: clave.slice(PREFIJO_MIN.length),
      condicionValor: { $gte: coercionarValorAtributo(valorCrudo) },
    };
  }
  if (clave.startsWith(PREFIJO_MAX)) {
    return {
      nombreCaracteristica: clave.slice(PREFIJO_MAX.length),
      condicionValor: { $lte: coercionarValorAtributo(valorCrudo) },
    };
  }
  if (clave.startsWith(PREFIJO_CONTIENE)) {
    return {
      nombreCaracteristica: clave.slice(PREFIJO_CONTIENE.length),
      condicionValor: { $regex: escaparRegex(valorCrudo), $options: 'i' },
    };
  }
  return {
    nombreCaracteristica: clave,
    condicionValor: valorParaBuscarCaracteristica(valorCrudo),
  };
}

/** Escapa caracteres especiales de regex antes de usar un texto en un $regex. */
export function escaparRegex(texto: string): string {
  return texto.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
