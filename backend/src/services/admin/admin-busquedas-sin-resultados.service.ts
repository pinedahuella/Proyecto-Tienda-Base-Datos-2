import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import { manejarErrorClickHouse } from '../../helpers/manejar-error-clickhouse';
import {
  validarDiasEvento,
  validarLimiteEvento,
} from '../../helpers/validaciones-eventos';
import type { ConsultarTendenciasQuery } from '../../dto/consultar-tendencias';
import type { BusquedaSinResultados } from '../../models/tendencia-evento';

/** Cuantos terminos sin resultados se comparan entre si para juntarlos. */
const CANDIDATOS = 300;

/** Un termino normalizado sin resultados, con sus vecinos por tecleo. */
export interface TerminoSinResultados {
  termino: string;
  sesiones: number;
  variantes: string[];
  ultima: string;
  /** Los otros candidatos a un error de tecleo de distancia (`editDistance`). */
  cercanos: string[];
}

/**
 * Lo mas buscado que NO encontro nada (`GET /admin/eventos/busquedas-sin-resultados`):
 * demanda que la tienda no cubre. Sale de `busqueda_realizada` (ClickHouse),
 * en vivo como el resto del panel de tendencias: es una ruta de admin, con
 * parametros, y ClickHouse agrega esto en milisegundos.
 *
 * Que cuenta:
 * - `resultados = 0`, `lote = 'real'`, en los ultimos `dias`.
 * - Sin filtros puestos (categoria, precio, calificacion, disponible): con un
 *   filtro, el cero puede ser culpa del filtro y no de que falte el producto.
 *   Una busqueda del facetado sin filtros es igual a una simple.
 * - Sesiones distintas, como las demas tendencias de busqueda: que alguien
 *   repita la misma busqueda no la hace mas buscada.
 *
 * Como se juntan las formas de escribir lo mismo:
 * 1. `termino_normalizado` (columna MATERIALIZED de ClickHouse: minusculas,
 *    sin tildes, sin espacios de mas) ya junta "Audifonos  INALAMBRICOS" con
 *    "audifonos inalambricos". El `termino` original no se pierde.
 * 2. Los errores de tecleo ("audifnos") los marca `editDistanceUTF8` entre los
 *    `CANDIDATOS` terminos mas buscados: 0 cambios si el mas corto tiene hasta
 *    4 letras (en palabras cortas un cambio es otra palabra), 1 hasta 8 y 2
 *    desde 9. Cada termino se une al MAS buscado que tenga cerca
 *    (`agruparPorTecleo`).
 * 3. Las sesiones de cada grupo se vuelven a contar en ClickHouse: quien busco
 *    dos formas del mismo grupo cuenta una vez.
 */
@Injectable()
export class AdminBusquedasSinResultadosService {
  private readonly logger = new Logger(AdminBusquedasSinResultadosService.name);

  async obtener(
    query: ConsultarTendenciasQuery,
  ): Promise<BusquedaSinResultados[]> {
    const dias = validarDiasEvento(query.dias);
    const limite = validarLimiteEvento(query.limite);

    try {
      const terminos = await this.terminos(dias);
      if (terminos.length === 0) {
        return [];
      }
      const grupoDe = agruparPorTecleo(terminos);
      const sesiones = await this.sesionesPorGrupo(dias, grupoDe);

      const grupos = new Map<string, BusquedaSinResultados>();
      for (const t of terminos) {
        const nombre = grupoDe.get(t.termino)!;
        const grupo = grupos.get(nombre) ?? {
          termino: nombre,
          sesiones: sesiones.get(nombre) ?? 0,
          terminos_agrupados: [],
          como_lo_escribieron: [],
          ultima_busqueda: t.ultima,
        };
        grupo.terminos_agrupados.push(t.termino);
        for (const variante of t.variantes) {
          if (
            grupo.como_lo_escribieron.length < 10 &&
            !grupo.como_lo_escribieron.includes(variante)
          ) {
            grupo.como_lo_escribieron.push(variante);
          }
        }
        if (t.ultima > grupo.ultima_busqueda) {
          grupo.ultima_busqueda = t.ultima;
        }
        grupos.set(nombre, grupo);
      }

      return [...grupos.values()]
        .sort(
          (a, b) =>
            b.sesiones - a.sesiones || a.termino.localeCompare(b.termino),
        )
        .slice(0, limite);
    } catch (error) {
      manejarErrorClickHouse(this.logger, error);
    }
  }

  /**
   * Los terminos normalizados sin resultados mas buscados y, de cada uno, los
   * otros que estan a un error de tecleo (`editDistanceUTF8`, sobre el mas
   * corto de los dos). El `CROSS JOIN` es entre a lo sumo `CANDIDATOS`
   * terminos: barato.
   */
  private async terminos(dias: number): Promise<TerminoSinResultados[]> {
    const resultado = await clickhouse.query({
      query: `
        WITH candidatos AS (
          SELECT termino_normalizado AS t,
                 count(DISTINCT sesion) AS sesiones,
                 groupUniqArray(10)(termino) AS variantes,
                 max(fecha) AS ultima
            FROM busqueda_realizada
           WHERE ${FILTRO_SIN_RESULTADOS}
           GROUP BY t
           ORDER BY sesiones DESC, t
           LIMIT {candidatos:UInt32}
        )
        SELECT a.t AS termino, a.sesiones AS sesiones, a.variantes AS variantes,
               formatDateTime(a.ultima, '%Y-%m-%dT%H:%i:%SZ', 'UTC') AS ultima,
               arrayFilter(x -> x != '', groupArray(
                 if(b.t != a.t AND editDistanceUTF8(a.t, b.t) <= multiIf(
                      least(lengthUTF8(a.t), lengthUTF8(b.t)) <= 4, 0,
                      least(lengthUTF8(a.t), lengthUTF8(b.t)) <= 8, 1, 2),
                    b.t, ''))) AS cercanos
          FROM candidatos a
          CROSS JOIN candidatos b
         GROUP BY a.t, a.sesiones, a.variantes, a.ultima
         ORDER BY sesiones DESC, termino`,
      query_params: { dias, candidatos: CANDIDATOS },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<
      Omit<TerminoSinResultados, 'sesiones'> & { sesiones: string }
    >();
    return filas.map((fila) => ({ ...fila, sesiones: Number(fila.sesiones) }));
  }

  /** Las sesiones distintas de cada grupo, contadas otra vez en ClickHouse. */
  private async sesionesPorGrupo(
    dias: number,
    grupoDe: Map<string, string>,
  ): Promise<Map<string, number>> {
    const resultado = await clickhouse.query({
      query: `
        SELECT transform(termino_normalizado, {terminos:Array(String)},
                         {grupos:Array(String)}, '') AS grupo,
               count(DISTINCT sesion) AS sesiones
          FROM busqueda_realizada
         WHERE ${FILTRO_SIN_RESULTADOS}
           AND has({terminos:Array(String)}, termino_normalizado)
         GROUP BY grupo`,
      query_params: {
        dias,
        terminos: [...grupoDe.keys()],
        grupos: [...grupoDe.values()],
      },
      format: 'JSONEachRow',
    });
    const filas = await resultado.json<{ grupo: string; sesiones: string }>();
    return new Map(filas.map((f) => [f.grupo, Number(f.sesiones)]));
  }
}

/** Las busquedas que cuentan (ver la clase). Usa el parametro `dias`. */
const FILTRO_SIN_RESULTADOS = `fecha >= now() - INTERVAL {dias:UInt32} DAY
             AND lote = 'real'
             AND resultados = 0
             AND termino_normalizado != ''
             AND empty(categorias) AND empty(precios)
             AND empty(calificaciones) AND disponible = 0`;

/**
 * Junta los terminos que son errores de tecleo unos de otros. Se recorren del
 * mas al menos buscado (ya vienen asi): cada uno se une al primer grupo cuyo
 * nombre (el termino mas buscado del grupo) tenga como cercano; si no hay,
 * abre su propio grupo. Asi un grupo siempre se llama como su forma mas
 * buscada y no se encadena ("ab" cerca de "abc", "abc" cerca de "abcd" no
 * junta "ab" con "abcd"). Devuelve, de cada termino, el nombre de su grupo.
 */
export function agruparPorTecleo(
  terminos: TerminoSinResultados[],
): Map<string, string> {
  const grupoDe = new Map<string, string>();
  const nombres: string[] = [];
  for (const t of terminos) {
    const nombre = nombres.find((n) => t.cercanos.includes(n));
    if (nombre != null) {
      grupoDe.set(t.termino, nombre);
    } else {
      nombres.push(t.termino);
      grupoDe.set(t.termino, t.termino);
    }
  }
  return grupoDe;
}
