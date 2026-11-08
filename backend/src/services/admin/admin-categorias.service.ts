import { Injectable, Logger } from '@nestjs/common';
import type { PoolClient } from 'pg';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import type {
  CaracteristicaDefinicion,
  CategoriaDocumento,
  TipoDato,
} from '../../models/categoria';

const REGEX_ID = /^\d+$/;
const TIPOS: TipoDato[] = ['texto', 'entero', 'decimal', 'booleano', 'lista'];

/** Una caracteristica tal como llega en el cuerpo de una peticion. */
export interface CaracteristicaPeticion {
  nombre?: unknown;
  tipo_dato?: unknown;
  unidad?: unknown;
}

/** POST /admin/categorias */
export interface CrearCategoriaPeticion {
  nombre?: unknown;
  id_categoria_padre?: unknown;
  caracteristicas?: CaracteristicaPeticion[];
  caracteristicas_variante?: CaracteristicaPeticion[];
}

/** POST /admin/categorias/:id/caracteristicas */
export interface AgregarCaracteristicaPeticion extends CaracteristicaPeticion {
  /** `producto` va a categoria_caracteristica, `variante` a la de variante. */
  para?: unknown;
}

/** Una fila de GET /admin/categorias. */
export interface CategoriaDeLaTienda {
  id_categoria: number;
  nombre: string;
  id_categoria_padre: number | null;
  categoria_padre: string | null;
  es_raiz: boolean;
  productos: number;
  caracteristicas: CaracteristicaDefinicion[];
  caracteristicas_variante: CaracteristicaDefinicion[];
}

/**
 * La tienda crea categorias, les cambia el nombre y les agrega
 * caracteristicas (`/admin/categorias`, permiso `catalogo.categorias`,
 * migracion 054).
 *
 * PostgreSQL es el dueno de la paleta (003 y 004) y la coleccion `categorias`
 * de MongoDB es su copia, la que lee el formulario de publicar. Cada cambio se
 * escribe en PostgreSQL dentro de una transaccion, se copia a MongoDB con la
 * misma forma que le da el ETL (etl/cargar.js) y solo entonces se confirma: si
 * MongoDB no contesta, PostgreSQL se deshace y las dos quedan iguales.
 *
 * Cambiar el nombre no recorre productos uno por uno. Cada producto de MongoDB
 * lleva `{id_categoria, nombre, categoria_padre}`; un solo updateMany por
 * id_categoria lo cambia en todos y los marca `pendiente_busqueda` y
 * `pendiente_vector`: el worker del buscador los reindexa y el de vectores los
 * recalcula, porque el nombre de la categoria va en el texto del vector. Agregar una caracteristica no toca ningun
 * producto: cada uno guarda solo las que llena.
 */
@Injectable()
export class AdminCategoriasService {
  private readonly logger = new Logger(AdminCategoriasService.name);

  /** Todas las categorias, raices y finales, con su paleta y cuantos productos tienen. */
  async listar(): Promise<{
    categorias: CategoriaDeLaTienda[];
    tipos_dato: TipoDato[];
  }> {
    try {
      const { rows } = await pool.query<{
        id_categoria: string;
        nombre: string;
        id_categoria_padre: string | null;
        categoria_padre: string | null;
        productos: number;
      }>(
        `SELECT c.id_categoria, c.nombre, c.id_categoria_padre, p.nombre AS categoria_padre,
                (SELECT count(*)::int FROM producto_catalogo pc WHERE pc.id_categoria = c.id_categoria) AS productos
           FROM categorias c
           LEFT JOIN categorias p ON p.id_categoria = c.id_categoria_padre
          ORDER BY COALESCE(p.nombre, c.nombre), c.id_categoria_padre NULLS FIRST, c.nombre`,
      );
      const paletas = await this.paletas();
      return {
        categorias: rows.map((f) => ({
          id_categoria: Number(f.id_categoria),
          nombre: f.nombre,
          id_categoria_padre:
            f.id_categoria_padre == null ? null : Number(f.id_categoria_padre),
          categoria_padre: f.categoria_padre,
          es_raiz: f.id_categoria_padre == null,
          productos: f.productos,
          caracteristicas: paletas.get(Number(f.id_categoria))?.producto ?? [],
          caracteristicas_variante:
            paletas.get(Number(f.id_categoria))?.variante ?? [],
        })),
        tipos_dato: TIPOS,
      };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /** Crea una categoria final debajo de una raiz, con su paleta. */
  async crear(
    datos: CrearCategoriaPeticion | undefined,
  ): Promise<CategoriaDeLaTienda> {
    const nombre = this.validarNombre(datos?.nombre);
    const padre = datos?.id_categoria_padre;
    const idPadre =
      typeof padre === 'number' || typeof padre === 'string'
        ? String(padre)
        : '';
    if (!REGEX_ID.test(idPadre)) {
      throw new ErrorValidacion(
        'id_categoria_padre tiene que ser el id de una categoria raiz',
      );
    }
    const deProducto = (datos?.caracteristicas ?? []).map((c) =>
      this.validarCaracteristica(c),
    );
    const deVariante = (datos?.caracteristicas_variante ?? []).map((c) =>
      this.validarCaracteristica(c),
    );
    this.sinRepetidas(deProducto, 'caracteristicas');
    this.sinRepetidas(deVariante, 'caracteristicas_variante');

    return this.enTransaccion(async (cliente) => {
      const padre = await cliente.query<{
        nombre: string;
        id_categoria_padre: string | null;
      }>(
        'SELECT nombre, id_categoria_padre FROM categorias WHERE id_categoria = $1',
        [idPadre],
      );
      if (padre.rows.length === 0 || padre.rows[0].id_categoria_padre != null) {
        throw new ErrorValidacion(
          'La categoria padre tiene que ser una raiz, como Hogar o Tecnologia',
        );
      }
      await this.exigirNombreLibre(cliente, nombre, null);

      const nueva = await cliente.query<{
        id_categoria: string;
        fecha_creacion: Date;
      }>(
        `INSERT INTO categorias (nombre, id_categoria_padre) VALUES ($1, $2)
         RETURNING id_categoria, fecha_creacion`,
        [nombre, idPadre],
      );
      const id = Number(nueva.rows[0].id_categoria);
      for (const c of deProducto)
        await this.enlazar(cliente, id, c, 'producto');
      for (const c of deVariante)
        await this.enlazar(cliente, id, c, 'variante');

      const documento: CategoriaDocumento = {
        _id: id,
        nombre,
        categoria_padre: padre.rows[0].nombre,
        es_raiz: false,
        fecha_creacion: nueva.rows[0].fecha_creacion,
        caracteristicas: deProducto,
        caracteristicas_variante: deVariante,
      };
      await mongoDb
        .collection<CategoriaDocumento>('categorias')
        .replaceOne({ _id: id }, documento, { upsert: true });

      return {
        id_categoria: id,
        nombre,
        id_categoria_padre: Number(idPadre),
        categoria_padre: padre.rows[0].nombre,
        es_raiz: false,
        productos: 0,
        caracteristicas: deProducto,
        caracteristicas_variante: deVariante,
      };
    });
  }

  /** Le cambia el nombre a una categoria, en PostgreSQL, en su copia y en sus productos. */
  async renombrar(
    idParametro: string,
    nombreNuevo: unknown,
  ): Promise<{
    id_categoria: number;
    nombre: string;
    productos_actualizados: number;
  }> {
    if (!REGEX_ID.test(idParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const id = Number(idParametro);
    const nombre = this.validarNombre(nombreNuevo);

    return this.enTransaccion(async (cliente) => {
      const actual = await cliente.query<{
        nombre: string;
        id_categoria_padre: string | null;
      }>(
        'SELECT nombre, id_categoria_padre FROM categorias WHERE id_categoria = $1 FOR UPDATE',
        [id],
      );
      if (actual.rows.length === 0) {
        throw new ErrorNoEncontrado('No existe una categoria con ese id');
      }
      const viejo = actual.rows[0].nombre;
      if (viejo === nombre) {
        throw new ErrorConflicto('La categoria ya se llama asi');
      }
      await this.exigirNombreLibre(cliente, nombre, id);
      await cliente.query(
        'UPDATE categorias SET nombre = $1 WHERE id_categoria = $2',
        [nombre, id],
      );

      const categorias = mongoDb.collection<CategoriaDocumento>('categorias');
      await categorias.updateOne({ _id: id }, { $set: { nombre } });
      const productos = mongoDb.collection('productos');
      const propios = await productos.updateMany(
        { 'categoria.id_categoria': id },
        {
          $set: {
            'categoria.nombre': nombre,
            pendiente_busqueda: true,
            pendiente_vector: true,
          },
        },
      );
      let actualizados = propios.modifiedCount;
      if (actual.rows[0].id_categoria_padre == null) {
        // Una raiz: sus hijas y los productos de sus hijas la nombran como padre.
        await categorias.updateMany(
          { categoria_padre: viejo },
          { $set: { categoria_padre: nombre } },
        );
        const hijos = await productos.updateMany(
          { 'categoria.categoria_padre': viejo },
          {
            $set: {
              'categoria.categoria_padre': nombre,
              pendiente_busqueda: true,
            },
          },
        );
        actualizados += hijos.modifiedCount;
      }
      return { id_categoria: id, nombre, productos_actualizados: actualizados };
    });
  }

  /** Agrega una caracteristica a la paleta de una categoria final. */
  async agregarCaracteristica(
    idParametro: string,
    datos: AgregarCaracteristicaPeticion | undefined,
  ): Promise<{
    id_categoria: number;
    para: 'producto' | 'variante';
    caracteristica: CaracteristicaDefinicion;
  }> {
    if (!REGEX_ID.test(idParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const id = Number(idParametro);
    const para = datos?.para ?? 'producto';
    if (para !== 'producto' && para !== 'variante') {
      throw new ErrorValidacion('para tiene que ser producto o variante');
    }
    const caracteristica = this.validarCaracteristica(datos ?? {});

    return this.enTransaccion(async (cliente) => {
      const categoria = await cliente.query<{
        id_categoria_padre: string | null;
      }>('SELECT id_categoria_padre FROM categorias WHERE id_categoria = $1', [
        id,
      ]);
      if (categoria.rows.length === 0) {
        throw new ErrorNoEncontrado('No existe una categoria con ese id');
      }
      if (categoria.rows[0].id_categoria_padre == null) {
        throw new ErrorValidacion(
          'Una categoria raiz no tiene productos, se le agrega a una de sus hijas',
        );
      }
      const definicion = await this.enlazar(cliente, id, caracteristica, para);
      await mongoDb.collection<CategoriaDocumento>('categorias').updateOne(
        { _id: id },
        {
          $push:
            para === 'producto'
              ? { caracteristicas: definicion }
              : { caracteristicas_variante: definicion },
        },
      );
      return { id_categoria: id, para, caracteristica: definicion };
    });
  }

  // ---------------------------------------------------------------------
  // privados
  // ---------------------------------------------------------------------

  /**
   * Enlaza una caracteristica a la categoria. Si ya existe con ese nombre se
   * reutiliza (el nombre es UNIQUE en la 004) siempre que sea del mismo tipo;
   * si no existe, se crea. Devuelve la definicion tal como queda guardada.
   */
  private async enlazar(
    cliente: PoolClient,
    idCategoria: number,
    c: CaracteristicaDefinicion,
    para: 'producto' | 'variante',
  ): Promise<CaracteristicaDefinicion> {
    const tabla =
      para === 'producto' ? 'caracteristica' : 'caracteristica_variante';
    const enlace =
      para === 'producto'
        ? 'categoria_caracteristica'
        : 'categoria_caracteristica_variante';
    const columna =
      para === 'producto' ? 'id_caracteristica' : 'id_caracteristica_variante';

    const existente = await cliente.query<{
      id: string;
      tipo_dato: TipoDato;
      unidad: string | null;
    }>(
      `SELECT c.id_caracteristica AS id, td.tipo_dato, c.unidad
         FROM ${tabla} c JOIN tipo_dato td ON td.id_tipo_dato = c.id_tipo_dato
        WHERE lower(c.nombre) = lower($1)`,
      [c.nombre],
    );
    let idCaracteristica: string;
    let definicion: CaracteristicaDefinicion;
    if (existente.rows.length > 0) {
      const e = existente.rows[0];
      if (e.tipo_dato !== c.tipo_dato) {
        throw new ErrorConflicto(
          `Ya existe una caracteristica ${c.nombre} de tipo ${e.tipo_dato}. Usa ese tipo o otro nombre`,
        );
      }
      idCaracteristica = e.id;
      definicion = {
        nombre: c.nombre,
        tipo_dato: e.tipo_dato,
        unidad: e.unidad,
      };
    } else {
      const nueva = await cliente.query<{ id: string }>(
        `INSERT INTO ${tabla} (nombre, id_tipo_dato, unidad)
         VALUES ($1, (SELECT id_tipo_dato FROM tipo_dato WHERE tipo_dato = $2), $3)
         RETURNING id_caracteristica AS id`,
        [c.nombre, c.tipo_dato, c.unidad],
      );
      idCaracteristica = nueva.rows[0].id;
      definicion = c;
    }

    const insertado = await cliente.query(
      `INSERT INTO ${enlace} (id_categoria, ${columna}) VALUES ($1, $2)
       ON CONFLICT DO NOTHING`,
      [idCategoria, idCaracteristica],
    );
    if (insertado.rowCount === 0) {
      throw new ErrorConflicto(`La categoria ya ofrece ${c.nombre}`);
    }
    // El nombre tal como esta en la base, por si se escribio con otras mayusculas.
    const guardado = await cliente.query<{ nombre: string }>(
      `SELECT nombre FROM ${tabla} WHERE id_caracteristica = $1`,
      [idCaracteristica],
    );
    return { ...definicion, nombre: guardado.rows[0].nombre };
  }

  /** La paleta de cada categoria, leida de PostgreSQL. */
  private async paletas(): Promise<
    Map<
      number,
      {
        producto: CaracteristicaDefinicion[];
        variante: CaracteristicaDefinicion[];
      }
    >
  > {
    const { rows } = await pool.query<{
      id_categoria: string;
      para: 'producto' | 'variante';
      nombre: string;
      tipo_dato: TipoDato;
      unidad: string | null;
    }>(
      `SELECT cc.id_categoria, 'producto' AS para, c.nombre, td.tipo_dato, c.unidad
         FROM categoria_caracteristica cc
         JOIN caracteristica c ON c.id_caracteristica = cc.id_caracteristica
         JOIN tipo_dato td ON td.id_tipo_dato = c.id_tipo_dato
       UNION ALL
       SELECT cv.id_categoria, 'variante', c.nombre, td.tipo_dato, c.unidad
         FROM categoria_caracteristica_variante cv
         JOIN caracteristica_variante c ON c.id_caracteristica = cv.id_caracteristica_variante
         JOIN tipo_dato td ON td.id_tipo_dato = c.id_tipo_dato
        ORDER BY 1, 2, 3`,
    );
    const mapa = new Map<
      number,
      {
        producto: CaracteristicaDefinicion[];
        variante: CaracteristicaDefinicion[];
      }
    >();
    for (const f of rows) {
      const id = Number(f.id_categoria);
      const p = mapa.get(id) ?? { producto: [], variante: [] };
      p[f.para].push({
        nombre: f.nombre,
        tipo_dato: f.tipo_dato,
        unidad: f.unidad,
      });
      mapa.set(id, p);
    }
    return mapa;
  }

  private validarNombre(valor: unknown): string {
    if (typeof valor !== 'string') {
      throw new ErrorValidacion('El nombre es obligatorio');
    }
    const nombre = valor.trim().replace(/\s+/g, ' ');
    if (nombre.length < 2 || nombre.length > 100) {
      throw new ErrorValidacion(
        'El nombre tiene que tener entre 2 y 100 letras',
      );
    }
    return nombre;
  }

  private validarCaracteristica(
    c: CaracteristicaPeticion,
  ): CaracteristicaDefinicion {
    const nombre = this.validarNombre(c?.nombre);
    if (!TIPOS.includes(c?.tipo_dato as TipoDato)) {
      throw new ErrorValidacion(`tipo_dato tiene que ser ${TIPOS.join(', ')}`);
    }
    let unidad: string | null = null;
    if (c.unidad != null && c.unidad !== '') {
      if (typeof c.unidad !== 'string' || c.unidad.trim().length > 20) {
        throw new ErrorValidacion(
          'La unidad es un texto corto, de hasta 20 letras',
        );
      }
      unidad = c.unidad.trim();
    }
    return { nombre, tipo_dato: c.tipo_dato as TipoDato, unidad };
  }

  private sinRepetidas(lista: CaracteristicaDefinicion[], campo: string): void {
    const vistos = new Set<string>();
    for (const c of lista) {
      const llave = c.nombre.toLowerCase();
      if (vistos.has(llave)) {
        throw new ErrorValidacion(`${c.nombre} va dos veces en ${campo}`);
      }
      vistos.add(llave);
    }
  }

  /** Dos categorias con el mismo nombre confundirian el selector y los filtros. */
  private async exigirNombreLibre(
    cliente: PoolClient,
    nombre: string,
    salvo: number | null,
  ): Promise<void> {
    const { rows } = await cliente.query(
      'SELECT 1 FROM categorias WHERE lower(nombre) = lower($1) AND ($2::bigint IS NULL OR id_categoria <> $2)',
      [nombre, salvo],
    );
    if (rows.length > 0) {
      throw new ErrorConflicto(`Ya hay una categoria que se llama ${nombre}`);
    }
  }

  /**
   * Corre el trabajo en una transaccion de PostgreSQL. La escritura en MongoDB
   * va adentro, antes del COMMIT: si falla, PostgreSQL se deshace.
   */
  private async enTransaccion<T>(
    trabajo: (cliente: PoolClient) => Promise<T>,
  ): Promise<T> {
    const cliente = await pool.connect();
    try {
      await cliente.query('BEGIN');
      const resultado = await trabajo(cliente);
      await cliente.query('COMMIT');
      return resultado;
    } catch (error) {
      try {
        await cliente.query('ROLLBACK');
      } catch {
        // Sin conexion no hay nada que deshacer; sigue el error original.
      }
      if (
        error instanceof ErrorValidacion ||
        error instanceof ErrorConflicto ||
        error instanceof ErrorNoEncontrado
      ) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    } finally {
      cliente.release();
    }
  }
}
