import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { UnionFind } from '../../helpers/union-find';
import { Hallazgo } from '../../models/fraude/hallazgo';
import { GrupoFraude } from '../../models/fraude/grupo-fraude';

/** Una cuenta que escribio o recibio resenas de mas de este numero de
 * contrapartes distintas es "concentradora" -- seccion 2 del documento
 * original. */
const MIN_CONTRAPARTES_CONCENTRADORA = 10;

/**
 * ciclo, reiterado, granja (persistida como `satelites`, ver
 * `tipo_anillo_fraude`) y coordinados -- un solo hallazgo de estos ya
 * vuelve nucleo a una cuenta, sin exigir un segundo hallazgo.
 */
const TIPOS_FUERTES = new Set([
  'ciclo',
  'reiterado',
  'satelites',
  'coordinados',
  // Reseñar y cancelar la compra (se reembolsa): una sola vez ya basta.
  'resena_positiva_cancelada',
]);

/**
 * Paso 2 del agrupador de casos de fraude
 * (`elementos Generales/plan pendiente/agrupador-fraude.md`): junta los
 * `Hallazgo[]` que arman los tres adaptadores (`HallazgoFraudeAdaptadorService`)
 * en grupos -- dos hallazgos van al mismo grupo si comparten al menos una
 * cuenta, transitivamente (union-busqueda: si A comparte con B y B con C,
 * A y C terminan juntas aunque nunca compartan un hallazgo directo).
 *
 * Dos excepciones a la union directa:
 *
 * - **Cuenta concentradora**: una cuenta con mas de 10 contrapartes
 *   distintas en resenas (la tienda, tipicamente) se agrega al grupo que
 *   le corresponda, pero nunca sirve de puente para fusionar dos grupos
 *   -- si no, cualquier hallazgo que la toque uniria todos los casos en
 *   uno solo.
 * - **Los hallazgos de login nunca fusionan** (decision del usuario,
 *   2026-09-26, en vez de la lista de "IPs de confianza" del documento
 *   original): compartir una IP es un indicio, no una prueba -- dos
 *   cuentas que comparten wifi por casualidad no deberian terminar
 *   metidas en un caso de fraude de resenas solo por eso. Un hallazgo de
 *   login se agrega como evidencia extra a un grupo que YA exista por
 *   evidencia estructural (grafo/eventos); si ninguna de sus cuentas
 *   pertenece ya a un grupo, se descarta -- no forma caso por si solo.
 *
 * Nucleo/periferia se decide DESPUES de agrupar, no durante la union: una
 * cuenta es nucleo si aparece en 2 o mas hallazgos del grupo, o en uno
 * solo pero "fuerte" (`TIPOS_FUERTES`). Los de login no cuentan para eso
 * ni agregan cuentas: de un hallazgo de login solo quedan en el caso las
 * cuentas que ya estaban por otra evidencia. Una cuenta concentradora nunca es
 * nucleo -- por definicion toca demasiados hallazgos ajenos al grupo para
 * que eso signifique algo (extension propia, el documento original no lo
 * dice explicito, pero es consistente con por que se excluye como puente).
 */
@Injectable()
export class AgrupadorFraudeService {
  private readonly logger = new Logger(AgrupadorFraudeService.name);

  async agrupar(hallazgos: Hallazgo[]): Promise<GrupoFraude[]> {
    const concentradoras = await this.obtenerCuentasConcentradoras();

    const estructurales = hallazgos.filter((h) => h.fuente !== 'login');
    const login = hallazgos.filter((h) => h.fuente === 'login');

    const unionFind = new UnionFind();
    for (const hallazgo of estructurales) {
      const normales = hallazgo.cuentas.filter(
        (cuenta) => !concentradoras.has(cuenta),
      );
      for (let i = 1; i < normales.length; i++) {
        unionFind.unir(normales[0], normales[i]);
      }
      // Si TODAS las cuentas del hallazgo son concentradoras, no hay
      // ninguna normal que ancle el grupo -- cada una queda registrada,
      // el hallazgo forma su propio grupo unitario mas abajo.
      if (normales.length === 0) {
        for (const cuenta of hallazgo.cuentas) {
          unionFind.encontrar(cuenta);
        }
      }
    }

    const porRaiz = new Map<number, Hallazgo[]>();
    for (const hallazgo of estructurales) {
      const normales = hallazgo.cuentas.filter(
        (cuenta) => !concentradoras.has(cuenta),
      );
      const ancla = normales[0] ?? hallazgo.cuentas[0];
      if (ancla == null) {
        continue; // un hallazgo sin ninguna cuenta no deberia pasar nunca
      }
      const raiz = unionFind.encontrar(ancla);
      const grupo = porRaiz.get(raiz) ?? [];
      grupo.push(hallazgo);
      porRaiz.set(raiz, grupo);
    }

    for (const hallazgo of login) {
      const raicesTocadas = new Set(
        hallazgo.cuentas
          .filter((cuenta) => !concentradoras.has(cuenta))
          .map((cuenta) => unionFind.encontrar(cuenta))
          .filter((raiz) => porRaiz.has(raiz)),
      );
      for (const raiz of raicesTocadas) {
        porRaiz.get(raiz)!.push(hallazgo);
      }
    }

    return [...porRaiz.values()].map((hallazgosDelGrupo) =>
      this.aGrupo(hallazgosDelGrupo, concentradoras),
    );
  }

  private aGrupo(
    hallazgos: Hallazgo[],
    concentradoras: Set<number>,
  ): GrupoFraude {
    const porCuenta = new Map<number, { veces: number; fuerte: boolean }>();
    for (const hallazgo of hallazgos) {
      // Login es evidencia extra: no mete cuentas al caso ni hace nucleo a
      // nadie (una IP compartida no es una prueba).
      if (hallazgo.fuente === 'login') {
        continue;
      }
      const esFuerte = TIPOS_FUERTES.has(hallazgo.tipo);
      for (const cuenta of hallazgo.cuentas) {
        const previo = porCuenta.get(cuenta) ?? { veces: 0, fuerte: false };
        porCuenta.set(cuenta, {
          veces: previo.veces + 1,
          fuerte: previo.fuerte || esFuerte,
        });
      }
    }

    const cuentas = new Map<number, boolean>();
    for (const [cuenta, info] of porCuenta) {
      const esNucleo =
        !concentradoras.has(cuenta) && (info.veces >= 2 || info.fuerte);
      cuentas.set(cuenta, esNucleo);
    }

    return { cuentas, hallazgos };
  }

  /**
   * Ver el comentario de la clase. La cuenta puede ser reseñadora o
   * reseñada -- cualquiera de los dos lados cuenta como "contraparte".
   *
   * **Bug corregido (2026-09-27, item C6):** el conteo incluia TODAS las
   * reseñas, tambien las que ya son evidencia de un anillo
   * (`senal_fraude_resena`) -- un vendedor con una granja de mas de 10
   * cuentas satelite (`satelites`, B.2) pasaba el umbral por su PROPIO
   * fraude, quedando marcado "concentrador" y excluido para siempre de
   * ser nucleo de su propio caso (justo lo contrario de lo que busca esta
   * exclusion: filtrar cuentas inocentes de mucho volumen, no blindar al
   * que arma la granja). Ahora las reseñas que ya son evidencia de algun
   * anillo no cuentan para este umbral.
   */
  private async obtenerCuentasConcentradoras(): Promise<Set<number>> {
    try {
      const resultado = await pool.query<{ id_usuario: string }>(
        `SELECT id_usuario
           FROM (
                  SELECT id_usuario, id_usuario_vendedor AS contraparte
                    FROM resena
                   WHERE id_resena NOT IN (SELECT id_resena FROM senal_fraude_resena)
                  UNION ALL
                  SELECT id_usuario_vendedor AS id_usuario, id_usuario AS contraparte
                    FROM resena
                   WHERE id_resena NOT IN (SELECT id_resena FROM senal_fraude_resena)
                ) todas
          GROUP BY id_usuario
         HAVING count(DISTINCT contraparte) > $1`,
        [MIN_CONTRAPARTES_CONCENTRADORA],
      );
      return new Set(resultado.rows.map((fila) => Number(fila.id_usuario)));
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }
}
