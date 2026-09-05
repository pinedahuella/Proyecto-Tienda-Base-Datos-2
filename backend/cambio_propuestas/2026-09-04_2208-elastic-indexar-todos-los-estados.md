# Cambio: Elasticsearch pasa a indexar TODOS los estados, no solo `activo`

**Fecha:** 2026-09-04, noche.
**Alcance:** decision de diseño que toca `backend/` (rutas nuevas, sin
escribir todavia) y `etl/` (del compañero, el cambio esta descrito abajo,
no aplicado). Continua a
`cambio_propuestas/2026-09-04_2124-pendiente-busqueda-cola-elastic.md`.

## Que cambia, en una frase

`elastic/README.md` dice hoy, y hasta ahora era correcto: *"Solo entra lo
que esta ACTIVO... Se filtra al EXTRAER y no al consultar, a proposito"*.
**Esa decision se revierte.** El indice va a guardar productos en
cualquier estado (`activo`, `inactivo`, `borrador`, `en_revision`,
`rechazado`); quien filtra a partir de ahora es la ruta del backend que
consulta, no el ETL que carga.

## Por que se revierte, si ya estaba razonado

Porque ahora hace falta algo que antes no: **una vista de admin que busque
sobre el catalogo entero**, incluyendo lo que no circula. Con el indice
recortado a solo `activo`, eso es imposible sin mantener un segundo indice
o reconstruir permanentemente contra Mongo -- y ya se decidio que
Elasticsearch fuera la unica fuente para el buscador.

Ademas, simplifica el worker que va a mantener el indice al dia (el que lee
`pendiente_busqueda`, ver la propuesta anterior): con TODOS los estados
adentro, el worker **siempre hace la misma operacion** (reindexar el
documento tal como esta hoy). Sin este cambio, tendria que decidir en cada
pasada si el producto "entra" o "sale" del indice segun su estado -- dos
caminos en vez de uno.

## Como se compensa el riesgo que esa decision original evitaba

El motivo original de filtrar al extraer segue siendo valido: *"filtrar al
consultar deja la puerta a que una ruta se olvide del filtro y ensene
productos rechazados a un comprador"*. No se descarta ese riesgo, se
traslada la defensa: en vez de que los datos mismos garanticen que solo hay
productos publicos, **el codigo de la ruta publica fuerza el filtro sin que
se le pueda pedir lo contrario** -- mismo patron que ya usa
`ProductosService` sobre Mongo (`ESTADO_PRODUCTO_VISIBLE`, "lista blanca,
no lista negra").

Van a ser DOS rutas nuevas de backend (no escritas todavia, es el paso
siguiente):

```
GET /buscador/productos         publica. El query de Elasticsearch SIEMPRE
                                 lleva { term: { estado: "activo" } } en un
                                 filter -- no es un query param, esta fijo
                                 en el codigo del servicio.

GET /buscador/productos/admin   protegida, solo admin. Mismo query, SIN
                                 ese filter: trae cualquier estado.
```

## Lo que se hizo HOY, a mano, como demostracion (no es el arreglo real)

Como `backend/` no puede tocar `etl/` ni `mongo/`, y ahora mismo el
catalogo entero en Mongo esta en `activo` (102 de 102 -- no hay ningun
producto en otro estado para probar de verdad), se creo un producto de
prueba y se indexo a mano en Elasticsearch, con la forma EXACTA que arma
`etl/extraer_busqueda.js`, para tener un documento no-activo real con el
que probar las dos rutas cuando se escriban:

```
Mongo:          _id 103, "PRUEBA producto inactivo para elastic", estado: inactivo
Elasticsearch:  PUT /mesh_productos/_doc/103, con estado: "inactivo"
```

Confirmado con `GET /mesh_productos/_count`: **103** documentos (102 reales
+ este de prueba). `GET /mesh_productos/_doc/103` devuelve el documento con
`"estado":"inactivo"`.

**Esto es manual y no sobrevive un `bash etl/cargar_busqueda.sh`**: esa
etapa borra el indice entero y lo reconstruye solo con lo que diga el
extractor, que hoy sigue filtrando por `activo`. Se deja explicito para que
nadie confunda este producto 103 con algo que el ETL ya sostiene solo.

## El cambio real que le toca al compañero: `etl/extraer_busqueda.js`

Hoy:

```js
// Solo lo ACTIVO. Se filtra aqui y no al consultar, a proposito...
const FILTRO = { estado: 'activo' };
```

Pasa a:

```js
// Se indexa TODO el catalogo, en cualquier estado. El filtro de "solo lo
// publico" ya no vive aca: lo aplica la ruta publica del backend
// (GET /buscador/productos), de forma fija, no condicionada a ningun
// parametro. Ver cambio_propuestas/2026-09-04_2208-elastic-indexar-todos-los-estados.md
const FILTRO = {};
```

Nada mas de `extraer_busqueda.js` cambia: `estado: p.estado` ya se
proyecta en cada documento (linea que ya existia), asi que no hace falta
agregar ningun campo, solo dejar de excluir por el.

## Una prueba existente que va a EMPEZAR A FALLAR, y hay que actualizarla

`pruebas/busqueda.sh`, parte 4 ("UN PRODUCTO RECHAZADO NO APARECE"), hoy
comprueba que el `_id` 105 (`rechazado` en Mongo) responde **404** contra
`GET /mesh_productos/_doc/105`. Con este cambio, **si va a estar** en el
indice (con `estado: "rechazado"` adentro) -- la ausencia ya no es la forma
correcta de comprobar que un comprador no lo puede ver.

Esa parte del arnes necesita reescribirse para probar la regla nueva: que
el documento SI este en el indice (`200`, con `estado: "rechazado"`), pero
que **la ruta publica del backend** (`GET /buscador/productos`, cuando
exista) no lo devuelva buscandolo por nombre. Hoy esa prueba mide contra
Elasticsearch solo; con el filtro movido al backend, tiene que medir contra
la ruta del backend para seguir midiendo algo real.

## Que sigue

1. Escribir las dos rutas (`GET /buscador/productos` con el filtro fijo,
   `GET /buscador/productos/admin` sin el) -- backend, pendiente.
2. El worker que lee `pendiente_busqueda` y reindexa -- backend, pendiente,
   ya simplificado por este cambio (una sola operacion, no dos).
3. El cambio de una linea en `etl/extraer_busqueda.js` -- compañero.
4. Actualizar la parte 4 de `pruebas/busqueda.sh` -- compañero.
