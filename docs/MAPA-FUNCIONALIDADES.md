# Mapa de funcionalidades de Mesh

Para encontrar rapido donde vive cada cosa del backend. Va por modulos grandes,
y en cada uno sus services, que es donde esta la logica. Debajo de cada service,
cada metodo que usa una ruta, con su linea, la ruta, el permiso que pide y el
controller que la recibe. Los workers dicen cada cuanto corren.

Los archivos que empiezan con `src/` son del backend, dentro de `backend/`.
Los de la pagina empiezan con `frontend/`. Lo armo un script leyendo el codigo
el 8 de noviembre de 2026, asi que las lineas son las de ese dia. Si alguien
mueve codigo, se abre el archivo y se busca el nombre del metodo.

**Como viaja una peticion.** La pagina llama una ruta, el controller la recibe,
`SesionGuard` y `PermisoGuard` la revisan, y el controller llama al service,
que es el que va a la base. Los helpers son funciones sueltas que usan varios
services. El paso a paso de cada flujo, de la pagina a la base, esta en
`presentacion-final/GUION.md`, en Los flujos de toda la tienda.

| Cifra | Hoy |
|---|---|
| Rutas del backend | 179, de ellas 146 con permiso y 33 publicas |
| Services | 99 |
| Workers que corren solos | 31 |

1. [Buscador](#buscador)
2. [Catalogo y ficha del producto](#catalogo-y-ficha-del-producto)
3. [Vectores y recomendacion semantica](#vectores-y-recomendacion-semantica)
4. [Recomendaciones por grafo y por eventos](#recomendaciones-por-grafo-y-por-eventos)
5. [Carrito, pago y venta relampago](#carrito-pago-y-venta-relampago)
6. [Pedidos y direcciones](#pedidos-y-direcciones)
7. [Ofertas, descuentos, reglas y avisos](#ofertas-descuentos-reglas-y-avisos)
8. [Resenas](#resenas)
9. [Cuenta, sesion y control de acceso](#cuenta-sesion-y-control-de-acceso)
10. [Panel del admin, dashboard, reportes, cuentas y tendencias](#panel-del-admin-dashboard-reportes-cuentas-y-tendencias)
11. [Fraude](#fraude)
12. [Las bases, su estado y su respaldo](#las-bases-su-estado-y-su-respaldo)

## Buscador

Elasticsearch. Busca aunque se escriba mal, sin tildes, y cuenta los filtros. Si Elasticsearch no contesta, busca en PostgreSQL.

**Services**

- `src/services/buscador/productos.service.ts:78`, `BuscadorProductosService`. La lista que sale mientras se escribe en la cabecera, con la palabra a medias (`bool_prefix`) y con errores (`fuzziness`).
  - `buscar()` `:88`, `GET /buscador/productos`, publica, controller `src/controllers/buscador/productos.controller.ts:36`
  - `buscarAdmin()` `:106`, `GET /buscador/productos/admin`, `@Permiso('catalogo.buscar_todo')`, controller `src/controllers/buscador/productos.controller.ts:73`
- `src/services/buscador/facetado.service.ts:94`, `BuscadorFacetadoService`. La pagina de resultados, con los filtros y sus numeros (`aggs`) y el Tal vez quisiste decir.
  - `buscar()` `:99`, `GET /buscador/productos/facetado`, publica, controller `src/controllers/buscador/facetado.controller.ts:30`
- `src/services/buscador/hibrida.service.ts:125`, `BuscadorHibridoService`. Junta la busqueda por palabras de Elasticsearch con la de significado de PostgreSQL, por posicion (RRF).
  - `buscar()` `:128`, `GET /buscador/productos/hibrida`, publica, controller `src/controllers/buscador/hibrida.controller.ts:20`
- `src/services/buscador/intencion.service.ts:105`, `BuscadorIntencionService`. Lo que cuentan otros compradores. Compara una frase con el vector de cada resena.
  - `buscar()` `:108`, `GET /buscador/productos/intencion`, publica, controller `src/controllers/buscador/intencion.controller.ts:22`
- `src/services/buscador/sugerencias.service.ts:33`, `BuscadorSugerenciasService`. Sugerencias de nombres al escribir.
  - `sugerir()` `:36`, `GET /buscador/productos/sugerencias`, publica, controller `src/controllers/buscador/sugerencias.controller.ts:21`
- `src/services/buscador/sugeridos.service.ts:77`, `SugeridosBusquedaService`. Lo que se ofrece cuando una busqueda no encuentra nada.
- `src/services/buscador/buscador-sync.service.ts:28`, `BuscadorSyncService`. Lleva a Elasticsearch los productos con la bandera `pendiente_busqueda` de MongoDB.
  - Corre solo cada 10 s, `@Interval` en la `:39`
- `src/services/vendedores/buscar-ofertas.service.ts:62`, `BuscarOfertasService`. El vendedor busca entre sus ofertas, en el indice `mesh_ofertas`.
  - `buscar()` `:65`, `GET /vendedor/ofertas/buscar`, `@Permiso('ofertas.ver')`, controller `src/controllers/vendedores/buscar-ofertas.controller.ts:28`

**Helpers y guardias**

- `src/helpers/correccion-busqueda.ts:40`, `pedirCorreccion()`. Arma el `suggest` del Tal vez quisiste decir.
- `src/helpers/buscador-respaldo.ts:156`, `buscarEnCopia()`. El buscador cuando Elasticsearch no contesta, en la copia de PostgreSQL, sin tildes y con errores.

**En la pagina**, `frontend/src/lib/BuscadorCabecera.svelte`, `frontend/src/routes/buscar/+page.svelte`, `frontend/src/lib/buscador.ts`

## Catalogo y ficha del producto

MongoDB guarda cada producto con sus variantes y caracteristicas. PostgreSQL tiene una copia corta, `producto_catalogo`, para comprar y para cuando MongoDB no contesta.

**Services**

- `src/services/productos/productos.service.ts:112`, `ProductosService`. La portada, la ficha y el historial del producto a una fecha (Entrega 1).
  - `listar()` `:132`, `GET /productos`, publica, controller `src/controllers/productos/productos.controller.ts:28`
  - `listarPaginado()` `:179`, `GET /productos/paginacion`, publica, controller `src/controllers/productos/productos.controller.ts:41`
  - `obtenerPublico()` `:265`, `GET /productos/:id`, publica, controller `src/controllers/productos/productos.controller.ts:100`
  - `reconstruirEnFecha()` `:398`, `GET /productos/:id/historial`, `@Permiso('productos.historial')`, controller `src/controllers/productos/productos.controller.ts:57`
  - `reconstruirOfertaEnFecha()` `:501`, `GET /productos/ofertas/:id/historial`, `@Permiso('productos.historial')`, controller `src/controllers/productos/productos.controller.ts:82`
- `src/services/vendedores/productos.service.ts:117`, `ProductosVendedorService`. Crear, proponer, aprobar y editar productos. Marca las banderas para el buscador y los vectores.
  - `crear()` `:125`, `POST /vendedor/productos`, `@Permiso('catalogo.editar')`, controller `src/controllers/vendedores/productos.controller.ts:196`
  - `proponer()` `:260`, `POST /vendedor/productos/propuestas`, `@Permiso('catalogo.proponer')`, controller `src/controllers/vendedores/productos.controller.ts:218`
  - `listarPropuestasPropias()` `:405`, `GET /vendedor/productos/propuestas`, `@Permiso('catalogo.proponer')`, controller `src/controllers/vendedores/productos.controller.ts:83`
  - `listarPropuestasSinAprobar()` `:432`, `GET /vendedor/productos/propuestas/sin-aprobar`, `@Permiso('catalogo.revisar')`, controller `src/controllers/vendedores/productos.controller.ts:100`
  - `listarTodasLasPropuestas()` `:459`, `GET /vendedor/productos/propuestas/todas`, `@Permiso('catalogo.revisar')`, controller `src/controllers/vendedores/productos.controller.ts:118`
  - `revisarPropuesta()` `:575`, `PATCH /vendedor/productos/:id/revision`, `@Permiso('catalogo.revisar')`, controller `src/controllers/vendedores/productos.controller.ts:238`
  - `reenviarPropuesta()` `:696`, `PATCH /vendedor/productos/:id/reenviar`, `@Permiso('catalogo.proponer')`, controller `src/controllers/vendedores/productos.controller.ts:263`
  - `listarRechazosPropuesta()` `:879`, `GET /vendedor/productos/propuestas/:id/rechazos`, `@Permiso('catalogo.proponer')`, controller `src/controllers/vendedores/productos.controller.ts:135`
  - `editar()` `:1152`, `PATCH /vendedor/productos/:id`, `@Permiso('catalogo.editar')`, controller `src/controllers/vendedores/productos.controller.ts:281`
  - `listarPropios()` `:1494`, `GET /vendedor/productos`, `@Permiso('catalogo.ver')`, controller `src/controllers/vendedores/productos.controller.ts:45`
  - `listarPropiosPaginado()` `:1527`, `GET /vendedor/productos/paginado`, `@Permiso('catalogo.ver')`, controller `src/controllers/vendedores/productos.controller.ts:63`
  - `obtenerPropio()` `:1610`, `GET /vendedor/productos/:id`, `@Permiso('catalogo.ver')`, controller `src/controllers/vendedores/productos.controller.ts:178`
  - `obtenerHistorialPropio()` `:1652`, `GET /vendedor/productos/:id/historial`, `@Permiso('catalogo.ver')`, controller `src/controllers/vendedores/productos.controller.ts:158`
- `src/services/vendedores/categorias.service.ts:27`, `CategoriasService`. Las categorias validas y sus caracteristicas, para el formulario.
  - `listarValidas()` `:36`, `GET /categorias`, publica, controller `src/controllers/productos/categorias.controller.ts:21`
  - `listarValidas()` `:36`, `GET /vendedor/categorias`, `@Permiso('catalogo.ver')`, controller `src/controllers/vendedores/categorias.controller.ts:23`
  - `obtenerPorId()` `:71`, `GET /categorias/:id`, publica, controller `src/controllers/productos/categorias.controller.ts:32`
  - `obtenerPorId()` `:71`, `GET /vendedor/categorias/:id`, `@Permiso('catalogo.ver')`, controller `src/controllers/vendedores/categorias.controller.ts:34`
- `src/services/admin/admin-categorias.service.ts:72`, `AdminCategoriasService`. La tienda crea categorias, las renombra en todos sus productos con un `updateMany` y les agrega caracteristicas.
  - `listar()` `:76`, `GET /admin/categorias`, `@Permiso('catalogo.categorias')`, controller `src/controllers/admin/admin-categorias.controller.ts:35`
  - `crear()` `:116`, `POST /admin/categorias`, `@Permiso('catalogo.categorias')`, controller `src/controllers/admin/admin-categorias.controller.ts:51`
  - `renombrar()` `:195`, `PATCH /admin/categorias/:id`, `@Permiso('catalogo.categorias')`, controller `src/controllers/admin/admin-categorias.controller.ts:64`
  - `agregarCaracteristica()` `:266`, `POST /admin/categorias/:id/caracteristicas`, `@Permiso('catalogo.categorias')`, controller `src/controllers/admin/admin-categorias.controller.ts:81`
- `src/services/productos/evento-producto-sync.service.ts:30`, `EventoProductoSyncService`. Pone al dia en MongoDB el precio, el stock y la nota del producto, por la cola `evento_producto`.
  - Corre solo cada 5 s, `@Interval` en la `:57`

**Helpers y guardias**

- `src/helpers/catalogo-respaldo.ts:131`, `productosPorIds()`. Las tarjetas desde PostgreSQL cuando MongoDB no contesta.

**En la pagina**, `frontend/src/routes/producto/[id]/+page.svelte`, `frontend/src/lib/PanelVendedor.svelte`, `frontend/src/lib/CategoriasTienda.svelte`

## Vectores y recomendacion semantica

PostgreSQL con pgvector guarda los vectores, Ollama los calcula en la misma PC. Cada producto tiene dos, el general (nombre, categoria y descripcion) y el de caracteristicas, desde el 8 de noviembre.

**Services**

- `src/services/productos/similares.service.ts:120`, `SimilaresService`. Parecidos a este. Primero su categoria y despues el resto, cada bloque por un puntaje, 0,7 del parecido general, 0,2 del de caracteristicas y 0,1 de la nota (`puntajeDe()`).
  - `obtener()` `:123`, `GET /productos/:id/similares`, publica, controller `src/controllers/productos/similares.controller.ts:20`
- `src/services/productos/vectores-sync.service.ts:148`, `VectoresSyncService`. Calcula los dos vectores de cada producto que cambio, solo si cambio su texto.
  - Corre solo cada 10 s, `@Interval` en la `:159`
- `src/services/vendedores/sugerencias-propuesta.service.ts:110`, `SugerenciasPropuestaService`. Al proponer un producto sugiere la categoria y avisa Puede que ya exista desde 0,85 de parecido.
  - `sugerir()` `:113`, `POST /vendedor/productos/sugerencias`, `@Permiso('catalogo.proponer')`, controller `src/controllers/vendedores/sugerencias-propuesta.controller.ts:30`
- `src/services/resenas/evento-comentario-sync.service.ts:67`, `EventoComentarioSyncService`. Calcula el vector de cada resena o respuesta nueva, por la cola `evento_comentario`.
  - Corre solo cada 10 s, `@Interval` en la `:88`
- `src/services/resenas/valoracion-comentarios.service.ts:41`, `ValoracionComentariosService`. Con el vector ya guardado, el clasificador dice si el texto suena bueno o malo.
  - Corre solo cada 30 s, `@Interval` en la `:54`

**Helpers y guardias**

- `src/helpers/vectores-ollama.ts:33`, `pedirVectores()`. Pide a Ollama el vector de una lista de textos.
- `src/helpers/vectores-pgvector.ts:41`, `buscarCercanos()`. Busca vecinos con el indice HNSW, subiendo `hnsw.ef_search` dentro de su transaccion.
- `src/helpers/vectores-pgvector.ts:74`, `paresParecidos()`. Los pares de resenas casi iguales, calculados dentro de PostgreSQL.
- `src/helpers/valoracion-texto.ts:122`, `valorarTexto()`. La cuenta del clasificador de resenas, con los pesos de `backend/modelos/`.

## Recomendaciones por grafo y por eventos

Neo4j sabe quien compro que, ClickHouse cuenta vistas y compras, y Redis guarda las listas listas para la portada.

**Services**

- `src/services/productos/tambien-compraron.service.ts:56`, `TambienCompraronService`. Quienes lo compraron tambien llevaron, en Neo4j, primero la misma categoria.
  - `obtener()` `:59`, `GET /productos/:id/tambien-compraron`, publica, controller `src/controllers/productos/tambien-compraron.controller.ts:22`
- `src/services/productos/para-ti.service.ts:62`, `ParaTiService`. Para ti, lo que compraron quienes compraron lo mismo, en Neo4j.
  - `obtener()` `:65`, `GET /productos/para-ti`, `@Permiso('productos.para_ti')`, controller `src/controllers/productos/para-ti.controller.ts:28`
- `src/services/productos/tambien-vieron.service.ts:25`, `TambienVieronService`. Quienes vieron esto tambien vieron, leido de Redis.
  - `obtener()` `:35`, `GET /productos/:id/tambien-vieron`, publica, controller `src/controllers/productos/tambien-vieron.controller.ts:21`
- `src/services/productos/tambien-vieron-sync.service.ts:86`, `TambienVieronSyncService`. Lo cuenta en ClickHouse y lo deja en Redis.
  - Corre solo cada 15 min, `@Interval` en la `:94`
- `src/services/productos/mas-vendidos.service.ts:34`, `MasVendidosService`. Lo mas vendido de la portada, leido de Redis.
  - `obtener()` `:57`, `GET /productos/mas-vendidos`, publica, controller `src/controllers/productos/mas-vendidos.controller.ts:25`
- `src/services/productos/mas-vendidos-sync.service.ts:99`, `MasVendidosSyncService`. Cuenta las ventas en ClickHouse y deja la lista en Redis.
  - Corre solo cada 10 min, `@Interval` en la `:117`
- `src/services/productos/mas-vistos.service.ts:24`, `MasVistosService`. Lo mas visto, leido de Redis.
  - `obtener()` `:33`, `GET /productos/mas-vistos`, publica, controller `src/controllers/productos/mas-vistos.controller.ts:22`
- `src/services/productos/mas-vistos-sync.service.ts:39`, `MasVistosSyncService`. Cuenta las vistas en ClickHouse y deja la lista en Redis.
  - Corre solo cada 10 min, `@Interval` en la `:57`
- `src/services/productos/combos.service.ts:22`, `CombosService`. Se compran juntos, de Redis, y si Redis no esta, de ClickHouse en el momento.
  - `obtener()` `:32`, `GET /productos/combos`, publica, controller `src/controllers/productos/combos.controller.ts:17`
- `src/services/productos/combos-sync.service.ts:54`, `CombosSyncService`. Cuenta los pares que se compran juntos en ClickHouse.
  - Corre solo cada 30 min, `@Interval` en la `:74`
- `src/services/productos/vistos-recientemente.service.ts:41`, `VistosRecientementeService`. Viste hace poco, las vistas de esa persona en ClickHouse.
  - `listar()` `:44`, `GET /productos/vistos-recientemente`, publica, controller `src/controllers/productos/vistos-recientemente.controller.ts:22`
- `src/services/productos/ofertas-destacadas.service.ts:37`, `OfertasDestacadasService`. Las ofertas con descuento y las ventas relampago de la portada, de Redis.
  - `obtenerConDescuento()` `:42`, `GET /productos/ofertas/descuento`, publica, controller `src/controllers/productos/ofertas-destacadas.controller.ts:29`
  - `obtenerVentaRelampago()` `:46`, `GET /productos/ofertas/venta-relampago`, publica, controller `src/controllers/productos/ofertas-destacadas.controller.ts:43`
- `src/services/grafo/grafo-sync.service.ts:46`, `GrafoSyncService`. Lleva cada resena a Neo4j por la cola `evento_grafo` y dice si el grafo cuadra con PostgreSQL.
  - Corre solo cada 10 s, `@Interval` en la `:90`
  - `conciliar()` `:350`, `GET /admin/grafo/conciliacion`, `@Permiso('sistema.ver')`, controller `src/controllers/grafo/grafo.controller.ts:30`
- `src/services/grafo/grafo-compras-sync.service.ts:71`, `GrafoComprasSyncService`. Lleva cada compra a Neo4j.
  - Corre solo cada 10 s, `@Interval` en la `:97`
- `src/services/grafo/grafo-categorias-sync.service.ts:32`, `GrafoCategoriasSyncService`. Pone al dia la categoria de cada producto del grafo.
  - Corre solo cada 1 min, `@Interval` en la `:48`

**Helpers y guardias**

- `src/helpers/recomendaciones-respaldo.ts:36`, `conRespaldoDeNeo4j()`. Para ti y tambien compraron desde PostgreSQL cuando Neo4j no contesta.

## Carrito, pago y venta relampago

El carrito de verdad es el pedido `pendiente` de PostgreSQL y Redis guarda la copia rapida. Pagar es una sola transaccion de PostgreSQL. La venta relampago aparta unidades con un script Lua de Redis.

**Services**

- `src/services/carrito/carrito.service.ts:157`, `CarritoService`. Agregar, cambiar, quitar, vaciar y pagar (`comprarCarrito()`, con `BEGIN`, `comprar_pedido()` y `COMMIT`).
  - `verCarrito()` `:202`, `GET /carrito`, `@Permiso('carrito.usar')`, controller `src/controllers/carrito/carrito.controller.ts:47`
  - `definirCantidad()` `:242`, `PUT /carrito/lineas/:idOferta`, `@Permiso('carrito.usar')`, controller `src/controllers/carrito/carrito.controller.ts:60`
  - `quitarLinea()` `:428`, `DELETE /carrito/lineas/:idOferta`, `@Permiso('carrito.usar')`, controller `src/controllers/carrito/carrito.controller.ts:79`
  - `vaciar()` `:484`, `DELETE /carrito`, `@Permiso('carrito.usar')`, controller `src/controllers/carrito/carrito.controller.ts:96`
  - `sincronizar()` `:547`, `POST /carrito/sincronizar`, `@Permiso('carrito.usar')`, controller `src/controllers/carrito/carrito.controller.ts:110`
  - `comprarCarrito()` `:634`, `POST /carrito/comprar`, `@Permiso('carrito.comprar')`, controller `src/controllers/carrito/carrito.controller.ts:124`
- `src/services/carrito/carrito-redis.service.ts:85`, `CarritoRedisService`. La copia del carrito en Redis y el candado del doble clic (`SET NX EX 30`).
- `src/services/carrito/carrito-postgres.service.ts:135`, `CarritoPostgresService`. El carrito de verdad, el pedido `pendiente`, con su version para no pisar cambios.
- `src/services/carrito/carrito-barrido.service.ts:26`, `CarritoBarridoService`. Borra los carritos sin tocar en 24 horas.
  - Corre solo cada 10 min, `@Interval` en la `:37`
- `src/services/inventario-limitado/inventario-limitado.service.ts:169`, `InventarioLimitadoService`. Abre, reserva y cierra la venta relampago con el script Lua.
- `src/services/inventario-limitado/reservas-venta-relampago-sync.service.ts:30`, `ReservasVentaRelampagoSyncService`. Rehace el contador de Redis desde las reservas de PostgreSQL.
  - Corre solo cada 10 s, `@Interval` en la `:58`
- `src/services/vendedores/ventas-limitadas.service.ts:43`, `VentasLimitadasService`. El vendedor abre o cierra su venta relampago.
  - Corre solo cada 1 min, `@Interval` en la `:220`
  - `abrir()` `:83`, `POST /vendedor/ofertas/:id/venta-limitada`, `@Permiso('ofertas.venta_relampago')`, controller `src/controllers/vendedores/ventas-limitadas.controller.ts:42`
  - `cerrar()` `:133`, `DELETE /vendedor/ofertas/:id/venta-limitada`, `@Permiso('ofertas.venta_relampago')`, controller `src/controllers/vendedores/ventas-limitadas.controller.ts:62`

**Helpers y guardias**

- `src/helpers/precio-descuento.ts:20`, `expresionPrecioFinal()`. El precio final con el descuento, `ROUND(precio * (1 - descuento / 100), 2)`, el mismo en todas las consultas.

**En la pagina**, `frontend/src/lib/CarritoRedis.svelte`, `frontend/src/lib/Checkout.svelte`

## Pedidos y direcciones

PostgreSQL. Cancelar devuelve las unidades y reembolsa el pago en la misma transaccion, y queda anotado quien lo hizo.

**Services**

- `src/services/compradores/pedidos.service.ts:45`, `PedidosCompradorService`. Mis pedidos y cancelar. La tienda cancela cualquiera o lo marca enviado o entregado (migracion 051).
  - `listar()` `:66`, `GET /comprador/pedidos`, `@Permiso('pedidos.ver')`, controller `src/controllers/compradores/pedidos.controller.ts:37`
  - `obtener()` `:122`, `GET /comprador/pedidos/:id`, `@Permiso('pedidos.ver')`, controller `src/controllers/compradores/pedidos.controller.ts:62`
  - `metodosPago()` `:234`, `GET /comprador/pedidos/metodos-pago`, `@Permiso('pedidos.ver')`, controller `src/controllers/compradores/pedidos.controller.ts:51`
  - `cancelarPedido()` `:251`, `POST /comprador/pedidos/:id/cancelar`, `@Permiso('pedidos.cancelar')`, controller `src/controllers/compradores/pedidos.controller.ts:80`
  - `cancelarComoTienda()` `:284`, `POST /admin/pedidos/:id/cancelar`, `@Permiso('pedidos.administrar')`, controller `src/controllers/admin/admin-pedidos.controller.ts:34`
  - `marcarEnvio()` `:315`, `POST /admin/pedidos/:id/enviado`, `@Permiso('pedidos.administrar')`, controller `src/controllers/admin/admin-pedidos.controller.ts:55`
  - `marcarEnvio()` `:315`, `POST /admin/pedidos/:id/entregado`, `@Permiso('pedidos.administrar')`, controller `src/controllers/admin/admin-pedidos.controller.ts:73`
- `src/services/direccion-usuario.service.ts:35`, `DireccionUsuarioService`. Las direcciones. Cada cambio guarda una version y el pedido apunta a la de ese dia.
  - `crear()` `:43`, `POST /direccion-usuario`, `@Permiso('direcciones.administrar')`, controller `src/controllers/direccion-usuario.controller.ts:84`
  - `actualizar()` `:106`, `PATCH /direccion-usuario/:id`, `@Permiso('direcciones.administrar')`, controller `src/controllers/direccion-usuario.controller.ts:101`
  - `listar()` `:196`, `GET /direccion-usuario`, `@Permiso('direcciones.administrar')`, controller `src/controllers/direccion-usuario.controller.ts:37`
  - `obtenerConHistorial()` `:218`, `GET /direccion-usuario/:id`, `@Permiso('direcciones.administrar')`, controller `src/controllers/direccion-usuario.controller.ts:67`
  - `obtenerHistorial()` `:268`, `GET /direccion-usuario/historial`, `@Permiso('direcciones.administrar')`, controller `src/controllers/direccion-usuario.controller.ts:50`

**En la pagina**, `frontend/src/lib/MisPedidos.svelte`, `frontend/src/lib/Direcciones.svelte`

## Ofertas, descuentos, reglas y avisos

Una oferta es quien vende un producto, a que precio y cuantas tiene. Vive en PostgreSQL y se busca en Elasticsearch. Los avisame usan el percolator de Elasticsearch.

**Services**

- `src/services/vendedores/ofertas.service.ts:148`, `OfertasVendedorService`. Publicar, editar, aprobar, descuentos, y lo que la tienda hace con las ofertas de todos (`administrar()`).
  - `crear()` `:285`, `POST /vendedor/ofertas`, `@Permiso('ofertas.publicar')`, controller `src/controllers/vendedores/ofertas.controller.ts:176`
  - `editar()` `:466`, `PATCH /compartidas/ofertas/:id`, `@Permiso('ofertas.usar_compartidas')`, controller `src/controllers/compartidas/ofertas-compartidas.controller.ts:94`
  - `editar()` `:466`, `PATCH /vendedor/ofertas/:id`, `@Permiso('ofertas.editar')`, controller `src/controllers/vendedores/ofertas.controller.ts:263`
  - `aplicarDescuento()` `:627`, `POST /compartidas/ofertas/:id/descuento`, `@Permiso('ofertas.usar_compartidas')`, controller `src/controllers/compartidas/ofertas-compartidas.controller.ts:136`
  - `aplicarDescuento()` `:627`, `POST /vendedor/ofertas/:id/descuento`, `@Permiso('ofertas.descuento')`, controller `src/controllers/vendedores/ofertas.controller.ts:222`
  - `quitarDescuento()` `:717`, `DELETE /compartidas/ofertas/:id/descuento`, `@Permiso('ofertas.usar_compartidas')`, controller `src/controllers/compartidas/ofertas-compartidas.controller.ts:169`
  - `quitarDescuento()` `:717`, `DELETE /vendedor/ofertas/:id/descuento`, `@Permiso('ofertas.descuento')`, controller `src/controllers/vendedores/ofertas.controller.ts:244`
  - `listarDeProducto()` `:794`, `GET /admin/ofertas`, `@Permiso('ofertas.administrar')`, controller `src/controllers/admin/admin-ofertas.controller.ts:40`
  - `administrar()` `:840`, `PATCH /admin/ofertas/:id`, `@Permiso('ofertas.administrar')`, controller `src/controllers/admin/admin-ofertas.controller.ts:51`
  - `revisar()` `:942`, `PATCH /vendedor/ofertas/:id/revision`, `@Permiso('ofertas.revisar')`, controller `src/controllers/vendedores/ofertas.controller.ts:197`
  - `listarPropias()` `:1119`, `GET /vendedor/ofertas`, `@Permiso('ofertas.ver')`, controller `src/controllers/vendedores/ofertas.controller.ts:54`
  - `listarPropiasPaginado()` `:1154`, `GET /vendedor/ofertas/paginado`, `@Permiso('ofertas.ver')`, controller `src/controllers/vendedores/ofertas.controller.ts:74`
  - `obtenerConMisOfertas()` `:1263`, `GET /vendedor/ofertas/producto/:idProducto`, `@Permiso('ofertas.ver')`, controller `src/controllers/vendedores/ofertas.controller.ts:157`
  - `listarRechazos()` `:1366`, `GET /vendedor/ofertas/:id/rechazos`, `@Permiso('ofertas.ver')`, controller `src/controllers/vendedores/ofertas.controller.ts:134`
  - `listarPendientes()` `:1411`, `GET /vendedor/ofertas/pendientes`, `@Permiso('ofertas.revisar')`, controller `src/controllers/vendedores/ofertas.controller.ts:96`
  - `listarPendientesPaginado()` `:1456`, `GET /vendedor/ofertas/pendientes/paginado`, `@Permiso('ofertas.revisar')`, controller `src/controllers/vendedores/ofertas.controller.ts:114`
- `src/services/reglas-descuento-automatico/reglas-descuento-automatico.service.ts:50`, `ReglasDescuentoAutomaticoService`. Las reglas que ponen un descuento solas segun las ventas.
  - `crear()` `:94`, `POST /vendedor/reglas-descuento`, `@Permiso('reglas.administrar')`, controller `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts:44`
  - `listarPropias()` `:163`, `GET /vendedor/reglas-descuento`, `@Permiso('reglas.ver')`, controller `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts:65`
  - `listarPropiasPaginado()` `:192`, `GET /vendedor/reglas-descuento/paginado`, `@Permiso('reglas.ver')`, controller `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts:79`
  - `editar()` `:259`, `PATCH /vendedor/reglas-descuento/:id`, `@Permiso('reglas.administrar')`, controller `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts:98`
  - `eliminar()` `:408`, `DELETE /vendedor/reglas-descuento/:id`, `@Permiso('reglas.administrar')`, controller `src/controllers/reglas-descuento-automatico/reglas-descuento-automatico.controller.ts:119`
- `src/services/reglas-descuento-automatico/disparador-reglas-automatico.service.ts:71`, `DisparadorReglasAutomaticoService`. Mira las ventas en ClickHouse y aplica las reglas.
  - Corre solo cada 1 min, `@Interval` en la `:85`
- `src/services/reglas-descuento-periodo/reglas-descuento-periodo.service.ts:57`, `ReglasDescuentoPeriodoService`. Los descuentos por fecha.
  - `crear()` `:149`, `POST /vendedor/reglas-descuento-periodos`, `@Permiso('reglas.administrar')`, controller `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts:45`
  - `listarPropias()` `:243`, `GET /vendedor/reglas-descuento-periodos`, `@Permiso('reglas.ver')`, controller `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts:66`
  - `listarPropiasPaginado()` `:270`, `GET /vendedor/reglas-descuento-periodos/paginado`, `@Permiso('reglas.ver')`, controller `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts:83`
  - `editar()` `:349`, `PATCH /vendedor/reglas-descuento-periodos/:id`, `@Permiso('reglas.administrar')`, controller `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts:106`
  - `eliminar()` `:540`, `DELETE /vendedor/reglas-descuento-periodos/:id`, `@Permiso('reglas.administrar')`, controller `src/controllers/reglas-descuento-periodo/reglas-descuento-periodo.controller.ts:130`
- `src/services/reglas-descuento-periodo/disparador-reglas-periodo.service.ts:65`, `DisparadorReglasPeriodoService`. Pone el descuento al empezar la fecha y lo quita al terminar.
  - Corre solo cada 15 min, `@Interval` en la `:79`
- `src/services/vendedores/evento-oferta-sync.service.ts:68`, `EventoOfertaSyncService`. Lleva las ofertas a Elasticsearch por la cola `evento_oferta` y prueba cada cambio contra los avisame.
  - Corre solo cada 5 s, `@Interval` en la `:93`
- `src/services/vendedores/registro-ofertas-redis.service.ts:89`, `RegistroOfertasRedisService`. Las tarjetas de las ofertas con descuento y de venta relampago en Redis.
- `src/services/vendedores/registro-ofertas-sync.service.ts:37`, `RegistroOfertasSyncService`. Corrige esas tarjetas de Redis si alguna se perdio.
  - Corre solo cada 10 min, `@Interval` en la `:58`
- `src/services/compradores/seguimientos-oferta.service.ts:117`, `SeguimientosOfertaService`. Avisame si baja de precio, y los avisos que llegan.
  - `crear()` `:120`, `POST /comprador/seguimientos`, `@Permiso('avisos.usar')`, controller `src/controllers/compradores/seguimientos-oferta.controller.ts:48`
  - `listar()` `:182`, `GET /comprador/seguimientos`, `@Permiso('avisos.usar')`, controller `src/controllers/compradores/seguimientos-oferta.controller.ts:65`
  - `borrar()` `:195`, `DELETE /comprador/seguimientos/:id`, `@Permiso('avisos.usar')`, controller `src/controllers/compradores/seguimientos-oferta.controller.ts:118`
  - `listarAvisos()` `:238`, `GET /comprador/seguimientos/avisos`, `@Permiso('avisos.usar')`, controller `src/controllers/compradores/seguimientos-oferta.controller.ts:82`
  - `marcarAviso()` `:289`, `PATCH /comprador/seguimientos/avisos/:id`, `@Permiso('avisos.usar')`, controller `src/controllers/compradores/seguimientos-oferta.controller.ts:99`
- `src/services/compradores/percolar-seguimientos.service.ts:31`, `PercolarSeguimientosService`. Prueba una oferta contra todos los avisame guardados en el percolator.

**En la pagina**, `frontend/src/lib/OfertasVendedor.svelte`, `frontend/src/lib/ReglasDescuento.svelte`, `frontend/src/lib/ReglasPeriodo.svelte`

## Resenas

PostgreSQL. Solo resena quien compro y pago. La resena oculta por la tienda sigue en la base y en Neo4j como evidencia.

**Services**

- `src/services/resenas/resenas.service.ts:91`, `ResenasService`. Listar, escribir, responder, votar y ocultar resenas (`moderar()`).
  - `listarDeProducto()` `:112`, `GET /productos/:id/resenas`, publica, controller `src/controllers/resenas/resenas.controller.ts:53`
  - `comproProducto()` `:210`, `GET /productos/:id/comprado`, `@Permiso('pedidos.ver')`, controller `src/controllers/resenas/resenas.controller.ts:70`
  - `resenoProducto()` `:245`, `GET /productos/:id/resenado`, `@Permiso('resenas.escribir')`, controller `src/controllers/resenas/resenas.controller.ts:95`
  - `crear()` `:288`, `POST /resenas`, `@Permiso('resenas.escribir')`, controller `src/controllers/resenas/resenas.controller.ts:119`
  - `responder()` `:380`, `POST /resenas/:id/respuestas`, `@Permiso('resenas.escribir')`, controller `src/controllers/resenas/resenas.controller.ts:138`
  - `votar()` `:425`, `PUT /comentarios/:id/voto`, `@Permiso('resenas.votar')`, controller `src/controllers/resenas/resenas.controller.ts:159`
  - `quitarVoto()` `:460`, `DELETE /comentarios/:id/voto`, `@Permiso('resenas.votar')`, controller `src/controllers/resenas/resenas.controller.ts:180`
  - `moderar()` `:735`, `PATCH /admin/resenas/:id`, `@Permiso('resenas.moderar')`, controller `src/controllers/admin/admin-resenas.controller.ts:31`

**En la pagina**, `frontend/src/lib/Resenas.svelte`

## Cuenta, sesion y control de acceso

Dos guardias en cada ruta. `SesionGuard` dice quien eres o 401, y `PermisoGuard` pregunta a `rol_permiso` si tu rol puede o 403. Las ofertas compartidas tienen una tercera, por persona.

**Services**

- `src/services/usuario.service.ts:64`, `UsuarioService`. Registrarse, entrar y el rol de hoy de cada sesion (`estadoDeSesion()`).
  - `registrar()` `:74`, `POST /usuario/registro`, publica, controller `src/controllers/usuario.controller.ts:115`
  - `iniciarSesion()` `:120`, `POST /usuario/login`, publica, controller `src/controllers/usuario.controller.ts:154`
  - `obtenerPorId()` `:186`, `GET /usuario/yo`, `@Permiso('cuenta.ver')`, controller `src/controllers/usuario.controller.ts:302`
  - `verificarExistencia()` `:354`, `GET /usuario/registros-existentes`, publica, controller `src/controllers/usuario.controller.ts:135`
- `src/services/perfil.service.ts:25`, `PerfilService`. Mi cuenta, datos y contrasena.
  - `obtener()` `:36`, `GET /perfil`, `@Permiso('cuenta.ver')`, controller `src/controllers/perfil.controller.ts:46`
  - `actualizar()` `:71`, `PATCH /perfil`, `@Permiso('cuenta.editar')`, controller `src/controllers/perfil.controller.ts:58`
  - `cambiarContrasena()` `:132`, `PATCH /perfil/contrasena`, `@Permiso('cuenta.editar')`, controller `src/controllers/perfil.controller.ts:76`
- `src/services/log.service.ts:33`, `LogService`. Anota cada entrada en MongoDB, para el fraude de login.
- `src/services/acl/permisos.service.ts:58`, `PermisosService`. Los permisos por rol. `tiene()` le pregunta a la base en cada peticion del guard, y no deja quitar los protegidos. Cada minuto guarda una copia de la matriz, por si PostgreSQL no contesta.
  - Corre solo cada 1 min, `@Interval` en la `:70`
  - `matriz()` `:213`, `GET /admin/permisos`, `@Permiso('permisos.ver')`, controller `src/controllers/admin/admin-permisos.controller.ts:37`
  - `registro()` `:271`, `GET /admin/permisos/registro`, `@Permiso('permisos.ver')`, controller `src/controllers/admin/admin-permisos.controller.ts:47`
  - `otorgar()` `:309`, `POST /admin/permisos/:idRol/:idPermiso`, `@Permiso('permisos.administrar')`, controller `src/controllers/admin/admin-permisos.controller.ts:61`
  - `revocar()` `:341`, `DELETE /admin/permisos/:idRol/:idPermiso`, `@Permiso('permisos.administrar')`, controller `src/controllers/admin/admin-permisos.controller.ts:86`
- `src/services/acl/acl-ofertas.service.ts:70`, `AclOfertasService`. El ACL de cada oferta, quien puede verla, editarla o ponerle descuento.
  - `listarCompartidas()` `:184`, `GET /compartidas/ofertas`, `@Permiso('ofertas.usar_compartidas')`, controller `src/controllers/compartidas/ofertas-compartidas.controller.ts:61`
  - `obtenerCompartida()` `:197`, `GET /compartidas/ofertas/:id`, `@Permiso('ofertas.usar_compartidas')`, controller `src/controllers/compartidas/ofertas-compartidas.controller.ts:74`
  - `listarPermisos()` `:223`, `GET /vendedor/ofertas/:id/permisos`, `@Permiso('ofertas.compartir')`, controller `src/controllers/vendedores/permisos-oferta.controller.ts:39`
  - `otorgar()` `:244`, `POST /vendedor/ofertas/:id/permisos`, `@Permiso('ofertas.compartir')`, controller `src/controllers/vendedores/permisos-oferta.controller.ts:57`
  - `revocar()` `:324`, `DELETE /vendedor/ofertas/:id/permisos/:idPermiso`, `@Permiso('ofertas.compartir')`, controller `src/controllers/vendedores/permisos-oferta.controller.ts:77`

**Helpers y guardias**

- `src/guards/sesion.guard.ts:71`, `SesionGuard`. Lee la cookie, la verifica y lee el rol de la base en cada peticion.
- `src/guards/permiso.guard.ts:41`, `PermisoGuard`. Lee el `@Permiso` de la ruta y lo pregunta. Una ruta sin `@Permiso` tambien se niega.
- `src/guards/permiso-oferta.guard.ts:42`, `PermisoOfertaGuard`. Sin entrada para esa oferta 404, con ver pero sin editar 403.
- `src/decorators/permiso.decorator.ts:18`, `@Permiso()`. La etiqueta de cada ruta con el permiso que pide.
- `src/helpers/token.ts:48`, `firmarToken()`. Firma el token de 2 horas, HS256.
- `src/helpers/token.ts:63`, `verificarToken()`. Verifica la firma y que no haya vencido.
- `src/helpers/contrasena.ts:31`, `compararContrasena()`. Compara la clave con la guardada con scrypt.

**En la pagina**, `frontend/src/lib/sesion.ts`, `frontend/src/lib/PanelPermisos.svelte`, `frontend/src/lib/CompartirOferta.svelte`

## Panel del admin, dashboard, reportes, cuentas y tendencias

El dashboard y los reportes leen PostgreSQL, las tendencias leen ClickHouse. Cada pestana pide su permiso.

**Services**

- `src/services/dashboards/dashboard-general.service.ts:73`, `DashboardGeneralService`. Las cifras del periodo contra el anterior.
  - `resumen()` `:81`, `GET /admin/dashboard/resumen`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:67`
  - `ventas()` `:139`, `GET /admin/dashboard/ventas`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:75`
  - `embudo()` `:185`, `GET /admin/dashboard/embudo`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:83`
  - `categorias()` `:244`, `GET /admin/dashboard/categorias`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:91`
  - `pagos()` `:264`, `GET /admin/dashboard/pagos`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:99`
  - `mapa()` `:284`, `GET /admin/dashboard/mapa`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:107`
  - `vendedores()` `:300`, `GET /admin/dashboard/vendedores`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:115`
  - `productos()` `:321`, `GET /admin/dashboard/productos`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:123`
  - `departamentos()` `:340`, `GET /admin/dashboard/departamentos`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:131`
  - `busquedas()` `:359`, `GET /admin/dashboard/busquedas`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:139`
  - `cancelaciones()` `:432`, `GET /admin/dashboard/cancelaciones`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:147`
  - `pedidos()` `:504`, `GET /admin/dashboard/pedidos`, `@Permiso('dashboard.ver')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:156`
- `src/services/dashboards/dashboard-exportar.service.ts:119`, `DashboardExportarService`. Exportar el dashboard a Excel o PDF.
  - `excel()` `:122`, `GET /admin/dashboard/exportar/excel`, `@Permiso('dashboard.exportar')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:175`
  - `pdf()` `:428`, `GET /admin/dashboard/exportar/pdf`, `@Permiso('dashboard.exportar')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:200`
- `src/services/dashboards/dashboard-correo.service.ts:24`, `DashboardCorreoService`. Mandar el dashboard por correo.
  - `limpiarCorreos()` `:28`, `POST /admin/dashboard/exportar/correo`, `@Permiso('dashboard.exportar')`, controller `src/controllers/dashboards/dashboard-general.controller.ts:225`
- `src/services/admin/admin-reportes.service.ts:37`, `AdminReportesService`. Pedidos, pagos, como pagan y pedidos sin pagar.
  - `reservaciones()` `:46`, `GET /admin/reportes/reservaciones`, `@Permiso('reportes.ver')`, controller `src/controllers/admin/admin-reportes.controller.ts:29`
  - `ventas()` `:109`, `GET /admin/reportes/ventas`, `@Permiso('reportes.ver')`, controller `src/controllers/admin/admin-reportes.controller.ts:40`
- `src/services/admin/admin-usuarios.service.ts:25`, `AdminUsuariosService`. Cambiar el rol o bloquear una cuenta, nunca la propia.
  - `listar()` `:35`, `GET /admin/usuarios`, `@Permiso('usuarios.ver')`, controller `src/controllers/admin/admin-usuarios.controller.ts:27`
  - `actualizar()` `:70`, `PATCH /admin/usuarios/:id`, `@Permiso('usuarios.editar')`, controller `src/controllers/admin/admin-usuarios.controller.ts:43`
- `src/services/admin/admin-catalogos.service.ts:15`, `AdminCatalogosService`. Los roles y estados para los menus.
  - `listarRoles()` `:18`, `GET /admin/roles`, `@Permiso('usuarios.ver')`, controller `src/controllers/admin/admin-catalogos.controller.ts:22`
  - `listarEstados()` `:29`, `GET /admin/estados`, `@Permiso('usuarios.ver')`, controller `src/controllers/admin/admin-catalogos.controller.ts:33`
- `src/services/admin/admin-tendencias.service.ts:60`, `AdminTendenciasService`. Lo mas visto, llevado al carrito, vendido, devuelto y buscado, contando personas distintas.
  - `rankingVistas()` `:63`, `GET /admin/eventos/vista`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:48`
  - `rankingCarrito()` `:73`, `GET /admin/eventos/carrito`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:59`
  - `rankingCompras()` `:83`, `GET /admin/eventos/compra`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:70`
  - `rankingDevoluciones()` `:89`, `GET /admin/eventos/devolucion`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:81`
  - `rankingBusquedas()` `:99`, `GET /admin/eventos/busqueda`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:96`
  - `rankingClicsBusqueda()` `:105`, `GET /admin/eventos/busqueda-clic`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:124`
  - `rankingCategoriasBuscadas()` `:120`, `GET /admin/eventos/categorias-mas-buscadas`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:139`
  - `rankingPreciosBuscados()` `:126`, `GET /admin/eventos/precios-mas-buscados`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:154`
  - `rankingCalificacionesBuscadas()` `:132`, `GET /admin/eventos/calificaciones-mas-buscadas`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:169`
- `src/services/admin/admin-tendencias-avanzadas.service.ts:81`, `AdminTendenciasAvanzadasService`. Productos en ascenso, el embudo y las busquedas sin respuesta.
  - `enAscenso()` `:93`, `GET /admin/eventos/tendencias`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias-avanzadas.controller.ts:34`
  - `embudo()` `:155`, `GET /admin/eventos/embudo`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias-avanzadas.controller.ts:49`
  - `busquedasSinRespuesta()` `:239`, `GET /admin/eventos/busquedas-sin-respuesta`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias-avanzadas.controller.ts:61`
- `src/services/admin/admin-busquedas-sin-resultados.service.ts:51`, `AdminBusquedasSinResultadosService`. Lo que la gente busca y no encuentra.
  - `obtener()` `:54`, `GET /admin/eventos/busquedas-sin-resultados`, `@Permiso('tendencias.ver')`, controller `src/controllers/admin/admin-tendencias.controller.ts:109`
- `src/services/eventos/eventos.service.ts:17`, `EventosService`. Guarda cada vista, carrito y clic como un evento en ClickHouse.
  - `registrarVista()` `:21`, `POST /eventos/vista`, publica, controller `src/controllers/eventos.controller.ts:56`
  - `registrarCarrito()` `:54`, `POST /eventos/carrito`, `@Permiso('carrito.usar')`, controller `src/controllers/eventos.controller.ts:93`
  - `registrarClicBusqueda()` `:238`, `POST /eventos/busqueda-clic`, publica, controller `src/controllers/eventos.controller.ts:133`

**En la pagina**, `frontend/src/lib/PanelDashboard.svelte`, `frontend/src/lib/PanelReportes.svelte`, `frontend/src/lib/PanelAdmin.svelte`, `frontend/src/lib/PanelTendencias.svelte`

## Fraude

Treinta tipos repartidos en cinco bases. Cada hallazgo es una senal en `senal_fraude` de PostgreSQL, y cada 15 minutos las que comparten cuentas se juntan en un caso.

**Services**

- `src/services/fraude/anillos-detector.service.ts:26`, `AnillosDetectorService`. Los anillos de resenas en Neo4j, tres o cuatro cuentas en circulo.
  - Corre solo cada 15 min, `@Interval` en la `:39`
- `src/services/fraude/patrones-fraude-detector.service.ts:40`, `PatronesFraudeDetectorService`. Los patrones sin circulo en Neo4j, satelites, persistente, coordinados y reputacion en minutos.
  - Corre solo cada 15 min, `@Interval` en la `:65`
- `src/services/fraude/fraude-anillos-persistidos.service.ts:79`, `FraudeAnillosPersistidosService`. La pestana Resenas en anillo, con su detalle del grafo.
  - `listarPaginado()` `:88`, `GET /admin/fraude/alertas-resenas`, `@Permiso('fraude.ver')`, controller `src/controllers/admin/admin-fraude-anillos.controller.ts:47`
  - `marcarAnillo()` `:201`, `PATCH /admin/fraude/alertas-resenas/:id`, `@Permiso('fraude.resolver')`, controller `src/controllers/admin/admin-fraude-anillos.controller.ts:60`
  - `obtenerDetalleGrafo()` `:301`, `GET /admin/fraude/alertas-resenas/:id/detalle-grafo`, `@Permiso('fraude.ver')`, controller `src/controllers/admin/admin-fraude-anillos.controller.ts:74`
- `src/services/fraude/resenas-repetidas-detector.service.ts:63`, `ResenasRepetidasDetectorService`. Una cuenta que escribe la misma resena una y otra vez, por el texto.
  - Corre solo cada 15 min, `@Interval` en la `:94`
- `src/services/fraude/resenas-parecidas-detector.service.ts:98`, `ResenasParecidasDetectorService`. Resenas copiadas entre cuentas sobre un vendedor o un producto.
  - Corre solo cada 15 min, `@Interval` en la `:132`
- `src/services/fraude/anillo-de-texto-detector.service.ts:67`, `AnilloDeTextoDetectorService`. Tres cuentas o mas con casi la misma resena a un vendedor.
  - Corre solo cada 15 min, `@Interval` en la `:96`
- `src/services/fraude/notas-incoherentes-detector.service.ts:123`, `NotasIncoherentesDetectorService`. Estrellas que contradicen lo escrito.
  - Corre solo cada 15 min, `@Interval` en la `:145`
- `src/services/fraude/resenas-canceladas-detector.service.ts:67`, `ResenasCanceladasDetectorService`. Resenas de compras que el mismo comprador cancelo.
  - Corre solo cada 15 min, `@Interval` en la `:86`
- `src/services/fraude/chequeo-texto-inmediato.service.ts:41`, `ChequeoTextoInmediatoService`. Los detectores de texto al instante, cuando alguien escribe una resena.
- `src/services/fraude/hallazgos-evento-fraude-detector.service.ts:96`, `HallazgosEventoFraudeDetectorService`. Compras y navegacion en ClickHouse, vistas infladas, compras en rafaga y devoluciones seriales.
  - Corre solo cada 1 dia, `@Interval` en la `:106`
- `src/services/fraude/hallazgos-evento-fraude-persistidos.service.ts:81`, `HallazgosEventoFraudePersistidosService`. La pestana Compras y navegacion.
  - `listarPaginado()` `:90`, `GET /admin/fraude/alertas-eventos`, `@Permiso('fraude.ver')`, controller `src/controllers/admin/admin-fraude-eventos.controller.ts:45`
  - `marcarHallazgo()` `:203`, `PATCH /admin/fraude/alertas-eventos/:id`, `@Permiso('fraude.resolver')`, controller `src/controllers/admin/admin-fraude-eventos.controller.ts:60`
- `src/services/fraude/hallazgo-fraude-adaptador.service.ts:97`, `HallazgoFraudeAdaptadorService`. Decide que hallazgos entran a los casos.
- `src/services/fraude/agrupador-fraude-worker.service.ts:41`, `AgrupadorFraudeWorkerService`. Junta las senales que comparten cuentas en casos.
  - Corre solo cada 15 min, `@Interval` en la `:54`
- `src/services/fraude/agrupador-fraude.service.ts:61`, `AgrupadorFraudeService`. La cuenta de como se agrupan.
- `src/services/fraude/persistencia-caso-fraude.service.ts:44`, `PersistenciaCasoFraudeService`. Guarda los casos y su evidencia.
- `src/services/fraude/puntaje-fraude.service.ts:65`, `PuntajeFraudeService`. Cuanto suma cada senal al puntaje de un caso.
- `src/services/fraude/reglas-casi-confirmado.service.ts:27`, `ReglasCasiConfirmadoService`. Las reglas que dicen que un caso casi seguro es fraude.
- `src/services/fraude/casos-fraude.service.ts:84`, `CasosFraudeService`. La pestana Casos, y resolver un caso.
  - `listarPaginado()` `:87`, `GET /admin/fraude/casos`, `@Permiso('fraude.ver')`, controller `src/controllers/admin/admin-casos-fraude.controller.ts:36`
  - `obtenerDetalle()` `:179`, `GET /admin/fraude/casos/:id`, `@Permiso('fraude.ver')`, controller `src/controllers/admin/admin-casos-fraude.controller.ts:47`
  - `actualizar()` `:226`, `PATCH /admin/fraude/casos/:id`, `@Permiso('fraude.resolver')`, controller `src/controllers/admin/admin-casos-fraude.controller.ts:59`
- `src/services/fraude-login/fraude-login.service.ts:135`, `FraudeLoginService`. Los contadores de Redis al entrar, fuerza bruta, varias cuentas desde una IP y una cuenta desde muchas IPs.
  - `listarAlertasPaginado()` `:346`, `GET /admin/fraude/alertas-login`, `@Permiso('fraude.ver')`, controller `src/controllers/fraude/fraude.controller.ts:29`
  - `listarAlertasPaginadoUsuario()` `:450`, `GET /perfil/alertas-fraude`, `@Permiso('cuenta.ver')`, controller `src/controllers/perfil.controller.ts:93`
  - `marcarLeida()` `:519`, `PATCH /perfil/alertas-fraude/:id`, `@Permiso('cuenta.editar')`, controller `src/controllers/perfil.controller.ts:111`
- `src/services/fraude-login/fraude-login-retrospectivo.service.ts:60`, `FraudeLoginRetrospectivoService`. Lo mismo en ventanas de 24 horas, en Elasticsearch, y la granja de registros.
  - Corre solo cada 15 min, `@Interval` en la `:90`
- `src/services/fraude-login/toma-cuenta.service.ts:23`, `TomaCuentaService`. Una cuenta que entra desde una IP y un navegador nuevos.
- `src/services/fraude-login/viaje-imposible.service.ts:49`, `ViajeImposibleService`. La misma cuenta en dos lugares demasiado lejos para el tiempo que paso.
- `src/services/fraude-login/fraude-login-exploracion.service.ts:76`, `FraudeLoginExploracionService`. Todo lo que hizo una cuenta, y marcar una alerta revisada.
  - `listarEventosPaginado()` `:83`, `GET /admin/fraude/eventos-login`, `@Permiso('fraude.ver')`, controller `src/controllers/admin/admin-fraude-login.controller.ts:45`
  - `marcarAlerta()` `:228`, `PATCH /admin/fraude/alertas-login/:id`, `@Permiso('fraude.resolver')`, controller `src/controllers/admin/admin-fraude-login.controller.ts:61`
- `src/services/eventos-autenticacion/eventos-autenticacion-sync.service.ts:43`, `EventosAutenticacionSyncService`. Lleva el registro de entradas de MongoDB a Elasticsearch.
  - Corre solo cada 5 s, `@Interval` en la `:54`

**Helpers y guardias**

- `src/helpers/registrar-alerta-fraude.ts:46`, `registrarAlertaFraude()`. Guarda una senal de login, o suma una deteccion si ya existia.

**En la pagina**, `frontend/src/lib/PanelFraude.svelte`, `docs/FRAUDE-CATALOGO.md`

## Las bases, su estado y su respaldo

Cada base tiene un cortacircuitos. Si falla, se deja de preguntarle 15 segundos y se usa su respaldo. Sin PostgreSQL se mira pero no se paga.

**Services**

- `src/services/base-datos.service.ts:10`, `BaseDatosService`. Si PostgreSQL contesta.
  - `verificarConexion()` `:20`, `GET /db`, publica, controller `src/controllers/base-datos.controller.ts:25`
- `src/services/base-datos-documental.service.ts:11`, `BaseDatosDocumentalService`. Si MongoDB contesta.
  - `verificarConexion()` `:20`, `GET /documental`, publica, controller `src/controllers/base-datos-documental.controller.ts:16`
- `src/services/base-datos-clave-valor.service.ts:14`, `BaseDatosClaveValorService`. Si Redis contesta.
  - `verificarConexion()` `:24`, `GET /clave-valor`, publica, controller `src/controllers/base-datos-clave-valor.controller.ts:19`
- `src/services/base-datos-grafo.service.ts:15`, `BaseDatosGrafoService`. Si Neo4j contesta.
  - `verificarConexion()` `:23`, `GET /grafo`, publica, controller `src/controllers/base-datos-grafo.controller.ts:17`
- `src/services/base-datos-buscador.service.ts:19`, `BaseDatosBuscadorService`. Si Elasticsearch contesta.
  - `verificarConexion()` `:32`, `GET /buscador`, publica, controller `src/controllers/base-datos-buscador.controller.ts:19`
- `src/services/base-datos-vectores.service.ts:24`, `BaseDatosVectoresService`. Si Ollama contesta y tiene el modelo.
  - `verificarConexion()` `:27`, `GET /vectores`, publica, controller `src/controllers/base-datos-vectores.controller.ts:19`
- `src/services/inicio.service.ts:12`, `InicioService`. La portada del backend, que dice si esta vivo.
  - `obtenerEstado()` `:13`, `GET /`, publica, controller `src/controllers/inicio.controller.ts:15`

**Helpers y guardias**

- `src/helpers/cortacircuitos.ts:27`, `Cortacircuitos`. Despues de un fallo pausa la base 15 segundos. `GET /db/cortacircuitos`, con `@Permiso('sistema.ver')`, dice el estado de cada una.
- `src/helpers/respuesta.ts:19`, `exito()`. Toda respuesta sale con `ok`, `mensaje` y `payload`.

**En la pagina**, `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md`

Rutas sin service, las contesta el controller solo. `GET /db/cortacircuitos`, `POST /usuario/logout`.
