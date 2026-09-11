/**
 * Coleccion `eventos_autenticacion` de MongoDB. Un documento por cada
 * intento de entrada al sistema: `registro`, `login` (exitoso o fallido) y
 * `logout`.
 *
 * Reemplaza a las tablas `log_login` / `log_registro` de PostgreSQL, que
 * siguen existiendo pero ya NO se escriben desde el backend (ver
 * `cambio_propuestas/2026-09-10_eventos-autenticacion-mongo.md`). Se movio a
 * Mongo porque el evento es semi-estructurado y va a crecer con cada senal
 * de fraude nueva (geo, huella de dispositivo, etc.), y porque asi el log de
 * seguridad no carga la base transaccional. La escritura es best-effort: si
 * Mongo no responde, el login/registro/logout funciona igual (`LogService`
 * nunca lanza, y el controlador la llama sin `await`).
 *
 * Solo se inserta, nunca se actualiza: es un registro historico e inmutable.
 */

export type TipoEventoAutenticacion = 'login' | 'logout' | 'registro';

export type ResultadoAutenticacion = 'exito' | 'fallo';

/**
 * Por que fallo un intento. `null` en los eventos con resultado `exito`.
 *
 *  - `credenciales_invalidas`: el identificador existe pero la contrasena no
 *    coincide.
 *  - `usuario_inexistente`: no hay ninguna cuenta con ese correo ni usuario.
 *  - `cuenta_inactiva`: la cuenta existe y la contrasena es correcta, pero
 *    esta suspendida o en otro estado no activo.
 *  - `datos_invalidos`: la peticion venia sin identificador o sin contrasena.
 *
 * El cliente SIEMPRE recibe el mismo 401 generico
 * ("Correo electronico, usuario o contrasena incorrectos"); este motivo es
 * solo para el log de seguridad, nunca se expone en la respuesta HTTP (si
 * lo hiciera, esta ruta serviria para averiguar que cuentas existen o
 * cuales estan suspendidas).
 */
export type MotivoFalloAutenticacion =
  | 'credenciales_invalidas'
  | 'usuario_inexistente'
  | 'cuenta_inactiva'
  | 'datos_invalidos';

/** Ubicacion aproximada de la IP del evento -- ver `geolocalizarIp` en `helpers/contexto-peticion.ts`. */
export interface GeoEvento {
  lat: number;
  lon: number;
  pais: string | null;
  ciudad: string | null;
}

export interface EventoAutenticacion {
  tipo: TipoEventoAutenticacion;
  resultado: ResultadoAutenticacion;
  motivo: MotivoFalloAutenticacion | null;
  /**
   * Id del usuario involucrado, o `null` cuando no se puede atribuir: un
   * login fallido contra una cuenta que no existe, o un logout sin token
   * valido. En un `credenciales_invalidas` o `cuenta_inactiva` si se conoce
   * (la cuenta existe).
   */
  id_usuario: string | null;
  /**
   * El correo o usuario que se tecleo en el intento. En el `registro` es el
   * correo con el que se creo la cuenta. `null` en el `logout` (ahi no hay
   * formulario, se identifica por la cookie). Se guarda tal cual lo mando el
   * cliente, sin normalizar.
   */
  identificador_intentado: string | null;
  /** IP de origen (`request.ip` de Fastify). `null` si no se pudo determinar. */
  ip: string | null;
  /** Cabecera `User-Agent` cruda. `null` si la peticion no la trae. */
  user_agent: string | null;
  /**
   * Huella del cliente: SHA-256 de `user-agent` + `accept-language`. NO
   * identifica a una persona ni a un equipo de forma fiable -- se falsea
   * cambiando una cabecera --, sirve para agrupar peticiones del mismo
   * navegador honesto (por ejemplo varias cuentas que entran desde el mismo
   * navegador). `null` si la peticion no trae `User-Agent`.
   */
  huella_cliente: string | null;
  /**
   * Ubicacion aproximada de `ip` (`geoip-lite`, calculado en el mismo
   * camino del login -- ver `contextoDePeticion`). `null` sin IP, con IP
   * privada/local, o si no se pudo resolver (anycast/CDN). Lo consume
   * `ViajeImposibleService` para comparar la distancia entre dos logins de
   * una misma cuenta.
   */
  geo: GeoEvento | null;
  /** Momento del evento, en UTC. Lo pone el backend, no el cliente. */
  fecha: Date;
  /**
   * Bandera "cola sin cola": marca que el documento todavia no esta en el
   * indice de Elasticsearch (`mesh_eventos_autenticacion`). La pone
   * `LogService` al insertar; `EventosAutenticacionSyncService` la quita con
   * `$unset` en cuanto lo indexa. Solo puede valer `true` -- si no esta, es
   * que ya se sincronizo. Como el evento es inmutable, se pone una sola vez
   * y se quita una sola vez, nunca vuelve. Mismo patron que
   * `pendiente_busqueda` del catalogo, y por lo mismo (Mongo standalone: sin
   * replica set no hay Change Streams).
   */
  pendiente_elastic?: true;
}
