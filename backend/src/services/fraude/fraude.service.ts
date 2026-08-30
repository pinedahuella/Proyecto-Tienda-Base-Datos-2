import { Injectable, Logger } from '@nestjs/common';
import neo4j from 'neo4j-driver';
import { consultarGrafo } from '../../database/neo4j';
import { conLimiteDeTiempo } from '../../helpers/limite-tiempo';
import { manejarErrorGrafo } from '../../helpers/manejar-error-grafo';
import {
  Anillo,
  AnalisisFraude,
  CuentaSenalada,
  ProductoSenalado,
  ResenaSenalada,
  RespuestaFraude,
  TipoAnillo,
} from '../../models/fraude';

/**
 * El panel de manipulacion de resenas de la Entrega 2 (`GET
 * /admin/fraude/anillos`).
 *
 * Recorre el grafo de Neo4j -- una PROYECCION de la tabla `resena` que carga
 * el ETL `etl/cargar_grafo.sh`, y que el backend solo CONSULTA -- buscando
 * grupos de cuentas cuyo patron de calificaciones no se explica por el uso
 * normal de la tienda.
 *
 * El modelo del grafo, en tres relaciones:
 *
 *     (:Usuario)-[:ESCRIBIO]->(:Resena)-[:CALIFICA_A]->(:Usuario)
 *                             (:Resena)-[:SOBRE]->(:Producto)
 *                             (:Usuario)-[:VIVE_EN]->(:Direccion)
 *
 * Se corren cuatro consultas de deteccion (adaptadas de
 * `neo4j/consultas/A1..A4`, que estan escritas para el visor de linea de
 * comandos y aqui devuelven ya la forma del payload):
 *
 *   - CICLICOS       camino cerrado ESCRIBIO/CALIFICA_A de 4 a 8 saltos. 2
 *                    cuentas -> `mutuo`; 3 o mas -> `ciclo`.  (A.1)
 *   - MISMO_PRODUCTO par que se califica en los dos sentidos sobre el mismo
 *                    producto -> `reiterado`. Tapa al `mutuo` del mismo par:
 *                    es la misma pareja con una senal mas fuerte.  (A.2)
 *   - MISMA_DIRECCION cuentas distintas en un nodo :Direccion con calle ->
 *                    `direccion`. Siempre su propia entrada.  (A.4)
 *   - CONTEO         cuantas cuentas / resenas / relaciones tiene el grafo,
 *                    para el campo `analizado`.
 *
 * La consulta de rafagas (A.3) y el puntaje compuesto (A.5) todavia no se
 * usan aqui -- ver `elementos Generales/endpoints-fraude.md`.
 *
 * NINGUNA de estas consultas PRUEBA fraude: senalan un grupo para que un
 * humano lo mire. Contra los datos sembrados de hoy devuelven vacio, y eso
 * es lo correcto (no hay anillos reales). El `arnes` que demuestra que las
 * consultas sirven es `neo4j/correr_fraude.sh`, que siembra un anillo de
 * mentira.
 */
@Injectable()
export class FraudeService {
  private readonly logger = new Logger(FraudeService.name);

  /** El analisis completo puede tocar varias consultas de varios saltos. */
  private static readonly LIMITE_MS = 15000;

  /** Ventana para llamar "rafaga" a un grupo de resenas: 72 horas. */
  private static readonly VENTANA_RAFAGA_MS = 72 * 60 * 60 * 1000;

  async analizar(): Promise<RespuestaFraude> {
    try {
      const [ciclicos, reiterados, direcciones, conteo] =
        await conLimiteDeTiempo(
          Promise.all([
            consultarGrafo<FilaGrupo>(CYPHER_GRUPOS_CICLICOS),
            consultarGrafo<FilaGrupo>(CYPHER_PARES_MISMO_PRODUCTO),
            consultarGrafo<FilaDireccion>(CYPHER_MISMA_DIRECCION),
            consultarGrafo<FilaConteo>(CYPHER_CONTEO),
          ]),
          FraudeService.LIMITE_MS,
          'Neo4j',
        );

      return {
        anillos: this.armarAnillos(ciclicos, reiterados, direcciones),
        analizado: this.aAnalisis(conteo[0]),
      };
    } catch (error) {
      manejarErrorGrafo(this.logger, error);
    }
  }

  // ---------------------------------------------------------------------
  // Armado de los anillos
  // ---------------------------------------------------------------------

  private armarAnillos(
    ciclicos: FilaGrupo[],
    reiterados: FilaGrupo[],
    direcciones: FilaDireccion[],
  ): Anillo[] {
    // clave (ids ordenados) -> el grupo con su evidencia acumulada. El
    // mismo par puede llegar por varias consultas (o por varias rotaciones
    // del mismo ciclo): se junta, no se duplica.
    const grupos = new Map<string, GrupoCrudo>();

    const registrar = (
      tipo: TipoAnillo,
      cuentas: CuentaCruda[],
      resenas: ResenaCruda[],
      ganaElTipo: boolean,
    ): void => {
      if (cuentas.length < 2) {
        return;
      }
      const clave = claveIds(cuentas);
      const existente = grupos.get(clave);
      if (existente == null) {
        grupos.set(clave, { tipo, cuentas, resenas: [...resenas] });
        return;
      }
      existente.resenas.push(...resenas);
      if (ganaElTipo) {
        existente.tipo = tipo;
        existente.cuentas = cuentas;
      }
    };

    // Primero los ciclicos; luego "reiterado" pisa el tipo del par (misma
    // pareja, senal mas fuerte) conservando la evidencia ya juntada.
    for (const fila of ciclicos) {
      const tipo: TipoAnillo = fila.cuentas.length >= 3 ? 'ciclo' : 'mutuo';
      registrar(tipo, fila.cuentas, fila.resenas, false);
    }
    for (const fila of reiterados) {
      registrar('reiterado', fila.cuentas, fila.resenas, true);
    }

    const anillos = [...grupos.values()].map((grupo) =>
      this.anilloDeResenas(grupo.tipo, grupo.cuentas, grupo.resenas),
    );

    // "direccion" siempre es su propia entrada, aparte de las de resena: son
    // hallazgos distintos aunque toquen a las mismas cuentas.
    for (const fila of direcciones) {
      if (fila.cuentas.length < 2) {
        continue;
      }
      anillos.push(this.anilloDeDireccion(fila));
    }

    return anillos.sort(
      (a, b) =>
        b.senales.length - a.senales.length ||
        b.resenas.length - a.resenas.length ||
        a.id.localeCompare(b.id),
    );
  }

  private anilloDeResenas(
    tipo: TipoAnillo,
    cuentasCrudas: CuentaCruda[],
    resenasCrudas: ResenaCruda[],
  ): Anillo {
    const cuentas = cuentasCrudas.map(aCuenta);
    const resenas = dedupResenas(resenasCrudas);
    const productos = productosDe(resenasCrudas);
    return {
      id: `${tipo}-${idsOrdenados(cuentas).join('-')}`,
      tipo,
      saltos: this.saltos(tipo, cuentas.length),
      cuentas,
      productos,
      resenas,
      senales: this.senalesDeResenas(
        tipo,
        cuentasCrudas,
        cuentas,
        resenas,
        productos,
      ),
    };
  }

  private anilloDeDireccion(fila: FilaDireccion): Anillo {
    const cuentas = fila.cuentas.map(aCuenta);
    const resenas = dedupResenas(fila.resenas);
    return {
      id: `direccion-${idsOrdenados(cuentas).join('-')}`,
      tipo: 'direccion',
      saltos: 2,
      cuentas,
      productos: productosDe(fila.resenas),
      resenas,
      senales: this.senalesDeDireccion(fila, cuentas, resenas),
    };
  }

  /**
   * Cuantos saltos del grafo une a las cuentas.
   *   ciclo / mutuo   Usuario -> Resena -> Usuario por cada cuenta: 2 * N.
   *   reiterado       el par mutuo es un camino de 4 (A->rA->B->rB->A).
   *   direccion       Usuario -> Direccion <- Usuario: 2.
   */
  private saltos(tipo: TipoAnillo, cuentas: number): number {
    if (tipo === 'ciclo' || tipo === 'mutuo') {
      return cuentas * 2;
    }
    if (tipo === 'reiterado') {
      return 4;
    }
    return 2;
  }

  // ---------------------------------------------------------------------
  // Senales (las frases que explican la sospecha)
  // ---------------------------------------------------------------------

  private senalesDeResenas(
    tipo: TipoAnillo,
    cuentasCrudas: CuentaCruda[],
    cuentas: CuentaSenalada[],
    resenas: ResenaSenalada[],
    productos: ProductoSenalado[],
  ): string[] {
    const senales: string[] = [];

    if (tipo === 'ciclo') {
      const camino = cuentas.map((c) => c.usuario).join(' -> ');
      senales.push(
        `La calificacion forma un circulo cerrado entre ${cuentas.length} cuentas: ${camino} -> ${cuentas[0].usuario}`,
      );
    } else if (tipo === 'mutuo') {
      senales.push('Las dos cuentas se calificaron la una a la otra');
    } else if (tipo === 'reiterado') {
      senales.push(
        productos.length <= 1
          ? 'Se califican mutuamente sobre el mismo producto'
          : `Se califican mutuamente sobre ${productos.length} productos en comun`,
      );
    }

    const notas = resenas.map((r) => r.calificacion);
    if (notas.length >= 2 && notas.every((n) => n === 5)) {
      senales.push(`Las ${notas.length} calificaciones son de 5 estrellas`);
    } else if (notas.length >= 2 && notas.every((n) => n >= 4)) {
      senales.push(
        'Todas las calificaciones entre estas cuentas son de 4 o 5 estrellas',
      );
    }

    const ventana = this.ventana(resenas);
    if (ventana != null && ventana.ms <= FraudeService.VENTANA_RAFAGA_MS) {
      senales.push(
        `Las ${resenas.length} resenas se escribieron en un intervalo de ${ventana.texto}`,
      );
    }

    const dia = mismoDiaDeAlta(cuentasCrudas);
    if (dia != null) {
      senales.push(
        `Las ${cuentas.length} cuentas se crearon el mismo dia (${dia})`,
      );
    }

    return senales;
  }

  private senalesDeDireccion(
    fila: FilaDireccion,
    cuentas: CuentaSenalada[],
    resenas: ResenaSenalada[],
  ): string[] {
    const senales: string[] = [];

    const lugar = [fila.exacta, fila.ciudad].filter(Boolean).join(', ');
    senales.push(
      `${cuentas.length} cuentas distintas registradas en la misma direccion${lugar ? `: ${lugar}` : ''}`,
    );

    const dia = mismoDiaDeAlta(fila.cuentas);
    if (dia != null) {
      senales.push(
        `Las ${cuentas.length} cuentas se crearon el mismo dia (${dia})`,
      );
    }

    if (resenas.length > 0) {
      senales.push(
        `Ademas se califican entre si (${resenas.length} ${resenas.length === 1 ? 'resena' : 'resenas'} entre estas cuentas)`,
      );
      if (resenas.every((r) => r.calificacion === 5)) {
        senales.push('Todas esas calificaciones son de 5 estrellas');
      }
    }

    return senales;
  }

  /** El lapso entre la primera y la ultima resena del grupo, si hay al menos dos. */
  private ventana(
    resenas: ResenaSenalada[],
  ): { ms: number; texto: string } | null {
    const instantes = resenas
      .map((r) => Date.parse(r.fecha))
      .filter((n) => Number.isFinite(n));
    if (instantes.length < 2) {
      return null;
    }
    const ms = Math.max(...instantes) - Math.min(...instantes);
    return { ms, texto: duracionLegible(ms) };
  }

  // ---------------------------------------------------------------------
  // Conversion de lo que devuelve el grafo
  // ---------------------------------------------------------------------

  private aAnalisis(fila: FilaConteo | undefined): AnalisisFraude {
    return {
      cuentas: aNumero(fila?.cuentas),
      resenas: aNumero(fila?.resenas),
      relaciones: aNumero(fila?.relaciones),
    };
  }
}

// =====================================================================
// Filas crudas: lo que devuelve cada consulta antes de limpiarse
// =====================================================================

interface CuentaCruda {
  id_usuario: unknown;
  usuario: string;
  correo_electronico: string;
  nombre: string | null;
  apellido: string | null;
  /** ISO 8601 o null; solo se usa para la senal "creadas el mismo dia". */
  fecha_alta: string | null;
}

interface ResenaCruda {
  id_resena: unknown;
  autor: string;
  vendedor: string;
  id_producto: unknown;
  producto: string | null;
  calificacion: unknown;
  fecha: string;
}

interface FilaGrupo {
  cuentas: CuentaCruda[];
  resenas: ResenaCruda[];
}

interface FilaDireccion {
  clave: string;
  ciudad: string | null;
  departamento: string | null;
  exacta: string | null;
  cuentas: CuentaCruda[];
  resenas: ResenaCruda[];
}

interface FilaConteo {
  cuentas: unknown;
  resenas: unknown;
  relaciones: unknown;
}

interface GrupoCrudo {
  tipo: TipoAnillo;
  cuentas: CuentaCruda[];
  resenas: ResenaCruda[];
}

// =====================================================================
// Utilidades
// =====================================================================

/**
 * Neo4j devuelve los enteros como su propio tipo `Integer` (64 bits sin
 * perdida). Los conteos y los ids de este dominio son chicos: se pasan a
 * `number` sin riesgo. Mismo criterio que `base-datos-grafo.service.ts`.
 */
function aNumero(valor: unknown): number {
  if (neo4j.isInt(valor)) {
    return (valor as { toNumber(): number }).toNumber();
  }
  return typeof valor === 'number' ? valor : 0;
}

function aCuenta(cruda: CuentaCruda): CuentaSenalada {
  return {
    id_usuario: aNumero(cruda.id_usuario),
    usuario: cruda.usuario,
    correo_electronico: cruda.correo_electronico,
    nombre: cruda.nombre ?? '',
    apellido: cruda.apellido ?? '',
  };
}

function aResena(cruda: ResenaCruda): ResenaSenalada {
  return {
    id_resena: aNumero(cruda.id_resena),
    autor: cruda.autor,
    vendedor: cruda.vendedor,
    producto: cruda.producto ?? '(producto desconocido)',
    calificacion: aNumero(cruda.calificacion),
    fecha: cruda.fecha,
  };
}

/**
 * Las resenas del grupo, sin repetir por `id_resena` y ordenadas por fecha.
 * El id se acepta si es un entero distinto de 0 -- puede ser NEGATIVO: asi
 * son los ids que siembra `neo4j/correr_fraude.sh` para la demo, y tienen
 * que aparecer en el panel igual que los reales.
 */
function dedupResenas(crudas: ResenaCruda[]): ResenaSenalada[] {
  const porId = new Map<number, ResenaSenalada>();
  for (const cruda of crudas) {
    const resena = aResena(cruda);
    if (
      Number.isInteger(resena.id_resena) &&
      resena.id_resena !== 0 &&
      !porId.has(resena.id_resena)
    ) {
      porId.set(resena.id_resena, resena);
    }
  }
  return [...porId.values()].sort((a, b) => a.fecha.localeCompare(b.fecha));
}

/** Los productos distintos que aparecen en un conjunto de resenas. */
function productosDe(crudas: ResenaCruda[]): ProductoSenalado[] {
  const porId = new Map<number, string>();
  for (const cruda of crudas) {
    const id = aNumero(cruda.id_producto);
    // id != 0 (puede ser negativo: datos sembrados para la demo).
    if (Number.isInteger(id) && id !== 0 && !porId.has(id)) {
      porId.set(id, cruda.producto ?? `Producto ${id}`);
    }
  }
  return [...porId.entries()].map(([id_producto, nombre]) => ({
    id_producto,
    nombre,
  }));
}

/** Los ids de las cuentas, como numero y ordenados: la identidad del grupo. */
function idsOrdenados(cuentas: CuentaSenalada[]): number[] {
  return cuentas.map((c) => c.id_usuario).sort((a, b) => a - b);
}

function claveIds(cuentas: CuentaCruda[]): string {
  return cuentas
    .map((c) => aNumero(c.id_usuario))
    .sort((a, b) => a - b)
    .join('-');
}

/**
 * El dia (`AAAA-MM-DD`) en que se crearon TODAS las cuentas del grupo, si
 * fue el mismo para todas. `null` si alguna no tiene fecha o si difieren.
 */
function mismoDiaDeAlta(cuentas: CuentaCruda[]): string | null {
  const dias = cuentas
    .map((c) =>
      typeof c.fecha_alta === 'string' && c.fecha_alta.length >= 10
        ? c.fecha_alta.slice(0, 10)
        : null,
    )
    .filter((d): d is string => d != null);
  if (dias.length !== cuentas.length || dias.length === 0) {
    return null;
  }
  return new Set(dias).size === 1 ? dias[0] : null;
}

function duracionLegible(ms: number): string {
  const minutos = ms / 60000;
  if (minutos < 60) {
    return cantidad(Math.max(1, Math.round(minutos)), 'minuto', 'minutos');
  }
  const horas = minutos / 60;
  if (horas < 48) {
    return cantidad(Math.round(horas), 'hora', 'horas');
  }
  return cantidad(Math.round(horas / 24), 'dia', 'dias');
}

/** `1 hora`, `3 horas`. */
function cantidad(n: number, singular: string, plural: string): string {
  return `${n} ${n === 1 ? singular : plural}`;
}

// =====================================================================
// Las consultas Cypher
//
// Adaptadas de neo4j/consultas/A1..A4 -- que estan escritas para el visor
// de linea de comandos (varias sentencias, RETURN de rotulo) y no se pueden
// correr tal cual desde el driver. La logica de deteccion es la misma; el
// RETURN arma ya la forma del payload. El grafo NO se modifica: son de
// solo lectura (`consultarGrafo` abre la sesion en modo READ).
// =====================================================================

/**
 * A.1 -- camino cerrado ESCRIBIO/CALIFICA_A de 4 a 8 saltos (2 a 4 cuentas).
 * Ancla cada anillo en su cuenta de menor id para no contarlo una vez por
 * rotacion, y exige que las cuentas del ciclo sean todas distintas (sin eso,
 * un par que se califica dos veces en cada sentido sale ademas como un
 * "anillo de 4" con los correos repetidos).
 */
const CYPHER_GRUPOS_CICLICOS = `
MATCH camino = (inicio:Usuario)-[:ESCRIBIO|CALIFICA_A*4..8]->(inicio)
WITH nodes(camino) AS nodos
WITH [n IN nodos WHERE n:Usuario] AS usuariosCamino,
     [n IN nodos WHERE n:Resena]  AS resenasCamino
WITH usuariosCamino[0..-1] AS ciclo, resenasCamino
WHERE ALL (c IN ciclo WHERE ciclo[0].id <= c.id)
  AND size(ciclo) = size(reduce(vistas = [], c IN ciclo |
        CASE WHEN c.id IN vistas THEN vistas ELSE vistas + c.id END))
RETURN
  [c IN ciclo | {
    id_usuario: c.id, usuario: c.usuario, correo_electronico: c.correo,
    nombre: c.nombre, apellido: c.apellido, fecha_alta: toString(c.fecha_alta)
  }] AS cuentas,
  [r IN resenasCamino | {
    id_resena: r.id,
    autor:    head([ (a:Usuario)-[:ESCRIBIO]->(r) | a.usuario ]),
    vendedor: head([ (r)-[:CALIFICA_A]->(v:Usuario) | v.usuario ]),
    id_producto: head([ (r)-[:SOBRE]->(p:Producto) | p.id ]),
    producto:    head([ (r)-[:SOBRE]->(p:Producto) | p.nombre ]),
    calificacion: r.calificacion,
    fecha: toString(r.fecha)
  }] AS resenas
`;

/**
 * A.2 -- par que se califica en los DOS sentidos sobre el MISMO producto. La
 * frase literal del enunciado. `a.id < b.id` para que el par salga una vez.
 */
const CYPHER_PARES_MISMO_PRODUCTO = `
MATCH (a:Usuario)-[:ESCRIBIO]->(ra:Resena)-[:CALIFICA_A]->(b:Usuario),
      (b)-[:ESCRIBIO]->(rb:Resena)-[:CALIFICA_A]->(a),
      (ra)-[:SOBRE]->(:Producto)<-[:SOBRE]-(rb)
WHERE a.id < b.id
WITH a, b, collect(DISTINCT ra) + collect(DISTINCT rb) AS resenasPar
RETURN
  [x IN [a, b] | {
    id_usuario: x.id, usuario: x.usuario, correo_electronico: x.correo,
    nombre: x.nombre, apellido: x.apellido, fecha_alta: toString(x.fecha_alta)
  }] AS cuentas,
  [r IN resenasPar | {
    id_resena: r.id,
    autor:    head([ (au:Usuario)-[:ESCRIBIO]->(r) | au.usuario ]),
    vendedor: head([ (r)-[:CALIFICA_A]->(ve:Usuario) | ve.usuario ]),
    id_producto: head([ (r)-[:SOBRE]->(p:Producto) | p.id ]),
    producto:    head([ (r)-[:SOBRE]->(p:Producto) | p.nombre ]),
    calificacion: r.calificacion,
    fecha: toString(r.fecha)
  }] AS resenas
`;

/**
 * A.4 -- cuentas distintas que caen en el mismo nodo :Direccion, exigiendo
 * que ese nodo tenga calle (`d.tiene_calle`): sin eso "misma casa" pasa a
 * significar "misma ciudad", que no es senal de nada. Incluye, si las hay,
 * las resenas que esas cuentas se escribieron entre si.
 */
const CYPHER_MISMA_DIRECCION = `
MATCH (u:Usuario)-[:VIVE_EN]->(d:Direccion)
WHERE d.tiene_calle
WITH d, collect(DISTINCT u) AS habitantes
WHERE size(habitantes) >= 2
RETURN
  d.clave AS clave, d.ciudad AS ciudad, d.departamento AS departamento,
  d.exacta AS exacta,
  [c IN habitantes | {
    id_usuario: c.id, usuario: c.usuario, correo_electronico: c.correo,
    nombre: c.nombre, apellido: c.apellido, fecha_alta: toString(c.fecha_alta)
  }] AS cuentas,
  [ (a:Usuario)-[:ESCRIBIO]->(r:Resena)-[:CALIFICA_A]->(b:Usuario)
    WHERE a IN habitantes AND b IN habitantes | {
      id_resena: r.id, autor: a.usuario, vendedor: b.usuario,
      id_producto: head([ (r)-[:SOBRE]->(p:Producto) | p.id ]),
      producto:    head([ (r)-[:SOBRE]->(p:Producto) | p.nombre ]),
      calificacion: r.calificacion, fecha: toString(r.fecha)
  } ] AS resenas
`;

/** El denominador de `analizado`: tamano del grafo entero. */
const CYPHER_CONTEO = `
MATCH (u:Usuario)
WITH count(u) AS cuentas
MATCH (r:Resena)
WITH cuentas, count(r) AS resenas
MATCH ()-[rel]->()
RETURN cuentas, resenas, count(rel) AS relaciones
`;
