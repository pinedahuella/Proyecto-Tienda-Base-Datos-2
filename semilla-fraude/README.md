# semilla-fraude

Datos para que salgan los tipos de fraude que no se pueden armar en vivo frente
al profesor, o que no tenian ninguna demo. Con esta semilla y las demos, cada
uno de los 30 tipos que el backend detecta tiene de donde salir; el catalogo
entero, con la demo de cada uno, esta en `docs/FRAUDE-CATALOGO.md`. Hecha el
2026-10-19.

| Archivo | Que hace |
|---|---|
| `fraude.sql` | Siembra 3 vendedores, 21 compradores, 26 resenas y 35 pedidos. Idempotente: si ya existe cualquier cuenta `fraude.*@mesh.com` no hace nada. Todo en una transaccion |
| `quitar.sql` | La deshace entera: resenas, pedidos (pago, kardex y stock devuelto), las ofertas de sus vendedores, las senales que salieron de ella y las cuentas. Anota los pedidos en `pedido_quitado` para que se borren tambien de ClickHouse |

`arrancar.ps1` la corre en cada arranque, en el paso **5e. Semilla de fraude**,
despues de los combos (5d) y antes de ClickHouse y Neo4j, para que el ETL de
compras y el grafo la tomen en el mismo arranque.

## Lo que siembra, y lo que dispara

Contrasena `Vendedor123` para los vendedores y `Comprador123` para los demas.
Las fechas son relativas al dia de la siembra ("hace 9 dias").

| Senal | Detector | Cuentas | Como |
|---|---|---|---|
| `satelites` (B.2) | Neo4j, cada 15 min | `fraude.vendedor.satelites`, `fraude.satelite1` a `3` | El vendedor nacio hace 200 dias y vende bandas, una pesa rusa y un tapete. Las tres cuentas nacen hace 10 a 12 dias, le compran solo a el y le ponen 5 a los 3 dias de nacer (el limite es 7) |
| `persistente` (B.3) | Neo4j, cada 15 min | `fraude.persistente`, `fraude.vendedor.persistente` | Una compra y un 5 al mes durante cuatro meses (hace 98, 68, 38 y 8 dias), siempre a la misma botica y a nadie mas. Pide 3 meses distintos: no se puede armar en vivo |
| `reputacion_expres` (B.7) | Neo4j, cada 15 min | `fraude.vendedor.expres`, `fraude.expres1` y `2` | El vendedor nacio hace 5 dias; las dos cuentas, hace 2 y 1.5, y le ponen 5 a las 6 horas de nacer (el limite es 24) |
| `resenas_repetidas` | texto, cada 15 min | `fraude.repetidas` | Cinco resenas casi iguales, con dos o tres palabras cambiadas, en cinco productos, en 25 dias |
| `resenas_parecidas_producto` | texto, cada 15 min | `fraude.parecidas1` a `6` | Seis cuentas dejan casi la misma resena en los Guantes de portero Zarpa 300, de a 2 por vendedor |
| `notas_incoherentes_producto` | texto, cada 15 min | `fraude.incoherente1` a `6` | Seis cuentas le ponen 5 estrellas al Sillin de ruta Vertebra SR-2 con textos distintos que dicen que salio malo (el clasificador los lee como `mala`, de 0.95 a 0.99), de a 2 por vendedor |
| `compras_en_rafaga` (F2) | ClickHouse, una vez al dia | `fraude.rafaga` | 5 pedidos en 11 minutos, hace 9 dias (el limite es 5 en 15) |
| `devoluciones_seriales` (F5) | ClickHouse, una vez al dia | `fraude.devoluciones` | 4 compras y 3 canceladas (3 devueltas, el 75 %; pide 3 y el 50 %) |

## Por que cada grupo dispara solo lo suyo

Se probo en la base local: despues de sembrar, el ETL y los detectores, salen
esas ocho senales y ninguna otra con estas cuentas.

- Los satelites resenan mas de 24 horas despues de nacer y su vendedor es
  viejo: no son reputacion expres. Son tres porque B.2 pide tres.
- Reputacion expres lleva dos cuentas y no tres: con tres tambien serian
  satelites.
- Las resenas repetidas caben en 25 dias y caen en vendedores distintos: no
  juntan los 3 meses de persistente ni son de un solo vendedor (satelites).
- Las parecidas y las incoherentes caen de a 2 por vendedor, en tres
  vendedores. Con 3 en uno, ese vendedor ya tiene un `anillo_de_texto` (3
  cuentas con la misma plantilla); y el vendedor pide 5 para
  `resenas_parecidas_vendedor` y `notas_incoherentes_vendedor`. Cada cuenta
  escribe una sola, lejos de las 5 de `resenas_repetidas` y
  `notas_incoherentes_cuenta`. Por eso la rueda reparte por vendedor y no por
  oferta, y la semilla se niega a entrar si alguno de los dos productos tiene
  menos de 3 vendedores.
- La persistente y la de reputacion expres tienen su propio vendedor: B.2, B.3
  y B.7 meten al vendedor en el caso, y uno de los del catalogo saldria como
  sospechoso.
- Las cuentas de compras no resenan. La rafaga cae en cinco productos de un
  pedido cada uno; las devoluciones son cancelaciones de pedidos comprados
  (`cancelar_pedido`), el mismo camino de la aplicacion.

## Lo que no siembra

- **El login entero** (las 10 senales). Las inmediatas salen en el momento del
  intento, de los contadores de Redis: no hay dato que sembrar. Salen con
  `demo-evento-fraude.ps1`, que manda los intentos con una IP de mentira
  (X-Forwarded-For) y no necesita Tor.
- **Vistas infladas (F1) y una IP con 4 cuentas comprando (F3).** Necesitan la
  IP y la sesion de la peticion, y el ETL de compras copia de PostgreSQL, que no
  las guarda. Salen con `demo-compras-fraude.ps1`.
- **Los anillos, coordinados, el anillo de texto, las notas incoherentes de
  cuenta y de vendedor, las parecidas de vendedor y las resenas canceladas.**
  Ya tenian su demo en vivo y se arman en un minuto.
- **`anillo_en_el_tiempo`** esta en el catalogo pero ningun detector lo genera:
  se dejo fuera de alcance el 2026-09-25 (`docs/fraude-entrega3/README.md`).

## Cuando salen las senales

La semilla deja los datos; las senales las escriben los detectores del backend:
los del grafo y los de texto cada 15 minutos, el de compras una vez al dia (y
Nest no lo corre al arrancar). Lo de texto necesita ademas que el backend haya
calculado el vector y la valoracion de cada resena (Ollama). Para no esperar:

```
node pruebas/correr_detectores_fraude.cjs
```

Corre todos una vez y despues el agrupador de casos. Se ven en el panel del
admin, en Fraude.

## Fechas y renovacion

Los detectores miran ventanas: 60 dias el grafo, 180 el texto, 30 las compras.
Una senal ya detectada se queda en el panel, pero en una base sembrada hace mas
de un mes los datos van saliendo de su ventana y un detector ya no los vuelve a
encontrar. Para renovarlos:

```
docker cp semilla-fraude/quitar.sql mesh-postgres:/tmp/quitar_fraude.sql
docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 -f /tmp/quitar_fraude.sql
.\arrancar.ps1
```

`quitar.sql` se niega a borrar si alguien que no es de la semilla le compro a
uno de sus vendedores, y dice que pedido es.
