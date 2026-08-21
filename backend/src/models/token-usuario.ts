import { JWTPayload } from 'jose';

/**
 * Lo que va firmado dentro del token de sesion: el usuario y su rol, nada
 * mas. Si el nombre o el correo del usuario cambian, el token viejo no
 * queda desactualizado porque nunca los llevo.
 *
 * Extiende JWTPayload (el tipo que usa la libreria jose) para que este
 * objeto se pueda firmar y leer directamente, sin conversiones.
 */
export interface TokenUsuario extends JWTPayload {
  id_usuario: string;
  id_rol_usuario: number;
}
