import { ErrorValidacion } from './errores';
import { ESTADOS_OFERTA_VALIDOS } from '../models/estado-oferta';

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
 * El filtro `activo` de GET /vendedor/ofertas/paginado: un booleano de
 * texto, opcional. `"true"` recorta a las ofertas en estado `activa`;
 * `"false"` a las que NO lo estan (pendiente, pausada, retirada o
 * rechazada); ausente (o vacio) devuelve `null` -- sin filtrar por estado,
 * igual que la ruta sin paginar. Cualquier otro valor es un 400.
 */
export function validarFiltroActivo(valor: string | undefined): boolean | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (valor !== 'true' && valor !== 'false') {
    throw new ErrorValidacion('El filtro activo debe ser "true" o "false"');
  }
  return valor === 'true';
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
