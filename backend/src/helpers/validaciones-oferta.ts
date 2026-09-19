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
