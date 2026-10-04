/**
 * Cuerpo esperado en POST /resenas.
 *
 * Una resena es de un VENDEDOR sobre un PRODUCTO (no del producto solo): el
 * catalogo es compartido y un producto no es de nadie, asi que se califica
 * a quien te lo vendio. Ver migrations/011_resenas.sql.
 *
 * El texto NO viaja como columna de `resena`: se guarda en su comentario
 * RAIZ (`comentario` con `id_comentario_padre` NULL) y `resena.id_comentario`
 * lo apunta.
 */
export interface CrearResenaPeticion {
  /** El `_id` del producto en MongoDB. Entero > 0. */
  id_producto: number;
  /** Correo de la cuenta del vendedor al que se califica. */
  correo_vendedor: string;
  /** De 1 a 5. */
  calificacion: number;
  /** El texto de la resena. Obligatorio, de 40 a 350 caracteres. */
  comentario: string;
}
