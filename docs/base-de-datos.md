# Base de datos

Modelo relacional en PostgreSQL. Son 31 tablas.

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

**`id_pedido` e `id_usuario` se turnan.** Una venta la dispara el sistema y no
tiene usuario; un ajuste manual no tiene pedido. Por eso los dos aceptan NULL.

| Movimiento | id_pedido | id_usuario |
|---|---|---|
| Venta | el pedido | NULL |
| Reabastecimiento | NULL | el admin |
| Ajuste por conteo | NULL | el admin |
| Devolucion | el pedido | quien la procesó |

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

El total sale de sumar las lineas, asi que guardarlo violaria 3FN. Se calcula con
una vista. `Pago.monto` es otra cosa: lo que efectivamente se cobro.

---

## Los atributos variables

Toda caracteristica variable cae en `Productos.descripcion`, porque no existe un
conjunto de atributos comun a todas las categorias. Los atributos de una laptop no
se parecen a los de una camisa.

La consecuencia es que no se puede filtrar por atributo. Es una limitacion
conocida del modelo relacional para este caso, y esta anotada dentro del diagrama.
