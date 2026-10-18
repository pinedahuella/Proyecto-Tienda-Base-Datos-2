import { Injectable, Logger } from '@nestjs/common';
import type { estypes } from '@elastic/elasticsearch';
import { elasticClient } from '../../database/elastic';
import { obtenerIdTienda } from '../../helpers/cuenta-tienda';
import { ErrorValidacion } from '../../helpers/errores';
import { manejarErrorConexionElastic } from '../../helpers/manejar-error-elastic';
import {
  validarAlcanceBusquedaOferta,
  validarFiltroDescuentoOferta,
  validarFiltroEstadoOferta,
  validarFiltroStockOferta,
  validarOrdenBusquedaOferta,
  validarTextoBusquedaOferta,
} from '../../helpers/validaciones-oferta';
import {
  validarEnteroPositivo,
  validarLimite,
  validarPagina,
  validarPrecio,
} from '../../helpers/validaciones-productos';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import type {
  BuscarOfertasQuery,
  DocumentoOferta,
  OfertaEncontrada,
  OfertasEncontradas,
  ResumenBusquedaOfertas,
} from '../../dto/buscar-ofertas';
import { INDICE_OFERTAS } from './evento-oferta-sync.service';

/** Elasticsearch no pagina con from + size por encima de esto (index.max_result_window). */
const VENTANA_MAXIMA = 10000;

/** Cuantos vendedores trae `resumen.por_vendedor`. */
const VENDEDORES_EN_RESUMEN = 10;

/**
 * El buscador de ofertas (GET /vendedor/ofertas/buscar). Consulta el indice
 * `mesh_ofertas` de Elasticsearch, que mantiene EventoOfertaSyncService desde
 * PostgreSQL. Solo LEE: para editar una oferta siguen las rutas de
 * OfertasVendedorService contra PostgreSQL, la fuente de verdad.
 *
 * Quien ve que:
 *
 *   - Un vendedor: solo sus ofertas. El filtro `id_vendedor` va fijo en el
 *     codigo, no sale de ningun parametro de la peticion (misma "lista
 *     blanca" que BuscadorProductosService con `estado: activo`).
 *   - La tienda y los admin: por defecto las de la tienda (un admin actua
 *     como la tienda, igual que en OfertasVendedorService.resolverIdEfectivo).
 *     Con `alcance=todas`, las de cualquier vendedor, y pueden filtrar por
 *     uno con `id_vendedor`.
 *
 * El texto es difuso (`fuzziness: AUTO`) y sin tildes (`espanol_llano`), sobre
 * el nombre del producto (mas peso), el de la variante y el del vendedor.
 *
 * Ademas de la pagina, devuelve un `resumen` hecho con agregaciones de
 * Elasticsearch sobre todo lo que cumple la busqueda: cuantas por estado,
 * cuantas con descuento, cuantas agotadas, el rango de precios y (con
 * `alcance=todas`) los vendedores con mas ofertas.
 */
@Injectable()
export class BuscarOfertasService {
  private readonly logger = new Logger(BuscarOfertasService.name);

  async buscar(
    idUsuarioToken: string,
    idRolUsuario: number,
    query: BuscarOfertasQuery,
  ): Promise<OfertasEncontradas> {
    const texto = validarTextoBusquedaOferta(query.q);
    const alcance = validarAlcanceBusquedaOferta(query.alcance);
    const idVendedor = validarEnteroPositivo(query.id_vendedor, 'id_vendedor');
    const idProducto = validarEnteroPositivo(query.id_producto, 'id_producto');
    const estado = validarFiltroEstadoOferta(query.estado);
    const conDescuento = validarFiltroDescuentoOferta(query.con_descuento);
    const stock = validarFiltroStockOferta(query.stock);
    const precioMin = validarPrecio(query.precio_min, 'precio_min');
    const precioMax = validarPrecio(query.precio_max, 'precio_max');
    const orden =
      validarOrdenBusquedaOferta(query.orden) ??
      (texto != null ? 'relevancia' : 'recientes');
    const limite = validarLimite(query.limite);
    const pagina = validarPagina(query.pagina);

    if (
      precioMin != null &&
      precioMax != null &&
      Number(precioMin) > Number(precioMax)
    ) {
      throw new ErrorValidacion('precio_min no puede ser mayor que precio_max');
    }
    const saltar = (pagina - 1) * limite;
    if (saltar + limite > VENTANA_MAXIMA) {
      throw new ErrorValidacion(
        `La busqueda solo llega hasta el resultado ${VENTANA_MAXIMA}: afina los filtros`,
      );
    }

    const idTienda = await obtenerIdTienda(this.logger);
    const esTiendaOAdmin =
      idRolUsuario === ID_ROL_ADMIN || idUsuarioToken === idTienda;
    if (alcance === 'todas' && !esTiendaOAdmin) {
      throw new ErrorValidacion(
        'alcance=todas es solo de la tienda y de los admin',
      );
    }
    if (idVendedor != null && alcance !== 'todas') {
      throw new ErrorValidacion('id_vendedor solo se usa con alcance=todas');
    }

    const filtros: estypes.QueryDslQueryContainer[] = [];
    if (alcance === 'propias') {
      // Un admin no tiene ofertas propias: busca las de la tienda.
      const idPropio =
        idRolUsuario === ID_ROL_ADMIN ? idTienda : idUsuarioToken;
      filtros.push({ term: { id_vendedor: Number(idPropio) } });
    } else if (idVendedor != null) {
      filtros.push({ term: { id_vendedor: idVendedor } });
    }
    if (idProducto != null) {
      filtros.push({ term: { id_producto: idProducto } });
    }
    if (estado != null) {
      filtros.push({ term: { estado } });
    }
    if (conDescuento === true) {
      filtros.push({ exists: { field: 'porcentaje_descuento' } });
    } else if (conDescuento === false) {
      filtros.push({
        bool: { must_not: [{ exists: { field: 'porcentaje_descuento' } }] },
      });
    }
    if (stock === 'agotadas') {
      filtros.push({ term: { stock: 0 } });
    } else if (stock === 'con_stock') {
      filtros.push({ range: { stock: { gt: 0 } } });
    }
    if (precioMin != null || precioMax != null) {
      filtros.push({
        range: {
          precio_final: {
            gte: precioMin != null ? Number(precioMin) : undefined,
            lte: precioMax != null ? Number(precioMax) : undefined,
          },
        },
      });
    }

    const aggs: Record<string, estypes.AggregationsAggregationContainer> = {
      por_estado: { terms: { field: 'estado', size: 10 } },
      con_descuento: { filter: { exists: { field: 'porcentaje_descuento' } } },
      agotadas: { filter: { term: { stock: 0 } } },
      precio_final: { stats: { field: 'precio_final' } },
    };
    if (alcance === 'todas') {
      aggs.por_vendedor = {
        terms: { field: 'id_vendedor', size: VENDEDORES_EN_RESUMEN },
        aggs: {
          usuario: { terms: { field: 'vendedor_usuario.exacto', size: 1 } },
        },
      };
    }

    try {
      const respuesta = await elasticClient.search<DocumentoOferta>({
        index: INDICE_OFERTAS,
        from: saltar,
        size: limite,
        track_total_hits: true,
        query: {
          bool: {
            must: [
              texto != null
                ? {
                    multi_match: {
                      query: texto,
                      fields: [
                        'nombre_producto^3',
                        'nombre_variante^2',
                        'vendedor_usuario',
                        'vendedor_nombre',
                      ],
                      fuzziness: 'AUTO',
                    },
                  }
                : { match_all: {} },
            ],
            filter: filtros,
          },
        },
        sort: aOrden(orden),
        aggs,
      });

      const total =
        typeof respuesta.hits.total === 'number'
          ? respuesta.hits.total
          : (respuesta.hits.total?.value ?? 0);

      return {
        ofertas: respuesta.hits.hits
          .map((hit) => hit._source)
          .filter((fuente): fuente is DocumentoOferta => fuente != null)
          .map(aOfertaEncontrada),
        pagina,
        limite,
        total_ofertas: total,
        total_paginas: total === 0 ? 0 : Math.ceil(total / limite),
        resumen: aResumen(respuesta.aggregations, alcance === 'todas'),
      };
    } catch (error) {
      manejarErrorConexionElastic(this.logger, error);
    }
  }
}

/** Cada orden lleva `id_oferta` de desempate, para que la paginacion sea estable. */
function aOrden(orden: string): estypes.SortCombinations[] {
  const desempate: estypes.SortCombinations = { id_oferta: { order: 'desc' } };
  switch (orden) {
    case 'relevancia':
      return ['_score', desempate];
    case 'precio_asc':
      return [{ precio_final: { order: 'asc' } }, desempate];
    case 'precio_desc':
      return [{ precio_final: { order: 'desc' } }, desempate];
    case 'descuento_desc':
      return [
        { porcentaje_descuento: { order: 'desc', missing: '_last' } },
        desempate,
      ];
    case 'stock_asc':
      return [{ stock: { order: 'asc' } }, desempate];
    default:
      return [desempate];
  }
}

function aOfertaEncontrada(doc: DocumentoOferta): OfertaEncontrada {
  return {
    id_oferta: String(doc.id_oferta),
    id_producto: String(doc.id_producto),
    id_producto_variante: String(doc.id_producto_variante),
    nombre_producto: doc.nombre_producto,
    nombre_variante: doc.nombre_variante,
    estado_variante: doc.estado_variante,
    vendedor: {
      id_usuario: String(doc.id_vendedor),
      usuario: doc.vendedor_usuario,
      nombre: doc.vendedor_nombre,
      estado: doc.estado_vendedor,
    },
    precio: aMonto(doc.precio),
    porcentaje_descuento:
      doc.porcentaje_descuento == null
        ? null
        : aMonto(doc.porcentaje_descuento),
    precio_final: aMonto(doc.precio_final),
    stock: doc.stock,
    estado: doc.estado,
  };
}

type Agregaciones = Record<string, estypes.AggregationsAggregate> | undefined;

function aResumen(
  aggs: Agregaciones,
  conVendedores: boolean,
): ResumenBusquedaOfertas {
  const porEstado = aggs?.por_estado as
    estypes.AggregationsStringTermsAggregate | undefined;
  const conDescuento = aggs?.con_descuento as
    estypes.AggregationsFilterAggregate | undefined;
  const agotadas = aggs?.agotadas as
    estypes.AggregationsFilterAggregate | undefined;
  const precios = aggs?.precio_final as
    estypes.AggregationsStatsAggregate | undefined;

  const resumen: ResumenBusquedaOfertas = {
    por_estado: Object.fromEntries(
      cubetas(porEstado).map((c) => [String(c.key), c.doc_count]),
    ),
    con_descuento: conDescuento?.doc_count ?? 0,
    agotadas: agotadas?.doc_count ?? 0,
    precio_final: {
      minimo: precios?.min == null ? null : aMonto(precios.min),
      maximo: precios?.max == null ? null : aMonto(precios.max),
      promedio: precios?.avg == null ? null : aMonto(precios.avg),
    },
  };

  if (conVendedores) {
    const porVendedor = aggs?.por_vendedor as
      estypes.AggregationsLongTermsAggregate | undefined;
    resumen.por_vendedor = cubetas(porVendedor).map((c) => {
      const usuario = (c as unknown as Record<string, unknown>).usuario as
        estypes.AggregationsStringTermsAggregate | undefined;
      return {
        id_vendedor: String(c.key),
        usuario: String(cubetas(usuario)[0]?.key ?? ''),
        ofertas: c.doc_count,
      };
    });
  }
  return resumen;
}

/** Las cubetas de un `terms`, que el cliente tipa como arreglo u objeto. */
function cubetas(
  agg:
    | estypes.AggregationsStringTermsAggregate
    | estypes.AggregationsLongTermsAggregate
    | undefined,
): { key: string | number; doc_count: number }[] {
  const lista = agg?.buckets;
  return Array.isArray(lista) ? lista : [];
}

/** Un monto de Elasticsearch (double) con 2 decimales, como numeric(12,2). */
function aMonto(valor: number): string {
  return valor.toFixed(2);
}
