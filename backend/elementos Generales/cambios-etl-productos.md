# Cambios del ETL en el documento de producto

Lo que cambió en `etl/` y cómo queda ahora el documento de la colección
`productos`. Está aquí para saber qué hay que ajustar del lado del backend.

Todo lo de abajo está corriendo: se puede comprobar contra la base con DbGate
(http://localhost:3001) o con `.\arrancar.ps1 -Mongo`.

---

## 1. El `valor` sale con su tipo, ya no siempre texto

Era el punto 1 de `pendientes-etl-caracteristicas.md`. Ya está hecho.

El ETL convierte según el `tipo_dato` de la definición antes de escribir:
`entero` y `decimal` a `Number`, `booleano` a `Boolean`, `texto` a `String`.

```json
// antes
{ "nombre": "Nucleos", "valor": "10", "unidad": null }
// ahora
{ "nombre": "Nucleos", "valor": 10, "unidad": null }
```

Medido sobre las 50 fichas: de 1407 valores que eran todos `string` se pasó a
649 `string`, 238 array, 200 `number` y 28 `boolean`.

## 2. Una característica de tipo `lista` es UNA entrada con un array

Era el punto 3 del mismo archivo.

```json
// antes: una entrada por elemento, con el nombre repetido
{ "nombre": "Contenido del paquete", "valor": "Telefono",    "unidad": null },
{ "nombre": "Contenido del paquete", "valor": "Cable USB-C", "unidad": null }

// ahora
{ "nombre": "Contenido del paquete", "valor": ["Telefono", "Cable USB-C"], "unidad": null }
```

**Los filtros no necesitan ningún cambio**, tal como estaba anotado: Mongo
compara un campo array contra un valor suelto por contención, así que el
`$elemMatch: { nombre, valor }` que ya usa `ProductosService` encuentra igual.
Comprobado: `?Contenido del paquete=Manual` devuelve los mismos 12 productos
que antes del cambio.

## 3. Los eventos de creación ya traen las características

Era el punto 2. Los 50 eventos de creación traen `caracteristicas_adicionales`
dentro de `datos`.

Los de modificación **no**, y no es un olvido: las características no tienen
historial en el relacional, así que el ETL solo conoce las de hoy. Las escribe
iguales en todas las fotos que arma y por eso salen enteras en la creación y
nunca como un cambio. Para que una modificación las muestre harían falta dos
tablas de historial que no están en el ER, y eso es decisión de equipo.

## 4. Nueva colección: `categorias`

Las 29 categorías, cada una con las características que ofrece, su tipo y su
unidad. Es la paleta del formulario de publicar; no guarda valores.

```json
{
  "_id": 5,
  "nombre": "Computadoras",
  "categoria_padre": "Electronica",
  "porcentaje_comision": { "$numberDecimal": "6.00" },
  "caracteristicas":          [ { "nombre": "Marca", "tipo_dato": "texto", "unidad": null } ],
  "caracteristicas_variante": [ { "nombre": "Memoria RAM", "tipo_dato": "entero", "unidad": "GB" } ]
}
```

## 5. Nuevo: `variantes[].stock`

Cuántas unidades quedan de esa variante.

```json
{
  "id_producto_variante": 1,
  "nombre_variante": "M azul",
  "precio": { "$numberDecimal": "169.00" },
  "stock": 9
}
```

Está en el documento porque el catálogo se lee de Mongo: sin esto, mostrar
"agotado" o filtrar por disponible obliga a una consulta a PostgreSQL por cada
producto de la página.

**Es una copia, nunca la verdad.** Quien decide si alcanza es PostgreSQL, dentro
de la transacción de la compra. Si se decidiera con este número, dos personas
comprarían la última unidad.

**No entra en los eventos**, a propósito. Los eventos existen para reconstruir el
catálogo; el stock cambia con cada venta y llenaría la colección de ruido. El
historial del stock ya vive en `stock_movimiento`, en PostgreSQL, y con más
detalle (motivo, usuario, pedido). Consecuencia: reconstruir un producto a una
fecha pasada no devuelve stock.

### De dónde sale ese número y quién lo escribe

El número vive en `inventario.stock`, en PostgreSQL, y ese saldo se deriva del
libro `stock_movimiento`. Al documento entra en tres momentos, y cada uno lo
hace alguien distinto:

| Cuándo | Quién lo escribe |
| --- | --- |
| Carga inicial o recarga completa | El ETL. `extraer.sql` hace el JOIN con `inventario` |
| Después de una compra | El backend, con lo que devuelve `crear_pedido` |
| Al publicar un producto o agregar una variante | El backend, al crear la fila de `inventario` |

El ETL solo alcanza lo primero: corre con `.\arrancar.ps1` y solo manda sobre
los productos que vienen de PostgreSQL. Los otros dos momentos son de la
aplicación.

Para el segundo y el tercero, la escritura es esta:

```js
db.productos.updateOne(
  { _id: 1, 'variantes.id_producto_variante': 1 },
  { $set: { 'variantes.$.stock': 7 } }
);
```

---

## Las funciones del pedido

Están en `migrations/007_flujo_pedido.sql` y ya corren. Son cuatro, porque
**armar un pedido y comprarlo no son lo mismo**:

| Función | Qué hace | ¿Toca el stock? |
| --- | --- | --- |
| `crear_pedido(id_usuario, id_direccion_historial)` | Abre un pedido vacío en `pendiente` | No |
| `agregar_linea(id_pedido, linea_jsonb)` | Mete un producto, o le suma cantidad si ya estaba | No, solo comprueba |
| `quitar_linea(id_pedido, id_producto, id_variante)` | Lo saca | No |
| `comprar_pedido(id_pedido, metodo_pago)` | Confirma: descuenta, registra el pago, pasa a `comprado` | **Sí** |
| `cancelar_pedido(id_pedido)` | Cancela. Si estaba comprado, devuelve el stock | Sí, al revés |

Los estados del pedido son `pendiente`, `comprado`, `enviado`, `entregado` y
`cancelado`. Comprar y pagar no son lo mismo: un pedido contra entrega está
comprado y todavía no pagado, y el estado del dinero vive en `pago`.

### Mientras el pedido está pendiente, el stock NO está reservado

`agregar_linea` comprueba que haya suficiente, pero no descuenta ni aparta
nada. Es un aviso temprano, no una garantía: dos personas pueden meter la
última unidad en su pedido, y se la lleva **la primera que compre**. La
segunda recibe "no hay suficiente stock" al llamar a `comprar_pedido`.

Es como funciona cualquier tienda. Reservar desde que se agrega también es
defendible, pero obliga a soltar las reservas de los pedidos que nadie termina,
y eso pide un proceso que las vaya venciendo. No se hizo.

### Armar el pedido

```sql
SELECT crear_pedido($1, $2);   -- id_usuario, id_direccion_historial -> devuelve id_pedido

SELECT agregar_linea($1, $2);  -- id_pedido, la linea como JSON
```

La línea:

```json
{
  "id_producto": 1,
  "id_producto_variante": 1,
  "nombre_producto": "Camisa de lino manga larga",
  "nombre_variante": "M azul",
  "precio_unitario": "169.00",
  "porcentaje_comision": "12.00",
  "cantidad": 2
}
```

El nombre, el precio y la comisión **vienen como parámetro** porque viven en
Mongo y PostgreSQL no los puede leer. Se sacan del documento antes de llamar, y
quedan congelados desde que se agrega: si el vendedor sube el precio después,
ese pedido conserva el que se le mostró a la persona.

Agregar dos veces la misma variante **suma la cantidad en una sola línea**, no
crea dos. Devuelve la cantidad acumulada y el stock disponible del momento:

```json
{ "id_pedido": 8, "id_producto": 1, "id_producto_variante": 1, "cantidad": 3, "stock_disponible": 9 }
```

### Comprar

```sql
SELECT comprar_pedido($1, $2);  -- id_pedido, 'tarjeta' | 'transferencia' | 'efectivo contra entrega'
```

Aquí sí se vende. Vuelve a mirar el stock de cada línea, lo descuenta, escribe
el movimiento, registra el pago como `pendiente` y pasa el pedido a `comprado`.
**O pasan las cinco cosas o no pasa ninguna.**

Devuelve lo que hace falta para poner Mongo al día, sin volver a consultar:

```json
{
  "id_pedido": 8,
  "total": "507.00",
  "stock": [ { "id_producto": 1, "id_producto_variante": 1, "stock": 6 } ]
}
```

**El control de stock está adentro.** La función bloquea la fila del inventario
(`SELECT ... FOR UPDATE`), mira el saldo y decide. Es lo único que impide que
dos personas compren la última unidad; si eso se hiciera en el backend, las dos
leerían "queda 1" y las dos venderían.

Y recorre las líneas ordenadas por producto y variante: si dos compras
simultáneas tomaran las mismas variantes en orden distinto, cada una bloquearía
la que la otra espera y quedarían trabadas.

### Cancelar

```sql
SELECT cancelar_pedido($1);
```

Cancelar uno `pendiente` no toca el stock, porque nunca se descontó. Cancelar
uno `comprado` sí: devuelve las unidades con un movimiento de `devolucion` y
pasa el pago a `reembolsado`. **La salida no se borra** — un libro mayor no se
corrige quitando renglones, se compensa con la entrada contraria, y así queda
constancia de las dos. Devuelve el stock resultante, igual que comprar.

Un pedido ya `enviado` o `entregado` no se cancela desde aquí.

### Los errores

Salen como excepción, con el mensaje en claro:

```
No hay suficiente stock de "L azul": quedan 11 y el pedido pide 9999
El pedido 8 ya esta comprado
El pedido 8 esta comprado y ya no se puede cambiar
El metodo de pago "efectivo" no existe
Esa direccion no es de este usuario
El pedido 8 no tiene ninguna linea
```

### Probado

- Pedido abierto y dos líneas agregadas de la misma variante: quedó **una**
  línea con 3 unidades y el stock **sin moverse** (9).
- Al comprar: stock 9 → 6, pedido `comprado`, pago `pendiente` por 507.00.
- Al cancelar: stock 6 → 9, pago `reembolsado`, y el libro conserva los dos
  movimientos (venta 3 y devolución 3).
- Pedir más de lo que hay avisa y no deja nada a medias.
- Las 92 variantes siguen cuadrando con el libro: 0 descuadres.

Lo que las funciones **no** hacen: confirmar el pago (el pedido nace comprado y
su pago pendiente; ponerle la fecha y pasarlo a `aprobado` es otro paso) ni
actualizar Mongo. Eso segundo es de quien llama.

---

## Lo que hay que ajustar del lado del backend

**1. Al publicar un producto, crear su inventario.** `POST /vendedor/productos`
escribe el documento pero no crea la fila de `inventario`, así que sus variantes
salen sin `stock`. Hoy pasa con los dos productos publicados desde el panel (51
y 52): son los únicos del catálogo cuyas variantes no traen el campo. El ETL no
los toca — solo manda sobre los id que vienen de PostgreSQL — así que esa fila
la tiene que crear la aplicación.

Lo mismo al agregar una variante nueva en `PATCH /vendedor/productos/:id`.

**2. Después de una compra, actualizar el `stock` del documento.** El descuento
real ocurre en PostgreSQL; el número del documento hay que ponerlo al día
después, o el catálogo seguirá mostrando el stock viejo. La función
`crear_pedido` devuelve el stock resultante de cada variante justamente para
eso, sin tener que volver a consultar.

**3. Nada más.** Los filtros de `GET /productos` y `GET /productos/paginacion`
siguen funcionando sin tocarlos: se corrieron las 44 comprobaciones de filtros y
las 17 de paginación después de estos cambios y todas cuadran contra la base.

---

## Dos cosas más que cambiaron y no son del ETL

**Dos productos se movieron de categoría.** `Balon de futbol numero 5` y
`El camino de las nubes` colgaban de una categoría raíz (Deportes y Libros), y
ahí no se puede publicar: `GET /vendedor/categorias` solo devuelve las que
tienen padre, y `GET /vendedor/categorias/:id` contesta 404 para una raíz, así
que el panel del vendedor no podía ni abrirlos. Ahora están en dos
subcategorías nuevas, `Futbol` y `Literatura`, y las raíces ya no ofrecen
características.

**El historial contaba los días en UTC.** En
`services/vendedores/productos.service.ts`, el corte de
`GET /vendedor/productos/:id/historial?fecha=` era la medianoche UTC, seis horas
antes que en Guatemala: un producto publicado a las 21:45 del día 22 se guarda
como 03:45Z del 23, así que preguntar por el 22 contestaba "el producto no
existía en esa fecha" el mismo día en que se publicó. El corte ahora se hace en
`-06:00`. Es el único archivo de `backend/src/` que se tocó.
