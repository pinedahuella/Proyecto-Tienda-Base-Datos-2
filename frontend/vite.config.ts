import adapter from '@sveltejs/adapter-auto';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// Este archivo corre en Node, pero el proyecto no trae @types/node. Solo hace
// falta leer una variable de entorno.
declare const process: { env: Record<string, string | undefined> };

/**
 * A donde va lo que el navegador pide a `/api`. Por defecto el backend normal.
 * `tunel-celular.ps1 -ConCopia` lo cambia al 3100, donde corre la copia del
 * backend con trustProxy.
 *
 * 127.0.0.1 y no localhost: el backend escucha solo en IPv4 (0.0.0.0) y
 * localhost puede resolverse primero a ::1.
 */
const backend = process.env.MESH_BACKEND ?? 'http://127.0.0.1:3000';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// adapter-auto only supports some environments, see https://svelte.dev/docs/kit/adapter-auto for a list.
			// If your environment is not supported, or you settled on a specific environment, switch out the adapter.
			// See https://svelte.dev/docs/kit/adapters for more information about adapters.
			adapter: adapter()
		})
	],

	// `vite preview` hereda las dos cosas de aqui (preview.proxy y
	// preview.allowedHosts valen por defecto lo mismo que en server).
	server: {
		proxy: {
			'/api': {
				target: backend,
				rewrite: (ruta) => ruta.replace(/^\/api/, ''),
				// Agrega la IP de quien llego a X-Forwarded-For, detras de la que
				// ya puso el tunel. El backend solo la lee con trustProxy; sin
				// eso ve 127.0.0.1, que es este mismo proxy.
				xfwd: true
			}
		},
		// Sin esto Vite contesta "Blocked request" a todo lo que llega por un
		// tunel rapido, porque el Host no es localhost.
		allowedHosts: ['.trycloudflare.com']
	}
});
