/**
 * Constantes de negocio compartidas entre varios servicios. Solo van aqui
 * las que de verdad se repiten en mas de un archivo; si algo se usa en un
 * solo lugar, se queda ahi.
 */

/**
 * El correo de la cuenta de la tienda (ver migrations/datos/generador.js y
 * backend/elementos Generales/cambios-multivendedor.md, seccion 9): en el
 * modelo multi-vendedor es la unica cuenta que oferta TODAS las variantes,
 * su precio es el que se ensena en el catalogo, y (decision del equipo) es
 * la unica que puede crear o editar entradas del catalogo compartido.
 */
export const CORREO_TIENDA = 'tienda@mesh.com';

/**
 * Al hacer `POST /carrito/comprar`, si alguna linea del carrito no se puede
 * comprar (agotada, oferta pausada/retirada, o un id de oferta inventado),
 * la compra SIEMPRE se rechaza con 409 -- este interruptor no cambia eso.
 * Lo que decide es si, ademas del rechazo, esas lineas se quitan del
 * carrito en Redis antes de responder (`true`) o si el carrito queda
 * intacto para que el cliente decida (`false`). Es una decision de negocio
 * fija para todos, no algo que cada peticion pueda pedir distinto: para
 * cambiarla hay que tocar esta linea y redesplegar.
 */
export const QUITAR_LINEAS_NO_DISPONIBLES_AL_PAGAR = false;

/**
 * Cuanto dura una reserva individual de inventario limitado antes de
 * vencer sola (`redis/inventario_limitado.lua`, operaciones `reservar` /
 * `redimensionar`, y el `redimensionar-reserva.lua` provisional). El
 * compañero propone 900 s (15 min) en `redis/README.md` -- se usa el
 * mismo numero aca. No es el TTL del carrito entero (24h de
 * inactividad, `CarritoService.TTL_SEGUNDOS`): una reserva puntual puede
 * vencer sola mientras el resto del carrito sigue vivo.
 */
export const TTL_RESERVA_INVENTARIO_LIMITADO_SEGUNDOS = 900;
