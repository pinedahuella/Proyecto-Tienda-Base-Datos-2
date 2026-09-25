import { Producto } from './producto';

/**
 * Una fila de `GET /admin/eventos/tendencias`: un producto cuyas vistas
 * diarias vienen creciendo (ver `AdminTendenciasAvanzadasService.enAscenso()`
 * para la formula exacta). `veces` es cuanto crecio el promedio diario
 * reciente contra el anterior; `vistas_por_persona` va al lado para
 * distinguir una tendencia real de un producto inflado a punta de vistas
 * (ver `F1_vistas_infladas.sql`, todavia no conectado al backend).
 */
export interface TendenciaEnAscenso {
  por_dia_ahora: number;
  por_dia_antes: number;
  veces: number;
  vistas_por_persona: number;
  producto: Producto | null;
}

/**
 * Una fila de `GET /admin/eventos/embudo`: un producto con un problema
 * detectable cruzando vista/carrito/compra/devolucion -- una pregunta que
 * PostgreSQL no puede contestar porque no guarda los carritos que no
 * terminaron ni las vistas.
 */
export interface TendenciaEmbudo {
  sesiones: number;
  en_carrito: number;
  pedidos: number;
  unidades: number;
  devueltas: number;
  conversion: number;
  tasa_devolucion: number;
  diagnostico: 'mucho_interes_poca_compra' | 'devolucion_alta';
  producto: Producto | null;
}

/**
 * Una fila de `GET /admin/eventos/busquedas-sin-respuesta`: un termino
 * buscado con un problema. Sin segunda consulta a Mongo -- el termino ya
 * es toda la informacion, no hay un producto al que pedirle nombre.
 */
export interface TendenciaBusquedaSinRespuesta {
  termino: string;
  busquedas: number;
  sesiones: number;
  mas_resultados: number;
  clics: number;
  diagnostico: 'no_tenemos' | 'no_convence';
}
