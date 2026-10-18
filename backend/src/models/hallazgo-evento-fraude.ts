import { EstadoAlertaFraude } from './alerta-fraude';

/**
 * Catalogo y forma de `hallazgo_evento_fraude` (ver
 * `elementos Generales/plan pendiente/hallazgos-evento-fraude.sql`).
 *
 * Persiste F1-F6 (`docs/fraude-entrega3/03-consultas-clickhouse.md`):
 * hallazgos de fraude calculados sobre eventos de ClickHouse (vistas,
 * carritos, compras, devoluciones, registros) -- distinto de
 * `alerta-fraude.ts` (fraude de login) y `anillo-fraude.ts` (grafo sobre
 * resenas), aunque reusa el mismo catalogo de estados
 * (`ID_ESTADO_ALERTA_FRAUDE_*` en `models/alerta-fraude.ts`).
 */

export type TipoHallazgoEvento =
  | 'vistas_infladas'
  | 'compras_en_rafaga'
  | 'ip_multicuenta_compras'
  | 'devoluciones_seriales'
  | 'granja_de_registros';

/**
 * Una cuenta involucrada en un hallazgo, derivada de
 * `hallazgo_evento_fraude_cuenta` + `usuarios` -- mismo criterio que
 * `CuentaDeAnillo` (`models/anillo-fraude.ts`), con `es_nucleo` de mas.
 * `es_nucleo` siempre `true` por ahora (ver el comentario de esa tabla en
 * `hallazgos-evento-fraude.sql`).
 */
export interface CuentaDeHallazgoEvento {
  id_usuario: string;
  usuario: string;
  es_nucleo: boolean;
}

/** `GET /admin/fraude/alertas-eventos`: un hallazgo, forma de API. */
export interface HallazgoEventoFraude {
  id_hallazgo_evento_fraude: string;
  tipo: TipoHallazgoEvento;
  clave: string;
  cuentas: CuentaDeHallazgoEvento[];
  id_producto_mongo: number | null;
  detalle: Record<string, unknown>;
  contador: number;
  ventana_inicio: Date;
  estado: EstadoAlertaFraude;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
