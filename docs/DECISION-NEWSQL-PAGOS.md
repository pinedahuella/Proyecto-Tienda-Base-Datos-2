# ADR-12 -- Pagos en un motor NewSQL, evaluado y descartado por ahora

En el registro unico (`docs/DECISIONES.md`) es el ADR-12. En el informe de la
Entrega 3 se cito como ADR-8.

Fecha 2026-09-25. Estado decidido, se queda PostgreSQL.

Es el punto opcional de la Entrega 3. El enunciado pide contrastar un motor
NewSQL contra el modelo relacional que ya tenemos para el modulo de pagos, y
aclara que la conclusion puede ir en cualquier sentido si esta bien
fundamentada. Sigue la estructura de registro de decision de la seccion 5.3,
contexto, alternativas, decision, justificacion y consecuencias. Cierra con las
condiciones en las que la respuesta cambiaria.

---

## 1. Contexto

### Donde vive hoy el pago

El pago no es un modulo suelto. Es una fila de la tabla `pago`
(`migrations/006_pedidos.sql`) que nace dentro de la misma transaccion que el
pedido, sus lineas, el descuento de stock y el kardex. Todo eso lo hace una sola
funcion de PostgreSQL, `comprar_carrito()` (`migrations/012_comprar_carrito.sql`),
que llama a `comprar_pedido()` (`migrations/007_flujo_pedido.sql`).

```
comprar_carrito(usuario, direccion, lineas, metodo)
  crear_pedido                       INSERT pedido
  agregar_linea  (por cada linea)    SELECT oferta ... FOR UPDATE
                                     INSERT pedido_producto
  comprar_pedido                     UPDATE oferta SET stock = stock - n
                                     INSERT stock_movimiento
                                     INSERT pago
COMMIT
```

Si cualquier paso falla, no queda ni pedido, ni pago, ni stock descontado. Esa
garantia la da una sola base con una sola transaccion, y es lo que
`docs/CONSISTENCIA-CHECKOUT.md` llama la parte que no se negocia, el dinero y el
stock.

### Que ofrece un motor NewSQL

NewSQL es SQL con transacciones ACID repartidas entre varios nodos. Los datos se
parten en rangos, cada rango se replica en tres nodos con un protocolo de
consenso (Raft) y una transaccion puede tocar rangos de nodos distintos sin
perder el ACID. Lo que se gana es escalar escrituras agregando nodos y seguir
funcionando si se cae uno, sin perder datos confirmados.

Los dos que mas se parecen a lo que ya usamos hablan el protocolo de
PostgreSQL.

- CockroachDB. Compatible con el protocolo y gran parte del SQL de PostgreSQL.
  Trabaja por defecto en aislamiento SERIALIZABLE.
- YugabyteDB. Reutiliza la capa de consultas de PostgreSQL sobre un
  almacenamiento distribuido propio, por eso acepta mas del dialecto, incluidas
  funciones en PL/pgSQL y triggers.

### El tamano del problema

Mesh corre en una sola maquina con un solo PostgreSQL. Los pedidos y pagos se
cuentan en decenas o pocos cientos, igual que las ventas que se midieron para el
ADR-8. El cuello de botella que si existe es otro, la venta relampago, donde
muchas compras pelean por la misma fila de `oferta` en el mismo segundo. Ese
caso ya lo resolvio la Entrega 2 con un contador atomico en Redis delante de
PostgreSQL (`migrations/014_inventario_limitado.sql` y el ticket de reserva),
y el `FOR UPDATE` solo ve pasar a quien ya gano su unidad.

---

## 2. Alternativas consideradas

1. Quedarse en PostgreSQL, sin cambios.
2. Mover solo `pago` a un motor NewSQL y dejar pedido, oferta y stock en
   PostgreSQL.
3. Mover todo el nucleo transaccional (`pedido`, `pedido_producto`, `pago`,
   `oferta`, `stock_movimiento` y sus funciones) a CockroachDB.
4. Lo mismo que la 3, pero sobre YugabyteDB.

### 2.1 La alternativa 2 rompe lo que hoy funciona

Mover solo los pagos parece lo mas prudente y es lo peor. El pago dejaria de
estar en la misma transaccion que el stock. Para cobrar y descontar tendriamos
dos bases y ningun COMMIT comun, o sea una transaccion distribuida entre motores
distintos o una saga con compensaciones. Es justo el problema que
`CONSISTENCIA-CHECKOUT.md` resuelve dejando el dinero y el stock juntos en
PostgreSQL. Se descarta sin necesidad de medir nada.

### 2.2 Las alternativas 3 y 4, que son las serias

Moverlo todo junto conserva la atomicidad, porque la transaccion sigue siendo
una sola, ahora repartida. Lo que hay que mirar es cuanto del codigo actual
sobrevive y que se gana a cambio.

| Criterio | PostgreSQL hoy | CockroachDB | YugabyteDB |
|---|---|---|---|
| Consistencia | ACID en un nodo, `READ COMMITTED` con `FOR UPDATE` en la fila caliente | ACID distribuido, `SERIALIZABLE` por defecto | ACID distribuido, admite `READ COMMITTED` y `SERIALIZABLE` |
| Funciones PL/pgSQL (`comprar_carrito`, `comprar_pedido`, `agregar_linea`) | Todas corren | Soporte parcial y reciente, hay que reescribir o probar cada una | Corren, reutiliza el motor de PostgreSQL |
| Triggers (`trg_resena_al_grafo`, `trg_oferta_registrar_precio`) | Corren | Soporte reciente y limitado | Corren |
| La fila caliente de la venta relampago | Un `FOR UPDATE` local, microsegundos | Cada escritura pasa por consenso entre nodos, mas latencia, y en `SERIALIZABLE` los choques vuelven como error `40001` que la aplicacion tiene que reintentar | Igual que Cockroach en latencia por consenso |
| Escalabilidad | Vertical, un nodo | Horizontal en escrituras | Horizontal en escrituras |
| Alta disponibilidad | No, si cae el contenedor no se compra | Si, con tres nodos sobrevive a uno caido | Si, con tres nodos |
| Costo operativo | Un contenedor, lo que ya hay | Minimo tres nodos para tener tolerancia a fallos, varios GB de memoria | Minimo tres nodos, cada uno con dos procesos (master y tserver) |
| Resto del sistema (ETL, pgAdmin, pruebas por `psql`, `pgvector`) | Todo funciona | Hay que revisar cada script, pgAdmin se conecta con limites | Mejor compatibilidad, pero `pgvector` depende de la version |

---

## 3. Decision

Se queda PostgreSQL para pedidos y pagos. No se migra a un motor NewSQL.

---

## 4. Justificacion

Consistencia. Hoy ya tenemos la garantia mas fuerte que necesita un pago, una
sola transaccion que cobra, descuenta y registra. Un motor NewSQL ofrece la
misma garantia, no una mejor, y la reparte entre nodos que en este proyecto no
existen.

Patron de consulta. El pago se escribe una vez por compra y se lee por pedido
(`idx_pago_pedido`). No hay consultas que barran millones de pagos ni escrituras
que saturen un nodo. El unico punto de contencion real, la venta relampago,
ya se saco de PostgreSQL con Redis. En un motor distribuido esa misma fila
caliente seria mas lenta, porque cada escritura necesita el voto de la mayoria
de las replicas, y en CockroachDB los choques aparecerian como reintentos que
hoy el backend no maneja.

Escalabilidad. Escalar escrituras en horizontal resuelve un problema que no
tenemos. A este volumen un solo PostgreSQL tiene margen de sobra, igual que se
concluyo para grafos y columnar en el ADR-8.

Costo operativo. Un cluster con tolerancia a fallos pide al menos tres nodos.
En la maquina del equipo, que ya levanta seis bases, eso es memoria que no hay.
Ademas habria que portar las funciones PL/pgSQL, los triggers, el ETL y las
pruebas que hoy corren con `psql`, con el riesgo de romper el checkout que ya
esta probado bajo falla (`pruebas/falla_checkout.sh`).

---

## 5. Consecuencias

Lo que se mantiene. El checkout sigue siendo una transaccion local, rapida y
facil de probar. Las funciones, triggers y pruebas siguen iguales.

Lo que se asume. PostgreSQL es un punto unico de falla. Si su contenedor cae, no
se puede comprar hasta que vuelva, y el sistema lo dice en lugar de cobrar a
medias (fila 11 de `CONSISTENCIA-CHECKOUT.md`, el mismo criterio). No hay
replica ni conmutacion automatica.

---

## 6. Cuando si estaria justificado

La respuesta cambiaria si se cumpliera alguna de estas condiciones.

- Compradores en varias regiones que necesiten escribir cerca de donde estan,
  con datos que por ley tengan que quedarse en su pais.
- Un volumen de escrituras de pedidos y pagos que un solo nodo de PostgreSQL ya
  no aguante, medido y no supuesto.
- Un requisito de disponibilidad que no admita perder la compra durante la caida
  de un servidor, con conmutacion automatica y sin perder pagos confirmados.

Antes de llegar a NewSQL hay un paso intermedio mas barato. Una replica de
PostgreSQL por streaming con conmutacion automatica (Patroni, por ejemplo) cubre
la tercera condicion sin reescribir nada. NewSQL tendria sentido cuando
aparezcan la primera o la segunda.

Si llegara ese dia, YugabyteDB seria la primera opcion a probar, porque corre las
funciones PL/pgSQL y los triggers que hoy sostienen el checkout. CockroachDB
obligaria a reescribir mas y a manejar reintentos por `SERIALIZABLE`.
