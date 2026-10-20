import { SignJWT, jwtVerify, JWTPayload } from 'jose';
import { obligatoria } from './entorno';
import { ErrorSesion } from './errores';
import { TokenUsuario } from '../dto/token-usuario';

const ALGORITMO = 'HS256';

// 2 horas, en segundos. Un solo numero: de aqui sale tanto la expiracion
// del token como la duracion de la cookie donde va a viajar, para que no
// puedan quedar desincronizados.
export const DURACION_SEGUNDOS = 60 * 60 * 2;

/** Nombre de la cookie donde el navegador guarda el token. */
export const NOMBRE_COOKIE_TOKEN = 'mesh_token';

/**
 * Opciones para esa cookie (van tal cual a reply.setCookie de Fastify
 * cuando exista la ruta de login).
 *
 * httpOnly para que JavaScript en el navegador no pueda leer la cookie: si
 * algun dia hay un XSS, el token no se puede robar desde ahi. secure solo
 * en produccion porque en desarrollo el backend corre sin HTTPS.
 */
export const OPCIONES_COOKIE_TOKEN = {
  httpOnly: true,
  sameSite: 'lax' as const,
  secure: process.env.NODE_ENV === 'production',
  path: '/',
  maxAge: DURACION_SEGUNDOS,
};

/**
 * La clave para firmar y verificar sale de JWT_SECRET. Igual que con la
 * contrasena de PostgreSQL: si no esta en .env, el backend no arranca en
 * vez de firmar con un secreto de a de veras.
 */
function obtenerClave(): Uint8Array {
  return new TextEncoder().encode(obligatoria('JWT_SECRET'));
}

/**
 * Firma un token con el id del usuario y su rol.
 *
 * No lleva nombre, correo ni nada que pueda cambiar despues: si esos datos
 * cambian en la base, el token viejo no queda desactualizado ni hay que
 * invalidarlo antes de tiempo.
 */
export async function firmarToken(datos: TokenUsuario): Promise<string> {
  return new SignJWT(datos)
    .setProtectedHeader({ alg: ALGORITMO })
    .setIssuedAt()
    .setExpirationTime(`${DURACION_SEGUNDOS}s`)
    .sign(obtenerClave());
}

/**
 * Verifica la firma y que no este vencido, y devuelve el payload.
 *
 * Cualquier motivo de fallo (firma invalida, vencido, formato raro, le
 * falta id_usuario o id_rol_usuario) se agrupa en ErrorSesion: a quien
 * llama no le interesa por que fallo el token, solo que no sirve.
 */
export async function verificarToken(token: string): Promise<TokenUsuario> {
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(token, obtenerClave()));
  } catch {
    throw new ErrorSesion('Token invalido o expirado');
  }

  if (!esTokenUsuario(payload)) {
    throw new ErrorSesion('Token invalido o expirado');
  }

  return payload;
}

function esTokenUsuario(payload: JWTPayload): payload is TokenUsuario {
  return (
    typeof payload.id_usuario === 'string' &&
    typeof payload.id_rol_usuario === 'number'
  );
}
