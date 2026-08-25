import { StockResultanteOferta } from './comprar-pedido';

/** Lo que devuelve cancelar_pedido() de PostgreSQL (migrations/007_flujo_pedido.sql). */
export interface CancelacionResultado {
  id_pedido: number;
  /** El estado que tenia el pedido antes de cancelarlo (pendiente o comprado). */
  estado_previo: string;
  /** Vacio si estaba pendiente: cancelar uno pendiente no toca el stock, porque nunca se desconto. */
  stock: StockResultanteOferta[];
}
