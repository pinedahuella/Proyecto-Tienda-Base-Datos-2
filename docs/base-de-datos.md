# Base de datos

Modelo relacional en PostgreSQL. **36 tablas construidas** de las 39 del
diagrama; faltan las tres de la parte social (comentario, resena y likes).

El catalogo de productos ya no vive solo aqui: se migro a MongoDB, y eso cambio
un par de decisiones de este modelo. Esta explicado abajo, en "El catalogo se
mudo a MongoDB".

El diagrama esta en `diagrama-general.png` de esta misma carpeta. El archivo
editable es `diagrama-general.drawio`, se abre en https://app.diagrams.net

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
`crear_pedido`, `agregar_linea`, `quitar_linea`, `comprar_pedido`,
`cancelar_pedido` y `reponer_stock`. Estan ahi y no en la aplicacion por dos
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
(`PedidosCompradorService.revisarCambiosAntesDeComprar`), con una consulta sin
bloqueo. Queda una ventana angosta: si alguien pausa o retira la oferta justo
entre ese chequeo y la llamada a `comprar_pedido`, la compra pasa igual -- el
stock sigue correcto (el `FOR UPDATE` no se salta), pero el estado no se
revalida dentro de la misma transaccion. Pendiente de decidir si vale la pena
cerrar esa ventana metiendo el chequeo de estado dentro de la funcion.

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
   `oferta.stock`. Medido sobre las 168 ofertas: **cero descuadres**.

Lo que lo consigue es una sola linea, el `SELECT ... FOR UPDATE` sobre la fila
de `Oferta` dentro de `comprar_pedido`. La segunda conexion se queda esperando
ahi hasta que la primera termina, y entonces lee el saldo ya descontado. Sin ese
bloqueo las dos leerian "queda 1" y las dos venderian.

Y por eso vive dentro de la funcion y no en el backend: cualquier ruta nueva que
descontara stock por su cuenta se lo saltaria.

---

## El catalogo se mudo a MongoDB

Los productos, sus variantes, sus caracteristicas y su historial se leen desde
MongoDB. PostgreSQL sigue siendo el dueno: el ETL de `etl/` extrae de aqui y
escribe alla, y cada documento se reemplaza entero.

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

**El caso simetrico, para que se vea que la pregunta se contesta por caso y no
por costumbre:** si algun dia hiciera falta llevar las ofertas a Mongo, el
vendedor iria **embebido dentro de cada una**. Son cuatro campos, se leen
siempre con ella ("Vendido por Carlos Ramirez") y casi nunca cambian. La misma
pregunta, respuesta contraria.

Y como la **lista** del catalogo si necesita un precio y saber si hay
existencias en cada tarjeta, el producto lleva cuatro numeros calculados:

| Campo | Que es |
|---|---|
| `precio_tienda` | el precio de la tienda, que es el que se **ensena** |
| `precio_desde` | el mas barato al que se ofrece, de cualquier vendedor |
| `stock_tienda` | unidades de la tienda |
| `stock_total` | unidades entre todos los vendedores activos |
| `total_ofertas` | cuantos vendedores lo tienen activo |

**Por que hay dos precios y no uno.** La tarjeta ensena el de la tienda, que es
la regla del profesor. Pero el FILTRO del buscador usa `precio_desde`: quien
busca "hasta Q4000" quiere lo que puede pagar con eso, y en 21 de los 34
productos del conjunto hay alguien vendiendolo mas barato que la tienda. Con el
filtro sobre `precio_tienda` esos quedaban fuera de la busqueda aunque si le
sirvieran. Es un fallo que solo se ve buscando, no leyendo el modelo.

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
En el conjunto de datos pasa en 6 variantes, a proposito: si la tienda tuviera
existencias de todo, el filtro devolveria el catalogo entero siempre y nadie
sabria si funciona.

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

## La resena es de la oferta, no del producto

Todavia no esta construida, pero la decision ya se tomo y conviene dejarla
escrita porque no es obvia.

`Resena` cuelga de `Oferta` y no de `Productos`. Con varios vendedores, una
queja de "llego tarde, mal empacado" es del **vendedor**, no del producto.

Lo que se gana es que la Entrega 2 se vuelve posible: el enunciado pide detectar
*"conjuntos de cuentas que se califican entre si de forma reiterada sobre los
mismos productos"*. Con la resena colgando del producto, las cuentas nunca se
tocan entre ellas y esa frase no tiene como expresarse. Con
`resena -> oferta -> usuario`, "A califica a B" es un camino real de dos saltos.

Y no se pierde la vista del producto: las resenas de la laptop salen subiendo
por `Oferta -> Productos Variantes -> Productos`. **La consecuencia que hay que
anotar** es que la calificacion del producto pasa a ser el promedio de las de
sus ofertas, asi que una queja de envio cuenta para la nota del producto.
Amazon las separa; aqui van juntas.

La resena no lleva fecha propia: es el comentario raiz
(`id_comentario_padre` en NULL) y `Comentario.fecha_publicacion` ya guarda
cuando. `Likes` si lleva `fecha_creacion` porque no es un comentario y no tiene
de donde heredarla -- y ademas es el campo que hace posible detectar
manipulacion: 40 likes en tres minutos, o cuentas creadas el mismo dia dandose
like entre si.

---

## Los historiales no llevan estado

Un historial solo se inserta, nunca se actualiza. El estado vive en la fila viva,
que si cambia.

La regla: si la fila se actualiza, lleva estado. Si solo se inserta, no. Por eso
`Oferta` lleva estado y `Precio Historial` no.

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

**`Oferta` es la excepcion y lleva las dos fechas**, porque es una fila viva:
`fecha_creacion` dice cuando nacio y `fecha_actualizacion` cuando se toco por
ultima vez. Esa segunda la mantiene un trigger y no la aplicacion: si dependiera
de que cada UPDATE se acuerde de ponerla, el dia que una ruta nueva no lo haga
la fecha miente sin dar ningun error.

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
promedio esta en **57%**.

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
