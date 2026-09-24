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
