# Pendientes

Lo que se sabe que falta. Un solo sitio para mirar.

**Al 2026-08-30.** Lo que esta hecho y probado no esta aqui: esta en
`docs/TRASPASO.md`.

| # | Que | De quien | Cuanto | Urgencia |
|---|---|---|---|---|
| 1 | El precio se congela al PAGAR, no al agregar | los dos | ~2 h | **alta: es un cobro incorrecto** |
| ~~2~~ | ~~La semilla no respalda con compras las 86 resenas~~ | -- | -- | **CERRADO el 2026-08-30** |
| 3 | `Carrito.svelte` quedo muerto (937 lineas) | Meme | 5 min | baja |
| 4 | El grafo se queda viejo y el ETL relee todo | Meme | ver su doc | baja |

Y de la **Entrega 2** falta trabajo que no es un bug:

| Que | Puntos | De quien |
|---|---|---|
| Oferta de inventario limitado enchufada al backend | 3 | Jose David (`redis/` ya tiene el Lua y el arnes) |
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

**La de Jose David:** que el carrito de Redis guarde tambien el
`id_precio_historial` de cada linea. El hash pasa de `id_oferta -> cantidad` a
`id_oferta -> cantidad:id_precio_historial`, o a dos campos.

**La de Meme (migracion 013):** que `agregar_linea()` acepte un
`id_precio_historial` opcional y lo use en vez de buscar el vigente. **La 007 no
se edita** -- es la regla de `migrations/README.md` -- se hace la siguiente.

## La trampa

Un `id_precio_historial` de hace 24 horas puede apuntar a un precio que ya no
rige, y la persona tiene derecho a ese precio... hasta cierto punto. Hay que
decidir **cuanto vale un precio congelado**: si es para siempre mientras el
carrito viva, o si pasadas N horas se recalcula avisando.

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

# 3. `Carrito.svelte` quedo muerto

937 lineas que ya no importa nadie: el panel lateral es `CarritoRedis.svelte`
desde la mudanza a Redis.

Se dejo un dia por si hacia falta de referencia. **Borrarlo**, junto con lo que
solo el usaba de `pedido.ts` (las funciones del carrito viejo:
`leerPedidoAbierto`, `guardarPedidoAbierto`, `olvidarPedidoAbierto`,
`crearPedido`, `agregarLinea`, `restarLinea`, `quitarLinea`,
`cambiarDireccionPedido`).

Ojo antes de borrar de `pedido.ts`: **`MisPedidos` y `Pedido.svelte` siguen
usando parte de ese archivo**. Hay que mirar cual, no borrar el archivo entero.

Un componente muerto que se parece al vivo es una trampa para el siguiente que
entre.

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
