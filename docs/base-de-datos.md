# Base de datos

Modelo relacional en PostgreSQL. **Las 42 tablas del diagrama estan
construidas.** Las tres ultimas -- `comentario`, `resena` y `likes` -- entraron
con `migrations/011_resenas.sql`; aqui decia "39 de 42" y ya no es cierto. Se
comprueba contando:

```bash
docker exec -i mesh-postgres psql -U meme -d mesh -tAc \
  "SELECT count(*) FROM information_schema.tables
    WHERE table_schema='public' AND table_type='BASE TABLE';"
-- 42
```

Eso contaba 42 cuando se escribio. Hoy la base tiene **46**: `evento_grafo` de
la 015, que no es del ER porque no modela negocio (es la cola hacia Neo4j), y
las tres tablas de alertas de fraude de la 016, que SI son negocio y **todavia
no estan en el diagrama**. Estan explicadas abajo, en "Las alertas de fraude
del login".

> **Los numeros de este documento describen el conjunto de datos que genera
> `migrations/datos/generador.js` con su semilla fija** -- 102 productos, 202
> variantes, **556 ofertas, 11 cuentas**, y desde la 011 tambien **90 resenas,
> 118 comentarios** y 62 votos, mas los **13 pedidos de 101 lineas** que las
> respaldan -- no el estado de una base que ya se uso.
>
> Tres de esas cuentas (`anillo.*@mesh.com`) y 4 de esas resenas son el **anillo
> de fraude**, sembrado a proposito para que el panel de la Entrega 2 tenga algo
> real que ensenar. Ver `docs/PENDIENTES.md`.
> Una base sobre la que alguien compro, publico una oferta o creo un producto
> tiene mas, y eso es normal, no un desajuste. Para volver a los numeros de
> aqui: `.\arrancar.ps1 -Reiniciar`.

El catalogo de productos ya no vive solo aqui: se migro a MongoDB, y eso cambio
un par de decisiones de este modelo. Esta explicado abajo, en "El catalogo se
mudo a MongoDB".

El diagrama esta en `diagrama-general.png` de esta misma carpeta. El archivo
editable es `diagrama-general.drawio`, se abre en https://app.diagrams.net

**Desde el 2026-09-25 ese dibujo tiene las 56 tablas de la base (migraciones 001
a 025) y se genera, no se dibuja a mano**: `python docs/generar-er.py` lo lee de
la base viva y falla si una tabla o una llave foranea se queda sin dibujo. Las dos
tablas de reglas de descuento (021 y 022) van en el modulo de ofertas, los
hallazgos F1 a F6 (025) en el de fraude y `producto_vector` (024) en la isla del
catalogo, porque apunta a MongoDB por id y no por llave foranea. El ER de la
Entrega 1, con sus notas de la migracion a MongoDB, se conserva en
`diagrama-general-entrega1.drawio`. Lo que se dice arriba de "42 tablas" es la
foto de la Entrega 1.

Version en Drive:
https://drive.google.com/file/d/1obLn5lAiQ4xzDM1OWzVNyqCENhTJoH6_/view?usp=sharing

Abajo esta el por que de cada decision del modelo.

---

## El catalogo es compartido y la oferta es de alguien

Es la decision que ordena todo lo demas, y la que cambio a mitad del proyecto.

Al principio un producto **era de un vendedor**: `Productos.id_usuario`, y el
precio adentro de la variante. Eso es un marketplace donde cada quien monta su
tienda y la misma laptop existe cinco veces, una por vendedor, sin nada que las
relacione.

Ahora el catalogo describe **cosas del mundo** y cualquiera puede ofertarlas:

```
Productos              la laptop.  De nadie.
  Productos Variantes    la laptop de 16 GB.  De nadie.
    Oferta               la que vende Juan a Q5000, con 9 unidades
    Oferta               la misma, que vende Maria a Q4800, con 3
```

**Lo que se gana:** una sola ficha, una sola foto, un solo juego de
caracteristicas y un solo historial para la laptop, sin importar cuantos la
vendan. Comparar precios se vuelve posible porque hay algo que comparar.

**Lo que se paga:** el producto pierde tres campos que parecian suyos.

| Se fue de | Se fue a |
|---|---|
| `productos.id_usuario` | `oferta.id_usuario` |
| `productos_variantes.precio` | `oferta.precio` |
| la tabla `inventario` | `oferta.stock` |

`Oferta` apunta al catalogo por `id_producto_mongo` e
`id_producto_variante_mongo`, **sin llave foranea**, igual que la linea del
pedido. La razon es la misma: el catalogo se lee desde MongoDB y PostgreSQL no
puede garantizar integridad referencial contra otra base. Lo que se gana es una
sola forma de identificar una variante en todo el sistema; lo que se paga es que
la base ya no puede rechazar una oferta sobre una variante que no existe, y eso
pasa a ser trabajo de la aplicacion.

**Y se identifica por el PAR, nunca por la variante sola.** En Mongo las
variantes van embebidas dentro del producto y no hay indice unico sobre
`variantes.id_producto_variante`: dos productos distintos PUEDEN tener una
variante con el mismo id. Por eso el `UNIQUE` de `Oferta` lleva las tres
columnas -- vendedor, producto y variante -- y no dos. Con solo
`(vendedor, variante)` la base rechazaria que un mismo vendedor ofertara la
variante 5 de la laptop y la variante 5 de la camisa, que son cosas distintas.
Es el mismo motivo por el que la linea del pedido guarda los dos id.

Y aparece una pregunta que antes no existia: **de todos los precios, cual se
ensena.** La respuesta la puso el profesor: **el primero siempre es el de la
pagina**. La cuenta `tienda@mesh.com` tiene oferta de todas las variantes y su
precio es el que sale en el catalogo. Como no falta en ninguna, no hace falta
una regla de reserva para el caso "nadie vende esto".

---

## Precio y stock viven juntos, pero con dos libros

`Oferta` guarda las dos cosas, y eso fue deliberado. Antes eran dos tablas -- el
precio en una pivote de usuario-variante y el stock en `inventario` -- con la
**misma llave logica** (vendedor + variante) y ningun enlace entre si. Se podia
tener stock sin precio (invendible, y sin que nada avisara) o precio sin stock.
Juntas son una sola cosa, y ademas le dan casa al estado, que antes no tenia
ninguna.

Pero sus historias van **separadas**, y no por comodidad:

**El stock es aditivo. El precio no.** El saldo del stock es la suma de sus
movimientos, y por eso `Stock Movimiento` es un kardex con cantidad y signo. Un
cambio de precio no suma ni resta: reemplaza. Meterlos en el mismo libro dejaria
cada fila de precio con el motivo, la cantidad y el pedido en NULL, que es
exactamente el antipatron de *"columnas mayormente nulas"* que el enunciado del
curso critica.

```
Oferta            precio y stock de hoy
  Precio Historial    un snapshot por cada precio que tuvo
  Stock Movimiento    un renglon por cada entrada y salida
```

**El precio de nacimiento lo escribe la base, no la costumbre.** Un trigger de
`005_ofertas.sql` inserta la primera fila de `Precio Historial` cuando nace la
oferta, y otra cada vez que cambia el precio. Sin esa primera fila, preguntar
por una fecha anterior al primer *cambio* devolveria vacio, y "no existia" se
leeria igual que "nunca cambio".

---

## La linea del pedido no copia el precio

Un pedido tiene que recordar con que precio y de quien se compro, aunque despues
esos datos cambien. Antes eso se resolvia copiando el numero dentro de la linea.
Ya no hace falta, y esta es la parte que mas nos pueden preguntar.

`Pedido / producto` guarda **un solo puntero**:

```
pedido_producto.id_precio_historial
   -> precio_historial.precio      cuanto se cobro
   -> precio_historial.id_oferta
        -> oferta.id_usuario       quien vendio
```

**Por que esto congela igual que una copia:** cada eslabon es inmutable. Una fila
de `Precio Historial` no se actualiza nunca, y una oferta no cambia de dueno. El
precio queda tan fijo como si se hubiera copiado, y copiarlo seria guardar un
dato deducible -- el mismo motivo por el que `Pedido` no lleva `total`.

**Y de ahi sale una regla que hay que respetar en todo el sistema:** nada de esa
cadena se puede borrar jamas. Por eso van tres `ON DELETE RESTRICT` seguidos, y
por eso **retirar una oferta es cambiarle el estado, nunca un DELETE**, y un
vendedor que se va se desactiva en vez de borrarse. Es justamente lo que hace
util el estado `retirada`: las dos decisiones se sostienen entre si.

**Lo que si se copia son los nombres**, y por lo contrario: `nombre_producto`,
`nombre_variante` y `nombre_vendedor` **si cambian** y no se pueden deducir. Si
manana el vendedor se cambia el nombre de usuario, la factura vieja tiene que
seguir diciendo a quien se le compro ese dia.

**Sobre las formas normales:** guardar los nombres no es redundancia, porque no
son deducibles del estado de hoy: son un hecho distinto ("como se llamaba
entonces"). Guardar el precio si lo seria, y por eso no esta.

---

## Se fue la comision, y con ella una tabla

El profesor dejo la comision fuera del alcance. Se quito entera:
`categorias.porcentaje_comision`, `categorias_historial` (que existia **solo**
para congelar la comision del dia de la venta) y
`pedido_producto.porcentaje_comision`.

Vale la pena anotar el efecto colateral, porque tumbo un argumento que teniamos
escrito: la razon por la que un producto tenia **una sola** categoria era que la
comision vivia en la categoria, y con dos no se sabria cual cobrar. Ese motivo ya
no existe. La categoria unica se queda igual, pero ahora por otra razon: es la
que define **que caracteristicas ofrece** el formulario, y con dos categorias un
producto tendria dos paletas que se pisan.

---

## Dos niveles de categoria, ni uno mas

```
Electronica              raiz.  Agrupa. No tiene caracteristicas ni productos.
  Laptops                hoja.  Aqui cuelgan las caracteristicas y los productos.
  Audifonos              hoja.
```

Una hoja **no puede tener hijas**. Antes el arbol era libre y podia crecer
cuanto quisiera; en la practica el backend ya daba por hecho que solo se publica
en categorias con padre (`GET /vendedor/categorias` nunca devolvia una raiz, y
`GET /vendedor/categorias/:id` contestaba 404 para una). Lo que se hizo fue
**dejar de confiar en la costumbre**: ahora lo garantiza la base con un trigger,
en los dos sentidos -- ni se cuelga una hija de una hoja, ni se convierte en
hoja una raiz que ya tiene hijas.

Va con trigger y no con una columna `nivel` porque **el ER manda**, y esa columna
no esta en el diagrama. Un CHECK no alcanza: no puede mirar la fila del padre.

Un segundo trigger impide publicar un producto en una raiz. Las caracteristicas
viven en las hojas, asi que un producto colgado de una raiz queda fuera de todo
formulario -- y eso ya paso una vez, con un balon y una novela que no se podian
ni abrir para editar.

---

## El pedido y la compra son dos momentos

Armar un pedido no es comprarlo.

Mientras esta **pendiente** se le agregan lineas y se le quitan. Ahi se
**comprueba** que haya stock, pero no se descuenta nada: el pedido todavia no es
una venta.

Al **comprar** si. Se vuelve a mirar el stock de cada linea, se descuenta, se
escribe el movimiento, se registra el pago y el pedido pasa a `comprado`. Las
cinco cosas juntas o ninguna.

Los estados son `pendiente`, `comprado`, `enviado`, `entregado` y `cancelado`.
Se llama **comprado** y no pagado porque conceptualmente no son lo mismo: el
estado del pedido y el del dinero son columnas distintas, `Pedido.id_estado_pedido`
y `Pago.id_estado_pago`, cada una con su propio catalogo (`pagado` es un estado
de `Pago`, no de `Pedido`). Para la primera entrega, en la practica las dos
avanzan juntas: `comprar_pedido()` registra el pago como `pagado` de una vez,
sin importar el metodo -- no hay quien confirme una transferencia o un pago
contra entrega todavia (ver mas abajo, el problema de que un pedido puede
mezclar vendedores y el pago es uno solo). Es una simplificacion a proposito,
no el diseno final: el dia que se agregue una confirmacion real, la mayoria
de los metodos volveran a nacer `pendiente` como aqui se describia antes.

**Mientras el pedido esta pendiente, el stock NO esta reservado.** Dos personas
pueden meter la ultima unidad en su pedido; se la lleva la primera que compre y
la segunda recibe "no hay suficiente stock" al confirmar. Lo que se comprueba al
agregar es un aviso temprano, no una garantia. Reservar desde que se agrega
tambien es defendible, pero obliga a soltar las reservas de los pedidos que
nadie termina, y eso pide un proceso que las vaya venciendo. No se hizo.

Todo esto vive en funciones de la base (`migrations/007_flujo_pedido.sql`):
`crear_pedido`, `agregar_linea`, `restar_linea`, `quitar_linea`,
`cambiar_direccion_pedido`, `comprar_pedido`, `cancelar_pedido` y
`reponer_stock`. Estan ahi y no en la aplicacion por dos
motivos: una funcion de PostgreSQL corre dentro de una transaccion, asi que
nadie puede olvidarse de abrirla; y el `SELECT ... FOR UPDATE` -- lo unico que
impide que dos personas compren la ultima unidad -- queda donde estan los datos,
no repartido por las rutas que descuenten stock.

**El bloqueo ahora es sobre la fila de `Oferta`.** Es un detalle que mejoro solo
al volverse multi-vendedor: antes se bloqueaba la variante, asi que dos compras
de la misma camisa se esperaban aunque fueran a vendedores distintos. Ahora son
filas distintas y no se estorban.

**Un pedido puede mezclar vendedores.** Tres lineas de tres personas caben en el
mismo pedido y en el mismo pago. Cancelarlo es todo o nada: cancelar la linea de
un solo vendedor obliga a decidir que pasa con el pago, que es uno solo, y eso
no se hizo.

Cancelar un pedido comprado **no borra la salida**: escribe la entrada contraria
con motivo `devolucion`. Un libro mayor no se corrige quitando renglones.

**El chequeo de que la oferta siga `activa` no vive dentro de `comprar_pedido`.**
La funcion SQL, al comprar, solo vuelve a mirar el stock (con el `FOR UPDATE` de
arriba); que la oferta siga activa se comprueba antes, en el backend
(`PedidosCompradorService.revisarCambiosAntesDeComprar`). Esto dejaba una
ventana angosta cuando el chequeo y la llamada a `comprar_pedido` eran dos
consultas sueltas: si alguien pausaba o retiraba la oferta justo entre las
dos, la compra pasaba igual -- el `FOR UPDATE` de `comprar_pedido` no se
saltaba, pero solo protegia el stock, nunca el estado.

**Cerrado sin tocar la funcion SQL**: `comprarPedido()` ahora abre su propia
transaccion (`pool.connect()` + `BEGIN`/`COMMIT`/`ROLLBACK`, no `pool.query`
suelto) y el chequeo de `revisarCambiosAntesDeComprar` corre con
`FOR UPDATE OF o` sobre esas mismas filas de `Oferta`, dentro de esa
transaccion. El bloqueo queda tomado desde el chequeo: un `PATCH
/vendedor/ofertas/:id` concurrente que intente cambiar el estado de esa
oferta se queda esperando a que la transaccion de la compra termine, y
`comprar_pedido()` -- que vuelve a pedir `FOR UPDATE` sobre la misma fila,
ya bloqueada por la misma transaccion -- siempre lee el estado que ya se
valido. Probado en vivo (25 ago 2026): dos conexiones directas confirmaron
que la segunda se queda bloqueada mientras la primera sostiene el `FOR
UPDATE`, y se desbloquea justo al hacer `ROLLBACK`; los tres caminos de
`comprarPedido` (bloqueante por stock, bloqueante por estado, aviso de
precio con y sin `confirmar_cambios`) se probaron end-to-end contra la base
real sin regresiones.

**El estado de la VARIANTE tambien bloquea la compra, ademas del de la
oferta** (25 ago 2026, sesion posterior). El estado de un producto ya
protegia la busqueda, la ficha publica y crear una oferta (lista blanca,
`ESTADO_PRODUCTO_VISIBLE = 'activo'`), pero el de cada variante no vivia
en PostgreSQL -- nada revisaba `variantes[].estado` al comprar, solo al
agregar la linea (`agregarLinea`, via `obtenerPublico`). Decision del
usuario: agregar y comprar tratan una variante `inactiva` igual que un
producto oculto (no se puede agregar, no se puede comprar); quitar una
linea o restarle cantidad (el "-1") siguen funcionando siempre, sin
importar el estado de la variante -- nunca aumentan lo que hay en el
carrito, asi que no hay nada que proteger ahi, y sirven como la salida
para limpiar el carrito de algo que ya no se puede comprar.

`revisarCambiosAntesDeComprar` ahora tambien resuelve el estado de cada
variante de las lineas del pedido con una sola consulta a Mongo
(`ProductosService.obtenerEstadosVariante`, con `$in` sobre todos los
`id_producto` de una vez, nunca una consulta por linea), dentro de la
misma transaccion que ya tenia el `FOR UPDATE OF o`. Probado en vivo con
una variante forzada a `inactiva` directo en Mongo (no existe todavia
ningun endpoint que la desactive): agregarla al carrito rechaza con 404,
comprarla despues de agregarla y luego desactivarla rechaza con 409 (y
el `ROLLBACK` deja el pedido intacto), y restar/quitar la misma linea
siguen funcionando sin problema.

---

## El stock, con kardex

`Oferta.stock` guarda el saldo y `Stock Movimiento` guarda cada entrada y salida
que lo explica.

**El signo vive en `Motivo_Movimiento`, no en el movimiento.** El campo
`valor (1, -1)` esta en el motivo, asi que una venta siempre resta y una
reposicion siempre suma. No existe forma de registrar una venta que suba el
stock, porque no hay donde escribirlo. `cantidad` va siempre positiva y el efecto
real es `cantidad * valor`.

**`id_usuario_modifico` siempre, `id_pedido` solo a veces.** Todo movimiento lo
causa alguien, asi que el usuario quedo NOT NULL. El que se turna es el pedido:
una reposicion o un ajuste no nacen de ninguna venta.

| Movimiento | id_pedido | id_usuario_modifico |
|---|---|---|
| Venta | el pedido | quien compra |
| Devolucion | el pedido | quien compra |
| Reposicion | NULL | el vendedor |
| Ajuste o merma | NULL | quien lo registra |

**Se llama `id_usuario_modifico` y no `id_usuario` a proposito.** Ahora hay dos
usuarios cerca: el dueno del stock, que sale de `oferta.id_usuario`, y quien
provoco el movimiento, que es este. Con el mismo nombre, cualquier consulta
seria una moneda al aire. Lo mismo en `Precio Historial`.

**`stock_resultante` es el saldo despues de cada movimiento.** Sirve para dos
cosas: responder "cuanto habia el 3 de marzo" leyendo una fila, y detectar
manipulacion. Si la suma de los movimientos no cuadra con el ultimo saldo,
alguien borro o altero una fila. El conjunto de datos lo comprueba solo al
final, y falla la migracion entera si no cuadra.

Si, `Oferta.stock` y `stock_resultante` son datos derivables. Es redundancia
deliberada: recalcular la suma en cada consulta del catalogo no es viable, y a
cambio queda la verificacion de integridad.

**Una sola tabla de movimientos, no dos.** Se penso separar movimientos de venta
y de administrador. Se descarto porque guardarian los mismos campos y obligaria
a un UNION en casi todas las consultas. Una tabla se parte cuando los campos son
distintos, no cuando el origen es distinto.

---

## Que no se vende dos veces la ultima unidad: medido

El enunciado pide el flujo de compra como una transaccion atomica. No basta con
decir que lo es: se probo.

Se dejo una oferta con **una sola unidad** y dos pedidos, de dos compradores
distintos, cada uno pidiendola. Despues se llamo a `comprar_pedido` de los dos
**a la vez**, en dos conexiones separadas:

```
pedido 3  ->  compro. total 3856.00
pedido 4  ->  ERROR: No hay suficiente stock de "8 GB / 256 GB" (Paola Guzman):
              quedan 0 y se pidieron 1
```

Como quedo la oferta:

```
 id_oferta | stock | vendedor        | los dos pedidos
         1 |     0 | ventas_poniente | 3: comprado | 4: pendiente
```

Y su kardex:

```
 motivo      valor  cantidad  stock_resultante  pedido
 reposicion    +1        8           8            -
 venta         -1        1           7            1
 ajuste        -1        6           1            -
 venta         -1        1           0            3
```

Tres cosas que ensena esta prueba:

1. **No hubo sobreventa.** Una unidad, una venta.
2. **La transaccion que fallo no dejo rastro.** No hay un movimiento de venta
   del pedido 4, ni un pago, ni el pedido cambio de estado: sigue en
   `pendiente`. Revirtio entero, no a medias.
3. **El saldo lo explica el libro.** 8 - 1 - 6 - 1 = 0, que es lo que dice
   `oferta.stock`. Medido sobre **todas** las ofertas, dos veces: primero sobre
   las 552 del conjunto recien cargado, y despues sobre una base ya usada -- 555
   ofertas tras comprar, cancelar y publicar a mano. **Cero descuadres las dos
   veces**, con las dos comprobaciones que tienen sentido: que `oferta.stock`
   sea el ultimo `stock_resultante` del kardex, y que la suma con signo de todos
   los movimientos de una oferta de exactamente su saldo.

   ```sql
   -- que el saldo sea el ultimo renglon del libro
   WITH ultimo AS (
     SELECT DISTINCT ON (sm.id_oferta) sm.id_oferta, sm.stock_resultante
     FROM stock_movimiento sm
     ORDER BY sm.id_oferta, sm.fecha_movimiento DESC, sm.id_stock_movimiento DESC
   )
   SELECT count(*) FILTER (WHERE o.stock <> COALESCE(u.stock_resultante, 0)) AS descuadres
   FROM oferta o LEFT JOIN ultimo u ON u.id_oferta = o.id_oferta;
   ```

Lo que lo consigue es una sola linea, el `SELECT ... FOR UPDATE` sobre la fila
de `Oferta` dentro de `comprar_pedido`. La segunda conexion se queda esperando
ahi hasta que la primera termina, y entonces lee el saldo ya descontado. Sin ese
bloqueo las dos leerian "queda 1" y las dos venderian.

Y por eso vive dentro de la funcion y no en el backend: cualquier ruta nueva que
descontara stock por su cuenta se lo saltaria.

---

## Una oferta nace esperando, y un producto se propone

Tres cosas entraron juntas y conviene leerlas juntas, porque las tres responden
a la misma pregunta: **quien puede meter algo al sitio sin que nadie lo mire.**

### La oferta ya no nace vendiendo

Antes, cualquiera que publicara una oferta la tenia a la venta en el acto. Ahora
la oferta de un vendedor normal nace `pendiente` y no circula hasta que la tienda
la aprueba. La de la tienda -- y la de un admin, que el backend trata igual -- sigue
naciendo `activa`: la tienda es la autoridad y no tiene a quien pedirle permiso.

Se guardan **tres cosas**, y ninguna sobra:

| | Que responde | Que le pasa despues |
|---|---|---|
| `id_estado_oferta` | en que situacion esta AHORA | se pierde en cuanto cambia |
| `fecha_aprobacion` | si alguna vez se aprobo, y cuando | no cambia nunca mas |
| `id_usuario_aprobo` | **quien** la dejo pasar | no cambia nunca mas |

La tercera sigue la convencion que el proyecto ya usa en `Precio Historial` y en
`Stock Movimiento`: quien provoco el cambio se guarda aparte del dueno de la
cosa. Y su NULL dice algo distinto del NULL de la fecha: **la fecha en NULL
significa "sin aprobar"; el usuario en NULL significa "no consta quien"**, que es
el caso normal de las ofertas de la tienda -- nacen aprobadas sin que nadie las
revise. En el conjunto de datos son 350 aprobadas por la tienda y 202 nacidas
aprobadas sin revisor.

Por eso esta columna **no** lleva un CHECK que la empareje con la fecha, aunque
`Propuesta Producto` si lo lleva: alli las dos van siempre juntas, y aqui
prohibirian el caso mas comun.

Una oferta aprobada que despues se pausa ya no dice por ningun lado que alguna
vez paso por revision, y sin ese dato el vendedor no podria volver a activarla
sin pedir permiso otra vez. Es la misma regla de siempre: la fila viva lleva
estado, el hecho historico va aparte.

**Y hay una invariante que ninguna restriccion declarativa puede sostener:** una
oferta `activa` o `pausada` tiene que tener `fecha_aprobacion`, porque a esos dos
estados no se llega sin el visto bueno. Como `CHECK` no se puede escribir -- una
restriccion no admite subconsultas, y meter el `id_estado_oferta` a mano ahi
dentro es justamente el id escrito a mano que el proyecto prohibe.

Con un trigger SI se podria, y conviene decir por que no se hizo en vez de dar a
entender que era imposible: `oferta` ya lleva dos triggers de este proyecto, asi
que el camino existe. Se dejo fuera porque el que decide sobre esta regla es el
backend -- es el que sabe si quien publica es la tienda o un vendedor -- y meter
un segundo guardian en la base que pueda contradecirlo aparta la regla de donde
se decide. Queda anotado como la alternativa si algun dia hace falta cerrarla
desde abajo.

Lo que si la vigila es el conjunto de datos, que la comprueba al cargar: si
alguna vez se siembra una oferta activa sin aprobar, la migracion falla en vez de
dejar la base torcida.

El rechazo va en su propia tabla, `Rechazo Oferta`, y no en dos columnas de
`Oferta`. El motivo es que **un rechazo se repite**: el vendedor corrige el
precio, la oferta vuelve a `pendiente`, y se le puede volver a rechazar. Con
columnas, el segundo rechazo pisaria al primero y se perderia la historia justo
cuando empieza a ser interesante. Es la misma regla que ya siguen
`Precio Historial` y `Stock Movimiento`: lo que pasa varias veces va en filas.

### Un vendedor puede proponer una entrada del catalogo

Crear productos era solo de la tienda, para que dos vendedores no subieran la
misma laptop dos veces. Lo que se abre es la **propuesta**, no la edicion: el
vendedor crea el producto, nace `en_revision` y no circula; la tienda lo aprueba
(pasa a `activo`) o lo rechaza con un motivo. Editar el catalogo compartido sigue
siendo de la tienda.

`Propuesta Producto` guarda quien propuso, quien aprobo y cuando. Su tabla gemela
`Rechazo Producto` guarda los motivos, por la misma razon que `Rechazo Oferta`.

**Y los dos estados nuevos no se cuelan al catalogo publico** -- ni estos ni
ninguno que se agregue despues. La busqueda y la ficha filtran por **lista
blanca**: solo `activo` pasa. Un estado nuevo queda oculto por defecto en vez de
visible por defecto, que es la unica forma de que nadie tenga que acordarse de
excluirlo.

### La direccion llega hasta la puerta

`Direcciones` llegaba hasta la ciudad. Con "Guatemala, Guatemala, Guatemala" se
sabe el punto del mapa pero no la casa, asi que un pedido no se podia entregar.

Se agrego `direccion_exacta`, **una sola linea de texto** y no cuatro columnas.
Una direccion guatemalteca no se deja partir sin pelear: *"5a. Avenida Norte 22,
frente al Arco de Santa Catalina"* y *"6a. Avenida 9-18, Zona 10, Edificio Vista
Real, Nivel 3"* no tienen la misma forma. Cuatro columnas fijas obligarian a
inventar una regla que la mitad de las direcciones no cumple, y acabarian siendo
el antipatron de columnas mayormente nulas que critica el enunciado. Ademas el
unico que lee este dato es quien tiene que llegar a la puerta: no se filtra ni se
agrupa por el, se imprime en la etiqueta y se lee.

Va en `Direcciones` **y** en `Direccion Historial`, igual que las otras cuatro. No
es duplicar: el pedido apunta al historial, no a la fila viva, y si la calle solo
viviera en la fila viva, editarla cambiaria a donde dice que se mando un pedido de
hace tres meses.

Nace nullable a proposito. Las filas anteriores a la columna no tienen forma
honesta de rellenarse, y una direccion inventada se entrega mal sin que nadie se
entere. El backend si la exige al crear una nueva, y el conjunto de datos la trae
de nacimiento; cuando no quede ninguna en NULL se puede cerrar con un
`SET NOT NULL`.

---

## Registro de decisiones arquitectonicas

Las cuatro decisiones de modelado y tecnologia de la Entrega 1, en el formato que pide el
enunciado (seccion 5.3): contexto, alternativas consideradas, decision,
justificacion con criterios tecnicos, y consecuencias. Abajo, en las secciones
siguientes, esta el detalle largo de cada una.

Hay una quinta, **ADR-5 - Todo lo social se queda en PostgreSQL**, que es de la
Entrega 2 y por eso no vive aqui sino junto a lo que decide, en "La resena es del
VENDEDOR sobre un PRODUCTO". Es la tercera decision de **no** migrar del
documento.

Vale la pena leer antes el criterio 5.5 del propio enunciado: *"la
justificacion de mantener un componente en su forma relacional se evalua con el
mismo nivel de exigencia que la justificacion de una migracion"*. Por eso la
segunda es una decision de **no** migrar, y la cuarta es una decision de dejar en
PostgreSQL algo que nacia del catalogo documental; las dos estan argumentadas con
el mismo cuidado que la primera.

### ADR-1 - Migrar el catalogo de productos a MongoDB

| | |
|---|---|
| **Contexto** | Cada categoria necesita atributos distintos: los de una laptop no se parecen a los de una camisa. En el modelo relacional eso caia en `descripcion` como texto libre, y por lo tanto **no se podia filtrar por atributo**. Medido sobre el conjunto: ningun producto llena el 100% de lo que su categoria ofrece y el promedio esta en **59%**, asi que una tabla de columnas fijas quedaria mayormente nula. |
| **Alternativas consideradas** | (a) Dejarlo como estaba, con todo en `descripcion`: barato, pero renuncia a filtrar por atributo, que es una funcionalidad que el enunciado pide. (b) Entidad-atributo-valor en PostgreSQL: permite filtrar, pero cada consulta con dos atributos necesita un `JOIN` por atributo y el plan se degrada rapido. (c) `jsonb` en PostgreSQL: intermedio real, y honestamente viable. (d) Migrar a MongoDB. |
| **Decision** | (d). El catalogo -- productos, variantes, caracteristicas, imagenes e historial -- vive en MongoDB. Se descarto (c) porque el enunciado de esta entrega pide explicitamente una base documental y ejercitar su marco de agregacion y sus indices; con `jsonb` se resolveria el problema pero no el ejercicio. |
| **Justificacion** | **Patron de consulta:** el catalogo se lee entero y por producto, casi nunca por partes, que es exactamente la forma de un documento. **Escalabilidad:** los atributos se agregan sin migracion de esquema. **Costo operativo:** un motor mas que levantar y mantener, y dos backups en vez de uno. **Consistencia:** es lo que se paga, y va abajo. |
| **Consecuencias** | Se gana filtrar por atributo, una ficha sin `JOIN` y agregar caracteristicas sin tocar el esquema. Se pierde la integridad referencial entre las lineas de pedido y los productos: `pedido_producto.id_producto_mongo` **no es** una llave foranea y no puede serlo, asi que ese enlace lo sostiene la aplicacion. Y aparece un ETL que hay que mantener. |

### ADR-2 - NO migrar las ofertas: se quedan en PostgreSQL

| | |
|---|---|
| **Contexto** | Al volverse multi-vendedor, quien vende, a que precio y con cuantas unidades dejo de ser del producto y paso a ser una fila de `oferta`. La pregunta es si esa fila se va con el catalogo a MongoDB o se queda. |
| **Alternativas consideradas** | (a) Embeberlas dentro del documento del producto. (b) Coleccion propia en MongoDB. (c) Dejarlas en PostgreSQL. |
| **Decision** | (c). Ni siquiera tienen coleccion en la base documental. Lo unico que viaja son cinco numeros ya calculados (`precio_tienda`, `precio_desde`, `stock_tienda`, `stock_total`, `total_ofertas`), para que la lista del catalogo se pinte sin salir de Mongo. |
| **Justificacion** | **Consistencia, y es el criterio que decide:** el descuento de inventario tiene que ser atomico y no vender dos veces la ultima unidad. Eso lo sostiene un `SELECT ... FOR UPDATE` dentro de `comprar_pedido()`; medido, cero sobreventas y cero descuadres sobre 555 ofertas. **Tasa de cambio:** precio, stock y estado cambian en cada venta, y una copia en la base documental habria que sostenerla al dia en dos sitios. **Patron de consulta:** embeberlas ademas seria peor, porque Mongo reescribe el documento entero en cada actualizacion -- comprar una camisa reescribiria su catalogo completo, y dos vendedores vendiendo a la vez pelearian por el mismo documento. **Volumen:** NO es el motivo; un documento aguanta 16 MB y ningun producto va a tener tantos vendedores. |
| **Consecuencias** | La ficha de un producto necesita dos consultas, una a cada base -- pero es una sola consulta indexada y ya se pagaba. Los cinco numeros calculados son una copia y hay que recalcularlos cada vez que una oferta cambia de precio, se quede sin unidades o se pause; si no, la tarjeta dice un precio y la ficha otro. Ese recalculo esta en `recalcularCamposCalculados()` y es deuda asumida a conciencia. |

### ADR-3 - Las imagenes, embebidas dentro de su variante

| | |
|---|---|
| **Contexto** | Cada variante tiene sus fotos. En el relacional eran dos tablas, `imagen_producto` y su pivote con la variante. |
| **Alternativas consideradas** | (a) Coleccion aparte en MongoDB, referenciada. (b) Embebidas en el producto. (c) Embebidas en la variante. |
| **Decision** | (c). Un arreglo de URLs dentro de cada variante. |
| **Justificacion** | **Frecuencia de acceso conjunto:** no existe ninguna pantalla que pida una imagen sin su variante. **Volumen:** son URLs, no archivos, y son pocas y acotadas. **Tasa de cambio:** cambian al ritmo del catalogo, que es lento. Se eligio (c) sobre (b) porque la foto es de la variante -- la camisa azul y la blanca no comparten imagen. |
| **Consecuencias** | Desaparece la columna `numero_orden`: en un arreglo la posicion **es** el orden, y guardarlo aparte seria un dato duplicado que se puede desincronizar. A cambio, reordenar las fotos obliga a reescribir el arreglo, que es exactamente la operacion que uno quiere ahi. |

### ADR-4 - Quien propuso un producto se guarda en PostgreSQL, no en el documento

| | |
|---|---|
| **Contexto** | El giro multi-vendedor quito `productos.id_usuario` a proposito: un producto describe una cosa del mundo y no es de nadie. Al abrir la creacion del catalogo a los vendedores hace falta saber **quien propuso** cada entrada -- para avisarle del rechazo y para dejarle re-enviar la suya -- y eso parece devolver el vinculo usuario-producto que se habia eliminado. |
| **Alternativas consideradas** | (a) Un campo de proponente dentro del documento del producto en MongoDB. (b) Devolver `id_usuario` a la entidad del producto. (c) Una tabla pivote en PostgreSQL, fuera del documento. (d) No guardar al proponente y que la tienda avise por fuera. |
| **Decision** | (c). `Propuesta Producto` en PostgreSQL, apuntando al catalogo por `id_producto_mongo` y sin llave foranea, igual que `Oferta` y `Pedido / producto`. |
| **Justificacion** | **Integridad referencial, y es el criterio que decide:** el proponente y el aprobador son dos llaves foraneas contra `usuarios`, y PostgreSQL las garantiza. En el documento serian dos numeros sueltos que nada impide que apunten a una cuenta que no existe. **Patron de consulta:** la cola de revision es "lo que falta por aprobar, lo mas viejo primero" -- un filtro por nulidad mas un orden por fecha sobre TODAS las propuestas, que es un indice parcial en el relacional y un recorrido de la coleccion entera en el documental, donde ademas cada producto solo sabe de si mismo. **Volumen:** los rechazos crecen sin techo por propuesta, y embebidos harian que el documento del producto engordara para todos los que solo querian el precio. Se descarto (a) y (b) porque reintroducen la propiedad del producto por la puerta de atras. **Lo que este ADR NO alega es tasa de cambio:** el estado del producto vive en el documento y el tramite lo reescribe igual en cada paso, asi que sacar la propuesta de Mongo no ahorra ni una reescritura. |
| **Consecuencias** | Se paga que un solo tramite queda repartido entre dos bases: el estado vive en el documento y la atribucion en el relacional, sin transaccion que las abarque, asi que sostener el flujo es trabajo de la aplicacion. **La propuesta no tiene estado propio a proposito** -- el suyo es el del producto -- porque darselo crearia dos verdades sobre lo mismo y habria que mantenerlas sincronizadas (ver "Los historiales no llevan estado", donde se explica por que esta tabla es la excepcion de esa regla). Y hay que decirlo claro para que no se lea como una contradiccion: **esto es atribucion, no propiedad.** La fila no da ningun derecho -- en cuanto el producto es `activo` cualquier vendedor puede ofertarlo, incluido o no el que lo propuso, y el proponente no puede editarlo ni bloquearlo. Es la misma figura que `Pedido / producto`, que guarda a quien se le compro ese dia sin convertir al comprador en dueno de nada. |

---

## El catalogo se mudo a MongoDB

Los productos, sus variantes, sus caracteristicas y su historial viven en
MongoDB.

**Y viven ahi de verdad: la migracion esta terminada, no es una copia que se
sostiene en dos sitios.** Conviene decirlo con precision porque es la decision
de la entrega, y aqui antes decia lo contrario ("PostgreSQL sigue siendo el
dueno"), que dejo de ser cierto y no se corrigio a tiempo:

- Las tablas `productos`, `productos_variantes` y `productos_historial` de
  PostgreSQL son el **origen** de la migracion. De ahi salio el conjunto de
  datos de prueba, y de ahi lo sigue leyendo el ETL de `etl/` para poder
  reconstruir MongoDB desde cero cuando haga falta.
- Pero la aplicacion **ya no escribe ahi**. `POST /vendedor/productos` y
  `PATCH /vendedor/productos/:id` tocan MongoDB y nada mas -- el propio
  servicio lo dice: *"los productos ya no se registran en PostgreSQL (las
  migraciones de productos fueron solo para el ETL que cargo los datos de
  prueba)"*.
- Se nota contandolos. Hoy: **102 filas en `productos` de PostgreSQL y 105
  documentos en MongoDB**. Los tres de diferencia se crearon desde el panel y
  no tienen fila del otro lado. La diferencia no es un desajuste que haya que
  arreglar: es la prueba de que la migracion se completo.

De ahi salen las dos reglas que gobiernan el ETL, y que estan explicadas en
`etl/README.md`: solo manda sobre **su tramo** (del id 1 al mas alto que trajo
de PostgreSQL) y ahi si reemplaza el documento entero; lo que nacio en Mongo
por encima de ese tope ni lo toca ni lo cuenta.

Los id que viven en Mongo llevan el sufijo **`_mongo`** en la linea del pedido.
**No son llaves foraneas y no pueden serlo**: PostgreSQL no puede garantizar
integridad referencial contra otra base. El sufijo esta para que quien lea la
tabla lo sepa de un vistazo y no busque una FK que no existe. El enlace lo
sostiene la aplicacion.

Se guardan los **dos** id, producto y variante, no solo el de la variante: en
Mongo las variantes van embebidas dentro del producto y no hay indice unico
sobre `variantes.id_producto_variante`. El par si es inequivoco.

### Que se embebe y que se referencia

Es la decision de modelado de la Entrega 1, y se contesta distinto en cada caso
porque los casos son distintos. Los tres criterios son los del enunciado:
frecuencia de acceso conjunto, volumen y tasa de cambio.

**La categoria: embebida.** Se lee siempre con el producto, son tres campos y
casi nunca cambia. Del padre solo el nombre, para poder ensenar
"Electronica > Laptops" sin una segunda consulta.

**Las variantes y las caracteristicas: embebidas.** No se consultan solas, son
pocas y cambian al ritmo del catalogo, que es lento.

**Las imagenes: embebidas dentro de su variante.** Cuelgan de ella y no del
producto. `numero_orden` se gasta al ordenarlas: en un arreglo la posicion ya es
el orden.

**Las ofertas: NO se migran.** Se quedan en `oferta`, en PostgreSQL, y ni
siquiera tienen coleccion propia en la base documental. El motivo **no es el
volumen**: un documento de Mongo aguanta 16 MB y ningun producto va a tener
tantos vendedores. Son dos, y el primero pesa mas que el segundo:

> **Precio, stock y estado cambian en cada venta.** Copiarlos a la base
> documental obligaria a sostenerlos al dia en dos bases a la vez, y ese es
> justo el riesgo de inconsistencia que el proyecto entero quiere evitar.
> PostgreSQL es donde se decide si alcanza para vender, dentro de la
> transaccion; una segunda copia que se puede desfasar solo agrega formas de
> mentir.
>
> **Y embeberlas dentro del producto seria peor.** Mongo reescribe el documento
> entero en cada actualizacion, asi que comprar una camisa reescribiria el
> documento completo de la camisa: sus variantes, sus caracteristicas y sus
> imagenes. Dos vendedores vendiendo a la vez pelearian por el mismo documento,
> que es lo contrario de lo que pide la Entrega 2 con la venta de unidades
> limitadas bajo concurrencia.

La ficha de un producto, que si necesita las ofertas de verdad, las pide a
PostgreSQL con una sola consulta indexada. Es un cruce entre las dos bases que
resuelve la aplicacion, no una llave foranea -- y eso es exactamente lo que la
entrega pide documentar.

**Las resenas: REFERENCIADAS.** Ya estan construidas (`migrations/011_resenas.sql`,
tablas `resena`, `comentario` y `likes`); aqui decia "todavia no" y la decision
que se argumenta abajo es la que efectivamente se implemento.

Van **fuera del documento del producto**, en `resena` de PostgreSQL. Los tres
criterios, uno por uno:

**Frecuencia de acceso conjunto: baja, y esa es la trampa.** Parece que si --
uno piensa en la ficha del producto, que las ensena. Pero la ficha es una
pantalla de las dos que leen el catalogo, y la otra, la LISTA, es la que se pide
todo el tiempo y no las necesita para nada: una tarjeta ensena foto, nombre y
precio. Embeberlas haria que cada tanda de 20 productos arrastrara las resenas
de los 20, para pintar cero. Y ni siquiera la ficha las quiere enteras: las
quiere paginadas, diez a la vez, que es justo lo que un arreglo embebido no
sabe hacer sin traerse el arreglo completo.

**Volumen: no tienen techo, y este es el criterio que decide.** Es la diferencia
de fondo con las variantes y las caracteristicas, que si van embebidas: un
producto tiene dos o tres variantes y ocho caracteristicas, y ese numero **esta
acotado por el modelo**. Las resenas crecen mientras el producto se venda, sin
limite. Mongo tiene un tope duro de 16 MB por documento, pero el problema
aparece mucho antes: el documento se hace grande para TODOS los que lo leen,
incluido quien solo queria el precio.

**Tasa de cambio: baja por resena, alta por producto.** Una resena se escribe
una vez y casi nunca se edita, y eso, aislado, favoreceria embeber. Pero lo que
importa no es cuanto cambia una resena: es cuantas veces cambia el DOCUMENTO que
las contendria. Mongo reescribe el documento entero en cada actualizacion, asi
que cada resena nueva reescribiria el producto completo -- sus variantes, sus
imagenes y sus caracteristicas -- y dos personas resenando a la vez pelearian
por el mismo documento. Es exactamente el argumento que ya descarto embeber las
ofertas.

**Y hay un cuarto motivo, propio de este modelo:** la resena califica a un
**vendedor** -- `resena.id_usuario_vendedor`, una llave foranea a `usuarios` --
y los usuarios viven en PostgreSQL. Embeberla en el documento del producto
dejaria la calificacion de una cuenta guardada dentro de la ficha de una cosa
que no es suya, y con las dos puntas del "A califica a B" repartidas entre dos
bases.

**Lo que se paga:** la ficha necesita una consulta mas para traerlas. Es un
costo que ya estaba pagado: la ficha **ya** hace una segunda consulta a
PostgreSQL para las ofertas, asi que las resenas viajan en esa misma ida y no
agregan un viaje.

**Y lo que se gana de cara a lo que viene:** la Entrega 2 pide detectar
*"conjuntos de cuentas que se califican entre si de forma reiterada sobre los
mismos productos"*. Eso es recorrer relaciones entre cuentas, no leer un
documento; con las resenas sueltas y apuntando a las dos cuentas y al producto,
ese camino queda abierto -- embebidas dentro del producto, habria que deshacerlo
primero. Es lo que despues permitio proyectar todo esto a Neo4j sin cambiar el
modelo relacional (`neo4j/README.md`).

**El caso simetrico, para que se vea que la pregunta se contesta por caso y no
por costumbre:** si algun dia hiciera falta llevar las ofertas a Mongo, el
vendedor iria **embebido dentro de cada una**. Son cuatro campos, se leen
siempre con ella ("Vendido por Carlos Ramirez") y casi nunca cambian. La misma
pregunta, respuesta contraria.

---

**Las tres respuestas juntas**, que es como las pide el enunciado:

| Caso | Decision | El criterio que la decide |
|---|---|---|
| Imagenes | **embebidas** en su variante | se leen siempre con ella, son pocas y no cambian |
| Producto y vendedor | **referenciado** (la oferta se queda en PostgreSQL) | precio, stock y estado cambian en cada venta |
| Resenas | **referenciadas** | volumen sin techo, y cada una reescribiria el producto entero |

Y como la **lista** del catalogo si necesita un precio y saber si hay
existencias en cada tarjeta, el producto lleva cinco numeros calculados
(aqui decia "cuatro" y la tabla de abajo siempre listo cinco):

| Campo | Que es |
|---|---|
| `precio_tienda` | el precio de la tienda, que es el que se **ensena** |
| `precio_desde` | el mas barato al que se ofrece, de cualquier vendedor |
| `stock_tienda` | unidades de la tienda |
| `stock_total` | unidades entre todos los vendedores activos |
| `total_ofertas` | cuantos vendedores lo tienen activo |

**Por que hay dos precios y no uno.** La tarjeta ensena el de la tienda, que es
la regla del profesor. Pero el FILTRO del buscador usa `precio_desde`: quien
busca "hasta Q4000" quiere lo que puede pagar con eso, y en **59 de los 102**
productos del conjunto hay alguien vendiendolo mas barato que la tienda -- mas
de la mitad. Con el filtro sobre `precio_tienda` esos quedaban fuera de la
busqueda aunque si le sirvieran. Es un fallo que solo se ve buscando, no
leyendo el modelo.

```sql
-- los productos donde alguien vende mas barato que la tienda
-- (precio final, con el descuento de la migracion 020; o.precio es el de lista)
WITH t AS (SELECT id_usuario FROM usuarios WHERE correo_electronico = 'tienda@mesh.com')
SELECT count(*) FROM (
  SELECT o.id_producto_mongo,
         min(ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2))
           FILTER (WHERE o.id_usuario = (SELECT id_usuario FROM t)) AS precio_tienda,
         min(ROUND(o.precio * (1 - COALESCE(o.porcentaje_descuento, 0) / 100), 2)) AS precio_desde
  FROM oferta o JOIN estado_oferta eo USING (id_estado_oferta)
  WHERE eo.estado_oferta_nombre = 'activa'
  GROUP BY 1
) x WHERE precio_desde < precio_tienda;
```

Y `precio_desde` **no mira el stock**, a proposito: si lo mirara, un rango de
precio estaria filtrando ademas por disponibilidad sin que nadie lo pida, y para
eso ya estan los dos campos de stock. Cada filtro contesta una pregunta y se
combinan.

Los tres primeros van tambien dentro de cada variante. **En el padre los dos de
stock son SUMAS** de sus variantes, porque la tarjeta ensena un producto y no una
variante. Y los dos cuentan **solo ofertas activas**: una pausada tiene unidades
y no se puede comprar, asi que contarla haria que el filtro de disponibilidad
mintiera.

Sin ellos no se puede filtrar por disponibilidad sin consultar la coleccion de
ofertas una vez por tarjeta, que es justo lo que se queria evitar.

Son una **copia** y hay que recalcularlos cuando una oferta cambie de precio, se
quede sin unidades o se pause: si no, la tarjeta va a decir un precio y la ficha
otro.

**Y hay un caso que la pantalla tiene que decidir:** `stock_tienda = 0` con
`stock_total > 0` **no es agotado**. La tienda no tiene, pero otro vendedor si.
En el conjunto de datos pasa en **18 de las 202 variantes**, a proposito: si la
tienda tuviera existencias de todo, el filtro devolveria el catalogo entero
siempre y nadie sabria si funciona. **Agotadas de verdad** (`stock_total = 0`)
son **6**, que es un caso distinto y se pinta distinto.

> Aqui decia "6 variantes" para el primer caso, y el 6 era el numero del
> SEGUNDO: se habian mezclado las dos cifras. Se remidieron las dos el
> 2026-08-30 contra el catalogo recien cargado, con la definicion literal del
> ETL (por variante, solo ofertas activas). Se cuentan asi:
>
> ```js
> db.productos.aggregate([{ $unwind: "$variantes" }, { $group: { _id: null,
>   tiendaCeroOtroSi: { $sum: { $cond: [ { $and: [
>       { $eq: ["$variantes.stock_tienda", 0] },
>       { $gt: ["$variantes.stock_total", 0] } ] }, 1, 0 ] } },
>   agotadasDeVerdad: { $sum: { $cond: [
>       { $eq: ["$variantes.stock_total", 0] }, 1, 0 ] } } } }])
> ```

### Que se puede reconstruir y que no

| Pregunta | Se contesta desde |
|---|---|
| nombre, descripcion y categoria de un producto ese dia | eventos de MongoDB |
| a como estaba una oferta ese dia | `Precio Historial`, en PostgreSQL |
| cuantas unidades habia ese dia | `Stock Movimiento`, en PostgreSQL |

**El precio cambio de lado, y hay que decirlo.** El enunciado pide reconstruir
"precio, descripcion y disponibilidad" desde la base documental. Al volverse
multi-vendedor, un producto **dejo de tener un precio**: tiene tantos como
vendedores, y cada uno es de su oferta. Por eso su historia se quedo en
PostgreSQL. No es un olvido; es la consecuencia directa del cambio de modelo.

**La disponibilidad se lee como unidades disponibles**, y se reconstruye con el
kardex. Es una de las dos lecturas posibles de la palabra; la otra ("estaba
publicada o pausada") no se guarda, por la regla de que los historiales no
llevan estado.

---

## La resena es del VENDEDOR sobre un PRODUCTO, no de la oferta

**Esto cambio, y hay que leerlo con cuidado porque va al informe: aqui se
defendio lo contrario durante toda la Entrega 1.** La version anterior de esta
seccion decia "la resena cuelga de `Oferta`". Ya no. Vive en
`migrations/011_resenas.sql` y cuelga de dos cosas a la vez:

```
resena
  id_usuario           quien califica       -> usuarios   (FK)
  id_usuario_vendedor  a quien califica     -> usuarios   (FK)
  id_producto_mongo    sobre que producto   -> MongoDB, SIN FK
  calificacion         1..5
  id_comentario        la raiz del hilo     -> comentario (FK, UNIQUE)
```

**El motivo original se conserva entero, y ademas se acorta.** La razon por la
que la resena colgaba de `Oferta` era que "A califica a B" fuera un camino real
entre cuentas, y no un promedio sobre un producto que no es de nadie. Ese motivo
sigue siendo bueno y no se abandona: `id_usuario_vendedor` lo cumple mejor.
Antes eran dos saltos (`resena -> oferta -> usuario`); ahora es **uno**, y ni
siquiera es un salto: es una columna.

**Lo que se descarto fue el vehiculo, no el argumento.** `oferta` es unica por
(usuario, producto, **variante**). Colgar la resena de ahi no la deja sobre
"Carlos me vendio bien esta laptop" sino sobre "Carlos me vendio bien la laptop,
version negra de 14 pulgadas". Un vendedor con tres variantes del mismo producto
termina con sus resenas repartidas en tres filas que el modelo trata como cosas
distintas, y su nota pasa a ser un promedio de promedios. **Nadie resena una
variante.** Con `id_producto_mongo` la resena queda donde la persona la escribio:
sobre el producto.

Cambiarlo costo cero porque las tablas todavia no existian. En tres semanas
costaba migracion, ETL y reescribir el informe.

**Lo que se paga, dicho de frente.** Con `id_oferta` la base garantizaba que la
resena apuntaba a una oferta real. Con `id_producto_mongo` no puede: el catalogo
vive en MongoDB. Que ese vendedor venda ese producto pasa a ser comprobacion de
la aplicacion. Es el **mismo precio que `oferta` ya paga** desde la 005 y ya
estaba escrito arriba -- no es una excepcion nueva, es la regla de la casa
aplicada otra vez. Y lo que si queda garantizado es la mitad que importa para la
Entrega 2: las dos cuentas son cuentas de verdad, con llave foranea, porque
viven aqui.

Tambien se pierde el ascenso `Oferta -> Productos Variantes -> Productos` para
armar la nota de un producto, y a cambio se gana: la nota del producto es ahora
un `avg(calificacion)` directo sobre `resena`, sin promediar promedios. Lo que
NO cambia es la consecuencia que ya estaba anotada: una queja de envio ("llego
tarde, mal empacado") es del vendedor y cuenta igual para la nota del producto.
Amazon las separa; aqui van juntas.

### Por que NO hay llave foranea a `pedido`

No se exige haber comprado para resenar, y es deliberado.

La Entrega 2 pide senalar cuentas que se califican entre si de forma anomala. La
resena **sin compra detras** es la senal mas fuerte que existe de eso. Exigir la
compra la borraria del modelo: el fraude mas obvio dejaria de poder
representarse, y la consulta de varios saltos perderia su hallazgo mas util.

Es la diferencia entre un modelo que **impide** el fraude y uno que lo puede
**observar**. Aqui hace falta el segundo.

**Ojo con lo que esto dice y lo que no, porque es facil leerlo al reves.** Que
el ESQUEMA no exija la compra no significa que el SISTEMA la regale: el backend
si la exige, en la aplicacion (`exigirCompraPagada`), y ademas al mismo vendedor.
Son dos capas distintas a proposito -- una regla de aplicacion se cambia con un
`if`, una llave foranea no se puede quitar sin migrar la base -- y la de arriba
se puede levantar el dia que haga falta representar el fraude.

Y aqui hay que corregir lo que esta seccion afirmaba hasta el 2026-08-30. Decia
que **83 de las 86 resenas no tenian un pedido detras**, y lo presentaba como la
prueba de que el modelo puede observar el fraude. Eso ya no es cierto, y lo que
es peor: **nunca fue una virtud, era una contradiccion**. El conjunto de datos
describia resenas que el propio sistema habria rechazado al escribirlas, y la
consecuencia visible era que el boton "Escribir una resena" no aparecia casi en
ningun producto.

> **Ojo con el 83 y el 84**, que aparecen los dos en la documentacion vieja y
> parecen contradecirse: no lo son, cuentan cosas distintas. El **83** salia de
> la consulta que estaba escrita aqui, que solo miraba `(comprador, producto)`.
> El **84** sale de la condicion que el backend exige de verdad, que ademas pide
> que la compra sea **a ese vendedor**. La condicion mas estricta encuentra una
> resena huerfana mas, como tiene que ser. La cifra que importa es la segunda,
> porque es la que decide si el boton aparece.

Hoy la semilla las respalda:

```sql
-- Resenas SIN una compra pagada a ese vendedor detras.
-- Los JOIN son los mismos de exigirCompraPagada, a proposito: contarlo de otra
-- forma seria medir algo distinto de lo que el sistema exige.
SELECT count(*) FROM resena r
WHERE NOT EXISTS (
  SELECT 1 FROM pedido pe
  JOIN pago             pg  ON pg.id_pedido           = pe.id_pedido
  JOIN estado_pago      epa ON epa.id_estado_pago     = pg.id_estado_pago
  JOIN estado_pedido    epe ON epe.id_estado_pedido   = pe.id_estado_pedido
  JOIN pedido_producto  pp  ON pp.id_pedido           = pe.id_pedido
  JOIN precio_historial ph  ON ph.id_precio_historial = pp.id_precio_historial
  JOIN oferta           o   ON o.id_oferta            = ph.id_oferta
  WHERE pe.id_usuario = r.id_usuario
    AND o.id_usuario  = r.id_usuario_vendedor
    AND pp.id_producto_mongo = r.id_producto_mongo
    AND epa.estado_pago_nombre    = 'pagado'
    AND epe.estado_pedido_nombre <> 'cancelado');
-- 0   (antes de arreglar la semilla: 84)
```

Es la comprobacion **10** del `DO` final de `001_catalogo.sql`, asi que la
migracion entera falla si alguna vez vuelve a haber una.

**Entonces, sin resenas huerfanas, como se demuestra la senal?** Sembrando el
anillo, que es donde tiene que vivir: `bash neo4j/correr_fraude.sh` lo mete en
**Neo4j** con cuentas de id negativo y etiqueta `:Prueba`, corre las cinco
consultas y lo borra. Que no toque PostgreSQL no es comodidad -- es que el
grafo es una proyeccion y se puede ensuciar sin mentirle a la fuente de verdad.

### Por que `comentario` lleva `id_usuario` aunque el diagrama no lo tenga

Es un **hueco del diagrama**, no una licencia que nos tomamos.

Sin esa columna una **respuesta** no tiene autor. La raiz de una resena si
podria sacarlo de `resena.id_usuario`, pero una respuesta no cuelga de ninguna
resena -- cuelga de otro comentario -- y se quedaria sin forma de saber quien la
escribio. No se podria ni pintar "Carlos respondio: ..." ni contar cuentas que se
comentan entre si, que es una de las senales de la Entrega 2. En el conjunto de
datos hay 28 respuestas sobre 90 raices, o sea 118 comentarios en total.

Para la raiz queda repetido con `resena.id_usuario`. Es redundancia real y se
acepta a sabiendas: la alternativa era dejar las respuestas sin autor. La
coherencia entre las dos la comprueba el conjunto de datos al cargar.

Y el arbol vive en **una sola tabla** y no en dos porque una respuesta y el texto
de una resena son la misma cosa: alguien escribio algo. Partirlos obligaria a
tener dos tablas de `likes` o una referencia polimorfica -- y el like sobre la
RESENA es justo el que importa para detectar manipulacion.

La resena no lleva fecha propia: es el comentario raiz
(`id_comentario_padre` en NULL) y `comentario.fecha_publicacion` ya guarda
cuando. Seria una segunda verdad sobre lo mismo. `likes` si lleva
`fecha_creacion` porque no es un comentario y no tiene de donde heredarla -- y
ademas es el campo que hace posible detectar manipulacion: 40 likes en tres
minutos, o cuentas creadas el mismo dia dandose like entre si.

### ADR-5 - Todo lo social se queda en PostgreSQL

| | |
|---|---|
| **Contexto** | El catalogo ya se migro a MongoDB. Las resenas y sus comentarios son la parte que mas se lee de la ficha de un producto, y la pregunta obligada -- por el criterio 5.5 del enunciado, que exige justificar quedarse igual que justificar migrar -- es si tambien se van al documental. |
| **Alternativas consideradas** | (a) Embeberlas en el documento del producto en MongoDB. (b) Coleccion propia de resenas y comentarios en MongoDB. (c) Dejarlas en PostgreSQL. |
| **Decision** | (c). `resena`, `comentario` y `likes` en PostgreSQL. Ni embebidas ni con coleccion propia. |
| **Justificacion** | **Heterogeneidad de atributos, que es el criterio que trajo MongoDB a este sistema y aqui no aplica:** MongoDB entro por UNA razon -- los atributos cambian entre categorias de producto, y medido sobre el conjunto ningun producto llena el 100% de lo que su categoria ofrece (promedio 59%). Un comentario tiene siempre los mismos cuatro campos: autor, texto, fecha y padre. Heterogeneidad cero. Llevarlo al documental seria usarlo porque esta, no porque el dato lo pida. **Integridad referencial:** las dos puntas de "A califica a B" son llaves foraneas contra `usuarios`; en un documento serian dos numeros sueltos que nada impide que apunten a una cuenta que no existe -- el mismo argumento del ADR-4. **Patron de consulta:** la ficha las quiere paginadas, diez a la vez, que es justo lo que un arreglo embebido no sabe hacer sin traerse el arreglo completo. **Volumen:** no tienen techo, y cada resena nueva reescribiria el documento entero del producto (ver arriba). |
| **Consecuencias** | La ficha cruza dos bases, que es un costo ya pagado. Y la velocidad de lectura, que es la preocupacion real, se resuelve **sin cambiar la fuente de verdad**: con el contador denormalizado (`cantidad_likes` / `cantidad_dislikes`, sostenido por trigger) y con cache. Es lo que hacen los sistemas que tienen este problema de verdad -- TAO de Facebook es un cache de grafo delante de MySQL, no un reemplazo de MySQL. El cache le toca a Redis en la Entrega 2. |

**Y la velocidad no es una suposicion: se midio.** La consulta de la ficha -- las
diez resenas de un producto con su texto, su fecha, su autor y sus dos
contadores -- corre en **decimas de milisegundo**:

```sql
EXPLAIN (ANALYZE)
SELECT r.calificacion, c.comentario, c.fecha_publicacion,
       c.cantidad_likes, c.cantidad_dislikes, u.usuario
FROM resena r
JOIN comentario c ON c.id_comentario = r.id_comentario
JOIN usuarios   u ON u.id_usuario    = r.id_usuario
WHERE r.id_producto_mongo = 48
ORDER BY c.fecha_publicacion DESC
LIMIT 10;
```

Tres corridas de "un calentamiento mas tres medidas" dieron medianas de 0.219,
0.146 y 0.070 ms, y **las doce lecturas cayeron entre 0.068 y 0.485 ms**. La
primera consulta de cada sesion sube a unos pocos milisegundos y por eso no
cuenta: es el plan que se arma, no la consulta.

El milisegundo es ruidoso; el numero estable es el otro que imprime el plan:
`Buffers: shared hit=8`, ni una lectura de disco. Ocho paginas que ya estan en
memoria.

Y conviene mirar el plan de frente, porque dice algo que no se esperaba:
**PostgreSQL NO usa `idx_resena_producto` aqui, hace un `Seq Scan` sobre
`resena`.** No es un fallo del indice: con 86 filas la tabla entera cabe en una
sola pagina (`Buffers: shared hit=1` en ese nodo), asi que recorrerla sale mas
barato que entrar por el indice. El indice esta puesto para el tamano al que este
argumento importa, no para este. Y el argumento no depende de el: si a esta
escala la consulta ya es ruido comparada con la pantalla de al lado, cambiar de
motor por velocidad es optimizar lo que no cuesta.

Contra que se compara: `docs/frontend.md` mide, con el mismo metodo (mediana de
tres corridas en caliente), **188 ms para `GET /productos?limite=20`**, que es la
ruta que pinta la primera pantalla del catalogo. **Son tres ordenes de magnitud.**
Y no son cifras equivalentes, y por eso la comparacion vale: los 188 ms son una
ruta HTTP entera -- red, Nest, Mongo y serializacion de 40 KB -- y las decimas de
milisegundo son solo el motor relacional contestando. Aun asi, mover las resenas
a MongoDB para "que la ficha vaya mas rapido" estaria optimizando la parte que ni
en su peor lectura llega al 0.3% de lo que la pantalla de al lado ya paga sin
quejarse.

Los dos numeros se pueden volver a medir, y conviene hacerlo antes de citarlos:
el de arriba con el `EXPLAIN (ANALYZE)` de aqui, y el de los 188 ms con lo que
describe `docs/frontend.md`.

---

## Las alertas de fraude del login (migracion 016)

**Entraron la noche del 2026-09-10**, detras del codigo que las usa. El backend
cuenta en Redis tres senales en el propio camino del login, y cuando una cruza
su umbral deja una fila aqui:

```
fuerza_bruta_ip       8 fallos desde la misma IP en 60 s
fuerza_bruta_cuenta   5 fallos contra el mismo identificador en 60 s
multi_cuenta_ip       4 identificadores distintos desde la misma IP en 300 s
```

Son tres tablas:

```
tipo_alerta_fraude     que senal disparo la alerta      catalogo, 3 filas
estado_alerta_fraude   en que va la revision del admin  pendiente, revisada, descartada
alerta_fraude          la alerta
  id_tipo_alerta_fraude   -> tipo_alerta_fraude
  clave                   el ORIGEN de la senal: la IP, o el identificador tecleado
  id_usuario              la cuenta, solo en fuerza_bruta_cuenta y si existe
  detalle                 jsonb, la evidencia para un humano
  contador                cuantas veces se cruzo el umbral en esa ventana
  ventana_inicio          el minuto truncado de la deteccion
  id_estado_alerta_fraude -> estado_alerta_fraude
  id_usuario_reviso       el id REAL del admin, sin sustituir por la tienda
  fecha_revision, fecha_creacion, fecha_actualizacion
```

**No es un log.** Una fila aqui dice "esto merece que un admin lo mire", no
"esto paso". Cada intento, bueno o malo, vive en `eventos_autenticacion` de
MongoDB (mas abajo); aqui solo llega lo que cruzo un umbral.

**Las columnas son copia exacta del SQL de referencia del backend**
(`backend/elementos Generales/plan pendiente/fraude-login-eventos.sql`), y no
por comodidad: ese SQL ya se corrio a mano en alguna base, y ahi el
`CREATE TABLE IF NOT EXISTS` de la 016 se salta entero. Una columna o un
`CHECK` de mas existiria en unas bases y en otras no, sin que nadie se entere.
Lo que haya que cambiarle va en una migracion nueva, con un `ALTER` que llegue a
todas.

### Los catalogos van en tabla y no en un CHECK

Como cualquier otro catalogo del proyecto (`estado_oferta`, `estado_producto`,
`motivo_movimiento`). Un tipo nuevo, como el viaje imposible el dia que haya
geolocalizacion, es una fila en una migracion nueva, no rehacer la restriccion
de una tabla que se escribe en cada ataque. Y la alerta apunta a su tipo con una
llave foranea, que un texto con `CHECK` no tiene.

El precio es el de siempre, y aqui con una vuelta mas. El backend no consulta el
catalogo en cada login: **fija los ids en su codigo**, 1, 2 y 3, en
`models/alerta-fraude.ts`, igual que `ID_ROL_ADMIN`. La migracion no escribe
ningun id (es la regla de `migrations/README.md`): los pone la secuencia, en el
orden del `VALUES`. En una base limpia salen 1, 2 y 3, pero si no salieran, el
backend guardaria una `fuerza_bruta_ip` con el id de otro tipo **sin un solo
error**: la llave foranea se cumple, solo que apunta a la fila equivocada.

Por eso el final de la 016 es un candado: busca cada nombre y **falla la
migracion** si su id no es el que el backend espera. Los numeros aparecen ahi y
solo ahi, como comprobacion y nunca en un `INSERT`.

Y los catalogos se insertan con `WHERE NOT EXISTS`, no solo con
`ON CONFLICT DO NOTHING`. El segundo pide el `nextval` antes de descubrir el
choque y lo quema, y la 016 corre en cada arranque: cada arranque le sumaria
tres a la secuencia, y el cuarto tipo que se agregue un dia no saldria con el 4.

### La llave del UPSERT

```
UNIQUE (id_tipo_alerta_fraude, clave, ventana_inicio)
```

`ventana_inicio` es el minuto truncado de la deteccion. Con el tipo y la clave
forma la llave del `ON CONFLICT` del backend: varios cruces del umbral en el
mismo minuto suben `contador` en una sola fila en vez de duplicarla. Al minuto
siguiente nace otra, a proposito: una alerta que un admin ya reviso no se
reabre sola. Por lo mismo, el `UPSERT` no toca el estado en el choque.

**Es lo unico de la tabla que el backend no puede perder.** Su `ON CONFLICT`
necesita un indice unico sobre esas tres columnas exactas, y sin el, el `INSERT`
revienta con "there is no unique or exclusion constraint matching". El candado
de la 016 lo comprueba en `pg_index`, y no en `pg_constraint`, porque al
`ON CONFLICT` le sirve igual un `UNIQUE` que un `CREATE UNIQUE INDEX`.

Dos consecuencias del diseno del backend que conviene saber al leer la tabla,
y estan en `docs/BACKEND-PENDIENTE.md`: `clave` es `varchar(255)` y el
identificador no tiene tope, asi que uno mas largo hace fallar el `INSERT` y la
alerta se pierde; y el `ON CONFLICT` quema un id de la secuencia en cada choque,
asi que los ids saltan.

### El log de autenticacion se mudo a MongoDB, y `log_login` quedo congelado

Desde el 2026-09-10 el backend escribe cada intento de entrar en la coleccion
`eventos_autenticacion` de MongoDB, y ya no en `log_login` ni en `log_registro`.
Antes solo se guardaban los logins buenos; ahora se guarda tambien cada fallo,
con su motivo. La forma del documento esta en
`backend/src/models/evento-autenticacion.ts`:

```
tipo                     login | logout | registro
resultado                exito | fallo
motivo                   por que fallo, null si salio bien
id_usuario               null si no se puede atribuir
identificador_intentado  el correo o usuario tecleado, tal cual
ip, user_agent, huella_cliente
fecha
pendiente_elastic        true hasta que el worker lo copia a Elasticsearch
```

Solo se inserta. La unica escritura posterior es la del worker, que le quita
`pendiente_elastic` despues de copiarlo al indice `mesh_eventos_autenticacion`.
Y el backend la escribe sin esperar: si Mongo no contesta, el login sale igual
y ese evento se pierde. Para un login es lo correcto, porque no tiene por que
esperar los 3 s que tarda el driver en rendirse. Y por lo mismo esto es un log
y no una fuente de verdad: puede faltarle un evento sin que nada lo diga.

**`log_login` y `log_registro` no se borran.** Guardan el historico de antes del
cambio, y tienen llave foranea contra `usuarios`, que en Mongo no habria. Pero
quien las abra tiene que saber que ya no reciben filas, o va a sacar
conclusiones de una tabla congelada. Por eso la 016 lo dice en el `COMMENT` de
cada una, que es lo que ensenan `\d+` y pgAdmin.

La consecuencia que muerde: **la copia a ClickHouse sigue leyendo `log_login`**,
asi que desde el 2026-09-10 no recibe logueos nuevos. Ver `etl/README.md` y el
punto 16 de `docs/PENDIENTES.md`.

Los indices de la coleccion estan en `mongo/003_eventos_autenticacion.js`. Uno
es el que importa hoy: `eventos_pendientes_elastic`, `{fecha: 1}` parcial sobre
`pendiente_elastic: true`, que es exactamente la consulta del worker cada 5
segundos. Sin el, esa consulta era un COLLSCAN mas un SORT en memoria sobre una
coleccion que solo crece; con el sale IXSCAN y sin SORT, y el indice tiene el
tamano de la cola, no el del historico. Los otros cinco (por usuario, por IP,
por tipo y resultado, por identificador y por huella) los pide el plan del
backend y hoy no los usa ninguna ruta.

---

## Las reglas de descuento automatico (migracion 021)

`regla_descuento_automatico` guarda, por oferta, "si se venden
`umbral_unidades` en `ventana_minutos`, aplicar `porcentaje_descuento` durante
`duracion_segundos`", o abrir una venta relampago si `es_venta_relampago`.

- **Una por oferta.** `UNIQUE(id_oferta)`, y el backend convierte el choque en
  un 409. Por eso no es una columna mas de `oferta`: una oferta sin regla no
  tiene cinco columnas en NULL, simplemente no tiene fila.
- **Se va con su oferta.** `ON DELETE CASCADE`: una regla sin oferta no se
  refiere a nada.
- **Los CHECK solo descartan lo absurdo.** Enteros mayores que 0 y un
  porcentaje entre 0 y 100 sin incluirlos, el mismo de `oferta` en la 020. Los
  topes de negocio (1 a 90 %, una semana) viven en el backend.
- **La duracion no admite 0.** En la venta limitada 0 es "sin vencimiento", aqui
  la regla siempre tiene que apagarse sola.
- **`activa` en vez de borrar.** El backend no tiene ruta para borrar una regla,
  solo para pausarla.
- `fecha_actualizacion` la mueve el mismo `oferta_tocar_fecha()` de la 005.

~~Es solo configuracion. El proceso que mire ClickHouse y la dispare todavia no
existe en el backend.~~ Desde el 2026-09-25 existe:
DisparadorReglasAutomaticoService mira cada minuto las unidades vendidas en
ClickHouse y, si llegan al umbral, pone el descuento con `duracion_segundos`
de vencimiento. Lo quita el mismo worker que quita los descuentos manuales con
duracion (ver abajo, la clave de Redis). Si la duracion no pasa de la ventana,
la oferta parpadea: se apaga y las mismas ventas la vuelven a prender. El panel
lo avisa al escribir la regla.

## Las reglas de descuento por periodo (migracion 022)

`regla_descuento_periodo` es la otra forma de descuento automatico: por
calendario y no por ventas. Sale tal cual del SQL de referencia del companero
(`backend/elementos Generales/plan pendiente/reglas-descuento-periodos.sql`).

- **El rango es dia, mes y anio**, y lo que falta amplia la repeticion. Con
  anio pasa una vez; sin anio, cada anio; sin mes, cada mes. Los dos CHECK de
  tabla son esa cascada: los meses van juntos y no hay anio sin mes.
- **Varias por oferta**, a diferencia de la automatica, siempre que sus dias no
  se toquen. Eso no lo puede exigir un CHECK (no ve otras filas): lo vigila el
  backend y contesta 409.
- **Dos indices**, uno por oferta para el listado y uno PARCIAL de las activas,
  que son las unicas que preguntan el disparador y la exclusion.
- Mismo `ON DELETE CASCADE` y mismo `oferta_tocar_fecha()` que la 021.

El disparador (DisparadorReglasPeriodoService, cada 15 minutos) pone y quita
el descuento reusando las rutas de siempre, a nombre del vendedor dueno.

### Un descuento a la vez por oferta

Desde el 2026-09-24 las cuatro formas de poner un descuento se excluyen:
manual (con su venta relampago, que lo exige), regla automatica y regla por
periodo. Una regla pausada no cuenta. Vive en el backend
(`helpers/exclusion-mecanismos-descuento.ts`) y no en la base, porque "activa"
en el descuento manual solo lo sabe `oferta.porcentaje_descuento` y en las
reglas su columna `activa`: son tres tablas.

### Quien decide si un descuento sigue vivo (migracion 028)

`POST .../descuento` guarda cuando vence en `oferta.fecha_vencimiento_descuento`:
`now() + duracion_segundos`, o NULL si no se pidio duracion, que quiere decir
permanente. La venta relampago tiene la suya, `fecha_vencimiento_venta_limitada`.
Cada minuto el backend quita todo descuento que no este en venta relampago y
cuya fecha ya paso. **La verdad de "sigue vivo" esta en PostgreSQL.**

Hasta el 2026-09-26 estaba en Redis: una clave `mesh:oferta:<id>:descuento`
con `EXPIRE`, y el backend quitaba todo descuento cuya clave no existiera. Eso
tenia dos problemas. La semilla (`001_catalogo.sql`) pone sus descuentos directo
en `oferta`, sin clave, y `arrancar.ps1` tenia que sembrarlas en su paso 5b-2.
Y un Redis vaciado se llevaba para siempre tambien los descuentos permanentes.
Con la 028 (37ad2e6 de Jose David) la clave desaparecio y el paso 5b-2 solo
comprueba que los descuentos de la semilla nacieron permanentes.

Queda fuera a proposito: si Redis se vacia a media venta relampago, su
contador de stock (`mesh:oferta:<id>`) no se vuelve a sembrar y la venta queda
pausada hasta que venza o el vendedor la reabra. El descuento no se pierde.

## Los patrones B de resenas (migracion 023)

La 019 guardaba los anillos mutuo, ciclo y reiterado. La 023 deja guardar
tambien seis de los siete patrones B (`neo4j/consultas/B1..B7`) en la misma
`anillo_fraude`, sin tabla nueva. Sale del SQL de referencia del companero
(`anillos-fraude-familia-b.sql`).

- **Siete filas en `tipo_anillo_fraude`**, ids 4 a 10: cadena_abierta,
  satelites, persistente, anillo_en_el_tiempo, favor_devuelto, coordinados y
  reputacion_expres. El backend los fija como constantes y un candado al final
  de la migracion falla si un id no cuadra. `anillo_en_el_tiempo` (B.4) queda
  reservado: el backend no lo guarda.
- **La unicidad de `clave` pasa a `(id_tipo_anillo_fraude, clave)`.** Con la
  clave sola, dos patrones distintos sobre el mismo par de cuentas se
  pisaban. El backend ya escribe con ese `ON CONFLICT`, asi que sin la 023 el
  INSERT falla en una base nueva. mutuo, ciclo y reiterado siguen compartiendo
  fila porque el backend busca antes cualquiera de los tres.
- **En `coordinados` el vendedor no es sospechoso.** Son dos autores que
  califican lo mismo a la vez; las cuentas del caso son ellos dos. No cambia
  la tabla, lo resuelve la consulta que deriva las cuentas.

## Los historiales no llevan estado

Un historial solo se inserta, nunca se actualiza. El estado vive en la fila viva,
que si cambia.

La regla: si la fila se actualiza, lleva estado. Si solo se inserta, no. Por eso
`Oferta` lleva estado y `Precio Historial` no.

**Y hay una excepcion que conviene mirar de frente, porque parece romperla:**
`Propuesta Producto` es una fila viva -- se actualiza cuando alguien la aprueba -- y
**no tiene columna de estado**. No es un olvido. El estado de una propuesta es el
estado del PRODUCTO que propone (`en_revision`, `rechazado`, `activo`), y ese
vive en el documento de MongoDB. Darle un estado propio a la propuesta crearia
dos verdades sobre lo mismo, que es justo lo que la regla quiere evitar: la
propuesta podria decir "aprobada" mientras el producto sigue `en_revision`, y
nadie sabria cual manda.

Lo que si guarda es el HECHO de la aprobacion -- `fecha_aprobacion` e
`id_usuario_aprobo` -- que es lo que el estado pierde en cuanto cambia. La regla,
enunciada con mas precision: **el estado vive una sola vez, en la fila que
describe la cosa; los hechos historicos viven donde ocurrieron.**

Por lo mismo la fecha se llama `fecha_creacion` y no `fecha_actualizacion`: marca
desde cuando rige esa version. Con una sola fecha alcanza para reconstruir:

```sql
SELECT precio FROM precio_historial
WHERE id_oferta = 42
  AND fecha_creacion <= '2026-03-03'
ORDER BY fecha_creacion DESC
LIMIT 1;
```

Con un indice en `(id_oferta, fecha_creacion DESC)` la base no recorre nada:
entra al indice y lee una fila. No hace falta un booleano `es_vigente`, que
ademas seria derivable, el mismo problema por el que quitamos `pedidos.total`.

**`Oferta` es la excepcion y lleva TRES fechas**, porque es una fila viva:
`fecha_creacion` dice cuando nacio, `fecha_actualizacion` cuando se toco por
ultima vez, y `fecha_aprobacion` cuando la tienda le dio el visto bueno. La
segunda la mantiene un trigger y no la aplicacion: si dependiera de que cada
UPDATE se acuerde de ponerla, el dia que una ruta nueva no lo haga la fecha
miente sin dar ningun error.

La tercera merece su propia linea porque no es una fecha de auditoria como las
otras dos: es la unica que puede estar en NULL, y ese NULL significa algo --
**esta oferta nunca fue aprobada**. Es lo que separa una oferta que espera
revision de una que ya circula, y sobrevive a que despues se pause o se retire,
que es exactamente lo que el estado no sabe hacer.

---

## Un historial de producto que si sabe su categoria

`Productos Historial` guarda `id_categoria`, y es nuevo.

Sin esa columna, mover un producto de categoria **reescribia su pasado**: el
historial de enero contestaba con la categoria de hoy. En el conjunto de datos
se ve: el balon de futbol nacio mal clasificado en Fitness y se movio a Futbol
en abril, y reconstruirlo al 1 de mayo devuelve Fitness.

Apunta a la fila viva de `Categorias`, asi que si alguien **renombra** una
categoria la reconstruccion muestra el nombre nuevo. Se acepta a proposito: una
categoria se renombra cada nunca, y la tabla que guardaba sus versiones existia
solo por la comision, que ya no esta.

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

### Que tan disparejo quedo, medido

No basta con decir que los atributos varian: hay que ensenarlo. En el conjunto
de datos, **ningun producto llena el 100%** de lo que su categoria ofrece, y el
promedio esta en **59%**.

Eso fue deliberado. La primera version tenia las paletas hechas a la medida de
los productos, y casi todos las llenaban enteras: asi el modelo parece una tabla
de columnas fijas y desaparece justo el fenomeno que la entrega tiene que
ensenar. Se ensancharon con campos que un formulario si propone y casi nadie
llena.

```sql
SELECT round(100.0 * avg(llena::numeric / ofrece), 0) AS pct_promedio
FROM (
  SELECT (SELECT count(*) FROM categoria_caracteristica cc
           WHERE cc.id_categoria = p.id_categoria) AS ofrece,
         (SELECT count(DISTINCT pc.id_caracteristica) FROM producto_caracteristica pc
           WHERE pc.id_producto = p.id_producto) AS llena
  FROM productos p
) t;
```
