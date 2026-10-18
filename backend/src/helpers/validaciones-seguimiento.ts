import { ErrorValidacion } from './errores';

/**
 * Reglas de /comprador/seguimientos: lo que el comprador pide seguir
 * (`busqueda` o `baja_precio`) y el marcado de sus avisos. Los ids del
 * catalogo usan `validarIdProducto` / `validarIdProductoVariante` de
 * validaciones-inventario.ts, los mismos que POST /vendedor/ofertas.
 */

export const TIPOS_SEGUIMIENTO = ['busqueda', 'baja_precio'];

export const ESTADOS_SEGUIMIENTO = ['activos', 'cumplidos'];

/** Igual al CHECK de seguimiento_oferta.texto y al tope del buscador de ofertas. */
const LONGITUD_MAXIMA_TEXTO_SEGUIMIENTO = 100;

const REGEX_ID = /^\d+$/;

/** Mismo formato que los precios del resto del backend: texto, hasta 2 decimales. */
const REGEX_PRECIO = /^\d+(\.\d{1,2})?$/;

/** El tope de numeric(12,2). */
const PRECIO_MAXIMO_COLUMNA = 9999999999.99;

export function validarTipoSeguimiento(valor: unknown): string {
  if (typeof valor !== 'string' || !TIPOS_SEGUIMIENTO.includes(valor)) {
    throw new ErrorValidacion(
      `El tipo es obligatorio y debe ser uno de: ${TIPOS_SEGUIMIENTO.join(', ')}`,
    );
  }
  return valor;
}

export function validarTextoSeguimiento(valor: unknown): string {
  const texto = typeof valor === 'string' ? valor.trim() : '';
  if (texto === '') {
    throw new ErrorValidacion('El texto de la busqueda es obligatorio');
  }
  if (texto.length > LONGITUD_MAXIMA_TEXTO_SEGUIMIENTO) {
    throw new ErrorValidacion(
      `La busqueda no puede pasar de ${LONGITUD_MAXIMA_TEXTO_SEGUIMIENTO} caracteres`,
    );
  }
  return texto;
}

/** `precio_maximo` y `precio_referencia`: opcionales, texto mayor a 0 con hasta 2 decimales. */
export function validarPrecioSeguimiento(
  valor: unknown,
  nombreCampo: string,
): string | null {
  if (valor == null) {
    return null;
  }
  if (
    typeof valor !== 'string' ||
    !REGEX_PRECIO.test(valor) ||
    Number(valor) <= 0 ||
    Number(valor) > PRECIO_MAXIMO_COLUMNA
  ) {
    throw new ErrorValidacion(
      `${nombreCampo} debe ser un numero mayor a 0, con hasta 2 decimales`,
    );
  }
  return valor;
}

/** `solo_tienda`: opcional, `false` si no viene. */
export function validarSoloTienda(valor: unknown): boolean {
  if (valor == null) {
    return false;
  }
  if (typeof valor !== 'boolean') {
    throw new ErrorValidacion('solo_tienda debe ser true o false');
  }
  return valor;
}

/** Un campo que no es de ese tipo de seguimiento: se rechaza en vez de ignorarlo en silencio. */
export function exigirAusente(
  valor: unknown,
  campo: string,
  tipo: string,
): void {
  if (valor !== undefined) {
    throw new ErrorValidacion(`${campo} no se usa con tipo ${tipo}`);
  }
}

export function validarFiltroEstadoSeguimiento(
  valor: string | undefined,
): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!ESTADOS_SEGUIMIENTO.includes(valor)) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_SEGUIMIENTO.join(', ')}`,
    );
  }
  return valor;
}

export function validarFiltroNoLeidos(valor: string | undefined): boolean {
  if (valor == null || valor === '') {
    return false;
  }
  if (valor !== 'true' && valor !== 'false') {
    throw new ErrorValidacion('no_leidos debe ser "true" o "false"');
  }
  return valor === 'true';
}

export function validarLeido(valor: unknown): boolean {
  if (typeof valor !== 'boolean') {
    throw new ErrorValidacion('leido es obligatorio y debe ser true o false');
  }
  return valor;
}

/** El `:id` de la ruta (seguimiento o aviso). */
export function validarIdSeguimiento(valor: string): string {
  if (!REGEX_ID.test(valor)) {
    throw new ErrorValidacion('El id no es valido');
  }
  return valor;
}
