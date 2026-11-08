import {
  Body,
  Controller,
  Get,
  Param,
  Patch,
  Query,
  UseGuards,
} from '@nestjs/common';
import { UsuarioActual } from '../../decorators/usuario-actual.decorator';
import { Permiso } from '../../decorators/permiso.decorator';
import { PermisoGuard } from '../../guards/permiso.guard';
import { SesionGuard } from '../../guards/sesion.guard';
import { manejarErrorHttp } from '../../helpers/manejar-error-http';
import { exito } from '../../helpers/respuesta';
import type { TokenUsuario } from '../../dto/token-usuario';
import { OfertasVendedorService } from '../../services/vendedores/ofertas.service';

/** Cuerpo de PATCH /admin/ofertas/:id. Sin precio: el precio es del vendedor. */
interface AdministrarOfertaPeticion {
  estado?: string;
  ajuste_stock?: number;
}

/**
 * Controlador de /admin/ofertas: la tienda ve todas las ofertas de un
 * producto, de cualquier vendedor y en cualquier estado, y las pausa,
 * reactiva o retira y les ajusta las unidades (migracion 053). En el panel
 * sale en Catalogo, con el boton Ofertas de cada producto.
 *
 * @Permiso('ofertas.administrar') en la clase. En la semilla solo el admin.
 */
@Controller('admin/ofertas')
@UseGuards(SesionGuard, PermisoGuard)
@Permiso('ofertas.administrar')
export class AdminOfertasController {
  constructor(private readonly ofertasService: OfertasVendedorService) {}

  // GET /admin/ofertas?producto=7
  @Get()
  async listar(@Query('producto') producto: string) {
    try {
      const ofertas = await this.ofertasService.listarDeProducto(producto);
      return exito(ofertas, 'Ofertas del producto obtenidas');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudieron obtener las ofertas');
    }
  }

  // PATCH /admin/ofertas/:id   { "estado": "pausada", "ajuste_stock": -2 }
  @Patch(':id')
  async administrar(
    @Param('id') id: string,
    @Body() cuerpo: AdministrarOfertaPeticion | undefined,
    @UsuarioActual() usuarioActual: TokenUsuario,
  ) {
    try {
      const oferta = await this.ofertasService.administrar(
        usuarioActual.id_usuario,
        id,
        cuerpo,
      );
      return exito(oferta, 'Oferta actualizada por la tienda');
    } catch (error) {
      manejarErrorHttp(error, 'No se pudo actualizar la oferta');
    }
  }
}
