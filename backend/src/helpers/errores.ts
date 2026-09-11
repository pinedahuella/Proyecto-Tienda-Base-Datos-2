/**
 * Errores de dominio que un servicio puede lanzar y que el controlador
 * traduce a un codigo HTTP.
 *
 * Van separados de un Error comun para que el controlador sepa, con
 * instanceof, si lo que fallo fue el cliente (datos invalidos, ya existe) o
 * el servidor (lo que no reconoce se trata como 500).
 */

/** El cliente mando datos invalidos. El controlador la traduce a HTTP 400. */
export class ErrorValidacion extends Error {}

/** Lo que se queria crear ya existe. El controlador la traduce a HTTP 409. */
export class ErrorConflicto extends Error {}

/** La base de datos no respondio. El controlador la traduce a HTTP 503. */
export class ErrorConexion extends Error {}

/** El token de sesion no vino, no es valido o ya vencio. HTTP 401. */
export class ErrorSesion extends Error {}

/**
 * Un intento de login que fallo. Extiende ErrorSesion (el controlador la
 * sigue traduciendo a 401 con el mismo mensaje generico), pero lleva el
 * motivo real y, cuando se conoce, el id de la cuenta: es lo que necesita
 * el log de seguridad (eventos_autenticacion). Nada de esto llega a la
 * respuesta HTTP -- si lo hiciera, esta ruta serviria para averiguar que
 * cuentas existen o cuales estan suspendidas.
 */
export class ErrorInicioSesion extends ErrorSesion {
  constructor(
    public readonly motivo:
      'credenciales_invalidas' | 'usuario_inexistente' | 'cuenta_inactiva',
    public readonly idUsuario: string | null = null,
  ) {
    super('Correo electronico, usuario o contrasena incorrectos');
  }
}

/** No existe lo que se pidio. El controlador la traduce a HTTP 404. */
export class ErrorNoEncontrado extends Error {}

/**
 * El pago no se pudo procesar (tarjeta rechazada, vencida, fondos
 * insuficientes, etc.). El controlador la traduce a HTTP 402 -- distinto de
 * ErrorValidacion (400): los datos de la peticion estaban bien formados, lo
 * que fallo fue el cobro en si.
 */
export class ErrorPago extends Error {}
