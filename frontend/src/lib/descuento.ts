/**
 * Lo poco que hace falta para pintar un descuento, en un solo sitio.
 *
 * El backend manda el porcentaje como texto (`numeric(5,2)` de PostgreSQL:
 * "25.00", "12.50") o `null` cuando la oferta no tiene descuento. El precio
 * final ya viene calculado (`precio_final` en las ofertas, `precio` en el
 * carrito): aqui NO se calcula ningun precio. Hacerlo en el navegador seria
 * una segunda formula que puede redondear distinto que la de PostgreSQL, y
 * entonces la pantalla diria un precio y se cobraria otro.
 *
 * Ver backend/elementos Generales/plan pendiente/descuentos-oferta.md.
 */

/** Si ese porcentaje es un descuento de verdad (no null, no vacio, mayor que 0). */
export function tieneDescuento(porcentaje: string | number | null | undefined): boolean {
	if (porcentaje == null || porcentaje === '') return false;
	const n = Number(porcentaje);
	return Number.isFinite(n) && n > 0;
}

/**
 * "25.00" -> "25%", "12.50" -> "12.5%". Sin los ceros de sobra: "-25.00%"
 * en una etiqueta chica se lee como un numero de contabilidad, no como una
 * rebaja.
 */
export function textoPorcentaje(porcentaje: string | number | null | undefined): string {
	const n = Number(porcentaje ?? 0);
	return n.toLocaleString('es-GT', { maximumFractionDigits: 2 }) + '%';
}

/**
 * Lo que se ensena cuando el backend contesta 409 al poner un descuento, abrir
 * una venta relampago o activar una regla.
 *
 * Desde el 2026-09-24 los cuatro mecanismos (descuento manual con su venta
 * relampago, regla automatica y regla por periodo) se excluyen: una oferta
 * tiene uno activo como mucho. El backend lo dice asi, en
 * `helpers/exclusion-mecanismos-descuento.ts`:
 *
 *   "Esta oferta ya tiene una regla de descuento por periodo activa: los
 *    mecanismos de descuento/venta relampago son mutuamente excluyentes,
 *    hay que desactivar ese primero"
 *
 * La primera mitad sirve tal cual. La segunda habla de "mecanismos", que es
 * vocabulario nuestro, y se cambia por lo que la persona tiene que hacer.
 * Cualquier otro 409 (el solape entre reglas por periodo, una regla automatica
 * repetida) ya viene escrito para leerse y pasa sin tocar.
 *
 * Devuelve null si no es un 409, para que quien llama use su mensaje de
 * siempre.
 */
export function textoConflictoDescuento(r: { estado: number; mensaje?: string }): string | null {
	if (r.estado !== 409) return null;
	// El backend a veces nombra la fila con su id ("activa (id 4)"). Al usuario no le dice nada.
	const mensaje = (typeof r.mensaje === 'string' ? r.mensaje : '').replace(/\s*\(id \d+\)/gi, '').trim();
	if (/regla de descuento por periodo activa.*se solapa/i.test(mensaje)) {
		return 'Ya hay una regla activa para esta oferta en esos dias. Cambia las fechas o pausa la otra.';
	}
	const exclusion = /^(Esta oferta ya tiene [^:]+):\s*los mecanismos/i.exec(mensaje);
	if (exclusion) {
		return `${exclusion[1]}. Solo puede tener un descuento a la vez. Quitalo o pausa esa regla y vuelve a intentar.`;
	}
	return mensaje || 'Esta oferta ya tiene otro descuento activo.';
}
