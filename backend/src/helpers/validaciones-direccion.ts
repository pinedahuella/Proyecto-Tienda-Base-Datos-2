import { ErrorValidacion } from './errores';
import { esTextoNoVacio } from './validaciones-perfil';

const REGEX_FECHA = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * Reglas de pais, departamento, ciudad, direccion_exacta y codigo_postal:
 * van aqui, sueltas de DireccionUsuarioService, porque las usa mas de un
 * lugar (POST /direccion-usuario y PATCH /direccion-usuario/:id) y tienen
 * que dar exactamente los mismos mensajes en los dos.
 */

export function validarPais(pais: string): void {
  if (!esTextoNoVacio(pais)) {
    throw new ErrorValidacion('El pais es obligatorio');
  }
  if (pais.length > 100) {
    throw new ErrorValidacion('El pais no puede tener mas de 100 caracteres');
  }
}

export function validarDepartamento(departamento: string): void {
  if (!esTextoNoVacio(departamento)) {
    throw new ErrorValidacion('El departamento es obligatorio');
  }
  if (departamento.length > 100) {
    throw new ErrorValidacion(
      'El departamento no puede tener mas de 100 caracteres',
    );
  }
}

export function validarCiudad(ciudad: string): void {
  if (!esTextoNoVacio(ciudad)) {
    throw new ErrorValidacion('La ciudad es obligatoria');
  }
  if (ciudad.length > 100) {
    throw new ErrorValidacion('La ciudad no puede tener mas de 100 caracteres');
  }
}

/**
 * direccion_exacta: la calle, numero, zona y referencias en una sola linea.
 * Obligatoria al crear una direccion -- sin ella no se puede entregar un
 * pedido -- y del largo de la columna, varchar(255). Al editar es opcional
 * como el resto (si no viene, no se toca), pero si viene tiene que cumplir
 * lo mismo.
 */
export function validarDireccionExacta(direccionExacta: string): void {
  if (!esTextoNoVacio(direccionExacta)) {
    throw new ErrorValidacion('La direccion exacta es obligatoria');
  }
  if (direccionExacta.length > 255) {
    throw new ErrorValidacion(
      'La direccion exacta no puede tener mas de 255 caracteres',
    );
  }
}

/** codigo_postal es opcional: solo se revisa la longitud si de verdad viene algo. */
export function validarCodigoPostal(
  codigoPostal: string | null | undefined,
): void {
  if (codigoPostal != null && codigoPostal !== '' && codigoPostal.length > 20) {
    throw new ErrorValidacion(
      'El codigo postal no puede tener mas de 20 caracteres',
    );
  }
}

/**
 * fecha es obligatoria en GET /direccion-usuario/historial: sin ella no hay
 * a que momento reconstruir.
 */
export function validarFechaHistorial(fecha: string | undefined): void {
  if (!esTextoNoVacio(fecha)) {
    throw new ErrorValidacion('La fecha es obligatoria');
  }
  const coincidencia = REGEX_FECHA.exec(fecha);
  if (!coincidencia) {
    throw new ErrorValidacion('La fecha debe tener el formato AAAA-MM-DD');
  }
  // Date.parse() no sirve para esto: normaliza los desbordes en vez de
  // rechazarlos ("2024-02-30" se convierte en 1 de marzo sin dar NaN), asi
  // que un 400 "La fecha no es valida" nunca salia para una fecha de
  // calendario inexistente. Se arma la fecha a mano y se compara contra los
  // numeros que mando el cliente: si no coinciden, el dia no existe.
  const [, anioTexto, mesTexto, diaTexto] = coincidencia;
  const anio = Number(anioTexto);
  const mes = Number(mesTexto);
  const dia = Number(diaTexto);
  const fechaUtc = new Date(Date.UTC(anio, mes - 1, dia));
  const esFechaReal =
    fechaUtc.getUTCFullYear() === anio &&
    fechaUtc.getUTCMonth() === mes - 1 &&
    fechaUtc.getUTCDate() === dia;
  if (!esFechaReal) {
    throw new ErrorValidacion('La fecha no es valida');
  }
}
