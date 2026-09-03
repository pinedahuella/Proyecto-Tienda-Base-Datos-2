import { Injectable, Logger } from '@nestjs/common';
import { pool } from '../../database/postgres';
import {
  ErrorConflicto,
  ErrorNoEncontrado,
  ErrorValidacion,
} from '../../helpers/errores';
import { manejarErrorConexion } from '../../helpers/manejar-error-db';
import { validarIdProducto } from '../../helpers/validaciones-inventario';
import {
  validarCalificacion,
  validarComentarioResena,
  validarCorreoVendedor,
  validarValorVoto,
} from '../../helpers/validaciones-resena';
import { CrearResenaPeticion } from '../../dto/crear-resena';
import { ResponderResenaPeticion } from '../../dto/responder-resena';
import { VotarComentarioPeticion } from '../../dto/votar-comentario';
import {
  RespuestaCreada,
  RespuestaResena,
  ResenaProducto,
  ResenasDeProducto,
  ResumenResenas,
  VendedorCalificable,
  VotoActualizado,
  VotoResena,
} from '../../models/resena';
import { ProductosService } from '../productos/productos.service';

const REGEX_ID = /^\d+$/;
const CODIGO_UNIQUE_VIOLATION = '23505';
const CODIGO_CHECK_VIOLATION = '23514';
const CODIGO_FK_VIOLATION = '23503';

/** Fila cruda de una resena + su comentario raiz + autor + vendedor. */
interface FilaResena {
  id_resena: string;
  id_comentario: string;
  calificacion: number;
  comentario: string;
  fecha_publicacion: Date;
  cantidad_likes: number;
  cantidad_dislikes: number;
  autor_usuario: string;
  autor_correo: string;
  vendedor_usuario: string;
  vendedor_correo: string;
  vendedor_nombre: string;
}

/** Fila cruda de una respuesta (comentario con padre) + su autor. */
interface FilaRespuesta {
  id_comentario: string;
  id_comentario_padre: string;
  comentario: string;
  fecha_publicacion: Date;
  cantidad_likes: number;
  cantidad_dislikes: number;
  autor_usuario: string;
  autor_correo: string;
}

/**
 * Servicio de las resenas: `GET /productos/:id/resenas` (publica) y
 * `POST /resenas` (pide sesion).
 *
 * Todo vive en PostgreSQL (migrations/011_resenas.sql): `resena` guarda la
 * calificacion y apunta a su comentario RAIZ, donde estan el texto y la
 * fecha; las respuestas cuelgan de esa raiz; los votos (`likes`) van contra
 * `id_comentario`, no contra `id_resena`.
 *
 * **Regla de negocio propia del equipo (no del enunciado):** solo se puede
 * calificar a un vendedor de un producto que se le compro y se pago -- un
 * pedido con pago `pagado` y estado distinto de `cancelado`. Es decision de
 * Jose David y se puede quitar despues si el profesor no la quiere; mientras
 * tanto, tanto `POST /resenas` como la lista `puede_calificar` la aplican.
 *
 * Al publicar una resena (`crear`) se recalculan los campos `resenas_promedio`
 * y `resenas_total` que Mongo guarda como copia en el documento del producto
 * (via `ProductosService.recalcularCamposCalculados`): son los que usan la
 * tarjeta y el filtro del catalogo. La media autoritativa la sigue calculando
 * en vivo `listarDeProducto` desde PostgreSQL (`resumen.promedio`).
 */
@Injectable()
export class ResenasService {
  private readonly logger = new Logger(ResenasService.name);

  constructor(private readonly productosService: ProductosService) {}

  /**
   * Todas las resenas de un producto, con su vendedor, su autor, sus
   * respuestas y el resumen (nota media y reparto por estrellas). Publica:
   * si viene sesion, cada voto trae `mio` y `puede_calificar` sale con los
   * vendedores que la cuenta todavia puede calificar; sin sesion, `mio` es
   * `null` y `puede_calificar` es `[]`.
   *
   * `idUsuarioSesion` es el id de la cuenta logueada, o `null` si la
   * peticion vino sin cookie de sesion valida (el controlador la resuelve).
   */
  async listarDeProducto(
    idProductoParametro: string,
    idUsuarioSesion: string | null,
  ): Promise<ResenasDeProducto> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    let filas: FilaResena[];
    try {
      const resultado = await pool.query<FilaResena>(
        `SELECT r.id_resena, r.id_comentario, r.calificacion,
                c.comentario, c.fecha_publicacion,
                c.cantidad_likes, c.cantidad_dislikes,
                ua.usuario AS autor_usuario,
                ua.correo_electronico AS autor_correo,
                uv.usuario AS vendedor_usuario,
                uv.correo_electronico AS vendedor_correo,
                uv.nombre || COALESCE(' ' || uv.apellido, '') AS vendedor_nombre
           FROM resena r
           JOIN comentario c ON c.id_comentario = r.id_comentario
           JOIN usuarios  ua ON ua.id_usuario   = r.id_usuario
           JOIN usuarios  uv ON uv.id_usuario   = r.id_usuario_vendedor
          WHERE r.id_producto_mongo = $1
          ORDER BY c.fecha_publicacion DESC, r.id_resena DESC`,
        [idProducto],
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    const idsComentarioRaiz = filas.map((f) => f.id_comentario);
    const respuestasPorRaiz = await this.consultarRespuestas(idsComentarioRaiz);

    // Los ids de TODOS los comentarios en juego (raices + respuestas): es
    // sobre estos que se busca el voto de la sesion.
    const idsComentario = [
      ...idsComentarioRaiz,
      ...[...respuestasPorRaiz.values()].flat().map((r) => r.id_comentario),
    ];
    const votoPropio = await this.consultarVotosPropios(
      idUsuarioSesion,
      idsComentario,
    );

    const resenas: ResenaProducto[] = filas.map((fila) => ({
      id_resena: Number(fila.id_resena),
      id_comentario: Number(fila.id_comentario),
      calificacion: fila.calificacion,
      comentario: fila.comentario,
      fecha_publicacion: fila.fecha_publicacion,
      autor_usuario: fila.autor_usuario,
      autor_correo: fila.autor_correo,
      vendedor_usuario: fila.vendedor_usuario,
      vendedor_correo: fila.vendedor_correo,
      vendedor_nombre: fila.vendedor_nombre,
      voto: this.armarVoto(
        fila.cantidad_likes,
        fila.cantidad_dislikes,
        votoPropio.get(fila.id_comentario) ?? null,
      ),
      respuestas: (respuestasPorRaiz.get(fila.id_comentario) ?? []).map(
        (r): RespuestaResena => ({
          id_comentario: Number(r.id_comentario),
          autor_usuario: r.autor_usuario,
          autor_correo: r.autor_correo,
          comentario: r.comentario,
          fecha_publicacion: r.fecha_publicacion,
          voto: this.armarVoto(
            r.cantidad_likes,
            r.cantidad_dislikes,
            votoPropio.get(r.id_comentario) ?? null,
          ),
        }),
      ),
    }));

    return {
      resenas,
      resumen: this.armarResumen(filas),
      puede_calificar: await this.consultarPuedeCalificar(
        idUsuarioSesion,
        idProducto,
      ),
    };
  }

  /**
   * `¿La cuenta compro este producto?` -- true si tiene al menos un pedido
   * con pago `pagado` y estado del pedido distinto de `cancelado` que
   * incluya una linea de ese producto. **No** mira el vendedor: es "lo
   * compre" a secas, a diferencia de la regla de `POST /resenas` que si
   * exige que sea a ESE vendedor.
   */
  async comproProducto(
    idUsuario: string,
    idProductoParametro: string,
  ): Promise<{ comprado: boolean }> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    try {
      const resultado = await pool.query(
        `SELECT 1
           FROM pedido pe
           JOIN pago            pg  ON pg.id_pedido        = pe.id_pedido
           JOIN estado_pago     epa ON epa.id_estado_pago  = pg.id_estado_pago
           JOIN estado_pedido   epe ON epe.id_estado_pedido = pe.id_estado_pedido
           JOIN pedido_producto pp  ON pp.id_pedido        = pe.id_pedido
          WHERE pe.id_usuario = $1
            AND pp.id_producto_mongo = $2
            AND epa.estado_pago_nombre    = 'pagado'
            AND epe.estado_pedido_nombre <> 'cancelado'
          LIMIT 1`,
        [idUsuario, idProducto],
      );
      return { comprado: (resultado.rowCount ?? 0) > 0 };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * `¿La cuenta ya reseno este producto?` -- true si tiene al menos una fila
   * en `resena` para ese `id_producto_mongo`, sea cual sea el vendedor (se
   * puede resenar el mismo producto a varios vendedores).
   */
  async resenoProducto(
    idUsuario: string,
    idProductoParametro: string,
  ): Promise<{ resenado: boolean }> {
    if (!REGEX_ID.test(idProductoParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idProducto = Number(idProductoParametro);

    try {
      const resultado = await pool.query(
        `SELECT 1 FROM resena
          WHERE id_usuario = $1 AND id_producto_mongo = $2
          LIMIT 1`,
        [idUsuario, idProducto],
      );
      return { resenado: (resultado.rowCount ?? 0) > 0 };
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Escribe una resena: un comentario raiz con el texto y, apuntandolo, la
   * fila de `resena`. Van en una sola sentencia (un CTE), que PostgreSQL
   * ejecuta de forma atomica -- un fallo en el segundo INSERT no deja un
   * comentario huerfano.
   *
   * Antes de escribir nada se comprueba:
   *   - que el correo sea de una cuenta real (404 si no)
   *   - que no te estes calificando a vos mismo (400)
   *   - **que le hayas comprado ese producto a ese vendedor** y lo hayas
   *     pagado (409 si no) -- la regla del equipo, ver la cabecera de la
   *     clase
   *
   * El `UNIQUE (id_usuario, id_usuario_vendedor, id_producto_mongo)` de la
   * tabla rechaza la segunda resena del mismo trio -> 409.
   *
   * Ya escrita, se recalculan `resenas_promedio`/`resenas_total` en el
   * documento de Mongo del producto. Si ese recalculo falla no revienta la
   * publicacion: la resena ya esta en PostgreSQL (la fuente de verdad) y
   * `recalcularCamposCalculados` se traga sus propios errores -- la copia
   * del catalogo se pondra al dia en el proximo cambio o corrida del ETL.
   */
  async crear(
    idUsuario: string,
    datos: CrearResenaPeticion,
  ): Promise<{ id_resena: number; id_comentario: number }> {
    const idProducto = validarIdProducto(datos.id_producto);
    const correoVendedor = validarCorreoVendedor(datos.correo_vendedor);
    const calificacion = validarCalificacion(datos.calificacion);
    const comentario = validarComentarioResena(datos.comentario);

    const idVendedor = await this.resolverVendedorPorCorreo(correoVendedor);

    if (idVendedor === idUsuario) {
      throw new ErrorValidacion('No puedes calificarte a ti mismo');
    }

    await this.exigirCompraPagada(idUsuario, idVendedor, idProducto);

    try {
      const resultado = await pool.query<{
        id_resena: string;
        id_comentario: string;
      }>(
        `WITH raiz AS (
           INSERT INTO comentario (id_usuario, comentario)
           VALUES ($1, $2)
           RETURNING id_comentario
         )
         INSERT INTO resena (id_usuario, id_usuario_vendedor, id_producto_mongo,
                             calificacion, id_comentario)
         SELECT $1, $3, $4, $5, raiz.id_comentario FROM raiz
         RETURNING id_resena, id_comentario`,
        [idUsuario, comentario, idVendedor, idProducto, calificacion],
      );
      const fila = resultado.rows[0];
      await this.productosService.recalcularCamposCalculados([idProducto]);
      return {
        id_resena: Number(fila.id_resena),
        id_comentario: Number(fila.id_comentario),
      };
    } catch (error) {
      const codigo = (error as { code?: string } | undefined)?.code;
      if (codigo === CODIGO_UNIQUE_VIOLATION) {
        throw new ErrorConflicto(
          'Ya calificaste a este vendedor por este producto',
        );
      }
      if (codigo === CODIGO_CHECK_VIOLATION) {
        // No deberia llegar aca: calificacion, comentario y auto-calificacion
        // ya se validaron. Queda como red de seguridad si una ruta futura
        // se salta una validacion.
        throw new ErrorValidacion('La resena no cumple una regla de la base');
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Responde a una resena: inserta un `comentario` que cuelga del comentario
   * RAIZ de esa resena. `:id` es el `id_resena`.
   *
   * **Cualquier cuenta con sesion puede responder** (decision del equipo; el
   * enunciado / BACKEND-PENDIENTE decia "solo el vendedor calificado"). No
   * hay comprobacion de dueno ni de rol.
   *
   * **Un solo nivel, por ahora:** la respuesta siempre cuelga de la raiz de
   * la resena, nunca de otra respuesta, porque no existe una ruta para
   * responder a un `id_comentario` cualquiera. Asi el arbol se queda plano
   * sin necesidad de un CHECK.
   *
   * Un `id_resena` que no existe -> 404: el `INSERT ... SELECT ... FROM
   * resena WHERE id_resena = $` no encuentra nada y no inserta.
   */
  async responder(
    idUsuario: string,
    idResenaParametro: string,
    datos: ResponderResenaPeticion,
  ): Promise<RespuestaCreada> {
    if (!REGEX_ID.test(idResenaParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idResena = Number(idResenaParametro);
    const comentario = validarComentarioResena(datos.comentario);

    try {
      const resultado = await pool.query<{ id_comentario: string }>(
        `INSERT INTO comentario (id_usuario, id_comentario_padre, comentario)
         SELECT $1, r.id_comentario, $2
           FROM resena r
          WHERE r.id_resena = $3
         RETURNING id_comentario`,
        [idUsuario, comentario, idResena],
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe una resena con ese id');
      }
      return { id_comentario: Number(fila.id_comentario) };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * Pone o cambia el voto de la cuenta sobre un comentario (`:id` es
   * `id_comentario` -- sirve para la raiz de una resena o para una
   * respuesta). UPSERT sobre la llave `(id_usuario, id_comentario)` de
   * `likes`: votar distinto es un UPDATE, no otra fila. Los contadores
   * `cantidad_likes`/`cantidad_dislikes` los recuenta el trigger
   * `trg_likes_recontar`; aca solo se leen despues.
   *
   * Un `id_comentario` que no existe -> 404 (lo levanta la FK, codigo
   * 23503).
   */
  async votar(
    idUsuario: string,
    idComentarioParametro: string,
    datos: VotarComentarioPeticion,
  ): Promise<VotoActualizado> {
    if (!REGEX_ID.test(idComentarioParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idComentario = Number(idComentarioParametro);
    const valor = validarValorVoto(datos.valor);

    try {
      await pool.query(
        `INSERT INTO likes (id_usuario, id_comentario, valor)
         VALUES ($1, $2, $3)
         ON CONFLICT (id_usuario, id_comentario)
         DO UPDATE SET valor = EXCLUDED.valor`,
        [idUsuario, idComentario, valor],
      );
    } catch (error) {
      const codigo = (error as { code?: string } | undefined)?.code;
      if (codigo === CODIGO_FK_VIOLATION) {
        throw new ErrorNoEncontrado('No existe un comentario con ese id');
      }
      manejarErrorConexion(this.logger, error);
    }

    return this.leerVoto(idUsuario, idComentario);
  }

  /**
   * Quita el voto de la cuenta sobre un comentario. Idempotente: si no
   * habia voto, no pasa nada y responde igual. Un `id_comentario` que no
   * existe -> 404.
   */
  async quitarVoto(
    idUsuario: string,
    idComentarioParametro: string,
  ): Promise<VotoActualizado> {
    if (!REGEX_ID.test(idComentarioParametro)) {
      throw new ErrorValidacion('El id no es valido');
    }
    const idComentario = Number(idComentarioParametro);

    let borradas: number;
    try {
      const resultado = await pool.query(
        'DELETE FROM likes WHERE id_usuario = $1 AND id_comentario = $2',
        [idUsuario, idComentario],
      );
      borradas = resultado.rowCount ?? 0;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    // No se borro nada: puede ser que la cuenta no habia votado, o que el
    // comentario no existe. Solo en ese caso se paga la consulta extra para
    // distinguir "no habia voto" (200, idempotente) de "no existe" (404).
    if (borradas === 0) {
      await this.exigirComentarioExiste(idComentario);
    }

    return this.leerVoto(idUsuario, idComentario);
  }

  /** 404 si el comentario no existe. Solo se usa en el caso borde del DELETE. */
  private async exigirComentarioExiste(idComentario: number): Promise<void> {
    try {
      const resultado = await pool.query(
        'SELECT 1 FROM comentario WHERE id_comentario = $1',
        [idComentario],
      );
      if ((resultado.rowCount ?? 0) === 0) {
        throw new ErrorNoEncontrado('No existe un comentario con ese id');
      }
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * El estado del voto de un comentario para una cuenta: los contadores
   * (recontados por el trigger) y lo que quedo votando la cuenta.
   */
  private async leerVoto(
    idUsuario: string,
    idComentario: number,
  ): Promise<VotoActualizado> {
    try {
      const resultado = await pool.query<{
        cantidad_likes: number;
        cantidad_dislikes: number;
        mio: number | null;
      }>(
        `SELECT c.cantidad_likes, c.cantidad_dislikes,
                l.valor AS mio
           FROM comentario c
           LEFT JOIN likes l
             ON l.id_comentario = c.id_comentario AND l.id_usuario = $2
          WHERE c.id_comentario = $1`,
        [idComentario, idUsuario],
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe un comentario con ese id');
      }
      return {
        a_favor: fila.cantidad_likes,
        en_contra: fila.cantidad_dislikes,
        mio: fila.mio,
      };
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /** El id de la cuenta del vendedor, por su correo. 404 si no existe. */
  private async resolverVendedorPorCorreo(correo: string): Promise<string> {
    try {
      const resultado = await pool.query<{ id_usuario: string }>(
        'SELECT id_usuario FROM usuarios WHERE correo_electronico = $1',
        [correo],
      );
      const fila = resultado.rows[0];
      if (fila == null) {
        throw new ErrorNoEncontrado('No existe un vendedor con ese correo');
      }
      return fila.id_usuario;
    } catch (error) {
      if (error instanceof ErrorNoEncontrado) {
        throw error;
      }
      manejarErrorConexion(this.logger, error);
    }
  }

  /**
   * La regla del equipo: 409 salvo que exista un pedido de `idUsuario`, con
   * pago `pagado` y estado del pedido distinto de `cancelado`, que tenga una
   * linea del producto `idProducto` cuya oferta es de `idVendedor`.
   *
   * La cadena `pedido_producto.id_precio_historial -> precio_historial.id_oferta
   * -> oferta.id_usuario` es la misma que ya usa la factura para saber a
   * quien se le compro (ver migrations/006_pedidos.sql).
   */
  private async exigirCompraPagada(
    idUsuario: string,
    idVendedor: string,
    idProducto: number,
  ): Promise<void> {
    let compro: boolean;
    try {
      const resultado = await pool.query(
        `SELECT 1
           FROM pedido pe
           JOIN pago            pg  ON pg.id_pedido        = pe.id_pedido
           JOIN estado_pago     epa ON epa.id_estado_pago  = pg.id_estado_pago
           JOIN estado_pedido   epe ON epe.id_estado_pedido = pe.id_estado_pedido
           JOIN pedido_producto pp  ON pp.id_pedido        = pe.id_pedido
           JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
           JOIN oferta          o   ON o.id_oferta         = ph.id_oferta
          WHERE pe.id_usuario = $1
            AND o.id_usuario  = $2
            AND pp.id_producto_mongo = $3
            AND epa.estado_pago_nombre    = 'pagado'
            AND epe.estado_pedido_nombre <> 'cancelado'
          LIMIT 1`,
        [idUsuario, idVendedor, idProducto],
      );
      compro = resultado.rowCount != null && resultado.rowCount > 0;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    if (!compro) {
      throw new ErrorConflicto(
        'Solo puedes calificar a un vendedor de un producto que le compraste y pagaste',
      );
    }
  }

  /** "el mapa id_comentario_raiz -> sus respuestas (filas crudas)", en una consulta. */
  private async consultarRespuestas(
    idsComentarioRaiz: string[],
  ): Promise<Map<string, FilaRespuesta[]>> {
    const mapa = new Map<string, FilaRespuesta[]>();
    if (idsComentarioRaiz.length === 0) {
      return mapa;
    }

    let filas: FilaRespuesta[];
    try {
      const resultado = await pool.query<FilaRespuesta>(
        `SELECT c.id_comentario, c.id_comentario_padre,
                c.comentario, c.fecha_publicacion,
                c.cantidad_likes, c.cantidad_dislikes,
                ua.usuario AS autor_usuario,
                ua.correo_electronico AS autor_correo
           FROM comentario c
           JOIN usuarios ua ON ua.id_usuario = c.id_usuario
          WHERE c.id_comentario_padre = ANY($1::bigint[])
          ORDER BY c.fecha_publicacion ASC, c.id_comentario ASC`,
        [idsComentarioRaiz],
      );
      filas = resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }

    for (const fila of filas) {
      const lista = mapa.get(fila.id_comentario_padre) ?? [];
      lista.push(fila);
      mapa.set(fila.id_comentario_padre, lista);
    }
    return mapa;
  }

  /**
   * "el mapa id_comentario -> lo que voto esta cuenta (1 o -1)". Vacio si no
   * hay sesion o no hay comentarios.
   */
  private async consultarVotosPropios(
    idUsuarioSesion: string | null,
    idsComentario: string[],
  ): Promise<Map<string, number>> {
    const mapa = new Map<string, number>();
    if (idUsuarioSesion == null || idsComentario.length === 0) {
      return mapa;
    }
    try {
      const resultado = await pool.query<{
        id_comentario: string;
        valor: number;
      }>(
        `SELECT id_comentario, valor
           FROM likes
          WHERE id_usuario = $1 AND id_comentario = ANY($2::bigint[])`,
        [idUsuarioSesion, idsComentario],
      );
      for (const fila of resultado.rows) {
        mapa.set(fila.id_comentario, fila.valor);
      }
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
    return mapa;
  }

  /**
   * Los vendedores de este producto que `idUsuarioSesion` todavia puede
   * calificar: le compro el producto (pago `pagado`, pedido no `cancelado`),
   * no es el mismo usuario, y aun no tiene una resena de ese trio. Sin
   * sesion, `[]`.
   */
  private async consultarPuedeCalificar(
    idUsuarioSesion: string | null,
    idProducto: number,
  ): Promise<VendedorCalificable[]> {
    if (idUsuarioSesion == null) {
      return [];
    }
    try {
      const resultado = await pool.query<VendedorCalificable>(
        `SELECT DISTINCT
                uv.correo_electronico AS correo,
                uv.usuario,
                uv.nombre || COALESCE(' ' || uv.apellido, '') AS nombre
           FROM pedido pe
           JOIN pago            pg  ON pg.id_pedido        = pe.id_pedido
           JOIN estado_pago     epa ON epa.id_estado_pago  = pg.id_estado_pago
           JOIN estado_pedido   epe ON epe.id_estado_pedido = pe.id_estado_pedido
           JOIN pedido_producto pp  ON pp.id_pedido        = pe.id_pedido
           JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
           JOIN oferta          o   ON o.id_oferta         = ph.id_oferta
           JOIN usuarios        uv  ON uv.id_usuario       = o.id_usuario
          WHERE pe.id_usuario = $1
            AND pp.id_producto_mongo = $2
            AND epa.estado_pago_nombre    = 'pagado'
            AND epe.estado_pedido_nombre <> 'cancelado'
            AND o.id_usuario <> $1
            AND NOT EXISTS (
              SELECT 1 FROM resena r
               WHERE r.id_usuario          = $1
                 AND r.id_usuario_vendedor = o.id_usuario
                 AND r.id_producto_mongo   = $2
            )
          ORDER BY nombre`,
        [idUsuarioSesion, idProducto],
      );
      return resultado.rows;
    } catch (error) {
      manejarErrorConexion(this.logger, error);
    }
  }

  private armarVoto(
    aFavor: number,
    enContra: number,
    mio: number | null,
  ): VotoResena {
    return { mio, a_favor: aFavor, en_contra: enContra };
  }

  /** total, promedio (2 decimales) y el reparto con las cinco claves siempre. */
  private armarResumen(filas: FilaResena[]): ResumenResenas {
    const reparto: Record<string, number> = {
      '1': 0,
      '2': 0,
      '3': 0,
      '4': 0,
      '5': 0,
    };
    let suma = 0;
    for (const fila of filas) {
      reparto[String(fila.calificacion)] += 1;
      suma += fila.calificacion;
    }
    const total = filas.length;
    const promedio = total === 0 ? 0 : Math.round((suma / total) * 100) / 100;
    return { total, promedio, reparto };
  }
}
