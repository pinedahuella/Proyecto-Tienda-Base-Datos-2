import { Usuario } from './usuario';

/** Cuerpo esperado en POST /usuario/registro. */
export interface RegistroUsuarioPeticion {
  correo_electronico: string;
  usuario: string;
  nombre: string;
  apellido?: string | null;
  contrasena: string;
  fecha_nacimiento?: string | null;
}

/**
 * Lo que devuelve POST /usuario/registro: el usuario creado, sin el hash de
 * la contrasena. Ese campo no sale nunca de la base de datos.
 */
export type UsuarioRegistrado = Omit<Usuario, 'contrasena_hash'>;
