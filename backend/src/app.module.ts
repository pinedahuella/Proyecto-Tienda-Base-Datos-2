import { Module } from '@nestjs/common';
import { InicioController } from './controllers/inicio.controller';
import { InicioService } from './services/inicio.service';
import { BaseDatosController } from './controllers/base-datos.controller';
import { BaseDatosService } from './services/base-datos.service';
import { BaseDatosDocumentalController } from './controllers/base-datos-documental.controller';
import { BaseDatosDocumentalService } from './services/base-datos-documental.service';
import { UsuarioController } from './controllers/usuario.controller';
import { UsuarioService } from './services/usuario.service';
import { AdminUsuariosController } from './controllers/admin/admin-usuarios.controller';
import { AdminUsuariosService } from './services/admin/admin-usuarios.service';
import { AdminCatalogosController } from './controllers/admin/admin-catalogos.controller';
import { AdminCatalogosService } from './services/admin/admin-catalogos.service';
import { PerfilController } from './controllers/perfil.controller';
import { PerfilService } from './services/perfil.service';
import { LogService } from './services/log.service';
import { DireccionUsuarioController } from './controllers/direccion-usuario.controller';
import { DireccionUsuarioService } from './services/direccion-usuario.service';
import { ProductosController } from './controllers/productos/productos.controller';
import { ProductosService } from './services/productos/productos.service';
import { CategoriasPublicoController } from './controllers/productos/categorias.controller';
import { CategoriasController } from './controllers/vendedores/categorias.controller';
import { CategoriasService } from './services/vendedores/categorias.service';
import { ProductosVendedorController } from './controllers/vendedores/productos.controller';
import { ProductosVendedorService } from './services/vendedores/productos.service';
import { InventarioVendedorService } from './services/vendedores/inventario.service';
import { PedidosCompradorController } from './controllers/compradores/pedidos.controller';
import { PedidosCompradorService } from './services/compradores/pedidos.service';

/**
 * Modulo principal: la lista de todas las piezas de la aplicacion.
 *
 * Cada controlador nuevo se registra en "controllers" y cada servicio en
 * "providers". Si una clase no esta aqui, Nest no la conoce y su ruta no existe.
 */
@Module({
  imports: [],
  controllers: [
    InicioController,
    BaseDatosController,
    BaseDatosDocumentalController,
    UsuarioController,
    AdminUsuariosController,
    AdminCatalogosController,
    PerfilController,
    DireccionUsuarioController,
    ProductosController,
    CategoriasPublicoController,
    CategoriasController,
    ProductosVendedorController,
    PedidosCompradorController,
  ],
  providers: [
    InicioService,
    BaseDatosService,
    BaseDatosDocumentalService,
    UsuarioService,
    AdminUsuariosService,
    AdminCatalogosService,
    PerfilService,
    LogService,
    DireccionUsuarioService,
    ProductosService,
    CategoriasService,
    ProductosVendedorService,
    InventarioVendedorService,
    PedidosCompradorService,
  ],
})
export class AppModule {}
