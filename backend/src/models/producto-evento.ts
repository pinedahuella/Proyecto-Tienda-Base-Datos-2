import {
  EntradaCaracteristica,
  Producto,
  ProductoCategoria,
  ProductoVariante,
} from './producto';

/**
 * Documentos de la coleccion `productos_eventos` en MongoDB.
 */
export interface ProductoEventoCreacion {
  /** "<id_producto>-<numero>", igual que en los eventos existentes. */
  _id: string;
  id_producto: number;
  numero: number;
  fecha: Date;
  operacion: 'creacion';
  /** La copia completa del producto tal como quedo creado, sin _id (ya va en id_producto). */
  datos: Omit<Producto, '_id'>;
}

/**
 * Los campos de la raiz del producto que se pueden editar (ver
 * ProductosVendedorService.editar). Cada uno sale completo cuando cambio,
 * nunca un diff parcial adentro — mismo criterio que ya usan los eventos
 * reales para categoria y variantes.
 */
export interface ProductoEventoCambios {
  nombre?: string;
  descripcion?: string | null;
  estado?: string;
  categoria?: ProductoCategoria;
  caracteristicas_adicionales?: EntradaCaracteristica[];
  caracteristicas_personalizadas?: EntradaCaracteristica[];
  variantes?: ProductoVariante[];
}

export interface ProductoEventoModificacion {
  _id: string;
  id_producto: number;
  numero: number;
  fecha: Date;
  operacion: 'modificacion';
  /** Solo las llaves que de verdad cambiaron en esta edicion, cada una completa. */
  cambios: ProductoEventoCambios;
}
