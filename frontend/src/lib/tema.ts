import { browser } from '$app/environment';

/**
 * Tema claro u oscuro.
 *
 * El tema se guarda como el atributo data-tema del <html>, y toda la paleta
 * cuelga de ahi. Se recuerda en localStorage para que no cambie al recargar.
 */

export type Tema = 'claro' | 'oscuro';

const LLAVE = 'mesh.tema';

export function leerTema(): Tema {
	if (!browser) return 'claro';
	const guardado = localStorage.getItem(LLAVE);
	if (guardado === 'claro' || guardado === 'oscuro') return guardado;
	// Sin eleccion previa, se sigue lo que tenga configurado el sistema
	return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'oscuro' : 'claro';
}

export function aplicarTema(tema: Tema) {
	if (!browser) return;
	document.documentElement.dataset.tema = tema;
	localStorage.setItem(LLAVE, tema);
}
