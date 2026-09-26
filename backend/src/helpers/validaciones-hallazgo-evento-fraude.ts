import { ErrorValidacion } from './errores';
import { TIPOS_HALLAZGO_EVENTO_VALIDOS } from '../dto/paginar-hallazgos-evento-fraude';
import { TipoHallazgoEvento } from '../models/hallazgo-evento-fraude';

const REGEX_ID_ENTERO = /^\d+$/;

/**
 * El filtro `tipo` de GET /admin/fraude/alertas-eventos: opcional, uno de
 * los seis de F1-F6. Ausente (o vacio) devuelve `null` -- sin filtrar,
 * todos -- mismo criterio que `validarFiltroTipoAnillo`
 * (`helpers/validaciones-anillo-fraude.ts`).
 *
 * El filtro de `estado` y el `estado` destino del `PATCH` NO se duplican
 * aqui: `validarFiltroEstadoAlerta`/`validarNuevoEstadoAlerta`
 * (`helpers/validaciones-fraude.ts`) ya son genericos sobre
 * `estado_alerta_fraude` y sirven tal cual.
 */
export function validarFiltroTipoHallazgoEvento(
  valor: string | undefined,
): TipoHallazgoEvento | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!TIPOS_HALLAZGO_EVENTO_VALIDOS.includes(valor as TipoHallazgoEvento)) {
    throw new ErrorValidacion(
      `El tipo debe ser uno de: ${TIPOS_HALLAZGO_EVENTO_VALIDOS.join(', ')}`,
    );
  }
  return valor as TipoHallazgoEvento;
}

/** El id de `hallazgo_evento_fraude` en la ruta de las dos rutas que reciben `:id`. */
export function validarIdHallazgoEventoFraude(valor: string): string {
  if (!REGEX_ID_ENTERO.test(valor)) {
    throw new ErrorValidacion('El id del hallazgo debe ser un numero entero');
  }
  return valor;
}
