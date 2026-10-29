/**
 * El ACL de funcionalidades (migracion 050, ADR-26): cada accion de la tienda
 * tiene un codigo modulo.accion, cada ruta privada declara el suyo con
 * @Permiso(...) y la tabla rol_permiso dice que rol lo tiene.
 *
 * Esta lista es la misma de la semilla de la 050. Esta aqui para que un
 * @Permiso('ofertas.publcar') no compile; que cada codigo exista en la base y
 * que cada ruta privada declare uno lo comprueba pruebas/permisos_cobertura.cjs.
 */
export const PERMISOS = [
  'cuenta.ver',
  'cuenta.editar',
  'direcciones.administrar',
  'carrito.usar',
  'carrito.comprar',
  'pedidos.ver',
  'pedidos.cancelar',
  'avisos.usar',
  'resenas.escribir',
  'resenas.votar',
  'productos.historial',
  'productos.para_ti',
  'ofertas.ver',
  'ofertas.publicar',
  'ofertas.editar',
  'ofertas.descuento',
  'ofertas.venta_relampago',
  'ofertas.revisar',
  'ofertas.compartir',
  'ofertas.usar_compartidas',
  'catalogo.ver',
  'catalogo.proponer',
  'catalogo.editar',
  'catalogo.revisar',
  'catalogo.buscar_todo',
  'reglas.ver',
  'reglas.administrar',
  'dashboard.ver',
  'dashboard.exportar',
  'tendencias.ver',
  'fraude.ver',
  'fraude.resolver',
  'usuarios.ver',
  'usuarios.editar',
  'reportes.ver',
  'sistema.ver',
  'permisos.ver',
  'permisos.administrar',
] as const;

export type CodigoPermiso = (typeof PERMISOS)[number];

/** Un rol, como columna de la matriz. */
export interface RolDeLaMatriz {
  id_rol_usuario: number;
  rol: string;
}

/** Un permiso, como fila de la matriz, con los roles que lo tienen. */
export interface PermisoDeLaMatriz {
  id_permiso: number;
  codigo: string;
  permiso: string;
  descripcion: string;
  /** id_rol_usuario de los roles que lo tienen. */
  roles: number[];
  /** id_rol_usuario a los que no se les puede quitar desde la API. */
  protegido_para: number[];
}

export interface ModuloDeLaMatriz {
  modulo: string;
  descripcion: string;
  permisos: PermisoDeLaMatriz[];
}

/** Lo que devuelve GET /admin/permisos. */
export interface MatrizPermisos {
  roles: RolDeLaMatriz[];
  modulos: ModuloDeLaMatriz[];
}

/** Una fila de auditoria_permiso, con nombres en vez de ids. */
export interface RegistroPermiso {
  id_auditoria_permiso: string;
  fecha: string;
  accion: 'negado' | 'otorgar' | 'revocar';
  actor: { id_usuario: string; usuario: string | null; correo: string | null };
  rol: string;
  codigo: string;
  metodo: string | null;
  ruta: string | null;
}
