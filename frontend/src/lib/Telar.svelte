<script lang="ts">
	/**
	 * Telar: dibuja un tejido de ligamento tafetan en canvas.
	 *
	 * La urdimbre son los hilos verticales, la trama los horizontales.
	 * Cada cruce alterna quien pasa por encima, que es exactamente como se teje
	 * una tela: por eso la trama va en onda y no recta.
	 *
	 * Un solo hilo de trama es dorado. En los textiles hechos a mano el tejedor
	 * deja una hebra distinta como firma; ese es el unico color de la pagina.
	 */

	let { densidad = 30 }: { densidad?: number } = $props();

	let lienzo: HTMLCanvasElement;

	const HILO = '#2B3563';
	const HILO_TENUE = '#1D2547';
	const ORO = '#E0A73E';

	$effect(() => {
		const ctx = lienzo.getContext('2d');
		if (!ctx) return;

		const quieto = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

		let ancho = 0;
		let alto = 0;
		let columnas = 0;
		let filas = 0;
		let filaOro = 0;
		let cuadro = 0;
		let inicio = 0;
		let terminado = false;

		// Poca amplitud: la trama debe leerse como tela tensada, no como red colgando
		const amplitud = 2.2;

		function medir() {
			const dpr = Math.min(window.devicePixelRatio || 1, 2);
			ancho = lienzo.clientWidth;
			alto = lienzo.clientHeight;
			lienzo.width = Math.floor(ancho * dpr);
			lienzo.height = Math.floor(alto * dpr);
			ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);

			columnas = Math.ceil(ancho / densidad) + 2;
			filas = Math.ceil(alto / densidad) + 2;
			// El hilo dorado cruza por el tercio superior, detras de la tarjeta
			filaOro = Math.max(1, Math.round(filas * 0.38));
		}

		/** Altura de la trama `f` en la posicion x. La onda pasa sobre y bajo la urdimbre. */
		function ondaY(f: number, x: number, fase: number) {
			const base = f * densidad;
			return base + Math.sin((x / densidad) * Math.PI + f * Math.PI + fase) * amplitud;
		}

		function pintar(avance: number, fase: number, brillo: number) {
			ctx!.clearRect(0, 0, ancho, alto);
			ctx!.lineCap = 'round';

			// --- Urdimbre: los hilos verticales caen primero ---
			const avanceUrdimbre = Math.min(1, avance / 0.45);
			ctx!.lineWidth = 1;
			for (let c = 0; c < columnas; c++) {
				const x = c * densidad;
				const retraso = (c / columnas) * 0.35;
				const p = Math.max(0, Math.min(1, (avanceUrdimbre - retraso) / (1 - retraso)));
				if (p <= 0) continue;
				ctx!.strokeStyle = c % 2 === 0 ? HILO : HILO_TENUE;
				ctx!.beginPath();
				ctx!.moveTo(x, 0);
				ctx!.lineTo(x, alto * p);
				ctx!.stroke();
			}

			// --- Trama: los hilos horizontales se tejen de izquierda a derecha ---
			const avanceTrama = Math.max(0, (avance - 0.3) / 0.7);
			for (let f = 0; f < filas; f++) {
				const retraso = (f / filas) * 0.4;
				const p = Math.max(0, Math.min(1, (avanceTrama - retraso) / (1 - retraso)));
				if (p <= 0) continue;

				const esOro = f === filaOro;
				const hasta = ancho * p;

				ctx!.strokeStyle = esOro ? ORO : f % 2 === 0 ? HILO : HILO_TENUE;
				ctx!.lineWidth = esOro ? 1.6 : 1;
				ctx!.globalAlpha = esOro ? 0.85 : 1;
				ctx!.beginPath();
				for (let x = 0; x <= hasta; x += 3) {
					const y = ondaY(f, x, fase);
					if (x === 0) ctx!.moveTo(x, y);
					else ctx!.lineTo(x, y);
				}
				ctx!.stroke();
				ctx!.globalAlpha = 1;

				// El hilo dorado lleva un reflejo lento que recorre su largo
				if (esOro && brillo >= 0) {
					const centro = brillo * ancho;
					if (centro <= hasta) {
						const g = ctx!.createLinearGradient(centro - 90, 0, centro + 90, 0);
						g.addColorStop(0, 'rgba(224,167,62,0)');
						g.addColorStop(0.5, 'rgba(255,226,160,0.95)');
						g.addColorStop(1, 'rgba(224,167,62,0)');
						ctx!.strokeStyle = g;
						ctx!.lineWidth = 2;
						ctx!.beginPath();
						for (let x = Math.max(0, centro - 90); x <= Math.min(hasta, centro + 90); x += 3) {
							const y = ondaY(f, x, fase);
							if (x === Math.max(0, centro - 90)) ctx!.moveTo(x, y);
							else ctx!.lineTo(x, y);
						}
						ctx!.stroke();
					}
				}

				// --- El cruce: donde la trama pasa por debajo, la urdimbre se redibuja encima ---
				ctx!.lineWidth = 1;
				for (let c = 0; c < columnas; c++) {
					const x = c * densidad;
					if (x > hasta) break;
					if ((c + f) % 2 !== 0) continue;
					const y = ondaY(f, x, fase);
					ctx!.strokeStyle = c % 2 === 0 ? HILO : HILO_TENUE;
					ctx!.beginPath();
					ctx!.moveTo(x, y - 4);
					ctx!.lineTo(x, y + 4);
					ctx!.stroke();
				}
			}
		}

		function animar(ahora: number) {
			if (!inicio) inicio = ahora;
			const t = (ahora - inicio) / 1400;
			const avance = Math.min(1, t);
			// easeOutCubic: el telar frena al final en vez de cortarse en seco
			const suave = 1 - Math.pow(1 - avance, 3);

			const brillo = terminado ? ((ahora / 7000) % 1.6) - 0.3 : -1;
			pintar(suave, 0, brillo);

			if (avance >= 1) terminado = true;
			cuadro = requestAnimationFrame(animar);
		}

		medir();

		if (quieto) {
			pintar(1, 0, -1);
		} else {
			cuadro = requestAnimationFrame(animar);
		}

		const alRedimensionar = () => {
			medir();
			if (quieto) pintar(1, 0, -1);
		};
		window.addEventListener('resize', alRedimensionar);

		return () => {
			cancelAnimationFrame(cuadro);
			window.removeEventListener('resize', alRedimensionar);
		};
	});
</script>

<canvas bind:this={lienzo} aria-hidden="true"></canvas>

<style>
	/* El canvas es un elemento reemplazado: sin width/height explicitos usa su
	   tamano intrinseco de 300x150 aunque tenga inset:0. El scroll horizontal
	   que esto podria causar lo corta el overflow-x del body. */
	canvas {
		position: fixed;
		inset: 0;
		width: 100%;
		height: 100%;
		z-index: 0;
		pointer-events: none;
	}
</style>
