import { Injectable, Logger } from '@nestjs/common';
import { Interval } from '@nestjs/schedule';
import { mongoDb } from '../../database/mongo';
import { pool } from '../../database/postgres';
import { OLLAMA_MODELO } from '../../database/ollama';
import {
  DIMENSIONES_VECTOR as DIMENSIONES,
  LOTE_VECTORES as LOTE,
  md5,
  pedirVectores,
} from '../../helpers/vectores-ollama';
import { aVectorPg } from '../../helpers/vectores-pgvector';
import { Producto } from '../../models/producto';

interface ProductoPendiente {
  _id: number;
  nombre: string;
  descripcion: string | null;
  categoria: { nombre: string };
  estado: string;
}

/** Lo que ya hay en `vector_producto` de un producto. */
interface VectorGuardado {
  texto_hash: string;
  grupo: string;
  activo: boolean;
}

/** Un vector nuevo, listo para guardarse. */
interface VectorNuevo {
  id: number;
  vector: number[];
  hash: string;
  grupo: string;
  activo: boolean;
}

/** El texto que se convierte en vector -- MISMO formato que
 * `etl/cargar_vectores.ps1` (`"$nombre. Categoria $cat. $desc"`), para que
 * el hash de un producto ya cargado por el ETL coincida si nada cambio. */
function construirTexto(producto: ProductoPendiente): string {
  return `${producto.nombre}. Categoria ${producto.categoria?.nombre ?? ''}. ${producto.descripcion ?? ''}`.trim();
}

/**
 * Recomendacion semantica de la Entrega final: el vector de cada producto
 * vive en `vector_producto` (PostgreSQL, pgvector), junto con su `texto_hash`,
 * su `grupo` y si esta `activo`. Ver
 * `elementos Generales/plan pendiente/vectores-pgvector.md`.
 *
 * Consume la bandera `pendiente_vector` de `Producto` -- mismo patron "cola
 * sin cola" que `BuscadorSyncService`, pero con un paso extra antes de
 * llamar a Ollama: compara el hash del texto (nombre+categoria+descripcion)
 * contra el `texto_hash` que ya tiene la fila. Si el hash no cambio (la
 * bandera se puso por un cambio de estado, o de caracteristicas/variantes
 * que no afectan el texto), NO gasta una llamada a Ollama -- solo actualiza
 * `grupo` y `activo` si hace falta. Es la misma logica de
 * `etl/cargar_vectores.ps1`, aplicada solo al subconjunto marcado en vez de
 * a todo el catalogo.
 *
 * Si el producto todavia no esta en `producto_catalogo` (la FK de
 * `vector_producto`), se deja pendiente y se reintenta en la proxima corrida.
 */
@Injectable()
export class VectoresSyncService {
  private readonly logger = new Logger(VectoresSyncService.name);

  /** Cada 10 segundos, como `BuscadorSyncService`: `activo` decide que
   * productos salen en las busquedas por significado, y un producto que se
   * desactiva no puede seguir saliendo horas despues. Ollama solo se llama
   * cuando cambia el texto, no en cada corrida. */
  private static readonly INTERVALO_MS = 10000;

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

    let guardados: Map<number, VectorGuardado | null>;
    try {
      guardados = await this.leerGuardados(pendientes.map((p) => p._id));
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
    const listos: number[] = [];
    // Lo que se proceso de cada producto: si al bajar la bandera el documento
    // ya dice otra cosa, se cambio mientras se calculaba y va otra vez.
    const firmas = new Map<number, string>();
    let soloGrupoOActivo = 0;

    for (const producto of pendientes) {
      if (!guardados.has(producto._id)) {
        // Todavia no esta en producto_catalogo: se reintenta luego.
        continue;
      }
      const texto = construirTexto(producto);
      const hash = md5(texto);
      const grupo = md5(
        `${producto.categoria?.nombre ?? ''}|${producto.descripcion ?? ''}`.trim(),
      );
      const activo = producto.estado === 'activo';
      firmas.set(producto._id, firmaDe(producto));
      const previo = guardados.get(producto._id);

      if (previo == null || previo.texto_hash !== hash) {
        porRecalcular.push({ producto, texto, hash, grupo, activo });
        continue;
      }
      if (previo.grupo !== grupo || previo.activo !== activo) {
        try {
          await pool.query(
            `UPDATE vector_producto SET grupo = $2, activo = $3
              WHERE id_producto_mongo = $1`,
            [producto._id, grupo, activo],
          );
          soloGrupoOActivo++;
        } catch (error) {
          this.logger.warn(
            `worker de vectores: no se pudo actualizar el producto ${producto._id} (${(error as Error)?.message ?? error})`,
          );
          continue;
        }
      }
      // Si nada cambio, la bandera se puso por un campo que no afecta al
      // vector (caracteristicas, variantes): solo hay que bajarla.
      listos.push(producto._id);
    }

    let recalculados = 0;
    for (let i = 0; i < porRecalcular.length; i += LOTE) {
      const lote = porRecalcular.slice(i, i + LOTE);
      let vectores: number[][];
      try {
        vectores = await pedirVectores(lote.map((item) => item.texto));
      } catch (error) {
        this.logger.warn(
          `worker de vectores: Ollama fallo en el lote que empieza en ${i} (${(error as Error)?.message ?? error})`,
        );
        continue;
      }

      const nuevos: VectorNuevo[] = [];
      for (let k = 0; k < lote.length; k++) {
        const item = lote[k];
        const vector = vectores[k];
        if (!Array.isArray(vector) || vector.length !== DIMENSIONES) {
          this.logger.warn(
            `worker de vectores: el modelo devolvio ${vector?.length ?? 0} dimensiones para el producto ${item.producto._id}, se esperaban ${DIMENSIONES}`,
          );
          continue;
        }
        nuevos.push({
          id: item.producto._id,
          vector,
          hash: item.hash,
          grupo: item.grupo,
          activo: item.activo,
        });
      }

      try {
        await this.guardar(nuevos);
        for (const nuevo of nuevos) {
          listos.push(nuevo.id);
        }
        recalculados += nuevos.length;
      } catch (error) {
        this.logger.warn(
          `worker de vectores: no se pudieron guardar los vectores del lote que empieza en ${i} en PostgreSQL (${(error as Error)?.message ?? error})`,
        );
      }
    }

    if (listos.length > 0) {
      try {
        // Uno por uno y de forma atomica, devolviendo el documento de ANTES:
        // si alguien lo cambio mientras Ollama calculaba (y volvio a poner la
        // bandera), el vector guardado es del texto viejo y la bandera vuelve
        // a subir. Antes un updateMany la bajaba a ciegas y ese cambio se
        // perdia (la misma carrera que tenia el worker del buscador).
        const coleccion = mongoDb.collection<Producto>('productos');
        for (const id of listos) {
          const antes = await coleccion.findOneAndUpdate(
            { _id: id },
            { $unset: { pendiente_vector: '' } },
            { returnDocument: 'before' },
          );
          if (antes != null && firmaDe(antes) !== firmas.get(id)) {
            await coleccion.updateOne(
              { _id: id },
              { $set: { pendiente_vector: true } },
            );
          }
        }
      } catch (error) {
        this.logger.warn(
          `worker de vectores: no se pudo limpiar pendiente_vector en Mongo (${(error as Error)?.message ?? error})`,
        );
      }
    }

    this.logger.log(
      `worker de vectores: ${pendientes.length} pendiente(s), ${recalculados} recalculado(s), ${soloGrupoOActivo} solo grupo o activo, ${listos.length} al dia`,
    );
  }

  /** Lo que `vector_producto` ya sabe de esos productos: `null` si estan en
   * `producto_catalogo` pero sin vector todavia. Uno que ni siquiera esta en
   * `producto_catalogo` no aparece en el mapa. */
  private async leerGuardados(
    ids: number[],
  ): Promise<Map<number, VectorGuardado | null>> {
    const { rows } = await pool.query<{
      id_producto_mongo: string;
      texto_hash: string | null;
      grupo: string | null;
      activo: boolean | null;
    }>(
      `SELECT pc.id_producto_mongo, v.texto_hash, v.grupo, v.activo
         FROM producto_catalogo pc
         LEFT JOIN vector_producto v USING (id_producto_mongo)
        WHERE pc.id_producto_mongo = ANY($1::bigint[])`,
      [ids],
    );
    return new Map(
      rows.map((fila) => [
        Number(fila.id_producto_mongo),
        fila.texto_hash == null
          ? null
          : {
              texto_hash: fila.texto_hash,
              grupo: fila.grupo!,
              activo: fila.activo!,
            },
      ]),
    );
  }

  /** Guarda los vectores de un lote en una sola sentencia (UPSERT). */
  private async guardar(nuevos: VectorNuevo[]): Promise<void> {
    if (nuevos.length === 0) {
      return;
    }
    await pool.query(
      `INSERT INTO vector_producto
              (id_producto_mongo, vector, texto_hash, grupo, activo, modelo)
       SELECT t.id, t.vector::vector, t.hash, t.grupo, t.activo, $6
         FROM unnest($1::bigint[], $2::text[], $3::text[], $4::text[], $5::boolean[])
                AS t (id, vector, hash, grupo, activo)
       ON CONFLICT (id_producto_mongo) DO UPDATE SET
         vector = EXCLUDED.vector,
         texto_hash = EXCLUDED.texto_hash,
         grupo = EXCLUDED.grupo,
         activo = EXCLUDED.activo,
         modelo = EXCLUDED.modelo,
         fecha_calculo = now()`,
      [
        nuevos.map((n) => n.id),
        nuevos.map((n) => aVectorPg(n.vector)),
        nuevos.map((n) => n.hash),
        nuevos.map((n) => n.grupo),
        nuevos.map((n) => n.activo),
        OLLAMA_MODELO,
      ],
    );
  }
}

/**
 * Lo que decide el vector de un producto y sus dos banderas de vector_producto:
 * el texto (su md5), el grupo de copias y si esta activo. Si cambia, hay que
 * volver a pasar por el worker.
 */
function firmaDe(producto: ProductoPendiente): string {
  const grupo = md5(
    `${producto.categoria?.nombre ?? ''}|${producto.descripcion ?? ''}`.trim(),
  );
  return `${md5(construirTexto(producto))}|${grupo}|${producto.estado === 'activo'}`;
}
