import { ErrorValidacion } from './errores';

const REGEX_FECHA = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Reglas de nombre, apellido, fecha de nacimiento y contrasena: van aqui,
 * sueltas de UsuarioService, porque las usa mas de un lugar (POST
 * /usuario/registro, PATCH /admin/usuarios/:id, PATCH /perfil, PATCH
 * /perfil/contrasena) y tienen que dar exactamente los mismos mensajes en
 * todos. Si alguna regla cambia, cambia en un solo sitio.
 */

export function esTextoNoVacio(valor: unknown): valor is string {
  return typeof valor === 'string' && valor.trim().length > 0;
}

export function validarNombre(nombre: string): void {
  if (!esTextoNoVacio(nombre)) {
    throw new ErrorValidacion('El nombre es obligatorio');
  }
  if (nombre.length > 100) {
    throw new ErrorValidacion('El nombre no puede tener mas de 100 caracteres');
  }
}

/** apellido es opcional: solo se revisa la longitud si de verdad viene algo. */
export function validarApellido(apellido: string | null | undefined): void {
  if (apellido != null && apellido !== '' && apellido.length > 100) {
    throw new ErrorValidacion(
      'El apellido no puede tener mas de 100 caracteres',
    );
  }
}

/** fecha_nacimiento es opcional: solo se revisa si de verdad viene algo. */
export function validarFechaNacimiento(
  fechaNacimiento: string | null | undefined,
): void {
  if (fechaNacimiento == null || fechaNacimiento === '') {
    return;
  }

  if (!REGEX_FECHA.test(fechaNacimiento)) {
    throw new ErrorValidacion(
      'La fecha de nacimiento debe tener el formato AAAA-MM-DD',
    );
  }
  if (Number.isNaN(Date.parse(fechaNacimiento))) {
    throw new ErrorValidacion('La fecha de nacimiento no es valida');
  }
  if (!esMayorDeEdad(fechaNacimiento)) {
    throw new ErrorValidacion('El usuario debe ser mayor de 18 anos');
  }
}

export function validarContrasena(contrasena: string): void {
  if (!esTextoNoVacio(contrasena)) {
    throw new ErrorValidacion('La contrasena es obligatoria');
  }
  if (contrasena.length < 8) {
    throw new ErrorValidacion('La contrasena debe tener al menos 8 caracteres');
  }
  if (!/[A-Z]/.test(contrasena)) {
    throw new ErrorValidacion(
      'La contrasena debe tener al menos una letra mayuscula',
    );
  }
  if (!/[^A-Za-z0-9]/.test(contrasena)) {
    throw new ErrorValidacion(
      'La contrasena debe tener al menos un caracter especial',
    );
  }
}

/**
 * Le suma 18 anos a la fecha de nacimiento y compara contra hoy. Usar
 * setUTCFullYear en vez de restar anos a mano evita errores con anos
 * bisiestos: si nacio el 29 de febrero, Date ajusta sola la fecha limite.
 */
function esMayorDeEdad(fechaNacimiento: string): boolean {
  const nacimiento = new Date(`${fechaNacimiento}T00:00:00Z`);
  const limite = new Date(nacimiento);
  limite.setUTCFullYear(limite.getUTCFullYear() + 18);
  return new Date() >= limite;
}
