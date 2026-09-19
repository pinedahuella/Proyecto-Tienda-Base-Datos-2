import { Injectable, Logger } from '@nestjs/common';
import { clickhouse } from '../../database/clickhouse';
import type { OrigenVista } from '../../dto/registrar-vista';

/**
 * Escribe los eventos de producto/buscador en ClickHouse -- ver
 * `elementos Generales/plan pendiente/eventos-clickhouse.md`.
 *
 * A proposito NUNCA lanza: registrar un evento es un efecto secundario de
 * algo que ya paso (una vista, un agregado al carrito), no algo de lo que
 * dependa la respuesta al cliente. Mismo criterio que `LogService.guardar()`
 * y `FraudeLoginService.registrarIntento()` -- si ClickHouse esta caido o
 * tarda, el detalle queda en el log del servidor y la peticion HTTP sigue
 * igual. Por eso cada controlador la llama SIN `await`.
 */
@Injectable()
export class EventosService {
  private readonly logger = new Logger(EventosService.name);

  /** `POST /eventos/vista` -- publica, `id_usuario` opcional. */
  async registrarVista(datos: {
    idProducto: number;
    idUsuario: string | null;
    sesion: string;
    ip: string;
    origen: OrigenVista;
  }): Promise<void> {
    try {
      await clickhouse.insert({
        table: 'vista_producto',
        values: [
          {
            fecha: formatoFechaClickHouse(new Date()),
            id_producto: datos.idProducto,
            id_usuario: datos.idUsuario,
            sesion: datos.sesion,
            ip: datos.ip,
            origen: datos.origen,
            lote: 'real',
          },
        ],
        format: 'JSONEachRow',
      });
    } catch (error) {
      this.logger.warn(`No se pudo registrar la vista de producto: ${error}`);
    }
  }

  /**
   * `POST /eventos/carrito` -- exige sesion (el carrito siempre la exige en
   * este proyecto), `id_usuario` obligatorio, nunca `null`. Sin `sesion` ni
   * `origen`: no hace falta distinguir visitantes anonimos aqui.
   */
  async registrarCarrito(datos: {
    idProducto: number;
    idOferta: number;
    idUsuario: string;
    cantidad: number;
    ip: string;
  }): Promise<void> {
    try {
      await clickhouse.insert({
        table: 'carrito_producto',
        values: [
          {
            fecha: formatoFechaClickHouse(new Date()),
            id_producto: datos.idProducto,
            id_oferta: datos.idOferta,
            id_usuario: datos.idUsuario,
            cantidad: datos.cantidad,
            ip: datos.ip,
            lote: 'real',
          },
        ],
        format: 'JSONEachRow',
      });
    } catch (error) {
      this.logger.warn(`No se pudo registrar el agregado al carrito: ${error}`);
    }
  }

  /**
   * Compra confirmada -- llamada DIRECTO desde `CarritoService.ejecutarCompraCarrito`
   * (fire-and-forget, sin `await`), justo despues de que `comprar_carrito()`
   * de PostgreSQL confirma el pedido. Sin ruta HTTP propia: a diferencia de
   * `vista`/`carrito`, este evento no depende de que el frontend avise nada
   * -- el backend YA sabe con certeza que la compra paso, no hace falta
   * pedirselo a nadie mas. Ver `elementos Generales/plan pendiente/eventos-clickhouse.md`
   * para el porque de esta decision (y por que NO es un worker con outbox,
   * a diferencia de reseñas->Neo4j o logueos->Elasticsearch).
   *
   * `ReplacingMergeTree` en `compra_producto` (por `id_pedido`) protege
   * contra un reintento de este mismo fire-and-forget si algun dia lo
   * hubiera -- hoy no se reintenta, pero la tabla ya viene preparada.
   *
   * Una fila POR LINEA del pedido, todas en un solo `INSERT` (ClickHouse
   * prefiere lotes a filas sueltas) -- nunca una llamada por linea.
   */
  async registrarCompra(datos: {
    idUsuario: string;
    idPedido: number;
    ip: string;
    lineas: { idProducto: number; idOferta: number; cantidad: number }[];
  }): Promise<void> {
    if (datos.lineas.length === 0) {
      return;
    }
    try {
      const fecha = formatoFechaClickHouse(new Date());
      await clickhouse.insert({
        table: 'compra_producto',
        values: datos.lineas.map((linea) => ({
          fecha,
          id_producto: linea.idProducto,
          id_oferta: linea.idOferta,
          id_usuario: datos.idUsuario,
          cantidad: linea.cantidad,
          id_pedido: datos.idPedido,
          ip: datos.ip,
          lote: 'real',
        })),
        format: 'JSONEachRow',
      });
    } catch (error) {
      this.logger.warn(
        `No se pudo registrar la compra en ClickHouse: ${error}`,
      );
    }
  }

  /**
   * Devolucion/cancelacion confirmada -- llamada DIRECTO desde
   * `PedidosCompradorService.cancelarPedido()`, mismo patron exacto que
   * `registrarCompra` (sin ruta HTTP, fire-and-forget, sin `await`, misma
   * razon para no ser un worker con outbox). Solo se llama cuando el pedido
   * SI estaba comprado (nunca para uno pendiente que nunca llego a compra).
   *
   * Sin `motivo`: se evaluo agregarlo, pero `motivo_movimiento` en
   * PostgreSQL solo tiene un valor relevante aqui (`devolucion`, generico)
   * -- no hay una razon mas especifica que capturar todavia.
   */
  async registrarDevolucion(datos: {
    idUsuario: string;
    idPedido: number;
    ip: string;
    lineas: { idProducto: number; idOferta: number; cantidad: number }[];
  }): Promise<void> {
    if (datos.lineas.length === 0) {
      return;
    }
    try {
      const fecha = formatoFechaClickHouse(new Date());
      await clickhouse.insert({
        table: 'devolucion_producto',
        values: datos.lineas.map((linea) => ({
          fecha,
          id_producto: linea.idProducto,
          id_oferta: linea.idOferta,
          id_usuario: datos.idUsuario,
          cantidad: linea.cantidad,
          id_pedido: datos.idPedido,
          ip: datos.ip,
          lote: 'real',
        })),
        format: 'JSONEachRow',
      });
    } catch (error) {
      this.logger.warn(
        `No se pudo registrar la devolucion en ClickHouse: ${error}`,
      );
    }
  }

  /**
   * `busqueda_realizada` -- llamada DIRECTO desde
   * `BuscadorProductosController.buscar()` (fire-and-forget, sin `await`),
   * SIN ruta propia: el backend ya corrio la busqueda y sabe el termino y
   * cuantos resultados dio, no hace falta que el frontend avise nada (mismo
   * razonamiento que `registrarCompra`, no el de `registrarVista`).
   *
   * `idUsuario` opcional (de la cookie si hay una valida): buscar es
   * publico, igual que ver un producto.
   */
  async registrarBusqueda(datos: {
    termino: string;
    resultados: number;
    idUsuario: string | null;
    sesion: string;
  }): Promise<void> {
    try {
      await clickhouse.insert({
        table: 'busqueda_realizada',
        values: [
          {
            fecha: formatoFechaClickHouse(new Date()),
            termino: datos.termino,
            resultados: datos.resultados,
            id_usuario: datos.idUsuario,
            sesion: datos.sesion,
            lote: 'real',
          },
        ],
        format: 'JSONEachRow',
      });
    } catch (error) {
      this.logger.warn(
        `No se pudo registrar la busqueda en ClickHouse: ${error}`,
      );
    }
  }

  /**
   * `POST /eventos/busqueda-clic` -- a diferencia de `registrarBusqueda`,
   * SI necesita ruta propia: hacer clic en un resultado es una interaccion
   * de interfaz que el backend no puede saber por su cuenta.
   */
  async registrarClicBusqueda(datos: {
    termino: string;
    idProducto: number;
    posicion: number;
    idUsuario: string | null;
    sesion: string;
  }): Promise<void> {
    try {
      await clickhouse.insert({
        table: 'busqueda_clic',
        values: [
          {
            fecha: formatoFechaClickHouse(new Date()),
            termino: datos.termino,
            id_producto: datos.idProducto,
            posicion: datos.posicion,
            id_usuario: datos.idUsuario,
            sesion: datos.sesion,
            lote: 'real',
          },
        ],
        format: 'JSONEachRow',
      });
    } catch (error) {
      this.logger.warn(
        `No se pudo registrar el clic de busqueda en ClickHouse: ${error}`,
      );
    }
  }
}

/**
 * `DateTime64(3)` de ClickHouse por HTTP/JSONEachRow quiere un STRING
 * `AAAA-MM-DD HH:MM:SS.mmm`, no un numero -- un `INSERT` de prueba directo
 * confirmo que un timestamp numerico (segundos o milisegundos desde epoch)
 * falla al parsear o, peor, se interpreta mal sin avisar. El string se
 * arma en la zona horaria del SERVIDOR de ClickHouse (`America/Guatemala`,
 * ver `clickhouse/docker-compose.yml`) con `Intl.DateTimeFormat`, sin
 * importar en que zona horaria corra el proceso de Node -- un string sin
 * offset se interpreta en la zona del servidor, y si se armara con la hora
 * LOCAL del backend (que podria estar en otra zona) el dato quedaria
 * corrido, el mismo problema que ya paso una vez con el `now()` del
 * contenedor (ver el propio `clickhouse/docker-compose.yml`).
 */
function formatoFechaClickHouse(fecha: Date): string {
  const partes = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Guatemala',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  }).formatToParts(fecha);
  const obtener = (tipo: string): string =>
    partes.find((p) => p.type === tipo)?.value ?? '00';
  const milisegundos = String(fecha.getMilliseconds()).padStart(3, '0');
  return `${obtener('year')}-${obtener('month')}-${obtener('day')} ${obtener('hour')}:${obtener('minute')}:${obtener('second')}.${milisegundos}`;
}
