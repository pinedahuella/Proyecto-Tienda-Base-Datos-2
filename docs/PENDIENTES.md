# Pendientes

Lo que se sabe que falta. Un solo sitio para mirar.

**Al 2026-08-29.** Lo que esta hecho y probado no esta aqui: esta en
`docs/TRASPASO.md`.

| # | Que | De quien | Cuanto | Urgencia |
|---|---|---|---|---|
| 1 | El precio se congela al PAGAR, no al agregar | los dos | ~2 h | **alta: es un cobro incorrecto** |
| 2 | La semilla no respalda con compras las 86 resenas | Meme | ~2 h | media |
| 3 | `Carrito.svelte` quedo muerto (937 lineas) | Meme | 5 min | baja |
| 4 | El grafo se queda viejo y el ETL relee todo | Meme | ver su doc | baja |

Y de la **Entrega 2** falta trabajo que no es un bug:

| Que | Puntos | De quien |
|---|---|---|
| Oferta de inventario limitado enchufada al backend | 3 | Jose David (`redis/` ya tiene el Lua y el arnes) |
| `GET /admin/fraude/anillos` | parte de 3 | Jose David (`neo4j/` ya tiene las consultas) |
| Resenar desde el pedido (bloque 5 de BACKEND-PENDIENTE) | -- | Jose David |
| **Comparativa grafos vs columnar**, con la defensa de la NO elegida | 1.5 | **nadie todavia** |
| **Diagrama de arquitectura** (el ER no lo es) | parte de 1 | **nadie todavia** |

Los dos ultimos **no dependen de nadie mas** y son 2.5 puntos.

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

# 2. Las 86 resenas sembradas no tienen compra detras

Jose David decidio, y lo dejo escrito en su servicio, que **solo se puede
calificar a un vendedor al que se le compro y se le pago**. Es su decision y se
queda: es la "compra verificada" de Amazon y es defendible.

El problema no es la regla: es que **la semilla no la cumple**. Medido:

```
  pares (comprador, producto) con compra pagada ....... 11
  de las 86 resenas sembradas, con compra detras ....... 2
```

**84 de las 86 no se podrian haber escrito bajo la regla que el sistema exige.**

## Que se rompe hoy

En casi todos los productos el boton "Escribir una resena" no aparece. Existe la
funcionalidad y no se puede demostrar salvo en unos pocos productos.

**Mientras tanto:** `bash pruebas/resenas.sh` imprime en que producto y con que
cuenta SI aparece. Es el mapa hasta que esto se arregle.

## El arreglo

En `migrations/datos/generador.js`: que cada resena tenga su compra. Las seis
trampas:

1. **Usar las funciones, no INSERT a mano** -- `comprar_carrito()` de la 012 hace
   las tres de una.
2. **Comprar mueve el stock**, y hay numeros DOCUMENTADOS que dependen de el (las
   "6 variantes donde la tienda no tiene y otro si" de `docs/base-de-datos.md`).
   Hay que remedirlos o el documento pasa a mentir.
3. **Una de cada diez ofertas nace con stock 0** a proposito: `comprar_pedido`
   las rechaza.
4. **Las fechas quedan al reves**: `crear_pedido` usa `now()`, asi que la compra
   sale hoy y la resena en abril. Resenada antes de comprada, sin que nada falle.
5. **Doce pedidos de varias lineas**, no 86 pedidos.
6. **El azar va DESPUES de la linea 1718**, o se reescriben las 552 ofertas.

## Y el candado, que es lo que impide que vuelva

La contradiccion aparecio porque nada la vigilaba. Va la comprobacion **10** al
`DO` del final de `001_catalogo.sql`:

```sql
-- 10. Toda resena tiene una compra pagada detras.
SELECT count(*) INTO v_mal
FROM resena r
WHERE NOT EXISTS (
    SELECT 1 FROM pedido pe
    JOIN pago pg USING (id_pedido)
    JOIN estado_pago epa USING (id_estado_pago)
    JOIN pedido_producto pp USING (id_pedido)
    WHERE pe.id_usuario = r.id_usuario
      AND pp.id_producto_mongo = r.id_producto_mongo
      AND epa.estado_pago_nombre = 'pagado');

IF v_mal > 0 THEN
    RAISE EXCEPTION '% resenas no tienen una compra pagada detras', v_mal;
END IF;
```

## La consecuencia para la Entrega 2

Con esta regla, **el anillo de fraude tiene que comprarse entre si antes de
calificarse**. Es mas realista -- un anillo de verdad compra barato para poder
resenar -- pero **hay que sembrarlo asi**, y no se puede descubrir el dia de la
demostracion.

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
