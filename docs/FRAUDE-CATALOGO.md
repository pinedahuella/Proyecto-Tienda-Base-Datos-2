# Catalogo de fraude

Todos los tipos de fraude que conoce Mesh, que motor los busca, cuando, con que
umbral, y como se ven: con la semilla (`semilla-fraude/`, entra con
`arrancar.ps1`) o con una demo en vivo. Puesto al dia el 2026-10-19, con el
backend despues de la limpieza de fraude del 17-10 (migracion 042).

El catalogo vive en `tipo_senal_fraude` (migraciones 031 a 042): **31 tipos**.
Los detectores del backend generan **30**; `anillo_en_el_tiempo` esta en el
catalogo pero se dejo fuera de alcance el 2026-09-25 y nada lo genera
(`docs/fraude-entrega3/README.md`, B.4).

Cada deteccion es una fila de `senal_fraude` (una por tipo y clave: la cuenta,
la IP, el producto o el grupo de cuentas), y el agrupador junta las senales en
casos de fraude cada 15 minutos. En el panel del admin, **Fraude**, hay cuatro
pestanas: Casos, Intentos de entrada (login), Resenas en anillo (todo lo de
resenas) y Compras y navegacion (ClickHouse y la granja de registros).

## Como dejarlo todo listo antes de la clase

```
.\arrancar.ps1                                   siembra semilla-fraude (paso 5e)
cd backend ; npm run start:dev                   y en otra consola el frontend
node pruebas/correr_detectores_fraude.cjs        los detectores una vez, sin esperar su reloj
```

Con eso el panel ya tiene una senal de cada tipo de la semilla. En clase se
arma en vivo lo que se quiera ensenar, con las demos de abajo. Cada demo tarda
menos de un minuto, salvo las de resenas (hasta 2, esperan a que el backend
calcule el vector de cada resena con Ollama).

`pruebas/correr_detectores_fraude.cjs` corre los detectores que van por reloj
(acepta familias: `anillos patrones texto canceladas login compras casos`). Hace
falta porque el de compras corre UNA vez al dia y Nest no lo dispara al
arrancar, y los demas cada 15 minutos.

## A. Anillos de resenas (Neo4j)

Corren cada 15 minutos y en el momento en que se escribe una resena (chequeo
acotado). Ventana de 60 dias.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `ciclo` | Tres o mas cuentas que se compran y se califican en circulo (A.1) | Un ciclo de 3 a 4 cuentas, todas las resenas en 60 dias | `.\demo-anillo-resenas.ps1 -Cuentas 3` |
| `mutuo` | Dos cuentas que se califican la una a la otra; las horas entre ida y vuelta van en el detalle y suben el puntaje (antes `favor_devuelto`) | Un par | `.\demo-patrones-resenas.ps1 -Patron favor` |
| `reiterado` | El par mutuo sobre el MISMO producto (A.2) | Un par | `.\demo-anillo-resenas.ps1 -Cuentas 2` |

## B. Patrones de resenas (Neo4j)

Cada 15 minutos; coordinados y persistente tambien al escribir una resena.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `satelites` (B.2) | Cuentas recien nacidas que solo le compran y le ponen notas altas a un vendedor | 3 cuentas, primera resena a 7 dias o menos de nacer, todas de 4 o 5 | Semilla: `fraude.vendedor.satelites` y `fraude.satelite1` a `3`; en vivo `.\demo-patrones-resenas.ps1 -Patron satelites` (en vivo todo nace hoy, asi que sale tambien reputacion expres) |
| `persistente` (B.3) | Una cuenta que califica alto al mismo vendedor mes tras mes, y casi a nadie mas | 3 meses distintos, el 60 % de sus resenas, la ultima en 60 dias | Semilla: `fraude.persistente`. No se puede armar en vivo |
| `coordinados` (B.6) | Dos cuentas que califican lo mismo al mismo vendedor en el mismo rato | 3 productos, cada par de resenas a 24 horas o menos | `.\demo-patrones-resenas.ps1 -Patron coordinados` |
| `reputacion_expres` (B.7) | Un vendedor recien nacido que recibe notas altas de cuentas recien nacidas | Vendedor de 7 dias o menos, autor de 24 horas o menos | Semilla: `fraude.vendedor.expres`; en vivo `.\demo-patrones-resenas.ps1 -Patron expres`. Tambien sale solo en cualquier demo que crea un vendedor y compradores nuevos |
| `anillo_en_el_tiempo` (B.4) | Un anillo que se reactiva despues de meses | | Fuera de alcance: ningun detector lo genera |

## C. El texto de las resenas (PostgreSQL, `vector_comentario`)

Cada 15 minutos, y las de notas incoherentes tambien al valorar una resena
nueva. Usan el vector de cada resena (Ollama) y la valoracion del clasificador
(`clasificador-resenas/`). Ventana de 180 dias; resenas de 100 caracteres o mas (las mas cortas no se valoran).
"Gemela" es otra resena con coseno de 0.92 o mas.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `resenas_repetidas` | Una cuenta que repite la misma resena | 5 resenas con gemela de la MISMA cuenta, el 30 % de las suyas | Semilla: `fraude.repetidas`; en vivo `.\demo-resenas-texto.ps1 -Caso repetidas` |
| `anillo_de_texto` | Varias cuentas con la misma plantilla sobre un vendedor | 3 cuentas, gemelas a 30 dias o menos | `.\demo-resenas-texto.ps1 -Caso copiadas` |
| `resenas_parecidas_vendedor` | Un vendedor cuyas resenas son copias de otras cuentas (solo alerta) | 5 con gemela de OTRA cuenta y el 20 % | `.\demo-resenas-texto.ps1 -Caso copiadas` |
| `resenas_parecidas_producto` | Lo mismo sobre un producto (solo alerta) | 5 y el 40 % | Semilla: Guantes de portero Zarpa 300; en vivo `.\demo-resenas-texto.ps1 -Caso parecidas_producto` |
| `notas_incoherentes_cuenta` | Una cuenta que pone estrellas contrarias a lo que escribe | 5 contradictorias y el 20 % | `.\demo-resenas-texto.ps1 -Caso incoherentes` |
| `notas_incoherentes_vendedor` | Lo mismo en las resenas de un vendedor (solo alerta) | 5 y el 20 % | `.\demo-resenas-texto.ps1 -Caso incoherentes` |
| `notas_incoherentes_producto` | Lo mismo en las resenas de un producto (solo alerta) | 5 y el 40 % | Semilla: Sillin de ruta Vertebra SR-2; en vivo `.\demo-resenas-texto.ps1 -Caso incoherentes_producto` |

## D. Resenas y compras canceladas (PostgreSQL)

Cada 15 minutos y al cancelar un pedido. Ventana de 60 dias.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `resena_positiva_cancelada` | Una resena buena de una compra que despues se cancelo | 4 o 5 estrellas, cancelada a 72 horas o menos | `.\demo-resenas-texto.ps1 -Caso cancelada` |
| `resenas_negativas_canceladas_vendedor` | Un vendedor con muchas resenas malas de compras canceladas | 5 | `.\demo-resenas-texto.ps1 -Caso negativas` |

Solo cuentan las cancelaciones que hizo el mismo comprador. Desde el 2026-11-07 la
tienda puede cancelar cualquier pedido (migracion 051), y esa cancelacion no corre
el detector: el movimiento de devolucion queda a nombre del admin y el detector lo
salta, igual que la regla R-CASI-3. La devolucion si llega a ClickHouse, con
`por_la_tienda = 1`, y F5 (devoluciones seriales) y el embudo solo cuentan las de 0.

## E. Login, en el momento (Redis y Elasticsearch)

Salen en el mismo intento de login, de los contadores de Redis (las ventanas
cortas) o comparando con el historial de la cuenta en Elasticsearch (toma de
cuenta y viaje imposible). No hay dato que sembrar: se arman en vivo.

`demo-evento-fraude.ps1` manda cada intento con una IP de mentira en
`X-Forwarded-For`, que el backend toma cuando la peticion viene de esta misma
maquina (`trustProxy: 'loopback'`) y que `geoip-lite` ubica igual que una real.
No necesita Tor. `demo-fraude-pais.ps1` hace lo mismo saliendo de verdad por
otro pais.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `fuerza_bruta_cuenta` | Muchos fallos contra una cuenta | 5 en 60 s | `.\demo-evento-fraude.ps1 -Tipo fuerza_bruta_cuenta` |
| `fuerza_bruta_ip` | Muchos fallos desde una IP | 8 en 60 s | `.\demo-evento-fraude.ps1 -Tipo fuerza_bruta_ip` |
| `multi_cuenta_ip` | Una IP que prueba muchas cuentas | 4 identificadores en 300 s | `.\demo-evento-fraude.ps1 -Tipo multi_cuenta_ip` |
| `ip_rotacion_cuenta` | Una cuenta probada desde muchas IPs | 4 IPs en 300 s | `.\demo-evento-fraude.ps1 -Tipo ip_rotacion_cuenta` |
| `toma_cuenta` | Una cuenta que entra desde una IP que nunca uso | 3 logins buenos antes | `.\demo-evento-fraude.ps1 -Tipo toma_cuenta` |
| `viaje_imposible` | Dos logins buenos tan lejos y tan seguidos que no hay avion que llegue | 800 km/h | `.\demo-evento-fraude.ps1 -Tipo viaje_imposible` (Guatemala y Tokio, 12 325 km) |

## F. Login lento (Elasticsearch)

Miran las ultimas 24 horas; corren cada 15 minutos y en cada intento de login
(acotado a esa cuenta e IP). La demo escribe primero en Mongo el historial de
las horas anteriores, como lo escribe el backend, y hace en vivo el intento que
cruza el umbral. La granja mira 30 dias y solo corre con el reloj: la demo
corre el detector una vez.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `fuerza_bruta_cuenta_lenta` | Fallos contra una cuenta repartidos en el dia | 15 en 24 h | `.\demo-evento-fraude.ps1 -Tipo fuerza_bruta_cuenta_lenta` |
| `multi_cuenta_ip_lenta` | Una IP que prueba muchas cuentas a lo largo del dia | 8 identificadores en 24 h | `.\demo-evento-fraude.ps1 -Tipo multi_cuenta_ip_lenta` |
| `ip_rotacion_cuenta_lenta` | Una cuenta probada desde muchas IPs a lo largo del dia | 5 IPs en 24 h | `.\demo-evento-fraude.ps1 -Tipo ip_rotacion_cuenta_lenta` |
| `granja_de_registros` | Muchas cuentas nacidas desde la misma IP | 5 en 60 minutos | `.\demo-evento-fraude.ps1 -Tipo granja_de_registros` |

## G. Compras y navegacion (ClickHouse)

Una vez al dia (`HallazgosEventoFraudeDetectorService`). Ventana de 30 dias,
solo el lote `real`.

| Tipo | Que es | Umbral | Como se ve |
|---|---|---|---|
| `vistas_infladas` (F1) | Un producto que una misma sesion abre una y otra vez | 20 vistas por sesion | `.\demo-compras-fraude.ps1 -Caso vistas_infladas` |
| `compras_en_rafaga` (F2) | Una cuenta que compra muchas veces en minutos | 5 pedidos en 15 minutos | Semilla: `fraude.rafaga`; en vivo `.\demo-compras-fraude.ps1 -Caso compras_en_rafaga` |
| `ip_multicuenta_compras` (F3) | Varias cuentas comprando desde una IP | 4 cuentas | `.\demo-compras-fraude.ps1 -Caso ip_multicuenta_compras` |
| `devoluciones_seriales` (F5) | Una cuenta que devuelve casi todo lo que compra | 3 unidades y el 50 % | Semilla: `fraude.devoluciones`; en vivo `.\demo-compras-fraude.ps1 -Caso devoluciones_seriales` |

F1 y F3 necesitan la IP y la sesion de la peticion, que el ETL de compras no
trae de PostgreSQL: por eso no estan en la semilla. F4 (carrito acaparador) se
quito y F6 (la granja) se movio al login, en Elasticsearch.

## Cosas que conviene saber decir

- **Cada demo dispara solo su tipo**, y cada grupo de la semilla tambien: los
  numeros estan puestos para no cruzar el umbral de un vecino (ver
  `semilla-fraude/README.md` y la cabecera de cada demo). La excepcion honesta
  es `reputacion_expres`: cualquier demo que crea un vendedor y compradores
  nuevos y resena el mismo dia la cumple, porque eso es justo lo que describe.
- **Todas las demos entran a varias cuentas desde esta maquina**, y eso suma en
  `multi_cuenta_ip` y `multi_cuenta_ip_lenta` de la IP 127.0.0.1. Es la senal
  funcionando: una maquina que entra a muchas cuentas es lo que busca.
- **Lo que se ve en el panel no se borra solo.** Una senal ya detectada se queda
  hasta que el admin la revisa: el backend no tiene limpieza periodica (la de
  la 042 fue una sola vez, al migrar).
- **La semilla se renueva** con `semilla-fraude/quitar.sql` y otro arranque: sus
  fechas son relativas al dia en que se sembro.
- **Una resena falsa se oculta, no se borra** (migracion 052). En el panel, Fraude,
  Resenas en anillo, Ver detalle real, columna En la tienda. Sale de la ficha y del
  promedio, pero sigue en el grafo y en la senal, que es la evidencia, y su autor
  no puede volver a resenar ese producto de ese vendedor.

## Probado

El 2026-10-19, en la base local, con el backend compilado:

- Semilla: sus 8 tipos salen, cada uno solo con sus cuentas y ningun tipo de
  mas (despues de corregir que las parecidas cayeran de a 3 en un vendedor, que
  armaba un anillo de texto). `quitar.sql`, volver a sembrar y la segunda pasada
  sin duplicar, tambien desde `arrancar.ps1`.
- `demo-evento-fraude.ps1`: los 10 tipos de login, cada uno con su senal
  confirmada en PostgreSQL.
- `demo-compras-fraude.ps1`: los 4 casos, con sus claves (el producto, la
  cuenta y la IP `::ffff:...`, que ClickHouse guarda como IPv6).
- `demo-anillo-resenas.ps1` con 3 y con 2 cuentas (ciclo y reiterado),
  `demo-patrones-resenas.ps1` (favor, coordinados, y los nuevos satelites y
  expres) y `demo-resenas-texto.ps1` (los 4 de antes con 6 de 6 senales, y los
  nuevos repetidas, parecidas_producto e incoherentes_producto). La cuenta de
  incoherentes y la de repetidas compran sus 5 productos en un pedido: con 5
  pedidos seguidos tambien eran una compra en rafaga.
- `bash pruebas/correr_todas.sh`: las 38 pruebas del repo en verde con la
  semilla puesta (`neo4j/correr_patrones.sh` a la segunda: la primera vez el
  backend paso al grafo, en medio de la prueba, las cuentas que acababan de
  crear las demos, y su comprobacion de "el grafo quedo igual" lo vio).
