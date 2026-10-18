import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import neo4j from 'neo4j-driver';
import { consultarGrafo } from '../../database/neo4j';
import { conLimiteDeTiempo } from '../../helpers/limite-tiempo';
import { registrarAnilloFraude } from '../../helpers/registrar-anillo-fraude';

/**
 * `elementos Generales/plan pendiente/anillos-fraude-persistencia.md`: el
 * worker periodico que re-evalua A.1 (ciclos) y A.2 (mismo producto) --
 * consultas Cypher de deteccion sobre resenas -- acotadas a una ventana de
 * tiempo, cada `INTERVALO_MS`, y persiste lo que encuentra en
 * `anillo_fraude`/`anillo_fraude_resena` (ver
 * `anillos-fraude-persistencia.sql`, mismo folder).
 *
 * A.4 (misma direccion) queda fuera de este worker -- no depende de resenas,
 * asi que una version "por ventana de resenas" no le aplica (ver el plan,
 * punto 2 de las decisiones cerradas). Tampoco hay ningun endpoint todavia
 * que lea la tabla nueva -- eso queda para una ronda aparte.
 *
 * Mismo molde que `FraudeLoginRetrospectivoService` / `GrafoSyncService`:
 * `@Interval`, un flag `procesando` evita que se solape con la corrida
 * anterior, y un error de conexion se loguea y no tumba el proceso.
 */
@Injectable()
export class AnillosDetectorService {
  private readonly logger = new Logger(AnillosDetectorService.name);

  private static readonly INTERVALO_MS = 15 * 60 * 1000;

  /** Cuantos dias hacia atras se considera "activo". Ajustable, ver el plan. */
  private static readonly VENTANA_DIAS = 60;

  /** Las dos consultas son de varios saltos; que no se cuelgue. */
  private static readonly LIMITE_MS = 15000;

  private procesando = false;

  @Interval('anillos-detector', AnillosDetectorService.INTERVALO_MS)
  async detectar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      const dias = neo4j.int(AnillosDetectorService.VENTANA_DIAS);
      const [ciclicos, reiterados] = await conLimiteDeTiempo(
        Promise.all([
          consultarGrafo<FilaGrupo>(CYPHER_CICLICOS_VENTANA, { dias }),
          consultarGrafo<FilaGrupo>(CYPHER_MISMO_PRODUCTO_VENTANA, { dias }),
        ]),
        AnillosDetectorService.LIMITE_MS,
        'Neo4j',
      );
      const grupos = this.agrupar(ciclicos, reiterados);
      this.loguear(grupos, 'worker de anillos');
      await this.persistir(grupos);
    } catch (error) {
      this.logger.warn(
        `worker de anillos interrumpido: ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }

  /**
   * Version acotada de `detectar()`: la llama `ResenasService.crear()` justo
   * despues de que la resena nueva termina de proyectarse al grafo
   * (`GrafoSyncService.procesarAhora()`), para no esperar los 15 minutos del
   * worker. Corre A.1/A.2 con la MISMA ventana y el MISMO armado que la
   * version periodica (`agrupar`/`loguear` son compartidos a proposito: dos
   * copias de la regla es como esta clase termina en desacuerdo consigo
   * misma), pero exigiendo que el camino/par incluya la resena recien
   * proyectada (`idResena`) -- no las dos cuentas en general (eso
   * reencontraria un anillo viejo que el worker periodico ya vio), solo lo
   * que esta resena en concreto pudo haber cambiado.
   *
   * Fire-and-forget, sin mutex compartido con `detectar()`: las dos
   * consultas son de solo lectura y no hay estado compartido entre
   * corridas, asi que no hace falta (mismo razonamiento que
   * `GrafoSyncService.procesarAhora()`).
   */
  async detectarInmediato(idResena: string): Promise<void> {
    try {
      const dias = neo4j.int(AnillosDetectorService.VENTANA_DIAS);
      const idResenaNeo4j = neo4j.int(idResena);
      const [ciclicos, reiterados] = await conLimiteDeTiempo(
        Promise.all([
          consultarGrafo<FilaGrupo>(CYPHER_CICLICOS_VENTANA_ACOTADO, {
            dias,
            idResena: idResenaNeo4j,
          }),
          consultarGrafo<FilaGrupo>(CYPHER_MISMO_PRODUCTO_VENTANA_ACOTADO, {
            dias,
            idResena: idResenaNeo4j,
          }),
        ]),
        AnillosDetectorService.LIMITE_MS,
        'Neo4j',
      );
      const grupos = this.agrupar(ciclicos, reiterados);
      this.loguear(grupos, `chequeo acotado de anillos (resena ${idResena})`);
      await this.persistir(grupos);
    } catch (error) {
      this.logger.warn(
        `chequeo acotado de anillos interrumpido (resena ${idResena}): ${mensajeCorto(error)}`,
      );
    }
  }

  /**
   * Junta el resultado de A.1/A.2 por el conjunto de cuentas: un par puede
   * llegar por las dos consultas (o por varias rotaciones del mismo ciclo) y
   * se junta, no se duplica; "reiterado" pisa el tipo de un par que tambien
   * salio como "mutuo" (misma pareja, senal mas fuerte).
   *
   * De un par se guardan ademas las `horas` entre la ida y la vuelta (la mas
   * corta, si se calificaron varias veces): es lo que antes era su propia
   * senal, `favor_devuelto` (B.5). Devolver la nota en minutos no es una
   * compra, es una respuesta; el puntaje lo usa como bono.
   */
  private agrupar(
    ciclicos: FilaGrupo[],
    reiterados: FilaGrupo[],
  ): GrupoDetectado[] {
    const grupos = new Map<string, GrupoDetectado>();
    const registrar = (
      tipo: 'mutuo' | 'ciclo' | 'reiterado',
      cuentas: number[],
      resenas: number[],
      ganaElTipo: boolean,
      horas: number | null,
    ): void => {
      const clave = [...cuentas].sort((a, b) => a - b).join('-');
      const existente = grupos.get(clave);
      if (existente == null) {
        grupos.set(clave, {
          tipo,
          clave,
          cuentas,
          resenas: dedup(resenas),
          horas,
        });
        return;
      }
      existente.resenas = dedup([...existente.resenas, ...resenas]);
      if (ganaElTipo) {
        existente.tipo = tipo;
      }
      if (
        horas != null &&
        (existente.horas == null || horas < existente.horas)
      ) {
        existente.horas = horas;
      }
    };

    for (const fila of ciclicos) {
      const cuentas = fila.cuentas.map(aNumero);
      const resenas = fila.resenas.map(aNumero);
      const segundos = (fila.segundos ?? []).map(aNumero);
      registrar(
        cuentas.length >= 3 ? 'ciclo' : 'mutuo',
        cuentas,
        resenas,
        false,
        cuentas.length === 2 && segundos.length === 2
          ? Math.abs(segundos[1] - segundos[0]) / 3600
          : null,
      );
    }
    for (const fila of reiterados) {
      const cuentas = fila.cuentas.map(aNumero);
      const resenas = fila.resenas.map(aNumero);
      registrar('reiterado', cuentas, resenas, true, null);
    }

    return [...grupos.values()];
  }

  private loguear(grupos: GrupoDetectado[], contexto: string): void {
    if (grupos.length === 0) {
      this.logger.log(
        `${contexto}: sin hallazgos en los ultimos ${AnillosDetectorService.VENTANA_DIAS} dias`,
      );
      return;
    }
    for (const grupo of grupos) {
      this.logger.log(
        `${contexto}: ${grupo.tipo} -- cuentas [${grupo.cuentas.join(', ')}], ${grupo.resenas.length} resena(s) [${grupo.resenas.join(', ')}]`,
      );
    }
  }

  /**
   * Deja (o refresca) una fila de `anillo_fraude` por cada grupo -- ver
   * `registrarAnilloFraude` para el detalle del UPSERT. Un anillo que falla
   * al persistir (PostgreSQL caido) no debe tumbar el resto del lote ni la
   * corrida completa: se loguea y se sigue con los demas, mismo criterio que
   * `BuscadorSyncService`/`EventosAutenticacionSyncService` con sus items.
   */
  private async persistir(grupos: GrupoDetectado[]): Promise<void> {
    for (const grupo of grupos) {
      try {
        await registrarAnilloFraude({
          tipo: grupo.tipo,
          clave: grupo.clave,
          resenas: grupo.resenas,
          detalle: grupo.horas == null ? undefined : { horas: grupo.horas },
        });
      } catch (error) {
        this.logger.warn(
          `no se pudo persistir el anillo ${grupo.clave}: ${mensajeCorto(error)}`,
        );
      }
    }
  }
}

interface GrupoDetectado {
  tipo: 'mutuo' | 'ciclo' | 'reiterado';
  clave: string;
  cuentas: number[];
  resenas: number[];
  /** Solo de un par: horas entre la ida y la vuelta (la mas corta). */
  horas: number | null;
}

/** Una fila cruda de cualquiera de las dos consultas: ids de Neo4j (Integer).
 * `segundos` (la fecha de cada resena) solo la traen las de ciclos. */
interface FilaGrupo {
  cuentas: unknown[];
  resenas: unknown[];
  segundos?: unknown[];
}

/**
 * Neo4j devuelve los enteros como su propio tipo `Integer` (64 bits). Los
 * ids de este dominio son chicos: se pasan a `number` sin riesgo. Mismo
 * criterio que `grafo-sync.service.ts`.
 */
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

/**
 * A.1 con ventana: camino cerrado ESCRIBIO/CALIFICA_A de 4 a 8 saltos,
 * exigiendo ademas que TODAS las resenas del camino caigan dentro de los
 * ultimos `$dias` dias -- un ciclo con una sola resena vieja ya no cuenta
 * como activo. Solo devuelve los ids (no el detalle de cuentas/resenas que
 * arma el panel): esta version es de deteccion, no de payload para un
 * endpoint.
 */
const CYPHER_CICLICOS_VENTANA = `
MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH nodes(camino) AS nodos
WITH [n IN nodos WHERE n:Usuario] AS usuariosCamino,
     [n IN nodos WHERE n:Resena]  AS resenasCamino
WITH usuariosCamino[0..-1] AS ciclo, resenasCamino
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
  AND ALL (r IN resenasCamino WHERE r.fecha >= datetime() - duration({days: $dias}))
RETURN
  [c IN ciclo | c.id] AS cuentas,
  [r IN resenasCamino | r.id] AS resenas,
  [r IN resenasCamino | r.fecha.epochSeconds] AS segundos
`;

/**
 * A.2 con ventana: mismo patron que `CYPHER_PARES_MISMO_PRODUCTO`, exigiendo
 * que las DOS resenas del par (`ra`, `rb`) esten dentro de la ventana.
 */
const CYPHER_MISMO_PRODUCTO_VENTANA = `
MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a),
      (ra)-[:SOBRE]->(:Producto)<-[:SOBRE]-(rb)
WHERE a.id < b.id
  AND ra.fecha >= datetime() - duration({days: $dias})
  AND rb.fecha >= datetime() - duration({days: $dias})
WITH a, b, collect(DISTINCT ra.id) + collect(DISTINCT rb.id) AS resenas
RETURN [a.id, b.id] AS cuentas, resenas
`;

/**
 * A.1 acotada a UNA resena: igual que `CYPHER_CICLICOS_VENTANA`, pero exige
 * ademas que `$idResena` sea parte del camino -- la reescritura de esta
 * consulta solo puede encontrar un ciclo NUEVO si pasa por la resena recien
 * proyectada (es la unica arista que se acaba de agregar al grafo); un
 * ciclo viejo entre las mismas dos cuentas ya lo habria visto una corrida
 * anterior del worker periodico o de este mismo chequeo acotado.
 */
const CYPHER_CICLICOS_VENTANA_ACOTADO = `
MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH nodes(camino) AS nodos
WITH [n IN nodos WHERE n:Usuario] AS usuariosCamino,
     [n IN nodos WHERE n:Resena]  AS resenasCamino
WITH usuariosCamino[0..-1] AS ciclo, resenasCamino
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
  AND ALL (r IN resenasCamino WHERE r.fecha >= datetime() - duration({days: $dias}))
  AND $idResena IN [r IN resenasCamino | r.id]
RETURN
  [c IN ciclo | c.id] AS cuentas,
  [r IN resenasCamino | r.id] AS resenas,
  [r IN resenasCamino | r.fecha.epochSeconds] AS segundos
`;

/**
 * A.2 acotada a UNA resena: igual que `CYPHER_MISMO_PRODUCTO_VENTANA`, pero
 * exige que `$idResena` sea una de las dos resenas del par (`ra` o `rb`) --
 * mismo razonamiento que la de arriba.
 */
const CYPHER_MISMO_PRODUCTO_VENTANA_ACOTADO = `
MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a),
      (ra)-[:SOBRE]->(:Producto)<-[:SOBRE]-(rb)
WHERE a.id < b.id
  AND ra.fecha >= datetime() - duration({days: $dias})
  AND rb.fecha >= datetime() - duration({days: $dias})
  AND ($idResena = ra.id OR $idResena = rb.id)
WITH a, b, collect(DISTINCT ra.id) + collect(DISTINCT rb.id) AS resenas
RETURN [a.id, b.id] AS cuentas, resenas
`;
