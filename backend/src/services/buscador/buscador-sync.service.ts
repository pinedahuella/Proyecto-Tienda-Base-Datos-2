import { Injectable, Logger } from '@nestjs/common';
import { Decimal128 } from 'mongodb';
import { Interval } from '@nestjs/schedule';
import { mongoDb } from '../../database/mongo';
import { elasticClient } from '../../database/elastic';
import { Producto } from '../../models/producto';

const INDICE = process.env.ELASTIC_INDICE ?? 'mesh_productos';

/**
 * El worker que mantiene al dia el indice de busqueda (Elasticsearch,
 * `mesh_productos`) a partir de la bandera `pendiente_busqueda` del
 * catalogo de MongoDB. Ver
 * `cambio_propuestas/2026-09-04_2124-pendiente-busqueda-cola-elastic.md`
 * y `2026-09-04_2208-elastic-indexar-todos-los-estados.md`.
 *
 * A diferencia de `GrafoSyncService` (que decide entre proyectar o borrar
 * segun exista o no la resena), aca hay una sola operacion: el indice
 * guarda TODOS los estados, asi que cada producto pendiente se reindexa tal
 * como esta hoy -- sea `activo`, `inactivo`, `en_revision`, lo que sea.
 * Quien decide que no se le muestre a un comprador un producto no-activo es
 * la ruta publica que consulta el indice, no este worker.
 *
 * Mismo patron que `GrafoSyncService.vaciarCola()`: `@Interval`, con una
 * bandera para que una corrida lenta no se pise con la siguiente.
 */
@Injectable()
export class BuscadorSyncService {
  private readonly logger = new Logger(BuscadorSyncService.name);

  private static readonly INTERVALO_MS = 10000;

  /** Tope por corrida: si hay mas pendientes, siguen en la proxima. */
  private static readonly MAX_POR_CORRIDA = 200;

  /** `true` mientras una corrida esta en curso: la siguiente se salta. */
  private procesando = false;

  @Interval('buscador-pendientes', BuscadorSyncService.INTERVALO_MS)
  async sincronizar(): Promise<void> {
    if (this.procesando) {
      return;
    }
    this.procesando = true;

    try {
      const coleccion = mongoDb.collection<Producto>('productos');
      const pendientes = await coleccion
        .find({ pendiente_busqueda: true })
        .limit(BuscadorSyncService.MAX_POR_CORRIDA)
        .toArray();

      if (pendientes.length === 0) {
        return;
      }

      let sincronizados = 0;
      for (const producto of pendientes) {
        try {
          // `update` con `doc_as_upsert`: crea el documento si no existe y, si
          // existe, reemplaza solo los campos de `aDocumentoIndice`.
          const indexado = aDocumentoIndice(producto);
          await elasticClient.update({
            index: INDICE,
            id: String(producto._id),
            doc: indexado,
            doc_as_upsert: true,
          });
          // La bandera se apaga de forma atomica y devolviendo el documento de
          // ANTES. Si alguien lo cambio mientras se indexaba (y volvio a poner
          // la bandera), lo indexado ya no es lo de hoy: se vuelve a prender y
          // va en la proxima corrida. Antes se apagaba a ciegas y ese cambio se
          // perdia; paso al renombrar una categoria dos veces seguidas
          // (2026-11-07): 20 productos quedaron con el nombre viejo.
          const antes = await coleccion.findOneAndUpdate(
            { _id: producto._id },
            { $unset: { pendiente_busqueda: '' } },
            { returnDocument: 'before' },
          );
          if (
            antes != null &&
            JSON.stringify(aDocumentoIndice(antes)) !== JSON.stringify(indexado)
          ) {
            await coleccion.updateOne(
              { _id: producto._id },
              { $set: { pendiente_busqueda: true } },
            );
            continue;
          }
          sincronizados++;
        } catch (error) {
          // Uno solo fallido (Elasticsearch caido, o este producto en
          // particular) no debe tumbar el resto del lote. Se deja
          // pendiente_busqueda en true: se reintenta en la proxima corrida,
          // no se pierde.
          this.logger.warn(
            `No se pudo sincronizar el producto ${producto._id} con el buscador: ${mensajeCorto(error)}`,
          );
        }
      }

      if (sincronizados > 0) {
        this.logger.log(
          `worker del buscador: ${sincronizados} producto(s) sincronizados`,
        );
      }
    } catch (error) {
      this.logger.warn(
        `worker del buscador: corrida interrumpida -- ${mensajeCorto(error)}`,
      );
    } finally {
      this.procesando = false;
    }
  }
}

/**
 * Arma el documento del indice a partir del producto de Mongo, con la MISMA
 * forma que `etl/extraer_busqueda.js` -- mismos nombres de campo, mismo
 * tratamiento de `Decimal128` y de las variantes. Si esa forma cambia algun
 * dia, hay que cambiar las dos a la par. Las dos llevan `hay_descuento`
 * (desde el 2026-09-27) e `imagen`, la foto de la tarjeta (desde el
 * 2026-10-23).
 */
function aDocumentoIndice(producto: Producto): Record<string, unknown> {
  const variantes = (producto.variantes ?? [])
    .map((v) => v.nombre_variante)
    .filter((n): n is string => typeof n === 'string' && n.trim().length > 0);

  return {
    nombre: producto.nombre,
    descripcion: producto.descripcion,
    estado: producto.estado,
    id_categoria: producto.categoria?.id_categoria ?? null,
    categoria_nombre: producto.categoria?.nombre ?? null,
    categoria_padre: producto.categoria?.categoria_padre ?? null,
    precio_desde: aNumero(producto.precio_desde),
    precio_tienda: aNumero(producto.precio_tienda),
    hay_descuento: producto.hay_descuento ?? false,
    stock_total: producto.stock_total ?? 0,
    total_ofertas: producto.total_ofertas ?? 0,
    resenas_promedio: producto.resenas_promedio ?? 0,
    resenas_total: producto.resenas_total ?? 0,
    variantes,
    imagen: primeraImagen(producto),
  };
}

/**
 * La foto de la tarjeta: la primera imagen de la primera variante que tenga
 * alguna, igual que `etl/extraer_busqueda.js`.
 */
function primeraImagen(producto: Producto): string | null {
  for (const v of producto.variantes ?? []) {
    const imagen = (v.imagenes ?? []).find(
      (i) => typeof i === 'string' && i.trim().length > 0,
    );
    if (imagen) {
      return imagen;
    }
  }
  return null;
}

/**
 * `Decimal128` (como lo guarda Mongo) a `number` (lo que pide el mapeo
 * `double` de Elasticsearch). `null` se conserva tal cual: un producto sin
 * precio no vale Q0, es que no se vende -- mismo criterio que
 * `etl/extraer_busqueda.js`.
 */
function aNumero(valor: Decimal128 | null): number | null {
  return valor == null ? null : Number(valor.toString());
}

/** Un mensaje de error corto para el log. */
function mensajeCorto(error: unknown): string {
  const texto = error instanceof Error ? error.message : String(error);
  return texto.length > 300 ? `${texto.slice(0, 297)}...` : texto;
}
