# Respaldo del catálogo: la tienda se ve sin MongoDB

**Fecha:** 2026-10-19 (noche), con permiso de José David para tocar `backend/`.
**Alcance:** `backend/`, la migración `047_catalogo_respaldo.sql` y
`etl/extraer_catalogo_postgres.js` (paso 7e de `arrancar.ps1`). En la base de la
PC de José David la 047 ya está aplicada y la copia llenada.

## Por qué

El profesor pidió que, si se apaga una base, la aplicación siga respondiendo con
las que quedan. Con MongoDB caído se podía comprar (la 029 copió a PostgreSQL lo
que pide el checkout), pero el catálogo, la ficha de un producto, las categorías
y las tarjetas de las recomendaciones daban 503: la tienda se veía vacía.

## Qué se hizo

- **Migración 047.** `producto_catalogo` suma `estado`, `id_categoria`,
  `descripcion` y `fecha_creacion`. Sin `estado` el respaldo mostraría
  borradores y propuestas; sin la categoría la ficha se rompe
  (`producto.categoria.nombre`).
- **La copia se escribe donde ya se escribía.** `sincronizarCatalogo` copia los
  campos nuevos. `editar()` sincroniza también si cambia solo el estado, la
  descripción o la categoría (antes solo con nombre o variantes).
  `revisarPropuesta()` y `reenviarPropuesta()` actualizan el estado de la copia
  dentro de su misma transacción (`actualizarEstadoCatalogo`). El paso 7e copia
  los campos nuevos para lo que entra por fuera del backend.
- **`helpers/catalogo-respaldo.ts`** (nuevo):
  - `conRespaldoDeMongo(deMongo, dePostgres)`: si Mongo no responde, corre el
    respaldo. Cortacircuitos de 15 s: después de una caída va directo a
    PostgreSQL, sin esperar los 3 s del driver en cada petición.
  - `productosDesdePostgres(ids)`: arma el documento con la misma forma que
    Mongo desde la copia, `oferta` y `resena`, con las mismas cuentas que
    `recalcularUnProducto` (precio de la tienda, precio desde, stock, vendedores,
    descuento, notas). Marca `desde_respaldo: true`. No tiene características.
  - `paginaDesdePostgres(filtros)`: el catálogo paginado con todos los filtros
    fijos. Los filtros por características (solo viven en Mongo) dan 503, en
    vez de una lista mal filtrada.
  - `categoriasValidasDesdePostgres()` y `productosPorIds()`.
- **Dónde se usa.** `GET /productos`, `/productos/paginacion`, `/productos/:id`,
  `/categorias`, para ti, también compraron, parecidos, vistos recientemente y
  las dos tendencias del admin. `construirFiltro` se partió en `leerFiltros`
  (valida) y `filtroMongo` (arma el filtro): Mongo y el respaldo validan igual.
- **Cliente de Mongo cerrado.** Si el backend arranca con Mongo caído, el driver
  7 cierra el cliente y cada consulta da "Topology is closed" para siempre (antes
  salía como 500). `esCaidaDeMongo` (en `manejar-error-mongo.ts`) lo reconoce
  como caída, y el respaldo llama a `mongoClient.connect()` al volver a probar
  Mongo: se reconecta todo el backend, workers incluidos.
- **Frontend.** La ficha con `desde_respaldo` dice "Algunos detalles de este
  producto no se pueden mostrar ahora".

Lo que no cambia: crear, editar y proponer productos siguen pidiendo Mongo (503
con Mongo caído). El documento completo vive ahí.

## Pruebas

- Con la base de José David y el backend apuntando a un Mongo cerrado, 71
  llamadas comparadas campo por campo contra las mismas con Mongo: 362 iguales y
  1 distinta, la del filtro por característica, que da 503 a propósito. Tiempo
  casi igual (12.4 s contra 12.6 s), ninguna llamada pasó de 1.1 s.
- Mongo prendido y apagado en vivo (un reenviador en 27999): el backend arranca
  con Mongo caído y la ficha sale del respaldo; Mongo vuelve y a los 15 s sale de
  Mongo otra vez, sin reiniciar; Mongo se cae con el backend corriendo, la
  primera petición tarda 3.2 s y las siguientes 70 ms; vuelve otra vez.
- Las escrituras: editar solo la descripción, solo el estado, y una propuesta
  rechazada, reenviada, aprobada y dada de baja. Después de cada una, la copia es
  igual a Mongo. Queda el producto 1104 de la prueba, inactivo.
- Edge a 1536x730 con Mongo caído: catálogo con sus tarjetas y filtros, ficha
  completa con el aviso, 0 errores de JavaScript.
- `tsc` y eslint limpios, `svelte-check` 0 errores.
