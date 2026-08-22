/**
 * Cuerpo esperado en POST /perfil.
 *
 * Cada campo es opcional. Si viene en null (o no viene), ese campo no se
 * toca; solo se actualiza lo que llega con un valor. Debe venir al menos
 * uno de los dos.
 */
export interface EditarPerfilPeticion {
  nombre?: string | null;
  apellido?: string | null;
}
