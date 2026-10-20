import { Logger } from '@nestjs/common';
import { cortacircuitosElastic, esCaidaDeElastic } from '../database/elastic';
import { pool } from '../database/postgres';
import { ResultadoBusquedaProducto } from '../dto/buscar-productos';
import { FacetaCategoria, FacetaRango } from '../dto/buscar-productos-facetado';
import { ctePreciosYNotas } from './catalogo-respaldo';
import { CORREO_TIENDA } from './constantes';
import { ErrorConexion } from './errores';
import {
  FiltrosElegidos,
  RANGOS_NOTA,
  RANGOS_PRECIO,
  RangoPrecio,
} from './facetas-buscador';
import { esFalloDeConexion } from './manejar-error-db';

/**
 * El respaldo del buscador: cuando Elasticsearch no responde, la busqueda de
 * productos sale de la copia del catalogo en PostgreSQL (2026-10-20), en vez
 * de dar 503 a los 22 segundos. Es el mismo molde que el respaldo del catalogo
 * sin Mongo (`catalogo-respaldo.ts`).
 *
 * La copia tiene el nombre, la descripcion, las variantes, el estado y la
 * categoria de cada producto (migraciones 029 y 047), y los precios, el stock
 * y las notas se calculan en el momento desde `oferta` y `resena`
 * (`ctePreciosYNotas`). La migracion 048 pone lo que hace falta para buscar
 * texto como lo busca el indice `mesh_productos`:
 *
 *   - Sin tildes y en minusculas (`mesh_normalizar`), como su analizador
 *     `espanol_llano`.
 *   - Cada palabra buscada se compara con las palabras del nombre (vale 3),
 *     de las variantes (1) y de la descripcion (0.5), con la tolerancia de
 *     `fuzziness: AUTO` (`mesh_coincide`): "labtop" encuentra "laptop".
 *   - Basta que coincida una palabra (el `multi_match` es OR), y las palabras
 *     que estan en muchos productos pesan menos, como en el puntaje de
 *     Elasticsearch: en "camisa de vestir" manda "camisa" y no "de".
 *   - Entre empates, el nombre mas corto primero (Elasticsearch premia el campo
 *     corto por la misma razon).
 *
 * Medido contra Elasticsearch el 2026-10-20 con laptop, labtop, audifonos,
 * camisa, "laptop gamer", "silla de comedor" y asdffff: los mismos productos,
 * en un orden muy parecido, en 0.2 a 0.6 s. Lo que no tiene es el "tal vez
 * quisiste decir" (sale `null`).
 */

const logger = new Logger('BuscadorRespaldo');

/** Si la ultima busqueda salio del respaldo: para avisar solo al entrar y al salir. */
let enRespaldo = false;

/**
 * Corre `deElastic`, y si Elasticsearch no responde (o su cortacircuitos esta
 * en pausa), `deCopia`. Cualquier otro error de Elasticsearch sale tal cual,
 * para que el que llama lo clasifique como siempre. Un fallo de PostgreSQL en
 * el respaldo sale como `ErrorConexion` (503).
 */
export async function conRespaldoDeElastic<T>(
  deElastic: () => Promise<T>,
  deCopia: () => Promise<T>,
): Promise<T> {
  if (!cortacircuitosElastic.enPausa()) {
    try {
      const resultado = await deElastic();
      if (enRespaldo) {
        enRespaldo = false;
        logger.log(
          'Elasticsearch volvio: el buscador sale otra vez de Elasticsearch',
        );
      }
      return resultado;
    } catch (error) {
      if (!esCaidaDeElastic(error)) {
        throw error;
      }
      if (!enRespaldo) {
        enRespaldo = true;
        logger.warn(
          `Elasticsearch no responde (${error instanceof Error ? error.message : String(error)}): el buscador sale de la copia del catalogo en PostgreSQL`,
        );
      }
    }
  }

  try {
    return await deCopia();
  } catch (error) {
    if (esFalloDeConexion(error)) {
      logger.error(
        `El respaldo del buscador tampoco pudo leer PostgreSQL: ${error instanceof Error ? error.message : String(error)}`,
      );
      throw new ErrorConexion('No se pudo conectar con PostgreSQL');
    }
    throw error;
  }
}

/** Las facetas contadas en la copia, con la misma forma que las de Elasticsearch. */
export interface FacetasCopia {
  categoria: FacetaCategoria[];
  precio: FacetaRango[];
  calificacion: FacetaRango[];
  disponible: number;
}

export interface OpcionesBusquedaCopia {
  /** Lo escrito. Vacio = todos los productos (navegar solo por facetas). */
  texto: string;
  limite: number;
  /** Solo los publicos (`activo`). El buscador del admin ve todos. */
  soloActivos: boolean;
  /** Lo elegido en el panel de filtros. Sin esto, sin filtros. */
  filtros?: FiltrosElegidos;
  /**
   * Como el `minimum_should_match: '2<70%'` de la busqueda hibrida: con una o
   * dos palabras tienen que coincidir todas, con mas el 70 %. Sin esto basta
   * una, como el `multi_match` del buscador de siempre.
   */
  exigirMayoria?: boolean;
  /**
   * Para la lista del buscador de la cabecera, que busca con cada letra: la
   * ultima palabra escrita tambien vale como principio de una palabra del
   * nombre ("lap" encuentra "Laptop"), y pesa mas que un parecido de una
   * letra ("lap" contra "las"). Como el `bool_prefix` de la ruta con
   * Elasticsearch.
   */
  prefijo?: boolean;
}

export interface ResultadoCopia {
  resultados: ResultadoBusquedaProducto[];
  /** Cuantos coinciden en total, no solo los `limite` que se devuelven. */
  total: number;
  /** Contadas sobre lo que coincide con el texto Y con los filtros elegidos. */
  facetas: FacetasCopia;
}

/** Una fila de producto como la devuelve la consulta, antes de pasar a numeros. */
interface FilaResultado {
  id: string;
  nombre: string;
  estado: string | null;
  categoria: string | null;
  precio_desde: string | null;
  precio_tienda: string | null;
  hay_descuento: boolean | null;
  stock_total: string | number;
  promedio: string | null;
  total_resenas: string | number;
}

/**
 * La busqueda en la copia: los resultados mas parecidos primero, el total y
 * las facetas, en una sola consulta.
 */
export async function buscarEnCopia(
  opciones: OpcionesBusquedaCopia,
): Promise<ResultadoCopia> {
  const parametros: unknown[] = [
    CORREO_TIENDA,
    opciones.texto,
    opciones.soloActivos,
    opciones.limite,
  ];
  const p = (valor: unknown): string => {
    parametros.push(valor);
    return `$${parametros.length}`;
  };

  const condiciones: string[] = ['TRUE'];
  const filtros = opciones.filtros;
  if (filtros != null) {
    if (filtros.categorias.length > 0) {
      condiciones.push(
        `id_categoria = ANY(${p(filtros.categorias)}::bigint[])`,
      );
    }
    if (filtros.precios.length > 0) {
      condiciones.push(
        `(${filtros.precios.map((r) => condicionRango('precio_desde', r)).join(' OR ')})`,
      );
    }
    if (filtros.calificacionMinima != null) {
      condiciones.push(`promedio >= ${p(filtros.calificacionMinima)}::numeric`);
    }
    if (filtros.disponible) {
      condiciones.push('stock_total > 0');
    }
  }

  const mayoria = opciones.exigirMayoria
    ? `AND count(*) FILTER (WHERE c.valor > 0) >=
             CASE WHEN (SELECT count(*) FROM palabras) <= 2 THEN (SELECT count(*) FROM palabras)
                  ELSE ceil(0.7 * (SELECT count(*) FROM palabras)) END`
    : '';

  // La palabra solo trae letras y numeros (se parte por lo demas), asi que
  // puede ir dentro de la expresion regular sin escaparla.
  const principio = opciones.prefijo
    ? `CASE WHEN pa.w = (SELECT w FROM ultima)
                       AND d.n_nombre ~ ('(^|[^[:alnum:]])' || pa.w) THEN 1.2 ELSE 0 END`
    : '0';

  const conteosPrecio = RANGOS_PRECIO.map(
    (r) =>
      `'${r.key}', count(*) FILTER (WHERE ${condicionRango('precio_desde', r)})`,
  ).join(', ');
  const conteosNota = RANGOS_NOTA.map(
    (r) => `'${r.key}', count(*) FILTER (WHERE promedio >= ${Number(r.from)})`,
  ).join(', ');

  const { rows } = await pool.query<{
    total: number;
    resultados: FilaResultado[];
    categorias: { id: string; nombre: string | null; cantidad: number }[];
    precios: Record<string, number>;
    notas: Record<string, number>;
    disponible: number;
  }>(
    `WITH ${ctePreciosYNotas('$1')},
       palabras AS (
         SELECT DISTINCT w
           FROM unnest(regexp_split_to_array(mesh_normalizar($2), '[^[:alnum:]]+')) AS w
          WHERE w <> ''
       ),
       docs AS (
         SELECT pc.id_producto_mongo AS id, pc.nombre, pc.estado, pc.id_categoria,
                mesh_normalizar(pc.nombre) AS n_nombre,
                mesh_normalizar(COALESCE(pc.descripcion, '')) AS n_descripcion,
                mesh_normalizar(COALESCE((SELECT string_agg(vc.nombre_variante, ' ')
                                            FROM variante_catalogo vc
                                           WHERE vc.id_producto_mongo = pc.id_producto_mongo), ''))
                  AS n_variantes
           FROM producto_catalogo pc
          WHERE pc.estado IS NOT NULL
            AND (NOT $3::boolean OR pc.estado = 'activo')
       ),
       ultima AS (
         SELECT substring(mesh_normalizar($2) FROM '([[:alnum:]]+)[^[:alnum:]]*$') AS w
       ),
       cruce AS (
         SELECT d.id, pa.w,
                3 * GREATEST(mesh_coincide(pa.w, d.n_nombre), ${principio})
                  + mesh_coincide(pa.w, d.n_variantes)
                  + 0.5 * mesh_coincide(pa.w, d.n_descripcion) AS valor
           FROM docs d CROSS JOIN palabras pa
       ),
       rareza AS (
         SELECT w, ln((SELECT count(*) FROM docs)::numeric
                      / (1 + count(*) FILTER (WHERE valor > 0))) + 1 AS peso
           FROM cruce
          GROUP BY w
       ),
       puntaje AS (
         SELECT c.id, sum(c.valor * r.peso) AS puntaje
           FROM cruce c JOIN rareza r USING (w)
          GROUP BY c.id
         HAVING sum(c.valor) > 0 ${mayoria}
         UNION ALL
         -- Sin texto, todos: navegar el catalogo solo con los filtros.
         SELECT id, 0 FROM docs WHERE NOT EXISTS (SELECT 1 FROM palabras)
       ),
       base AS (
         SELECT d.id, d.nombre, d.estado, d.id_categoria, cat.nombre AS categoria,
                pp.precio_desde, pp.precio_tienda, pp.hay_descuento,
                COALESCE(pp.stock_total, 0) AS stock_total,
                COALESCE(n.promedio, 0) AS promedio,
                COALESCE(n.total, 0) AS total_resenas,
                pu.puntaje
           FROM puntaje pu
           JOIN docs d USING (id)
           LEFT JOIN pp ON pp.id = d.id
           LEFT JOIN n ON n.id = d.id
           LEFT JOIN categorias cat ON cat.id_categoria = d.id_categoria
       ),
       filtrados AS (
         SELECT * FROM base WHERE ${condiciones.join(' AND ')}
       )
     SELECT
       (SELECT count(*)::int FROM filtrados) AS total,
       COALESCE((SELECT json_agg(r) FROM (
                  SELECT id, nombre, estado, categoria, precio_desde, precio_tienda,
                         hay_descuento, stock_total, promedio, total_resenas
                    FROM filtrados
                   ORDER BY puntaje DESC, length(nombre), id
                   LIMIT $4) r), '[]') AS resultados,
       COALESCE((SELECT json_agg(c) FROM (
                  SELECT id_categoria AS id, categoria AS nombre, count(*)::int AS cantidad
                    FROM filtrados
                   WHERE id_categoria IS NOT NULL
                   GROUP BY id_categoria, categoria
                   ORDER BY count(*) DESC, id_categoria
                   LIMIT 50) c), '[]') AS categorias,
       (SELECT json_build_object(${conteosPrecio}) FROM filtrados) AS precios,
       (SELECT json_build_object(${conteosNota}) FROM filtrados) AS notas,
       (SELECT count(*)::int FROM filtrados WHERE stock_total > 0) AS disponible`,
    parametros,
  );

  const fila = rows[0];
  return {
    total: fila.total,
    resultados: fila.resultados.map(aResultado),
    facetas: {
      categoria: fila.categorias.map((c) => ({
        id: Number(c.id),
        nombre: c.nombre ?? '?',
        cantidad: c.cantidad,
      })),
      precio: RANGOS_PRECIO.map((r) => ({
        clave: r.key,
        cantidad: Number(fila.precios[r.key] ?? 0),
      })),
      calificacion: RANGOS_NOTA.map((r) => ({
        clave: r.key,
        cantidad: Number(fila.notas[r.key] ?? 0),
      })),
      disponible: fila.disponible,
    },
  };
}

/** Un documento del buscador, como lo guarda `mesh_productos`. */
export interface DocumentoCopia {
  nombre: string;
  descripcion: string | null;
  estado: string;
  categoria_nombre: string | null;
  precio_desde: number | null;
  precio_tienda: number | null;
  hay_descuento: boolean;
  stock_total: number;
  resenas_promedio: number;
  resenas_total: number;
}

/**
 * Los documentos de `ids` armados desde la copia, con la forma de
 * `mesh_productos`: lo que la busqueda hibrida y la de intencion le piden a
 * Elasticsearch con `mget` para pintar lo que encontraron por vectores.
 */
export async function documentosDesdeCopia(
  ids: number[],
): Promise<Map<number, DocumentoCopia>> {
  const docs = new Map<number, DocumentoCopia>();
  if (ids.length === 0) {
    return docs;
  }
  const { rows } = await pool.query<
    FilaResultado & { descripcion: string | null }
  >(
    `WITH ${ctePreciosYNotas('$1')}
     SELECT pc.id_producto_mongo AS id, pc.nombre, pc.descripcion, pc.estado,
            cat.nombre AS categoria, pp.precio_desde, pp.precio_tienda, pp.hay_descuento,
            COALESCE(pp.stock_total, 0) AS stock_total,
            COALESCE(n.promedio, 0) AS promedio, COALESCE(n.total, 0) AS total_resenas
       FROM producto_catalogo pc
       LEFT JOIN pp ON pp.id = pc.id_producto_mongo
       LEFT JOIN n ON n.id = pc.id_producto_mongo
       LEFT JOIN categorias cat ON cat.id_categoria = pc.id_categoria
      WHERE pc.id_producto_mongo = ANY($2::bigint[])
        AND pc.estado IS NOT NULL`,
    [CORREO_TIENDA, ids],
  );
  for (const fila of rows) {
    const r = aResultado(fila);
    docs.set(r.id_producto, {
      nombre: r.nombre,
      descripcion: fila.descripcion,
      estado: r.estado,
      categoria_nombre: r.categoria,
      precio_desde: r.precio_desde,
      precio_tienda: r.precio_tienda,
      hay_descuento: r.hay_descuento,
      stock_total: r.stock_total,
      resenas_promedio: r.resenas_promedio,
      resenas_total: r.resenas_total,
    });
  }
  return docs;
}

/**
 * Las sugerencias mientras se escribe, desde la copia: como el `bool_prefix`
 * sobre `nombre.escribiendo`, todas las palabras escritas tienen que estar en
 * el nombre y la ultima puede estar a medias ("laptop au" -> "Laptop Aurora").
 * Solo productos publicos, el nombre mas corto primero.
 */
export async function autocompletarDesdeCopia(
  prefijo: string,
  limite: number,
): Promise<{ id_producto: number; nombre: string }[]> {
  const { rows } = await pool.query<{ id: string; nombre: string }>(
    `WITH escrito AS (
         SELECT array_remove(regexp_split_to_array(mesh_normalizar($1), '[^[:alnum:]]+'), '') AS ps
       ),
       nombres AS (
         SELECT pc.id_producto_mongo AS id, pc.nombre,
                ' ' || regexp_replace(mesh_normalizar(pc.nombre), '[^[:alnum:]]+', ' ', 'g') || ' ' AS n
           FROM producto_catalogo pc
          WHERE pc.estado = 'activo'
       )
     SELECT nm.id, nm.nombre
       FROM nombres nm, escrito e
      WHERE cardinality(e.ps) > 0
        -- Todas menos la ultima, palabras enteras; la ultima, el principio de una.
        AND (SELECT bool_and(CASE WHEN o < cardinality(e.ps)
                                  THEN position(' ' || w || ' ' IN nm.n) > 0
                                  ELSE position(' ' || w IN nm.n) > 0 END)
               FROM unnest(e.ps) WITH ORDINALITY AS t (w, o))
      ORDER BY length(nm.nombre), nm.id
      LIMIT $2`,
    [prefijo, limite],
  );
  return rows.map((fila) => ({
    id_producto: Number(fila.id),
    nombre: fila.nombre,
  }));
}

function aResultado(fila: FilaResultado): ResultadoBusquedaProducto {
  return {
    id_producto: Number(fila.id),
    nombre: fila.nombre,
    estado: fila.estado ?? '',
    categoria: fila.categoria,
    precio_desde: numeroONulo(fila.precio_desde),
    precio_tienda: numeroONulo(fila.precio_tienda),
    hay_descuento: fila.hay_descuento ?? false,
    stock_total: Number(fila.stock_total),
    resenas_promedio: Number(fila.promedio ?? 0),
    resenas_total: Number(fila.total_resenas),
  };
}

function numeroONulo(valor: string | null): number | null {
  return valor == null ? null : Number(valor);
}

/**
 * La condicion SQL de un rango de precio, como el `range` de Elasticsearch:
 * `from` incluido y `to` excluido. Los numeros salen de `RANGOS_PRECIO`, nunca
 * de la persona, asi que van escritos en la consulta.
 */
function condicionRango(columna: string, rango: RangoPrecio): string {
  const partes: string[] = [];
  if (rango.from != null) {
    partes.push(`${columna} >= ${Number(rango.from)}`);
  }
  if (rango.to != null) {
    partes.push(`${columna} < ${Number(rango.to)}`);
  }
  return partes.length > 0 ? `(${partes.join(' AND ')})` : 'TRUE';
}
