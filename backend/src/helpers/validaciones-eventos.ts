import { ErrorValidacion } from './errores';
import { ORIGENES_VISTA_VALIDOS, OrigenVista } from '../dto/registrar-vista';

/**
 * Reglas de `POST /eventos/vista`. `id_producto` reusa
 * `validarIdProducto` de `validaciones-inventario.ts` -- mismo campo, mismo
 * mensaje que el resto del proyecto.
 */

/**
 * La `sesion` la genera el NAVEGADOR (ver
 * `elementos Generales/plan pendiente/eventos-clickhouse.md`), el backend
 * solo la recibe tal cual: no es un id verificable, solo hace falta que no
 * venga vacia.
 */
export function validarSesionEvento(valor: unknown): string {
  if (typeof valor !== 'string' || valor.trim() === '') {
    throw new ErrorValidacion('La sesion es obligatoria');
  }
  return valor.trim();
}

export function validarOrigenEvento(valor: unknown): OrigenVista {
  if (
    typeof valor !== 'string' ||
    !ORIGENES_VISTA_VALIDOS.includes(valor as OrigenVista)
  ) {
    throw new ErrorValidacion(
      `El origen debe ser uno de: ${ORIGENES_VISTA_VALIDOS.join(', ')}`,
    );
  }
  return valor as OrigenVista;
}

/** El termino buscado, para `POST /eventos/busqueda-clic`: string no vacio. */
export function validarTerminoEvento(valor: unknown): string {
  if (typeof valor !== 'string' || valor.trim() === '') {
    throw new ErrorValidacion('El termino es obligatorio');
  }
  return valor.trim();
}

/**
 * La posicion (1-based) del resultado sobre el que se hizo clic dentro de
 * la lista que devolvio la busqueda -- entero mayor a 0, mismo criterio
 * que `validarIdProducto`/`validarIdOferta`.
 */
export function validarPosicionEvento(valor: unknown): number {
  if (typeof valor !== 'number' || !Number.isInteger(valor) || valor <= 0) {
    throw new ErrorValidacion(
      'La posicion es obligatoria y debe ser un numero entero mayor a 0',
    );
  }
  return valor;
}

// -------------------------------------------------------------------------
// GET /admin/eventos/* -- filas crudas de las tablas de ClickHouse, en una
// ventana de dias hacia atras. Mismo criterio que `validarLimite`/
// `validarPagina` de `validaciones-productos.ts`: un valor fuera de rango
// se recorta al tope en vez de rechazar la peticion.
// -------------------------------------------------------------------------

const REGEX_ENTERO_EVENTO = /^\d+$/;

const DIAS_EVENTO_DEFECTO = 7;
const DIAS_EVENTO_MAXIMO = 365; // mismo horizonte que el TTL de las tablas.

const LIMITE_EVENTO_DEFECTO = 20;
const LIMITE_EVENTO_MAXIMO = 200;

/** Cuantos dias hacia atras mirar. Opcional, por defecto 7, tope 365 (el TTL de las tablas). */
export function validarDiasEvento(valor: string | undefined): number {
  if (valor == null || valor === '') {
    return DIAS_EVENTO_DEFECTO;
  }
  if (!REGEX_ENTERO_EVENTO.test(valor) || Number(valor) < 1) {
    throw new ErrorValidacion('dias debe ser un numero entero mayor a 0');
  }
  return Math.min(Number(valor), DIAS_EVENTO_MAXIMO);
}

/** Cuantas filas como maximo. Opcional, por defecto 20, tope 200. */
export function validarLimiteEvento(valor: string | undefined): number {
  if (valor == null || valor === '') {
    return LIMITE_EVENTO_DEFECTO;
  }
  if (!REGEX_ENTERO_EVENTO.test(valor) || Number(valor) < 1) {
    throw new ErrorValidacion('El limite debe ser un numero entero mayor a 0');
  }
  return Math.min(Number(valor), LIMITE_EVENTO_MAXIMO);
}

const DIAS_BASE_DEFECTO = 21;
const DIAS_VENTANA_DEFECTO = 30;

/**
 * Cuantos dias hacia atras mirar para el periodo BASE de
 * `GET /admin/eventos/tendencias` (contra el que se compara la ventana
 * reciente). Opcional, por defecto 21 -- mismo valor probado en
 * `clickhouse/consultas/parametros.txt` -- mismo tope que `validarDiasEvento`.
 */
export function validarDiasBase(valor: string | undefined): number {
  if (valor == null || valor === '') {
    return DIAS_BASE_DEFECTO;
  }
  if (!REGEX_ENTERO_EVENTO.test(valor) || Number(valor) < 1) {
    throw new ErrorValidacion('dias_base debe ser un numero entero mayor a 0');
  }
  return Math.min(Number(valor), DIAS_EVENTO_MAXIMO);
}

/**
 * Cuantos dias hacia atras mirar -- compartido por `GET /admin/eventos/embudo`,
 * `GET /admin/eventos/busquedas-sin-respuesta` y
 * `GET /productos/vistos-recientemente` (`dias_historial`, mismo valor por
 * defecto). Opcional, por defecto 30 -- mismo valor probado en
 * `clickhouse/consultas/parametros.txt`.
 */
export function validarDiasVentana(valor: string | undefined): number {
  if (valor == null || valor === '') {
    return DIAS_VENTANA_DEFECTO;
  }
  if (!REGEX_ENTERO_EVENTO.test(valor) || Number(valor) < 1) {
    throw new ErrorValidacion(
      'dias_ventana debe ser un numero entero mayor a 0',
    );
  }
  return Math.min(Number(valor), DIAS_EVENTO_MAXIMO);
}

/**
 * La direccion del ranking de `GET /admin/eventos/*` (tendencias):
 * `positivo` (por defecto) trae primero los que MAS tuvieron esa metrica
 * (`ORDER BY total DESC` -- los primeros M); `negativo` trae primero los
 * que MENOS (`ASC` -- los ultimos M). Devuelve ya la palabra clave SQL --
 * interpolarla es segura porque solo puede valer una de estas dos, nunca
 * texto libre del cliente.
 */
export function validarDireccionEvento(
  valor: string | undefined,
): 'ASC' | 'DESC' {
  if (valor == null || valor === '' || valor === 'positivo') {
    return 'DESC';
  }
  if (valor === 'negativo') {
    return 'ASC';
  }
  throw new ErrorValidacion('direccion debe ser uno de: positivo, negativo');
}
