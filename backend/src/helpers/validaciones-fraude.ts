import { ErrorValidacion } from './errores';
import {
  ESTADOS_ALERTA_FRAUDE_VALIDOS,
  TIPOS_ALERTA_FRAUDE_VALIDOS,
} from '../dto/paginar-alertas-fraude';
import {
  MOTIVOS_FALLO_AUTENTICACION_VALIDOS,
  RESULTADOS_AUTENTICACION_VALIDOS,
  TIPOS_EVENTO_AUTENTICACION_VALIDOS,
} from '../dto/paginar-eventos-autenticacion';
import { EstadoAlertaFraude, TipoAlertaFraude } from '../models/alerta-fraude';
import {
  MotivoFalloAutenticacion,
  ResultadoAutenticacion,
  TipoEventoAutenticacion,
} from '../models/evento-autenticacion';

const REGEX_ID_ENTERO = /^\d+$/;

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

/**
 * El filtro `tipo` de GET /admin/fraude/alertas-login: opcional, uno de los
 * siete tipos de `TIPOS_ALERTA_FRAUDE_VALIDOS`. Ausente (o vacio) devuelve
 * `null` -- sin filtrar, todos -- mismo criterio que
 * `validarFiltroEstadoAlerta` de arriba.
 */
export function validarFiltroTipoAlerta(
  valor: string | undefined,
): TipoAlertaFraude | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!TIPOS_ALERTA_FRAUDE_VALIDOS.includes(valor as TipoAlertaFraude)) {
    throw new ErrorValidacion(
      `El tipo debe ser uno de: ${TIPOS_ALERTA_FRAUDE_VALIDOS.join(', ')}`,
    );
  }
  return valor as TipoAlertaFraude;
}

/**
 * El `estado` que manda el cuerpo de `PATCH /admin/fraude/alertas-login/:id`:
 * a diferencia de `validarFiltroEstadoAlerta` (un filtro opcional de
 * lectura), este es obligatorio y solo admite los dos destinos posibles --
 * `pendiente` nunca es un destino valido, solo el estado de nacimiento de una
 * alerta (lo pone `registrarAlertaFraude`).
 */
const ESTADOS_DESTINO_ALERTA_FRAUDE_VALIDOS: EstadoAlertaFraude[] = [
  'revisada',
  'descartada',
];

export function validarNuevoEstadoAlerta(
  valor: string | undefined,
): EstadoAlertaFraude {
  if (
    valor == null ||
    !ESTADOS_DESTINO_ALERTA_FRAUDE_VALIDOS.includes(valor as EstadoAlertaFraude)
  ) {
    throw new ErrorValidacion(
      `El estado debe ser uno de: ${ESTADOS_DESTINO_ALERTA_FRAUDE_VALIDOS.join(', ')}`,
    );
  }
  return valor as EstadoAlertaFraude;
}

/** El id de `alerta_fraude` en la ruta de `PATCH /admin/fraude/alertas-login/:id`. */
export function validarIdAlertaFraude(valor: string): string {
  if (!REGEX_ID_ENTERO.test(valor)) {
    throw new ErrorValidacion('El id de la alerta debe ser un numero entero');
  }
  return valor;
}

// -------------------------------------------------------------------------
// Filtros de GET /admin/fraude/eventos-login (explorador de logs crudos en
// Elasticsearch). Cada uno es exacto (nunca fuzzy) y opcional: ausente (o
// vacio) devuelve `null`, sin filtrar -- mismo criterio que los de arriba.
// -------------------------------------------------------------------------

export function validarFiltroTipoEvento(
  valor: string | undefined,
): TipoEventoAutenticacion | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (
    !TIPOS_EVENTO_AUTENTICACION_VALIDOS.includes(
      valor as TipoEventoAutenticacion,
    )
  ) {
    throw new ErrorValidacion(
      `El tipo debe ser uno de: ${TIPOS_EVENTO_AUTENTICACION_VALIDOS.join(', ')}`,
    );
  }
  return valor as TipoEventoAutenticacion;
}

export function validarFiltroResultadoEvento(
  valor: string | undefined,
): ResultadoAutenticacion | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (
    !RESULTADOS_AUTENTICACION_VALIDOS.includes(valor as ResultadoAutenticacion)
  ) {
    throw new ErrorValidacion(
      `El resultado debe ser uno de: ${RESULTADOS_AUTENTICACION_VALIDOS.join(', ')}`,
    );
  }
  return valor as ResultadoAutenticacion;
}

export function validarFiltroMotivoEvento(
  valor: string | undefined,
): MotivoFalloAutenticacion | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (
    !MOTIVOS_FALLO_AUTENTICACION_VALIDOS.includes(
      valor as MotivoFalloAutenticacion,
    )
  ) {
    throw new ErrorValidacion(
      `El motivo debe ser uno de: ${MOTIVOS_FALLO_AUTENTICACION_VALIDOS.join(', ')}`,
    );
  }
  return valor as MotivoFalloAutenticacion;
}

/** Para id_usuario del explorador: mismo formato que valida `pool` (bigint), pero se usa como string en el filtro de Elasticsearch. */
export function validarFiltroIdUsuarioEvento(
  valor: string | undefined,
): string | null {
  if (valor == null || valor === '') {
    return null;
  }
  if (!REGEX_ID_ENTERO.test(valor)) {
    throw new ErrorValidacion('El id de usuario debe ser un numero entero');
  }
  return valor;
}

/** Filtro de texto exacto generico (ip, identificador, huella_cliente, geo_pais): recorta espacios, vacio cuenta como ausente. */
export function validarFiltroTextoEvento(
  valor: string | undefined,
): string | null {
  if (valor == null || valor.trim() === '') {
    return null;
  }
  return valor.trim();
}

/**
 * `fecha_desde`/`fecha_hasta` del explorador: opcionales, formato ISO 8601.
 * Se validan juntas para poder exigir que el rango no venga invertido.
 */
export function validarRangoFechasEvento(
  fechaDesde: string | undefined,
  fechaHasta: string | undefined,
): { desde: Date | null; hasta: Date | null } {
  const desde = validarFechaEvento(fechaDesde, 'fecha_desde');
  const hasta = validarFechaEvento(fechaHasta, 'fecha_hasta');

  if (desde != null && hasta != null && desde > hasta) {
    throw new ErrorValidacion('fecha_desde no puede ser posterior a fecha_hasta');
  }

  return { desde, hasta };
}

function validarFechaEvento(
  valor: string | undefined,
  nombreCampo: string,
): Date | null {
  if (valor == null || valor === '') {
    return null;
  }
  const fecha = new Date(valor);
  if (Number.isNaN(fecha.getTime())) {
    throw new ErrorValidacion(`${nombreCampo} debe ser una fecha valida (ISO 8601)`);
  }
  return fecha;
}

/**
 * `incluir_usuario` del explorador: `true`/`false`, no nulo -- a diferencia
 * de `validarFiltroActivo` (que devuelve `null` sin filtrar), aca ausente
 * significa `false` (no hacer el lookup extra contra Postgres), no "sin
 * decidir". Mismas dos versiones convivan a proposito (ver
 * `FraudeLoginExploracionService.listarEventosPaginado`): con esta bandera
 * se puede medir el costo real del enriquecimiento contra la version base.
 */
export function validarIncluirUsuarioEvento(valor: string | undefined): boolean {
  if (valor == null || valor === '') {
    return false;
  }
  if (valor !== 'true' && valor !== 'false') {
    throw new ErrorValidacion('incluir_usuario debe ser "true" o "false"');
  }
  return valor === 'true';
}
