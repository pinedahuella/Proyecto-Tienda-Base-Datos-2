import { PeriodoDashboard } from '../../dto/dashboards/dashboard-general';
import { ErrorValidacion } from '../../helpers/errores';

/**
 * La zona de la tienda. Los dias, las semanas y las horas del dashboard se
 * cuentan en hora de Guatemala: un pedido de las 11 de la noche es de ese
 * dia, no del siguiente como diria UTC.
 */
export const ZONA_TIENDA = 'America/Guatemala';

/** Lo mas largo que se deja pedir: con mas, el mapa de calor y la serie dejan de decir algo. */
const MAXIMO_DIAS = 3 * 366;

const FECHA = /^\d{4}-\d{2}-\d{2}$/;

/** Hoy en Guatemala, AAAA-MM-DD. */
function hoyEnLaTienda(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: ZONA_TIENDA }).format(
    new Date(),
  );
}

function aFecha(texto: string, nombre: string): Date {
  if (!FECHA.test(texto)) {
    throw new ErrorValidacion(`${nombre} tiene que ser una fecha AAAA-MM-DD`);
  }
  const fecha = new Date(`${texto}T00:00:00Z`);
  if (
    Number.isNaN(fecha.getTime()) ||
    fecha.toISOString().slice(0, 10) !== texto
  ) {
    throw new ErrorValidacion(`${nombre} no es una fecha que exista`);
  }
  return fecha;
}

const DIA_MS = 86_400_000;
const comoTexto = (fecha: Date) => fecha.toISOString().slice(0, 10);

/**
 * El periodo de `?desde=&hasta=`, con los dos extremos incluidos. Sin
 * `desde`, el primero de enero del anio de `hasta`; sin `hasta`, hoy. El
 * anterior es el del mismo largo justo antes, para comparar.
 */
export function leerPeriodo(desde?: string, hasta?: string): PeriodoDashboard {
  const hastaTexto = hasta?.trim() || hoyEnLaTienda();
  const fin = aFecha(hastaTexto, 'hasta');
  const desdeTexto = desde?.trim() || `${hastaTexto.slice(0, 4)}-01-01`;
  const inicio = aFecha(desdeTexto, 'desde');
  if (inicio > fin) {
    throw new ErrorValidacion('desde no puede ser despues de hasta');
  }
  const dias = Math.round((fin.getTime() - inicio.getTime()) / DIA_MS) + 1;
  if (dias > MAXIMO_DIAS) {
    throw new ErrorValidacion('El periodo puede ser de hasta tres anios');
  }
  const anteriorHasta = new Date(inicio.getTime() - DIA_MS);
  const anteriorDesde = new Date(anteriorHasta.getTime() - (dias - 1) * DIA_MS);
  return {
    desde: desdeTexto,
    hasta: hastaTexto,
    dias,
    anterior_desde: comoTexto(anteriorDesde),
    anterior_hasta: comoTexto(anteriorHasta),
    agrupado: dias <= 62 ? 'dia' : dias <= 400 ? 'semana' : 'mes',
  };
}
