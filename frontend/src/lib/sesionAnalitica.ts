import { browser } from '$app/environment';

/**
 * El `sesion` que piden `POST /eventos/vista`, `GET /buscador/productos` y
 * `POST /eventos/busqueda-clic` (ver
 * `backend/elementos Generales/endpoints/endpoints-eventos.md`). NO tiene
 * nada que ver con `sesion.ts` (la cookie `mesh_token` de autenticacion):
 * esto es puramente analitico, existe para distinguir un visitante anonimo
 * de otro en ClickHouse -- "cien personas vieron esto" contra "una persona
 * lo vio cien veces" -- y no identifica ni autentica a nadie.
 *
 * `sessionStorage` y no `localStorage`: la pregunta que este identificador
 * contesta es "esto paso en la misma visita", y una visita termina cuando
 * se cierra la pestana. Con `localStorage` la misma persona, semanas
 * despues, seguiria contando como "la misma sesion" -- que es exactamente
 * lo que este dato no deberia decir.
 *
 * Se genera UNA vez por pestana y se reusa: pedirlo de nuevo en cada evento
 * convertiria a cada visitante en cien sesiones distintas, que es el mismo
 * problema que este campo existe para evitar.
 */
const LLAVE = 'mesh.sesion-analitica';

export function sesionAnalitica(): string {
	if (!browser) return '';

	let valor = sessionStorage.getItem(LLAVE);
	if (!valor) {
		valor = crypto.randomUUID();
		sessionStorage.setItem(LLAVE, valor);
	}
	return valor;
}
