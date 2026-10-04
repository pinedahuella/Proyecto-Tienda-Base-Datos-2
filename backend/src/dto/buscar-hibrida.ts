import { ResultadoBusquedaProducto } from './buscar-productos';

/** Query params esperados en GET /buscador/productos/hibrida. */
export interface BuscarHibridaQuery {
  /** Lo que la persona escribio: palabras sueltas ("laptop gamer") o una frase ("algo para escuchar musica corriendo"). */
  q?: string;
  limite?: string;
}

/**
 * Un resultado de la busqueda hibrida: el mismo resumen que
 * `GET /buscador/productos`, mas lo que explica por que salio y en que lugar
 * quedo en cada una de las dos busquedas.
 */
export interface ResultadoHibrido extends ResultadoBusquedaProducto {
  /**
   * El puntaje combinado, de 0 a 1 (1 = primero en las dos busquedas). Por aqui
   * se ordena. Es relativo a esta busqueda: sirve para comparar resultados entre
   * si, no para compararlos con los de otra busqueda.
   */
  puntaje: number;
  /** Por donde salio: las palabras (`texto`), el significado (`significado`), o las dos. */
  origen: ('texto' | 'significado')[];
  /** Su lugar en la busqueda por palabras (1 = el mejor), o `null` si no salio por ahi. */
  posicion_texto: number | null;
  /** Su lugar en la busqueda por significado (1 = el mas cercano), o `null` si no salio por ahi. */
  posicion_significado: number | null;
  /** El puntaje de relevancia de Elasticsearch en la busqueda por palabras, o `null`. */
  puntaje_texto: number | null;
  /** El parecido de significado con lo escrito, de 0 a 1 (coseno), o `null`. */
  similitud: number | null;
}

/**
 * La respuesta de GET /buscador/productos/hibrida. `modo` dice como se hizo:
 * `hibrida` (palabras + significado) o `solo_texto` cuando Ollama no respondio y
 * se contesto solo con las palabras, en vez de fallar.
 */
export interface RespuestaHibrida {
  modo: 'hibrida' | 'solo_texto';
  resultados: ResultadoHibrido[];
}
