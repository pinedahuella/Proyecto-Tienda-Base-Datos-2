import { browser } from '$app/environment';

/**
 * Sesion del navegador.
 *
 * OJO: esto todavia no es autenticacion. El backend no tiene endpoint de login,
 * asi que por ahora solo guarda el correo para que el panel sepa a quien saludar.
 * Cuando exista /auth/login hay que reemplazar esto por el token que devuelva.
 */

const LLAVE = 'mesh.sesion';

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

/** Saca un nombre presentable del correo: jose.gonzalez@mesh.com -> Jose */
export function nombreDesdeCorreo(correo: string): string {
	const usuario = correo.split('@')[0] ?? '';
	const primero = usuario.split(/[._-]/)[0] ?? usuario;
	return primero.charAt(0).toUpperCase() + primero.slice(1);
}
