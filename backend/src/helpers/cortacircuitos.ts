import { Logger } from '@nestjs/common';

/**
 * Un cortacircuitos por base: despues de ver que una base no responde, durante
 * `pausaMs` ni se le pregunta y el que llama recibe el fallo al instante. Al
 * pasar la pausa, la siguiente consulta vuelve a probar: si contesta, la base
 * volvio; si no, otra pausa.
 *
 * Existe por lo que tarda una base caida en decir que no esta. Con la base
 * parada en la misma maquina el "no" llega al instante, pero con la red cortada
 * o la base congelada cada consulta espera su limite entero (3 s Mongo, 8 s
 * Neo4j y ClickHouse, 10 s Redis, hasta 22 s Elasticsearch, medido el 19-10
 * con la PC de Jose David). Sin el cortacircuitos, cada seccion de la pagina
 * que toca esa base cobraria esa espera, una y otra vez. Con el, la cobra la
 * primera y las demas van directo a su respaldo o a su aviso.
 *
 * El molde es el de `conRespaldoDeMongo` (catalogo-respaldo.ts, 2026-10-19),
 * llevado a las seis bases. Cada entrada y salida queda en el registro del
 * backend con el nombre de la base, una sola vez por caida:
 *
 *   [Cortacircuitos] Redis no responde (Command timed out): pausa de 15 s
 *   [Cortacircuitos] Redis volvio
 *
 * No decide QUE es una caida: eso lo sabe cada driver (`esCaida`). Un error de
 * la consulta (sintaxis, una restriccion) no abre el cortacircuitos.
 */
export class Cortacircuitos {
  private static readonly logger = new Logger('Cortacircuitos');
  private static readonly todos = new Map<string, Cortacircuitos>();

  /** Hasta cuando no se le pregunta. 0 = la base responde. */
  private caidaHasta = 0;
  /** Si la base esta dada por caida, para avisar solo al entrar y al salir. */
  private caida = false;
  private desde: Date | null = null;
  private ultimoMotivo: string | null = null;

  constructor(
    readonly nombre: string,
    private readonly pausaMs = 15_000,
  ) {
    Cortacircuitos.todos.set(nombre, this);
  }

  /** `true` mientras dura la pausa: no vale la pena preguntarle. */
  enPausa(): boolean {
    return Date.now() < this.caidaHasta;
  }

  /** Si la ultima vez que se le pregunto no respondio (aunque ya paso la pausa). */
  dadaPorCaida(): boolean {
    return this.caida;
  }

  /** La base no respondio: pausa, y aviso en el registro si recien se cae. */
  registrarCaida(error: unknown): void {
    this.caidaHasta = Date.now() + this.pausaMs;
    this.ultimoMotivo = motivo(error);
    if (!this.caida) {
      this.caida = true;
      this.desde = new Date();
      Cortacircuitos.logger.warn(
        `${this.nombre} no responde (${this.ultimoMotivo}): pausa de ${this.pausaMs / 1000} s`,
      );
    }
  }

  /** La base respondio: si estaba caida, volvio. */
  registrarRespuesta(): void {
    this.caidaHasta = 0;
    if (this.caida) {
      this.caida = false;
      this.desde = null;
      Cortacircuitos.logger.log(`${this.nombre} volvio`);
    }
  }

  /**
   * Corre `consulta` si la base no esta en pausa. Si esta en pausa, lanza
   * `enPausaError()` sin preguntarle. Si la consulta falla y `esCaida` dice que
   * fue la base, la pausa empieza. El error sale siempre tal cual, para que el
   * que llama lo clasifique como siempre.
   */
  async correr<T>(
    consulta: () => Promise<T>,
    esCaida: (error: unknown) => boolean,
    enPausaError: () => Error,
  ): Promise<T> {
    if (this.enPausa()) {
      throw enPausaError();
    }
    try {
      const resultado = await consulta();
      this.registrarRespuesta();
      return resultado;
    } catch (error) {
      if (esCaida(error)) {
        this.registrarCaida(error);
      }
      throw error;
    }
  }

  /** Lo que se sabe de cada base, para GET /base-datos/estado. */
  static estados(): {
    base: string;
    responde: boolean;
    caida_desde: string | null;
    motivo: string | null;
  }[] {
    return [...Cortacircuitos.todos.values()].map((c) => ({
      base: c.nombre,
      responde: !c.caida,
      caida_desde: c.desde?.toISOString() ?? null,
      motivo: c.caida ? c.ultimoMotivo : null,
    }));
  }
}

function motivo(error: unknown): string {
  const texto =
    error instanceof AggregateError
      ? error.errors.map((e: unknown) => motivo(e)).join(' | ')
      : error instanceof Error
        ? error.message
        : String(error);
  return texto.length > 160 ? `${texto.slice(0, 157)}...` : texto;
}

/**
 * Corre una promesa con un limite de tiempo para la base congelada: si no
 * resuelve en `ms`, rechaza con `error()`. La promesa original sigue su curso
 * (no se puede cancelar), pero el que llama ya no la espera.
 */
export async function conLimite<T>(
  promesa: Promise<T>,
  ms: number,
  error: () => Error,
): Promise<T> {
  let temporizador: NodeJS.Timeout | undefined;
  const limite = new Promise<never>((_, rechazar) => {
    temporizador = setTimeout(() => rechazar(error()), ms);
  });
  try {
    return await Promise.race([promesa, limite]);
  } finally {
    clearTimeout(temporizador);
  }
}
