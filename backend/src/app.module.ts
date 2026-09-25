import { Module } from '@nestjs/common';
import { ScheduleModule } from '@nestjs/schedule';
import { InicioController } from './controllers/inicio.controller';
import { InicioService } from './services/inicio.service';
import { BaseDatosController } from './controllers/base-datos.controller';
import { BaseDatosService } from './services/base-datos.service';
import { BaseDatosDocumentalController } from './controllers/base-datos-documental.controller';
import { BaseDatosDocumentalService } from './services/base-datos-documental.service';
import { BaseDatosClaveValorController } from './controllers/base-datos-clave-valor.controller';
import { BaseDatosClaveValorService } from './services/base-datos-clave-valor.service';
import { BaseDatosGrafoController } from './controllers/base-datos-grafo.controller';
import { BaseDatosGrafoService } from './services/base-datos-grafo.service';
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
import { OfertasVendedorController } from './controllers/vendedores/ofertas.controller';
import { OfertasVendedorService } from './services/vendedores/ofertas.service';
import { VentasLimitadasController } from './controllers/vendedores/ventas-limitadas.controller';
import { VentasLimitadasService } from './services/vendedores/ventas-limitadas.service';
import { RegistroOfertasRedisService } from './services/vendedores/registro-ofertas-redis.service';
import { RegistroOfertasSyncService } from './services/vendedores/registro-ofertas-sync.service';
import { PedidosCompradorController } from './controllers/compradores/pedidos.controller';
import { PedidosCompradorService } from './services/compradores/pedidos.service';
import { ResenasController } from './controllers/resenas/resenas.controller';
import { ResenasService } from './services/resenas/resenas.service';
import { CarritoController } from './controllers/carrito/carrito.controller';
import { CarritoService } from './services/carrito/carrito.service';
import { FraudeController } from './controllers/fraude/fraude.controller';
import { AnillosDetectorService } from './services/fraude/anillos-detector.service';
import { PatronesFraudeDetectorService } from './services/fraude/patrones-fraude-detector.service';
import { AdminReportesController } from './controllers/admin/admin-reportes.controller';
import { AdminReportesService } from './services/admin/admin-reportes.service';
import { InventarioLimitadoService } from './services/inventario-limitado/inventario-limitado.service';
import { GrafoController } from './controllers/grafo/grafo.controller';
import { GrafoSyncService } from './services/grafo/grafo-sync.service';
import { BaseDatosBuscadorController } from './controllers/base-datos-buscador.controller';
import { BaseDatosBuscadorService } from './services/base-datos-buscador.service';
import { BuscadorProductosController } from './controllers/buscador/productos.controller';
import { BuscadorProductosService } from './services/buscador/productos.service';
import { BuscadorSyncService } from './services/buscador/buscador-sync.service';
import { EventosAutenticacionSyncService } from './services/eventos-autenticacion/eventos-autenticacion-sync.service';
import { FraudeLoginService } from './services/fraude-login/fraude-login.service';
import { TomaCuentaService } from './services/fraude-login/toma-cuenta.service';
import { ViajeImposibleService } from './services/fraude-login/viaje-imposible.service';
import { FraudeLoginRetrospectivoService } from './services/fraude-login/fraude-login-retrospectivo.service';
import { AdminFraudeLoginController } from './controllers/admin/admin-fraude-login.controller';
import { FraudeLoginExploracionService } from './services/fraude-login/fraude-login-exploracion.service';
import { AdminFraudeAnillosController } from './controllers/admin/admin-fraude-anillos.controller';
import { FraudeAnillosPersistidosService } from './services/fraude/fraude-anillos-persistidos.service';
import { EventosController } from './controllers/eventos.controller';
import { EventosService } from './services/eventos/eventos.service';
import { AdminTendenciasController } from './controllers/admin/admin-tendencias.controller';
import { AdminTendenciasService } from './services/admin/admin-tendencias.service';
import { MasVendidosSyncService } from './services/productos/mas-vendidos-sync.service';
import { MasVendidosController } from './controllers/productos/mas-vendidos.controller';
import { MasVendidosService } from './services/productos/mas-vendidos.service';
import { OfertasDestacadasController } from './controllers/productos/ofertas-destacadas.controller';
import { OfertasDestacadasService } from './services/productos/ofertas-destacadas.service';
import { ReglasDescuentoAutomaticoController } from './controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller';
import { ReglasDescuentoAutomaticoService } from './services/reglas-descuento-automatico/reglas-descuento-automatico.service';
import { ReglasDescuentoPeriodoController } from './controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller';
import { ReglasDescuentoPeriodoService } from './services/reglas-descuento-periodo/reglas-descuento-periodo.service';
import { DisparadorReglasPeriodoService } from './services/reglas-descuento-periodo/disparador-reglas-periodo.service';

/**
 * Modulo principal: la lista de todas las piezas de la aplicacion.
 *
 * Cada controlador nuevo se registra en "controllers" y cada servicio en
 * "providers". Si una clase no esta aqui, Nest no la conoce y su ruta no existe.
 */
@Module({
  imports: [
    // Habilita @Interval/@Cron -- lo usa GrafoSyncService (worker del outbox).
    ScheduleModule.forRoot(),
  ],
  controllers: [
    InicioController,
    BaseDatosController,
    BaseDatosDocumentalController,
    BaseDatosClaveValorController,
    BaseDatosGrafoController,
    UsuarioController,
    AdminUsuariosController,
    AdminCatalogosController,
    PerfilController,
    DireccionUsuarioController,
    ProductosController,
    CategoriasPublicoController,
    CategoriasController,
    ProductosVendedorController,
    OfertasVendedorController,
    VentasLimitadasController,
    PedidosCompradorController,
    ResenasController,
    CarritoController,
    FraudeController,
    AdminReportesController,
    GrafoController,
    BaseDatosBuscadorController,
    BuscadorProductosController,
    AdminFraudeLoginController,
    AdminFraudeAnillosController,
    EventosController,
    AdminTendenciasController,
    MasVendidosController,
    OfertasDestacadasController,
    ReglasDescuentoAutomaticoController,
    ReglasDescuentoPeriodoController,
  ],
  providers: [
    InicioService,
    BaseDatosService,
    BaseDatosDocumentalService,
    BaseDatosClaveValorService,
    BaseDatosGrafoService,
    UsuarioService,
    AdminUsuariosService,
    AdminCatalogosService,
    PerfilService,
    LogService,
    DireccionUsuarioService,
    ProductosService,
    CategoriasService,
    ProductosVendedorService,
    OfertasVendedorService,
    VentasLimitadasService,
    RegistroOfertasRedisService,
    RegistroOfertasSyncService,
    PedidosCompradorService,
    ResenasService,
    CarritoService,
    AnillosDetectorService,
    PatronesFraudeDetectorService,
    AdminReportesService,
    InventarioLimitadoService,
    GrafoSyncService,
    BaseDatosBuscadorService,
    BuscadorProductosService,
    BuscadorSyncService,
    EventosAutenticacionSyncService,
    FraudeLoginService,
    TomaCuentaService,
    ViajeImposibleService,
    FraudeLoginRetrospectivoService,
    FraudeLoginExploracionService,
    FraudeAnillosPersistidosService,
    EventosService,
    AdminTendenciasService,
    MasVendidosSyncService,
    MasVendidosService,
    OfertasDestacadasService,
    ReglasDescuentoAutomaticoService,
    ReglasDescuentoPeriodoService,
    DisparadorReglasPeriodoService,
  ],
})
export class AppModule {}
