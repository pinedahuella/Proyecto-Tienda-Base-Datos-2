/**
 * Lee una variable de entorno obligatoria y corta el arranque si no existe.
 *
 * Es a proposito: si un valor sensible (una contrasena, un secreto de firma)
 * viniera con un valor por defecto escrito en el codigo, ese valor quedaria
 * en el repositorio. Mejor que el backend no arranque y diga que falta, a
 * que arranque con una credencial publicada.
 */
export function obligatoria(nombre: string): string {
  const valor = process.env[nombre];
  if (!valor) {
    throw new Error(
      `Falta la variable ${nombre}. Copia backend/.env.example como backend/.env y llenalo.`,
    );
  }
  return valor;
}
