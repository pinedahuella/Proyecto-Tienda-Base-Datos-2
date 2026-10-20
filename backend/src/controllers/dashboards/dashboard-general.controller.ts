import {
  Body,
  Controller,
  Get,
  Post,
  Query,
  Res,
  UseGuards,
} from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { Roles } from '../../decorators/roles.decorator';
import type { PeticionCorreoDashboard } from '../../dto/dashboards/dashboard-general';
import { SesionGuard } from '../../guards/sesion.guard';
import { ErrorValidacion } from '../../helpers/errores';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import { ID_ROL_ADMIN } from '../../models/rol-usuario';
import { DashboardCorreoService } from '../../services/dashboards/dashboard-correo.service';
import {
  DashboardExportarService,
  leerSecciones,
  nombreArchivo,
} from '../../services/dashboards/dashboard-exportar.service';
import { DashboardGeneralService } from '../../services/dashboards/dashboard-general.service';

/** El periodo de todas las rutas: `?desde=AAAA-MM-DD&hasta=AAAA-MM-DD`, los dos opcionales. */
interface QueryPeriodo {
  desde?: string;
  hasta?: string;
}

const TIPO_EXCEL =
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/**
 * El dashboard general del admin (pestana Dashboard del panel). Solo lectura:
 * cada seccion es un GET con el mismo periodo y la pagina las pide a la vez.
 *
 *   GET  /admin/dashboard/resumen          cifras de arriba contra el periodo anterior
 *   GET  /admin/dashboard/ventas           cobrado, pedidos y unidades en el tiempo
 *   GET  /admin/dashboard/embudo           de mirar (ClickHouse) a comprar (PostgreSQL)
 *   GET  /admin/dashboard/categorias       vendido por categoria
 *   GET  /admin/dashboard/pagos            cobrado por mes y metodo de pago
 *   GET  /admin/dashboard/mapa             pedidos por dia de la semana y hora
 *   GET  /admin/dashboard/vendedores       los 10 que mas vendieron
 *   GET  /admin/dashboard/productos        los 10 que mas dejaron
 *   GET  /admin/dashboard/departamentos    a donde se manda
 *   GET  /admin/dashboard/busquedas        lo que se busca y no se encuentra (ClickHouse)
 *   GET  /admin/dashboard/cancelaciones    cuando, de que y con que pago se cancela
 *   GET  /admin/dashboard/pedidos          el registro, paginado y con filtros
 *   GET  /admin/dashboard/exportar/excel   todo en un .xlsx (?secciones=a,b para elegir)
 *   GET  /admin/dashboard/exportar/pdf     todo en un .pdf con las graficas
 *   POST /admin/dashboard/exportar/correo  el .pdf o el .xlsx por correo
 *
 * Solo admin, en la clase, como `AdminReportesController`.
 */
@Controller('admin/dashboard')
@UseGuards(SesionGuard)
@Roles(ID_ROL_ADMIN)
export class DashboardGeneralController {
  constructor(
    private readonly dashboard: DashboardGeneralService,
    private readonly exportar: DashboardExportarService,
    private readonly correo: DashboardCorreoService,
  ) {}

  @Get('resumen')
  async resumen(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.resumen(q.desde, q.hasta),
      'resumen',
    );
  }

  @Get('ventas')
  async ventas(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.ventas(q.desde, q.hasta),
      'ventas',
    );
  }

  @Get('embudo')
  async embudo(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.embudo(q.desde, q.hasta),
      'embudo',
    );
  }

  @Get('categorias')
  async categorias(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.categorias(q.desde, q.hasta),
      'ventas por categoria',
    );
  }

  @Get('pagos')
  async pagos(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.pagos(q.desde, q.hasta),
      'pagos por mes',
    );
  }

  @Get('mapa')
  async mapa(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.mapa(q.desde, q.hasta),
      'mapa de calor',
    );
  }

  @Get('vendedores')
  async vendedores(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.vendedores(q.desde, q.hasta),
      'vendedores',
    );
  }

  @Get('productos')
  async productos(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.productos(q.desde, q.hasta),
      'productos',
    );
  }

  @Get('departamentos')
  async departamentos(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.departamentos(q.desde, q.hasta),
      'departamentos',
    );
  }

  @Get('busquedas')
  async busquedas(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.busquedas(q.desde, q.hasta),
      'busquedas',
    );
  }

  @Get('cancelaciones')
  async cancelaciones(@Query() q: QueryPeriodo) {
    return this.responder(
      () => this.dashboard.cancelaciones(q.desde, q.hasta),
      'cancelaciones',
    );
  }

  // GET /admin/dashboard/pedidos?desde&hasta&estado&metodo&texto&pagina&limite
  @Get('pedidos')
  async pedidos(
    @Query()
    q: QueryPeriodo & {
      estado?: string;
      metodo?: string;
      texto?: string;
      pagina?: string;
      limite?: string;
    },
  ) {
    return this.responder(
      () => this.dashboard.pedidos(q),
      'registro de pedidos',
    );
  }

  // GET /admin/dashboard/exportar/excel?desde&hasta&secciones=resumen,ventas
  @Get('exportar/excel')
  async excel(
    @Query() q: QueryPeriodo & { secciones?: string },
    @Res({ passthrough: true }) reply: FastifyReply,
  ) {
    try {
      const datos = await this.dashboard.completo(
        q.desde,
        q.hasta,
        leerSecciones(q.secciones),
      );
      const archivo = await this.exportar.excel(datos);
      reply.header('Content-Type', TIPO_EXCEL);
      reply.header(
        'Content-Disposition',
        `attachment; filename="${nombreArchivo(datos, 'xlsx')}"`,
      );
      return archivo;
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo armar el Excel del dashboard');
    }
  }

  // GET /admin/dashboard/exportar/pdf?desde&hasta&secciones=resumen,ventas
  @Get('exportar/pdf')
  async pdf(
    @Query() q: QueryPeriodo & { secciones?: string },
    @Res({ passthrough: true }) reply: FastifyReply,
  ) {
    try {
      const datos = await this.dashboard.completo(
        q.desde,
        q.hasta,
        leerSecciones(q.secciones),
      );
      const archivo = await this.exportar.pdf(datos);
      reply.header('Content-Type', 'application/pdf');
      reply.header(
        'Content-Disposition',
        `attachment; filename="${nombreArchivo(datos, 'pdf')}"`,
      );
      return archivo;
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo armar el PDF del dashboard');
    }
  }

  // POST /admin/dashboard/exportar/correo  { correos, formato, desde, hasta, secciones }
  @Post('exportar/correo')
  async enviarPorCorreo(@Body() cuerpo: PeticionCorreoDashboard) {
    try {
      const correos = this.correo.limpiarCorreos(cuerpo?.correos);
      const formato = cuerpo?.formato ?? 'pdf';
      if (formato !== 'pdf' && formato !== 'excel') {
        throw new ErrorValidacion('formato tiene que ser pdf o excel');
      }
      const datos = await this.dashboard.completo(
        cuerpo.desde,
        cuerpo.hasta,
        leerSecciones(cuerpo.secciones),
      );
      const archivo =
        formato === 'pdf'
          ? await this.exportar.pdf(datos)
          : await this.exportar.excel(datos);
      const { desde, hasta } = datos.periodo;
      await this.correo.enviar({
        correos,
        asunto: `Mesh, dashboard general del ${desde} al ${hasta}`,
        html:
          `<p style="font-family:sans-serif">Va adjunto el dashboard general de Mesh del <strong>${desde}</strong> al <strong>${hasta}</strong>.</p>` +
          `<p style="font-family:sans-serif;color:#6b7280">Lo mando el panel de administracion de Mesh.</p>`,
        adjunto: archivo,
        nombreAdjunto: nombreArchivo(datos, formato === 'pdf' ? 'pdf' : 'xlsx'),
        tipo: formato === 'pdf' ? 'application/pdf' : TIPO_EXCEL,
      });
      return exito(
        { correos, formato },
        `Dashboard enviado a ${correos.join(', ')}`,
      );
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo mandar el dashboard por correo');
    }
  }

  private async responder<T>(fn: () => Promise<T>, que: string) {
    try {
      return exito(await fn(), `Dashboard, ${que}`);
    } catch (error) {
      manejarErrorHttp(error, `No se pudo cargar ${que}`);
    }
  }
}
