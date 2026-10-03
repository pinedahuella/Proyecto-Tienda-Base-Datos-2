import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import neo4j from 'neo4j-driver';
import { consultarGrafo } from '../../database/neo4j';
import { conLimiteDeTiempo } from '../../helpers/limite-tiempo';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';
import { TipoAnilloFraude } from '../../models/anillo-fraude';

/**
 * `elementos Generales/plan pendiente/anillos-fraude-familia-b.md`: extiende
 * lo que `AnillosDetectorService` hace para A.1/A.2 a las seis consultas de
 * `neo4j/consultas/B1..B7` que SI se persisten como su propio tipo de caso
 * (`cadena_abierta`, `satelites`, `persistente`, `favor_devuelto`,
 * `coordinados`, `reputacion_expres`). `B.4` (anillo_en_el_tiempo) queda
 * fuera a proposito: su funcion es mostrar lo que la ventana de dias
 * esconde, asi que ponerle la misma ventana lo volveria inutil -- se usa
 * como enriquecimiento del detalle de un `ciclo`/`reiterado` ya existente,
 * no como hallazgo propio (ver `FraudeAnillosPersistidosService`).
 *
 * Los umbrales de cada consulta (nota alta, dias de cadena, horas de
 * sincronia, etc.) son los mismos que `neo4j/consultas/B0_parametros.cypher`
 * -- medidos contra los datos reales, ver ese archivo para el porque de cada
 * numero. `VENTANA_DIAS` es la misma idea que
 * `AnillosDetectorService.VENTANA_DIAS`: sin ella, un hallazgo de hace anos
 * seguiria "confirmandose activo" para siempre, porque los parametros de
 * cada consulta acotan la FORMA del patron (cuanto dura, que tan sincronizado
 * esta) pero no su RECENCIA.
 *
 * Mismo molde que `AnillosDetectorService`: `@Interval`, un flag
 * `procesando` evita que se solape con la corrida anterior, y un error de
 * conexion se loguea y no tumba el proceso. A diferencia de aquella, aca no
 * hace falta un `agrupar()` que fusione tipos -- cada uno de los seis
 * patrones es independiente de los demas (no hay una escalada entre
 * `persistente` y `favor_devuelto`, por ejemplo), asi que cada hallazgo se
 * persiste con su propio tipo tal cual sale de su consulta.
 */
@Injectable()
export class PatronesFraudeDetectorService {
  private readonly logger = new Logger(PatronesFraudeDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Misma idea que `AnillosDetectorService.VENTANA_DIAS`. */
  private static readonly VENTANA_DIAS = 60;

  /** Seis consultas de varios saltos en la misma corrida; que no se cuelgue. */
  private static readonly LIMITE_MS = 20000;

  // Umbrales de B0_parametros.cypher (neo4j/consultas), medidos contra los
  // datos reales -- ver ese archivo para el razonamiento de cada uno.
  private static readonly NOTA_ALTA = 4;
  private static readonly DIAS_CADENA = 30;
  private static readonly DIAS_CUENTA_DESECHABLE = 7;
  private static readonly MIN_SATELITES = 3;
  private static readonly MIN_MESES = 3;
  private static readonly MIN_EXCLUSIVIDAD = 0.6;
  private static readonly HORAS_DEVOLUCION = 72;
  private static readonly HORAS_SINCRONIA = 24;
  private static readonly MIN_COINCIDENCIAS = 3;
  private static readonly HORAS_CUENTA_NUEVA = 24;
  private static readonly DIAS_VENDEDOR_NUEVO = 7;

  private procesando = false;

  @Interval(
    'patrones-fraude-detector',
    PatronesFraudeDetectorService.INTERVALO_MS,
  )
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const parametros = this.parametrosBase();
      const [cadenas, satelites, persistentes, favores, coordinados, expres] =
        await conLimiteDeTiempo(
          Promise.all([
            consultarGrafo<FilaHallazgo>(CYPHER_B1_VENTANA, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B2_VENTANA, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B3_VENTANA, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B5_VENTANA, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B6_VENTANA, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B7_VENTANA, parametros),
          ]),
          PatronesFraudeDetectorService.LIMITE_MS,
          'Neo4j',
        );

      const hallazgos: HallazgoTipado[] = [
        ...cadenas.map((f) => ({ tipo: 'cadena_abierta' as const, fila: f })),
        ...satelites.map((f) => ({ tipo: 'satelites' as const, fila: f })),
        ...persistentes.map((f) => ({ tipo: 'persistente' as const, fila: f })),
        ...favores.map((f) => ({ tipo: 'favor_devuelto' as const, fila: f })),
        ...coordinados.map((f) => ({ tipo: 'coordinados' as const, fila: f })),
        ...expres.map((f) => ({ tipo: 'reputacion_expres' as const, fila: f })),
      ];

      this.loguear(hallazgos, 'worker de patrones');
      await this.persistir(hallazgos);
    } catch (error) {
      this.logger.warn(
        `worker de patrones interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * Version acotada de `detectar()`, para los cuatro patrones cuya evidencia
   * gira sobre DOS cuentas y una reseña puntual (B.1/B.3/B.5/B.6) -- mismo
   * criterio que `AnillosDetectorService.detectarInmediato()`. B.2
   * (satelites) y B.7 (reputacion expres) quedan fuera: agrupan por
   * VENDEDOR ("¿ya tiene 3+ satelites?"), una pregunta sobre el vendedor
   * completo que una sola reseña nueva no contesta sola -- los cubre el
   * worker periodico, sin que el rezago de hasta 15 min sea un problema real
   * para patrones que por definicion tardan mas de un dia en formarse.
   *
   * Fire-and-forget, sin mutex compartido con `detectar()` -- mismo
   * razonamiento que `AnillosDetectorService.detectarInmediato()`.
   */
  async detectarInmediato(idResena: string): Promise<void> {
    try {
      const parametros = {
        ...this.parametrosBase(),
        idResena: neo4j.int(idResena),
      };
      const [cadenas, persistentes, favores, coordinados] =
        await conLimiteDeTiempo(
          Promise.all([
            consultarGrafo<FilaHallazgo>(CYPHER_B1_VENTANA_ACOTADO, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B3_VENTANA_ACOTADO, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B5_VENTANA_ACOTADO, parametros),
            consultarGrafo<FilaHallazgo>(CYPHER_B6_VENTANA_ACOTADO, parametros),
          ]),
          PatronesFraudeDetectorService.LIMITE_MS,
          'Neo4j',
        );

      const hallazgos: HallazgoTipado[] = [
        ...cadenas.map((f) => ({ tipo: 'cadena_abierta' as const, fila: f })),
        ...persistentes.map((f) => ({ tipo: 'persistente' as const, fila: f })),
        ...favores.map((f) => ({ tipo: 'favor_devuelto' as const, fila: f })),
        ...coordinados.map((f) => ({ tipo: 'coordinados' as const, fila: f })),
      ];

      this.loguear(
        hallazgos,
        `chequeo acotado de patrones (resena ${idResena})`,
      );
      await this.persistir(hallazgos);
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de patrones interrumpido (resena ${idResena}): ${mensajeCorto(error)}`,
      );
    }
  }

  private parametrosBase(): Record<string, unknown> {
    return {
      dias: neo4j.int(PatronesFraudeDetectorService.VENTANA_DIAS),
      nota_alta: neo4j.int(PatronesFraudeDetectorService.NOTA_ALTA),
      dias_cadena: neo4j.int(PatronesFraudeDetectorService.DIAS_CADENA),
      dias_cuenta_desechable: neo4j.int(
        PatronesFraudeDetectorService.DIAS_CUENTA_DESECHABLE,
      ),
      min_satelites: neo4j.int(PatronesFraudeDetectorService.MIN_SATELITES),
      min_meses: neo4j.int(PatronesFraudeDetectorService.MIN_MESES),
      min_exclusividad: PatronesFraudeDetectorService.MIN_EXCLUSIVIDAD,
      horas_devolucion: neo4j.int(
        PatronesFraudeDetectorService.HORAS_DEVOLUCION,
      ),
      horas_sincronia: neo4j.int(PatronesFraudeDetectorService.HORAS_SINCRONIA),
      min_coincidencias: neo4j.int(
        PatronesFraudeDetectorService.MIN_COINCIDENCIAS,
      ),
      horas_cuenta_nueva: neo4j.int(
        PatronesFraudeDetectorService.HORAS_CUENTA_NUEVA,
      ),
      dias_vendedor_nuevo: neo4j.int(
        PatronesFraudeDetectorService.DIAS_VENDEDOR_NUEVO,
      ),
    };
  }

  private loguear(hallazgos: HallazgoTipado[], contexto: string): void {
    if (hallazgos.length === 0) {
      this.logger.log(
        `${contexto}: sin hallazgos en los ultimos ${PatronesFraudeDetectorService.VENTANA_DIAS} dias`,
      );
      return;
    }
    for (const { tipo, fila } of hallazgos) {
      const cuentas = fila.cuentas.map(aNumero);
      const resenas = fila.resenas.map(aNumero);
      this.logger.log(
        `${contexto}: ${tipo} -- cuentas [${cuentas.join(', ')}], ${resenas.length} resena(s) [${resenas.join(', ')}]`,
      );
    }
  }

  /**
   * A diferencia de `AnillosDetectorService.persistir()`, no hay `agrupar()`
   * previo: cada fila de cada consulta ya es un caso independiente (no hay
   * tipo que "gane" sobre otro entre los seis patrones), asi que se registra
   * tal cual sale, una llamada por fila.
   */
  private async persistir(hallazgos: HallazgoTipado[]): Promise<void> {
    for (const { tipo, fila } of hallazgos) {
      const cuentas = fila.cuentas.map(aNumero);
      const resenas = dedup(fila.resenas.map(aNumero));
      const clave = [...cuentas].sort((a, b) => a - b).join('-');
      try {
        await registrarAnilloFraude({
          tipo,
          clave,
          resenas,
          detalle: this.detalleDe(tipo, fila),
        });
      } catch (error) {
        this.logger.warn(
          `no se pudo persistir el caso ${tipo} ${clave}: ${mensajeCorto(error)}`,
        );
      }
    }
  }

  /** Solo estos tres tipos traen metricas hoy -- ver `PUNTOS_BASE` en
   * `puntaje-fraude.service.ts`. Los demas se quedan con el `{}` por
   * defecto de `registrarAnilloFraude`. */
  private detalleDe(
    tipo: HallazgoTipado['tipo'],
    fila: FilaHallazgo,
  ): Record<string, unknown> | undefined {
    if (tipo === 'favor_devuelto') {
      return { horas: fila.horas };
    }
    if (tipo === 'reputacion_expres') {
      return { autor_minutos_vida: fila.autor_minutos_vida };
    }
    if (tipo === 'persistente') {
      return { es_mutuo: fila.es_mutuo, regularidad: fila.regularidad };
    }
    return undefined;
  }
}

type HallazgoTipado = {
  tipo: Exclude<
    TipoAnilloFraude,
    | 'mutuo'
    | 'ciclo'
    | 'reiterado'
    | 'anillo_en_el_tiempo'
    | 'resenas_repetidas'
    | 'anillo_de_texto'
  >;
  fila: FilaHallazgo;
};

/** Una fila cruda de cualquiera de las consultas: ids de Neo4j (Integer).
 * Los ultimos cuatro campos solo los traen B.3/B.5/B.7 -- ver `detalleDe`. */
interface FilaHallazgo {
  cuentas: unknown[];
  resenas: unknown[];
  horas?: number;
  autor_minutos_vida?: number;
  es_mutuo?: boolean;
  regularidad?: number;
}

/** Mismo criterio que `anillos-detector.service.ts`. */
function aNumero(valor: unknown): number {
  if (neo4j.isInt(valor)) {
    return (valor as { toNumber(): number }).toNumber();
  }
  return typeof valor === 'number' ? valor : 0;
}

function dedup(numeros: number[]): number[] {
  return [...new Set(numeros)].sort((a, b) => a - b);
}

function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}

// =====================================================================
// B.1 -- cadena abierta
// =====================================================================
//
// Igual que `neo4j/consultas/B1_cadena_abierta.cypher`, sin el bloque de
// `Direccion` (fuera de alcance por ahora) y sin las columnas cosmeticas
// (correos, agravantes) -- esta version es de deteccion, no de payload para
// un endpoint. Agrega `ultima >= ... - $dias` (recencia: la reseña MAS
// RECIENTE de la cadena, no solo que su duracion quepa en `$dias_cadena`) y,
// en la version acotada, exige que `$idResena` sea parte del camino.
const CYPHER_B1_BASE = `
MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(fin:Usuario)
WHERE inicio <> fin
WITH inicio, fin,
     [n IN nodes(camino) WHERE n:Usuario] AS cuentas,
     [n IN nodes(camino) WHERE n:Resena]  AS resenas
WHERE size(cuentas) = size(reduce(vistas = [], c IN cuentas |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
  AND ALL (r IN resenas WHERE r.calificacion >= $nota_alta)
  AND NOT EXISTS { (fin)-[:ESCRIBIO|CALIFICA_A*2..6]->(inicio) }
`;

const CYPHER_B1_RESTO = `
WITH cuentas, resenas,
     reduce(m = resenas[0].fecha, r IN resenas | CASE WHEN r.fecha < m THEN r.fecha ELSE m END) AS primera,
     reduce(m = resenas[0].fecha, r IN resenas | CASE WHEN r.fecha > m THEN r.fecha ELSE m END) AS ultima
WHERE ultima.epochSeconds - primera.epochSeconds <= $dias_cadena * 86400
  AND ultima >= datetime() - duration({days: $dias})

WITH [c IN cuentas | c.id] AS ids, collect(resenas) AS grupos
WITH ids, reduce(t = [], g IN grupos | t + [r IN g WHERE NOT r IN t]) AS resenas

WITH collect({ids: ids, resenas: resenas}) AS todas
UNWIND todas AS c
WITH c, todas
WHERE NONE (o IN todas WHERE size(o.ids) > size(c.ids)
        AND ANY (i IN range(0, size(o.ids) - size(c.ids))
                 WHERE o.ids[i..i + size(c.ids)] = c.ids))
RETURN c.ids AS cuentas, [r IN c.resenas | r.id] AS resenas
`;

const CYPHER_B1_VENTANA = CYPHER_B1_BASE + CYPHER_B1_RESTO;

const CYPHER_B1_VENTANA_ACOTADO =
  CYPHER_B1_BASE +
  `  AND $idResena IN [r IN resenas | r.id]\n` +
  CYPHER_B1_RESTO;

// =====================================================================
// B.2 -- satelites (solo periodico, agrupa por vendedor)
// =====================================================================
const CYPHER_B2_VENTANA = `
MATCH (s:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(v:Usuario)
WITH s, collect(DISTINCT v) AS vendedores, collect(r) AS resenas
WHERE size(vendedores) = 1
  AND ALL (x IN resenas WHERE x.calificacion >= $nota_alta)
WITH vendedores[0] AS v, s, resenas,
     reduce(m = resenas[0].fecha, x IN resenas | CASE WHEN x.fecha < m THEN x.fecha ELSE m END) AS primera
WHERE primera.epochSeconds >= s.fecha_alta.epochSeconds
  AND primera.epochSeconds - s.fecha_alta.epochSeconds <= $dias_cuenta_desechable * 86400

WITH v, collect(s) AS satelites,
     reduce(t = [], g IN collect(resenas) | t + g) AS resenas
WHERE size(satelites) >= $min_satelites
  AND reduce(m = resenas[0].fecha, x IN resenas | CASE WHEN x.fecha > m THEN x.fecha ELSE m END)
      >= datetime() - duration({days: $dias})
RETURN [v.id] + [x IN satelites | x.id] AS cuentas, [r IN resenas | r.id] AS resenas
`;

// =====================================================================
// B.3 -- persistente
// =====================================================================
const CYPHER_B3_BASE = `
MATCH (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(b:Usuario)
WITH a, b, r ORDER BY r.fecha
WITH a, b, collect(r) AS rs
WHERE ALL (x IN rs WHERE x.calificacion >= $nota_alta)
`;

const CYPHER_B3_RESTO = `
WITH a, b, rs,
     reduce(ms = [], x IN rs |
       CASE WHEN (x.fecha.year * 100 + x.fecha.month) IN ms THEN ms
            ELSE ms + (x.fecha.year * 100 + x.fecha.month) END) AS meses
WHERE size(meses) >= $min_meses
  AND rs[-1].fecha >= datetime() - duration({days: $dias})
WITH a, b, rs,
     1.0 * size(rs) / COUNT { (a)-[:ESCRIBIO]->(:Resena) } AS exclusividad
WHERE exclusividad >= $min_exclusividad
WITH a, b, rs,
     [i IN range(1, size(rs) - 1) |
        (rs[i].fecha.epochSeconds - rs[i - 1].fecha.epochSeconds) / 86400.0] AS intervalos
WITH a, b, rs, intervalos,
     reduce(s = 0.0, x IN intervalos | s + x) / size(intervalos) AS media
WITH a, b, rs, media,
     sqrt(reduce(s = 0.0, x IN intervalos | s + (x - media) ^ 2) / size(intervalos)) AS desviacion
RETURN [a.id, b.id] AS cuentas, [x IN rs | x.id] AS resenas,
       desviacion / media AS regularidad,
       EXISTS { (b)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(a) } AS es_mutuo
`;

const CYPHER_B3_VENTANA = CYPHER_B3_BASE + CYPHER_B3_RESTO;

const CYPHER_B3_VENTANA_ACOTADO =
  CYPHER_B3_BASE + `  AND $idResena IN [x IN rs | x.id]\n` + CYPHER_B3_RESTO;

// =====================================================================
// B.5 -- favor devuelto
// =====================================================================
const CYPHER_B5_BASE = `
MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a)
WHERE rb.fecha >= ra.fecha
  AND rb.fecha.epochSeconds - ra.fecha.epochSeconds <= $horas_devolucion * 3600
  AND ra.calificacion >= $nota_alta
  AND rb.calificacion >= $nota_alta
  AND rb.fecha >= datetime() - duration({days: $dias})
`;

const CYPHER_B5_RESTO = `
WITH CASE WHEN a.id < b.id THEN a ELSE b END AS x,
     CASE WHEN a.id < b.id THEN b ELSE a END AS y,
     collect(ra.id) + collect(rb.id) AS resenas,
     min(rb.fecha.epochSeconds - ra.fecha.epochSeconds) AS segundos_minimos
RETURN [x.id, y.id] AS cuentas, resenas,
       segundos_minimos / 3600.0 AS horas
`;

const CYPHER_B5_VENTANA = CYPHER_B5_BASE + CYPHER_B5_RESTO;

const CYPHER_B5_VENTANA_ACOTADO =
  CYPHER_B5_BASE +
  `  AND ($idResena = ra.id OR $idResena = rb.id)\n` +
  CYPHER_B5_RESTO;

// =====================================================================
// B.6 -- coordinados
// =====================================================================
const CYPHER_B6_BASE = `
MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:SOBRE]->(p:Producto)<-[:SOBRE]-(rb:Resena)<-[:ESCRIBIO]-(b:Usuario)
WHERE a.id < b.id
  AND abs(ra.fecha.epochSeconds - rb.fecha.epochSeconds) <= $horas_sincronia * 3600
`;

const CYPHER_B6_AGREGADO = `
MATCH (ra)-[:CALIFICA_A]->(v:Usuario)<-[:CALIFICA_A]-(rb)
WITH a, b, collect(ra) AS ras, collect(rb) AS rbs
WITH a, b, size(ras) AS coincidencias, ras, rbs,
     reduce(m = ras[0].fecha, x IN ras + rbs | CASE WHEN x.fecha > m THEN x.fecha ELSE m END) AS ultima
WHERE coincidencias >= $min_coincidencias
  AND ultima >= datetime() - duration({days: $dias})
`;

const CYPHER_B6_RETURN = `
RETURN [a.id, b.id] AS cuentas, [r IN ras | r.id] + [r IN rbs | r.id] AS resenas
`;

const CYPHER_B6_VENTANA =
  CYPHER_B6_BASE + CYPHER_B6_AGREGADO + CYPHER_B6_RETURN;

// El filtro de `$idResena` va DESPUES de agregar `coincidencias`, no en el
// WHERE de arriba (junto a `horas_sincronia`): filtrar las filas ANTES de
// contarlas dejaria, para el par (a,b), solo la fila de la reseña nueva --
// `coincidencias` daria 1 y nunca llegaria a `$min_coincidencias`. Detectado
// probando esta consulta a mano contra datos sembrados: la version que
// filtraba temprano encontraba el caso completo (B.6 con `$min_coincidencias`
// de sobra) en la version sin acotar, pero la acotada volvia vacia para la
// misma reseña -- exactamente el patron que se busca, invisible por como se
// armo el filtro.
const CYPHER_B6_VENTANA_ACOTADO =
  CYPHER_B6_BASE +
  CYPHER_B6_AGREGADO +
  `  AND $idResena IN ([r IN ras | r.id] + [r IN rbs | r.id])\n` +
  CYPHER_B6_RETURN;

// =====================================================================
// B.7 -- reputacion expres (solo periodico, agrupa por vendedor)
// =====================================================================
const CYPHER_B7_VENTANA = `
MATCH (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(v:Usuario)
WHERE r.calificacion >= $nota_alta
  AND r.fecha.epochSeconds >= a.fecha_alta.epochSeconds
  AND r.fecha.epochSeconds - a.fecha_alta.epochSeconds <= $horas_cuenta_nueva * 3600
  AND r.fecha.epochSeconds >= v.fecha_alta.epochSeconds
  AND r.fecha.epochSeconds - v.fecha_alta.epochSeconds <= $dias_vendedor_nuevo * 86400
  AND r.fecha >= datetime() - duration({days: $dias})
WITH v, a, r, (r.fecha.epochSeconds - a.fecha_alta.epochSeconds) / 60.0 AS minutos
WITH v, collect(DISTINCT a) AS autores, collect(r) AS resenas, min(minutos) AS minutos_min
RETURN [v.id] + [x IN autores | x.id] AS cuentas, [r IN resenas | r.id] AS resenas,
       minutos_min AS autor_minutos_vida
`;
