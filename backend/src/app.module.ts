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
import { AdminPermisosController } from './controllers/admin/admin-permisos.controller';
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
import { PermisosOfertaController } from './controllers/vendedores/permisos-oferta.controller';
import { OfertasCompartidasController } from './controllers/compartidas/ofertas-compartidas.controller';
import { AclOfertasService } from './services/acl/acl-ofertas.service';
import { PermisosService } from './services/acl/permisos.service';
import { BuscarOfertasController } from './controllers/vendedores/buscar-ofertas.controller';
import { BuscarOfertasService } from './services/vendedores/buscar-ofertas.service';
import { EventoOfertaSyncService } from './services/vendedores/evento-oferta-sync.service';
import { VentasLimitadasController } from './controllers/vendedores/ventas-limitadas.controller';
import { VentasLimitadasService } from './services/vendedores/ventas-limitadas.service';
import { RegistroOfertasRedisService } from './services/vendedores/registro-ofertas-redis.service';
import { RegistroOfertasSyncService } from './services/vendedores/registro-ofertas-sync.service';
import { PedidosCompradorController } from './controllers/compradores/pedidos.controller';
import { PedidosCompradorService } from './services/compradores/pedidos.service';
import { SeguimientosOfertaController } from './controllers/compradores/seguimientos-oferta.controller';
import { SeguimientosOfertaService } from './services/compradores/seguimientos-oferta.service';
import { PercolarSeguimientosService } from './services/compradores/percolar-seguimientos.service';
import { ResenasController } from './controllers/resenas/resenas.controller';
import { ResenasService } from './services/resenas/resenas.service';
import { CarritoController } from './controllers/carrito/carrito.controller';
import { CarritoService } from './services/carrito/carrito.service';
import { CarritoPostgresService } from './services/carrito/carrito-postgres.service';
import { CarritoRedisService } from './services/carrito/carrito-redis.service';
import { CarritoBarridoService } from './services/carrito/carrito-barrido.service';
import { ReservasVentaRelampagoSyncService } from './services/inventario-limitado/reservas-venta-relampago-sync.service';
import { FraudeController } from './controllers/fraude/fraude.controller';
import { AnillosDetectorService } from './services/fraude/anillos-detector.service';
import { PatronesFraudeDetectorService } from './services/fraude/patrones-fraude-detector.service';
import { ResenasRepetidasDetectorService } from './services/fraude/resenas-repetidas-detector.service';
import { NotasIncoherentesDetectorService } from './services/fraude/notas-incoherentes-detector.service';
import { ResenasParecidasDetectorService } from './services/fraude/resenas-parecidas-detector.service';
import { ResenasCanceladasDetectorService } from './services/fraude/resenas-canceladas-detector.service';
import { ChequeoTextoInmediatoService } from './services/fraude/chequeo-texto-inmediato.service';
import { AnilloDeTextoDetectorService } from './services/fraude/anillo-de-texto-detector.service';
import { HallazgosEventoFraudeDetectorService } from './services/fraude/hallazgos-evento-fraude-detector.service';
import { AdminReportesController } from './controllers/admin/admin-reportes.controller';
import { DashboardGeneralController } from './controllers/dashboards/dashboard-general.controller';
import { AdminReportesService } from './services/admin/admin-reportes.service';
import { DashboardCorreoService } from './services/dashboards/dashboard-correo.service';
import { DashboardExportarService } from './services/dashboards/dashboard-exportar.service';
import { DashboardGeneralService } from './services/dashboards/dashboard-general.service';
import { InventarioLimitadoService } from './services/inventario-limitado/inventario-limitado.service';
import { GrafoController } from './controllers/grafo/grafo.controller';
import { GrafoSyncService } from './services/grafo/grafo-sync.service';
import { GrafoComprasSyncService } from './services/grafo/grafo-compras-sync.service';
import { GrafoCategoriasSyncService } from './services/grafo/grafo-categorias-sync.service';
import { BaseDatosBuscadorController } from './controllers/base-datos-buscador.controller';
import { BaseDatosBuscadorService } from './services/base-datos-buscador.service';
import { BaseDatosVectoresController } from './controllers/base-datos-vectores.controller';
import { BaseDatosVectoresService } from './services/base-datos-vectores.service';
import { BuscadorProductosController } from './controllers/buscador/productos.controller';
import { BuscadorProductosService } from './services/buscador/productos.service';
import { BuscadorFacetadoController } from './controllers/buscador/facetado.controller';
import { BuscadorFacetadoService } from './services/buscador/facetado.service';
import { SugeridosBusquedaService } from './services/buscador/sugeridos.service';
import { BuscadorSugerenciasController } from './controllers/buscador/sugerencias.controller';
import { BuscadorSugerenciasService } from './services/buscador/sugerencias.service';
import { BuscadorIntencionController } from './controllers/buscador/intencion.controller';
import { BuscadorIntencionService } from './services/buscador/intencion.service';
import { BuscadorHibridoController } from './controllers/buscador/hibrida.controller';
import { BuscadorHibridoService } from './services/buscador/hibrida.service';
import { SugerenciasPropuestaController } from './controllers/vendedores/sugerencias-propuesta.controller';
import { SugerenciasPropuestaService } from './services/vendedores/sugerencias-propuesta.service';
import { BuscadorSyncService } from './services/buscador/buscador-sync.service';
import { EventoProductoSyncService } from './services/productos/evento-producto-sync.service';
import { EventosAutenticacionSyncService } from './services/eventos-autenticacion/eventos-autenticacion-sync.service';
import { FraudeLoginService } from './services/fraude-login/fraude-login.service';
import { TomaCuentaService } from './services/fraude-login/toma-cuenta.service';
import { ViajeImposibleService } from './services/fraude-login/viaje-imposible.service';
import { FraudeLoginRetrospectivoService } from './services/fraude-login/fraude-login-retrospectivo.service';
import { AdminFraudeLoginController } from './controllers/admin/admin-fraude-login.controller';
import { FraudeLoginExploracionService } from './services/fraude-login/fraude-login-exploracion.service';
import { AdminFraudeAnillosController } from './controllers/admin/admin-fraude-anillos.controller';
import { FraudeAnillosPersistidosService } from './services/fraude/fraude-anillos-persistidos.service';
import { AdminCasosFraudeController } from './controllers/admin/admin-casos-fraude.controller';
import { HallazgoFraudeAdaptadorService } from './services/fraude/hallazgo-fraude-adaptador.service';
import { AgrupadorFraudeService } from './services/fraude/agrupador-fraude.service';
import { PuntajeFraudeService } from './services/fraude/puntaje-fraude.service';
import { ReglasCasiConfirmadoService } from './services/fraude/reglas-casi-confirmado.service';
import { PersistenciaCasoFraudeService } from './services/fraude/persistencia-caso-fraude.service';
import { AgrupadorFraudeWorkerService } from './services/fraude/agrupador-fraude-worker.service';
import { CasosFraudeService } from './services/fraude/casos-fraude.service';
import { AdminFraudeEventosController } from './controllers/admin/admin-fraude-eventos.controller';
import { HallazgosEventoFraudePersistidosService } from './services/fraude/hallazgos-evento-fraude-persistidos.service';
import { EventosController } from './controllers/eventos.controller';
import { EventosService } from './services/eventos/eventos.service';
import { AdminTendenciasController } from './controllers/admin/admin-tendencias.controller';
import { AdminTendenciasService } from './services/admin/admin-tendencias.service';
import { AdminTendenciasAvanzadasController } from './controllers/admin/admin-tendencias-avanzadas.controller';
import { AdminTendenciasAvanzadasService } from './services/admin/admin-tendencias-avanzadas.service';
import { MasVendidosSyncService } from './services/productos/mas-vendidos-sync.service';
import { MasVendidosController } from './controllers/productos/mas-vendidos.controller';
import { MasVendidosService } from './services/productos/mas-vendidos.service';
import { MasVistosSyncService } from './services/productos/mas-vistos-sync.service';
import { MasVistosController } from './controllers/productos/mas-vistos.controller';
import { MasVistosService } from './services/productos/mas-vistos.service';
import { OfertasDestacadasController } from './controllers/productos/ofertas-destacadas.controller';
import { OfertasDestacadasService } from './services/productos/ofertas-destacadas.service';
import { VistosRecientementeController } from './controllers/productos/vistos-recientemente.controller';
import { VistosRecientementeService } from './services/productos/vistos-recientemente.service';
import { TambienVieronSyncService } from './services/productos/tambien-vieron-sync.service';
import { TambienVieronController } from './controllers/productos/tambien-vieron.controller';
import { TambienVieronService } from './services/productos/tambien-vieron.service';
import { SimilaresController } from './controllers/productos/similares.controller';
import { SimilaresService } from './services/productos/similares.service';
import { VectoresSyncService } from './services/productos/vectores-sync.service';
import { EventoComentarioSyncService } from './services/resenas/evento-comentario-sync.service';
import { ValoracionComentariosService } from './services/resenas/valoracion-comentarios.service';
import { ParaTiController } from './controllers/productos/para-ti.controller';
import { TambienCompraronController } from './controllers/productos/tambien-compraron.controller';
import { TambienCompraronService } from './services/productos/tambien-compraron.service';
import { CombosController } from './controllers/productos/combos.controller';
import { CombosService } from './services/productos/combos.service';
import { CombosSyncService } from './services/productos/combos-sync.service';
import { AdminBusquedasSinResultadosService } from './services/admin/admin-busquedas-sin-resultados.service';
import { ParaTiService } from './services/productos/para-ti.service';
import { ReglasDescuentoAutomaticoController } from './controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller';
import { ReglasDescuentoAutomaticoService } from './services/reglas-descuento-automatico/reglas-descuento-automatico.service';
import { ReglasDescuentoPeriodoController } from './controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller';
import { ReglasDescuentoPeriodoService } from './services/reglas-descuento-periodo/reglas-descuento-periodo.service';
import { DisparadorReglasPeriodoService } from './services/reglas-descuento-periodo/disparador-reglas-periodo.service';
import { DisparadorReglasAutomaticoService } from './services/reglas-descuento-automatico/disparador-reglas-automatico.service';

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
    AdminPermisosController,
    AdminCatalogosController,
    PerfilController,
    DireccionUsuarioController,
    ProductosController,
    CategoriasPublicoController,
    CategoriasController,
    ProductosVendedorController,
    OfertasVendedorController,
    PermisosOfertaController,
    OfertasCompartidasController,
    BuscarOfertasController,
    VentasLimitadasController,
    PedidosCompradorController,
    SeguimientosOfertaController,
    ResenasController,
    CarritoController,
    FraudeController,
    AdminReportesController,
    DashboardGeneralController,
    GrafoController,
    BaseDatosBuscadorController,
    BaseDatosVectoresController,
    BuscadorProductosController,
    BuscadorFacetadoController,
    BuscadorSugerenciasController,
    BuscadorIntencionController,
    BuscadorHibridoController,
    SugerenciasPropuestaController,
    AdminFraudeLoginController,
    AdminFraudeAnillosController,
    AdminCasosFraudeController,
    AdminFraudeEventosController,
    EventosController,
    AdminTendenciasController,
    AdminTendenciasAvanzadasController,
    MasVendidosController,
    MasVistosController,
    OfertasDestacadasController,
    VistosRecientementeController,
    TambienVieronController,
    SimilaresController,
    ParaTiController,
    TambienCompraronController,
    CombosController,
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
    AclOfertasService,
    PermisosService,
    BuscarOfertasService,
    EventoOfertaSyncService,
    VentasLimitadasService,
    RegistroOfertasRedisService,
    RegistroOfertasSyncService,
    PedidosCompradorService,
    SeguimientosOfertaService,
    PercolarSeguimientosService,
    ResenasService,
    CarritoService,
    CarritoPostgresService,
    CarritoRedisService,
    CarritoBarridoService,
    ReservasVentaRelampagoSyncService,
    AnillosDetectorService,
    PatronesFraudeDetectorService,
    ResenasRepetidasDetectorService,
    NotasIncoherentesDetectorService,
    ResenasParecidasDetectorService,
    ResenasCanceladasDetectorService,
    ChequeoTextoInmediatoService,
    AnilloDeTextoDetectorService,
    HallazgosEventoFraudeDetectorService,
    AdminReportesService,
    DashboardGeneralService,
    DashboardExportarService,
    DashboardCorreoService,
    InventarioLimitadoService,
    GrafoSyncService,
    GrafoComprasSyncService,
    GrafoCategoriasSyncService,
    BaseDatosBuscadorService,
    BaseDatosVectoresService,
    BuscadorProductosService,
    BuscadorFacetadoService,
    SugeridosBusquedaService,
    BuscadorSugerenciasService,
    BuscadorIntencionService,
    BuscadorHibridoService,
    SugerenciasPropuestaService,
    BuscadorSyncService,
    EventoProductoSyncService,
    EventosAutenticacionSyncService,
    FraudeLoginService,
    TomaCuentaService,
    ViajeImposibleService,
    FraudeLoginRetrospectivoService,
    FraudeLoginExploracionService,
    FraudeAnillosPersistidosService,
    HallazgoFraudeAdaptadorService,
    AgrupadorFraudeService,
    PuntajeFraudeService,
    ReglasCasiConfirmadoService,
    PersistenciaCasoFraudeService,
    AgrupadorFraudeWorkerService,
    CasosFraudeService,
    HallazgosEventoFraudePersistidosService,
    EventosService,
    AdminTendenciasService,
    AdminTendenciasAvanzadasService,
    MasVendidosSyncService,
    MasVendidosService,
    MasVistosSyncService,
    MasVistosService,
    OfertasDestacadasService,
    VistosRecientementeService,
    TambienVieronSyncService,
    TambienVieronService,
    SimilaresService,
    VectoresSyncService,
    EventoComentarioSyncService,
    ValoracionComentariosService,
    ParaTiService,
    TambienCompraronService,
    CombosService,
    CombosSyncService,
    AdminBusquedasSinResultadosService,
    ReglasDescuentoAutomaticoService,
    ReglasDescuentoPeriodoService,
    DisparadorReglasPeriodoService,
    DisparadorReglasAutomaticoService,
  ],
})
export class AppModule {}
