# Frontend

> **Todo corre contra el modelo multi-vendedor.** El flujo completo -- buscar,
> agregar al carrito, elegir a donde se entrega y pagar -- esta construido y
> probado contra el backend real.
>
> **Al dia con el backend, al 2026-09-06.** Este bloque tenia un aviso rojo que
> decia que a tres cosas -- la calle en las direcciones, la aprobacion de ofertas
> y la propuesta de productos -- les faltaba pantalla. **Las tres llevan dias
> construidas** y el aviso se quedo aqui. Comprobado archivo por archivo antes de
> borrarlo: `direccion_exacta` viaja desde `Direcciones.svelte` y desde
> `Checkout.svelte`, `PropuestasProducto.svelte` existe con su cola de revision, y
> `OfertasVendedor.svelte` consume `/vendedor/ofertas/pendientes` con aprobar y
> rechazar.
>
> Lo dejo escrito porque el error es el mismo que este proyecto ya se ha hecho
> tres veces al reves, con el backend construyendo una pieza que la pantalla no
> consume. **Un aviso rojo que ya no es cierto cuesta mas que no tener aviso**,
> porque manda a trabajar en algo que esta hecho.
>
> Lo que SI falta hoy es la columna de filtros facetados del buscador, que es un
> requisito de la Entrega 3. Esta en `docs/PENDIENTES.md`, punto 10.
>
> | Pantalla | Estado |
> |---|---|
> | `/` catalogo | al dia. Dos formas de paginar: cursor y por numero de pagina |
> | `/producto/[id]` ficha | al dia, con pestanas, lista las ofertas de cada vendedor |
> | `/buscar` | al dia. **Le falta** la columna de facetas con sus numeros |
> | `/pedidos` | el pedido abierto y el historial, con su detalle y el boton de resenar |
> | `/panel` perfil, direcciones, admin | al dia, la calle incluida |
> | `/panel` vendedor | ofertas, publicar, precio, estado, stock, la venta relampago y las propuestas |
> | `/panel` tienda y admin | el catalogo, las dos colas de revision, fraude y reportes |
> | `/panel` tendencias | escrita contra un contrato que el backend todavia no publica. Ver `docs/BACKEND-PENDIENTE.md` |
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
| `/buscar` | los resultados del buscador, `?q=` | no |
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
| `src/routes/buscar/+page.svelte` | los resultados del buscador, hasta 50 |
| `src/lib/BuscadorCabecera.svelte` | el campo de la cabecera con su lista colgando |
| `src/lib/buscador.ts` | la llamada a `/buscador/productos` y como se lee un resultado |
| `src/routes/producto/[id]/+page.svelte` | la ficha: la foto arriba y el detalle debajo |
| `src/routes/entrar/+page.svelte` | inicio de sesion |
| `src/routes/registro/+page.svelte` | crear cuenta |
| `src/routes/panel/+page.svelte` | panel |
| `src/lib/PanelAdmin.svelte` | gestion de usuarios, dentro del panel |
| `src/lib/PanelFraude.svelte` | fraude, en dos pestanas: intentos de entrada sospechosos y anillos de manipulacion de resenas, con si el grafo esta al dia |
| `src/lib/NotificacionesFraude.svelte` | la campana general de la cabecera, de todas las cuentas: las alertas de login de la propia cuenta |
| `src/lib/NotificacionesAdmin.svelte` | la campana del admin, con escudo: los anillos de resenas pendientes |
| `src/lib/TendenciasAuto.svelte` | las tarjetas de rankings de Tendencias, con barras |
| `src/lib/PanelReportes.svelte` | los dos reportes de admin, ventas y reservaciones |
| `src/lib/CarritoRedis.svelte` | el carrito lateral sobre Redis, con la insignia de venta relampago |
| `src/lib/Resenas.svelte` | las resenas de un producto, con su promedio, votos y respuestas |
| `src/routes/pedidos/+page.svelte` | el pedido abierto y el historial, en su propia pagina |
| `src/lib/Carrito.svelte` | el carrito lateral, con casilla por linea |
| `src/lib/Checkout.svelte` | pagar: forma de pago, direccion de entrega y tarjeta simulada |
| `src/lib/MisPedidos.svelte` | los pedidos anteriores, con detalle, cancelar e historial del producto |
| `src/lib/estadoCarrito.svelte.ts` | si el carrito esta abierto y cuantas lineas lleva, compartido |
| `src/lib/OfertasVendedor.svelte` | las ofertas: verlas, editar precio/estado/stock, publicar y abrir o cerrar la venta relampago. Con `administraLaTienda` entra por el catalogo paginado en vez de traerlas todas |
| `src/lib/PanelVendedor.svelte` | el catalogo compartido (alta, edicion e historial por fecha), solo para la tienda o un admin |
| `src/lib/Direcciones.svelte` | direcciones, dentro del panel |
| `src/lib/Pedido.svelte` | el pedido abierto y sus lineas, dentro del panel |
| `src/lib/pedido.ts` | las cuatro rutas de `/comprador/pedidos` y el id del pedido abierto |
| `src/lib/api.ts` | `pedir()`, la unica forma de hablar con el backend. Pide a `/api`, y el proxy de `vite.config.ts` lo pasa al backend (ver `docs/ENTRAR-DESDE-EL-CELULAR.md`) |
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

### El boton de la venta relampago

Agregado el **2026-09-03**, en cuanto existieron
`POST` y `DELETE /vendedor/ofertas/:id/venta-limitada`. Aparece en cada oferta
`activa`, y tambien en una que ya la tenga abierta aunque haya cambiado de
estado por otro camino, porque cerrar siempre se tiene que poder.

**Esta en las DOS vistas, y eso no es simetria por gusto.** Un vendedor normal
entra por la lista; la tienda y el admin entran por el catalogo, que es otra rama
del marcado. Ponerlo solo en la lista habria dejado a la cuenta con MAS ofertas
sin poder abrir ni una. Las dos usan el mismo `{#snippet panelRelampago}` --
el primer snippet del proyecto -- para que no haya dos copias del panel que
corregir, que es la clase de cosa que se arregla en una vista y no en la otra.

El color naranja sale de tres variables (`--relampago-tinta`, `--relampago-fondo`
y `--relampago-linea`) declaradas en `.ofertas`, con su version para el tema
oscuro. Los valores claros son **exactamente** los de la insignia de
`CarritoRedis.svelte`: es la misma venta vista desde los dos lados del mostrador
y dos naranjas distintos la harian parecer dos cosas. Naranja y no rojo porque
el rojo tiene que seguir siendo el color que solo sale cuando algo esta mal.

Tres cosas que hace el panel y que no son adorno:

**Cerrar pide un clic mas.** El `DELETE` borra las claves de Redis de la oferta y
eso descarta las reservas en curso: las unidades vuelven al stock, pero quien
tenia algo apartado lo pierde, y cerrar no confirma ninguna compra. El panel lo
dice antes y el borde se pone mas grueso, porque los dos paneles ocupan el mismo
sitio y acciones opuestas que se ven iguales son una trampa.

**Separa los dos plazos.** `duracion_segundos` es cuando cierra la venta entera;
lo que cada persona tiene apartado antes de pagar son 15 minutos y es fijo. Se
confunden solos, y quien quiere "quince minutos" escribe 900 pensando en lo
segundo y cierra su propia venta en quince minutos.

**Con stock 0 no deja abrir.** El backend no lo impide: `sembrar` acepta cero y
contesta 201. Lo sembrado es una FOTO del stock de ese instante y ya no vuelve a
mirar PostgreSQL, asi que reponer existencias despues sube PostgreSQL y deja
Redis en cero, y la oferta queda incomprable sin ningun error ni ninguna marca.
Salio pulsando el boton sobre una oferta agotada de la tienda, no leyendo.

## El panel de fraude dice de cuando son sus datos

`PanelFraude.svelte`, agregado el **2026-09-04**.

El grafo de Neo4j se llena por una cola, no en vivo. Hasta ahora el panel
enseñaba **un analisis correcto sobre datos que podian estar incompletos y no
lo decia**. Un panel que falla se arregla; uno que calla se cree.

Ahora, debajo de la introduccion, sale una linea con el estado de la
sincronizacion, que sale de `GET /admin/grafo/conciliacion`:

```
al dia      gris, del tamano de un pie de foto
            "Grafo al dia con PostgreSQL, sincronizado hace 9 minutos"
atrasado    rojo, con fondo
            "Este analisis puede estar incompleto. El grafo no cuadra con
             PostgreSQL. Al grafo le faltan datos: 1 en resenas, ...
             Corre etl/cargar_grafo.sh --limpiar"
```

Tres decisiones que no son obvias:

**Va en una peticion aparte y sin `await`.** Es informacion SOBRE el analisis,
no parte de el. Si esa ruta tarda o falla, el panel tiene que ensenar sus
anillos igual: bloquear un analisis correcto por no poder decir si esta fresco
seria cambiar un problema chico por uno grande.

**Un fallo ahi no pinta nada**, en vez de pintar un aviso de error. "No se pudo
comprobar si esta al dia" al lado de un analisis correcto asusta mas de lo que
informa.

**Los eventos apartados se dicen SIEMPRE**, cuadre o no. Un evento que fallo
cinco veces no se reintenta solo, asi que si nadie lo mira se queda ahi para
siempre. Es la unica parte de todo el mecanismo que necesita a una persona.

Y una que se vio en pantalla y no leyendo el codigo: la frase se escribe entera
en cada rama del `{#if}` en vez de armarla con un `{#if}` en medio. Con el
condicional intercalado, Svelte deja el salto de linea como espacio y el punto
final quedaba separado, "con PostgreSQL ." Repetir seis palabras sale mas barato
que pelearse con los espacios de la plantilla.

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

## El buscador de la cabecera

El campo va en el centro de la cabecera, o sea en TODAS las pantallas, y no
dentro del catalogo. Buscar es la accion principal de una tienda y tenerlo solo
en el catalogo obligaria a volver antes de poder buscar desde una ficha o desde
los pedidos.

Se escribe y va saliendo una lista debajo, hasta ocho productos. Pulsar uno abre
su ficha. Pulsar Enter sin haber elegido ninguno lleva a `/buscar?q=`, que ensena
la lista entera hasta el tope de 50 que pone el backend.

### No es el filtro `nombre` del catalogo

Son dos cosas distintas y por eso conviven:

| | de donde sale | como compara |
|---|---|---|
| el filtro `nombre` del catalogo | MongoDB | subcadena, sin distinguir mayusculas |
| el buscador de la cabecera | Elasticsearch, `GET /buscador/productos` | difuso y sin tildes |

Medido: `labtop` no encuentra nada en el filtro del catalogo y en el buscador
devuelve las laptops; `ambar` encuentra los productos que se escriben con
tilde. Por eso el buscador NO filtra por categoria ni por precio -- eso sigue
viviendo en el catalogo, que es donde hay sitio para ensenar los filtros, y
desde `/buscar` se llega con un enlace.

### Lo que trae un resultado, y lo que no

El indice de Elasticsearch guarda un RESUMEN, no el producto entero: nombre,
categoria, los dos precios, el stock y la nota. No trae imagenes ni
caracteristicas, asi que la lista no las ensena. Para el detalle esta
`/producto/:id`, que lee de MongoDB, que sigue siendo la fuente de verdad del
catalogo.

La nota solo se escribe cuando hay resenas. El indice guarda 0 tanto para "le
pusieron cero" como para "nadie lo ha calificado", y esas dos cosas se leen muy
distinto cuando estas eligiendo que comprar; se distinguen con
`resenas_total`.

### Detalles que costaron y no se deben deshacer

- **La peticion vieja puede llegar despues que la nueva.** Se escribe `lam` y
  luego `lampara`: son dos consultas y no tardan lo mismo. Cada una lleva
  numero y solo se pinta la ultima. Sin eso la lista ensena resultados que no
  son de lo que hay escrito.
- **El tope de alto de la lista esta medido, no elegido.** Cada fila mide 54px
  y la lista llena mide 481px. Con un tope de 30rem (480px) se pasaba por UN
  pixel y salia una barra de desplazamiento para nada, en el caso mas normal
  de todos. Esta en 34rem.
- **En telefono el buscador baja a su propia fila.** Compartiendola no cabe:
  medido a 320px, la marca, el carrito, la hamburguesa y el tema ya se comen el
  ancho. Esconderlo tras la hamburguesa no era opcion.
- **Menos de dos letras no sale a la red.** Con una sola letra la busqueda
  difusa engancha medio catalogo y esa lista no ayuda a elegir.
- **El hover y el teclado marcan con la MISMA clase.** Con dos marcas a la vez
  no se sabe cual abre el Enter.

## Sin sesion, el catalogo ya no te saca a /entrar

`CarritoRedis` vive en el layout y pide el carrito al montarse, o sea en todas
las paginas. Sin sesion esa ruta contesta 401, y el layout trataba ese 401
siempre como "se vencio la sesion": limpiaba y mandaba a `/entrar`.

El resultado era que abrir la portada te sacaba a `/entrar` antes de poder ver
un solo producto, con la tienda entera inservible para quien todavia no ha
entrado. Comprobado en el navegador: se abre `/` y la direccion termina en
`/entrar` sin haber pulsado nada.

Ahora `sesionExpirada()` mira primero si HABIA sesion. Si la habia, se vencio y
se manda a entrar, como siempre. Si no la habia, ese 401 solo dice "no has
entrado", que para el catalogo es lo normal porque es publico.

No se arreglo dentro de `CarritoRedis` a proposito: el que sabe si habia sesion
es el sitio, no el panel del carrito, y el panel ya deja dicho que el no navega
por su cuenta.

## El panel se ve de una seccion a la vez

Antes era UNA COLUMNA con todo apilado. Medido en el navegador, con el catalogo
de 1105 productos:

| Cuenta | Antes | Ahora |
|---|---|---|
| admin | 7732 px de alto | 1460 px |
| la tienda | 5531 px | 1938 px |

Para llegar a la manipulacion de resenas, que era lo ultimo de todo, habia que
pasar por el perfil, las direcciones, las cuentas, los reportes, veinte ofertas
y una pagina del catalogo. Con un catalogo de verdad no se acaba nunca.

Ahora hay una barra de secciones y solo se pinta la elegida. **No es un indice
de anclas**: un indice que solo hace scroll no reduce nada, se siguen viendo las
demas por el rabillo del ojo.

### Tres decisiones que no se deben deshacer

- **El orden es por USO, no por construccion.** Un vendedor abre el panel para
  mirar sus ofertas mil veces mas que para cambiarse el apellido, asi que las
  ofertas van primeras y la cuenta al final. Al admin le pasa lo mismo con los
  reportes.
- **Montaje perezoso, y despues se queda montada.** Entrar al panel ya no
  dispara las consultas de las siete secciones: solo las de la que se abre.
  Volver a una ya visitada no pide nada. Comprobado midiendo las peticiones:
  abrir Ofertas dispara `/productos` y `/vendedor/categorias`, y VOLVER a
  Ofertas dispara CERO.
- **La seccion viaja en la direccion**, `/panel?s=fraude`. Asi recargar te deja
  donde estabas, el boton de atras hace lo que se espera y se puede mandar un
  enlace directo a Resenas en vez de decirle a alguien que baje hasta el final.
  Si la url pide una seccion que esta cuenta no tiene, se cae a la primera en
  vez de dejar la pantalla en blanco.

## Cosas que se veian como cajas dentro de cajas

- **El buscador y su lista eran dos rectangulos sueltos.** La lista colgaba a
  8px del campo, con su propio borde y sus propias esquinas. Ahora, con la
  lista abierta, el campo pierde el borde de abajo y las esquinas de abajo, y
  la lista se pega a `top: 100%`: medido, el hueco entre los dos es 0 y tienen
  el mismo ancho. Al cerrarse, el campo recupera sus 6px de esquina.
- **La sombra no era una sombra.** Era `box-shadow` con `--panel`, que es un
  color OPACO del tema: en claro casi no se distinguia del fondo y en oscuro
  quedaba mas claro que la pagina, o sea un halo al reves. Ahora hay un token
  `--sombra` en la paleta, distinto en cada tema, y lo usan la lista del
  buscador y el menu de la cabecera.
- **La cabecera eran cuatro recuadros en fila.** Carrito, Mis pedidos, Mi
  perfil y Salir, todos con borde: ninguno destacaba, ni siquiera el carrito,
  que es LA accion de una tienda. Ahora la navegacion es texto y solo el
  carrito lleva caja. Sin sesion, "Iniciar sesion" va rellena.
- **Los filtros del catalogo ocupaban media pantalla antes del primer
  producto.** Ahora estan en un cajon que arranca cerrado, con el numero de
  filtros puestos en el tirador: un cajon cerrado que no diga cuantos lleva
  esconde justo lo que explica por que la lista trae 3 productos y no 1105.
- **Las ofertas del vendedor eran veinte tarjetas sueltas.** Ahora son una
  lista con lineas finas: cada fila baja de ~72px a ~46px.

### Dos fallos que salieron al hacer esto

- **`.enlace` ya estaba tomado.** En `+layout.svelte` significa "un boton que se
  lee como enlace", subrayado e indigo, y va con la clase DOBLADA
  (`button.enlace.enlace`) justo para ganarle a las reglas de los componentes.
  Al usar ese nombre para la navegacion de la cabecera, los dos `<a>` salian
  bien y el `<button>` de Salir salia subrayado y de otro color en la misma
  fila. Se llama `.navegar`.
- **El icono de la hamburguesa salia como un PUNTO.** El relleno global de los
  botones (8px 16px) le deja 6 pixeles al svg, que pide 20. `BotonTema.svelte`
  ya tenia ese mismo fallo documentado y arreglado con `padding: 0`, y a la
  hamburguesa le faltaba. Solo se ve en telefono, que es donde sale, y por eso
  llevaba tiempo asi sin que nadie lo notara.

## El buscador de admin

David agrego una segunda ruta, `GET /buscador/productos/admin`, que no filtra
por estado: trae tambien lo que no circula (en revision, rechazado, pausado).
Pide sesion y rol de admin, y le contesta 403 a cualquier otro, la tienda
incluida.

El frontend elige la ruta segun quien mire. No es un permiso, es una
preferencia de pantalla: mentir del lado del navegador no abre nada, solo hace
que la busqueda falle con el 403 del backend. Comprobado midiendo que ruta usa
cada cuenta:

| Quien mira | Ruta que usa | La de admin a pelo |
|---|---|---|
| admin | `/buscador/productos/admin` | 200 |
| comprador | `/buscador/productos` | 403 |
| sin sesion | `/buscador/productos` | 403 |

Los resultados que no estan activos salen con su estado en una etiqueta. En la
busqueda publica esa etiqueta NO aparece nunca, porque ahi todos llegan
"activo" y una etiqueta igual en todas las filas no informa de nada.

Desde la lista, "ver todos los resultados" arrastra el criterio en la url
(`/buscar?q=...&todo=1`): seria raro que la lista de arriba enseñe un producto
rechazado y la pagina entera no lo traiga.

### Dos carreras que hubo que cerrar

- **El rol llega despues que la pagina.** La cabecera pregunta quien esta dentro
  con una peticion, asi que durante los primeros instantes `verTodo` es false
  aunque quien mire sea admin. Quien tecleara rapido veia una lista y otra
  distinta un segundo despues, sin ninguna pista. Ahora, cuando el rol llega,
  se repite la busqueda que hay en pantalla.
- **Quien le pasa `sesion` a la cabecera le cortaba la consulta, y con ella el
  rol.** El panel le pasaba solo el correo, asi que ahi el buscador se creia de
  un usuario normal: LA MISMA busqueda daba resultados distintos en el panel y
  en el catalogo. La cabecera acepta ahora `esAdmin` por la misma via que
  `sesion` -- la prop manda si viene, y si no la averigua ella.

## El recuadro dentro del recuadro del buscador

Al hacer clic en la barra de busqueda de la cabecera aparecia un segundo
rectangulo redondeado FLOTANDO DENTRO del primero. No era el desplegable: salia
sin escribir nada.

La causa esta en `+layout.svelte`, en las reglas globales de los campos. A todo
`input` del proyecto se le da borde, esquinas, relleno de 8px 11px y, al
enfocar, `box-shadow: 0 0 0 3px` -- un halo. Eso esta bien en un formulario,
donde el input ES la caja. En el buscador la caja es `.campo` y el input va
dentro, asi que el halo del input dibujaba una segunda caja.

`BuscadorCabecera` solo le quitaba el borde. Ahora le quita tambien el relleno,
las esquinas y la sombra, y lo hace en los TRES estados (`normal`, `:hover`,
`:focus`) -- si no, la regla global vuelve a ganar justo cuando el campo tiene
el foco, que es el momento en el que se mira. El halo se movio a `.campo`, que
es lo que la persona ve como el control, y desaparece cuando la lista esta
abierta, porque ahi el campo es la tapa del panel y no un control suelto.

**Regla general para este proyecto:** un `input` metido dentro de otra caja
tiene que renunciar a la caja global entera, no solo al borde.

## Las tarjetas del catalogo

Tres cosas que se veian mal y por que:

**Los precios flotaban.** Medido en la portada, el precio de las cuatro
tarjetas de la primera fila caia a 705, 725, 705 y 753 pixeles. Pasaba porque
debajo del precio habia tres bloques sueltos --el "desde", los vendedores y el
stock-- y cada uno aparecia o no segun el producto. Ahora todo lo de abajo va
en un bloque con `margin-top: auto` y el pie SIEMPRE ocupa una linea, tenga uno
o tres datos. Los precios de una fila quedan alineados.

**Tres rasgos no caben en una linea.** "Material principal Policarbonato
reforzado" se partia en dos y esa tarjeta crecia un renglon mas que sus
vecinas. Bajaron a dos, que caben enteros. Cortarlos a los tres para que
quepan no sirve: quedaban "Material princip...", "Pais de...", "Ma...", tres
etiquetas que no dicen nada. Dos completas informan.

**"63 en existencia" en cada tarjeta.** Ese numero no le sirve a nadie que este
eligiendo: da igual si hay 63 o 200, lo que importa es si HAY. Eran doce lineas
repitiendo que si. Ahora el stock se calla cuando hay y habla cuando no
--"Agotado", "Nadie lo vende"-- que es cuando cambia la decision.

El separador del pie lo pone el CSS (`span + span::before`) y no el marcado,
asi que da igual cuales de los tres datos aparezcan: nunca sale un punto suelto
al principio ni dos seguidos.

## Las dos escalas, y por que existen

La pagina se veia como muchas paginas pegadas. La causa no era ningun
componente en particular: era que cada uno inventaba sus medidas. Contado antes
de arreglarlo, sobre `frontend/src`:

| | Valores distintos |
|---|---|
| `font-size` | **34** |
| `gap` | **39** |
| `border-radius` | 9 (esta bien, casi todos ya eran tokens) |

Treinta y cuatro tamanos de letra, con cinco de ellos --0.90, 0.92, 0.93, 0.94
y 0.95-- dentro de medio pixel unos de otros. Nadie ve la diferencia entre 0.92
y 0.93 mirando un componente; lo que si se nota es el conjunto, porque cada
pieza queda ligeramente distinta de su vecina.

Y los huecos convivian en dos unidades para el MISMO valor: `0.5rem` y `8px`,
`0.75rem` y `12px`, `1rem` y `16px`, segun quien lo hubiera escrito. Asi no hay
forma de cambiar el ritmo de la pagina despues.

### La escala de letra, nueve pasos

```
--f-xs    0.75rem   etiquetas, contadores, letra al pie
--f-sm    0.82rem   datos secundarios dentro de una fila
--f-ms    0.88rem   texto de apoyo, ayudas de formulario
--f-base  0.94rem   el cuerpo y los controles
--f-md    1.05rem   titulo de una tarjeta
--f-lg    1.2rem    titulo de una seccion
--f-xl    1.4rem    titulo de un panel
--f-2xl   1.75rem   titulo de pagina
--f-3xl   2.2rem    el titular de la portada
```

### La escala de espacio, siete pasos

```
--e1  4px    --e2  8px    --e3 12px    --e4 16px
--e5 24px    --e6 32px    --e7 48px
```

Va en pixeles y no en rem a proposito: el espacio no tiene que crecer con la
letra del sistema operativo. Una tarjeta con el doble de relleno no se lee
mejor.

### Como se aplico

No se eligio paso por paso a ojo: se tomo cada valor escrito y se le busco el
**mas cercano** de la escala, asi que ningun texto se movio mas de un par de
decimas de rem ni ningun hueco mas de 3px. 209 declaraciones de `font-size` y
156 de `gap`, en 19 archivos.

`padding` se dejo como estaba, y es una decision: el relleno de un control suele
estar medido a mano --un boton de 38px de alto necesita SU relleno, no el del
vecino-- mientras que el hueco entre cosas es puro ritmo, que es donde se notaba
que cada componente iba por su cuenta.

### La regla, de aqui en adelante

**Un `rem` suelto en un componente es volver a empezar.** Si hace falta un
tamano que no esta, se agrega a la escala en `+layout.svelte` y se usa desde el
componente. Para comprobar que no se ha colado ninguno:

```
grep -rho "font-size: *[0-9.]*rem"  --include=*.svelte frontend/src
grep -rho "gap: *[0-9.]*rem"        --include=*.svelte frontend/src
```

Las dos tienen que salir vacias.

**La segunda pregunta por `rem` y no por cualquier numero, y se cambio el
2026-09-06 por un motivo que no es cosmetico.** Como estaba antes
(`gap: *[0-9][^;]*`) cazaba tambien `gap: 1px` de `Resenas.svelte` y `gap: 0` de
la ficha, que son los dos legitimos: un filo de un pixel no sale de una escala de
ritmo, y un cero es un cero. O sea que la comprobacion **no podia salir vacia
nunca**, y una comprobacion que siempre tiene ruido deja de leerse a las dos
semanas. Se ignora, y el dia que se cuele un `gap: 1.5rem` de verdad nadie lo va
a ver entre las otras dos lineas.

La escala manda sobre los `rem`, que son los que tienen que ser todos iguales
entre componentes. Los pixeles sueltos de un filo o de un cero no son de la
escala.

## En telefono el catalogo va a UNA columna

Habia una regla que en pantallas de 620px para abajo bajaba el minimo de la
rejilla a `minmax(160px, 1fr)`. Con eso, un telefono de 390px metia DOS
columnas: tarjetas de 171 pixeles de ancho.

Medido ahi: el titulo se partia en dos lineas, "2 variantes" tambien, el pie
salia cortado en "4 ve..." y los rasgos en "Material principal Pol...". Dos
tarjetas ilegibles no son mejores que una que se lee.

Se quito la regla. Con el minimo general de 250px, un telefono da una columna
de 358px --todo entra en su linea-- y una tablet de 620 sigue dando dos de 286.

## Las estrellas eran asteriscos

`Resenas.svelte` pintaba la calificacion con `'*'.repeat(n) + '.'.repeat(5 - n)`
en tipografia monoespaciada, o sea `***..`. A tamano de lectura eso no parece
una calificacion, parece una cadena de depuracion, y desentonaba con el resto
de la pagina, donde todos los iconos son SVG dibujados a mano: la lupa del
buscador, la hamburguesa, el sol y la luna del tema.

Ahora son cinco estrellas de verdad, las que cuentan rellenas de indigo y las
demas con el contorno en gris. **Se dibujan las cinco siempre**: con solo las
llenas hay que contarlas para saber si son 3 de 5 o 3 de 4.

No hizo falta ninguna libreria, que es lo que decia el comentario anterior para
justificar el texto. Es un poligono de cinco puntas.

## Las dos campanas de la cabecera (2026-09-20)

Hay dos, y no son la misma.

- **La general**, `NotificacionesFraude.svelte`, es de todas las cuentas. Muestra
  las alertas de login de la propia cuenta (`GET /perfil/alertas-fraude`) y cada
  una se puede pasar a leida con **Marcar leida**.
- **La del admin**, `NotificacionesAdmin.svelte`, con un escudo en vez de campana y
  el titulo **Avisos de admin**. `Cabecera.svelte` la pinta solo cuando la sesion
  es de un admin. Lista los anillos de resenas pendientes
  (`GET /admin/fraude/alertas-resenas?estado=pendiente`) con sus cuentas y un
  enlace **Revisar** a `/panel?s=fraude&t=resenas`. **No tiene Marcar leida
  propio**: un anillo deja de contar cuando se marca revisado o descartado en el
  panel.

El backend no cambio. Que cada admin tenga su propio estado de lectura pide una
tabla nueva del lado del backend, y esta pedido en `docs/BACKEND-PENDIENTE.md`.

## El panel de fraude, en dos pestanas (2026-09-20)

`PanelFraude.svelte` tiene ahora dos pestanas, **Intentos de entrada** y
**Resenas en anillo**. Se ve una a la vez, pero las dos siguen montadas y cada una
conserva su filtro y su pagina al cambiar de una a otra.

- El select de tipo de las alertas de login esta agrupado en **Por IP**, **Por
  cuenta** y **Ubicacion y acceso**. Es solo del select: el backend sigue
  filtrando un solo tipo a la vez.
- `/panel?s=fraude&t=resenas` abre directo en los anillos. `demo-anillo-resenas.ps1`
  abre ese enlace, y la campana del admin tambien lo usa.
- **Se quito la pestana Demo del panel del admin.** Las demos viven en la pestana
  Comandos del panel de las cuentas desarrollador (ver `comandos.txt`).

## Las graficas de Tendencias (2026-09-20)

En `TendenciasAuto.svelte` cada fila de un ranking lleva:

- una insignia de puesto, con los tres primeros tenidos de color;
- el nombre en una sola linea, con el texto completo al pasar el cursor;
- la cifra;
- una barra redondeada que mide contra el mayor valor de esa misma tarjeta.

La unidad va en el subtitulo de la tarjeta, por ejemplo "en sesiones distintas", y
no repetida en cada fila. En **Compras en ascenso** la barra es el periodo actual y
una marca vertical es el periodo anterior, con la etiqueta **nuevo** o **N veces**.
La leyenda solo sale si alguna fila tiene marca. La tarjeta ancha reparte sus filas
en columnas, dos en pantalla ancha. No hay ruta nueva en el backend.
