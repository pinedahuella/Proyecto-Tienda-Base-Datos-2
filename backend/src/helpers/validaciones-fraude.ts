import { ErrorValidacion } from './errores';
import { ESTADOS_ALERTA_FRAUDE_VALIDOS } from '../dto/paginar-alertas-fraude';
import { EstadoAlertaFraude } from '../models/alerta-fraude';

/**
 * El filtro `estado` de GET /admin/fraude/alertas-login: opcional, uno de
 * `pendiente`/`revisada`/`descartada`. Ausente (o vacio) devuelve `null` --
 * sin filtrar, todas -- mismo criterio que `validarFiltroActivo` de
 * `validaciones-oferta.ts`.
 */
export function validarFiltroEstadoAlerta(
  valor: string | undefined,
): EstadoAlertaFraude | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!ESTADOS_ALERTA_FRAUDE_VALIDOS.includes(valor as EstadoAlertaFraude)) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_ALERTA_FRAUDE_VALIDOS.join(', ')}`,
    );
  }
  return valor as EstadoAlertaFraude;
}
