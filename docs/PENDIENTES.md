# Pendientes

Lo que se sabe que falta. Un solo sitio para mirar.

**Al 2026-09-03.** Lo que esta hecho y probado no esta aqui: esta en
`docs/TRASPASO.md`.

| # | Que | De quien | Cuanto | Urgencia |
|---|---|---|---|---|
| 1 | El precio se congela al PAGAR, no al agregar | **falta la mitad de Jose David** | ~1 h | **alta: es un cobro incorrecto** |
| ~~2~~ | ~~La semilla no respalda con compras las 86 resenas~~ | -- | -- | **CERRADO el 2026-08-30** |
| ~~3~~ | ~~`Carrito.svelte` quedo muerto~~ | -- | -- | **CERRADO el 2026-08-30** |
| 4 | El grafo se queda viejo y el ETL relee todo | Meme | ver su doc | baja |
| 5 | Dos asignadores de id de producto que no se hablan | Jose David decide | ver abajo | **alta: puede machacar un producto sin dar error** |
| 6 | La nota no llega al catalogo hasta que corre el ETL | sin dueno | ver abajo | media |

---

# 5. Dos asignadores de id de producto que no se hablan

**Se encontro midiendo, no leyendo, y existe aunque nadie haga nada mas.**

`backend/src/services/vendedores/productos.service.ts` deja escrito que los
productos ya no se registran en PostgreSQL y que su id sale de "el maximo que ya
existe, mas uno". Ese maximo lo lee de **MongoDB**, en `siguienteIdProducto`.
Mientras tanto `productos.id_producto` de PostgreSQL sigue siendo un `bigserial`
con su propia cuenta.

Son dos numeradores independientes sobre el mismo espacio de ids, y **ya habian
divergido**: MongoDB tenia cuatro productos publicados desde el panel cuya fila
no existe en PostgreSQL, y la secuencia de PostgreSQL estaba a punto de entregar
justo esos numeros. El primer producto insertado en PostgreSQL se habria llevado
un id que en MongoDB ya era de otro producto, y el `replaceOne` del ETL lo
habria machacado **sin un solo error**.

Y no hay nada que avise: `etl/cargar.js` barre sobrantes en `categorias` y en
`productos_eventos`, pero **no tiene ningun barrido para `db.productos`**. El
verificador del arranque tampoco lo ve, porque solo se queja si Mongo tiene
MENOS documentos que PostgreSQL, y aqui tendria de mas.

**Lo que hay hoy es un parche, no un arreglo.** `migrations/lote/generar_lote.sql`
recibe los dos maximos de MongoDB, comprueba que sean creibles y alinea las dos
secuencias con `setval` antes de insertar. Eso resuelve el caso del generador y
deja los dos numeradores de acuerdo hacia adelante, pero **solo para ese
camino**. Cualquier otro `INSERT` en `productos` de PostgreSQL sigue expuesto.

La decision de fondo le toca a Jose David y esta escrita en
`docs/BACKEND-PENDIENTE.md`: si el id de producto debe salir de una sola fuente,
y cual.

---

# 6. La nota del catalogo no se refresca sola

Los documentos de MongoDB ya traen `resenas_promedio` y `resenas_total`, y salen
del ETL. Eso deja dos huecos conocidos, los dos medidos:

**Una resena nueva no mueve la nota** hasta que alguien corre el ETL. Es el mismo
problema del pendiente 4 y de `docs/PENDIENTE-OUTBOX.md`, ahora con un dato mas
encima. Mientras tanto la ficha del producto y la lista del catalogo pueden
ensenar dos numeros distintos: la ficha calcula en vivo contra PostgreSQL y la
lista lee la copia de Mongo.

**Un producto que solo vive en MongoDB nunca actualiza su nota.** `etl/extraer.sql`
itera sobre la tabla `productos` de PostgreSQL, asi que un producto publicado
desde el panel no pasa por ahi jamas y su nota se queda en el 0 con que lo
rellena `mongo/002_resenas.js`. Y no es teorico: esos productos tienen ofertas y
se pueden comprar, o sea que se pueden resenar hoy.

El arreglo de fondo es que el promedio se calcule agrupando `resena` por
`id_producto_mongo`, con independencia de que el producto tenga fila en
PostgreSQL. Es una etapa nueva del ETL, no un parche.

---

Y de la **Entrega 2** falta trabajo que no es un bug:

| Que | Puntos | De quien |
|---|---|---|
| Oferta de inventario limitado enchufada al backend | 3 | **casi**: Jose David la conecto al carrito el 2026-09-03. Faltan sus pasos 2 y 4 (ver `backend/elementos Generales/plan pendiente/inventario-limitado.md`). La migracion 014 y el frontend YA estan |
| ~~`GET /admin/fraude/anillos`~~ | ~~parte de 3~~ | **HECHA el 2026-08-30, y el panel ya la consume** |
| Resenar desde el pedido (bloque 5 de BACKEND-PENDIENTE) | -- | Jose David |
| **Comparativa grafos vs columnar**, con la defensa de la NO elegida | 1.5 | **nadie todavia** |
| **Diagrama de arquitectura** (el ER no lo es) | parte de 1 | **nadie todavia** |

Los dos ultimos **no dependen de nadie mas** y son 2.5 puntos.

Jose David agrego ademas **dos reportes de admin** que nadie habia pedido y que
suman: `GET /admin/reportes/ventas` y `GET /admin/reportes/reservaciones`. Su
pantalla es `frontend/src/lib/PanelReportes.svelte`, hecha el 2026-08-30.

---

# 1. El precio se congela al PAGAR, no al agregar

**Es lo mas urgente de esta lista porque es un cobro incorrecto**, no un detalle
de presentacion.

## Que pasa

`agregar_linea()` congela el precio al agregar al carrito. La migracion 007 lo
dice textual: *"si el vendedor lo sube despues, este pedido conserva el que se le
mostro a la persona"*.

Con el carrito en Redis, agregar y comprar pasan **en el mismo instante** --
`POST /carrito/comprar` llama a `comprar_carrito()`, que hace las tres cosas de
una. Asi que el precio que se congela es el del momento de PAGAR.

Si el vendedor lo sube mientras el carrito espera, **se le cobra el nuevo, sin
ningun error y sin que nadie se entere**. Y el carrito puede esperar 24 horas.

Peor: `GET /carrito` ya ensena un precio, la persona decide con ese numero, y
puede no ser el que se cobre. El endpoint del carrito lo reconoce por escrito
(*"cerrar la ventana de carrera entre ver y pagar es la fase 2"*).

## El arreglo, y son dos mitades

**La de Meme: HECHA el 2026-08-30, es `migrations/013_precio_del_carrito.sql`.**
`agregar_linea()` acepta un `id_precio_historial` DENTRO de `p_linea` y lo usa
en vez de buscar el vigente. La firma no cambio, asi que la 012 no se toco y el
campo viaja solo. Sin el campo se comporta igual que antes, para que la
migracion pudiera correr antes que el backend y para que la semilla siguiera
cargando.

Ademas exige que ese precio sea **de esa misma oferta**: sin ese filtro,
mandar el id de una fila de otra oferta seria elegir el precio a voluntad. Y no
bloquea la compra cuando el precio ya no es el vigente: **cobra el congelado y
lo dice**, con `precio_cambio`, `precio_congelado` y `precio_actual` en lo que
devuelve. La base informa; la politica la decide la aplicacion.

Medido en una transaccion con ROLLBACK: precio visto Q6,263, el vendedor lo
sube a Q31,315, se compran 3 unidades -> **cobra Q18,789** (3 x 6,263) en vez de
Q93,945. Con un precio de otra oferta o un id inventado, levanta excepcion.

**La de Jose David, que es lo que FALTA:** que el carrito de Redis guarde
tambien el `id_precio_historial` de cada linea -- el hash pasa de
`id_oferta -> cantidad` a llevar los dos datos -- que `POST /carrito/comprar` lo
mande, y que mire `precio_cambio` para armar los `avisos`. Los tres pasos estan
escritos al final de la 013.

**Hasta que eso exista, el precio se sigue congelando al pagar.** La 013 lo
habilita, no lo termina.

## La trampa, que sigue SIN decidirse

Un `id_precio_historial` de hace 24 horas puede apuntar a un precio que ya no
rige, y la persona tiene derecho a ese precio... hasta cierto punto. Hay que
decidir **cuanto vale un precio congelado**: si es para siempre mientras el
carrito viva, o si pasadas N horas se recalcula avisando.

La 013 **no la decide a proposito**: cobra el congelado y marca `precio_cambio`.
Cuanto vale la palabra que se le dio a un cliente es una decision comercial y no
le toca a la base -- le toca a quien escriba el paso 3 del backend.

`POST /comprador/pedidos/:id/comprar` ya resuelve esto con `confirmar_cambios` y
una lista de `avisos`. **Lo mismo sirve aqui**: si el precio cambio, el checkout
lo dice y pide confirmar. No hay que inventar nada, hay que portarlo.

---

# 2. Las 86 resenas sembradas no tienen compra detras -- CERRADO el 2026-08-30

**Ya no aplica.** Se deja escrito porque el arreglo cambio numeros que otros
documentos citan, y porque el candado que lo cierra hay que saber que existe.

## Que pasaba

Jose David decidio, y lo dejo escrito en su servicio, que **solo se puede
calificar a un vendedor al que se le compro y se le pago** -- y al MISMO
vendedor, por la cadena `pedido_producto -> precio_historial -> oferta ->
oferta.id_usuario`. Es su decision y se queda: es la "compra verificada" de
Amazon y es defendible.

El problema no era la regla: era que **la semilla no la cumplia**. Solo 2 de las
86 resenas tenian una compra detras, asi que 84 describian algo que el propio
sistema habria rechazado al escribirlo, y el boton "Escribir una resena" no
aparecia casi en ningun producto.

## Como quedo, medido contra una base recien creada

```
  resenas ......................................... 86
  de esas, con compra pagada a ESE vendedor ....... 86   (antes 2)
  resenas fechadas antes de su compra .............  0
  pedidos sembrados ...............................  10  (antes 2)
  lineas de pedido ................................  97  (antes 3)
  pares comprados y AUN sin resenar ...............  11
```

**Esos numeros son de ese momento.** Ese mismo dia, mas tarde, se sembro el
anillo de fraude y subieron a **90 resenas, 13 pedidos y 101 lineas** (11
usuarios, 556 ofertas). Se dejan como se midieron: lo que la medicion demuestra
-- que las 86 pasaron de 2 a 86 respaldadas -- no cambia.

Los 11 sin resenar son a proposito: `pruebas/resenas.sh` busca un par comprado
y todavia sin calificar, y hace `exit 1` si no queda ninguno. Si cada compra
llevara su resena encima, **el arnes moriria antes de probar las 5 rutas** y su
mapa de "donde SI se puede resenar" saldria vacio. Hoy imprime 8 productos.

## Como se hizo, y las cuatro decisiones que no son obvias

Todo en `migrations/datos/generador.js`; no se toco ninguna migracion numerada.

1. **Se compra con `comprar_carrito()` de la 012**, no con `INSERT` a mano: ella
   congela el `id_precio_historial` y arma `nombre_vendedor` desde la base, dos
   cosas que a mano se copian mal y que `pedido_producto` no protege con ningun
   UNIQUE.
2. **Las fechas se corrigen despues de comprar.** `crear_pedido` usa `now()`, asi
   que la compra saldria HOY y la resena en abril -- resenada antes de comprada,
   sin que nada falle. Se hace `UPDATE` de `pedido.fecha_creacion`,
   `pago.fecha_cancelacion` y `stock_movimiento.fecha_movimiento`; se comprobo
   que no hay ningun trigger sobre esas tres tablas.
3. **Los pedidos se agrupan por el mes de la OFERTA, no por el de la resena.**
   Agrupando por la resena, la oferta mas nueva del grupo queda posterior a la
   resena mas vieja y el pedido no se puede fechar sin quedar antes de que la
   oferta existiera.
4. **El sorteo nuevo va DESPUES de la linea 1718 del generador**, que es la
   ultima extraccion de la secuencia global `azar()`. Uno metido antes reescribe
   las 552 ofertas enteras. Comprobado con un `diff`: todo lo anterior a la parte
   social quedo bit a bit igual.

## El candado, que es lo que impide que vuelva

Dos comprobaciones nuevas en el `DO` final de `001_catalogo.sql`, la **10** y la
**11**: que toda resena tenga una compra pagada a ese vendedor, y que ninguna
este fechada antes de su compra. Fallan la migracion entera.

**Los JOIN de la 10 son calcados de `exigirCompraPagada` del backend**, con su
`estado_pedido_nombre <> 'cancelado'` incluido. El SQL que este mismo documento
proponia antes **no miraba el vendedor ni el cancelado**: habria aprobado una
resena de Ana a Carlos por algo que Ana le compro a Lucia. Un candado que valida
algo distinto de lo que el sistema exige es peor que no tenerlo.

## Lo que cambio de numeros, y donde estaba escrito

`115 comentarios / 46 votos / 29 respuestas` pasaron a **114 / 62 / 28**: los
pares elegidos cambian (ahora se filtran por stock y por precio quieto) y
`azarSocial` reparte distinto. Se actualizaron `docs/base-de-datos.md`,
`docs/BACKEND-PENDIENTE.md`, `migrations/README.md`, `neo4j/README.md`,
`etl/README.md` y `etl/extraer_grafo.sql`.

## Y una afirmacion que hay que dejar de repetir

Este documento decia que **"el anillo de fraude tiene que comprarse entre si
antes de calificarse"**. No es cierto para el anillo que existe: se siembra en
**Neo4j**, con cuentas de id negativo y etiqueta `:Prueba`, y no pasa por
`POST /resenas` ni toca PostgreSQL. Solo aplicaria si algun dia se sembrara en
la fuente de verdad, que `neo4j/README.md` ya descarto por escrito.

---

# 3. `Carrito.svelte` quedo muerto -- CERRADO el 2026-08-30

Borrado. 937 lineas que ya no importaba nadie: el panel lateral es
`CarritoRedis.svelte` desde la mudanza a Redis. Se comprobo primero que ningun
archivo lo importara.

## Y la lista que traia este pendiente estaba MAL

Decia que con el se podian borrar ocho funciones de `pedido.ts`
(`leerPedidoAbierto`, `guardarPedidoAbierto`, `olvidarPedidoAbierto`,
`crearPedido`, `agregarLinea`, `restarLinea`, `quitarLinea`,
`cambiarDireccionPedido`). **Siete de esas ocho siguen vivas**, medido buscando
cada nombre por todo el frontend:

| Funcion | Quien la usa todavia |
|---|---|
| `leerPedidoAbierto` | `Pedido.svelte`, `producto/[id]` |
| `guardarPedidoAbierto` | `Pedido.svelte`, `producto/[id]` |
| `olvidarPedidoAbierto` | `Pedido.svelte`, `sesion.ts`, `+layout.svelte`, `producto/[id]` |
| `crearPedido` | `Pedido.svelte`, `producto/[id]` |
| `agregarLinea` | `Pedido.svelte`, `producto/[id]` |
| `quitarLinea` | `Pedido.svelte` |
| `cambiarDireccionPedido` | `Checkout.svelte` |

Borrar las ocho habria roto cinco archivos. Lo que si estaba muerto son **tres**,
y dos ni figuraban en la lista: `restarLinea` (con su interfaz `LineaRestada`),
`leerDesmarcadas` y `guardarDesmarcadas`. Esas tres se fueron.

`LLAVE_MARCADAS` se queda: ya nadie la escribe, pero `olvidarPedidoAbierto` la
sigue BORRANDO a proposito, porque en los navegadores que usaron el carrito
viejo quedo escrita y solo se va por ahi.

**La leccion, que es la de siempre en este proyecto:** una lista de codigo
muerto escrita a mano caduca sin avisar. Antes de borrar, se mide -- un `grep`
por nombre cuesta un minuto y aqui evito romper cinco archivos.

---

# 4. El grafo se queda viejo y el ETL relee todo

Esta escrito aparte porque es largo: **`docs/PENDIENTE-OUTBOX.md`**.

- Una resena nueva no llega a Neo4j hasta que alguien corre el ETL, y el panel de
  fraude no avisa de que mira datos viejos.
- El ETL relee las 86 resenas cada vez (14 s medidos).
- La salida es un outbox: un trigger encola el evento en la misma transaccion.

**Lo mas barato de ese documento es la conciliacion** -- cuatro `count` que
comparan PostgreSQL contra Neo4j y avisan. Se puede hacer hoy y ya seria util.

**Y paga dos veces:** el outbox es la respuesta al documento de estrategia de
consistencia de la Entrega 3, que son 5 puntos de puro texto.
