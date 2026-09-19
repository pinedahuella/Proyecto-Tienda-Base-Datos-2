import adapter from '@sveltejs/adapter-auto';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// Este archivo corre en Node, pero el proyecto no trae @types/node. Solo hace
// falta leer una variable de entorno.
declare const process: { env: Record<string, string | undefined> };

// Por lo mismo (sin @types/node), la respuesta del proxy no tiene tipo, y el de
// vite para el proxy no declara `on` aunque en realidad es un EventEmitter. Se
// describe solo lo que se usa.
type RespuestaProxy = {
	headersSent?: boolean;
	writeHead?: (estado: number, cabeceras: Record<string, string>) => unknown;
	end?: (cuerpo: string) => unknown;
};
type EmisorProxy = {
	on(
		evento: 'error',
		escucha: (error: unknown, peticion: unknown, respuesta: RespuestaProxy | undefined) => void
	): unknown;
};

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
				xfwd: true,
				// CUANDO EL PROXY NO ALCANZA AL BACKEND. Mientras `nest start --watch`
				// reinicia (unos 10 segundos, y lo dispara cualquier toque a backend/,
				// tambien los de OneDrive), http-proxy contesta un 502 de TEXTO PLANO Y
				// SIN CUERPO. `pedir()` intenta leerlo como JSON, falla, y la persona
				// ve "El servidor respondio algo inesperado" sin ninguna pista de que
				// solo hay que esperar. Medido el 2026-09-18 con un backend caido:
				//
				//   HTTP/1.1 502 Bad Gateway    Content-Type: text/plain    (sin cuerpo)
				//
				// Aqui se contesta con la forma de siempre ({ ok, mensaje, payload }),
				// un 503, y la cabecera x-mesh-proxy-error, que es como `pedir()`
				// sabe que la peticion NUNCA LLEGO al backend y puede reintentarla sin
				// riesgo (un POST de login incluido: no hubo nada que duplicar). Un 503
				// que el backend mande por su cuenta no lleva la cabecera y no se
				// reintenta.
				configure: (proxy) => {
					(proxy as unknown as EmisorProxy).on('error', (_error, _peticion, respuesta) => {
						// Tambien puede ser un socket (websocket): ahi no hay nada que contestar.
						if (!respuesta?.writeHead || !respuesta.end || respuesta.headersSent) return;
						respuesta.writeHead(503, {
							'Content-Type': 'application/json; charset=utf-8',
							'X-Mesh-Proxy-Error': '1'
						});
						respuesta.end(
							JSON.stringify({
								ok: false,
								mensaje: 'El servidor se esta reiniciando. Espera unos segundos y vuelve a intentar.',
								payload: null
							})
						);
					});
				}
			}
		},
		// Sin esto Vite contesta "Blocked request" a todo lo que llega por un
		// tunel rapido, porque el Host no es localhost.
		allowedHosts: ['.trycloudflare.com']
	}
});
