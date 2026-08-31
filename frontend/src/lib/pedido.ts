import { browser } from '$app/environment';
import { pedir, conJson, type RespuestaApi } from './api';

/**
 * El pedido abierto, y todo lo que hace falta para hablar con
 * /comprador/pedidos.
 *
 * Las ocho rutas (ninguna pide un rol, solo sesion: comprar no es privilegio
 * de nadie, cualquiera con cuenta compra -- tambien un vendedor o un admin):
 *
 *   POST   /comprador/pedidos                         abre un pedido
 *   GET    /comprador/pedidos                         los mios, resumidos
 *   GET    /comprador/pedidos/metodos-pago            el catalogo de formas de pago
 *   GET    /comprador/pedidos/:id                     el pedido, su direccion y sus lineas
 *   PATCH  /comprador/pedidos/:id                     cambia la direccion de entrega
 *   POST   /comprador/pedidos/:id/detalles            agrega (o suma) una linea
 *   DELETE /comprador/pedidos/:id/detalles/:idDetalle quita una linea
 *   POST   /comprador/pedidos/:id/comprar             cierra la compra
 *   POST   /comprador/pedidos/:id/cancelar            cancela (y devuelve stock si ya se compro)
 *
 * Se compra una OFERTA, nunca un producto ni una variante: la misma
 * presentacion la venden varias personas a precios distintos. El precio se
 * congela al agregar la linea (`agregar_linea` guarda el id de la fila
 * vigente de `precio_historial`, que no se actualiza nunca), asi que si el
 * vendedor lo sube despues, quien ya la tenia en el carrito paga el viejo.
 */

/**
 * El id del pedido abierto vive en localStorage, no en una cookie ni en la
 * URL: no es un secreto (el backend comprueba que el pedido sea tuyo y da 404
 * si no lo es) y tiene que sobrevivir a recargar la pagina.
 *
 * Ya existe `GET /comprador/pedidos`, asi que perderlo dejo de ser fatal: se
 * puede volver a encontrar el pendiente en esa lista. Se sigue guardando
 * porque evita esa consulta en cada carga.
 */
const LLAVE = 'mesh.pedido';

/**
 * Que lineas del carrito estan marcadas para comprar.
 *
 * Vive SOLO en el navegador, y es a proposito: el backend no tiene ninguna
 * idea de "seleccionado" -- un pedido se compra entero. Marcar y desmarcar es
 * una ayuda para decidir, y al comprar hay que quitar de verdad lo que no se
 * quiera (ver Carrito.svelte, que lo avisa antes de hacerlo).
 */
const LLAVE_MARCADAS = 'mesh.pedido.marcadas';

export interface LineaPedido {
	id_pedido_producto: string;
	id_pedido: string;
	id_producto_mongo: string;
	id_producto_variante_mongo: string;
	nombre_producto: string;
	nombre_variante: string;
	/** Como se llamaba el vendedor ese dia. Se copia porque el nombre cambia. */
	nombre_vendedor: string;
	/**
	 * La oferta a la que se le compro. Con ella se suma otra unidad al mismo
	 * vendedor; sumarla por variante compraria a cualquiera.
	 */
	id_oferta: string;
	id_usuario_vendedor: string;
	/** Decimal de PostgreSQL: viaja como texto para no perder centavos. */
	precio_unitario: string;
	cantidad: number;
	/** El id de la fila de precio_historial que congelo el precio de esta linea. */
	id_precio_historial?: string;
}

export interface CabeceraPedido {
	id_pedido: string;
	fecha_creacion: string;
	id_usuario: string;
	id_direccion_historial: string;
	id_estado_pedido: number;
	estado_pedido_nombre: string;
}

/**
 * La VERSION de la direccion que regia al crear el pedido, no la direccion
 * vigente hoy: por eso trae su propia fecha_creacion, que es desde cuando
 * rige esa version.
 */
export interface DireccionDelPedido {
	id_direccion_historial: string;
	id_direccion: string;
	pais: string;
	departamento: string;
	ciudad: string;
	/**
	 * La calle, el numero, la zona y las referencias, en una linea.
	 *
	 * Puede venir NULL, y no es un error: la columna es de la migracion 008 y
	 * las versiones del historial anteriores a ella no la tienen. Nadie sabe
	 * que calle regia entonces, asi que NULL dice exactamente eso.
	 */
	direccion_exacta: string | null;
	codigo_postal: string | null;
	fecha_creacion: string;
}

/** Lo que devuelve GET /comprador/pedidos/:id. */
export interface PedidoCompleto {
	pedido: CabeceraPedido;
	direccion: DireccionDelPedido;
	detalles: LineaPedido[];
}

/**
 * Una fila de GET /comprador/pedidos: el pedido resumido, sin sus lineas.
 *
 * Los tres campos del pago salen `null` mientras sigue `pendiente`: el pago
 * nace recien al comprar.
 */
export interface ResumenPedido {
	id_pedido: string;
	fecha_creacion: string;
	id_estado_pedido: number;
	estado_pedido_nombre: string;
	/** Suma de precio congelado * cantidad. "0.00" si no tiene lineas. */
	total: string;
	cantidad_lineas: number;
	metodo_pago: string | null;
	estado_pago: string | null;
	fecha_cancelacion: string | null;
}

/** Lo que devuelve POST /comprador/pedidos/:id/detalles. */
export interface LineaAgregada {
	id_pedido: number;
	id_oferta: number;
	id_usuario_vendedor: number;
	id_pedido_producto: number;
	/** La cantidad ACUMULADA de esa variante en el pedido, no la de esta llamada. */
	cantidad: number;
	stock_disponible: number;
}

export interface MetodoPago {
	id_metodo_pago: number;
	/** Esto es lo que hay que mandar en `metodo_pago` al comprar, NO el id. */
	metodo_nombre: string;
}

/** El mock de tarjeta. No se guarda en ninguna tabla: no hay columna para eso. */
export interface DatosTarjeta {
	numero: string;
	/** MM/AA */
	vencimiento: string;
	cvv: string;
	titular: string;
}

/**
 * Una linea cuyo precio de hoy ya no es el que quedo congelado.
 *
 * NO bloquea la compra: se cobra el congelado igual. Pero se avisa antes de
 * cobrar, y para seguir hay que repetir la peticion con confirmar_cambios.
 */
export interface AvisoDePrecio {
	id_pedido_producto: number;
	nombre_producto: string;
	nombre_variante: string;
	precio_congelado: string;
	precio_actual: string;
}

/** El saldo que le quedo a cada oferta tocada. */
export interface StockResultante {
	id_oferta: number;
	id_usuario: number;
	id_producto: number;
	id_producto_variante: number;
	stock: number;
}

/**
 * Lo que devuelve comprar. Ojo con `comprado`: puede venir `ok: true` con
 * `comprado: false`, que quiere decir "no compre nada todavia, mira estos
 * avisos y vuelve a mandarlo con confirmar_cambios".
 */
export interface ResultadoCompra {
	comprado: boolean;
	id_pedido?: number;
	total?: string;
	stock?: StockResultante[];
	avisos?: AvisoDePrecio[];
}

export interface ResultadoCancelacion {
	id_pedido: number;
	estado_previo: string;
	/** Vacio si el pedido estaba pendiente: no habia nada que devolver. */
	stock: StockResultante[];
}

// ------------------------------------------------------------ el id guardado
export function leerPedidoAbierto(): string | null {
	if (!browser) return null;
	return localStorage.getItem(LLAVE);
}

export function guardarPedidoAbierto(idPedido: string) {
	if (!browser) return;
	localStorage.setItem(LLAVE, idPedido);
}

export function olvidarPedidoAbierto() {
	if (!browser) return;
	localStorage.removeItem(LLAVE);
	// LLAVE_MARCADAS ya no la escribe nadie: era del carrito viejo, que se
	// borro con `Carrito.svelte`. Se sigue BORRANDO a proposito, porque en los
	// navegadores que usaron aquella version la clave quedo escrita y solo se
	// va por aqui. Es limpieza de lo que dejamos, no codigo muerto.
	localStorage.removeItem(LLAVE_MARCADAS);
}

// ------------------------------------------------------------ las rutas
/**
 * Una direccion del usuario, tal como la devuelve GET /direccion-usuario.
 *
 * Es la fila VIVA, la que se puede editar. La que guarda un pedido es otra
 * cosa: una version congelada en `direccion_historial` (ver DireccionDelPedido),
 * para que el pedido siempre diga a donde se mando de verdad aunque despues se
 * corrija la direccion.
 */
export interface DireccionUsuario {
	id_direccion: string;
	id_usuario: string;
	pais: string;
	departamento: string;
	ciudad: string;
	/** La calle. Puede ser NULL en las direcciones anteriores a la migracion 008. */
	direccion_exacta: string | null;
	codigo_postal: string | null;
	fecha_creacion: string;
	id_estado_direccion: number;
}

/** Las direcciones propias. Un usuario sin ninguna recibe [], no un error. */
export function traerDirecciones() {
	return pedir<DireccionUsuario[]>('/direccion-usuario');
}

/**
 * Crea una direccion. El codigo postal es lo unico opcional.
 *
 * `direccion_exacta` va OBLIGATORIA: el backend responde 400 sin ella, porque
 * sin calle no se puede entregar un pedido. Al EDITAR si es opcional, pero esta
 * funcion solo crea.
 */
export function crearDireccion(datos: {
	pais: string;
	departamento: string;
	ciudad: string;
	direccion_exacta: string;
	codigo_postal?: string | null;
}) {
	return pedir<DireccionUsuario>('/direccion-usuario', conJson('POST', datos));
}

/**
 * Como se lee una direccion en una linea.
 *
 * La calle va DELANTE porque es lo que de verdad lleva el paquete a la puerta;
 * lo demas es el punto del mapa. Va opcional en el tipo y con `filter(Boolean)`
 * porque puede ser NULL en las direcciones anteriores a la migracion 008, y en
 * ese caso la linea sale como salia antes en vez de con un hueco.
 *
 * OJO al tocar esta funcion: su texto tambien alimenta la comparacion de
 * Checkout que avisa "esa es la version que se guardo" (`entregaDesactualizada`).
 * Si la calle entrara aqui pero no viniera en las dos respuestas del backend, el
 * aviso quedaria encendido para siempre. Comprobado antes de agregarla: la traen
 * las dos, `GET /direccion-usuario` y la direccion del pedido.
 */
export function direccionEnUnaLinea(d: {
	ciudad: string;
	departamento: string;
	pais: string;
	direccion_exacta?: string | null;
	codigo_postal?: string | null;
}): string {
	const partes = [d.direccion_exacta, d.ciudad, d.departamento, d.pais].filter(Boolean);
	const texto = partes.join(', ');
	return d.codigo_postal ? `${texto} (${d.codigo_postal})` : texto;
}

/**
 * Una caracteristica reconstruida. `valor` puede ser una lista ("Contenido del
 * paquete"), un numero con unidad ("Garantia: 18 meses") o un texto suelto.
 */
export interface CaracteristicaEnFecha {
	nombre: string;
	valor: string | number | boolean | string[];
	unidad?: string | null;
}

/** Una presentacion del producto, tal como estaba ese dia. */
export interface VarianteEnFecha {
	id_producto_variante: number;
	nombre_variante: string;
	descripcion?: string | null;
	caracteristicas_adicionales?: CaracteristicaEnFecha[];
	caracteristicas_personalizadas?: CaracteristicaEnFecha[];
}

/**
 * Lo que devuelve GET /productos/:id/historial?fecha=
 *
 * TODOS los campos menos `_id` son opcionales o admiten null, y no es
 * pereza al tipar: la reconstruccion fusiona eventos, y cada evento aporta
 * solo lo que cambio. Un producto cuya creacion es el unico evento anterior
 * a la fecha trae lo que tuviera ese dia y nada mas.
 *
 * OJO -- este tipo se quedo corto una vez y costo caro: declaraba solo
 * `nombre` y `descripcion`, asi que la pantalla de pedidos ensenaba dos
 * campos de los cinco que la ruta manda. No daba ningun error, ni de
 * TypeScript ni en consola: los otros tres simplemente no existian. Si esta
 * ruta empieza a mandar un campo mas, se agrega AQUI, que es de donde
 * cuelgan las pantallas.
 */
export interface ProductoEnFecha {
	_id: number;
	nombre: string | null;
	descripcion: string | null;
	categoria?: { nombre: string; id_categoria?: number; categoria_padre?: string | null } | null;
	variantes?: VarianteEnFecha[];
	caracteristicas_adicionales?: CaracteristicaEnFecha[];
	caracteristicas_personalizadas?: CaracteristicaEnFecha[];
}

/**
 * Reconstruye un producto tal como estaba en una fecha.
 *
 * Publica, y a diferencia de GET /productos/:id **no oculta** los productos
 * en borrador o inactivos: un pedido viejo tiene que poder ensenar su producto
 * aunque hoy ya no este en el catalogo.
 *
 * La fecha va como AAAA-MM-DD.
 */
export function traerProductoEnFecha(idProducto: string | number, fecha: string) {
	return pedir<ProductoEnFecha>(
		`/productos/${idProducto}/historial?fecha=${encodeURIComponent(fecha)}`
	);
}

/** Precio y existencias de una oferta, tal como estaban ese dia. */
export interface OfertaEnFecha {
	id_oferta: string;
	/** Decimal de PostgreSQL: viaja como texto para no perder centavos. */
	precio: string;
	stock: number;
}

/**
 * El precio y el stock que tenia una oferta en una fecha.
 *
 * Va aparte del producto y no se puede unir: el catalogo de Mongo no guarda
 * ninguno de los dos, porque al volverse multi-vendedor dejaron de ser del
 * producto. Su historia vive en `precio_historial` y `stock_movimiento`, en
 * PostgreSQL, y hay una por vendedor.
 *
 * Un 404 aqui significa "la oferta no existia en esa fecha", que es un dato
 * y no un fallo (lo distingue el backend por que no haya ninguna fila de
 * precio_historial anterior; ver ProductosService.reconstruirOfertaEnFecha).
 */
export function traerOfertaEnFecha(idOferta: string | number, fecha: string) {
	return pedir<OfertaEnFecha>(
		`/productos/ofertas/${idOferta}/historial?fecha=${encodeURIComponent(fecha)}`
	);
}

/** Abre un pedido nuevo sobre una direccion del usuario. */
export function crearPedido(idDireccion: string | number) {
	return pedir<{ id_pedido: string }>(
		'/comprador/pedidos',
		// Se manda TAL CUAL, sin Number(). El backend lo declara `number | string`
		// a proposito (dto/cambiar-direccion-pedido.ts) y lo resuelve el mismo:
		// es un bigint que el driver entrega como texto para no perder precision,
		// y convertirlo aqui vuelve a meter justo la perdida que el backend evita.
		conJson('POST', { id_direccion: idDireccion })
	);
}

/** Todos los pedidos propios, resumidos, del mas nuevo al mas viejo. */
export function listarPedidos() {
	return pedir<ResumenPedido[]>('/comprador/pedidos');
}

export function traerPedido(idPedido: string) {
	return pedir<PedidoCompleto>(`/comprador/pedidos/${idPedido}`);
}

/** El catalogo cerrado de formas de pago. Se pide, no se escribe a mano. */
export function traerMetodosPago() {
	return pedir<MetodoPago[]>('/comprador/pedidos/metodos-pago');
}

/**
 * Cambia a donde se entrega un pedido que sigue pendiente.
 *
 * Recibe el `id_direccion` normal, no el del historial: el backend resuelve
 * cual es la version vigente antes de aplicarlo.
 */
export function cambiarDireccionPedido(idPedido: string, idDireccion: string | number) {
	return pedir<{ id_pedido: number; id_direccion: number }>(
		`/comprador/pedidos/${idPedido}`,
		conJson('PATCH', { id_direccion: idDireccion })
	);
}

/**
 * Agrega una OFERTA al pedido, no un producto.
 *
 * Desde el giro multi-vendedor la misma variante la puede vender media
 * docena de personas, cada una a su precio: hay que decir a cual se le
 * compra. El backend resuelve solo el producto, la variante, el nombre y el
 * precio a partir de la oferta, asi que desde aqui no se manda ninguno --
 * y por eso nadie puede mandar un precio falso.
 */
export function agregarLinea(
	idPedido: string,
	linea: { id_oferta: number; cantidad: number }
) {
	return pedir<LineaAgregada>(
		`/comprador/pedidos/${idPedido}/detalles`,
		conJson('POST', linea)
	);
}

export function quitarLinea(idPedido: string, idDetalle: string) {
	return pedir<null>(`/comprador/pedidos/${idPedido}/detalles/${idDetalle}`, {
		method: 'DELETE'
	});
}

/**
 * Cierra la compra.
 *
 * `tarjeta` solo va cuando el metodo es "tarjeta". `confirmar_cambios` se
 * manda en el SEGUNDO intento, cuando el primero contesto con avisos de
 * precio: sin el, el backend vuelve a avisar y no compra.
 *
 * Codigos que hay que distinguir arriba:
 *   402  el cobro simulado no paso (tarjeta rechazada, sin fondos...)
 *   409  la oferta se pauso o ya no hay stock. Esto NO se salta con nada.
 */
export function comprarPedido(
	idPedido: string,
	cuerpo: { metodo_pago: string; tarjeta?: DatosTarjeta; confirmar_cambios?: boolean }
) {
	return pedir<ResultadoCompra>(
		`/comprador/pedidos/${idPedido}/comprar`,
		conJson('POST', cuerpo)
	);
}

/**
 * Cancela un pedido propio.
 *
 * Si estaba comprado, devuelve las unidades con un movimiento de
 * `devolucion` y el pago pasa a reembolsado; el libro mayor no se corrige
 * borrando renglones. Si estaba pendiente no toca stock, porque nunca se
 * descontó.
 */
export function cancelarPedido(idPedido: string) {
	return pedir<ResultadoCancelacion>(`/comprador/pedidos/${idPedido}/cancelar`, {
		method: 'POST'
	});
}

// ------------------------------------------------------------ cuentas
/**
 * Lo que cuesta una linea. El precio viaja como texto (es un decimal de
 * PostgreSQL) y hay que convertirlo aqui, no antes: hacerlo en el backend
 * seria devolver un float y ahi es donde se pierden los centavos.
 */
export function subtotal(linea: LineaPedido): number {
	return Number(linea.precio_unitario) * linea.cantidad;
}

export function totalPedido(detalles: LineaPedido[]): number {
	return detalles.reduce((suma, linea) => suma + subtotal(linea), 0);
}

export function quetzales(n: number): string {
	return 'Q' + n.toLocaleString('es-GT', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/**
 * true si la respuesta dice que el pedido guardado ya no sirve.
 *
 * El backend da 404 tanto si el pedido no existe como si es de otra persona
 * (no confirma por esta via que exista uno ajeno). En los dos casos lo que
 * hay guardado en este navegador esta caduco y hay que olvidarlo, o la
 * pantalla se queda pidiendo para siempre un pedido que nunca va a llegar.
 */
export function pedidoCaduco(r: RespuestaApi<unknown>): boolean {
	return r.estado === 404;
}
