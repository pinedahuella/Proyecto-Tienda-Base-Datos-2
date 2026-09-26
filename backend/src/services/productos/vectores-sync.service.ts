import { createHash } from 'crypto';
import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { pool } from '../../database/postgres';
import { mongoDb } from '../../database/mongo';
import { OLLAMA_URL, OLLAMA_MODELO } from '../../database/ollama';
import { conLimiteDeTiempo } from '../../helpers/limite-tiempo';
import { Producto } from '../../models/producto';

/** Igual que `$lote` en `etl/cargar_vectores.ps1`: cuantos textos van en una
 * sola llamada a Ollama. Ollama procesa el lote en un solo request, mas
 * barato que uno por producto. */
const LOTE = 32;
const DIMENSIONES = 768;
const LIMITE_MS_OLLAMA = 30000;

interface ProductoPendiente {
  _id: number;
  nombre: string;
  descripcion: string | null;
  categoria: { nombre: string };
  estado: string;
}

interface FilaProductoVector {
  id_producto: string;
  texto_hash: string;
  grupo: string;
  activo: boolean;
}

interface RespuestaEmbed {
  embeddings: number[][];
}

/** El texto que se convierte en vector -- MISMO formato que
 * `etl/cargar_vectores.ps1` (`"$nombre. Categoria $cat. $desc"`), para que
 * el hash de un producto ya cargado por el ETL coincida si nada cambio. */
function construirTexto(producto: ProductoPendiente): string {
  return `${producto.nombre}. Categoria ${producto.categoria?.nombre ?? ''}. ${producto.descripcion ?? ''}`.trim();
}

/** md5 del texto (para saber si cambio) o de categoria+descripcion sin el
 * nombre (el "grupo": las copias del generador solo cambian el nombre). */
function md5(texto: string): string {
  return createHash('md5').update(texto, 'utf8').digest('hex');
}

/**
 * Recomendacion semantica de la Entrega final (`producto_vector` en
 * PostgreSQL, migracion 024/pgvector, consultada por `SimilaresService`).
 *
 * Consume la bandera `pendiente_vector` de `Producto` -- mismo patron "cola
 * sin cola" que `BuscadorSyncService`, pero con un paso extra antes de
 * llamar a Ollama: compara el hash del texto (nombre+categoria+descripcion)
 * contra lo que ya hay en `producto_vector`. Si el hash no cambio (la
 * bandera se puso por un cambio de estado, o de caracteristicas/variantes
 * que no afectan el texto), NO gasta una llamada a Ollama -- solo actualiza
 * `activo`/`grupo` si hace falta. Es la misma logica de
 * `etl/cargar_vectores.ps1`, aplicada solo al subconjunto marcado en vez de
 * a todo el catalogo.
 *
 * Conviven sin problema: si `cargar_vectores.ps1` y este worker procesan el
 * mismo producto casi al mismo tiempo, el `ON CONFLICT` de Postgres deja la
 * ultima escritura (idempotente, ninguna corrompe a la otra).
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

    let existentes: Map<number, FilaProductoVector>;
    try {
      const resultado = await pool.query<FilaProductoVector>(
        `SELECT id_producto, texto_hash, COALESCE(grupo, '') AS grupo, activo
           FROM producto_vector
          WHERE id_producto = ANY($1::bigint[])`,
        [pendientes.map((p) => p._id)],
      );
      existentes = new Map(
        resultado.rows.map((fila) => [Number(fila.id_producto), fila]),
      );
    } catch (error) {
      this.logger.warn(
        `worker de vectores: no se pudo leer PostgreSQL (${(error as Error)?.message ?? error})`,
      );
      return;
    }

    const porRecalcular: {
      producto: ProductoPendiente;
      texto: string;
      hash: string;
      grupo: string;
      activo: boolean;
    }[] = [];
    const soloEstado: {
      idProducto: number;
      grupo: string;
      activo: boolean;
    }[] = [];
    const listos: number[] = [];

    for (const producto of pendientes) {
      const texto = construirTexto(producto);
      const hash = md5(texto);
      const grupo = md5(
        `${producto.categoria?.nombre ?? ''}|${producto.descripcion ?? ''}`.trim(),
      );
      const activo = producto.estado === 'activo';
      const previo = existentes.get(producto._id);

      if (previo == null || previo.texto_hash !== hash) {
        porRecalcular.push({ producto, texto, hash, grupo, activo });
        continue;
      }
      if (previo.activo !== activo || previo.grupo !== grupo) {
        soloEstado.push({ idProducto: producto._id, grupo, activo });
        continue;
      }
      // Ni el texto ni activo/grupo cambiaron: la bandera se puso por un
      // campo que no afecta al vector (caracteristicas, variantes). Nada
      // que hacer salvo bajarla.
      listos.push(producto._id);
    }

    for (const item of soloEstado) {
      try {
        await pool.query(
          'UPDATE producto_vector SET activo = $1, grupo = $2 WHERE id_producto = $3',
          [item.activo, item.grupo, item.idProducto],
        );
        listos.push(item.idProducto);
      } catch (error) {
        this.logger.warn(
          `worker de vectores: no se pudo actualizar activo/grupo del producto ${item.idProducto} (${(error as Error)?.message ?? error})`,
        );
      }
    }

    let recalculados = 0;
    for (let i = 0; i < porRecalcular.length; i += LOTE) {
      const grupo = porRecalcular.slice(i, i + LOTE);
      let vectores: number[][];
      try {
        vectores = await this.pedirVectores(grupo.map((item) => item.texto));
      } catch (error) {
        this.logger.warn(
          `worker de vectores: Ollama fallo en el lote que empieza en ${i} (${(error as Error)?.message ?? error})`,
        );
        continue;
      }

      for (let k = 0; k < grupo.length; k++) {
        const item = grupo[k];
        const vector = vectores[k];
        if (!Array.isArray(vector) || vector.length !== DIMENSIONES) {
          this.logger.warn(
            `worker de vectores: el modelo devolvio ${vector?.length ?? 0} dimensiones para el producto ${item.producto._id}, se esperaban ${DIMENSIONES}`,
          );
          continue;
        }
        try {
          await pool.query(
            `INSERT INTO producto_vector (id_producto, modelo, texto_hash, grupo, activo, vector)
             VALUES ($1, $2, $3, $4, $5, $6::vector)
             ON CONFLICT (id_producto) DO UPDATE SET
               modelo = EXCLUDED.modelo,
               texto_hash = EXCLUDED.texto_hash,
               grupo = EXCLUDED.grupo,
               activo = EXCLUDED.activo,
               vector = EXCLUDED.vector,
               fecha_calculo = now()`,
            [
              item.producto._id,
              OLLAMA_MODELO,
              item.hash,
              item.grupo,
              item.activo,
              `[${vector.join(',')}]`,
            ],
          );
          listos.push(item.producto._id);
          recalculados++;
        } catch (error) {
          this.logger.warn(
            `worker de vectores: no se pudo guardar el vector del producto ${item.producto._id} (${(error as Error)?.message ?? error})`,
          );
        }
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
      `worker de vectores: ${pendientes.length} pendiente(s), ${recalculados} recalculado(s), ${soloEstado.length} solo activo/grupo, ${listos.length} al dia`,
    );
  }

  private async pedirVectores(textos: string[]): Promise<number[][]> {
    const respuesta = await conLimiteDeTiempo(
      fetch(`${OLLAMA_URL}/api/embed`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: OLLAMA_MODELO, input: textos }),
      }),
      LIMITE_MS_OLLAMA,
      'Ollama',
    );
    if (!respuesta.ok) {
      throw new Error(`Ollama respondio ${respuesta.status}`);
    }
    const cuerpo = (await respuesta.json()) as RespuestaEmbed;
    return cuerpo.embeddings;
  }
}
