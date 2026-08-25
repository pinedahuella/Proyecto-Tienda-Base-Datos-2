# Backend: qué cambiar para el modelo multi-vendedor

La base y el ETL ya están hechos y corriendo.

> **La base está CONGELADA desde el 2026-08-25.** No se tocan más migraciones,
> ni campos del ETL, ni índices. Cada cambio de aquí obliga a rehacer trabajo
> del backend, y ya pasó tres veces en una mañana. Si aparece algo, se reporta
> y lo decide el equipo — no se cambia.

Esto es lo que falta del lado del backend, en orden.

```powershell
.\arrancar.ps1 -Reiniciar
```

Queda en PostgreSQL: 36 tablas · 34 productos · 63 variantes · **168 ofertas** ·
220 filas de precio · 153 movimientos de stock.
Y en Mongo: `productos` 34 · `categorias` 23 · `productos_eventos` 44.

---

## 0. Lo que ya está hecho (no rehacer)

| | |
|---|---|
| `GET /productos`, `/paginacion`, `/productos/:id` | listos, con los filtros nuevos |
| Flujo de pedidos completo | listo y **probado end to end** |
| Catálogo y ficha en el frontend | listos |
| Panel del vendedor | **falta**, y es lo que sigue |

**Probado el 2026-08-25**: compra con dos vendedores en un mismo pedido
(Q7,885 = 3,856 + 4,029), stock descontado, kardex cuadrado, pago escrito,
Mongo actualizado solo, y cancelación devolviendo stock con su movimiento de
`devolucion` y el pago a `reembolsado`. Las validaciones aguantan pedido ajeno
(404), pedido vacío (409), tarjeta inválida (400), vencida (402), método
inventado (409) y cantidad 0 o negativa (400).

**Lo único que falta de rutas:** `/vendedor/ofertas` — un vendedor ya no publica
un producto con precio, publica una **oferta** sobre un producto que ya existe
en el catálogo. Sin esas rutas el panel del vendedor no se puede arreglar.

---

## 1. La idea

Antes el producto **era de un vendedor** y llevaba el precio adentro. Ahora el
catálogo es **compartido** y lo que es de alguien es la **oferta**.

```
productos            la laptop.  De nadie.
productos_variantes  la laptop de 16 GB.  De nadie.
oferta               la que vende Juan a Q5000, con 9 unidades
oferta               la misma, de María a Q4800, con 3
```

La comisión salió del alcance: se fue entera.

---

## 2. Qué se fue y a dónde

| Se fue | Ahora está en |
|---|---|
| `productos.id_usuario` | `oferta.id_usuario` |
| `productos_variantes.precio` | `oferta.precio` |
| tabla `inventario` | `oferta.stock` |
| `categorias.porcentaje_comision` | — |
| tabla `categorias_historial` | — |
| `pedido_producto.precio_unitario` | vía `id_precio_historial` |
| `pedido_producto.porcentaje_comision` | — |
| `producto.vendedor` (Mongo) | tabla `oferta`, en PostgreSQL |
| `variantes[].precio` (Mongo) | tabla `oferta`, en PostgreSQL |
| `variantes[].stock` (Mongo) | tabla `oferta`, en PostgreSQL |

**Tablas nuevas** (`migrations/005_ofertas.sql`):

```
estado_oferta     activa | pausada | retirada
oferta            id_oferta, id_producto_mongo, id_producto_variante_mongo,
                  id_usuario, precio, stock, id_estado_oferta,
                  fecha_creacion, fecha_actualizacion
                  UNIQUE (id_usuario, id_producto_mongo, id_producto_variante_mongo)
precio_historial  id_precio_historial, id_oferta, precio, id_usuario_modifico,
                  fecha_creacion
```

**`oferta` apunta al catálogo por los ids de Mongo y SIN llave foránea**, igual
que `pedido_producto`: una sola forma de identificar una variante en todo el
sistema. La contra: la base ya no rechaza una oferta sobre una variante que no
existe — eso lo tiene que comprobar la aplicación al publicar.

**Y siempre por el PAR producto + variante, nunca por la variante sola.** En
Mongo las variantes van embebidas y no hay índice único sobre
`variantes.id_producto_variante`, así que dos productos distintos pueden tener
una variante con el mismo id. Por eso el `UNIQUE` lleva las tres columnas y el
índice lleva las dos del catálogo: con solo `(usuario, variante)` un vendedor no
podría ofertar la variante 5 de la laptop y la variante 5 de la camisa a la vez,
y la base rechazaría la segunda sin que nada esté mal.

Aplicá la misma regla en tus consultas: `WHERE id_producto_mongo = $1 AND
id_producto_variante_mongo = $2`.

### Las ofertas NO están en Mongo

Se quedan solo en PostgreSQL. Copiarlas obligaría a sostener precio, stock y
estado al día en dos bases a la vez, que es el riesgo de inconsistencia que
queremos evitar — y PostgreSQL es donde se decide si alcanza para vender.

En Mongo solo hay cuatro números **agregados** dentro del producto, para que la
lista del catálogo se pinte sin salir de ahí. **La ficha de un producto pide sus
ofertas a PostgreSQL.**

---

## 3. Los modelos

### `models/producto.ts`

Quitar `ProductoVendedor` entera. En `ProductoCategoria`, quitar
`porcentaje_comision`. En `ProductoVariante`, quitar `precio` y `stock`. Y
agregar en los dos:

```ts
export interface ProductoCategoria {
  id_categoria: number;
  nombre: string;
  categoria_padre: string | null;   // null en las raíces
}

export interface ProductoVariante {
  id_producto_variante: number;
  nombre_variante: string;
  descripcion: string | null;
  fecha_creacion: Date;
  estado: string;
  imagenes: string[];
  /** Precio de la tienda para ESTA variante. Copia calculada por el ETL. */
  precio_tienda: Decimal128 | null;
  /** Unidades de la tienda para esta variante. 0 si no tiene o está pausada. */
  stock_tienda: number;
  /** Unidades entre TODOS los vendedores activos de esta variante. */
  stock_total: number;
  /** Cuántos vendedores la tienen activa. */
  total_ofertas: number;
  caracteristicas_adicionales?: EntradaCaracteristica[];
  caracteristicas_personalizadas?: EntradaCaracteristica[];
}

export interface Producto {
  _id: number;
  nombre: string;
  descripcion: string | null;
  fecha_creacion: Date;
  estado: string;
  categoria: ProductoCategoria;
  /** El menor de los precios de la tienda entre sus variantes. */
  precio_tienda: Decimal128 | null;
  /** SUMA del stock de la tienda sobre todas sus variantes. */
  stock_tienda: number;
  /** SUMA del stock de todas las ofertas activas de todas sus variantes. */
  stock_total: number;
  total_ofertas: number;
  variantes: ProductoVariante[];
  caracteristicas_adicionales?: EntradaCaracteristica[];
  caracteristicas_personalizadas?: EntradaCaracteristica[];
}
```

`ProductoConStockTotal` ya no aplica: el stock no está en el producto.

### `models/oferta.ts` — nuevo

Es una fila de **PostgreSQL**, no un documento. Va con el resto de los modelos
relacionales, y los `bigint` llegan como `string` porque así los entrega `pg`.

```ts
/** Tabla oferta. Quien vende una variante, a qué precio y con cuántas unidades. */
export interface Oferta {
  id_oferta: string;
  /** Del catálogo en MongoDB. NO es llave foránea. */
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  id_usuario: string;
  precio: string;
  stock: number;
  id_estado_oferta: number;
  fecha_creacion: Date;
  fecha_actualizacion: Date;
}
```

### `models/pedido-producto.ts`

```ts
export interface PedidoProducto {
  id_pedido_producto: string;
  id_pedido: string;
  /** De aquí salen el precio cobrado, la oferta y el vendedor. */
  id_precio_historial: string;
  id_producto_mongo: string;
  id_producto_variante_mongo: string;
  cantidad: number;
  nombre_producto: string;
  nombre_variante: string;
  nombre_vendedor: string;
}
```

---

## 4. Las consultas que necesitás

**Las ofertas de una variante, de la más barata a la más cara** (tiene índice).
Es la consulta de la ficha, y va a **PostgreSQL**:

```sql
SELECT o.id_oferta, o.precio, o.stock, eo.estado_oferta_nombre AS estado,
       u.id_usuario, u.usuario, u.nombre, u.apellido
FROM oferta o
JOIN usuarios      u  ON u.id_usuario        = o.id_usuario
JOIN estado_oferta eo ON eo.id_estado_oferta = o.id_estado_oferta
WHERE o.id_producto_mongo          = $1
  AND o.id_producto_variante_mongo = $2
  AND eo.estado_oferta_nombre = 'activa'
ORDER BY o.precio;
```

**Todas las ofertas de un producto**, para la ficha completa: lo mismo con solo
`WHERE o.id_producto_mongo = $1` — el índice sirve igual, porque el id del
producto va primero y un índice compuesto se usa por su prefijo.

**Las ofertas de un vendedor**, para su panel: `WHERE o.id_usuario = $1`.

**El precio y el vendedor de una línea del pedido** (SQL):

```sql
SELECT pp.*, ph.precio, o.id_oferta, o.id_usuario AS id_vendedor
FROM pedido_producto pp
JOIN precio_historial ph ON ph.id_precio_historial = pp.id_precio_historial
JOIN oferta o            ON o.id_oferta            = ph.id_oferta
WHERE pp.id_pedido = $1;
```

**El filtro por rango de precio del catálogo** ya no puede ir con `$elemMatch`
sobre `variantes.precio`. Va contra `precio_desde`, que es el más barato al que
se ofrece — **no** contra `precio_tienda`:

```ts
filtro.precio_desde = { $gte: Decimal128.fromString(min),
                        $lte: Decimal128.fromString(max) };
```

La tarjeta **enseña** `precio_tienda` (regla del profesor) pero el buscador
filtra por lo que se puede **pagar**. En 21 de los 34 productos alguien lo vende
más barato que la tienda; con el filtro sobre `precio_tienda` esos quedaban
fuera de la búsqueda aunque sí le sirvieran a quien puso un tope. Ya está
arreglado en `productos.service.ts`, y quedó `precio_tienda_min/max` por si
alguna pantalla quiere el filtro estricto de la tienda.

**El filtro de disponibilidad** va contra `stock_total`, y usa el índice
`catalogo_categoria_estado_stock` sin recorrer la colección:

```ts
// solo lo que se puede comprar hoy, de cualquier vendedor
filtro.stock_total = { $gt: 0 };
```

Los dos campos de stock **solo cuentan ofertas `activa`**: una pausada tiene
unidades y no se puede comprar, así que contarla haría mentir al filtro.

En el conjunto de datos hay casos de los tres tipos, a propósito: 33 productos
con existencias, 1 agotado del todo, y 9 variantes donde la tienda está en 0 —
6 de ellas con otro vendedor que sí tiene. Ahí es donde hay que decidir qué dice
la tarjeta: `stock_tienda = 0` pero `stock_total > 0` **no es "agotado"**.

---

## 5. Las funciones de PostgreSQL

`migrations/007_flujo_pedido.sql`. Tres cambiaron de firma y una es nueva.

```sql
crear_pedido(id_usuario bigint, id_direccion_historial bigint) -> bigint
    -- igual que antes

agregar_linea(id_pedido bigint, linea jsonb) -> jsonb          -- CAMBIÓ
quitar_linea(id_pedido bigint, id_oferta bigint) -> boolean    -- CAMBIÓ
comprar_pedido(id_pedido bigint, metodo_pago varchar) -> jsonb
cancelar_pedido(id_pedido bigint) -> jsonb
reponer_stock(id_oferta bigint, cantidad integer,
              motivo varchar, id_usuario bigint) -> jsonb      -- NUEVA
```

### `agregar_linea`

El cuerpo de la línea ahora es:

```ts
await pool.query('SELECT agregar_linea($1, $2::jsonb)', [idPedido, JSON.stringify({
  id_oferta: idOferta,            // <- lo nuevo: se compra una OFERTA
  cantidad: cantidad,
  id_producto: idProducto,        // los ids de Mongo, para guardar en la línea
  id_producto_variante: idVariante,
  nombre_producto: nombreProducto,
  nombre_variante: nombreVariante,
})]);
```

**Ya no se manda el precio.** Lo busca ella en `precio_historial` y guarda el id
de la fila vigente, así que el backend no puede mandar un precio que no esté
publicado. **El nombre del vendedor tampoco**: sale de `usuarios`.

Devuelve:

```json
{ "id_pedido": 3, "id_pedido_producto": 7, "id_oferta": 12,
  "id_usuario_vendedor": 2, "cantidad": 2, "stock_disponible": 9 }
```

Rechaza con `check_violation` si la oferta está `pausada` o `retirada`.

### `comprar_pedido` y `cancelar_pedido`

Devuelven el stock resultante de cada oferta, para que actualices Mongo sin
volver a consultar:

```json
{ "id_pedido": 3, "total": "3852.00",
  "stock": [ { "id_oferta": 12, "id_usuario": 2, "id_producto": 3,
               "id_producto_variante": 5, "stock": 7 } ] }
```

Con eso hay que **recalcular los cuatro agregados** del producto en Mongo
(`precio_tienda`, `stock_tienda`, `stock_total`, `total_ofertas`) y hacerles
`$set` en su documento. Es lo único que se sincroniza a Mongo después de una
venta.

### `reponer_stock`

Reemplaza las rutas de inventario del vendedor. Motivos: `reposicion` (suma) y
`ajuste` (resta). No admite `venta` ni `devolucion`: esos los escribe solo el
flujo del pedido.

---

## 6. Las rutas

**Borrar** — hablan de `inventario`, que ya no existe:

```
GET   /vendedor/productos/inventario
GET   /vendedor/productos/inventario/motivos-ajuste
GET   /vendedor/productos/:id/inventario
POST  /vendedor/productos/:id/inventario
PATCH /vendedor/productos/:id/inventario
```

Con ellas se van `services/vendedores/inventario.service.ts`,
`helpers/validaciones-inventario.ts`, `dto/inventario-vendedor.ts` y
`dto/ajustar-inventario-vendedor.ts`.

**Crear** — lo que un vendedor sí posee ahora:

```
GET    /vendedor/ofertas            las mías
POST   /vendedor/ofertas            publicar una sobre una variante existente
PATCH  /vendedor/ofertas/:id        precio, estado
POST   /vendedor/ofertas/:id/stock  llama a reponer_stock()
```

**Cambiar**:

- `POST /comprador/pedidos/:id/detalles` — el cuerpo ahora lleva `id_oferta`
- `DELETE /comprador/pedidos/:id/detalles/:idDetalle` — pasa a ser por `id_oferta`
- `GET /productos` — quitar el filtro `id_vendedor`, rehacer el de precio
- `GET /productos/:id` — agregarle sus ofertas

**Crear, y esto es de la Entrega 1** — hoy no existe y sin ellas no se puede
cerrar una compra desde la app:

```
POST /comprador/pedidos/:id/comprar    llama a comprar_pedido()
POST /comprador/pedidos/:id/cancelar   llama a cancelar_pedido()
```

**Las 6 comprobaciones de propiedad** (`vendedor.id_usuario !== idUsuario`) en
`services/vendedores/productos.service.ts` ya no sirven: el producto no es de
nadie. Lo que se comprueba es que **la oferta** sea suya.

---

## 7. Las tres reglas que no se pueden romper

**1. Nada de esta cadena se borra, nunca.**

```
pedido_producto.id_precio_historial
   -> precio_historial.id_oferta
      -> oferta.id_usuario
         -> usuarios
```

De ahí sale el precio cobrado y quién vendió. Hay tres `ON DELETE RESTRICT`
seguidos: PostgreSQL te va a frenar. No lo rodees.

- **Retirar una oferta = `estado = 'retirada'`**, nunca un DELETE.
- **Un vendedor que se va se desactiva**, no se borra.

**2. `precio_tienda` y `total_ofertas` son copias.** Hay que recalcularlos cuando
una oferta cambie de precio, se quede sin stock o se pause. Si no, la tarjeta
dice un precio y la ficha otro.

**3. Un vendedor tiene UNA oferta por producto+variante.** Lo garantiza el
`UNIQUE` de las tres columnas; si insertás el mismo trío, revienta con
`unique_violation`. Pero el **mismo id de variante en otro producto sí pasa**, y
tiene que pasar.

---

## 8. Cuentas

Todas entran. Los hashes son scrypt del formato de `helpers/contrasena.ts`.

| Correo | Rol | Contraseña |
|---|---|---|
| `tienda@mesh.com` | vendedor | `Vendedor123` |
| `ventas.norte@mesh.com` · `ventas.sur@mesh.com` | vendedor | `Vendedor123` |
| `ventas.oriente@mesh.com` · `ventas.poniente@mesh.com` | vendedor | `Vendedor123` |
| `compradora.norte@mesh.com` · `comprador.sur@mesh.com` | comprador | `Comprador123` |
| `admin@mesh.com` | admin | `Admin123` |

`tienda@mesh.com` es la cuenta de la página: tiene oferta de **todas** las
variantes y su precio es el que se enseña. Regla del profesor, el primero
siempre es el de la página.

---

## 9. Una cosa que hay que decidir entre los tres

Un vendedor ya no publica un producto: publica una **oferta sobre un producto que
ya existe**. Entonces, ¿quién crea las entradas del catálogo?

Si cualquier vendedor puede, dos van a crear la misma laptop dos veces y el
catálogo compartido deja de servir. La base hoy no lo impide: `productos` no
tiene dueño.
