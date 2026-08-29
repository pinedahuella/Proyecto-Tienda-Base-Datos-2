/**
 * Los tipos de respuesta de las rutas de resenas (GET /productos/:id/resenas
 * y POST /resenas). Las tres tablas viven en PostgreSQL desde
 * migrations/011_resenas.sql: `resena`, `comentario` y `likes`.
 *
 * La forma la fija el frontend, que ya esta escrito contra ella
 * (`frontend/src/lib/Resenas.svelte`): si cambia aqui, se rompe alla.
 */

/**
 * El voto sobre un comentario (una resena vota su comentario RAIZ, una
 * respuesta vota el suyo). `a_favor`/`en_contra` son las copias derivadas
 * `comentario.cantidad_likes`/`cantidad_dislikes`, que mantiene el trigger
 * `trg_likes_recontar`. `mio` es lo que voto la cuenta que pide: `1`, `-1`
 * o `null` (sin sesion siempre `null`).
 */
export interface VotoResena {
  mio: number | null;
  a_favor: number;
  en_contra: number;
}

/** Una respuesta a una resena. La escribe el vendedor calificado. */
export interface RespuestaResena {
  id_comentario: number;
  autor_usuario: string;
  autor_correo: string;
  comentario: string;
  fecha_publicacion: Date;
  voto: VotoResena;
}

/** Una resena de un producto, con su vendedor, su autor y sus respuestas. */
export interface ResenaProducto {
  id_resena: number;
  /** La RAIZ del hilo: es contra este id que se vota. */
  id_comentario: number;
  calificacion: number;
  comentario: string;
  fecha_publicacion: Date;
  autor_usuario: string;
  autor_correo: string;
  vendedor_usuario: string;
  vendedor_correo: string;
  vendedor_nombre: string;
  voto: VotoResena;
  respuestas: RespuestaResena[];
}

/** El resumen de la ficha: la nota media y el reparto por estrellas. */
export interface ResumenResenas {
  total: number;
  promedio: number;
  /** Cuantas de cada nota, con las cinco claves "1".."5" SIEMPRE presentes. */
  reparto: Record<string, number>;
}

/**
 * Un vendedor de este producto al que la cuenta que pide todavia puede
 * calificar: le compro el producto (pedido pagado y no cancelado) y aun no
 * lo ha calificado. Llena el select del formulario. Sin sesion, lista vacia.
 */
export interface VendedorCalificable {
  correo: string;
  usuario: string;
  nombre: string;
}

/** La respuesta completa de GET /productos/:id/resenas. */
export interface ResenasDeProducto {
  resenas: ResenaProducto[];
  resumen: ResumenResenas;
  puede_calificar: VendedorCalificable[];
}

/** Lo que devuelve POST /resenas/:id/respuestas. */
export interface RespuestaCreada {
  id_comentario: number;
}

/**
 * El estado del voto de un comentario despues de `PUT` o `DELETE
 * /comentarios/:id/voto`: los contadores ya recontados por el trigger y lo
 * que quedo votando la cuenta (`mio`: `1`, `-1`, o `null` tras un DELETE).
 */
export interface VotoActualizado {
  a_favor: number;
  en_contra: number;
  mio: number | null;
}
