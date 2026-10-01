# Plan pendiente — Nombre y estado de la variante en PostgreSQL

> **Estado (2026-09-30): etapa 1 aplicada en local, migración real pendiente
> (le toca a quien lleva `migrations/`).** Etapa 3, punto 3 y 4 HECHOS: el
> `PUT` del carrito, el checkout del carrito y la revisión previa del checkout
> de pedidos leen de las tablas, sin Mongo. **Punto 1 HECHO (2026-10-01):**
> crear, proponer y editar (nombre o variantes) escriben Mongo y la copia en
> una transacción de PostgreSQL con compensación
> (`helpers/catalogo-postgres.ts`, ver `escribirConCatalogoPostgres`). No es
> atómico de verdad: queda una ventana si el proceso muere entre la escritura
> de Mongo y el COMMIT. Aprobar/rechazar/reenviar propuesta no toca nombre ni
> variantes, así que no sincroniza. Los cambios hechos fuera del backend
> (ETL, scripts) siguen necesitando `catalogo-en-postgres-sembrar.cjs`.
> Quedan sin tocar `PedidosCompradorService.agregarLinea` (flujo manual de
> pedidos, sin uso en el frontend) y la compra post-COMMIT que recalcula
> campos calculados en Mongo (best-effort, no hace fallar la compra).

## El problema

El checkout lee de MongoDB tres datos que no están en PostgreSQL: el nombre
del producto, el nombre de la variante y el estado de la variante
(`activa`/`inactiva`).

- `POST /carrito/comprar` → `CarritoService.verCarrito()` → `consultarProductos()`
  (`carrito.service.ts`).
- `POST /comprador/pedidos/:id/comprar` → `revisarCambiosAntesDeComprar()` →
  `ProductosService.obtenerEstadosVariante()` (`pedidos.service.ts`).

Con Mongo caído la compra da 503 aunque Mongo no participe del `COMMIT`: es
la fila 11 de `docs/CONSISTENCIA-CHECKOUT.md` y la opción 2 de
`prueba-falla-mongo-checkout.md` (copiar a PostgreSQL lo que falta).

## Decisión: dos tablas, no columnas en `oferta`

El nombre depende de la **variante**, no de la oferta. Una variante puede
tener muchas ofertas (multi-vendedor): como columna de `oferta` el nombre se
repetiría N veces y un renombre tocaría N filas. Normalizado:

```
producto_catalogo   (id_producto_mongo PK, nombre)
variante_catalogo   (id_producto_mongo FK, id_producto_variante_mongo,
                     nombre_variante, estado, imagen)  PK = el par
oferta  ──(etapa 2)──>  variante_catalogo por el par
```

- El **par** identifica la variante, no el id solo (dos productos pueden
  repetir el id de variante; ver el comentario de `oferta` en `005`).
- `oferta` **no gana columnas**: ya tiene el par.
- **Mongo sigue siendo la fuente del catálogo.** Las tablas son una copia
  de lo que la compra y el carrito necesitan. Además de nombre y estado,
  `variante_catalogo.imagen` guarda **una sola imagen, la portada**
  (`variantes.imagenes[0]`), para que `construirSnapshot()` arme la línea del
  carrito de Redis sin ir a Mongo. El resto de imágenes y todo lo demás se
  quedan en Mongo.
- `pedido_producto` no cambia: sigue congelando los nombres al comprar.

## Etapas

### Etapa 1 — Las tablas (HECHA en local)

`catalogo-en-postgres.sql` (mismo folder). Aplicado y sembrado en local:
102 productos, 202 variantes (con `imagen` de portada), 0 ofertas sin su
variante.

**Para quien lleva `migrations/`:** integrar como `029_catalogo_en_postgres.sql`
(después de `028_vencimiento_oferta.sql`). Todo lo que está antes del
`COMMIT` del archivo es la migración; la etapa 2 viene comentada al final.

**Ojo con el orden de siembra.** Las tablas nacen vacías en un
`.\arrancar.ps1 -Reiniciar`. Hay que poblarlas **antes** de que existan las
ofertas:

- `migrations/datos/` y el ETL (`etl/`) insertan el catálogo en Mongo y las
  ofertas en PostgreSQL. Ahí hay que insertar también en las dos tablas, o
  correr `catalogo-en-postgres-sembrar.cjs` (idempotente, lee Mongo) justo
  después del ETL y antes de las ofertas.
- `arrancar.ps1` debería correr la siembra, igual que ya hace con el
  índice de búsqueda cuando no cuadra.

### Etapa 2 — La llave foránea (NO aplicar todavía)

`oferta (id_producto_mongo, id_producto_variante_mongo)` →
`variante_catalogo`, `ON DELETE RESTRICT`. Devuelve a PostgreSQL la
integridad que `005` daba por perdida (una oferta sobre una variante que no
existe). El `ALTER TABLE` está comentado al final del `.sql`.

Se aplica **solo cuando** la etapa 3 sincroniza al crear productos y el
ETL/datos de arriba ya insertan el catálogo antes que las ofertas. Si no,
crear una oferta sobre un producto recién creado la rechazaría.

### Etapa 3 — Backend (pendiente, solo `backend/`)

1. **Sincronización Mongo → PostgreSQL.** Un servicio que haga UPSERT de
   `producto_catalogo` y `variante_catalogo` desde un producto. Se llama
   después de cada escritura de catálogo en
   `vendedores/productos.service.ts`: crear, editar (nombre, variantes,
   estado de variante), aprobar/rechazar propuesta y su compensación. Una
   variante que desaparece del producto se borra de `variante_catalogo` solo
   si ninguna oferta la usa; si la usa, queda `inactiva`.
2. **Ventana de inconsistencia.** Mongo y PostgreSQL no comparten
   transacción: si Mongo escribe y la sincronización falla, la copia queda
   vieja. Mismo problema que `pendiente_busqueda`; la salida natural es la
   misma bandera + un `@Interval` que reintente, y declararlo en
   `docs/CONSISTENCIA-CHECKOUT.md`. Decidir cuál antes de implementar.
3. **Leer de PostgreSQL en el checkout.** `consultarOfertas()` hace `JOIN` a
   `variante_catalogo` y `producto_catalogo`; `verCarrito()` deja de llamar a
   Mongo; `revisarCambiosAntesDeComprar()` lee `variante_catalogo.estado` y
   deja de usar `obtenerEstadosVariante()`.
4. **El carrito de Redis.** `construirSnapshot()` (el `PUT` del carrito)
   lee nombres, estado e `imagen` de `variante_catalogo` en la misma consulta
   que ya hace a `oferta`, y deja de llamar a Mongo. La foto guarda lo mismo
   que hoy (`LineaCarritoRedis`); solo cambia de dónde sale. Con esto ni el
   `PUT` ni el checkout necesitan Mongo para el catálogo.
5. **Pruebas:** `pruebas/falla_checkout.sh`, escenario B (Mongo parado): hoy
   da 503; debe pasar a comprar normal. Es la prueba de que se cerró la
   fila 11.

## Lo que queda por decidir

- Mecanismo de reintento de la sincronización (punto 2 de la etapa 3).
- Con el profesor: la fila 11 pasa de "ventana de disponibilidad aceptada" a
  "resuelta", a cambio de mantener una copia del catálogo.
