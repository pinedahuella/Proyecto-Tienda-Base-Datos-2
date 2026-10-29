import { HttpException, HttpStatus } from '@nestjs/common';
import {
  ErrorConexion,
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorPago,
  ErrorPermiso,
  ErrorSesion,
  ErrorValidacion,
} from './errores';
import { fallo } from './respuesta';

/**
 * Traduce un error de dominio (los de errores.ts) al HttpException con el
 * codigo que le corresponde. La usan tanto los controllers como los
 * guards: cualquiera que reciba un error de un servicio necesita este
 * mismo mapeo, y solo debe existir en un lugar.
 */
export function manejarErrorHttp(
  error: unknown,
  mensajePorDefecto: string,
): never {
  if (error instanceof ErrorValidacion) {
    throw new HttpException(fallo(error.message), HttpStatus.BAD_REQUEST);
  }
  if (error instanceof ErrorConflicto) {
    throw new HttpException(fallo(error.message), HttpStatus.CONFLICT);
  }
  if (error instanceof ErrorSesion) {
    throw new HttpException(fallo(error.message), HttpStatus.UNAUTHORIZED);
  }
  if (error instanceof ErrorNoEncontrado) {
    throw new HttpException(fallo(error.message), HttpStatus.NOT_FOUND);
  }
  if (error instanceof ErrorPermiso) {
    throw new HttpException(fallo(error.message), HttpStatus.FORBIDDEN);
  }
  if (error instanceof ErrorPago) {
    throw new HttpException(fallo(error.message), HttpStatus.PAYMENT_REQUIRED);
  }
  if (error instanceof ErrorConexion) {
    throw new HttpException(
      fallo(error.message),
      HttpStatus.SERVICE_UNAVAILABLE,
    );
  }

  throw new HttpException(
    fallo(mensajePorDefecto),
    HttpStatus.INTERNAL_SERVER_ERROR,
  );
}
