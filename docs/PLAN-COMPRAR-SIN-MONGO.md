# Plan de la decision 5, comprar sin MongoDB

Escrito el 2026-09-29. Es la decision 5 de la lista de propuestas (seccion 2 de
`docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md`), la que propuso el profesor. Cierra
la fila 12 de `docs/PENDIENTES.md` y la fila 11 de `docs/CONSISTENCIA-CHECKOUT.md`.

**La parte de la base ya esta hecha y probada** (seccion 2). Lo que falta es del
backend (seccion 3) y va por pasos chicos, cada uno se puede subir solo.

---

## 1. El problema, en una linea

MongoDB no escribe nada del pedido, pero las dos rutas de compra le preguntan el
nombre del producto, el de la variante, la imagen y si la variante esta activa
ANTES del COMMIT. Con MongoDB caido no se vende (503 en unos 5 s, escenario B de
`pruebas/falla_checkout.sh`). La salida que se eligio es la 2 de la fila 11,
copiar esos datos a la oferta, que es lo que ya se hace con precio y stock.

Despues del cambio:

| Flujo | Redis | PostgreSQL | MongoDB |
|---|---|---|---|
| Ver el carrito | lee | no | no |
| Agregar al carrito | escribe | lee la oferta con su copia | **no** |
| Comprar (carrito o pedido) | candado y reservas | la transaccion | **no** |
| Editar, pausar, descontar una oferta | registro de ofertas | escribe | solo el recalculo de agregados, despues y sin esperar |
| Crear una oferta nueva | no | escribe | lee el producto una vez (ver 3.7) |
| Editar un producto | no | pone al dia la copia | es el dueno, escribe primero |

MongoDB sigue siendo el dueno del catalogo. La oferta guarda una copia de
lectura, igual que `pedido_producto` ya guarda `nombre_producto` y
`nombre_variante` al comprar.

---

## 2. Lo que ya esta hecho (base de datos y arranque)

### 2.1 Migracion 029, `migrations/029_catalogo_en_oferta.sql`

Seis columnas nuevas en `oferta`, todas NULL al nacer.

| Columna | Tipo | Que es |
|---|---|---|
| `nombre_producto` | varchar(200) | nombre del producto en MongoDB |
| `nombre_variante` | varchar(100) | nombre de la variante |
| `imagen_variante` | text | primera imagen de la variante, o NULL |
| `producto_visible` | boolean | el producto esta `activo` (no borrador, inactivo ni rechazado) |
| `variante_activa` | boolean | la variante esta `activa` |
| `catalogo_copiado_en` | timestamptz | cuando se copio. **NULL = no hay copia, no confiar en las otras cinco** |

Los largos son los de `pedido_producto` y los de
`helpers/validaciones-crear-producto.ts` (200 y 100).

Una funcion, la unica forma de escribir la copia:

```sql
SELECT copiar_catalogo_a_oferta('[{"id_producto": 12, "id_producto_variante": 3,
  "nombre_producto": "...", "nombre_variante": "...", "imagen": "https://..." ,
  "producto_visible": true, "variante_activa": true}]'::jsonb);
-- devuelve cuantas ofertas cambiaron de verdad
```

- Pone al dia TODAS las ofertas de cada variante que recibe (de todos los
  vendedores).
- Solo cuenta como cambio lo que difiere. Correrla dos veces seguidas da 0.
- Un nombre mas largo que la columna da error, no se recorta.
- Una variante sin ofertas no hace nada.

Y un ajuste al trigger `oferta_tocar_fecha` (de la 005). Antes cualquier UPDATE
movia `fecha_actualizacion`. Ahora, si lo UNICO que cambio es la copia del
catalogo, la fecha no se mueve. Sin eso, renombrar un producto haria que sus
ofertas parecieran editadas por sus vendedores. Todo lo demas se comporta igual
que antes, incluido un UPDATE que no cambia nada.

### 2.2 Paso 7e de `arrancar.ps1`, "Copiando el catalogo a las ofertas"

`etl/extraer_catalogo_oferta.js` lee de MongoDB todas las variantes (tambien las
apagadas, para que una oferta se entere de que su producto se apago), arma la
llamada a `copiar_catalogo_a_oferta()` y se corre en PostgreSQL. Va despues del
catalogo y de los lotes. No corta el arranque, pero avisa en rojo si falla y
cuenta las ofertas que quedan sin copia.

### 2.3 Lo que se midio el 2026-09-29, sobre la base local

```
029 aplicada dos veces        sin error, la segunda solo avisa que las columnas ya estan
primera copia                 16908 ofertas puestas al dia, 3105 productos, 6232 variantes,
                              2,7 s en PostgreSQL y 2 s en MongoDB
segunda copia                 0 ofertas cambiadas
fecha_actualizacion           el md5 de las 16908 fechas igual antes y despues de copiar
ofertas sin copia             0
producto_visible = false      5, todas del producto 43, que esta inactivo en MongoDB
trigger                       solo copia no mueve la fecha; precio mas copia si; un UPDATE
                              sin cambios si (igual que antes)
nombre raro                   "Laptop Ambar n 'x' "y" $5" con tilde y enie, llega igual
nombre de 201 caracteres      ERROR value too long, no se recorta
paso 7e aislado               "6232 variantes de 3105 productos leidas de MongoDB,
                              0 oferta(s) puestas al dia" y "todas las ofertas tienen su copia"
```

---

## 3. Lo que le toca al backend, paso por paso

Las lineas son las del commit b431509. El orden importa: primero se ESCRIBE la
copia (3.1 y 3.2), despues se LEE (3.3 a 3.5). Si se lee antes de escribirla,
una oferta nueva saldria sin nombre.

### 3.1 Crear una oferta escribe su copia

`services/vendedores/ofertas.service.ts`, `crear()` (linea 253).

- La lectura a MongoDB de la linea 277 ya trae nombre, variantes e imagenes.
  Agregar `'variantes.estado': 1` a la proyeccion.
- El INSERT de la linea 315 suma las seis columnas. `producto_visible` es `true`
  porque la consulta ya filtra por `estado: ESTADO_PRODUCTO_VISIBLE`.
  `catalogo_copiado_en` va con `now()`.

### 3.2 Editar un producto pone al dia la copia

Un metodo nuevo en `services/productos/productos.service.ts`, por ejemplo
`copiarCatalogoAOfertas(producto: Producto)`, que arma el arreglo con TODAS las
variantes del documento y llama a `SELECT copiar_catalogo_a_oferta($1::jsonb)`.
Se llama despues de cada escritura a MongoDB que puede cambiar un nombre, una
imagen o un estado:

| Donde | Linea | Que cambia |
|---|---|---|
| `vendedores/productos.service.ts`, `editar()` | 1330 | nombre, estado, variantes enteras. Ya relee el documento en la 1333, pasarle ese |
| `vendedores/productos.service.ts`, `revisarPropuesta()` | 604 | estado del producto (aprobado o rechazado) |
| `vendedores/productos.service.ts`, `reenviarPropuesta()` | 710 | estado |
| `vendedores/productos.service.ts`, `compensarRevisionMongo()` | 797 | revierte el estado, tambien tiene que revertir la copia |

**Si la llamada a PostgreSQL falla despues de escribir en MongoDB**, no se
deshace la edicion. Se registra en el log y la copia queda vieja hasta el
proximo arranque (paso 7e). Es el mismo criterio que ya tiene el recalculo de
agregados. Si se quiere cerrar esa ventana sin esperar al arranque, ver 3.8.

### 3.3 El checkout del carrito deja de leer MongoDB

`services/carrito/carrito.service.ts`.

- `consultarOfertas()` (linea 1166) suma al SELECT las seis columnas.
- `verCarritoEnVivo()` (linea 284) toma nombre, variante, imagen y estados de la
  fila de la oferta. `consultarProductos()` ya no se llama, **salvo** para las
  ofertas con `catalogo_copiado_en IS NULL` (ver 3.6).
- `evaluarDisponibilidad()` (linea 1143) usa `variante_activa` y ademas
  `producto_visible`. Hoy el carrito no revisa si el producto se apago, solo la
  variante. Para no cambiar el frontend, un producto apagado puede salir con el
  mismo motivo `variante_no_disponible`.

### 3.4 Agregar al carrito deja de leer MongoDB

Mismo archivo, `construirSnapshot()` (linea 891). Igual que 3.3, la foto sale de
la fila de la oferta. Con esto agregar al carrito solo toca Redis y PostgreSQL.

### 3.5 La ruta del pedido deja de leer MongoDB

`services/compradores/pedidos.service.ts`.

- `agregarLinea()` (linea 228). Hoy llama a `productosService.obtenerPublico()`
  (linea 250) solo para el nombre y el estado de la variante. `resolverOferta()`
  (linea 794) puede traer las columnas nuevas y se valida con
  `producto_visible` y `variante_activa`, con el mismo 404 de hoy.
- `revisarCambiosAntesDeComprar()` (linea 853). Hoy llama a
  `obtenerEstadosVariante()` (linea 883). Se reemplaza por `o.variante_activa` y
  `o.producto_visible` en el mismo SELECT de la linea 869.

### 3.6 Una oferta sin copia vuelve a MongoDB

Mientras exista alguna oferta con `catalogo_copiado_en IS NULL` (una base donde
no corrio el paso 7e, o una oferta creada con un backend viejo), las rutas de
3.3 a 3.5 le piden el dato a MongoDB SOLO para esas lineas, como hoy. Asi el
cambio no rompe nada en ninguna PC. Cuando 3.1 y 3.2 lleven un tiempo en uso,
una migracion 030 pone NOT NULL a las columnas y este respaldo se borra.

### 3.7 Crear una oferta sigue leyendo MongoDB, y por que

El vendedor elige el producto desde el catalogo, que vive en MongoDB. Si MongoDB
esta caido ni siquiera puede ver que ofertar. Comprobar que el producto existe
y esta activo es justo lo que MongoDB sabe y PostgreSQL no. Todo lo que se hace
con una oferta YA creada (editar precio, stock, descuento, pausar, venta
relampago) ya no lee MongoDB antes de escribir, solo recalcula agregados
despues (3.9). Esto hay que dejarlo escrito en el informe como parte de la
decision, no como un olvido.

### 3.8 Opcional, una revision periodica de la copia

Si se quiere que una copia que quedo vieja por un fallo en 3.2 se arregle antes
del proximo arranque, un worker cada 10 minutos puede pedir a MongoDB los
productos con `fecha_actualizacion` reciente y pasarlos por
`copiar_catalogo_a_oferta()`. No es obligatorio para cerrar la fila 12.

### 3.9 Despues del COMMIT, no esperar a MongoDB

Hoy, al terminar de comprar, `comprarCarrito` (linea 751) y las dos rutas de
`pedidos.service.ts` (lineas 663 y 713) hacen
`await productosService.recalcularCamposCalculados(ids)`. Ese metodo se traga
sus errores, asi que la compra no falla. Pero con MongoDB caido espera los 3 s
de `serverSelectionTimeoutMS` **por cada producto**, uno detras de otro. Un
carrito con 5 productos contestaria unos 15 s despues de cobrar. Se propone no
esperarlo (`void ...catch(log)`), para que la respuesta salga en cuanto
PostgreSQL confirma. Lo mismo vale para `ofertas.service.ts` (lineas 349, 544,
664, 753 y 880).

---

## 4. Como se comprueba

Lo que no es backend lo hago yo cuando David avise que 3.1 a 3.5 estan subidos:

- `pruebas/falla_checkout.sh`, escenario B. Hoy espera 503 con MongoDB parado.
  Pasa a esperar la compra hecha, el pedido creado, el stock bajado y el
  carrito vacio, y que la respuesta llegue en menos de 2 s (comprueba 3.9).
- Un escenario nuevo en la misma prueba. Con MongoDB parado, agregar al carrito
  tambien funciona.
- Un arnes nuevo, `pruebas/catalogo_oferta.sh`. Renombrar un producto por la ruta
  del admin y ver el nombre nuevo en sus ofertas. Apagar una variante y ver que
  el carrito la marca no disponible. Comprobar que la fecha de la oferta no se
  movio.
- Correr los 23 arneses en serie otra vez.
- `docs/CONSISTENCIA-CHECKOUT.md` fila 11 y `docs/PENDIENTES.md` fila 12, cerradas
  con los numeros medidos. El informe suma el ADR-12 con el formato de la
  seccion 6 de las propuestas.

---

## 5. Lo que queda fuera a proposito

- El carrito que guarda la foto que manda el frontend es la decision 6, otra
  cosa. Con esta decision la foto la sigue armando el backend, pero desde
  PostgreSQL.
- Los estantes y el buscador siguen leyendo MongoDB y Elasticsearch. No estan en
  el camino del dinero.
- El nombre del vendedor no se copia, ya lo pone `agregar_linea()` desde
  `usuarios`.
