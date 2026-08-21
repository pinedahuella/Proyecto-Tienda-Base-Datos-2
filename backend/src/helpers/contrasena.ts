import { randomBytes, scrypt as scryptCallback, timingSafeEqual } from 'crypto';
import { promisify } from 'util';

const scrypt = promisify(scryptCallback);

const LONGITUD_SALT = 16;
const LONGITUD_HASH = 64;

/**
 * Hashea una contrasena con scrypt, el algoritmo que trae Node por defecto en
 * el modulo crypto. No hace falta una libreria externa como bcrypt.
 *
 * El salt sale al azar en cada llamada y viaja pegado al hash, separado por
 * ":". Hace falta un salt distinto por contrasena: si dos usuarios eligen la
 * misma contrasena, no pueden terminar con el mismo hash guardado.
 */
export async function hashearContrasena(contrasena: string): Promise<string> {
  const salt = randomBytes(LONGITUD_SALT).toString('hex');
  const derivada = (await scrypt(contrasena, salt, LONGITUD_HASH)) as Buffer;
  return `${salt}:${derivada.toString('hex')}`;
}

/**
 * Compara una contrasena en texto plano contra un hash guardado con
 * hashearContrasena().
 *
 * Usa timingSafeEqual para comparar los bytes: una comparacion normal (===)
 * termina apenas encuentra una diferencia, y ese tiempo de mas o de menos se
 * puede medir desde afuera para adivinar la contrasena byte a byte.
 */
export async function compararContrasena(
  contrasena: string,
  hash: string,
): Promise<boolean> {
  const [salt, hashGuardado] = hash.split(':');
  if (!salt || !hashGuardado) {
    return false;
  }

  const derivada = (await scrypt(contrasena, salt, LONGITUD_HASH)) as Buffer;
  const bufferGuardado = Buffer.from(hashGuardado, 'hex');

  if (derivada.length !== bufferGuardado.length) {
    return false;
  }

  return timingSafeEqual(derivada, bufferGuardado);
}
