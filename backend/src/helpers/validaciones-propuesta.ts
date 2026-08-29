import { ErrorValidacion } from './errores';

/**
 * Reglas de PATCH /vendedor/productos/:id/revision. La decisión y el motivo
 * del rechazo se validan con `validarDecisionRevision` y
 * `validarRazonRechazo` de `validaciones-oferta.ts` (mismos mensajes que en
 * las ofertas); aquí solo va lo propio de las propuestas de producto.
 */

/**
 * El comentario opcional que la tienda/admin deja al APROBAR una propuesta.
 * Si no viene, o viene vacío, se guarda NULL. Si viene, tiene que ser
 * texto; se guarda recortado.
 */
export function validarComentarioAprobacion(valor: unknown): string | null {
  if (valor == null) {
    return null;
  }
  if (typeof valor !== 'string') {
    throw new ErrorValidacion('El comentario debe ser texto');
  }
  const limpio = valor.trim();
  return limpio.length > 0 ? limpio : null;
}
