import { ErrorValidacion } from './errores';
import {
  EstadoCasoFraude,
  ESTADOS_CASO_FRAUDE_DESTINO,
  ESTADOS_CASO_FRAUDE_VALIDOS,
  NivelCasoFraude,
  NIVELES_CASO_FRAUDE_VALIDOS,
} from '../models/fraude/caso-fraude';

const REGEX_ID = /^\d+$/;

export function validarIdCasoFraude(valor: string): number {
  if (!REGEX_ID.test(valor)) {
    throw new ErrorValidacion('El id no es valido');
  }
  return Number(valor);
}

/** Opcional -- si no viene, no filtra por nivel. */
export function validarFiltroNivelCaso(
  valor: string | undefined,
): NivelCasoFraude | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!NIVELES_CASO_FRAUDE_VALIDOS.includes(valor as NivelCasoFraude)) {
    throw new ErrorValidacion(
      `El nivel debe ser uno de: ${NIVELES_CASO_FRAUDE_VALIDOS.join(', ')}`,
    );
  }
  return valor as NivelCasoFraude;
}

/** Opcional -- si no viene, no filtra por estado. */
export function validarFiltroEstadoCaso(
  valor: string | undefined,
): EstadoCasoFraude | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!ESTADOS_CASO_FRAUDE_VALIDOS.includes(valor as EstadoCasoFraude)) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_CASO_FRAUDE_VALIDOS.join(', ')}`,
    );
  }
  return valor as EstadoCasoFraude;
}

/** `PATCH /admin/fraude/casos/:id` -- solo se puede pedir moverlo a
 * revisada/descartada/confirmada, nunca de vuelta a pendiente. */
export function validarNuevoEstadoCaso(valor: unknown): EstadoCasoFraude {
  if (
    typeof valor !== 'string' ||
    !ESTADOS_CASO_FRAUDE_DESTINO.includes(valor as EstadoCasoFraude)
  ) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_CASO_FRAUDE_DESTINO.join(', ')}`,
    );
  }
  return valor as EstadoCasoFraude;
}

/** Obligatorio para descartar (seccion 5: "descartar pide un motivo"),
 * opcional para los otros dos destinos. */
export function validarMotivoCaso(
  valor: unknown,
  estadoDestino: EstadoCasoFraude,
): string | null {
  const texto = typeof valor === 'string' ? valor.trim() : '';
  if (estadoDestino === 'descartada' && texto === '') {
    throw new ErrorValidacion('Descartar un caso exige un motivo');
  }
  return texto === '' ? null : texto;
}
