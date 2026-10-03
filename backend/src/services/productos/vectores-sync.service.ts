import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { mongoDb } from '../../database/mongo';
import { elasticClient } from '../../database/elastic';
import { OLLAMA_MODELO } from '../../database/ollama';
import {
  DIMENSIONES_VECTOR as DIMENSIONES,
  LOTE_VECTORES as LOTE,
  md5,
  pedirVectores,
} from '../../helpers/vectores-ollama';
import { Producto } from '../../models/producto';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

interface ProductoPendiente {
  _id: number;
  nombre: string;
  descripcion: string | null;
  categoria: { nombre: string };
  estado: string;
}

/** Lo que ya hay en el documento de Elasticsearch de un producto. */
interface VectorIndexado {
  vector_hash?: string;
  vector_grupo?: string;
}

/** Un cambio parcial al documento: solo los campos del vector. */
interface CambioVector {
  id: number;
  doc: Record<string, unknown>;
}

/** El texto que se convierte en vector -- MISMO formato que
 * `etl/cargar_vectores.ps1` (`"$nombre. Categoria $cat. $desc"`), para que
 * el hash de un producto ya cargado por el ETL coincida si nada cambio. */
function construirTexto(producto: ProductoPendiente): string {
  return `${producto.nombre}. Categoria ${producto.categoria?.nombre ?? ''}. ${producto.descripcion ?? ''}`.trim();
}

/**
 * Recomendacion semantica de la Entrega final: el vector de cada producto
 * vive en el documento de `mesh_productos` (Elasticsearch, campo `dense_vector`
 * `vector`), junto con `vector_hash`, `vector_grupo` y `vector_modelo`. Antes
 * vivia en `producto_vector` (PostgreSQL, pgvector).
 *
 * Consume la bandera `pendiente_vector` de `Producto` -- mismo patron "cola
 * sin cola" que `BuscadorSyncService`, pero con un paso extra antes de
 * llamar a Ollama: compara el hash del texto (nombre+categoria+descripcion)
 * contra el `vector_hash` que ya tiene el documento. Si el hash no cambio (la
 * bandera se puso por un cambio de estado, o de caracteristicas/variantes
 * que no afectan el texto), NO gasta una llamada a Ollama -- solo actualiza
 * `vector_grupo` si hace falta. Es la misma logica de
 * `etl/cargar_vectores.ps1`, aplicada solo al subconjunto marcado en vez de
 * a todo el catalogo.
 *
 * Solo ESCRIBE los campos del vector, con una actualizacion parcial. Y como
 * `BuscadorSyncService` tambien actualiza el documento (con `update`, no con
 * `index`), ninguno de los dos workers borra lo del otro. Si el documento
 * todavia no existe en el indice, ese producto se deja pendiente y se
 * reintenta en la proxima corrida.
 *
 * El "activo" ya no se guarda aparte: es el `estado` del documento, que lo
 * mantiene `BuscadorSyncService`.
 */
@Injectable()
export class VectoresSyncService {
  private readonly logger = new Logger(VectoresSyncService.name);

  /** Cada 3 horas: un cambio de nombre/descripcion no es urgente, a
   * diferencia de una busqueda o una vista reciente. */
  private static readonly INTERVALO_MS = 3 * 60 * 60 * 1000;

  private procesando = false;

  @Interval('vectores-sync', VectoresSyncService.INTERVALO_MS)
  async recalcular(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;
    try {
      await this.recalcularTodos();
    } finally {
      this.procesando = false;
    }
  }

  private async recalcularTodos(): Promise<void> {
    let pendientes: ProductoPendiente[];
    try {
      pendientes = await mongoDb
        .collection<Producto>('productos')
        .find(
          { pendiente_vector: true },
          {
            projection: {
              nombre: 1,
              descripcion: 1,
              'categoria.nombre': 1,
              estado: 1,
            },
          },
        )
        .toArray();
    } catch (error) {
      this.logger.warn(
        `worker de vectores: no se pudo leer Mongo (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    if (pendientes.length === 0) {
      return;
    }

    let existentes: Map<number, VectorIndexado>;
    try {
      existentes = await this.leerIndexados(pendientes.map((p) => p._id));
    } catch (error) {
      this.logger.warn(
        `worker de vectores: no se pudo leer Elasticsearch (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    const porRecalcular: {
      producto: ProductoPendiente;
      texto: string;
      hash: string;
      grupo: string;
    }[] = [];
    const soloGrupo: CambioVector[] = [];
    const listos: number[] = [];

    for (const producto of pendientes) {
      const texto = construirTexto(producto);
      const hash = md5(texto);
      const grupo = md5(
        `${producto.categoria?.nombre ?? ''}|${producto.descripcion ?? ''}`.trim(),
      );
      const previo = existentes.get(producto._id);

      if (previo == null) {
        // El documento no esta en el indice (todavia): se reintenta luego.
        continue;
      }
      if (previo.vector_hash !== hash) {
        porRecalcular.push({ producto, texto, hash, grupo });
        continue;
      }
      if (previo.vector_grupo !== grupo) {
        soloGrupo.push({ id: producto._id, doc: { vector_grupo: grupo } });
        continue;
      }
      // Ni el texto ni el grupo cambiaron: la bandera se puso por un campo
      // que no afecta al vector (estado, caracteristicas, variantes). Nada
      // que hacer salvo bajarla.
      listos.push(producto._id);
    }

    try {
      for (const id of await this.actualizar(soloGrupo)) {
        listos.push(id);
      }
    } catch (error) {
      this.logger.warn(
        `worker de vectores: no se pudo actualizar el grupo en Elasticsearch (${(error as Error)?.message ?? error})`,
      );
    }

    let recalculados = 0;
    for (let i = 0; i < porRecalcular.length; i += LOTE) {
      const grupo = porRecalcular.slice(i, i + LOTE);
      let vectores: number[][];
      try {
        vectores = await pedirVectores(grupo.map((item) => item.texto));
      } catch (error) {
        this.logger.warn(
          `worker de vectores: Ollama fallo en el lote que empieza en ${i} (${(error as Error)?.message ?? error})`,
        );
        continue;
      }

      const cambios: CambioVector[] = [];
      for (let k = 0; k < grupo.length; k++) {
        const item = grupo[k];
        const vector = vectores[k];
        if (!Array.isArray(vector) || vector.length !== DIMENSIONES) {
          this.logger.warn(
            `worker de vectores: el modelo devolvio ${vector?.length ?? 0} dimensiones para el producto ${item.producto._id}, se esperaban ${DIMENSIONES}`,
          );
          continue;
        }
        cambios.push({
          id: item.producto._id,
          doc: {
            vector,
            vector_hash: item.hash,
            vector_grupo: item.grupo,
            vector_modelo: OLLAMA_MODELO,
          },
        });
      }

      try {
        const guardados = await this.actualizar(cambios);
        for (const id of guardados) {
          listos.push(id);
        }
        recalculados += guardados.length;
      } catch (error) {
        this.logger.warn(
          `worker de vectores: no se pudieron guardar los vectores del lote que empieza en ${i} en Elasticsearch (${(error as Error)?.message ?? error})`,
        );
      }
    }

    if (listos.length > 0) {
      try {
        await mongoDb
          .collection<Producto>('productos')
          .updateMany(
            { _id: { $in: listos } },
            { $unset: { pendiente_vector: '' } },
          );
      } catch (error) {
        this.logger.warn(
          `worker de vectores: no se pudo limpiar pendiente_vector en Mongo (${(error as Error)?.message ?? error})`,
        );
      }
    }

    this.logger.log(
      `worker de vectores: ${pendientes.length} pendiente(s), ${recalculados} recalculado(s), ${soloGrupo.length} solo grupo, ${listos.length} al dia`,
    );
  }

  /** Lo que el indice ya sabe del vector de esos productos. Un producto sin
   * documento en el indice no aparece en el mapa. */
  private async leerIndexados(
    ids: number[],
  ): Promise<Map<number, VectorIndexado>> {
    const resultado = new Map<number, VectorIndexado>();
    for (let i = 0; i < ids.length; i += 500) {
      const respuesta = await elasticClient.mget<VectorIndexado>({
        index: INDICE,
        ids: ids.slice(i, i + 500).map(String),
        _source: ['vector_hash', 'vector_grupo'],
      });
      for (const doc of respuesta.docs) {
        if ('found' in doc && doc.found) {
          resultado.set(Number(doc._id), doc._source ?? {});
        }
      }
    }
    return resultado;
  }

  /** Aplica los cambios parciales en un solo `_bulk`. Devuelve los ids que de
   * verdad se guardaron; los que fallaron (por ejemplo, documento que no
   * existe) quedan pendientes. */
  private async actualizar(cambios: CambioVector[]): Promise<number[]> {
    if (cambios.length === 0) {
      return [];
    }
    const respuesta = await elasticClient.bulk({
      operations: cambios.flatMap((cambio) => [
        { update: { _index: INDICE, _id: String(cambio.id) } },
        { doc: cambio.doc },
      ]),
    });
    const guardados: number[] = [];
    respuesta.items.forEach((item, k) => {
      const resultado = item.update;
      if (resultado?.error) {
        this.logger.warn(
          `worker de vectores: Elasticsearch rechazo el producto ${cambios[k].id} (${resultado.error.reason ?? resultado.error.type})`,
        );
        return;
      }
      guardados.push(cambios[k].id);
    });
    return guardados;
  }
}
