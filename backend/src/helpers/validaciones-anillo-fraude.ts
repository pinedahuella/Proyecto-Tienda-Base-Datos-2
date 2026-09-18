import { ErrorValidacion } from './errores';
import { TIPOS_ANILLO_FRAUDE_VALIDOS } from '../dto/paginar-anillos-fraude';
import { TipoAnilloFraude } from '../models/anillo-fraude';

const REGEX_ID_ENTERO = /^\d+$/;

/**
 * El filtro `tipo` de GET /admin/fraude/alertas-resenas: opcional, uno
 * de `mutuo`/`ciclo`/`reiterado`. Ausente (o vacio) devuelve `null` -- sin
 * filtrar, todos -- mismo criterio que `validarFiltroTipoAlerta`
 * (`helpers/validaciones-fraude.ts`).
 *
 * El filtro de `estado` y el `estado` destino del `PATCH` NO se duplican
 * aqui: `validarFiltroEstadoAlerta`/`validarNuevoEstadoAlerta` de
 * `validaciones-fraude.ts` ya son genericos sobre `estado_alerta_fraude`
 * (el catalogo reusado, sin logica propia de login) y sirven tal cual.
 */
export function validarFiltroTipoAnillo(
  valor: string | undefined,
): TipoAnilloFraude | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!TIPOS_ANILLO_FRAUDE_VALIDOS.includes(valor as TipoAnilloFraude)) {
    throw new ErrorValidacion(
      `El tipo debe ser uno de: ${TIPOS_ANILLO_FRAUDE_VALIDOS.join(', ')}`,
    );
  }
  return valor as TipoAnilloFraude;
}

/** El id de `anillo_fraude` en la ruta de las dos rutas que reciben `:id`. */
export function validarIdAnilloFraude(valor: string): string {
  if (!REGEX_ID_ENTERO.test(valor)) {
    throw new ErrorValidacion('El id del anillo debe ser un numero entero');
  }
  return valor;
}
