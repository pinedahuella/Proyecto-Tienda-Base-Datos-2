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
