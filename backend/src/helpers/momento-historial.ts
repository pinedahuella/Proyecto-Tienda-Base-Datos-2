import { esTextoNoVacio } from './validaciones-perfil';
import { ErrorValidacion } from './errores';

/**
 * El punto en el tiempo hasta el que hay que reconstruir un producto (query
 * param `fecha` de `GET /productos/:id/historial` y
 * `GET /vendedor/productos/:id/historial`), ya interpretado.
 */
export interface MomentoHistorial {
  /** El límite superior del rango de eventos a considerar. */
  limite: Date;
  /**
   * `$lt` cuando se dio solo la fecha (se toma el día completo, con el
   * límite en la medianoche del día siguiente). `$lte` cuando se dio una
   * hora exacta (inclusive: reconstruir "a las 21:00" incluye lo que pasó
   * exactamente a las 21:00).
   */
  comparador: '$lt' | '$lte';
}

const REGEX_MOMENTO =
  /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?$/;

/**
 * Interpreta el query param `fecha` de las rutas de reconstrucción de
 * producto. Acepta dos formas:
 *
 *   - `AAAA-MM-DD` — todo ese día. Igual que siempre: el día se cuenta en la
 *     zona de Guatemala (-06:00) y el límite es la medianoche del día
 *     siguiente, con comparación exclusiva (`$lt`).
 *   - `AAAA-MM-DDTHH:MM` o `AAAA-MM-DDTHH:MM:SS` — hasta ese instante
 *     inclusive (`$lte`). La hora se interpreta en **UTC**, que es como se
 *     guardan y se muestran las fechas de los eventos (`...Z`): reconstruir
 *     a `2026-02-18T21:00` cuadra con el evento que la API reporta con
 *     `fecha: "2026-02-18T21:00:00.000Z"`. Un espacio en vez de la `T`
 *     también vale.
 *
 * Los segundos son opcionales; si no vienen se toma el segundo `:00` de ese
 * minuto.
 *
 * Mismos mensajes de error que `validarFechaHistorial` para el caso de solo
 * fecha (obligatoria / formato / fecha inexistente), más "La hora no es
 * valida" cuando la parte de hora trae números fuera de rango.
 */
export function interpretarMomentoHistorial(
  valor: string | undefined,
): MomentoHistorial {
  if (!esTextoNoVacio(valor)) {
    throw new ErrorValidacion('La fecha es obligatoria');
  }

  const coincidencia = REGEX_MOMENTO.exec(valor.trim());
  if (!coincidencia) {
    throw new ErrorValidacion(
      'La fecha debe tener el formato AAAA-MM-DD o AAAA-MM-DDTHH:MM (con :SS opcional)',
    );
  }

  const [, anioT, mesT, diaT, horaT, minutoT, segundoT] = coincidencia;
  const anio = Number(anioT);
  const mes = Number(mesT);
  const dia = Number(diaT);

  // Misma comprobación de calendario que validarFechaHistorial: Date se
  // arma a mano y se compara contra lo que mandó el cliente, porque
  // Date.parse() normaliza los desbordes ("2024-02-30" -> 1 de marzo) en
  // vez de rechazarlos.
  const control = new Date(Date.UTC(anio, mes - 1, dia));
  if (
    control.getUTCFullYear() !== anio ||
    control.getUTCMonth() !== mes - 1 ||
    control.getUTCDate() !== dia
  ) {
    throw new ErrorValidacion('La fecha no es valida');
  }

  if (horaT == null) {
    const limite = new Date(`${anioT}-${mesT}-${diaT}T00:00:00.000-06:00`);
    limite.setUTCDate(limite.getUTCDate() + 1);
    return { limite, comparador: '$lt' };
  }

  const hora = Number(horaT);
  const minuto = Number(minutoT);
  const segundo = segundoT != null ? Number(segundoT) : 0;
  if (hora > 23 || minuto > 59 || segundo > 59) {
    throw new ErrorValidacion('La hora no es valida');
  }

  return {
    limite: new Date(Date.UTC(anio, mes - 1, dia, hora, minuto, segundo)),
    comparador: '$lte',
  };
}
