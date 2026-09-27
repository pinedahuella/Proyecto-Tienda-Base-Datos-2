import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { Hallazgo } from '../../models/fraude/hallazgo';

/**
 * F1 (vistas infladas) y F4 (carrito acaparador) no entran en los casos de
 * fraude de resenas (seccion 6 de `docs/fraude-entrega3/02-reglas-backend.md`):
 * F1 va al panel de tendencias como aviso, F4 a una cola de operaciones de
 * venta relampago. Los otros cuatro (F2, F3, F5, F6) si.
 */
const TIPOS_EVENTO_INCLUIDOS = [
  'compras_en_rafaga',
  'ip_multicuenta_compras',
  'devoluciones_seriales',
  'granja_de_registros',
];

/**
 * `multi_cuenta_ip`/`ip_rotacion_cuenta` (y sus `_lenta`) describen a quien
 * ACTUA -- muchas cuentas desde una IP. `fuerza_bruta_cuenta`, `toma_cuenta`
 * y `viaje_imposible` describen a la cuenta ATACADA (la victima): sumarlas
 * al puntaje de fraude de esa cuenta la castigaria por ser atacada, asi que
 * van a una cola de seguridad de cuentas aparte, nunca a un caso.
 * `fuerza_bruta_ip` tampoco entra -- no tiene cuentas destino resueltas en
 * `notificacion_fraude` (ver `registrarAlertaFraude`), nadie a quien
 * agrupar.
 */
const TIPOS_LOGIN_INCLUIDOS = [
  'multi_cuenta_ip',
  'multi_cuenta_ip_lenta',
  'ip_rotacion_cuenta',
  'ip_rotacion_cuenta_lenta',
];

interface FilaGrafo {
  id_anillo_fraude: string;
  tipo_anillo_fraude_nombre: string;
  clave: string;
  detalle: Record<string, unknown>;
  fecha_actualizacion: Date;
}

interface FilaConCuentas {
  id: string;
  tipo: string;
  detalle: Record<string, unknown>;
  fecha_actualizacion: Date;
  cuentas: string[];
}

/**
 * Los tres adaptadores del paso 1 del agrupador de casos de fraude
 * (`elementos Generales/plan pendiente/agrupador-fraude.md`): leen las tres
 * fuentes que hoy no se hablan (`anillo_fraude`, `hallazgo_evento_fraude`,
 * `alerta_fraude`) y devuelven `Hallazgo[]`, la forma comun que el
 * agrupador junta despues. Ninguno decide nada de agrupacion, puntaje ni
 * persistencia -- solo traducen.
 */
@Injectable()
export class HallazgoFraudeAdaptadorService {
  private readonly logger = new Logger(HallazgoFraudeAdaptadorService.name);

  /** A.1/A.2 (mutuo, ciclo, reiterado) y B.1-B.3/B.5-B.7 -- todo lo que ya
   * persiste `anillo_fraude`, sin distinguir tipo aca: el agrupador decide
   * que hacer con cada uno via el catalogo de puntos (seccion 3). */
  async obtenerDeGrafo(): Promise<Hallazgo[]> {
    try {
      const resultado = await pool.query<FilaGrafo>(
        `SELECT a.id_anillo_fraude, t.tipo_anillo_fraude_nombre,
                a.clave, a.detalle, a.fecha_actualizacion
           FROM anillo_fraude a
           JOIN tipo_anillo_fraude t
             ON t.id_tipo_anillo_fraude = a.id_tipo_anillo_fraude`,
      );
      return resultado.rows.map((fila) => {
        const cuentas = fila.clave
          .split('-')
          .map(Number)
          .filter((numero) => Number.isInteger(numero));
        return {
          fuente: 'grafo' as const,
          idOrigen: Number(fila.id_anillo_fraude),
          tipo: fila.tipo_anillo_fraude_nombre,
          cuentas,
          clave: construirClave(cuentas),
          metricas: fila.detalle,
          ultimaEvidencia: fila.fecha_actualizacion,
        };
      });
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** F2, F3, F5, F6 -- ver `TIPOS_EVENTO_INCLUIDOS`. */
  async obtenerDeEventos(): Promise<Hallazgo[]> {
    try {
      const resultado = await pool.query<FilaConCuentas>(
        `SELECT h.id_hallazgo_evento_fraude AS id,
                t.tipo_hallazgo_evento_nombre AS tipo,
                h.detalle, h.fecha_actualizacion,
                array_agg(c.id_usuario) AS cuentas
           FROM hallazgo_evento_fraude h
           JOIN tipo_hallazgo_evento t
             ON t.id_tipo_hallazgo_evento = h.id_tipo_hallazgo_evento
           JOIN hallazgo_evento_fraude_cuenta c
             ON c.id_hallazgo_evento_fraude = h.id_hallazgo_evento_fraude
          WHERE t.tipo_hallazgo_evento_nombre = ANY($1)
          GROUP BY h.id_hallazgo_evento_fraude, t.tipo_hallazgo_evento_nombre,
                   h.detalle, h.fecha_actualizacion`,
        [TIPOS_EVENTO_INCLUIDOS],
      );
      return resultado.rows.map((fila) => this.aHallazgo('eventos', fila));
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** `multi_cuenta_ip`/`ip_rotacion_cuenta` (y sus `_lenta`) -- ver
   * `TIPOS_LOGIN_INCLUIDOS`. Las cuentas ya vienen resueltas en
   * `notificacion_fraude` (`registrarAlertaFraude` las resuelve una sola
   * vez al nacer la alerta, incluso cuando `alerta_fraude.detalle` solo
   * trae identificadores de texto, correo o usuario). */
  async obtenerDeLogin(): Promise<Hallazgo[]> {
    try {
      const resultado = await pool.query<FilaConCuentas>(
        `SELECT a.id_alerta_fraude AS id,
                t.tipo_alerta_fraude_nombre AS tipo,
                a.detalle, a.fecha_actualizacion,
                array_agg(n.id_usuario) AS cuentas
           FROM alerta_fraude a
           JOIN tipo_alerta_fraude t
             ON t.id_tipo_alerta_fraude = a.id_tipo_alerta_fraude
           JOIN notificacion_fraude n
             ON n.id_alerta_fraude = a.id_alerta_fraude
          WHERE t.tipo_alerta_fraude_nombre = ANY($1)
          GROUP BY a.id_alerta_fraude, t.tipo_alerta_fraude_nombre,
                   a.detalle, a.fecha_actualizacion`,
        [TIPOS_LOGIN_INCLUIDOS],
      );
      return resultado.rows.map((fila) => this.aHallazgo('login', fila));
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private aHallazgo(
    fuente: 'eventos' | 'login',
    fila: FilaConCuentas,
  ): Hallazgo {
    const cuentas = [...new Set(fila.cuentas.map(Number))];
    return {
      fuente,
      idOrigen: Number(fila.id),
      tipo: fila.tipo,
      cuentas,
      clave: construirClave(cuentas),
      metricas: fila.detalle,
      ultimaEvidencia: fila.fecha_actualizacion,
    };
  }
}

/** Sin duplicados, orden NUMERICO (no lexicografico: "9" tiene que ir
 * antes que "14"), unidos con guion -- mismo criterio que
 * `anillo_fraude.clave`. Exportada: `CasosFraudeService` la reusa para
 * recalcular la firma de un caso al descartarlo, tiene que dar el MISMO
 * resultado que aca. */
export function construirClave(cuentas: number[]): string {
  return [...new Set(cuentas)].sort((a, b) => a - b).join('-');
}
