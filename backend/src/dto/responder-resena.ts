/**
 * Cuerpo esperado en POST /resenas/:id/respuestas.
 *
 * `:id` es el `id_resena`: la respuesta cuelga SIEMPRE del comentario raiz
 * de esa resena (`comentario.id_comentario_padre = resena.id_comentario`).
 * Por eso el arbol de comentarios se queda en UN solo nivel por ahora -- no
 * hay ruta para responder a una respuesta.
 *
 * Cualquier cuenta con sesion puede responder (decision del equipo; ver
 * endpoints-resenas.md). No hace falta ser el vendedor calificado.
 */
export interface ResponderResenaPeticion {
  /** El texto de la respuesta. Obligatorio, no vacio, hasta 350 caracteres, sin minimo. */
  comentario: string;
}
