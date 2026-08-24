# Frontend

SvelteKit.

## Las paginas

| Ruta | Que es | Pide sesion |
|---|---|---|
| `/` | el catalogo | no |
| `/producto/[id]` | la ficha de un producto | no |
| `/entrar` | iniciar sesion | no |
| `/registro` | crear cuenta | no |
| `/panel` | perfil, direcciones, y segun el rol la gestion o los productos | si |

El catalogo es la pagina de inicio y es publica: `GET /productos` no pide la
cookie, asi que se puede navegar la tienda sin cuenta. Por eso el inicio de
sesion se movio a `/entrar` y la cabecera lleva el enlace.

**Todo el filtrado lo hace el backend.** En el catalogo no se filtra en memoria:
si se hiciera, un filtro solo alcanzaria a los productos ya descargados y
mentiria en cuanto haya mas de una tanda.

El panel muestra una cosa u otra segun el rol: un admin ve la gestion de
usuarios, un vendedor ve sus productos, y un comprador el resumen. Esconder un
panel no da permisos -- quien decide es el backend, que responde 403.

## Archivos

| Archivo | Que contiene |
|---|---|
| `src/routes/+layout.svelte` | la paleta, los estilos globales y el armazon de la pagina |
| `src/routes/+page.svelte` | el catalogo, con sus filtros |
| `src/routes/producto/[id]/+page.svelte` | la ficha: la foto arriba y el detalle debajo |
| `src/routes/entrar/+page.svelte` | inicio de sesion |
| `src/routes/registro/+page.svelte` | crear cuenta |
| `src/routes/panel/+page.svelte` | panel |
| `src/lib/PanelAdmin.svelte` | gestion de usuarios, dentro del panel |
| `src/lib/PanelVendedor.svelte` | los productos del vendedor, dentro del panel |
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
`id_categoria`, `precio_min`, `precio_max`, `estado_variante` y `id_vendedor`.
La casilla "Solo variantes activas" manda `estado_variante=activa`, y el backend
la mete en el mismo `$elemMatch` que el rango de precio: marcarla con un rango
puesto pide **una variante que cumpla las dos cosas**, no dos variantes
distintas que cumplan una cada una.

`id_vendedor` no tiene campo propio porque no hay ruta que liste vendedores. Se
pone desde la tarjeta, con "Ver todo de ...".

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

## El inventario del vendedor: dos modos

La pantalla de Inventario del panel del vendedor **no ensena siempre lo mismo**,
y no es un capricho de diseno: es la unica forma honesta de pintar lo que el
backend contesta.

`GET /vendedor/productos/inventario` es **todo o nada**. Con que a UNA variante
le falte su fila en `inventario`, la peticion entera se cae con 409 y no
devuelve el stock de ninguna. Y el mensaje del 409 nombra **una sola** variante,
aunque falten diez.

De ahi los dos modos:

| Modo | Cuando | Que ensena |
|---|---|---|
| **pendientes** | falta alguna existencia | solo lo que falta, y un mensaje con los **ids** de los productos incompletos |
| **catalogo** | ya no falta nada | todos los productos agrupados, con sus variantes y su stock real |

Ensenar el catalogo entero mientras algo falta es lo que hacia que no se viera
que arreglar: 31 productos sanos tapando la unica variante rota.

**Como se sabe QUE variante falta.** El backend recorre `producto.variantes` en
el orden del documento y se detiene en la primera sin fila de inventario. Asi
que de un solo 409 se deducen tres cosas, y solo tres:

- las variantes **anteriores** a la nombrada: si tienen inventario
- la **nombrada**: no lo tiene
- las **posteriores**: no se sabe todavia

Lo que no se sabe sale como "por revisar", nunca como "sin existencias":
afirmar lo segundo seria inventarse un hecho. Se termina de saber solo, porque
al crear la que falta el siguiente 409 nombra a la siguiente.

El id de la variante sale de parsear el texto del 409 (`varianteDelMensaje()`).
Es fragil a proposito y esta contenido: si el texto cambia, la funcion devuelve
`null` y la pantalla cae al caso honesto -- el producto queda marcado incompleto
y todas sus variantes salen "por revisar". Se pierde precision, no se gana una
mentira.

**Vacio y 0 no son lo mismo.** Al publicar, `stock_inicial: 0` **si** crea la
fila de inventario (queda en cero, que es un dato: agotado). Dejar el campo
vacio no la crea, y esa es la variante que despues aparece como pendiente. Por
eso al crear un producto dejando alguna vacia sale un aviso con el id del
producto y un boton para ir a arreglarlo: antes solo decia "Producto creado" y
el 409 aparecia dias despues.

## El pedido

`src/lib/Pedido.svelte` (en el panel) y el boton "Agregar al pedido" de la ficha
consumen las cuatro rutas de `/comprador/pedidos`. Ninguna pide rol, solo
sesion: comprar no es privilegio de un rol, asi que el panel lo ensena a todos.

Dos huecos del backend que la pantalla **dice** en vez de esconder:

- **No hay ruta para cerrar la compra.** `comprar_pedido()` existe en PostgreSQL
  pero nadie la expone, asi que el pedido se queda en `pendiente`.
- **Agregar una linea no reserva stock.** Solo lo lee para avisar. Dos personas
  pueden meter la misma ultima unidad.

**No hay ruta para listar los pedidos de uno**, solo `GET /comprador/pedidos/:id`.
Por eso el id del pedido abierto se guarda en `localStorage` (`mesh.pedido`): si
se pierde, el pedido sigue en la base pero desde el navegador ya no se llega a
el.

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

## Lo que todavia falta

**No se puede cerrar la compra.** Falta la ruta del backend que llame a
`comprar_pedido()` / `cancelar_pedido()`. La pantalla del pedido ya esta y lo
avisa.

**No se puede bajar la cantidad de una linea.** `agregar_linea()` SUMA a lo que
ya habia, y no hay forma de fijar un total. Para bajar hay que quitar la linea
entera y volver a agregarla.

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
