import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { FuenteHallazgo, Hallazgo } from '../../models/fraude/hallazgo';

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
 * `fuerza_bruta_ip` tampoco entra -- no tiene cuentas (ver
 * `registrarAlertaFraude`), nadie a quien agrupar.
 */
const TIPOS_LOGIN_INCLUIDOS = [
  'multi_cuenta_ip',
  'multi_cuenta_ip_lenta',
  'ip_rotacion_cuenta',
  'ip_rotacion_cuenta_lenta',
];

/**
 * De que familia de `senal_fraude` viene cada fuente del agrupador. Los
 * anillos (A) y los patrones de resenas (B) son las dos familias de Neo4j y
 * entran TODOS los tipos.
 */
const FUENTE_POR_FAMILIA: Record<string, FuenteHallazgo> = {
  anillo_resenas: 'grafo',
  patron_resenas: 'grafo',
  compras_navegacion: 'eventos',
  login: 'login',
};

interface FilaSenal {
  id: string;
  tipo: string;
  familia: string;
  detalle: Record<string, unknown>;
  ultima_deteccion: Date;
  cuentas: string[];
}

/**
 * El adaptador del agrupador de casos de fraude
 * (`elementos Generales/plan pendiente/agrupador-fraude.md`): lee
 * `senal_fraude` (el modelo unico, ver `refactor-fraude-senales.md`) y
 * devuelve `Hallazgo[]`, la forma comun que el agrupador junta despues. No
 * decide nada de agrupacion, puntaje ni persistencia -- solo traduce.
 *
 * Reemplaza a los tres adaptadores de antes (`anillo_fraude`,
 * `hallazgo_evento_fraude` y `alerta_fraude`, etapa 7 del refactor).
 * Cambios de significado que conviene conocer:
 *  - `idOrigen` es el id de la SENAL, no el de una fila de ventana.
 *  - `ultimaEvidencia` sale de `ultima_deteccion`, que solo mueve el detector:
 *    revisar una senal vieja ya no la "rejuvenece" en el puntaje (item C4).
 *  - Las cuentas salen de `senal_fraude_cuenta` (cualquier rol).
 */
@Injectable()
export class HallazgoFraudeAdaptadorService {
  private readonly logger = new Logger(HallazgoFraudeAdaptadorService.name);

  /** Todas las senales vigentes que puede usar un caso. Deja fuera las
   * `descartada` (item C5, `docs/BACKEND-PENDIENTE.md`): una senal que el
   * admin ya marco como falso positivo no debe seguir sumando puntos ni
   * sirviendo de puente entre cuentas en una corrida futura. */
  async obtener(): Promise<Hallazgo[]> {
    try {
      const resultado = await pool.query<FilaSenal>(
        `SELECT s.id_senal_fraude AS id,
                t.tipo_senal_fraude_nombre AS tipo,
                f.familia_senal_fraude_nombre AS familia,
                s.detalle, s.ultima_deteccion,
                array_agg(c.id_usuario) AS cuentas
           FROM senal_fraude s
           JOIN tipo_senal_fraude t
             ON t.id_tipo_senal_fraude = s.id_tipo_senal_fraude
           JOIN familia_senal_fraude f
             ON f.id_familia_senal_fraude = t.id_familia_senal_fraude
           JOIN senal_fraude_cuenta c
             ON c.id_senal_fraude = s.id_senal_fraude
          WHERE s.id_estado_alerta_fraude <> (
                  SELECT id_estado_alerta_fraude FROM estado_alerta_fraude
                   WHERE estado_alerta_fraude_nombre = 'descartada'
                )
            AND (f.familia_senal_fraude_nombre IN ('anillo_resenas', 'patron_resenas')
                 OR t.tipo_senal_fraude_nombre = ANY($1))
          GROUP BY s.id_senal_fraude, t.tipo_senal_fraude_nombre,
                   f.familia_senal_fraude_nombre, s.detalle, s.ultima_deteccion`,
        [[...TIPOS_EVENTO_INCLUIDOS, ...TIPOS_LOGIN_INCLUIDOS]],
      );
      return resultado.rows.map((fila) => {
        const cuentas = [...new Set(fila.cuentas.map(Number))];
        return {
          fuente: FUENTE_POR_FAMILIA[fila.familia],
          idOrigen: Number(fila.id),
          tipo: fila.tipo,
          cuentas,
          clave: construirClave(cuentas),
          metricas: fila.detalle,
          ultimaEvidencia: fila.ultima_deteccion,
        };
      });
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
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
