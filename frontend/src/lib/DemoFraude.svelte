<script lang="ts">
	import { conJson, mensajeUtil, pedir } from './api';

	/**
	 * Panel de demostraciones, para la defensa de la entrega. Vive dentro de
	 * la aplicacion (y no en un .html suelto) por una razon concreta: un
	 * archivo abierto con file:// no comparte cookie ni origen con el
	 * backend, y los ataques de login y el anillo de resenas necesitan la
	 * MISMA sesion y el MISMO proxy de /api que ya usa el resto del panel.
	 * Abrir un .html aparte habria significado escribir otra vez todo el
	 * manejo de sesion, o pedirle CORS al backend, que no es de este lado.
	 *
	 * Es la version visual de tres scripts que ya existian:
	 *
	 *   demo-evento-fraude.ps1     los tres ataques de login, por HTTP directo
	 *   demo-anillo-resenas.ps1    el anillo de cuentas que se califican entre si
 *   demo-patrones-resenas.ps1  favor devuelto (un mutuo con sus horas) y coordinados
	 *   arrancar.ps1 -Productos    carga un lote de productos con semilla
	 *
	 * Los dos primeros SI se disparan desde aqui, con fetch: son peticiones
	 * al backend, y el navegador ya tiene la sesion de admin puesta. El
	 * tercero no se puede -- es un proceso local (`arrancar.ps1`) y una
	 * pagina no puede lanzar procesos -- asi que ese bloque arma el comando
	 * exacto y lo deja listo para copiar a la terminal.
	 *
	 * TODO LO QUE HACE ESTE PANEL DEJA RASTRO REAL: cuentas nuevas, compras,
	 * pedidos, intentos de login fallidos. No hay boton de deshacer, igual
	 * que en los scripts que envuelve.
	 */

	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	// ---------------------------------------------------------------
	// Bloque 1: ataques de login
	// ---------------------------------------------------------------

	interface Ataque {
		id: 'fuerza_bruta_cuenta' | 'fuerza_bruta_ip' | 'multi_cuenta_ip';
		nombre: string;
		explica: string;
		necesitaCuenta: boolean;
	}

	const ATAQUES: Ataque[] = [
		{
			id: 'fuerza_bruta_cuenta',
			nombre: 'Fuerza bruta contra una cuenta',
			explica: '6 intentos fallidos contra LA MISMA cuenta en un minuto (el umbral es 5).',
			necesitaCuenta: true
		},
		{
			id: 'fuerza_bruta_ip',
			nombre: 'Fuerza bruta desde una IP',
			explica: '8 intentos repartidos en 2 identificadores desde este equipo (el umbral de la IP es 8, sin que ninguno de los dos cruce el de cuenta).',
			necesitaCuenta: false
		},
		{
			id: 'multi_cuenta_ip',
			nombre: 'Varias cuentas desde la misma IP',
			explica: '4 cuentas reales, un fallo cada una, todas desde este equipo (el umbral es 4 cuentas distintas).',
			necesitaCuenta: false
		}
	];

	const CUENTAS_DEMO = [
		'ventas.norte@mesh.com',
		'ventas.sur@mesh.com',
		'compradora.norte@mesh.com',
		'comprador.sur@mesh.com',
		'admin@mesh.com'
	];

	let cuentaAtaque = $state(CUENTAS_DEMO[0]);
	let corriendoAtaque = $state<string | null>(null);
	let logAtaque = $state<string[]>([]);

	async function intentarLogin(identificador: string, contrasena: string): Promise<number> {
		const r = await fetch('/api/usuario/login', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify({ identificador, contrasena })
		});
		return r.status;
	}

	async function correrAtaque(a: Ataque) {
		corriendoAtaque = a.id;
		logAtaque = [`Corriendo: ${a.nombre}`];

		if (a.id === 'fuerza_bruta_cuenta') {
			for (let i = 1; i <= 6; i++) {
				const c = await intentarLogin(cuentaAtaque, `clave-mala-${i}`);
				logAtaque = [...logAtaque, `  intento ${i} de 6 contra ${cuentaAtaque} -> ${c}`];
			}
		} else if (a.id === 'fuerza_bruta_ip') {
			const dos = ['identificador.demo.uno@mesh.com', 'identificador.demo.dos@mesh.com'];
			for (const id of dos) {
				for (let i = 1; i <= 4; i++) {
					const c = await intentarLogin(id, `clave-mala-${i}`);
					logAtaque = [...logAtaque, `  ${id}, intento ${i} de 4 -> ${c}`];
				}
			}
		} else {
			for (const correo of CUENTAS_DEMO) {
				const c = await intentarLogin(correo, 'clave-mala-1');
				logAtaque = [...logAtaque, `  ${correo} -> ${c}`];
			}
		}

		logAtaque = [...logAtaque, 'Listo. La alerta puede tardar unos segundos en aparecer en Fraude.'];
		corriendoAtaque = null;
	}

	// ---------------------------------------------------------------
	// Bloque 2: anillo de resenas
	// ---------------------------------------------------------------

	const PRODUCTOS_ANILLO = [
		{ id: 83, variante: 166, nombre: 'Cartas al puerto seco' },
		{ id: 76, variante: 158, nombre: 'Cuerda de salto Relampago' },
		{ id: 81, variante: 170, nombre: 'Antologia del ruido' },
		{ id: 67, variante: 127, nombre: 'Espinilleras Muralla' }
	];
	const CONTRASENA_DEMO = 'Desarrollo123!';

	let tamanoAnillo = $state<2 | 3 | 4>(3);
	let prefijoAnillo = $state('desarrollador');
	let corriendoAnillo = $state(false);
	let logAnillo = $state<string[]>([]);
	let anilloListo = $state<{ correos: string[] } | null>(null);

	function agregar(linea: string) {
		logAnillo = [...logAnillo, linea];
	}

	/**
	 * OJO CON LA SESION. `POST /usuario/login` pone la cookie `mesh_token` de
	 * quien la llame -- si esta pagina iniciara sesion con una cuenta de
	 * demostracion, sacaria al admin de su propia sesion a mitad del panel.
	 * Por eso este bloque NUNCA llama a login. Para saber que cuentas ya
	 * existen usa `GET /admin/usuarios`, que corre con la sesion del admin
	 * que ya esta puesta, y para crear las que falten usa
	 * `POST /usuario/registro`, que crea la cuenta pero no inicia sesion con
	 * ella -- la fila de la ruta ni siquiera pone una cookie.
	 */
	async function correrAnillo() {
		corriendoAnillo = true;
		anilloListo = null;
		logAnillo = [];

		const n = tamanoAnillo;
		const correos = Array.from({ length: n }, (_, i) => `${prefijoAnillo}${i + 1}@mesh.com`);

		const existentes = await pedir<{ correo_electronico: string }[]>('/admin/usuarios');
		if (existentes.estado === 401) {
			alExpirarSesion();
			corriendoAnillo = false;
			return;
		}
		const yaHay = new Set((existentes.payload ?? []).map((u) => u.correo_electronico));

		agregar('Cuentas del anillo:');
		for (let i = 0; i < n; i++) {
			const correo = correos[i];
			if (yaHay.has(correo)) {
				agregar(`  ${correo} ya existia`);
				continue;
			}
			const reg = await pedir(
				'/usuario/registro',
				conJson('POST', {
					correo_electronico: correo,
					usuario: `${prefijoAnillo}${i + 1}`,
					nombre: `Desarrollador ${i + 1}`,
					apellido: 'Demo',
					contrasena: CONTRASENA_DEMO
				})
			);
			agregar(reg.ok ? `  ${correo} registrada` : `  ${correo}: ${mensajeUtil(reg)}`);
		}

		agregar('Listas. Ya se ven en Cuentas, con rol comprador y sin oferta todavia.');
		anilloListo = { correos };
		corriendoAnillo = false;
	}

	// ---------------------------------------------------------------
	// Bloque 3: cargar productos, solo el comando (no se puede lanzar
	// un proceso local desde una pagina)
	// ---------------------------------------------------------------

	let productosCantidad = $state(100);
	let productosSemilla = $state('');

	let comandoProductos = $derived(
		productosSemilla.trim() === ''
			? `.\\arrancar.ps1 -Productos ${productosCantidad}`
			: `.\\arrancar.ps1 -Productos ${productosCantidad} -Semilla ${productosSemilla.trim()}`
	);

	// ---------------------------------------------------------------
	// Bloque 4: patrones de resenas de la familia B (migracion 023).
	// Mismo mecanismo que el cierre del anillo: comprar de verdad lo hace
	// `demo-patrones-resenas.ps1` (una pagina no puede entrar con otras
	// cuentas sin sacar al admin de su sesion), y aqui se arma el comando.
	// Solo los que el backend revisa al llegar cada resena: el favor devuelto
	// (desde el 2026-10-17 un `mutuo` con las horas de ida y vuelta en su
	// detalle) y B.6. La cadena abierta (B.1) se quito ese dia.
	// ---------------------------------------------------------------

	interface PatronB {
		id: 'favor' | 'coordinados';
		nombre: string;
		explica: string;
		filtro: string;
	}

	const PATRONES_B: PatronB[] = [
		{
			id: 'favor',
			nombre: 'Favor devuelto',
			explica: 'Dos cuentas se compran una a la otra y se ponen 5 en minutos. Sale como mutuo, y las pocas horas entre la ida y la vuelta le suben el puntaje.',
			filtro: 'Se califican entre si'
		},
		{
			id: 'coordinados',
			nombre: 'Cuentas coordinadas',
			explica: 'Dos compradoras califican los mismos tres productos del mismo vendedor a la vez. El vendedor no entra en el caso.',
			filtro: 'Califican juntas lo mismo'
		}
	];

	const comandoPatron = (id: PatronB['id'] | 'todos') =>
		id === 'todos' ? '.\\demo-patrones-resenas.ps1' : `.\\demo-patrones-resenas.ps1 -Patron ${id}`;

	let copiado = $state(false);
	async function copiar(texto: string) {
		try {
			await navigator.clipboard.writeText(texto);
			copiado = true;
			setTimeout(() => (copiado = false), 1500);
		} catch {
			/* sin permiso de portapapeles, la persona lo selecciona a mano */
		}
	}
</script>

<section class="demo">
	<div class="titulo">
		<h2>Demostraciones</h2>
	</div>
	<p class="intro">
		Para la defensa. Cada bloque dispara una senal de fraude de verdad contra el sistema en
		ejecucion, con cuentas y compras reales -- no hay boton de deshacer. Son la version visual de
		<code>demo-evento-fraude.ps1</code>, <code>demo-anillo-resenas.ps1</code>,
		<code>demo-patrones-resenas.ps1</code> y <code>arrancar.ps1 -Productos</code>.
	</p>

	<article class="bloque">
		<h3>Ataques de login</h3>
		<p class="pie">Elige la cuenta objetivo, cuando el ataque la necesita, y pulsa Correr.</p>

		<label class="cuenta">
			<span>Cuenta objetivo</span>
			<select bind:value={cuentaAtaque}>
				{#each CUENTAS_DEMO as c (c)}
					<option value={c}>{c}</option>
				{/each}
			</select>
		</label>

		<div class="tarjetas">
			{#each ATAQUES as a (a.id)}
				<div class="tarjeta">
					<h4>{a.nombre}</h4>
					<p>{a.explica}</p>
					<button
						type="button"
						class="correr"
						disabled={corriendoAtaque !== null}
						onclick={() => correrAtaque(a)}
					>
						{corriendoAtaque === a.id ? 'Corriendo...' : 'Correr'}
					</button>
				</div>
			{/each}
		</div>

		{#if logAtaque.length > 0}
			<pre class="log">{logAtaque.join('\n')}</pre>
			<a class="ver" href="/panel?s=fraude">Abrir Fraude para ver la alerta</a>
		{/if}
	</article>

	<article class="bloque">
		<h3>Anillo de resenas</h3>
		<p class="pie">
			Cuentas de demostracion que se compran y se califican entre si, en circulo. Con 2 cuentas
			sale el par mutuo sobre el mismo producto; con 3 o 4, el ciclo.
		</p>

		<div class="mandos">
			<label>
				<span>Cuantas cuentas</span>
				<select bind:value={tamanoAnillo}>
					<option value={2}>2 (par mutuo)</option>
					<option value={3}>3 (ciclo)</option>
					<option value={4}>4 (ciclo)</option>
				</select>
			</label>
			<label>
				<span>Prefijo de las cuentas</span>
				<input type="text" bind:value={prefijoAnillo} maxlength="20" />
			</label>
			<button type="button" class="correr" disabled={corriendoAnillo} onclick={correrAnillo}>
				{corriendoAnillo ? 'Armando...' : 'Preparar el anillo'}
			</button>
		</div>

		{#if logAnillo.length > 0}
			<pre class="log">{logAnillo.join('\n')}</pre>
		{/if}

		{#if anilloListo}
			<div class="paso-final">
				<p>
					Las cuentas ya existen, tienen rol de vendedor y direccion. El circulo de compras y
					resenas se cierra con el script, que hace el checkout real de cada compra:
				</p>
				<div class="comando">
					<code>.\demo-anillo-resenas.ps1 -Cuentas {tamanoAnillo} -Prefijo {prefijoAnillo}</code>
					<button
						type="button"
						onclick={() => copiar(`.\\demo-anillo-resenas.ps1 -Cuentas ${tamanoAnillo} -Prefijo ${prefijoAnillo}`)}
					>
						{copiado ? 'Copiado' : 'Copiar'}
					</button>
				</div>
				<p class="por-que">
					Por que el ultimo paso es un comando y no un clic: comprar de verdad recorre
					PostgreSQL, Redis y Mongo con la misma transaccion que usa un comprador real, y ese
					camino ya esta escrito y probado en el script. Repetirlo aqui con fetch habria sido
					una segunda copia de la misma logica, y una copia es lo que se desincroniza primero.
				</p>
				<a class="ver" href="/panel?s=fraude">Abrir Fraude para ver el anillo</a>
			</div>
		{/if}
	</article>

	<article class="bloque">
		<h3>Patrones de resenas</h3>
		<p class="pie">
			Cuentas nuevas en cada corrida, con compras y resenas reales. El sistema los revisa al
			llegar cada resena y salen en segundos. El script confirma cada caso al final.
		</p>

		<div class="tarjetas">
			{#each PATRONES_B as p (p.id)}
				<div class="tarjeta">
					<h4>{p.nombre}</h4>
					<p>{p.explica}</p>
					<p class="donde">Verlo en Fraude, Resenas en anillo, tipo {p.filtro}.</p>
					<div class="comando">
						<code>{comandoPatron(p.id)}</code>
						<button type="button" onclick={() => copiar(comandoPatron(p.id))}>
							{copiado ? 'Copiado' : 'Copiar'}
						</button>
					</div>
				</div>
			{/each}
		</div>

		<div class="comando todos">
			<code>{comandoPatron('todos')}</code>
			<button type="button" onclick={() => copiar(comandoPatron('todos'))}>
				{copiado ? 'Copiado' : 'Copiar'}
			</button>
		</div>
		<p class="por-que">
			Los dos a la vez. Tambien estan en Comandos, grupo Demos de fraude. Reputacion en minutos
			sale sola a los 15 minutos con estas mismas cuentas. Persistente pide resenas de tres meses
			y no se arma en vivo.
		</p>
		<a class="ver" href="/panel?s=fraude&t=resenas">Abrir Fraude para ver los casos</a>
	</article>

	<article class="bloque">
		<h3>Cargar productos con semilla</h3>
		<p class="pie">
			Esto es un proceso local (`arrancar.ps1`) y una pagina no puede lanzarlo. Arma el comando
			exacto para pegar en la terminal.
		</p>

		<div class="mandos">
			<label>
				<span>Cuantos productos</span>
				<input type="number" min="1" max="9999" bind:value={productosCantidad} />
			</label>
			<label>
				<span>Semilla (vacio = una libre)</span>
				<input type="number" min="0" placeholder="opcional" bind:value={productosSemilla} />
			</label>
		</div>

		<div class="comando">
			<code>{comandoProductos}</code>
			<button type="button" onclick={() => copiar(comandoProductos)}>
				{copiado ? 'Copiado' : 'Copiar'}
			</button>
		</div>
	</article>
</section>

<style>
	.demo {
		padding: 26px 28px;
		margin-bottom: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo h2 {
		font-size: var(--f-xl);
		margin-bottom: 6px;
	}

	.intro {
		max-width: 760px;
		margin-bottom: var(--e4);
		color: var(--gris);
		font-size: var(--f-base);
	}

	.intro code {
		font-size: 0.92em;
	}

	.bloque {
		padding: 18px 20px;
		margin-bottom: var(--e4);
		background: var(--panel);
		border-radius: var(--r);
	}

	.bloque h3 {
		font-size: var(--f-lg, 1.1rem);
		margin-bottom: 4px;
	}

	.pie {
		margin-bottom: 14px;
		color: var(--gris);
		font-size: var(--f-sm);
	}

	.cuenta,
	.mandos label {
		display: flex;
		flex-direction: column;
		gap: 4px;
		font-size: var(--f-sm);
		color: var(--gris);
	}

	.cuenta {
		margin-bottom: 14px;
		max-width: 340px;
	}

	.mandos {
		display: flex;
		flex-wrap: wrap;
		gap: 14px;
		align-items: flex-end;
		margin-bottom: 14px;
	}

	select,
	input[type='text'],
	input[type='number'] {
		padding: 8px 10px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	input[type='number'] {
		width: 120px;
	}

	.tarjetas {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
		gap: 12px;
	}

	.tarjeta {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 14px 16px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.tarjeta h4 {
		font-size: var(--f-base);
	}

	.tarjeta p {
		flex: 1;
		color: var(--gris);
		font-size: var(--f-sm);
	}

	button.correr {
		align-self: flex-start;
		padding: 8px 16px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: #fff;
		background: var(--indigo);
		border: 0;
		border-radius: var(--r);
		cursor: pointer;
	}

	button.correr:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.log {
		margin-top: 14px;
		padding: 12px 14px;
		max-height: 260px;
		overflow-y: auto;
		font-family: var(--mono, monospace);
		font-size: 0.82rem;
		color: var(--tinta);
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		white-space: pre-wrap;
	}

	.ver {
		display: inline-block;
		margin-top: 10px;
		color: var(--indigo);
		font-size: var(--f-sm);
	}

	.paso-final {
		margin-top: 14px;
		padding-top: 14px;
		border-top: 1px solid var(--linea);
	}

	.paso-final p {
		margin-bottom: 10px;
		font-size: var(--f-sm);
	}

	.por-que {
		color: var(--gris);
	}

	.tarjeta p.donde {
		flex: 0;
		color: var(--tinta);
	}

	.comando.todos {
		margin-top: 12px;
	}

	.bloque > .por-que {
		margin-top: 10px;
		font-size: var(--f-sm);
	}

	.comando {
		display: flex;
		align-items: center;
		gap: 10px;
		flex-wrap: wrap;
		padding: 10px 14px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r);
	}

	.comando code {
		flex: 1;
		min-width: 240px;
		font-family: var(--mono, monospace);
		font-size: 0.88rem;
	}

	.comando button {
		padding: 6px 14px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: var(--tinta);
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}
</style>
