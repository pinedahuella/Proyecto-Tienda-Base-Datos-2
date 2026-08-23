# Base de datos

Modelo relacional en PostgreSQL. El diagrama tiene 38 tablas y hay 35
construidas; faltan las tres de la parte social (comentario, resena y likes).

El catalogo de productos ya no vive solo aqui: se migro a MongoDB, y eso cambio
un par de decisiones de este modelo. Esta explicado abajo, en "El catalogo se
mudo a MongoDB".

El diagrama esta en `diagrama-general.png` de esta misma carpeta. El archivo
editable es `diagrama-general.drawio`, se abre en https://app.diagrams.net

Version en Drive:
https://drive.google.com/file/d/1obLn5lAiQ4xzDM1OWzVNyqCENhTJoH6_/view?usp=sharing

Abajo esta el por que de cada decision del modelo.

---

## Los historiales no se encadenan

Esta es la decision que mas nos costo y la que mas nos pueden preguntar.

Un pedido tiene que recordar con que precio, con que nombre y con que comision
se vendio, aunque despues esos datos cambien. Para eso existen tres tablas de
historial: `Productos Variantes Historial`, `Productos Historial` y
`Categorias_historial`.

Al principio los encadenamos: la linea del pedido apuntaba al historial de la
variante, ese al del producto, y ese al de la categoria. Eso falla, porque cada
nivel cambia en fechas distintas:

```
1 ene    Variantes Historial #1  ->  Productos Historial #1 ("Camisa Nike")
15 feb   Se renombra a "Playera Nike"  ->  Productos Historial #2
         La variante no cambio, no se crea historial nuevo de variante
20 feb   Venta  ->  VH#1  ->  PH#1  ->  "Camisa Nike"
```

La venta del 20 de febrero queda guardada con el nombre de enero.

Con la comision es peor. Si sube del 10% al 15% y nadie edita el producto, todas
las ventas siguen cobrando 10% indefinidamente.

**Solucion:** `Pedido / producto` apunta a los tres historiales por separado.
Ningun historial apunta a otro historial, solo a su fila viva.

```
Pedido / producto
  id_producto_variante_historial   precio y talla
  id_producto_historial            nombre del producto
  id_categoria_historial           comision
```

La otra opcion era hacer cascada: que cada cambio de producto genere filas nuevas
de historial para todas sus variantes. Funciona, pero renombrar un producto con
20 variantes escribe 20 filas identicas, y subir la comision de una categoria
escribe miles. En un e-commerce se lee mucho mas de lo que se cambian precios.

**Sobre las formas normales:** no es redundancia. Desde el historial de variante
no se puede deducir que version del producto regia ese dia; si se pudiera,
sobraria el campo. Y cada FK es una sola por linea, no una lista, asi que no hay
dependencia multivaluada (4FN y 5FN se cumplen solas).

---

## El catalogo se mudo a MongoDB

Lo de arriba sigue siendo el motivo por el que una venta congela lo que se
vendio. Lo que cambio es **de donde** sale ese congelado.

Los tres historiales existen para los productos que cargo el ETL, pero un
producto que publica un vendedor **nace solo en MongoDB** y no tiene ninguna
fila en ellos. Asi que las tres llaves foraneas de `Pedido / producto` solo
funcionaban para los 50 productos del conjunto de prueba: con el producto 51 en
adelante no habia a que apuntar.

Se resolvio en dos partes.

**Los id que viven en Mongo llevan el sufijo `_mongo`.** `id_producto_mongo` e
`id_producto_variante_mongo`, en la linea del pedido y en el inventario. **No
son llaves foraneas y no pueden serlo**: PostgreSQL no puede garantizar
integridad referencial contra otra base. El sufijo esta para que quien lea la
tabla lo sepa de un vistazo y no busque una FK que no existe. El enlace lo
sostiene la aplicacion.

**Se guardan los DOS id, producto y variante**, no solo el de la variante. En
Mongo las variantes van embebidas dentro del producto y no hay indice unico
sobre `variantes.id_producto_variante`: que hoy no se repitan es solo la
convencion "el maximo mas uno" del backend. El par si es inequivoco. Lo mismo en
`Inventario`, donde el `UNIQUE (id_producto_mongo, id_producto_variante_mongo)`
es el que impide dos saldos para la misma variante -- el papel que en el
diagrama hacia la llave foranea.

**Lo que esas tres FK congelaban se copia dentro de la linea:** nombre del
producto, nombre de la variante, precio unitario y porcentaje de comision, tal
como estaban al vender.

Si, es redundancia. Es la misma que ya se aceptaba en `precio_unitario`, y por
tres razones:

- Una factura no puede depender de otra base para poder reimprimirse. Si Mongo
  esta caido o el producto se borro, con solo un id no se sabe que se vendio.
- Reconstruir desde los eventos de Mongo se hace **por dia**, y el nombre puede
  haber cambiado esa misma manana.
- Renombrar un producto no debe reescribir el pasado. En los datos de prueba se
  ve: el pedido de enero guarda "Camisa de lino" y el de marzo "Camisa de lino
  manga larga", porque la renombraron el 10 de febrero.

Para "como era el producto ese dia" -- la ficha completa, no lo cobrado -- se
usa la fecha del pedido contra `productos_eventos` en Mongo, que es donde vive
el historial del catalogo.

---

## El pedido y la compra son dos momentos

Armar un pedido no es comprarlo.

Mientras esta **pendiente** se le agregan lineas, se le quitan y se le cambia la
cantidad. Ahi se **comprueba** que haya stock, pero no se descuenta nada: el
pedido todavia no es una venta.

Al **comprar** si. Se vuelve a mirar el stock de cada linea, se descuenta, se
escribe el movimiento, se registra el pago y el pedido pasa a `comprado`. Las
cinco cosas juntas o ninguna.

Los estados son `pendiente`, `comprado`, `enviado`, `entregado` y `cancelado`.
Se llama **comprado** y no pagado porque no son lo mismo: un pedido contra
entrega esta comprado y todavia no pagado, y el estado del dinero vive en `Pago`,
que tiene el suyo.

**Mientras el pedido esta pendiente, el stock NO esta reservado.** Dos personas
pueden meter la ultima unidad en su pedido; se la lleva la primera que compre y
la segunda recibe "no hay suficiente stock" al confirmar. Lo que se comprueba al
agregar es un aviso temprano, no una garantia. Reservar desde que se agrega
tambien es defendible, pero obliga a soltar las reservas de los pedidos que
nadie termina, y eso pide un proceso que las vaya venciendo. No se hizo.

Todo esto vive en funciones de la base (`migrations/007_flujo_pedido.sql`):
`crear_pedido`, `agregar_linea`, `quitar_linea`, `comprar_pedido` y
`cancelar_pedido`. Estan ahi y no en la aplicacion por dos motivos: una funcion
de PostgreSQL corre dentro de una transaccion, asi que nadie puede olvidarse de
abrirla; y el `SELECT ... FOR UPDATE` sobre `Inventario` -- lo unico que impide
que dos personas compren la ultima unidad -- queda donde estan los datos, no
repartido por las rutas que descuenten stock.

Cancelar un pedido comprado **no borra la salida**: escribe la entrada contraria
con motivo `devolucion`. Un libro mayor no se corrige quitando renglones.

---

## Un vendedor por producto

`Productos.id_usuario` es el vendedor.

Evaluamos el modelo multi-vendedor (varios vendedores ofertando el mismo producto,
tipo Amazon). Lo descartamos porque obliga a sacar `precio` de
`Productos Variantes` y colgar `Inventario` de una entidad de publicacion nueva.
Eso recablea cuatro tablas y el documento del curso nunca pide competencia de
precios entre vendedores, solo el rol vendedor.

---

## Una categoria por producto, con jerarquia

`Categorias` se apunta a si misma con `id_categoria_padre`, igual que
`Comentario` con `id_comentario_padre`. Asi se arma `ropa > ropa de mujer >
zapatos` sin repetir la rama en cada producto.

Descartamos la relacion muchos a muchos por un motivo concreto: la comision vive
en la categoria. Si un producto tuviera dos categorias, no habria forma de decir
que comision cobrarle.

---

## Inventario con kardex

`Inventario.stock` guarda el total y `Stock Movimiento` guarda cada entrada y
salida que lo explica.

Tres detalles:

**El signo vive en `Motivo_Movimiento`, no en el movimiento.** El campo
`valor (1, -1)` esta en el motivo, asi que una venta siempre resta y una compra
siempre suma. No existe forma de registrar una venta que suba el stock, porque no
hay donde escribirlo. `cantidad` va siempre positiva y el efecto real es
`cantidad * valor`.

**`id_usuario` siempre, `id_pedido` solo a veces.** Al construirlo se cambio de
idea sobre esto: en el diagrama la venta no tenia usuario, pero una venta si lo
tiene -- es quien compra. Todo movimiento lo causa alguien, asi que `id_usuario`
quedo NOT NULL. El que se turna es `id_pedido`: una reposicion o un ajuste no
nacen de ninguna venta.

| Movimiento | id_pedido | id_usuario |
|---|---|---|
| Venta | el pedido | quien compra |
| Devolucion | el pedido | quien compra |
| Reposicion | NULL | el vendedor |
| Ajuste o merma | NULL | quien lo registra |

**`stock_resultante` es el saldo despues de cada movimiento.** Sirve para dos
cosas: responder "cuanto habia el 3 de marzo" leyendo una fila, y detectar
manipulacion. Si la suma de los movimientos no cuadra con el ultimo saldo, alguien
borro o altero una fila.

Si, `Inventario.stock` y `stock_resultante` son datos derivables. Es redundancia
deliberada: recalcular la suma en cada consulta del catalogo no es viable, y a
cambio queda la verificacion de integridad.

**Una sola tabla de movimientos, no dos.** Se penso separar movimientos de venta y
de administrador. Se descarto porque guardarian los mismos campos y obligaria a
un UNION en casi todas las consultas. Una tabla se parte cuando los campos son
distintos, no cuando el origen es distinto.

---

## La resena no lleva fecha

La resena es el comentario raiz (`id_comentario_padre` en NULL), y
`Comentario.fecha_publicacion` ya guarda cuando. Ponerle fecha propia seria el
mismo dato dos veces. Cuesta un JOIN en las consultas, nada mas.

`Likes` si lleva `fecha_creacion` porque no es un comentario y no tiene de donde
heredarla. Ademas es el campo que hace posible detectar manipulacion: 40 likes en
tres minutos, o cuentas creadas el mismo dia dandose like entre si.

---

## Los historiales no llevan estado

Un historial solo se inserta, nunca se actualiza. El estado vive en la fila viva,
que si cambia.

La regla: si la fila se actualiza, lleva estado. Si solo se inserta, no.

Por lo mismo la fecha se llama `fecha_creacion` y no `fecha_actualizacion`: marca
desde cuando rige esa version. Con una sola fecha alcanza para reconstruir:

```sql
SELECT * FROM productos_variantes_historial
WHERE id_producto_variante = 42
  AND fecha_creacion <= '2026-03-03'
ORDER BY fecha_creacion DESC
LIMIT 1;
```

Con un indice en `(id_producto_variante, fecha_creacion DESC)` la base no recorre
nada: entra al indice y lee una fila. No hace falta un booleano `es_vigente`, que
ademas seria derivable, el mismo problema por el que quitamos `pedidos.total`.

---

## Sin columna total en Pedido

El total sale de sumar las lineas, asi que guardarlo violaria 3FN: se calcula
cuando se necesita. `Pago.monto` es otra cosa -- lo que efectivamente se cobro --
y ese si se guarda, porque puede no coincidir con el total (un pago parcial, un
reembolso).

---

## Los atributos variables

> **Esto ya se resolvio.** Lo de abajo es el diagnostico del problema, que es lo
> que motivo migrar el catalogo a una base documental. La solucion fueron las
> siete tablas de caracteristicas (`004_caracteristicas.sql`): una definicion
> con su tipo y su unidad, lo que ofrece cada categoria, y el valor que le pone
> cada producto. En MongoDB eso llega como un arreglo de
> `{ nombre, valor, unidad }` dentro de cada producto y de cada variante.
>
> Se deja escrito porque el diagnostico sigue siendo la razon de todo lo demas.

### El problema, tal como estaba

Toda caracteristica variable cae en `Productos.descripcion`, porque no existe un
conjunto de atributos comun a todas las categorias. Los atributos de una laptop no
se parecen a los de una camisa.

La consecuencia es que no se puede filtrar por atributo. Es una limitacion
conocida del modelo relacional para este caso, y esta anotada dentro del diagrama.
