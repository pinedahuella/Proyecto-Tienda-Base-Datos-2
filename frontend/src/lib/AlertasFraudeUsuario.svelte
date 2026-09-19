<script lang="ts">
	import { onMount } from 'svelte';
	import { conJson, mensajeUtil, pedir } from './api';

	/**
	 * "Mis alertas de fraude" -- lo que ve el USUARIO afectado, no el admin.
	 *
	 * Segundo pedido del profesor sobre el modulo de fraude de login: que las
	 * alertas no solo las vea un admin, sino tambien la cuenta involucrada,
	 * "por si cualquiera desea tomar accion". Ver
	 * `backend/elementos Generales/plan pendiente/notificacion-fraude-usuario.md`.
	 *
	 *   GET   /perfil/alertas-fraude      las de la sesion actual, paginadas
	 *   PATCH /perfil/alertas-fraude/:id  marca UNA como leida (idempotente)
	 *
	 * Es una pantalla mas chica que `PanelFraude` a proposito: aqui no hay
	 * `estado` (pendiente/revisada/descartada, eso es la investigacion del
	 * admin) ni `cuentas_afectadas` (uno mismo ya sabe que es el afectado).
	 * Solo `fecha_lectura`, que es de esta cuenta y no de la alerta.
	 */
	let { alExpirarSesion }: { alExpirarSesion: () => void } = $props();

	type TipoAlerta =
		| 'fuerza_bruta_ip'
		| 'fuerza_bruta_cuenta'
		| 'multi_cuenta_ip'
		| 'ip_rotacion_cuenta'
		| 'toma_cuenta'
		| 'viaje_imposible'
		| 'fuerza_bruta_cuenta_lenta'
		| 'multi_cuenta_ip_lenta'
		| 'ip_rotacion_cuenta_lenta';

	interface AlertaPropia {
		id_alerta_fraude: string;
		tipo_alerta: TipoAlerta;
		clave: string;
		detalle: Record<string, unknown>;
		contador: number;
		ventana_inicio: string;
		fecha_creacion: string;
		/** De ESTA cuenta, no de la alerta -- null = no leida. */
		fecha_lectura: string | null;
	}

	interface AlertasPropiasPaginadas {
		alertas: AlertaPropia[];
		pagina: number;
		limite: number;
		total_alertas: number;
		total_paginas: number;
	}

	/** Frases pensadas para quien recibe la alerta, no para un admin investigando. */
	const QUE_PASO: Record<TipoAlerta, string> = {
		fuerza_bruta_ip: 'Muchos intentos fallidos desde una IP',
		fuerza_bruta_cuenta: 'Alguien fallo varias veces al intentar entrar con tu cuenta',
		multi_cuenta_ip: 'La misma IP probo tu cuenta junto con otras',
		ip_rotacion_cuenta: 'Tu cuenta se probo desde varias IPs distintas en poco tiempo',
		toma_cuenta: 'Entraste a tu cuenta desde una IP nueva',
		viaje_imposible: 'Dos entradas a tu cuenta implican un viaje imposible',
		fuerza_bruta_cuenta_lenta: 'Fallos repetidos contra tu cuenta, repartidos en el dia',
		multi_cuenta_ip_lenta: 'La misma IP probo tu cuenta junto con otras, repartido en el dia',
		ip_rotacion_cuenta_lenta: 'Tu cuenta se probo desde varias IPs, repartido en el dia'
	};

	const POR_PAGINA = 20;

	let alertas = $state<AlertaPropia[]>([]);
	let pagina = $state(1);
	let totalPaginas = $state(0);
	let total = $state(0);
	let cargando = $state(true);
	let error = $state('');
	let marcando = $state<string | null>(null);
	let pedido = 0;

	onMount(() => {
		void cargar(1);
	});

	async function cargar(p: number) {
		const este = ++pedido;
		pagina = p;
		cargando = true;
		error = '';

		const r = await pedir<AlertasPropiasPaginadas>(
			`/perfil/alertas-fraude?pagina=${p}&limite=${POR_PAGINA}`
		);

		if (este !== pedido) return;
		cargando = false;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			error = mensajeUtil(r);
			alertas = [];
			return;
		}

		const carga = r.payload;
		const lista = carga.alertas ?? [];

		if (lista.length === 0 && carga.total_paginas > 0 && p > carga.total_paginas) {
			void cargar(carga.total_paginas);
			return;
		}

		alertas = lista;
		pagina = carga.pagina;
		totalPaginas = carga.total_paginas;
		total = carga.total_alertas;
	}

	async function marcarLeida(a: AlertaPropia) {
		if (a.fecha_lectura) return;
		marcando = a.id_alerta_fraude;

		const r = await pedir<AlertaPropia>(
			`/perfil/alertas-fraude/${a.id_alerta_fraude}`,
			conJson('PATCH', {})
		);
		marcando = null;

		if (r.estado === 401) {
			alExpirarSesion();
			return;
		}

		if (!r.ok || !r.payload) {
			error = mensajeUtil(r);
			return;
		}

		alertas = alertas.map((x) => (x.id_alerta_fraude === a.id_alerta_fraude ? r.payload! : x));
	}

	function fecha(valor: string): string {
		if (!valor) return '--';
		const d = new Date(valor);
		if (Number.isNaN(d.getTime())) return '--';
		return d.toLocaleString('es-GT', {
			day: 'numeric',
			month: 'short',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit'
		});
	}

	function entero(valor: unknown): number | null {
		const n = Number(valor);
		return valor != null && Number.isFinite(n) ? n : null;
	}

	/** Un resumen corto de lo que se vio, sin la jerga de "detalle" que solo le sirve a un admin. */
	function resumen(a: AlertaPropia): string {
		const d = a.detalle ?? {};
		switch (a.tipo_alerta) {
			case 'multi_cuenta_ip':
			case 'multi_cuenta_ip_lenta': {
				const n = entero(d.cuentas_distintas);
				return n !== null
					? `Esa IP probo ${n} ${n === 1 ? 'cuenta' : 'cuentas'} en total, no solo la tuya.`
					: '';
			}
			case 'viaje_imposible': {
				const km = entero(d.distancia_km);
				const kmh = entero(d.velocidad_kmh);
				return km !== null && kmh !== null
					? `${km.toLocaleString('es-GT')} km entre dos entradas -- ${kmh.toLocaleString('es-GT')} km/h implicitos.`
					: '';
			}
			case 'toma_cuenta':
				return 'Si no fuiste vos, cambia tu contrasena cuanto antes.';
			default:
				return '';
		}
	}
</script>

<section class="alertas-usuario">
	<div class="titulo">
		<h2>Alertas de seguridad</h2>
		{#if !cargando && !error}
			<span class="etiqueta" class:limpio={total === 0}>
				{total} {total === 1 ? 'alerta' : 'alertas'}
			</span>
		{/if}
		<div class="acciones">
			<button type="button" onclick={() => cargar(pagina)} disabled={cargando}>
				Volver a mirar
			</button>
		</div>
	</div>

	<p class="intro">
		Si algo raro paso con tu cuenta -- una entrada desde un lugar nuevo, o de golpe muy lejos de tu
		ultima entrada -- aparece aqui. Esto solo avisa: no bloquea nada por su cuenta.
	</p>

	{#if error}
		<div class="fallo" role="alert">
			<p>{error}</p>
			<button type="button" onclick={() => cargar(pagina)}>Reintentar</button>
		</div>
	{:else if cargando && alertas.length === 0}
		<p class="gris">Buscando alertas...</p>
	{:else if alertas.length === 0}
		<div class="limpio-caja">
			<p>No hay ninguna alerta de seguridad en tu cuenta.</p>
		</div>
	{:else}
		<ul class="lista" class:esperando={cargando} aria-busy={cargando}>
			{#each alertas as a (a.id_alerta_fraude)}
				{@const nota = resumen(a)}
				<li class="alerta" class:no-leida={!a.fecha_lectura}>
					<div class="cabeza">
						<span class="que-paso">{QUE_PASO[a.tipo_alerta] ?? a.tipo_alerta}</span>
						{#if !a.fecha_lectura}
							<span class="punto" aria-hidden="true"></span>
						{/if}
					</div>

					{#if nota}
						<p class="nota">{nota}</p>
					{/if}

					<div class="pie">
						<span class="gris">{fecha(a.fecha_creacion)}</span>
						{#if a.fecha_lectura}
							<span class="gris">Leida {fecha(a.fecha_lectura)}</span>
						{:else}
							<button
								type="button"
								class="marcar"
								disabled={marcando === a.id_alerta_fraude}
								onclick={() => marcarLeida(a)}
							>
								Marcar como leida
							</button>
						{/if}
					</div>
				</li>
			{/each}
		</ul>

		{#if totalPaginas > 1}
			<nav class="paginacion" aria-label="Paginas de mis alertas">
				<button type="button" onclick={() => cargar(pagina - 1)} disabled={pagina <= 1 || cargando}>
					Anterior
				</button>
				<span class="cuantas">Pagina {pagina} de {totalPaginas}</span>
				<button
					type="button"
					onclick={() => cargar(pagina + 1)}
					disabled={pagina >= totalPaginas || cargando}
				>
					Siguiente
				</button>
			</nav>
		{/if}
	{/if}
</section>

<style>
	.alertas-usuario {
		padding: 26px 28px;
		margin-bottom: 28px;
		background: var(--blanco);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.titulo {
		display: flex;
		align-items: center;
		gap: var(--e2);
		flex-wrap: wrap;
		margin-bottom: 8px;
	}

	.titulo h2 {
		font-size: var(--f-xl);
		margin-right: 4px;
	}

	.etiqueta {
		padding: 3px 11px;
		font-size: var(--f-sm);
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: 999px;
	}

	.etiqueta.limpio {
		color: var(--gris);
		background: var(--panel);
		border-color: var(--linea);
	}

	.acciones {
		margin-left: auto;
	}

	.acciones button {
		padding: 8px 16px;
		font-family: inherit;
		font-size: var(--f-base);
		color: var(--tinta);
		background: none;
		border: 1px solid var(--linea);
		border-radius: var(--r);
		cursor: pointer;
	}

	.intro {
		max-width: 620px;
		margin-bottom: 20px;
		color: var(--gris);
		font-size: var(--f-base);
	}

	.gris {
		color: var(--gris);
		font-size: var(--f-sm);
	}

	.fallo {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e4);
		flex-wrap: wrap;
		padding: 14px 18px;
		color: var(--rojo);
		background: var(--off);
		border: 1px solid var(--rojo);
		border-radius: var(--r);
	}

	.limpio-caja {
		padding: 22px 24px;
		background: var(--panel);
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.lista {
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: var(--e3);
		transition: opacity var(--t);
	}

	.lista.esperando {
		opacity: 0.6;
	}

	.alerta {
		padding: 14px 18px;
		border: 1px solid var(--linea);
		border-radius: var(--r2);
	}

	.alerta.no-leida {
		border-color: var(--indigo);
	}

	.cabeza {
		display: flex;
		align-items: center;
		gap: var(--e2);
	}

	.que-paso {
		font-size: var(--f-base);
		font-weight: 500;
		color: var(--tinta);
	}

	.punto {
		width: 8px;
		height: 8px;
		border-radius: 50%;
		background: var(--indigo);
	}

	.nota {
		margin-top: var(--e2);
		font-size: var(--f-ms);
		color: var(--texto);
	}

	.pie {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--e3);
		margin-top: var(--e3);
	}

	.marcar {
		padding: 5px 12px;
		font-family: inherit;
		font-size: var(--f-sm);
		color: var(--indigo);
		background: none;
		border: 1px solid var(--indigo);
		border-radius: var(--r);
		cursor: pointer;
	}

	.marcar:disabled {
		opacity: 0.5;
		cursor: default;
	}

	.paginacion {
		display: flex;
		align-items: center;
		justify-content: center;
		flex-wrap: wrap;
		gap: var(--e4);
		margin-top: var(--e5);
	}

	.cuantas {
		color: var(--tinta);
		text-align: center;
	}

	@media (max-width: 620px) {
		.alertas-usuario {
			padding: 22px 20px;
		}
	}
</style>
