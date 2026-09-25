import { Producto } from './producto';

/**
 * Una fila de `GET /productos/vistos-recientemente` (R1 de
 * `docs/fraude-entrega3/03-consultas-clickhouse.md`): un producto distinto
 * que la persona miro hace poco, del mas nuevo al mas viejo.
 * `ya_comprado` no filtra nada -- informa. A diferencia de las tendencias
 * de admin, aca SI puede venir `producto: null` si el documento ya no
 * existe, pero es un caso raro: el catalogo no borra productos, solo los
 * desactiva.
 */
export interface ProductoVistoRecientemente {
  ultima_vista: string;
  veces: number;
  ya_comprado: boolean;
  producto: Producto | null;
}
