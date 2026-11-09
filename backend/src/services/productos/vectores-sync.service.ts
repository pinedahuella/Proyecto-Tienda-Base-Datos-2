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
import {
  EntradaCaracteristica,
  Producto,
  ValorCaracteristica,
} from '../../models/producto';

interface ProductoPendiente {
  _id: number;
  nombre: string;
  descripcion: string | null;
  categoria: { nombre: string };
  estado: string;
  caracteristicas_adicionales?: EntradaCaracteristica[];
  caracteristicas_personalizadas?: EntradaCaracteristica[];
  variantes?: {
    caracteristicas_adicionales?: EntradaCaracteristica[];
    caracteristicas_personalizadas?: EntradaCaracteristica[];
  }[];
}

/** Lo que ya hay en `vector_producto` de un producto. */
interface VectorGuardado {
  texto_hash: string;
  grupo: string;
  activo: boolean;
  /** null si el vector de caracteristicas todavia no se calculo (055). */
  caracteristicas_hash: string | null;
}

/** Un vector nuevo, listo para guardarse. */
interface VectorNuevo {
  id: number;
  vector: number[];
  hash: string;
  grupo: string;
  activo: boolean;
}

/** Un vector de caracteristicas nuevo. `vector` null si no tiene ninguna. */
interface VectorCaracNuevo {
  id: number;
  vector: number[] | null;
  hash: string;
}

/** El texto que se convierte en vector -- MISMO formato que
 * `etl/cargar_vectores.ps1` (`"$nombre. Categoria $cat. $desc"`), para que
 * el hash de un producto ya cargado por el ETL coincida si nada cambio. */
function construirTexto(producto: ProductoPendiente): string {
  return `${producto.nombre}. Categoria ${producto.categoria?.nombre ?? ''}. ${producto.descripcion ?? ''}`.trim();
}

/** Un valor de caracteristica como texto, con su unidad si la tiene. */
function valorComoTexto(
  valor: ValorCaracteristica,
  unidad: string | null,
): string {
  let texto: string;
  if (Array.isArray(valor)) {
    texto = valor
      .map((v) => String(v).trim())
      .filter(Boolean)
      .join(', ');
  } else if (typeof valor === 'boolean') {
    texto = valor ? 'si' : 'no';
  } else {
    texto = String(valor ?? '').trim();
  }
  if (!texto) {
    return '';
  }
  return unidad ? `${texto} ${unidad}` : texto;
}

/**
 * El texto del segundo vector (migracion 055): las caracteristicas del
 * producto y las de todas sus variantes, una por nombre, ordenadas por nombre,
 * cada una con sus valores sin repetir, en el orden en que aparecen. Por
 * ejemplo "Color Gris grafito. Marca Aurora. Memoria RAM 16 GB, 32 GB."
 *
 * Ordenar por nombre hace que la huella no cambie si solo cambia el orden en
 * que estan guardadas. Vacio si el producto no tiene ninguna. Solo lo arma
 * este worker: el ETL del arranque deja estos vectores para el, asi el texto
 * tiene una sola forma de escribirse.
 */
export function construirTextoCaracteristicas(
  producto: ProductoPendiente,
): string {
  const valores = new Map<string, string[]>();
  const sumar = (lista?: EntradaCaracteristica[]) => {
    for (const c of lista ?? []) {
      const nombre = (c?.nombre ?? '').trim();
      const texto = nombre ? valorComoTexto(c.valor, c.unidad) : '';
      if (!texto) {
        continue;
      }
      const vistos = valores.get(nombre) ?? [];
      if (!vistos.includes(texto)) {
        vistos.push(texto);
      }
      valores.set(nombre, vistos);
    }
  };
  sumar(producto.caracteristicas_adicionales);
  sumar(producto.caracteristicas_personalizadas);
  for (const variante of producto.variantes ?? []) {
    sumar(variante.caracteristicas_adicionales);
    sumar(variante.caracteristicas_personalizadas);
  }
  return [...valores.keys()]
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
    .map((nombre) => `${nombre} ${valores.get(nombre)!.join(', ')}.`)
    .join(' ');
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
 * contra el `texto_hash` que ya tiene la fila, y el de caracteristicas
 * contra `caracteristicas_hash` (migracion 055). Si ninguna huella cambio (la
 * bandera se puso al aprobarlo o retirarlo), NO gasta una llamada a Ollama --
 * solo actualiza `grupo` y `activo` si hace falta. Es la misma logica de
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
              caracteristicas_adicionales: 1,
              caracteristicas_personalizadas: 1,
              'variantes.caracteristicas_adicionales': 1,
              'variantes.caracteristicas_personalizadas': 1,
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
      /** El texto y la huella del segundo vector, el de caracteristicas. */
      textoCarac: string;
      hashCarac: string;
      /** Que vector hay que pedirle a Ollama, uno o los dos. */
      general: boolean;
      carac: boolean;
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
      const textoCarac = construirTextoCaracteristicas(producto);
      const hashCarac = md5(textoCarac);
      firmas.set(producto._id, firmaDe(producto));
      const previo = guardados.get(producto._id);
      const general = previo == null || previo.texto_hash !== hash;
      const carac = previo == null || previo.caracteristicas_hash !== hashCarac;

      if (general || carac) {
        if (
          previo != null &&
          !general &&
          (previo.grupo !== grupo || previo.activo !== activo)
        ) {
          // Solo cambian las caracteristicas: el general se queda, pero el
          // grupo y si esta activo se ponen al dia igual.
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
        porRecalcular.push({
          producto,
          texto,
          hash,
          grupo,
          activo,
          textoCarac,
          hashCarac,
          general,
          carac,
        });
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
      // Si nada cambio, la bandera se puso por un cambio que no toca ninguno
      // de los dos textos: solo hay que bajarla.
      listos.push(producto._id);
    }

    let recalculados = 0;
    let caracRecalculados = 0;
    // Cada producto pide uno o dos textos, asi que el lote de productos es la
    // mitad del de textos: nunca pasan de LOTE textos por llamada a Ollama.
    const loteProductos = Math.max(1, Math.floor(LOTE / 2));
    for (let i = 0; i < porRecalcular.length; i += loteProductos) {
      const lote = porRecalcular.slice(i, i + loteProductos);
      // Que texto va en que posicion: el general y, si tiene, el de
      // caracteristicas. Un producto sin caracteristicas no gasta llamada.
      const textos: string[] = [];
      const posiciones = lote.map((item) => {
        const pos = { general: -1, carac: -1 };
        if (item.general) {
          pos.general = textos.push(item.texto) - 1;
        }
        if (item.carac && item.textoCarac !== '') {
          pos.carac = textos.push(item.textoCarac) - 1;
        }
        return pos;
      });
      let vectores: number[][] = [];
      if (textos.length > 0) {
        try {
          vectores = await pedirVectores(textos);
        } catch (error) {
          this.logger.warn(
            `worker de vectores: Ollama fallo en el lote que empieza en ${i} (${(error as Error)?.message ?? error})`,
          );
          continue;
        }
      }

      const nuevos: VectorNuevo[] = [];
      const caracNuevos: VectorCaracNuevo[] = [];
      const completos: number[] = [];
      for (let k = 0; k < lote.length; k++) {
        const item = lote[k];
        const pos = posiciones[k];
        const vector = pos.general >= 0 ? vectores[pos.general] : null;
        const vectorCarac = pos.carac >= 0 ? vectores[pos.carac] : null;
        const esVector = (v: number[] | null) =>
          Array.isArray(v) && v.length === DIMENSIONES;
        if (
          (pos.general >= 0 && !esVector(vector)) ||
          (pos.carac >= 0 && !esVector(vectorCarac))
        ) {
          this.logger.warn(
            `worker de vectores: el modelo no devolvio ${DIMENSIONES} dimensiones para el producto ${item.producto._id}`,
          );
          continue;
        }
        if (item.general) {
          nuevos.push({
            id: item.producto._id,
            vector: vector!,
            hash: item.hash,
            grupo: item.grupo,
            activo: item.activo,
          });
        }
        if (item.carac) {
          // Sin caracteristicas el vector queda NULL y la huella es la del
          // texto vacio: asi se sabe que ya se miro y no tiene ninguna.
          caracNuevos.push({
            id: item.producto._id,
            vector: vectorCarac,
            hash: item.hashCarac,
          });
        }
        completos.push(item.producto._id);
      }

      try {
        // Primero el general, que crea la fila si no existia, y despues el de
        // caracteristicas, que solo la actualiza.
        await this.guardar(nuevos);
        await this.guardarCaracteristicas(caracNuevos);
        listos.push(...completos);
        recalculados += nuevos.length;
        caracRecalculados += caracNuevos.length;
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
      `worker de vectores: ${pendientes.length} pendiente(s), ${recalculados} recalculado(s), ${caracRecalculados} de caracteristicas, ${soloGrupoOActivo} solo grupo o activo, ${listos.length} al dia`,
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
      caracteristicas_hash: string | null;
    }>(
      `SELECT pc.id_producto_mongo, v.texto_hash, v.grupo, v.activo,
              v.caracteristicas_hash
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
              caracteristicas_hash: fila.caracteristicas_hash,
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

  /** El vector de caracteristicas de un lote, sobre filas que ya existen. */
  private async guardarCaracteristicas(
    nuevos: VectorCaracNuevo[],
  ): Promise<void> {
    if (nuevos.length === 0) {
      return;
    }
    await pool.query(
      `UPDATE vector_producto v
          SET vector_caracteristicas = t.vector::vector,
              caracteristicas_hash = t.hash
         FROM unnest($1::bigint[], $2::text[], $3::text[]) AS t (id, vector, hash)
        WHERE v.id_producto_mongo = t.id`,
      [
        nuevos.map((n) => n.id),
        nuevos.map((n) => (n.vector == null ? null : aVectorPg(n.vector))),
        nuevos.map((n) => n.hash),
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
  return `${md5(construirTexto(producto))}|${md5(construirTextoCaracteristicas(producto))}|${grupo}|${producto.estado === 'activo'}`;
}
