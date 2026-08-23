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

## Lo que todavia falta

**Las categorias del catalogo estan escritas a mano** en `+page.svelte`. Cuando
se hizo, la unica ruta que las listaba pedia sesion de vendedor y el catalogo es
publico. Ya existe `GET /categorias`, asi que esa lista se puede cambiar por la
llamada.

**La ficha del producto se trae con un rodeo.** Usa el cursor de `GET /productos`
(`despues_de = id - 1` con `limite = 1`) porque cuando se escribio no habia ruta
publica de detalle. Ya existe `GET /productos/:id`.

**No hay carrito ni compra.** Las funciones de la base ya estan
(`crear_pedido`, `agregar_linea`, `comprar_pedido`, `cancelar_pedido`), falta la
ruta del backend y la pantalla.

## Cosas que se aprendieron a golpes

**`conJson` no hace la peticion.** Arma las opciones para las que mandan cuerpo
JSON; la que pide es `pedir`. Usarla como si pidiera devuelve un objeto sin `ok`
y sin `mensaje`, asi que la pagina sale vacia **y sin ningun error a la vista**.

**Cargar los datos con `$effect` se repite solo.** En el panel se vieron seis
llamadas en el mismo instante, y como todo colgaba de `{#if cargando}`, cada
vuelta desmontaba el arbol y borraba el formulario a medio escribir. Va con
`onMount`, y la pantalla de carga solo tapa la primera vez.

**Un `<input type="number">` con `bind:value` guarda un numero, no texto.**
Llamarle `.trim()` revienta con "is not a function".
