import { pedir, type RespuestaApi } from './api';

/**
 * El ACL de funcionalidades, por rol (migracion 050, ADR-26).
 *
 * Cada ruta privada del backend pide un permiso (modulo.accion) y la tabla
 * rol_permiso dice que rol lo tiene. Lo que un rol no tiene se niega con 403,
 * aunque se llame a la ruta directo. Esta pantalla solo ensena y cambia la
 * tabla; quien niega es el backend.
 *
 *   GET    /admin/permisos                      la matriz
 *   GET    /admin/permisos/registro?limite=N    los intentos negados y los cambios
 *   POST   /admin/permisos/:idRol/:idPermiso    dar
 *   DELETE /admin/permisos/:idRol/:idPermiso    quitar
 */

export interface RolDeLaMatriz {
	id_rol_usuario: number;
	rol: string;
}

export interface PermisoDeLaMatriz {
	id_permiso: number;
	codigo: string;
	permiso: string;
	descripcion: string;
	roles: number[];
	protegido_para: number[];
}

export interface ModuloDeLaMatriz {
	modulo: string;
	descripcion: string;
	permisos: PermisoDeLaMatriz[];
}

export interface MatrizPermisos {
	roles: RolDeLaMatriz[];
	modulos: ModuloDeLaMatriz[];
}

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

export function leerMatriz(): Promise<RespuestaApi<MatrizPermisos>> {
	return pedir<MatrizPermisos>('/admin/permisos');
}

export function leerRegistro(limite = 30): Promise<RespuestaApi<RegistroPermiso[]>> {
	return pedir<RegistroPermiso[]>(`/admin/permisos/registro?limite=${limite}`);
}

export function darPermiso(idRol: number, idPermiso: number): Promise<RespuestaApi<unknown>> {
	return pedir<unknown>(`/admin/permisos/${idRol}/${idPermiso}`, { method: 'POST' });
}

export function quitarPermiso(idRol: number, idPermiso: number): Promise<RespuestaApi<unknown>> {
	return pedir<unknown>(`/admin/permisos/${idRol}/${idPermiso}`, { method: 'DELETE' });
}

/** Los nombres de los roles como se leen en pantalla. */
export function nombreRol(rol: string): string {
	return rol.charAt(0).toUpperCase() + rol.slice(1);
}
