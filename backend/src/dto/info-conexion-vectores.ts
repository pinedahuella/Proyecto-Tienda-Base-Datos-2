/** Datos que devuelve la comprobacion de conexion con Ollama. */
export interface InfoConexionVectores {
  url: string;
  modelo: string;
  /** Si el modelo de embeddings ya esta descargado en ese Ollama. */
  modelo_descargado: boolean;
  modelos_disponibles: string[];
}
