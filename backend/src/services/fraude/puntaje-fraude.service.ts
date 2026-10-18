import { Injectable } from '@nestjs/common';
import { GrupoFraude } from '../../models/fraude/grupo-fraude';
import { Hallazgo } from '../../models/fraude/hallazgo';

/**
 * Puntos base por tipo (seccion 3 de `docs/fraude-entrega3/02-reglas-backend.md`).
 * `reputacion_expres` aca guarda el PISO de su rango -- el valor real
 * depende de los minutos de vida del autor, que `PatronesFraudeDetectorService`
 * guarda en `senal_fraude.detalle`; el piso solo se usa si la metrica no vino
 * (`Number.isFinite` falla). `mutuo`/`reiterado` suman ademas el bono de ida y
 * vuelta (lo que antes era `favor_devuelto`). Los bonos de B.4 (ciclo/mutuo/
 * reiterado, `bonoB4` mas abajo) siguen sin conectar a proposito -- alcance
 * dejado para despues.
 */
const PUNTOS_BASE: Record<string, number> = {
  ciclo: 30,
  reiterado: 30,
  mutuo: 15,
  satelites: 25, // "granja", B.2
  coordinados: 20,
  reputacion_expres: 10, // piso del rango 20/10
  persistente: 15,
  resenas_repetidas: 15, // cuenta con 5+ resenas casi iguales (texto, pgvector)
  anillo_de_texto: 25, // 3+ cuentas con resenas casi iguales sobre un vendedor (texto, pgvector)
  resena_positiva_cancelada: 20, // resena de 4-5 estrellas y la compra cancelada (reembolsada) poco despues (pedidos, PostgreSQL)
  notas_incoherentes_cuenta: 10, // 5+ y 20 %+ de sus resenas con el texto contrario a las estrellas (texto, pgvector)
  ip_multicuenta_compras: 20, // F3
  granja_de_registros: 20, // F6
  compras_en_rafaga: 15, // F2
  devoluciones_seriales: 10, // F5
  multi_cuenta_ip: 10,
  multi_cuenta_ip_lenta: 10,
  ip_rotacion_cuenta: 5,
  ip_rotacion_cuenta_lenta: 5,
};

/** La recencia deja de bajar despues de este numero de dias sin
 * evidencia nueva (seccion 3, punto 4). */
const DIAS_RECENCIA = 30;
const PISO_RECENCIA = 0.5;
/** Cada hallazgo extra del MISMO tipo suma el 20% de sus propios puntos,
 * sin pasar del doble del que mas vale (seccion 3, punto 1). */
const FACTOR_REPETICION = 0.2;
const TOPE_REPETICION = 2;

/**
 * Paso 3 (mitad puntaje) del agrupador de casos de fraude: el calculo de
 * `caso_fraude.puntaje` a partir de un `GrupoFraude` ya armado por
 * `AgrupadorFraudeService`. Puro -- no toca la base, solo aritmetica
 * sobre lo que ya trae el grupo.
 *
 * Verificado a mano contra el ejemplo del "Caso 1" del documento
 * original (el unico con el paso a paso completo): ciclo 30 + bono B.4
 * (invisible hoy +10, orden secuencial +5) = 45; reiterado 30 + los
 * mismos bonos = 45; favor devuelto en 1.48h (tier 12) = 12 (hoy es el bono
 * de ida y vuelta del par, no un hallazgo aparte); suma 87 (sin
 * contar "misma casa con calle", que no tiene detector todavia, ver
 * `TIPOS_FUERTES` en el agrupador); un solo motor, factor 1; ultima
 * evidencia a 199 dias, recencia al piso 0.5. El documento suma 112
 * incluyendo los 10 de "misma casa" que aca todavia no se pueden producir
 * -- coincide exacto una vez se le suman esos 10 (112 * 0.5 = 56, el
 * mismo puntaje que reporta el documento).
 */
@Injectable()
export class PuntajeFraudeService {
  calcular(grupo: GrupoFraude): number {
    const puntosPorTipo = this.agruparPorTipo(grupo.hallazgos);
    const sumaPorTipos = [...puntosPorTipo.values()].reduce(
      (total, puntos) => total + puntos,
      0,
    );

    return (
      sumaPorTipos *
      this.factorDiversidad(grupo.hallazgos) *
      this.factorRecencia(grupo.hallazgos)
    );
  }

  /** Por cada tipo, el hallazgo que mas vale, mas el 20% de cada uno de
   * los demas del mismo tipo, sin pasar del doble del que mas vale --
   * asi un triangulo que aparece por tres pares no cuenta tres veces. */
  private agruparPorTipo(hallazgos: Hallazgo[]): Map<string, number> {
    const porTipo = new Map<string, number[]>();
    for (const hallazgo of hallazgos) {
      const lista = porTipo.get(hallazgo.tipo) ?? [];
      lista.push(this.puntosDeHallazgo(hallazgo));
      porTipo.set(hallazgo.tipo, lista);
    }

    const resultado = new Map<string, number>();
    for (const [tipo, puntos] of porTipo) {
      const ordenados = [...puntos].sort((a, b) => b - a);
      const maximo = ordenados[0];
      const extra = ordenados
        .slice(1)
        .reduce((total, valor) => total + valor * FACTOR_REPETICION, 0);
      resultado.set(tipo, Math.min(maximo + extra, maximo * TOPE_REPETICION));
    }
    return resultado;
  }

  /** Cuanto vale ESTE hallazgo por si solo (antes del descuento por
   * repeticion del mismo tipo, que se aplica al agrupar) -- publico
   * porque `PersistenciaCasoFraudeService` lo necesita para guardar
   * `evidencia_caso_fraude.puntos` (el aporte de un hallazgo individual,
   * no el total del caso). */
  puntosDeHallazgo(hallazgo: Hallazgo): number {
    if (hallazgo.tipo === 'reputacion_expres') {
      return this.puntosReputacionExpres(hallazgo.metricas);
    }

    let puntos = PUNTOS_BASE[hallazgo.tipo] ?? 0;
    if (
      hallazgo.fuente === 'grafo' &&
      (hallazgo.tipo === 'ciclo' ||
        hallazgo.tipo === 'mutuo' ||
        hallazgo.tipo === 'reiterado')
    ) {
      puntos += this.bonoB4(hallazgo.metricas);
    }
    if (hallazgo.tipo === 'mutuo' || hallazgo.tipo === 'reiterado') {
      puntos += this.bonoIdaYVuelta(hallazgo.metricas);
    }
    if (hallazgo.tipo === 'persistente') {
      puntos += this.bonoPersistente(hallazgo.metricas);
    }
    return puntos;
  }

  /** El par se devolvio la nota: +20 si tardo menos de 1 hora, +12 si
   * menos de 24, +8 si menos de 72, nada si mas -- lee `metricas.horas`. */
  private bonoIdaYVuelta(metricas: Record<string, unknown>): number {
    const horas = metricas.horas;
    if (typeof horas !== 'number' || !Number.isFinite(horas)) return 0;
    if (horas < 1) return 20;
    if (horas < 24) return 12;
    if (horas < 72) return 8;
    return 0;
  }

  /** 20 si el autor de la resena tenia menos de 60 minutos de vida, 10 si
   * no -- lee `metricas.autor_minutos_vida`. */
  private puntosReputacionExpres(metricas: Record<string, unknown>): number {
    const minutos = Number(metricas.autor_minutos_vida);
    return Number.isFinite(minutos) && minutos < 60 ? 20 : 10;
  }

  /** B.4: +10 si el anillo tuvo 2+ olas, +10 si el detector de hoy ya no
   * lo ve, +5 si la ronda va en orden -- lee `metricas.olas`,
   * `metricas.invisible_hoy`, `metricas.orden_secuencial`. */
  private bonoB4(metricas: Record<string, unknown>): number {
    let bono = 0;
    if (Number(metricas.olas) >= 2) bono += 10;
    if (metricas.invisible_hoy === true) bono += 10;
    if (metricas.orden_secuencial === true) bono += 5;
    return bono;
  }

  /**
   * +10 si es mutuo, +5 si la regularidad es menor que 0.2 -- lee
   * `metricas.es_mutuo`, `metricas.regularidad`.
   *
   * **Bug corregido (2026-09-27, "menores" de `docs/BACKEND-PENDIENTE.md`):**
   * cuando B.3 calcula la regularidad con una media de 0 (un solo
   * intervalo, o varios identicos), Neo4j devuelve `NaN`. `JSON.stringify`
   * convierte ese `NaN` en el literal `null` al guardarlo en
   * `anillo_fraude.detalle`, y `Number(null)` da `0` -- finito y menor a
   * 0.2 -- asi que el viejo `Number(metricas.regularidad)` sumaba el bono
   * de "regular" sobre un dato que en realidad no existia. Ahora se exige
   * `typeof === 'number'` ANTES de mirar si es finito: un `null` (o
   * cualquier otra cosa que no sea numero) nunca llega a `< 0.2`.
   */
  private bonoPersistente(metricas: Record<string, unknown>): number {
    let bono = 0;
    if (metricas.es_mutuo === true) bono += 10;
    const regularidad = metricas.regularidad;
    if (
      typeof regularidad === 'number' &&
      Number.isFinite(regularidad) &&
      regularidad < 0.2
    ) {
      bono += 5;
    }
    return bono;
  }

  /** 1 si toda la evidencia viene de un solo motor, 1.3 de dos, 1.6 de
   * tres. */
  private factorDiversidad(hallazgos: Hallazgo[]): number {
    const fuentes = new Set(hallazgos.map((hallazgo) => hallazgo.fuente));
    if (fuentes.size >= 3) return 1.6;
    if (fuentes.size === 2) return 1.3;
    return 1;
  }

  /** 0.5 elevado a (dias desde la ultima evidencia / 30), sin bajar de
   * 0.5 -- el piso es a proposito, un caso viejo no se apaga del todo. */
  private factorRecencia(hallazgos: Hallazgo[]): number {
    const masReciente = hallazgos.reduce(
      (maxima, hallazgo) =>
        hallazgo.ultimaEvidencia > maxima ? hallazgo.ultimaEvidencia : maxima,
      hallazgos[0].ultimaEvidencia,
    );
    const dias = (Date.now() - masReciente.getTime()) / (1000 * 60 * 60 * 24);
    return Math.max(PISO_RECENCIA, Math.pow(0.5, dias / DIAS_RECENCIA));
  }
}
