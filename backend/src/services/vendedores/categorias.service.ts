import { Injectable, Logger } from '@nestjs/common';
import { mongoDb } from '../../database/mongo';
import {
  ErrorConexion,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import {
  categoriasValidasDesdePostgres,
  conRespaldoDeMongo,
} from '../../helpers/catalogo-respaldo';
import { manejarErrorConexionMongo } from '../../helpers/manejar-error-mongo';
import {
  Categoria,
  CategoriaDocumento,
  CategoriaValida,
} from '../../models/categoria';

const REGEX_ID = /^\d+$/;

/**
 * Servicio de /vendedor/categorias: el menu de categorias y caracteristicas
 * que usa quien va a publicar un producto. Nunca escribe nada, solo lee la
 * coleccion `categorias` de Mongo.
 */
@Injectable()
export class CategoriasService {
  private readonly logger = new Logger(CategoriasService.name);

  /**
   * Las categorias en las que de verdad se puede publicar: las que no son
   * raiz (su `categoria_padre` no es null). Trae solo lo minimo para un
   * selector, no el menu de caracteristicas completo (para eso esta
   * obtenerPorId).
   */
  async listarValidas(): Promise<CategoriaValida[]> {
    try {
      // Sin Mongo salen de `categorias` en PostgreSQL, que es de donde Mongo
      // copia las suyas (helpers/catalogo-respaldo.ts): los filtros del
      // catalogo siguen funcionando.
      return await conRespaldoDeMongo<CategoriaValida[]>(async () => {
        const documentos = await mongoDb
          .collection<CategoriaDocumento>('categorias')
          .find(
            { categoria_padre: { $ne: null } },
            { projection: { nombre: 1, categoria_padre: 1 } },
          )
          .sort({ nombre: 1 })
          .toArray();

        return documentos.map((documento) => ({
          id_categoria: documento._id,
          nombre: documento.nombre,
          categoria_padre: documento.categoria_padre as string,
        }));
      }, categoriasValidasDesdePostgres);
    } catch (error) {
      if (error instanceof ErrorConexion) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }

  /**
   * Una categoria completa, con su menu de caracteristicas de producto y de
   * variante. Solo categorias validas (no raiz): pedir una raiz da el mismo
   * 404 que un id que no existe, porque en ninguna de las dos se puede
   * publicar.
   */
  async obtenerPorId(id: string): Promise<Categoria> {
    if (!REGEX_ID.test(id)) {
      throw new ErrorValidacion('El id no es valido');
    }

    try {
      const documento = await mongoDb
        .collection<CategoriaDocumento>('categorias')
        .findOne({ _id: Number(id), categoria_padre: { $ne: null } });

      if (documento == null) {
        throw new ErrorNoEncontrado('No existe una categoria con ese id');
      }

      const { _id, ...resto } = documento;
      return { id_categoria: _id, ...resto };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexionMongo(this.logger, error);
    }
  }
}
