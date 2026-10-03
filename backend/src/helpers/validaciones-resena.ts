import { ErrorValidacion } from './errores';
import { esTextoNoVacio } from './validaciones-perfil';

/**
 * Reglas de las rutas de resenas: `POST /resenas`,
 * `POST /resenas/:id/respuestas` y `PUT /comentarios/:id/voto`. El
 * `id_producto` se valida con `validarIdProducto` de
 * validaciones-inventario.ts (mismo mensaje que en las rutas de ofertas y
 * productos, por la regla de validaciones consistentes).
 */

const LONGITUD_MAXIMA_COMENTARIO = 250;

/** El correo del vendedor al que se califica: obligatorio, no vacio. Se recorta. */
export function validarCorreoVendedor(valor: unknown): string {
  if (!esTextoNoVacio(valor)) {
    throw new ErrorValidacion('El correo del vendedor es obligatorio');
  }
  return valor.trim();
}

/** La calificacion: entero de 1 a 5. Mismo rango que el CHECK de `resena`. */
export function validarCalificacion(valor: unknown): number {
  if (
    typeof valor !== 'number' ||
    !Number.isInteger(valor) ||
    valor < 1 ||
    valor > 5
  ) {
    throw new ErrorValidacion(
      'La calificacion debe ser un numero entero de 1 a 5',
    );
  }
  return valor;
}

/**
 * El texto de la resena: obligatorio, no vacio, hasta 250 caracteres. Se
 * guarda recortado; `comentario.comentario` ademas tiene un CHECK de
 * no-vacio en la base, esto da el 400 amable antes de llegar ahi.
 */
export function validarComentarioResena(valor: unknown): string {
  if (!esTextoNoVacio(valor)) {
    throw new ErrorValidacion(
      'El comentario es obligatorio y no puede estar vacio',
    );
  }
  const recortado = valor.trim();
  if (recortado.length > LONGITUD_MAXIMA_COMENTARIO) {
    throw new ErrorValidacion(
      `El comentario no puede tener mas de ${LONGITUD_MAXIMA_COMENTARIO} caracteres`,
    );
  }
  return recortado;
}

/**
 * El valor de un voto: exactamente `1` (a favor) o `-1` (en contra). La
 * columna `likes.valor` NO tiene CHECK (decision del equipo en la migracion
 * 011); esta funcion es la que amarra el rango, y ademas el trigger
 * `trg_likes_recontar` solo cuenta `= 1` y `= -1`, asi que un valor fuera
 * de rango no sumaria en ningun lado.
 */
export function validarValorVoto(valor: unknown): number {
  if (valor !== 1 && valor !== -1) {
    throw new ErrorValidacion(
      'El valor del voto debe ser 1 (a favor) o -1 (en contra)',
    );
  }
  return valor;
}
