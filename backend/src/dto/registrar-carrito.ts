/**
 * Cuerpo esperado en `POST /eventos/carrito`. A diferencia de
 * `RegistrarVistaPeticion`, no lleva `sesion` ni `id_usuario`: el carrito
 * SIEMPRE exige sesion en este proyecto (no hay carrito de invitado, ver
 * memoria `carrito-redis`), asi que `id_usuario` sale de `@UsuarioActual()`
 * -- nunca del cuerpo -- y no hace falta distinguir visitantes anonimos.
 */
export interface RegistrarCarritoPeticion {
  id_producto?: unknown;
  id_oferta?: unknown;
  cantidad?: unknown;
}
