import { browser } from '$app/environment';
import { pedir } from './api';

/**
 * Sesion del navegador.
 *
 * OJO: esto no es la autenticacion. La sesion de verdad es la cookie
 * mesh_token que deja POST /usuario/login, y es httpOnly: el navegador la
 * manda sola en cada peticion, pero desde JavaScript no se puede leer ni
 * escribir. Justamente por eso no esta aqui.
 *
 * Lo unico que guarda localStorage es el correo, y sirve para una sola cosa:
 * saber a quien mostrarle la pagina mientras se pregunta al backend. Quien
 * manda es siempre el backend, y por eso existe verificarSesion.
 */

const LLAVE = 'mesh.sesion';

/**
 * Lo que devuelven POST /usuario/login y GET /usuario/yo.
 *
 * Los mismos campos que la tabla usuarios menos contrasena_hash, que no sale
 * nunca de la base. id_usuario viaja como texto y no como numero porque es
 * bigserial: el driver pg entrega los bigint como string para no perder
 * precision.
 */
export interface UsuarioSesion {
	id_usuario: string;
	correo_electronico: string;
	usuario: string;
	nombre: string;
	apellido: string | null;
	fecha_nacimiento: string | null;
	fecha_creacion: string;
	id_rol_usuario: number;
	id_estado_usuario: number;
}

/**
 * Lo que devuelve GET /perfil: lo mismo de arriba mas el nombre del rol y del
 * estado, no solo sus ids. Asi se muestran directo sin tener que ir a
 * /admin/roles ni /admin/estados, que ademas son solo para admin.
 */
export interface PerfilUsuario extends UsuarioSesion {
	rol_usuario_nombre: string;
	estado_usuario_nombre: string;
}

/**
 * El id del rol admin en la tabla rol_usuario.
 *
 * Es el mismo valor que backend/src/models/rol-usuario.ts, y por el mismo
 * motivo: la migracion 001 inserta comprador, vendedor y admin en ese orden,
 * asi que admin es el 3. Un catalogo tan chico no cambia sin una migracion
 * nueva.
 *
 * Sirve para decidir que panel mostrar, no para dar permisos: quien decide
 * si se puede hacer algo es el backend, que responde 403 si el rol no
 * alcanza. Esconder un boton no protege nada.
 */
export const ID_ROL_ADMIN = 3;
export const ID_ROL_VENDEDOR = 2;

export function guardarSesion(correo: string) {
	if (!browser) return;
	localStorage.setItem(LLAVE, correo);
}

export function leerSesion(): string | null {
	if (!browser) return null;
	return localStorage.getItem(LLAVE);
}

export function cerrarSesion() {
	if (!browser) return;
	localStorage.removeItem(LLAVE);
}

/**
 * Pregunta al backend si la sesion sigue viva, con GET /usuario/yo.
 *
 * Es la unica forma honesta de saberlo: el token esta dentro de una cookie
 * httpOnly, asi que desde aqui no se puede mirar ni su fecha de vencimiento.
 * Y aunque se pudiera, no alcanzaria: esa ruta ademas comprueba en cada
 * peticion que la cuenta siga activa en la base ahora mismo, no solo en el
 * momento del login. Si suspenden a alguien con el token todavia vigente,
 * esto lo detecta de inmediato.
 *
 * Devuelve:
 *   el usuario  si la sesion sirve
 *   null        si el backend contesto 401: se acabo, hay que volver a entrar
 *
 * Lanza SesionIndeterminada si no se pudo averiguar (503, o el backend
 * apagado). Ese caso NO es una sesion vencida y no debe sacar a nadie: el
 * token puede estar perfecto y ser el servidor el que fallo.
 */
export class SesionIndeterminada extends Error {}

export async function verificarSesion(): Promise<UsuarioSesion | null> {
	const respuesta = await pedir<UsuarioSesion>('/usuario/yo');

	if (respuesta.ok && respuesta.payload) {
		return respuesta.payload;
	}

	if (respuesta.estado === 401) {
		// La cookie ya no sirve; se limpia tambien el rastro local para que la
		// proxima carga no muestre por un instante a alguien que ya salio.
		cerrarSesion();
		return null;
	}

	throw new SesionIndeterminada(respuesta.mensaje);
}
