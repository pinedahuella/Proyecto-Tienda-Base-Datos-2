import { ErrorValidacion } from './errores';
import {
  ESTADOS_OFERTA,
  ESTADOS_OFERTA_VALIDOS,
} from '../models/estado-oferta';

/**
 * Reglas de PATCH /vendedor/ofertas/:id: que estado se le puede poner a una
 * oferta propia, y el ajuste manual de su stock.
 */

export function validarEstadoOferta(valor: unknown): string {
  if (typeof valor !== 'string' || !ESTADOS_OFERTA_VALIDOS.includes(valor)) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_OFERTA_VALIDOS.join(', ')}`,
    );
  }
  return valor;
}

/**
 * Un ajuste manual de stock: entero distinto de 0. Positivo repone (motivo
 * "reposicion"), negativo corrige a la baja (motivo "ajuste") -- los dos
 * unicos motivos que reponer_stock() admite fuera del flujo del pedido
 * (ver migrations/007_flujo_pedido.sql).
 */
export function validarAjusteStock(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor === 0) {
    throw new ErrorValidacion(
      'El ajuste_stock debe ser un numero entero distinto de 0',
    );
  }
  return valor;
}

/**
 * El filtro `estado` de GET /vendedor/ofertas/paginado: opcional, uno de
 * los cinco `ESTADOS_OFERTA` (`pendiente`/`activa`/`pausada`/`retirada`/
 * `rechazada`) -- a diferencia de `PATCH /vendedor/ofertas/:id`
 * (`validarEstadoOferta`, que solo admite los tres que un vendedor puede
 * PONER), aqui se puede filtrar por CUALQUIERA de los cinco, incluidos
 * `pendiente` y `rechazada`: es una lectura, no una escritura. Ausente (o
 * vacio) devuelve `null` -- sin filtrar, todas, igual que la ruta sin
 * paginar. Mismo criterio que `validarFiltroEstadoAlerta` de
 * `validaciones-fraude.ts`.
 */
export function validarFiltroEstadoOferta(
  valor: string | undefined,
): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!ESTADOS_OFERTA.includes(valor)) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_OFERTA.join(', ')}`,
    );
  }
  return valor;
}

/**
 * Reglas de PATCH /vendedor/ofertas/:id/revision: la decision de la tienda
 * sobre una oferta pendiente.
 */

const DECISIONES_REVISION = ['aprobar', 'rechazar'];

export function validarDecisionRevision(valor: unknown): string {
  if (typeof valor !== 'string' || !DECISIONES_REVISION.includes(valor)) {
    throw new ErrorValidacion(
      `La decision debe ser una de: ${DECISIONES_REVISION.join(', ')}`,
    );
  }
  return valor;
}

/**
 * El motivo de un rechazo: obligatorio, texto no vacio. Se guarda ya
 * recortado en `rechazo_oferta.razon_rechazo`, que ademas tiene un CHECK
 * de no-vacio en la base -- esto da el 400 amable antes de llegar ahi.
 */
export function validarRazonRechazo(valor: unknown): string {
  if (typeof valor !== 'string' || valor.trim().length === 0) {
    throw new ErrorValidacion(
      'La razon del rechazo es obligatoria y no puede estar vacia',
    );
  }
  return valor.trim();
}

/**
 * Reglas de `POST /vendedor/ofertas/:id/descuento`: el % de descuento a
 * aplicar.
 */

/** Hasta 2 decimales, como el precio -- ver `REGEX_PRECIO` en validaciones-crear-producto.ts. */
const REGEX_PORCENTAJE = /^\d+(\.\d{1,2})?$/;

/**
 * Entre 1 y 90, hasta 2 decimales. 0 no es un descuento (para eso esta
 * `DELETE .../descuento`); 90 es un limite de sanidad de negocio, mas
 * estricto que el `CHECK` de la base (que solo exige < 100) -- 100 dejaria
 * el precio final en 0, y un descuento tan grande sin mas contexto huele a
 * error de tipeo, no a una promocion real.
 */
export function validarPorcentajeDescuento(valor: unknown): string {
  if (
    typeof valor !== 'number' ||
    !Number.isFinite(valor) ||
    !REGEX_PORCENTAJE.test(String(valor)) ||
    valor < 1 ||
    valor > 90
  ) {
    throw new ErrorValidacion(
      'El porcentaje_descuento debe ser un numero entre 1 y 90, con hasta 2 decimales',
    );
  }
  return String(valor);
}

/**
 * `duracion_segundos` de `POST .../venta-limitada` y (agregado 2026-09-24)
 * `POST .../descuento`: cuando cierra por su cuenta -- `0` = sin
 * vencimiento (hay que cerrarlo a mano). Mismo campo, mismo rango, mismo
 * mensaje en los dos endpoints -- antes vivia solo como metodo privado de
 * `VentasLimitadasService`, se saco de ahi para no duplicarlo.
 */
const DURACION_VENCIMIENTO_MAXIMA = 7 * 24 * 60 * 60;

export function validarDuracionVencimiento(valor: unknown): number {
  if (valor == null) {
    return 0;
  }
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 0 ||
    valor > DURACION_VENCIMIENTO_MAXIMA
  ) {
    throw new ErrorValidacion(
      `La duracion_segundos debe ser un entero entre 0 y ${DURACION_VENCIMIENTO_MAXIMA} (7 dias); 0 = sin vencimiento`,
    );
  }
  return valor;
}

/**
 * Reglas de GET /vendedor/ofertas/buscar (el buscador de ofertas sobre
 * Elasticsearch). El texto, el alcance, el orden, el filtro de stock y el de
 * descuento. Los numeros (`id_vendedor`, `id_producto`, `precio_min`,
 * `precio_max`, `pagina`, `limite`) usan las de validaciones-productos.ts.
 */

/** Mas largo que el nombre de un producto no tiene sentido buscar. */
const LONGITUD_MAXIMA_BUSQUEDA_OFERTA = 100;

export const ALCANCES_BUSQUEDA_OFERTA = ['propias', 'todas'];

export const ORDENES_BUSQUEDA_OFERTA = [
  'relevancia',
  'precio_asc',
  'precio_desc',
  'descuento_desc',
  'stock_asc',
  'recientes',
];

export const FILTROS_STOCK_OFERTA = ['agotadas', 'con_stock'];

/** El texto, recortado. Vacio o ausente devuelve `null`: se busca solo por filtros. */
export function validarTextoBusquedaOferta(
  valor: string | undefined,
): string | null {
  const texto = (valor ?? '').trim();
  if (texto === '') {
    return null;
  }
  if (texto.length > LONGITUD_MAXIMA_BUSQUEDA_OFERTA) {
    throw new ErrorValidacion(
      `La busqueda no puede pasar de ${LONGITUD_MAXIMA_BUSQUEDA_OFERTA} caracteres`,
    );
  }
  return texto;
}

/** `propias` por defecto. */
export function validarAlcanceBusquedaOferta(
  valor: string | undefined,
): string {
  if (valor == null || valor === '') {
    return 'propias';
  }
  if (!ALCANCES_BUSQUEDA_OFERTA.includes(valor)) {
    throw new ErrorValidacion(
      `El alcance debe ser uno de: ${ALCANCES_BUSQUEDA_OFERTA.join(', ')}`,
    );
  }
  return valor;
}

/** Ausente devuelve `null`: el servicio decide (relevancia con texto, recientes sin el). */
export function validarOrdenBusquedaOferta(
  valor: string | undefined,
): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!ORDENES_BUSQUEDA_OFERTA.includes(valor)) {
    throw new ErrorValidacion(
      `El orden debe ser uno de: ${ORDENES_BUSQUEDA_OFERTA.join(', ')}`,
    );
  }
  return valor;
}

export function validarFiltroStockOferta(
  valor: string | undefined,
): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!FILTROS_STOCK_OFERTA.includes(valor)) {
    throw new ErrorValidacion(
      `El filtro de stock debe ser uno de: ${FILTROS_STOCK_OFERTA.join(', ')}`,
    );
  }
  return valor;
}

/** `true` / `false`, o `null` si no viene (sin filtrar). */
export function validarFiltroDescuentoOferta(
  valor: string | undefined,
): boolean | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (valor !== 'true' && valor !== 'false') {
    throw new ErrorValidacion('con_descuento debe ser "true" o "false"');
  }
  return valor === 'true';
}
