/**
 * Los cinco estados de `estado_oferta` (ver migrations/005_ofertas.sql y
 * `elementos Generales/plan pendiente/aceptacion-de-ofertas.md`):
 * `pendiente` y `rechazada` son del flujo de aprobacion y NO los pone
 * nunca el cliente -- `pendiente` lo pone la creacion (o una edicion de
 * una oferta sin aprobar) y `rechazada` lo pone la tienda al rechazar.
 */
export const ESTADOS_OFERTA = [
  'pendiente',
  'activa',
  'pausada',
  'retirada',
  'rechazada',
];

/**
 * Los unicos estados que un vendedor puede enviar en el cuerpo de
 * `PATCH /vendedor/ofertas/:id` (lo valida `validarEstadoOferta`).
 */
export const ESTADOS_OFERTA_VALIDOS = ['activa', 'pausada', 'retirada'];
