import { Logger } from '@nestjs/common';
import { redis } from '../database/redis';
import type { UsuarioRegistrado } from '../dto/registro-usuario';
import { DURACION_SEGUNDOS } from './token';

/**
 * Una copia en Redis del perfil de quien tiene la sesion abierta, para que la
 * tienda lo siga reconociendo si PostgreSQL se cae (2026-10-20).
 *
 * Con PostgreSQL caido, la sesion ya abierta sigue valiendo (el token esta
 * firmado y `SesionGuard` se lo cree cuando no puede preguntarle a la base),
 * pero `GET /usuario/yo` no tenia de donde sacar el nombre y el correo, y la
 * cabecera no sabia quien era la persona. Esta copia es eso y nada mas: lo
 * publico del perfil, lo mismo que devuelve `/usuario/yo`. NO lleva la
 * contrasena ni nada para entrar: sin PostgreSQL no se puede iniciar sesion, y
 * es a proposito (una copia de las credenciales en otra base seria otro lugar
 * que proteger, y una cuenta suspendida podria entrar con la copia vieja).
 *
 * Se escribe al iniciar sesion y cada vez que `/usuario/yo` lee el perfil de
 * PostgreSQL, y vence con el token (2 horas): despues de eso la sesion tampoco
 * sirve. Escribirla nunca frena ni tumba nada: si Redis no esta, no hay copia.
 */
const logger = new Logger('PerfilSesion');

function clave(idUsuario: string): string {
  return `mesh:sesion:perfil:${idUsuario}`;
}

/** Guarda la copia. Nunca lanza. */
export async function guardarPerfilDeSesion(
  usuario: UsuarioRegistrado,
): Promise<void> {
  try {
    await redis.set(
      clave(usuario.id_usuario),
      JSON.stringify(usuario),
      'EX',
      DURACION_SEGUNDOS,
    );
  } catch (error) {
    logger.warn(
      `no se pudo guardar la copia del perfil de ${usuario.id_usuario}: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

/** La copia, o `null` si no hay (vencio, o nunca se guardo). Lanza si Redis no responde. */
export async function leerPerfilDeSesion(
  idUsuario: string,
): Promise<UsuarioRegistrado | null> {
  const valor = await redis.get(clave(idUsuario));
  if (valor == null) {
    return null;
  }
  try {
    return JSON.parse(valor) as UsuarioRegistrado;
  } catch {
    return null;
  }
}
