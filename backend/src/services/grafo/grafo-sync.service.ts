import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import type { PoolClient } from 'pg';
import neo4j from 'neo4j-driver';
import { pool } from '../../database/postgres';
import { consultarGrafo, ejecutarGrafo } from '../../database/neo4j';
import { conLimiteDeTiempo } from '../../helpers/limite-tiempo';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import {
  esFalloDeConexionGrafo,
  manejarErrorGrafo,
} from '../../helpers/manejar-error-grafo';
import { ESTADOS_DE_COMPRA } from './grafo-compras-sync.service';
import {
  ConciliacionGrafo,
  EstadoColaGrafo,
  EventoGrafoApartado,
  FilaConciliacion,
} from '../../models/grafo';

/**
 * La sincronizacion del grafo de Neo4j con PostgreSQL. El grafo es una
 * PROYECCION de la tabla `resena` (modelo en `neo4j/001_esquema.cypher`);
 * la carga inicial la hace el ETL `etl/cargar_grafo.sh`.
 *
 * Esta clase tiene dos piezas:
 *
 *  1. El **worker** del outbox (`@Interval`): cada N segundos vacia la cola
 *     `evento_grafo` -- por cada resena que cambio, la proyecta a Neo4j
 *     (`MERGE`) o la borra (`DETACH DELETE`) si ya no existe. Es el envio
 *     asincrono que pidio el profesor: `POST /resenas` no le habla a Neo4j,
 *     solo el trigger encola y este worker despacha. Todo idempotente.
 *
 *     Ademas del `@Interval`, expone `procesarAhora()`: la llama
 *     `ResenasService` justo despues de crear una resena, para no depender
 *     solo del reloj de 10s (ver ese metodo).
 *
 *  2. La **conciliacion** (`conciliar()`, para `GET /admin/grafo/conciliacion`):
 *     la red de seguridad. Compara los conteos de las dos bases y AVISA de
 *     la deriva -- NO repara (para eso esta `etl/cargar_grafo.sh --limpiar`).
 *
 * Ver `elementos Generales/plan pendiente/outbox-grafo.md`.
 */
@Injectable()
export class GrafoSyncService {
  private readonly logger = new Logger(GrafoSyncService.name);

  /** La conciliacion toca las dos bases; que no se cuelgue. */
  private static readonly LIMITE_MS = 15000;

  /** Cada cuanto corre el worker que vacia la cola. */
  private static readonly INTERVALO_MS = 10000;

  /** Tope de eventos por corrida del worker: si hay mas, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 500;

  /** Reintentos antes de apartar un evento envenenado (dato torcido). */
  private static readonly MAX_INTENTOS = 5;

  /** Cada cuantas corridas se poda lo ya procesado (~1 h con 10 s de intervalo). */
  private static readonly PODA_CADA = 360;

  /** Se descarta lo procesado con mas de estos dias. */
  private static readonly RETENCION_DIAS = 7;

  /** `true` mientras una corrida del worker esta en curso: la siguiente se salta. */
  private procesando = false;

  /** Cuenta corridas para decidir cuando podar. */
  private corridas = 0;

  /** Para no repetir el aviso de "la tabla evento_grafo no existe" en cada corrida. */
  private avisoTablaAusente = false;

  // ===================================================================
  // 1. EL WORKER -- vacia la cola `evento_grafo`
  // ===================================================================

  /**
   * Una corrida: toma eventos pendientes de a uno (transaccion corta,
   * `FOR UPDATE SKIP LOCKED` para no pisarse con otra instancia ni con el
   * ETL) y los aplica a Neo4j hasta vaciar la cola o llegar al tope.
   *
   * Si el evento falla por un problema de DATOS (Cypher invalido, dato
   * torcido) se le suma un intento y se sigue con el resto -- a los 5 queda
   * apartado. Si falla por CONEXION (Neo4j o PostgreSQL caidos) se corta la
   * corrida sin gastar intentos: se reintenta entera en la proxima.
   */
  @Interval('grafo-outbox', GrafoSyncService.INTERVALO_MS)
  async vaciarCola(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      await this.procesarPendientes(true);
    } finally {
      this.procesando = false;
    }
  }

  /**
   * Igual que `vaciarCola()`, pero fuera del reloj de 10s: la llama
   * `ResenasService` justo despues de insertar una resena, para que la
   * proyeccion al grafo no tenga que esperar el proximo tick.
   *
   * A proposito NO comparte el flag `procesando` del intervalo -- mismo
   * motivo que `EventosAutenticacionSyncService.sincronizarAhora()` (bug
   * real encontrado y corregido el 2026-09-15): bajo varias reseñas casi
   * simultaneas, compartir el mutex dejaria a la mayoria de las llamadas
   * sin hacer nada. Es seguro sin mutex porque `procesarUnEvento` ya toma
   * cada fila con `FOR UPDATE SKIP LOCKED` -- dos corridas superpuestas se
   * reparten la cola sin pisarse -- y ademas la proyeccion es idempotente
   * (`MERGE`), asi que ni siquiera hace falta que `SKIP LOCKED` sea
   * perfecto para que esto sea correcto.
   *
   * No corre la poda (`ejecutarPoda: false`): esa sigue atada solo al
   * ritmo del intervalo, no a cada reseña.
   */
  async procesarAhora(): Promise<void> {
    await this.procesarPendientes(false);
  }

  /**
   * Una corrida: toma eventos pendientes de a uno (transaccion corta,
   * `FOR UPDATE SKIP LOCKED` para no pisarse con otra instancia ni con el
   * ETL) y los aplica a Neo4j hasta vaciar la cola o llegar al tope.
   *
   * Si el evento falla por un problema de DATOS (Cypher invalido, dato
   * torcido) se le suma un intento y se sigue con el resto -- a los 5 queda
   * apartado. Si falla por CONEXION (Neo4j o PostgreSQL caidos) se corta la
   * corrida sin gastar intentos: se reintenta entera en la proxima.
   */
  private async procesarPendientes(ejecutarPoda: boolean): Promise<void> {
    let cliente: PoolClient | null = null;
    try {
      cliente = await pool.connect();

      let aplicados = 0;
      for (let i = 0; i < GrafoSyncService.MAX_POR_CORRIDA; i++) {
        const hubo = await this.procesarUnEvento(cliente);
        if (!hubo) {
          break;
        }
        aplicados++;
      }

      if (aplicados > 0) {
        this.logger.log(`worker del grafo: ${aplicados} evento(s) aplicados`);
      }

      if (ejecutarPoda && this.corridas++ % GrafoSyncService.PODA_CADA === 0) {
        await this.podar(cliente);
      }
    } catch (error) {
      if ((error as { code?: string })?.code === '42P01') {
        // La tabla `evento_grafo` todavia no existe (falta la migracion
        // 015). No hay nada que hacer; se avisa una sola vez y no en cada
        // corrida.
        if (!this.avisoTablaAusente) {
          this.logger.warn(
            'worker del grafo: la tabla evento_grafo no existe todavia (falta la migracion 015). El worker queda inactivo hasta que exista.',
          );
          this.avisoTablaAusente = true;
        }
        return;
      }
      // Un fallo de conexion (Neo4j o PostgreSQL) corta la corrida aca. No
      // se pierde nada: los eventos que no se alcanzaron a procesar siguen
      // pendientes y se reintentan en la proxima corrida.
      this.logger.warn(
        `worker del grafo: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      cliente?.release();
    }
  }

  /**
   * Procesa el evento pendiente mas viejo. `false` si la cola esta vacia
   * (nada mas que hacer en esta corrida).
   *
   * Cada evento va en su propia transaccion corta: el `FOR UPDATE SKIP
   * LOCKED` mantiene el candado solo mientras se aplica ESE evento a Neo4j
   * (~decenas de ms), no todo el lote.
   */
  private async procesarUnEvento(cliente: PoolClient): Promise<boolean> {
    await cliente.query('BEGIN');
    try {
      const { rows } = await cliente.query<{
        id_evento: string;
        id_resena: string;
      }>(
        `SELECT id_evento, id_resena
           FROM evento_grafo
          WHERE procesado_en IS NULL AND intentos < $1
          ORDER BY id_evento
          LIMIT 1
          FOR UPDATE SKIP LOCKED`,
        [GrafoSyncService.MAX_INTENTOS],
      );

      if (rows.length === 0) {
        await cliente.query('ROLLBACK');
        return false;
      }

      const { id_evento, id_resena } = rows[0];

      try {
        await this.proyectarResena(cliente, id_resena);
        await cliente.query(
          `UPDATE evento_grafo SET procesado_en = now() WHERE id_evento = $1`,
          [id_evento],
        );
        await cliente.query('COMMIT');
        return true;
      } catch (error) {
        if (esFalloDeConexionGrafo(error)) {
          // Neo4j (o PostgreSQL) caido: no es culpa del evento. Se deja
          // pendiente y se corta la corrida para reintentar entera luego.
          await cliente.query('ROLLBACK');
          throw error;
        }
        // Dato torcido / Cypher invalido: culpa del evento. Se le suma un
        // intento y se sigue con el resto de la cola. A los 5 queda
        // apartado y lo reporta la conciliacion.
        await cliente.query('ROLLBACK');
        await cliente.query('BEGIN');
        await cliente.query(
          `UPDATE evento_grafo
              SET intentos = intentos + 1, ultimo_error = $2
            WHERE id_evento = $1`,
          [id_evento, mensajeCorto(error)],
        );
        await cliente.query('COMMIT');
        this.logger.warn(
          `evento ${id_evento} (resena ${id_resena}): ${mensajeCorto(error)}`,
        );
        return true;
      }
    } catch (error) {
      await cliente.query('ROLLBACK').catch(() => undefined);
      throw error;
    }
  }

  /**
   * Proyecta UNA resena al grafo. Relee su estado ACTUAL de PostgreSQL (el
   * evento solo trae el id):
   *
   *  - si la resena existe -> `MERGE` del nodo `:Resena`, sus dos `:Usuario`
   *    (autor y vendedor), sus `:Direccion` + `[:VIVE_EN]`, el `:Producto`,
   *    y las tres relaciones `ESCRIBIO` / `CALIFICA_A` / `SOBRE`. Un
   *    comprador que resena por primera vez todavia no tiene nodo, por eso
   *    se hace `MERGE` de los participantes tambien.
   *  - si la resena ya no existe -> `MATCH (r:Resena {id}) DETACH DELETE r`.
   *
   * Todo con `MERGE`: reaplicar el mismo evento no cambia nada (el patron es
   * "al menos una vez").
   */
  private async proyectarResena(
    cliente: PoolClient,
    idResena: string,
  ): Promise<void> {
    const { rows } = await cliente.query<FilaResenaGrafo>(SQL_RESENA, [
      idResena,
    ]);

    if (rows.length === 0) {
      await ejecutarGrafo('MATCH (r:Resena {id: $id}) DETACH DELETE r', {
        id: neo4j.int(idResena),
      });
      return;
    }

    const f = rows[0];
    const { rows: dirs } = await cliente.query<FilaDireccionGrafo>(
      SQL_DIRECCIONES,
      [[f.autor_id, f.vendedor_id]],
    );

    await ejecutarGrafo(CYPHER_PROYECTAR_RESENA, {
      id_resena: neo4j.int(idResena),
      calificacion: neo4j.int(f.calificacion),
      fecha: f.fecha,
      texto: f.texto,
      autor_id: neo4j.int(f.autor_id),
      autor_usuario: f.autor_usuario,
      autor_correo: f.autor_correo,
      autor_nombre: f.autor_nombre,
      autor_apellido: f.autor_apellido,
      autor_alta: f.autor_alta,
      vendedor_id: neo4j.int(f.vendedor_id),
      vendedor_usuario: f.vendedor_usuario,
      vendedor_correo: f.vendedor_correo,
      vendedor_nombre: f.vendedor_nombre,
      vendedor_apellido: f.vendedor_apellido,
      vendedor_alta: f.vendedor_alta,
      producto_id: neo4j.int(f.producto_id),
      producto_nombre: f.producto_nombre,
      direcciones: dirs.map((d) => ({
        clave: d.clave,
        pais: d.pais,
        departamento: d.departamento,
        ciudad: d.ciudad,
        exacta: d.exacta,
        tiene_calle: d.tiene_calle,
        id_usuario: neo4j.int(d.id_usuario),
      })),
    });
  }

  /**
   * Borra de la cola lo ya procesado hace mas de `RETENCION_DIAS` dias. El
   * `procesado_en IS NOT NULL` no es opcional: sin el, una poda por fecha se
   * llevaria pendientes viejos, justo los que mas falta hacen.
   */
  private async podar(cliente: PoolClient): Promise<void> {
    try {
      const { rowCount } = await cliente.query(
        `DELETE FROM evento_grafo
          WHERE procesado_en IS NOT NULL
            AND procesado_en < now() - ($1 || ' days')::interval`,
        [String(GrafoSyncService.RETENCION_DIAS)],
      );
      if (rowCount && rowCount > 0) {
        this.logger.log(
          `worker del grafo: podados ${rowCount} evento(s) viejos`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `worker del grafo: no se pudo podar la cola -- ${mensajeCorto(error)}`,
      );
    }
  }

  /**
   * Compara PostgreSQL (la verdad) contra Neo4j (la proyeccion) y arma el
   * informe. Lo que de verdad importa es que **cada resena de PostgreSQL
   * tenga su nodo completo en el grafo**: eso se ve en la fila de resenas y
   * en las tres de relaciones (`cuenta_para_veredicto: true`). Los nodos de
   * producto/usuario se informan pero no tumban el veredicto -- el worker
   * incremental puede dejar huerfanos y el ETL completo carga de mas.
   */
  async conciliar(): Promise<ConciliacionGrafo> {
    const [pg, grafo] = await conLimiteDeTiempo(
      Promise.all([this.contarPostgres(), this.contarGrafo()]),
      GrafoSyncService.LIMITE_MS,
      'la conciliacion del grafo',
    );

    const cola = await this.estadoCola('evento_grafo');
    const colaCompras = await this.estadoCola('evento_grafo_compra');
    const eventosApartados = await this.eventosApartados();

    const comparacion: FilaConciliacion[] = [
      fila('resenas', pg.resenas, grafo.resenas, true),
      fila('relacion ESCRIBIO', pg.resenas, grafo.escribio, true),
      fila('relacion CALIFICA_A', pg.resenas, grafo.califica_a, true),
      fila('relacion SOBRE', pg.resenas, grafo.sobre, true),
      fila('compras', pg.compras, grafo.compras, true),
      fila('productos resenados', pg.productos, grafo.productos, false),
      fila('usuarios con resena', pg.participantes, grafo.usuarios, false),
    ];

    const cuadra = comparacion
      .filter((f) => f.cuenta_para_veredicto)
      .every((f) => f.diferencia === 0);

    // Hay algo que decir cuando el grafo NO cuadra, o cuando cuadra pero
    // quedaron eventos apartados (la cola tiene filas atascadas que un
    // humano deberia mirar, aunque los conteos den bien).
    const hayQueDecirAlgo = !cuadra || eventosApartados.length > 0;

    return {
      cuadra,
      verificado_en: new Date().toISOString(),
      ultima_sincronizacion: cola?.ultimaSincronizacion ?? null,
      cola: cola?.estado ?? null,
      cola_compras: colaCompras?.estado ?? null,
      comparacion,
      eventos_apartados: eventosApartados,
      sugerencia: hayQueDecirAlgo
        ? this.sugerencia(
            cuadra,
            comparacion,
            cola?.estado ?? null,
            eventosApartados,
          )
        : null,
    };
  }

  // -------------------------------------------------------------------
  // PostgreSQL: lo que el grafo DEBERIA tener
  // -------------------------------------------------------------------

  private async contarPostgres(): Promise<ContadoresPostgres> {
    try {
      const { rows } = await pool.query<{
        resenas: string;
        productos: string;
        participantes: string;
        compras: string;
      }>(
        `SELECT
           (SELECT count(*) FROM resena)                          AS resenas,
           (SELECT count(DISTINCT id_producto_mongo) FROM resena) AS productos,
           (SELECT count(*) FROM (
              SELECT id_usuario          FROM resena
              UNION
              SELECT id_usuario_vendedor FROM resena
            ) p)                                                  AS participantes,
           (SELECT count(*)
                FROM pedido pe
                JOIN estado_pedido e ON e.id_estado_pedido = pe.id_estado_pedido
                JOIN pedido_producto pp ON pp.id_pedido = pe.id_pedido
               WHERE e.estado_pedido_nombre = ANY($1::text[]))     AS compras`,
        [ESTADOS_DE_COMPRA],
      );
      return {
        resenas: Number(rows[0].resenas),
        productos: Number(rows[0].productos),
        participantes: Number(rows[0].participantes),
        compras: Number(rows[0].compras),
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  // -------------------------------------------------------------------
  // Neo4j: lo que el grafo TIENE
  // -------------------------------------------------------------------

  private async contarGrafo(): Promise<ContadoresGrafo> {
    try {
      // Cada CALL {} con solo agregacion devuelve exactamente una fila, asi
      // que el resultado es una sola fila aunque alguna etiqueta este vacia
      // (con MATCH suelto, un label sin nodos cortaria la consulta entera).
      const filas = await consultarGrafo<Record<string, unknown>>(`
        CALL { MATCH (r:Resena)            RETURN count(r) AS resenas }
        CALL { MATCH (p:Producto)          RETURN count(p) AS productos }
        CALL { MATCH (u:Usuario)           RETURN count(u) AS usuarios }
        CALL { MATCH ()-[e:ESCRIBIO]->()   RETURN count(e) AS escribio }
        CALL { MATCH ()-[c:CALIFICA_A]->() RETURN count(c) AS califica_a }
        CALL { MATCH ()-[s:SOBRE]->()      RETURN count(s) AS sobre }
        CALL { MATCH (k:Compra)            RETURN count(k) AS compras }
        RETURN resenas, productos, usuarios, escribio, califica_a, sobre, compras
      `);
      const f = filas[0] ?? {};
      return {
        resenas: aEntero(f.resenas),
        productos: aEntero(f.productos),
        usuarios: aEntero(f.usuarios),
        escribio: aEntero(f.escribio),
        califica_a: aEntero(f.califica_a),
        sobre: aEntero(f.sobre),
        compras: aEntero(f.compras),
      };
    } catch (error) {
      manejarErrorGrafo(this.logger, error);
    }
  }

  // -------------------------------------------------------------------
  // La cola del outbox (`evento_grafo`) -- puede no existir todavia
  // -------------------------------------------------------------------

  /**
   * `null` si la tabla de la cola aun no existe (las migraciones las hace el
   * companero; en local estan aplicadas por los `.sql` de referencia). Que
   * falte NO es un error: la conciliacion sigue siendo util sin la cola.
   */
  private async estadoCola(
    tabla: 'evento_grafo' | 'evento_grafo_compra',
  ): Promise<{
    estado: EstadoColaGrafo;
    ultimaSincronizacion: string | null;
  } | null> {
    try {
      const { rows } = await pool.query<{
        pendientes: string;
        apartados: string;
        ultima_sincronizacion: Date | null;
      }>(
        `SELECT
           count(*) FILTER (WHERE procesado_en IS NULL AND intentos < 5)  AS pendientes,
           count(*) FILTER (WHERE procesado_en IS NULL AND intentos >= 5) AS apartados,
           max(procesado_en)                                              AS ultima_sincronizacion
         FROM ${tabla}`,
      );
      return {
        estado: {
          pendientes: Number(rows[0].pendientes),
          apartados: Number(rows[0].apartados),
        },
        ultimaSincronizacion:
          rows[0].ultima_sincronizacion?.toISOString() ?? null,
      };
    } catch (error) {
      if ((error as { code?: string })?.code === '42P01') {
        this.logger.warn(
          `La tabla ${tabla} todavia no existe (falta su migracion): la conciliacion va sin esa cola`,
        );
        return null;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  private async eventosApartados(): Promise<EventoGrafoApartado[]> {
    try {
      const { rows } = await pool.query<{
        id_evento: string;
        id_resena: string;
        intentos: number;
        ultimo_error: string | null;
        fecha: Date;
      }>(
        `SELECT id_evento, id_resena, intentos, ultimo_error, fecha
           FROM evento_grafo
          WHERE procesado_en IS NULL AND intentos >= 5
          ORDER BY id_evento
          LIMIT 100`,
      );
      return rows.map((r) => ({
        id_evento: Number(r.id_evento),
        id_resena: Number(r.id_resena),
        intentos: r.intentos,
        ultimo_error: r.ultimo_error,
        fecha: r.fecha.toISOString(),
      }));
    } catch (error) {
      if ((error as { code?: string })?.code === '42P01') {
        return [];
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  // -------------------------------------------------------------------
  // La frase de "qué hacer"
  // -------------------------------------------------------------------

  private sugerencia(
    cuadra: boolean,
    comparacion: FilaConciliacion[],
    cola: EstadoColaGrafo | null,
    apartados: EventoGrafoApartado[],
  ): string {
    const faltan = comparacion.filter(
      (f) => f.cuenta_para_veredicto && f.diferencia < 0,
    );
    const sobran = comparacion.filter(
      (f) => f.cuenta_para_veredicto && f.diferencia > 0,
    );

    const partes: string[] = [];

    if (!cuadra) {
      if (faltan.length > 0) {
        partes.push(
          `Al grafo le faltan datos: ${faltan
            .map((f) => `${-f.diferencia} en ${f.recurso}`)
            .join(', ')}.`,
        );
      }
      if (sobran.length > 0) {
        partes.push(
          `El grafo tiene de mas: ${sobran
            .map((f) => `${f.diferencia} en ${f.recurso}`)
            .join(
              ', ',
            )} (posibles resenas borradas en PostgreSQL que siguen en el grafo).`,
        );
      }

      if ([...faltan, ...sobran].some((f) => f.recurso === 'compras')) {
        partes.push(
          'Las compras no las carga `etl/cargar_grafo.sh`: para rehacerlas, encola todas las cuentas con la siembra del final de `plan pendiente/grafo-compras.sql`.',
        );
      }

      if (cola != null && cola.pendientes > 0) {
        partes.push(
          `Hay ${cola.pendientes} evento(s) pendiente(s) en la cola: si el numero no baja solo en unos minutos, corre \`etl/cargar_grafo.sh --limpiar\`.`,
        );
      } else {
        partes.push(
          'Corre `etl/cargar_grafo.sh --limpiar` para reconstruir el grafo desde PostgreSQL.',
        );
      }
    } else {
      partes.push('Los conteos cuadran.');
    }

    if (apartados.length > 0) {
      partes.push(
        `Hay ${apartados.length} evento(s) apartado(s) que fallaron 5 veces y no se van a reintentar: revisa \`eventos_apartados\` (si apuntan a resenas que ya no existen, se pueden borrar de \`evento_grafo\`).`,
      );
    }

    return partes.join(' ');
  }
}

// =====================================================================
// Utilidades
// =====================================================================

interface ContadoresPostgres {
  resenas: number;
  productos: number;
  participantes: number;
  /** Lineas de pedido compradas (una `:Compra` cada una). */
  compras: number;
}

interface ContadoresGrafo {
  resenas: number;
  productos: number;
  usuarios: number;
  escribio: number;
  califica_a: number;
  sobre: number;
  compras: number;
}

function fila(
  recurso: string,
  postgres: number,
  neo4jValor: number,
  cuentaParaVeredicto: boolean,
): FilaConciliacion {
  return {
    recurso,
    postgres,
    neo4j: neo4jValor,
    diferencia: neo4jValor - postgres,
    cuenta_para_veredicto: cuentaParaVeredicto,
  };
}

/**
 * Neo4j devuelve los enteros como su tipo `Integer` de 64 bits. Los conteos
 * de este dominio son chicos: se pasan a `number` sin riesgo. Mismo criterio
 * que `base-datos-grafo.service.ts`.
 */
function aEntero(valor: unknown): number {
  if (neo4j.isInt(valor)) {
    return (valor as { toNumber(): number }).toNumber();
  }
  return typeof valor === 'number' ? valor : 0;
}

/** Un mensaje de error corto para guardar en `evento_grafo.ultimo_error` / loguear. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 500 ? `${texto.slice(0, 497)}...` : texto;
}

// =====================================================================
// El worker: lo que se relee de PostgreSQL por evento, y el Cypher
// =====================================================================

/** Una fila de `SQL_RESENA`: todo lo que el grafo necesita de una resena. */
interface FilaResenaGrafo {
  calificacion: number;
  /** ISO 8601 UTC con microsegundos y `Z` (de `to_char`), para `datetime()`. */
  fecha: string;
  texto: string;
  autor_id: string;
  autor_usuario: string;
  autor_correo: string;
  autor_nombre: string;
  autor_apellido: string | null;
  autor_alta: string;
  vendedor_id: string;
  vendedor_usuario: string;
  vendedor_correo: string;
  vendedor_nombre: string;
  vendedor_apellido: string | null;
  vendedor_alta: string;
  producto_id: string;
  producto_nombre: string;
}

/** Una fila de `SQL_DIRECCIONES`: un domicilio distinto de un usuario. */
interface FilaDireccionGrafo {
  id_usuario: string;
  clave: string;
  pais: string;
  departamento: string;
  ciudad: string;
  exacta: string | null;
  tiene_calle: boolean;
}

/**
 * Todo lo que el grafo necesita de UNA resena, releído de PostgreSQL. Las
 * fechas salen en UTC con microsegundos vía `to_char` (no como `Date` de
 * JS, que perdería precisión) para que `datetime()` de Cypher las tome
 * igual que el ETL. El nombre de producto tiene el mismo relleno que
 * `etl/extraer_grafo.sql` cuando el producto solo vive en MongoDB.
 */
const SQL_RESENA = `
  SELECT
    r.calificacion,
    to_char(c.fecha_publicacion AT TIME ZONE 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')            AS fecha,
    c.comentario                                        AS texto,
    r.id_usuario::text                                  AS autor_id,
    ua.usuario                                          AS autor_usuario,
    ua.correo_electronico                               AS autor_correo,
    ua.nombre                                           AS autor_nombre,
    ua.apellido                                         AS autor_apellido,
    to_char(ua.fecha_creacion AT TIME ZONE 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')            AS autor_alta,
    r.id_usuario_vendedor::text                         AS vendedor_id,
    uv.usuario                                          AS vendedor_usuario,
    uv.correo_electronico                               AS vendedor_correo,
    uv.nombre                                           AS vendedor_nombre,
    uv.apellido                                         AS vendedor_apellido,
    to_char(uv.fecha_creacion AT TIME ZONE 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')            AS vendedor_alta,
    r.id_producto_mongo::text                           AS producto_id,
    COALESCE(p.nombre,
             'Producto ' || r.id_producto_mongo || ' (solo en MongoDB)')
                                                        AS producto_nombre
  FROM resena r
  JOIN comentario c ON c.id_comentario = r.id_comentario
  JOIN usuarios ua  ON ua.id_usuario   = r.id_usuario
  JOIN usuarios uv  ON uv.id_usuario   = r.id_usuario_vendedor
  LEFT JOIN productos p ON p.id_producto = r.id_producto_mongo
  WHERE r.id_resena = $1
`;

/**
 * Los domicilios DISTINTOS de un conjunto de usuarios, con su clave
 * normalizada.
 *
 * La expresion de la clave (`translate` de las 14 letras acentuadas,
 * minusculas, espacios colapsados) es una COPIA VERBATIM de
 * `pg_temp.clave_direccion` de `etl/extraer_grafo.sql` -- tiene que producir
 * exactamente la misma clave, o el mismo domicilio caeria en dos nodos
 * `:Direccion` distintos segun quien lo cargo. Verificado: da la misma clave
 * en las 2 direcciones del conjunto de datos. Si esa funcion del ETL cambia,
 * hay que cambiar esta a la par.
 */
const SQL_DIRECCIONES = `
  WITH claves AS (
    SELECT
      id_usuario,
      lower(regexp_replace(trim(translate(
        coalesce(pais, '') || '|' || coalesce(departamento, '') || '|' ||
        coalesce(ciudad, '') || '|' || coalesce(direccion_exacta, ''),
        chr(225) || chr(233) || chr(237) || chr(243) || chr(250) ||
        chr(252) || chr(241) || chr(193) || chr(201) || chr(205) ||
        chr(211) || chr(218) || chr(220) || chr(209),
        'aeiouunAEIOUUN')), '\\s+', ' ', 'g'))               AS clave,
      pais, departamento, ciudad, direccion_exacta
    FROM direcciones
    WHERE id_usuario = ANY($1)
  )
  SELECT
    id_usuario::text                                          AS id_usuario,
    clave,
    min(pais)          AS pais,
    min(departamento)  AS departamento,
    min(ciudad)        AS ciudad,
    min(direccion_exacta) AS exacta,
    bool_or(direccion_exacta IS NOT NULL
            AND btrim(direccion_exacta) <> '')                AS tiene_calle
  FROM claves
  GROUP BY id_usuario, clave
`;

/**
 * Proyecta una resena y su vecindario al grafo, en una sola sentencia.
 * Todo `MERGE` (idempotente). El orden -- nodos antes que relaciones -- no
 * es estetico: `MERGE (a)-[:ESCRIBIO]->(r)` necesita que `a` y `r` existan.
 *
 * `UNWIND $direcciones AS d` con la lista vacia no hace nada, y los `MERGE`
 * de arriba se aplican igual (verificado). Un comprador sin domicilio
 * declarado simplemente no tiene `[:VIVE_EN]`, igual que en el ETL.
 *
 * Mismo modelo y mismas propiedades que `etl/extraer_grafo.sql`:
 *   (:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
 *                           (:Resena)-[:SOBRE]->(:Producto)
 *             (:Usuario)-[:VIVE_EN]->(:Direccion)
 */
const CYPHER_PROYECTAR_RESENA = `
MERGE (a:Usuario {id: $autor_id})
  SET a.correo = $autor_correo, a.usuario = $autor_usuario,
      a.nombre = $autor_nombre, a.apellido = $autor_apellido,
      a.fecha_alta = datetime($autor_alta)
MERGE (v:Usuario {id: $vendedor_id})
  SET v.correo = $vendedor_correo, v.usuario = $vendedor_usuario,
      v.nombre = $vendedor_nombre, v.apellido = $vendedor_apellido,
      v.fecha_alta = datetime($vendedor_alta)
MERGE (p:Producto {id: $producto_id})
  SET p.nombre = $producto_nombre
MERGE (r:Resena {id: $id_resena})
  SET r.calificacion = $calificacion, r.fecha = datetime($fecha), r.texto = $texto
MERGE (a)-[:ESCRIBIO]->(r)
MERGE (r)-[:CALIFICA_A]->(v)
MERGE (r)-[:SOBRE]->(p)
WITH r
UNWIND $direcciones AS d
  MERGE (dir:Direccion {clave: d.clave})
    SET dir.pais = d.pais, dir.departamento = d.departamento,
        dir.ciudad = d.ciudad, dir.exacta = d.exacta,
        dir.tiene_calle = d.tiene_calle
  WITH dir, d
  MATCH (u:Usuario {id: d.id_usuario})
  MERGE (u)-[:VIVE_EN]->(dir)
`;
