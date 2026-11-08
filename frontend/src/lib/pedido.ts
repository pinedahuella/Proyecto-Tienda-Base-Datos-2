import { browser } from '$app/environment';
import { pedir, conJson } from './api';

/**
 * Todo lo que hace falta para hablar con /comprador/pedidos.
 *
 * La compra sale del carrito (/carrito y el checkout, POST /carrito/comprar).
 * Desde el 2026-10-17 el carrito ES el pedido `pendiente` de la cuenta en
 * PostgreSQL, con una copia rapida en Redis, y el backend quito las seis
 * rutas que armaban un pedido a mano (crear, agregar, cambiar y quitar
 * lineas, cambiar la direccion y comprar): ahora dan 404. El pendiente
 * tampoco se lista ni se ve por id aqui.
 *
 * Las rutas que se usan (ninguna pide un rol, solo sesion: comprar no es privilegio
 * de nadie, cualquiera con cuenta compra -- tambien un vendedor o un admin):
 *
 *   GET    /comprador/pedidos                         los mios, resumidos
 *   GET    /comprador/pedidos/metodos-pago            el catalogo de formas de pago
 *   GET    /comprador/pedidos/:id                     el pedido, su direccion y sus lineas
 *   POST   /comprador/pedidos/:id/cancelar            cancela (y devuelve stock si ya se compro)
 *
 * Se compra una OFERTA, nunca un producto ni una variante: la misma
 * presentacion la venden varias personas a precios distintos. El precio se
 * congela al agregar la linea (`agregar_linea` guarda el id de la fila
 * vigente de `precio_historial`, que no se actualiza nunca), asi que si el
 * vendedor lo sube despues, quien ya la tenia en el carrito paga el viejo.
 */

/**
 * Donde el flujo viejo guardaba el id del pedido abierto. Ya nadie la
 * escribe; solo se borra (ver olvidarPedidoAbierto).
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
	/**
	 * El % de descuento que tenia la oferta cuando se congelo el precio, o
	 * null. Solo informativo: `precio_unitario` ya lo trae aplicado. Opcional
	 * porque solo lo manda el detalle del pedido (y el carrito, al pasar las
	 * lineas al checkout).
	 */
	porcentaje_descuento_aplicado?: string | null;
	cantidad: number;
	/** El id de la fila de precio_historial que congelo el precio de esta linea. */
	id_precio_historial?: string;

	/**
	 * Si esta compra da derecho a resenar. La regla es la misma que exige el
	 * backend al publicar: el pedido esta pagado y no esta cancelado.
	 *
	 * Los dos son OPCIONALES a proposito. Solo los manda
	 * `GET /comprador/pedidos/:id`, y un backend anterior al 2026-09-04 no los
	 * manda en absoluto. Sin ellos el boton simplemente no sale, que es como
	 * tiene que fallar: ofrecerlo y que el POST conteste 403 seria peor que no
	 * ofrecerlo.
	 */
	puede_resenar?: boolean;
	/**
	 * Si ya se reseno ESTA compra. Mira el trio completo
	 * (comprador, vendedor, producto), que es el mismo que protege el UNIQUE de
	 * `resena`, y no solo el producto.
	 *
	 * La diferencia importa y se ve en el pedido 17 de la semilla: el mismo
	 * producto comprado a dos vendedores distintos se resena DOS veces, una por
	 * vendedor. Mirando solo el producto, resenar a uno apagaria el boton del
	 * otro.
	 */
	ya_reseno?: boolean;
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
	/** true si lo cancelo la tienda y no la cuenta (migracion 051). */
	cancelado_por_tienda?: boolean;
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

// ------------------------------------------------------------ limpieza
export function olvidarPedidoAbierto() {
	if (!browser) return;
	// LLAVE ya no la escribe nadie: era del pedido abierto del flujo viejo.
	// Se borra por la misma razon que la de abajo.
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
