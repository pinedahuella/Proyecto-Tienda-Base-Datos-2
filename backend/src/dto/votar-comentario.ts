/**
 * Cuerpo esperado en PUT /comentarios/:id/voto.
 *
 * `:id` es el `id_comentario` -- sirve igual para el comentario raiz de una
 * resena que para una respuesta. Cambiar de opinion es el mismo PUT (la
 * llave primaria de `likes` es `(id_usuario, id_comentario)`, asi que se
 * hace un UPSERT). `DELETE /comentarios/:id/voto` quita el voto y no lleva
 * cuerpo.
 */
export interface VotarComentarioPeticion {
  /** `1` a favor, `-1` en contra. */
  valor: number;
}
