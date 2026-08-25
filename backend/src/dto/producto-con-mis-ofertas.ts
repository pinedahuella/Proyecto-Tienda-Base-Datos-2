import { Producto, ProductoVariante } from '../models/producto';
import { OfertaPropiaResumen } from '../models/oferta';

/**
 * Una variante con mi oferta (la del vendedor logueado) embebida, o null
 * si todavia no oferto sobre ella. Es la variante tal cual vive en Mongo
 * mas ese unico campo agregado -- no se guarda asi, se arma solo para
 * responder GET /vendedor/ofertas/producto/:id.
 */
export interface ProductoVarianteConMiOferta extends ProductoVariante {
  mi_oferta: OfertaPropiaResumen | null;
}

/**
 * Respuesta de GET /vendedor/ofertas/producto/:id: el producto completo
 * (misma forma que GET /productos/:id, pero SIN excluir `inactivo`/
 * `borrador` -- un vendedor tiene que poder ver un producto oculto para
 * decidir si le conviene ofertarlo, no solo lo que ya esta publicado), con
 * `mi_oferta` embebida en cada variante.
 */
export interface ProductoConMisOfertas extends Omit<Producto, 'variantes'> {
  variantes: ProductoVarianteConMiOferta[];
}
