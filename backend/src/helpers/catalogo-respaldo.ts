import { Logger } from '@nestjs/common';
import { Decimal128 } from 'mongodb';
import { mongoClient, mongoDb } from '../database/mongo';
import { pool } from '../database/postgres';
import { CategoriaValida } from '../models/categoria';
import { ESTADO_PRODUCTO_VISIBLE } from '../models/estado-producto';
import { Producto, ProductoVariante } from '../models/producto';
import { CORREO_TIENDA } from './constantes';
import { ErrorConexion } from './errores';
import { esFalloDeConexion } from './manejar-error-db';
import { esCaidaDeMongo } from './manejar-error-mongo';
import { expresionPrecioFinal } from './precio-descuento';

/**
 * El respaldo del catalogo: cuando MongoDB no responde, el catalogo, la ficha
 * de un producto y las tarjetas de las recomendaciones salen de la copia del
 * catalogo en PostgreSQL (migraciones 029 y 047) en vez de dar 503.
 *
 * La copia la mantienen al dia el backend (`catalogo-postgres.ts`, en la misma
 * transaccion que la escritura en Mongo) y el paso 7e de arrancar.ps1, asi que
 * el respaldo no muestra datos viejos: muestra menos datos. Tiene el nombre,
 * el estado, la categoria, la descripcion y las variantes con su portada; los
 * precios, el stock, los vendedores y las notas se calculan en el momento
 * desde `oferta` y `resena`, con las mismas cuentas que
 * `ProductosService.recalcularUnProducto` usa para escribirlos en Mongo. Lo
 * que no tiene son las caracteristicas (adicionales y personalizadas), que
 * solo viven en Mongo, ni la descripcion y las demas fotos de cada variante.
 * Cada producto del respaldo lleva `desde_respaldo: true` para que la pagina
 * lo sepa.
 *
 * Un detalle de la copia: una variante que se quito de un producto pero que
 * todavia tiene ofertas sigue en `variante_catalogo` como `inactiva`
 * (`sincronizarCatalogo`), asi que en el respaldo puede aparecer una variante
 * inactiva de mas.
 *
 * Con Mongo caido, cada consulta tarda 3 s en rendirse (`database/mongo.ts`).
 * Para no cobrar esos 3 s en cada peticion, despues de una caida se va directo
 * a PostgreSQL durante `PAUSA_MS`, y despues se vuelve a probar Mongo.
 */

const logger = new Logger('CatalogoRespaldo');

/** Cuanto se va directo al respaldo despues de ver a Mongo caido. */
const PAUSA_MS = 15_000;

/** Hasta cuando no se le pregunta a Mongo. 0 = Mongo responde. */
let mongoCaidoHasta = 0;
/** Si la ultima vez se uso el respaldo: para avisar en el log solo al entrar y al salir. */
let enRespaldo = false;

/** Un producto armado por el respaldo. */
export type ProductoRespaldo = Producto & { desde_respaldo?: true };

/**
 * Corre `deMongo`, y si Mongo no responde, `dePostgres`. Cualquier otro error
 * de Mongo sale tal cual, para que el llamador lo clasifique como siempre. Un
 * fallo de PostgreSQL en el respaldo sale como `ErrorConexion` (503).
 *
 * Al volver a probar Mongo despues de una caida se llama primero a
 * `mongoClient.connect()`: si el backend arranco con Mongo caido, el driver
 * dejo el cliente cerrado ("Topology is closed") y sin esto no volveria a
 * conectarse nunca. Con el cliente ya conectado no hace nada. El cliente es el
 * mismo para todo el backend, asi que se recuperan tambien los workers.
 */
export async function conRespaldoDeMongo<T>(
  deMongo: () => Promise<T>,
  dePostgres: () => Promise<T>,
): Promise<T> {
  if (Date.now() >= mongoCaidoHasta) {
    try {
      if (enRespaldo) {
        await mongoClient.connect();
      }
      const resultado = await deMongo();
      if (enRespaldo) {
        enRespaldo = false;
        logger.log('MongoDB volvio: el catalogo sale otra vez de Mongo');
      }
      return resultado;
    } catch (error) {
      if (!esCaidaDeMongo(error)) {
        throw error;
      }
      mongoCaidoHasta = Date.now() + PAUSA_MS;
      if (!enRespaldo) {
        enRespaldo = true;
        logger.warn(
          `MongoDB no responde (${error instanceof Error ? error.message : String(error)}): el catalogo sale de la copia en PostgreSQL`,
        );
      }
    }
  }

  try {
    return await dePostgres();
  } catch (error) {
    // Solo una caida de PostgreSQL se convierte en 503; un "no existe" o un
    // ErrorConexion del propio respaldo salen tal cual.
    if (esFalloDeConexion(error)) {
      logger.error(
        `El respaldo del catalogo tampoco pudo leer PostgreSQL: ${error instanceof Error ? error.message : String(error)}`,
      );
      throw new ErrorConexion('No se pudo conectar con PostgreSQL');
    }
    throw error;
  }
}

/**
 * Los productos de `ids`, de Mongo o, si no responde, del respaldo. Con
 * `soloVisibles` solo los publicos (`activo`). El orden no se garantiza: los
 * llamadores los buscan por id.
 */
export async function productosPorIds(
  ids: number[],
  opciones: { soloVisibles: boolean },
): Promise<ProductoRespaldo[]> {
  if (ids.length === 0) {
    return [];
  }
  return conRespaldoDeMongo<ProductoRespaldo[]>(
    () =>
      mongoDb
        .collection<Producto>('productos')
        .find(
          opciones.soloVisibles
            ? { _id: { $in: ids }, estado: ESTADO_PRODUCTO_VISIBLE }
            : { _id: { $in: ids } },
        )
        .toArray(),
    () => productosDesdePostgres(ids, opciones.soloVisibles),
  );
}

interface FilaProducto {
  id: string;
  nombre: string;
  descripcion: string | null;
  estado: string | null;
  fecha_creacion: Date | null;
  fecha_actualizacion: Date;
  id_categoria: string | null;
  categoria: string | null;
  categoria_padre: string | null;
}

interface FilaVariante {
  id: string;
  id_variante: string;
  nombre_variante: string;
  estado: string;
  imagen: string | null;
  fecha_actualizacion: Date;
}

/** Lo mismo que `FilaCalculoVariante` de `ProductosService`, con el producto. */
interface FilaCalculo {
  id: string;
  id_variante: string;
  precio_tienda: string | null;
  precio_desde: string | null;
  stock_tienda: number;
  stock_total: number;
  total_ofertas: number;
  hay_descuento: boolean;
}

/**
 * Arma los productos de `ids` desde PostgreSQL con la misma forma que el
 * documento de Mongo, en el orden de `ids`. Los que no estan en la copia (o
 * no son publicos, con `soloVisibles`) no salen.
 */
export async function productosDesdePostgres(
  ids: number[],
  soloVisibles: boolean,
): Promise<ProductoRespaldo[]> {
  const unicos = [...new Set(ids)];
  if (unicos.length === 0) {
    return [];
  }

  const [productos, variantes, calculos, ofertasProducto, notas] =
    await Promise.all([
      pool.query<FilaProducto>(
        `SELECT pc.id_producto_mongo AS id, pc.nombre, pc.descripcion, pc.estado,
                pc.fecha_creacion, pc.fecha_actualizacion,
                pc.id_categoria, c.nombre AS categoria, cp.nombre AS categoria_padre
           FROM producto_catalogo pc
           LEFT JOIN categorias c ON c.id_categoria = pc.id_categoria
           LEFT JOIN categorias cp ON cp.id_categoria = c.id_categoria_padre
          WHERE pc.id_producto_mongo = ANY($1::bigint[])
            AND (NOT $2::boolean OR pc.estado = $3)`,
        [unicos, soloVisibles, ESTADO_PRODUCTO_VISIBLE],
      ),
      pool.query<FilaVariante>(
        `SELECT id_producto_mongo AS id, id_producto_variante_mongo AS id_variante,
                nombre_variante, estado, imagen, fecha_actualizacion
           FROM variante_catalogo
          WHERE id_producto_mongo = ANY($1::bigint[])
          ORDER BY id_producto_mongo, id_producto_variante_mongo`,
        [unicos],
      ),
      // La misma cuenta que recalcularUnProducto, para muchos productos.
      pool.query<FilaCalculo>(
        `WITH tienda AS (
           SELECT id_usuario FROM usuarios WHERE correo_electronico = $2
         ),
         activa AS (
           SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'activa'
         )
         SELECT
           o.id_producto_mongo AS id,
           o.id_producto_variante_mongo AS id_variante,
           MAX(CASE WHEN o.id_usuario = (SELECT id_usuario FROM tienda)
                    THEN ${expresionPrecioFinal('o')} END)::text AS precio_tienda,
           MIN(CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                    THEN ${expresionPrecioFinal('o')} END)::text AS precio_desde,
           COALESCE(SUM(CASE WHEN o.id_usuario = (SELECT id_usuario FROM tienda)
                             AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                        THEN o.stock ELSE 0 END), 0)::int AS stock_tienda,
           COALESCE(SUM(CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                        THEN o.stock ELSE 0 END), 0)::int AS stock_total,
           COUNT(DISTINCT CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                           THEN o.id_usuario END)::int AS total_ofertas,
           bool_or(o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                   AND o.porcentaje_descuento IS NOT NULL) AS hay_descuento
         FROM oferta o
         WHERE o.id_producto_mongo = ANY($1::bigint[])
         GROUP BY o.id_producto_mongo, o.id_producto_variante_mongo`,
        [unicos, CORREO_TIENDA],
      ),
      pool.query<{ id: string; total_ofertas: number }>(
        `SELECT o.id_producto_mongo AS id, COUNT(DISTINCT o.id_usuario)::int AS total_ofertas
           FROM oferta o
           JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
          WHERE o.id_producto_mongo = ANY($1::bigint[]) AND eo.estado_oferta_nombre = 'activa'
          GROUP BY o.id_producto_mongo`,
        [unicos],
      ),
      pool.query<{ id: string; promedio: string | null; total: number }>(
        `SELECT id_producto_mongo AS id, ROUND(AVG(calificacion), 2)::text AS promedio,
                COUNT(*)::int AS total
           FROM resena
          WHERE id_producto_mongo = ANY($1::bigint[])
          GROUP BY id_producto_mongo`,
        [unicos],
      ),
    ]);

  const variantesPorProducto = agrupar(variantes.rows, (fila) => fila.id);
  const calculoPorVariante = new Map(
    calculos.rows.map((fila) => [`${fila.id}:${fila.id_variante}`, fila]),
  );
  const calculosPorProducto = agrupar(calculos.rows, (fila) => fila.id);
  const ofertasPorProducto = new Map(
    ofertasProducto.rows.map((fila) => [fila.id, fila.total_ofertas]),
  );
  const notaPorProducto = new Map(notas.rows.map((fila) => [fila.id, fila]));
  const filaPorId = new Map(
    productos.rows.map((fila) => [Number(fila.id), fila]),
  );

  const resultado: ProductoRespaldo[] = [];
  for (const id of unicos) {
    const fila = filaPorId.get(id);
    if (fila == null) {
      continue;
    }
    const fechaCreacion = fila.fecha_creacion ?? fila.fecha_actualizacion;

    const suyas = (variantesPorProducto.get(fila.id) ?? []).map(
      (v): ProductoVariante => {
        const calculo = calculoPorVariante.get(`${fila.id}:${v.id_variante}`);
        return {
          id_producto_variante: Number(v.id_variante),
          nombre_variante: v.nombre_variante,
          descripcion: null,
          fecha_creacion: fechaCreacion,
          estado: v.estado,
          imagenes: v.imagen != null ? [v.imagen] : [],
          precio_tienda: decimal(calculo?.precio_tienda ?? null),
          precio_desde: decimal(calculo?.precio_desde ?? null),
          stock_tienda: calculo?.stock_tienda ?? 0,
          stock_total: calculo?.stock_total ?? 0,
          total_ofertas: calculo?.total_ofertas ?? 0,
          hay_descuento: calculo?.hay_descuento ?? false,
        };
      },
    );

    // La raiz, como recalcularUnProducto: con todas las ofertas del producto,
    // el minimo de cada precio entre las variantes, el stock sumado y el
    // descuento si cualquiera lo tiene.
    const calculosDelProducto = calculosPorProducto.get(fila.id) ?? [];
    const nota = notaPorProducto.get(fila.id);
    const resenasTotal = nota?.total ?? 0;

    resultado.push({
      _id: id,
      nombre: fila.nombre,
      descripcion: fila.descripcion,
      fecha_creacion: fechaCreacion,
      estado: fila.estado ?? '',
      categoria: {
        id_categoria: fila.id_categoria != null ? Number(fila.id_categoria) : 0,
        nombre: fila.categoria ?? '',
        categoria_padre: fila.categoria_padre,
      },
      precio_tienda: minimo(calculosDelProducto.map((c) => c.precio_tienda)),
      precio_desde: minimo(calculosDelProducto.map((c) => c.precio_desde)),
      stock_tienda: calculosDelProducto.reduce((t, c) => t + c.stock_tienda, 0),
      stock_total: calculosDelProducto.reduce((t, c) => t + c.stock_total, 0),
      total_ofertas: ofertasPorProducto.get(fila.id) ?? 0,
      hay_descuento: calculosDelProducto.some((c) => c.hay_descuento),
      resenas_promedio: resenasTotal > 0 ? Number(nota!.promedio) : 0,
      resenas_total: resenasTotal,
      variantes: suyas,
      desde_respaldo: true,
    });
  }
  return resultado;
}

/**
 * Los filtros del catalogo ya validados (`ProductosService.leerFiltros`).
 * Mongo y el respaldo leen los mismos, asi que validan igual.
 */
export interface FiltrosCatalogo {
  nombre: string | null;
  /** Se pidio un `estado` que no es el publico: no hay nada que mostrar. */
  estadoImposible: boolean;
  idCategoria: number | null;
  precioMin: string | null;
  precioMax: string | null;
  precioTiendaMin: string | null;
  precioTiendaMax: string | null;
  estadoVariante: string | null;
  stockMin: number | null;
  stockMax: number | null;
  stockTiendaMin: number | null;
  stockTiendaMax: number | null;
  resenasPromedioMin: string | null;
  resenasPromedioMax: string | null;
  resenasTotalMin: number | null;
  resenasTotalMax: number | null;
  /** Los filtros por caracteristicas, ya como condiciones de Mongo. */
  caracteristicas: Record<string, unknown>[];
}

/**
 * Una pagina del catalogo publico desde PostgreSQL, con los mismos filtros y el
 * mismo orden (por id) que el de Mongo. Con `despuesDe` pagina por cursor; si
 * no, salta `saltar`. Los filtros por caracteristicas no se pueden aplicar
 * (viven solo en Mongo): en vez de devolver una lista sin filtrar, se responde
 * como si el catalogo no estuviera (503).
 */
export async function paginaDesdePostgres(
  filtros: FiltrosCatalogo,
  pagina: { limite: number; saltar?: number; despuesDe?: number | null },
): Promise<{ productos: ProductoRespaldo[]; total: number }> {
  if (filtros.caracteristicas.length > 0) {
    throw new ErrorConexion('No se pudo conectar con MongoDB');
  }
  if (filtros.estadoImposible) {
    return { productos: [], total: 0 };
  }

  const parametros: unknown[] = [CORREO_TIENDA, ESTADO_PRODUCTO_VISIBLE];
  const p = (valor: unknown): string => {
    parametros.push(valor);
    return `$${parametros.length}`;
  };
  const condiciones: string[] = ['pc.estado = $2'];

  if (filtros.nombre) {
    // Como el $regex con 'i' de Mongo: contiene, sin importar mayusculas. Los
    // comodines de LIKE que escriba la persona se buscan tal cual.
    const escapado = filtros.nombre.replace(/[\\%_]/g, (c) => `\\${c}`);
    condiciones.push(`pc.nombre ILIKE ${p(`%${escapado}%`)}`);
  }
  if (filtros.idCategoria != null) {
    condiciones.push(`pc.id_categoria = ${p(filtros.idCategoria)}`);
  }
  rango(
    condiciones,
    'pp.precio_desde',
    filtros.precioMin,
    filtros.precioMax,
    p,
    '::numeric',
  );
  rango(
    condiciones,
    'pp.precio_tienda',
    filtros.precioTiendaMin,
    filtros.precioTiendaMax,
    p,
    '::numeric',
  );
  if (filtros.estadoVariante) {
    condiciones.push(
      `EXISTS (SELECT 1 FROM variante_catalogo vc
                WHERE vc.id_producto_mongo = pc.id_producto_mongo
                  AND vc.estado = ${p(filtros.estadoVariante)})`,
    );
  }
  rango(
    condiciones,
    'COALESCE(pp.stock_total, 0)',
    filtros.stockMin,
    filtros.stockMax,
    p,
    '::int',
  );
  rango(
    condiciones,
    'COALESCE(pp.stock_tienda, 0)',
    filtros.stockTiendaMin,
    filtros.stockTiendaMax,
    p,
    '::int',
  );
  rango(
    condiciones,
    'COALESCE(n.promedio, 0)',
    filtros.resenasPromedioMin,
    filtros.resenasPromedioMax,
    p,
    '::numeric',
  );
  // Como en Mongo: filtrar por nota implica tener al menos una resena.
  let totalMin = filtros.resenasTotalMin;
  if (
    filtros.resenasPromedioMin != null ||
    filtros.resenasPromedioMax != null
  ) {
    totalMin = Math.max(totalMin ?? 0, 1);
  }
  rango(
    condiciones,
    'COALESCE(n.total, 0)',
    totalMin,
    filtros.resenasTotalMax,
    p,
    '::int',
  );

  const despuesDe = pagina.despuesDe ?? null;
  const corte = despuesDe != null ? `WHERE id > ${p(despuesDe)}` : '';
  const saltar = p(pagina.saltar ?? 0);
  const limite = p(pagina.limite);

  const { rows } = await pool.query<{ total: number; ids: string[] }>(
    `WITH tienda AS (
         SELECT id_usuario FROM usuarios WHERE correo_electronico = $1
       ),
       activa AS (
         SELECT id_estado_oferta FROM estado_oferta WHERE estado_oferta_nombre = 'activa'
       ),
       por_variante AS (
         SELECT o.id_producto_mongo AS id,
                MAX(CASE WHEN o.id_usuario = (SELECT id_usuario FROM tienda)
                         THEN ${expresionPrecioFinal('o')} END) AS precio_tienda,
                MIN(CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                         THEN ${expresionPrecioFinal('o')} END) AS precio_desde,
                SUM(CASE WHEN o.id_usuario = (SELECT id_usuario FROM tienda)
                          AND o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                         THEN o.stock ELSE 0 END) AS stock_tienda,
                SUM(CASE WHEN o.id_estado_oferta = (SELECT id_estado_oferta FROM activa)
                         THEN o.stock ELSE 0 END) AS stock_total
           FROM oferta o
          GROUP BY o.id_producto_mongo, o.id_producto_variante_mongo
       ),
       pp AS (
         SELECT id, MIN(precio_tienda) AS precio_tienda, MIN(precio_desde) AS precio_desde,
                SUM(stock_tienda) AS stock_tienda, SUM(stock_total) AS stock_total
           FROM por_variante
          GROUP BY id
       ),
       n AS (
         SELECT id_producto_mongo AS id, ROUND(AVG(calificacion), 2) AS promedio,
                COUNT(*) AS total
           FROM resena
          GROUP BY id_producto_mongo
       ),
       filtrados AS (
         SELECT pc.id_producto_mongo AS id
           FROM producto_catalogo pc
           LEFT JOIN pp ON pp.id = pc.id_producto_mongo
           LEFT JOIN n ON n.id = pc.id_producto_mongo
          WHERE ${condiciones.join('\n            AND ')}
       )
       SELECT (SELECT count(*) FROM filtrados)::int AS total,
              COALESCE((SELECT array_agg(id ORDER BY id)
                          FROM (SELECT id FROM filtrados ${corte}
                                 ORDER BY id OFFSET ${saltar} LIMIT ${limite}) pagina),
                       '{}') AS ids`,
    parametros,
  );
  const ids = rows[0].ids.map(Number);
  return {
    productos: await productosDesdePostgres(ids, true),
    total: rows[0].total,
  };
}

/**
 * Las categorias en las que se puede publicar (las que no son raiz), como
 * `CategoriasService.listarValidas`: de `categorias`, que es de donde Mongo
 * copia las suyas. Ordenadas por nombre byte a byte, como las ordena Mongo.
 */
export async function categoriasValidasDesdePostgres(): Promise<
  CategoriaValida[]
> {
  const { rows } = await pool.query<{
    id_categoria: string;
    nombre: string;
    categoria_padre: string;
  }>(
    `SELECT c.id_categoria, c.nombre, cp.nombre AS categoria_padre
       FROM categorias c
       JOIN categorias cp ON cp.id_categoria = c.id_categoria_padre
      ORDER BY c.nombre COLLATE "C"`,
  );
  return rows.map((fila) => ({
    id_categoria: Number(fila.id_categoria),
    nombre: fila.nombre,
    categoria_padre: fila.categoria_padre,
  }));
}

function agrupar<T>(filas: T[], clave: (fila: T) => string): Map<string, T[]> {
  const grupos = new Map<string, T[]>();
  for (const fila of filas) {
    const lista = grupos.get(clave(fila)) ?? [];
    lista.push(fila);
    grupos.set(clave(fila), lista);
  }
  return grupos;
}

function decimal(valor: string | null): Decimal128 | null {
  return valor != null ? Decimal128.fromString(valor) : null;
}

/** El menor de los precios que no son null, con dos decimales, como la raiz en Mongo. */
function minimo(precios: (string | null)[]): Decimal128 | null {
  const numeros = precios.filter((x): x is string => x != null).map(Number);
  return numeros.length > 0
    ? Decimal128.fromString(Math.min(...numeros).toFixed(2))
    : null;
}

function rango(
  condiciones: string[],
  columna: string,
  min: string | number | null,
  max: string | number | null,
  p: (valor: unknown) => string,
  tipo: string,
): void {
  if (min != null) {
    condiciones.push(`${columna} >= ${p(min)}${tipo}`);
  }
  if (max != null) {
    condiciones.push(`${columna} <= ${p(max)}${tipo}`);
  }
}
