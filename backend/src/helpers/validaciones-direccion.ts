import { ErrorValidacion } from './errores';
import { esTextoNoVacio } from './validaciones-perfil';

/**
 * Reglas de pais, departamento, ciudad y codigo_postal: van aqui, sueltas
 * de DireccionUsuarioService, porque las usa mas de un lugar (POST
 * /direccion-usuario y PATCH /direccion-usuario/:id) y tienen que dar
 * exactamente los mismos mensajes en los dos.
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
