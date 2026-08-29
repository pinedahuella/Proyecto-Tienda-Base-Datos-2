# Frontend

> **Todo corre contra el modelo multi-vendedor.** El flujo completo -- buscar,
> agregar al carrito, elegir a donde se entrega y pagar -- esta construido y
> probado contra el backend real.
>
> 🔴 **Pero el frontend se quedo atras del backend.** Entraron tres cosas nuevas
> -- la calle en las direcciones, la aprobacion de ofertas y la propuesta de
> productos -- con su backend y su esquema terminados y probados, y **ninguna
> tiene pantalla todavia**. Lo urgente es la calle: `Direcciones.svelte` y
> `Checkout.svelte` no mandan `direccion_exacta`, que el backend exige al crear,
> asi que **hoy no se puede dar de alta una direccion desde la interfaz**.
>
> | Pantalla | Estado |
> |---|---|
> | `/` catalogo | al dia. Dos formas de paginar: cursor y por numero de pagina |
> | `/producto/[id]` ficha | al dia, lista las ofertas de cada vendedor |
> | `/pedidos` | el pedido abierto y el historial, con su detalle |
> | `/panel` perfil, direcciones, admin | perfil y admin al dia. **Direcciones no**: le falta el campo de la calle, y sin el, crear una direccion devuelve 400 |
> | `/panel` vendedor | ofertas propias, publicar, precio, estado y stock. **Le falta** ensenar el estado `pendiente` y sus rechazos, y proponer productos |
> | `/panel` tienda y admin | el catalogo paginado y las ofertas de cada producto al abrirlo. **Le faltan** las dos colas de revision: ofertas pendientes y productos propuestos |
> | `/gracias` | al dia: el comprobante despues de comprar |
> | filtros | catalogo y ofertas filtran en el servidor; la lista del vendedor, en memoria |
> | `Carrito.svelte` | panel lateral, con seleccion por linea |
> | `Checkout.svelte` | forma de pago, direccion de entrega y el mock de tarjeta |

SvelteKit.

## Las paginas

| Ruta | Que es | Pide sesion |
|---|---|---|
| `/` | el catalogo | no |
| `/producto/[id]` | la ficha de un producto | no |
| `/entrar` | iniciar sesion | no |
| `/registro` | crear cuenta | no |
| `/pedidos` | el pedido abierto y todos los anteriores | si |
| `/panel` | perfil, direcciones, y segun el rol la gestion o las ofertas | si |

El catalogo es la pagina de inicio y es publica: `GET /productos` no pide la
cookie, asi que se puede navegar la tienda sin cuenta. Por eso el inicio de
sesion se movio a `/entrar` y la cabecera lleva el enlace.

**Todo el filtrado lo hace el backend.** En el catalogo no se filtra en memoria:
si se hiciera, un filtro solo alcanzaria a los productos ya descargados y
mentiria en cuanto haya mas de una tanda.

El panel muestra una cosa u otra segun **quien** es la cuenta, no solo segun su
rol. Un comprador ve el resumen. Un vendedor normal ve sus ofertas. Y quien
administra el catalogo -- la cuenta `tienda@mesh.com` **o** cualquier admin --
ve ademas el catalogo compartido, porque el backend les abre las mismas rutas
(`exigirTiendaOAdmin()` en `/vendedor/productos`, y `resolverIdEfectivo()` en
`/vendedor/ofertas`, que cambia el id de un admin por el de la tienda). El admin
ve tambien la gestion de cuentas, que es solo suya.

El rol no basta para decidirlo: los cinco vendedores tienen `id_rol_usuario` 2 y
solo uno administra el catalogo. Esconder un panel no da permisos -- quien decide
es el backend, que responde 403 o 404.

## Archivos

| Archivo | Que contiene |
|---|---|
| `src/routes/+layout.svelte` | la paleta, los estilos globales y el armazon de la pagina |
| `src/routes/+page.svelte` | el catalogo, con sus filtros |
| — | la tarjeta ensena `precio_tienda`, y `precio_desde` debajo cuando otro vendedor lo tiene mas barato |
| `src/routes/producto/[id]/+page.svelte` | la ficha: la foto arriba y el detalle debajo |
| `src/routes/entrar/+page.svelte` | inicio de sesion |
| `src/routes/registro/+page.svelte` | crear cuenta |
| `src/routes/panel/+page.svelte` | panel |
| `src/lib/PanelAdmin.svelte` | gestion de usuarios, dentro del panel |
| `src/routes/pedidos/+page.svelte` | el pedido abierto y el historial, en su propia pagina |
| `src/lib/Carrito.svelte` | el carrito lateral, con casilla por linea |
| `src/lib/Checkout.svelte` | pagar: forma de pago, direccion de entrega y tarjeta simulada |
| `src/lib/MisPedidos.svelte` | los pedidos anteriores, con detalle, cancelar e historial del producto |
| `src/lib/estadoCarrito.svelte.ts` | si el carrito esta abierto y cuantas lineas lleva, compartido |
| `src/lib/OfertasVendedor.svelte` | las ofertas: verlas, editar precio/estado/stock y publicar. Con `administraLaTienda` entra por el catalogo paginado en vez de traerlas todas |
| `src/lib/PanelVendedor.svelte` | el catalogo compartido (alta, edicion e historial por fecha), solo para la tienda o un admin |
| `src/lib/Direcciones.svelte` | direcciones, dentro del panel |
| `src/lib/Pedido.svelte` | el pedido abierto y sus lineas, dentro del panel |
| `src/lib/pedido.ts` | las cuatro rutas de `/comprador/pedidos` y el id del pedido abierto |
| `src/lib/api.ts` | `pedir()`, la unica forma de hablar con el backend |
| `src/lib/Cabecera.svelte` | cabecera pegada arriba |
| `src/lib/Pie.svelte` | pie |
| `src/lib/MarcaMesh.svelte` | logotipo |
| `src/lib/Trama.svelte` | el tejido del fondo |
| `src/lib/BotonTema.svelte` | boton de tema claro y oscuro |
| `src/lib/tema.ts` | lee y guarda el tema |
| `src/lib/sesion.ts` | guarda el correo del usuario |
| `static/favicon.svg` | icono de la pestana |

## La paleta

Todos los colores son variables en `+layout.svelte`. El tema oscuro solo cambia el
valor de esas variables, no las reglas: `--tinta` siempre es el texto principal y
`--blanco` siempre la superficie de las tarjetas. Asi ningun componente necesita saber
en que tema esta.

El acento es indigo porque Mesh es un tejido, y el indigo es el tinte del comercio
textil.

## El tema

El tema vive en el atributo `data-tema` del `<html>` y se recuerda en `localStorage`.
Se aplica desde un script en `app.html`, **antes de pintar**. Si se hiciera desde un
componente, la pagina saldria clara un instante y saltaria a oscura.

## Cosas que no se deben cambiar sin saber por que

**La trama del fondo es muy tenue a proposito** (`--hilo`). Si se sube, los hilos
cruzan por detras de las letras y el texto cuesta leerse, aunque el contraste medido
diga que esta bien: la formula de contraste compara dos colores planos y no ve una
textura.

**Los grises estan medidos, no elegidos a ojo.** Con los valores anteriores el texto
secundario quedaba en 2.7 de contraste sobre 4.5 que es el minimo legible. Los actuales
dan entre 5.0 y 6.4 en los dos temas.

**El favicon lleva trazo grueso** porque a 16 px una linea fina desaparece.

**El formulario del vendedor no tiene campos fijos.** Al elegir la categoria le
pregunta al backend que ofrece (`GET /vendedor/categorias/:id`) y pinta un
control por caracteristica segun su `tipo_dato`: texto, numero, si/no, o una
lista con un valor por linea. Si se agregara una caracteristica nueva a una
categoria, el formulario la muestra sin tocar el frontend.

## Los filtros del catalogo

Son los de `GET /productos`, tal como los definio el backend. El contrato esta
en `backend/elementos Generales/endpoints-productos.md`; aqui solo se dice como
se traducen a controles.

**Los fijos** son los que existen siempre: `nombre` (busqueda parcial),
`id_categoria`, `precio_min`, `precio_max` y `estado_variante`.
La casilla "Solo variantes activas" manda `estado_variante=activa`, y el backend
la mete en el mismo `$elemMatch` que el rango de precio: marcarla con un rango
puesto pide **una variante que cumpla las dos cosas**, no dos variantes
distintas que cumplan una cada una.

**`id_vendedor` ya no existe** y aqui se listaba como fijo: es la contradiccion
que tenia este documento, porque mas abajo -- en "El filtro por vendedor se fue"
-- ya se decia lo contrario. Manda esa. `ListarProductosQuery` (en
`backend/src/dto/listar-productos.ts`) no lo tiene, y como cualquier parametro
que el backend no reconoce se trata como filtro de caracteristica, mandarlo
devuelve cero sin decir por que.

**El stock: `stock_min` y `stock_max`.** Son la excepcion a lo de "la misma
variante": no van sobre una variante, van sobre `stock_total`, que es la suma de
`variantes[].stock` del producto entero. Por eso no entran en el `$elemMatch` del
precio.

El control es un selector, "Disponibilidad", porque los tres casos que la gente
pide de verdad son un solo valor cada uno y no vale la pena ensenar dos cajas
para pedirlos:

| Opcion | Que manda |
|---|---|
| Cualquiera | nada |
| Con stock | `stock_min=1` |
| Agotados | `stock_max=0` |
| Rango exacto... | abre dos campos, `stock_min` y `stock_max` |

**`stock_total` viene en cada producto sin pedirlo**, asi que la tarjeta ensena
"N en existencia" o "Agotado" en rojo. No se guarda en Mongo: lo calcula el
backend al responder, con un `$addFields`.

**En la ficha del producto las existencias van arriba**, junto al precio, con el
numero en grande, y ademas cada presentacion ensena las suyas. La ficha si puede
leer `variantes[].stock` una por una; la tarjeta del catalogo solo ensena el
total.

**"Agotado" y "sin registrar" no son lo mismo, y `stock_total` no los
distingue.** Una variante sin el campo `stock` cuenta como 0 en la suma que hace
el backend, asi que un producto recien publicado desde el panel da 0 igual que
uno que se vendio entero. Lo que si los separa es mirar si ALGUNA variante trae
el campo: si ninguna lo trae, la ficha dice "Sin registrar" en gris en vez de
"Agotado" en rojo. Sin eso, un producto al que nadie le ha cargado inventario se
lee como agotado, que es una afirmacion distinta y falsa.

`estado` (el del producto) no se expone a proposito: el backend excluye siempre
`inactivo` y `borrador`, asi que en el catalogo publico solo queda `activo` y el
filtro no podria distinguir nada.

**Los dinamicos** son las caracteristicas. Cualquier nombre de parametro que no
sea uno de los fijos es el nombre de una caracteristica, y el prefijo decide el
operador: sin prefijo igualdad, `min_` mayor o igual, `max_` menor o igual,
`contiene_` contiene sin distinguir mayusculas. Se pueden poner varios y todos
deben cumplirse.

**La categoria y la caracteristica se buscan escribiendo, no se eligen de un
desplegable.** Son 24 categorias y hasta 46 caracteristicas por categoria, y
recorrerlas a ojo no es forma de filtrar. Los dos son el mismo
`Autocompletar.svelte` de las direcciones, con cuatro opciones nuevas -- las
cuatro apagadas por defecto, asi que las direcciones no cambiaron:

| Opcion | Que hace | Categoria | Caracteristica |
|---|---|---|---|
| `mostrarAlEnfocar` | al enfocar sale la lista, para ojearla sin escribir | si | si |
| `compacto` | talla de barra de filtros, no de formulario | si | si |
| `limpiarSiVacio` | vaciar la caja borra el valor y avisa al padre | si | no |
| `permitirLibre` | vale un nombre que no este en la lista | no | si |

Tambien se le pusieron flechas, Enter y Escape.

**Los dos ultimos son opuestos a proposito.** La categoria **tiene** que ser una
de la lista: lo que viaja es `id_categoria`, un entero, y un nombre inventado no
significa nada -- escribir algo que no esta y salirse del campo lo borra y avisa.
La caracteristica es al reves: una personalizada la escribio quien publico el
producto y no hay lista que consultar, asi que lo tecleado vale.

Y `limpiarSiVacio` existe porque en la categoria "nada" **es** una respuesta
valida: vaciar la caja quiere decir "todas". Sin eso, borrar el texto dejaba la
caja vacia y el valor puesto -- la pantalla decia "ninguna categoria" y la
busqueda seguia filtrada por una. En una direccion no aplica: "sin ciudad" no es
una respuesta.

Un detalle que muerde: la lista ensena `Memoria RAM (GB)` pero la caja se queda
con `Memoria RAM`. Si la caja se quedara con el rotulo, la siguiente tecla lo
convertiria en el valor -- y `Memoria RAM (GB)` no es ninguna caracteristica, asi
que el filtro dejaria de encontrar sin decir por que. Por eso `permitirLibre` no
traduce valor a texto.

El menu sale de `GET /categorias/:id`, que trae el `tipo_dato` y la unidad de
cada una. De ahi sale el control y los operadores:

| `tipo_dato` | Control | Operadores, el primero por defecto |
|---|---|---|
| `texto` | un campo de texto | contiene, igual |
| `lista` | un campo de texto | igual, contiene |
| `entero` / `decimal` | dos campos, desde y hasta | entre (`min_`+`max_`), igual |
| `booleano` | si / no | igual |
| personalizada | segun el operador elegido | igual, contiene, entre |

**`min_` y `max_` solo se ofrecen sobre lo numerico**, y eso es una decision de
esta pantalla, no del backend. El backend los acepta contra cualquier tipo a
proposito, porque no necesita conocer el `tipo_dato`; pero sobre texto Mongo
compara lexicograficamente y el resultado no significa nada para quien busca:
medido contra el catalogo real, `min_Marca=A` devuelve 47 de 51 productos. Esa
es justamente la razon por la que la ruta de categoria trae el tipo.

Una caracteristica **personalizada** no esta en ninguna lista -- la escribe
quien publica el producto -- asi que basta con teclear su nombre. Ahi se
comprueba contra `CLAVES_RESERVADAS`, la misma lista de `productos.service.ts`:
una personalizada llamada `estado` o `nombre` se confundiria con un filtro fijo y
buscaria otra cosa **sin dar ningun error**.

**El operador se llama "es exactamente", no "es igual a".** Y cuando la busqueda
sale vacia con uno de esos puesto sobre un texto, debajo aparece la explicacion y
un boton que los pasa a "contiene". Es la queja mas facil de tener: se escribe
`azul`, el catalogo guarda `Azul`, y una igualdad exacta no encuentra nada. El
operador no se toco -- exacto es exacto, que es lo que dice la API -- lo que se
arreglo es que la pantalla lo diga en vez de dejar a la persona adivinando.

## Las ofertas del vendedor

`OfertasVendedor.svelte`, dentro del panel y **encima** del catalogo: en el
modelo multi-vendedor el producto es del catalogo compartido y no es de nadie,
mientras que la oferta -- precio, existencias y estado -- si es del vendedor.

**Dos formas de entrar, segun la cuenta.** Un vendedor normal tiene ~90 ofertas y
se le traen todas de una (`GET /vendedor/ofertas`): esa lista es su pantalla
entera. Pero la tienda oferta TODO el catalogo, y esa misma ruta le devuelve 202
filas antes de pintar nada; a un admin le devolveria esas mismas 202, porque el
backend le sustituye la identidad por la de la tienda
(`resolverIdEfectivo()`). Asi que a los dos se les entra por el PRODUCTO:
`GET /productos?limite=20&despues_de=` de 20 en 20, y las ofertas de un producto
solo al abrirlo. La lista completa sigue a un clic, en "Ver la lista completa".

Medido, mediana de tres corridas en caliente:

| Ruta | Peso | Tiempo | Trae |
|---|---|---|---|
| `GET /vendedor/ofertas` | 84 KB | 254 ms | 202 filas |
| `GET /productos?limite=20` | 40 KB | 188 ms | 20 filas |
| `GET /vendedor/ofertas/producto/:id` | 2 KB | 59 ms | un producto |

**El argumento no es el tiempo.** 254 ms no es una tragedia, y decir lo
contrario seria inventar -- aqui llego a estar escrito "1.7 s", que era una
medida en frio presentada como si fuera la normal. Son dos cosas: los bytes de
la primera pantalla (40 contra 84 KB, y 20 filas con imagen contra 202), y que
el coste de la lista completa crece con el catalogo mientras el de una tanda no.

## El catalogo compartido, tambien paginado

`PanelVendedor.svelte`, debajo de las ofertas y solo para la tienda o un admin.

Aqui habia el mismo problema y no tenia arreglo desde el frontend:
`GET /vendedor/productos` es la unica ruta que devuelve TODOS los estados del
catalogo --`borrador`, `activo`, `inactivo` y, desde la migracion 009,
`en_revision` y `rechazado`--, que es justo lo que este panel administra, y traia el catalogo entero de un golpe. La publica
`GET /productos/paginacion` si pagina, pero fuerza `estado: 'activo'` como
lista blanca (`models/estado-producto.ts`), asi que se dejaba fuera lo unico
que aqui no se puede dejar fuera.

**Lo resolvio el backend con una ruta nueva**, `GET /vendedor/productos/paginado`
(commit `704ba11`): todos los estados, paginada por numero de pagina
(`pagina`, `limite`, tope 100) y con un filtro, `nombre`. Devuelve
`{ productos, pagina, limite, total_productos, total_paginas }` y por dentro es
un `$facet`, igual que la paginacion del catalogo publico.

El efecto en el panel completo del admin, medido sumando TODO lo que pide al
abrir:

| | Antes | Ahora |
|---|---|---|
| Ofertas | 84 KB, las 202 | 40 KB, tanda de 20 |
| Catalogo | 191 KB, los 105 | 32 KB, pagina de 20 |
| **El panel entero** | 275 KB solo esas dos | **75 KB todo** |

Se pagina por **numero de pagina** y no por cursor, al reves que la vista de
ofertas: en un panel de administracion uno quiere poder volver a "la pagina 3",
no solo seguir bajando.

**Ojo con el filtro de nombre**: la ruta nueva dice ser insensible a tildes,
pero solo lo es en un sentido. Buscar `lampara` encuentra `Lampara`; buscar
`lámpara` no encuentra nada, porque `construirRegexNombreFlexible` solo expande
las vocales SIN tilde del texto buscado. Como el catalogo no tiene ni un nombre
con tilde, quien escriba bien en español no encuentra nada. Reportado.

Reemplaza a la vieja pantalla de Inventario, que leia la tabla `inventario`.
Esa tabla ya no existe: el stock se fue a `oferta.stock`. Con ella se fue toda
su maquinaria de dos modos, que existia porque
`GET /vendedor/productos/inventario` era todo o nada y habia que deducir de un
409 que variante faltaba. `GET /vendedor/ofertas` devuelve un arreglo plano y
no hace falta deducir nada.

Trae las ofertas en **todos sus estados** (`activa`, `pausada`, `retirada` y,
desde la migracion 010, `pendiente` y `rechazada`), porque es el panel del
duenno; la ficha publica solo ensena las activas. Ojo: la pantalla todavia no
sabe pintar los dos estados nuevos. El
filtro por estado es local, sobre lo que ya se trajo.

**El ajuste de existencias es un DELTA, no el total.** Es la trampa de esta
pantalla y por eso se dice dos veces: en la ayuda del campo y en un renglon que
se actualiza mientras se escribe (`15 -> 18 unidades`). El backend recibe
`ajuste_stock`, un entero con signo que nunca es 0: positivo llama a
`reponer_stock(..., 'reposicion', ...)` y negativo a `'ajuste'`. Un campo que
dijera "existencias: 15" invitaria a escribir 18 para dejar 18, y terminaria en
33 sin que nada avisara.

Un ajuste que dejaria el stock bajo cero se corta aqui, en rojo y con el numero
en pantalla, sin gastar la peticion: el backend lo rechazaria igual con el 409
de `reponer_stock()`.

**Al publicar, la variante que ya se oferta sale deshabilitada.** `oferta` tiene
`UNIQUE (id_usuario, id_producto_mongo, id_producto_variante_mongo)`, asi que un
vendedor tiene una sola oferta por variante. `GET /vendedor/ofertas/producto/:id`
trae `mi_oferta` en cada una, y con eso la ya tomada se ensena apagada y con su
precio en vez de dejar intentarlo para recibir un 409.

**Crear la variante sigue siendo solo de la tienda.** Un vendedor solo puede
ofertar sobre lo que ya esta publicado, asi que el alta no es un formulario de
producto: es buscar en el catalogo (`GET /productos?nombre=`), elegir variante,
y ponerle precio y unidades iniciales.

**Un precio llega de dos formas en la misma respuesta.** De PostgreSQL sale como
texto (`"13803.00"`, el driver `pg` no lo convierte para no perder precision) y
de Mongo como Decimal128 (`{ $numberDecimal: "..." }`). `quetzales()` aguanta
las dos: con solo la primera, los campos calculados del catalogo se pintaban
`Q[object Object]`.

## El pedido

`src/lib/Pedido.svelte` (en el panel) y el boton "Agregar al pedido" de la ficha
consumen las cuatro rutas de `/comprador/pedidos`. Ninguna pide rol, solo
sesion: comprar no es privilegio de un rol, asi que el panel lo ensena a todos.

Un hueco del backend que la pantalla **dice** en vez de esconder:

- **Agregar una linea no reserva stock.** Solo lo lee para avisar. Dos personas
  pueden meter la misma ultima unidad.

El id del pedido abierto se guarda en `localStorage` (`mesh.pedido`). Nacio como
apano -- entonces no habia forma de listar los pedidos de uno y perder el id
dejaba el pedido inalcanzable desde el navegador -- pero **`GET /comprador/pedidos`
ya existe**, asi que perderlo dejo de ser fatal: el pendiente se vuelve a
encontrar en esa lista. Se sigue guardando porque ahorra esa consulta en cada
carga, no porque haga falta.

Y de ahi salen dos reglas que parecen quisquillosas y no lo son:

**Un 404 no basta para olvidar el pedido.** `POST /comprador/pedidos/:id/detalles`
contesta 404 por tres motivos distintos: el pedido no es tuyo o no existe, el
producto esta oculto, o la variante no es de ese producto. Solo el primero habla
del pedido. Como el id guardado es el unico hilo que lo une a este navegador,
antes de soltarlo se pregunta con `GET /comprador/pedidos/:id`; si ese contesta,
el pedido vive y lo que fallo era otra cosa. Tirarlo a la primera dejaba un
pedido con lineas inalcanzable para siempre.

**Cerrar sesion borra el id.** Si se queda, la siguiente persona que entre en el
mismo navegador arrastra el pedido de la anterior: el backend le contesta 404
porque no es suyo, y la pantalla lo leia como "ese pedido ya no existe", que es
mentira -- existe, y es de otro.

## El catalogo y la ficha con varios vendedores

**La tarjeta ensena el precio de la TIENDA** (`precio_tienda`), que es la regla
del profesor: el primero siempre es el de la pagina. Y debajo, solo cuando
alguien lo tiene mas barato, `desde Q3,856.00 con otro vendedor`. Esconderlo
seria mentir por omision: el buscador filtra por `precio_desde`, asi que un tope
de Q4000 devuelve productos cuya tarjeta dice Q4100.

**El stock ya no se deduce contando variantes.** `stock_total` y `total_ofertas`
vienen calculados, y con eso los tres casos salen de mirar y no de deducir:

```
hay          stock_total > 0
sin-oferta   nadie lo vende todavia (total_ofertas === 0)
agotado      hay vendedores, pero ninguno tiene unidades
```

Antes `stock_total` se sumaba de `variantes[].stock`, que era OPCIONAL, y "se
vendio todo" daba el mismo 0 que "nadie registro nada". De ahi salio el bug del
`every()`, que daba por agotado un producto entero porque UNA variante estaba en
0. Ese problema desaparecio con el modelo, no se arreglo con mas codigo.

**En la ficha se compra una OFERTA, no una variante.** Cada vendedor tiene su
fila con su precio, sus unidades y su boton; la de la tienda va marcada. Las
ofertas NO vienen del documento del producto: las trae
`GET /productos/:id` desde PostgreSQL, porque precio y stock cambian en cada
venta.

**El filtro por vendedor se fue** del catalogo, y con el el boton "Ver todo de
X". Ojo si se reactiva: `id_vendedor` ya no es un filtro fijo del backend, asi
que mandarlo lo convierte en un filtro de caracteristica y devuelve cero sin
decir por que.

---

## El carrito y el pago

`Carrito.svelte` es un panel que entra desde la derecha y vive en el layout, no
en cada pagina: es UNO solo para todo el sitio. Se abre desde el boton de la
cabecera y solo al agregar algo desde una ficha.

**La seleccion por linea es del navegador, no del backend.** Aqui hay una
costura que conviene entender: el backend NO tiene ninguna idea de
"seleccionado" -- un pedido se compra ENTERO. Las casillas son una ayuda para
decidir, y se guardan en `localStorage`. Por eso, al comprar con lineas
desmarcadas, hay un paso de confirmacion que dice cuantas se van a QUITAR del
pedido: no hay forma de pagar una parte y dejar el resto guardado, y quitarlas
es un DELETE que no se deshace.

Se guarda lo DESMARCADO y no lo marcado, a proposito: una linea nueva tiene que
nacer marcada, y con la lista de marcadas habria que acordarse de agregarla en
cada sitio donde se agrega una.

`Checkout.svelte` es la ventana de pagar. Trae:

- **Las formas de pago se PIDEN**, no se escriben a mano: son un catalogo
  cerrado de la base (`GET /comprador/pedidos/metodos-pago`), y se manda
  `metodo_nombre`, nunca el id.
- **La direccion de entrega**, que se ve y se puede cambiar sin salir de ahi
  (`PATCH /comprador/pedidos/:id`), incluso agregando una nueva. Antes se pagaba
  sin verla: el pedido se abria con la PRIMERA direccion del usuario y no habia
  ni donde mirarla. Tras cambiarla se vuelve a LEER el pedido, y se pinta lo que
  quedo, no lo que se creyo mandar.
- **El mock de tarjeta**, que valida forma y Luhn antes de salir a la red.

Los cuatro finales del cobro son distintos y se tratan distinto:

| Que paso | Como llega | Que hace la pantalla |
|---|---|---|
| Comprado | `ok` con `comprado: true` | cierra, vacia el carrito |
| El precio cambio | `ok` con `comprado: false` y `avisos` | ensena congelado vs actual y deja repetir con `confirmar_cambios` |
| El cobro no paso | 402 | el mensaje del backend, se puede reintentar |
| Sin stock o pausada | 409 | NO se ofrece seguir: hay que arreglar el carrito |

El segundo es el que mas facil se lee mal: `ok` sigue en `true` y no se compro
nada. Se cobra el precio CONGELADO en los dos casos; el aviso existe para que
nadie pague creyendo otra cosa.

## Los pedidos

`/pedidos` es su propia pagina, no una seccion del panel. Comprar y administrar
la cuenta son cosas distintas, y tenerlas juntas obligaba a bajar por el perfil
y las direcciones para llegar a lo que uno venia a ver.

Arriba el pedido abierto; abajo los anteriores, que se despliegan de a uno y
solo entonces piden su detalle (`GET /comprador/pedidos/:id`). Lo ya cargado se
cachea.

**"Como se veia al comprarlo"** reconstruye el producto a la fecha del pedido
con `GET /productos/:id/historial?fecha=`. Esa ruta, a diferencia del catalogo,
NO oculta los productos inactivos o en borrador: un pedido tiene que poder
ensenar su producto aunque hoy ya no se venda. Es el criterio de mas peso de la
Entrega 1 puesto donde se ve.

Ojo con un dato que se lee mal: `metodo_pago`, `estado_pago` y
`fecha_cancelacion` vienen `null` mientras el pedido sigue `pendiente`. No es un
fallo: el pago nace recien al comprar.

## Lo que todavia falta

**Se puede comprar de punta a punta.** El carrito lleva al checkout, el
checkout cobra con la tarjeta simulada y el pedido queda `comprado`. Probado
contra la base: el stock baja lo justo, el kardex cuadra y el pago se escribe.

**No se puede FIJAR una cantidad, solo subirla o bajarla de a una.**
`agregar_linea()` suma y `restar_linea()` resta; ninguna acepta un total. Al
llegar a 0, la linea se borra sola (el backend contesta `eliminada: true`), asi
que el `-1` y el `Quitar` acaban siendo lo mismo cuando queda una unidad.

**El filtro "Sin unidades disponibles" del catalogo mezcla dos casos.** Va sobre
`stock_max=0`, y ahi caen tanto el producto agotado como el que nunca registro
existencias. El backend no ofrece forma de separarlos, asi que el filtro se
nombra por lo que de verdad devuelve. Las etiquetas de las tarjetas si los
separan.

## Cosas que se aprendieron a golpes

**"No se sabe" no se pinta igual que "no falta nada".** En la pantalla de
inventario, antes de la primera respuesta no se sabe nada de ningun producto, y
ese estado caia en la misma rama que "todo bien": el catalogo entero asomaba un
instante antes de que llegara el 409. Mientras se pregunta no se pinta nada de
la tabla, ni siquiera lo que se sabia antes.

**Un `every()` deja pasar el caso mixto.** `variantes.every(v => v.stock ===
undefined)` decia "sin registrar" solo si NINGUNA tenia stock, asi que bastaba
una registrada en 0 para dar el producto entero por inventariado y ponerle
"Agotado" -- afirmando que se vendio lo que nunca se registro. Cuando hay tres
estados posibles, se cuentan; no se resuelve con un booleano.

**La ficha de producto se reusa entre ids.** SvelteKit no vuelve a montar el
componente al ir de `/producto/1` a `/producto/2`, asi que con `onMount` la
pantalla se quedaba con el producto anterior mientras la URL decia otro. Peor
que un dato viejo: el boton de agregar al pedido mandaba el id NUEVO del
producto con el id de una variante del VIEJO. Va con un `$effect` que depende de
`id`, y con `untrack` alrededor de la carga para que no se dispare solo (ver
mas abajo).

**Probar la navegacion con `history.pushState` no prueba nada.** El router de
SvelteKit no se entera y `page.params` no cambia: la pantalla se queda igual y
parece que el bug sigue ahi. Para medirlo hay que navegar como navega la app,
con un `<a href>` que el router intercepte.

**`conJson` no hace la peticion.** Arma las opciones para las que mandan cuerpo
JSON; la que pide es `pedir`. Usarla como si pidiera devuelve un objeto sin `ok`
y sin `mensaje`, asi que la pagina sale vacia **y sin ningun error a la vista**.

**Cargar los datos con `$effect` se repite solo.** En el panel se vieron seis
llamadas en el mismo instante, y como todo colgaba de `{#if cargando}`, cada
vuelta desmontaba el arbol y borraba el formulario a medio escribir. Va con
`onMount`, y la pantalla de carga solo tapa la primera vez.

**Un `<input type="number">` con `bind:value` guarda un numero, no texto.**
Llamarle `.trim()` revienta con "is not a function". Y con el campo vacio guarda
`undefined`, que tampoco es texto.

Esto ya habia mordido en el catalogo y nadie lo vio: `precio_min` y `precio_max`
se armaban con `.trim()`, asi que **escribir un precio tiraba una excepcion
dentro de `buscar()` y se llevaba la peticion entera** -- la pantalla se quedaba
en "Buscando..." para siempre. En consola si estaba el error; en la pagina, nada.
Por eso ahora todo campo se lee con `texto()`, que aguanta las tres formas.

**Un cambio recargado en caliente deja el manejador dos veces.** Midiendo las
peticiones se veia que cada cambio de categoria pedia `/categorias/:id` y
`/productos` **dos veces**, y el evento del DOM salia una sola vez: eran dos
instancias del componente vivas a la vez, de las recargas de Vite. Con `F5` de
verdad sale una sola. Antes de perseguir un doble disparo, recarga entera.

## El historial dentro de un pedido

En `/pedidos`, cada linea trae un "Ver como se veia": reconstruye el producto
tal como estaba **el dia de la compra**, con
`GET /productos/:id/historial?fecha=`. Es la evidencia de funcionamiento que
pide la entrega, vista desde el lado del comprador.

Ensena nombre, descripcion, **categoria de ese dia** y **caracteristicas de ese
dia**. Lo de la categoria no es adorno: es el caso que justifica
`productos_historial.id_categoria` -- el balon nacio en Fitness y se movio a
Futbol, asi que reconstruirlo al 1 de mayo tiene que decir Fitness.

**El precio que se ensena NO es el de ese dia: es el que se pago.** Sale
congelado por `pedido_producto.id_precio_historial`, y para un comprobante es
lo correcto. Si alguna vez se quisiera "a como estaba la oferta ese dia" -- que
es otra pregunta -- la ruta es `GET /productos/ofertas/:id/historial?fecha=`,
la misma que usa el panel del catalogo.

**El dia se calcula en hora de Guatemala**, no recortando el texto ISO. Con el
recorte, un pedido de las 8:52 p. m. caia en el dia UTC siguiente y la pantalla
se contradecia sola: la cabecera decia "25 ago" y dos renglones mas abajo "Asi
se veia el 2026-08-26". El resultado no era incorrecto (el backend cuenta hasta
el final del dia), pero se leia como un error.
