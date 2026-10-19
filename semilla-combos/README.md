# semilla-combos

Pedidos de 2 y 3 productos que tienen sentido juntos, para que los combos de la
portada ("Se compran juntos", `GET /productos/combos`), "Quienes lo compraron
tambien llevaron" de la ficha (`GET /productos/:id/tambien-compraron`) y "Para
ti" (`GET /productos/para-ti`) tengan de donde salir. Lo pidio Jose David en
`backend/cambio_propuestas/2026-10-17_0015-combos.md` ("Semillas con pedidos de
varios productos que tengan sentido juntos"). Hecha el 2026-10-18.

Antes de esto casi todos los pedidos eran de un solo producto: en la base local
habia 5 pedidos de varios productos en los ultimos 180 dias y 4 combos.

| Archivo | Que hace |
|---|---|
| `combos.sql` | Siembra 8 cuentas y 18 pedidos. Idempotente: si ya existe cualquiera de las cuentas no hace nada. Todo en una transaccion |
| `quitar.sql` | La deshace entera: pedidos, pago, kardex, stock devuelto, direcciones y cuentas. Anota los pedidos en `pedido_quitado` para que se borren tambien de ClickHouse |

`arrancar.ps1` la corre en cada arranque, en el paso **5d. Pedidos de los
combos**, justo despues de las resenas del clasificador (5c) y antes de
ClickHouse y Neo4j. Entra igual en una base nueva (despues de
`migrations/datos/`) y en una que ya existe.

## Lo que siembra

8 cuentas compradoras, `combo1@mesh.com` a `combo8@mesh.com` (usuario `combo1`
a `combo8`, contrasena `Comprador123`, la de todos los compradores de la
semilla), cada una con su direccion y su primera version en el historial.

18 pedidos pagados, 45 lineas, de 8 combos del catalogo curado. Cada combo esta
en 2 o 3 pedidos de cuentas distintas:

| | Combo | Pedidos |
|---|---|---|
| A | Laptop Aurora 14 + Monitor Nube 22 + Audifonos Colibri Micro TWS | 3 |
| B | Escritorio Roble 120 + Lampara de escritorio Faro | 3 |
| C | Casco de ruta Aerodino + Guantes de ciclismo Palma Corta + Candado plegable Cerrojo F8 | 2 |
| D | Tapete de yoga Raiz 6 mm + Set de bandas elasticas | 2 |
| E | Balon de futbol numero 5 + Espinilleras Muralla + Zapato de tacos Relampago FG | 2 |
| F | Olla arrocera Grano 8 tazas + Cacerola honda Comal 18 | 2 |
| G | Limpiador en gel Verdo + Serum de niacinamida 10% + Crema hidratante nocturna Alba | 2 |
| H | Camisa oxford clasica + Pantalon chino resistente | 2 |

Los nombres son los de `producto_catalogo` (y de `productos`, que en una base
nueva es lo unico que hay en este paso: el catalogo se copia de Mongo despues).

**Como compra.** Por `crear_pedido`, `agregar_linea` y `comprar_pedido`, el
mismo camino de la aplicacion y el de los dos pedidos de
`migrations/datos/001_catalogo.sql`. Asi quedan su pago, su movimiento de venta
en el kardex y el stock descontado, y los triggers de la 041 encolan cada
cuenta en `evento_grafo_compra`. Por cada producto se elige una oferta activa,
aprobada, sin inventario limitado, con 3 unidades o mas y que ya existiera un
dia antes de la compra; se va rotando entre las que hay para que caigan en
vendedores distintos. Despues se corrigen las fechas que esas funciones
escriben con `now()` (pedido, pago y kardex).

**Las fechas** son relativas al dia de la siembra, de 8 a 160 dias atras, a una
hora de Guatemala, porque los combos solo cuentan los ultimos 180 dias. En una
base sembrada hace mas de medio ano los primeros van saliendo de la ventana;
para renovarlos, `quitar.sql` y arrancar otra vez.

## Por que no planta fraude

Revisado detector por detector:

- **F2 compras en rafaga** (5 pedidos de una cuenta en 15 minutos): cada cuenta
  tiene 2 o 3 pedidos, con 47 dias o mas entre uno y otro.
- **F3 una IP con 4 cuentas**: el ETL copia las compras con la IP comodin `::`,
  que F3 descarta. Las cuentas no tienen logins sembrados.
- **F5 devoluciones seriales**: no hay devoluciones.
- **F1 vistas infladas, granja de registros y alertas de login** salen de
  vistas, registros y logins, y aqui no hay ninguno.
- **Los del grafo y los de texto** (anillos, patrones de la familia B, notas
  incoherentes, resenas parecidas, resenas canceladas) miran resenas, y aqui no
  hay resenas.

Medido el 2026-10-18 con el backend corriendo: 0 senales, 0 hallazgos, 0
evidencias de caso y 0 alertas con las cuentas combo. F2 sobre ClickHouse da 1
pedido en la peor ventana de 15 minutos de cualquiera de ellas.

## Quitarla

```
docker cp semilla-combos/quitar.sql mesh-postgres:/tmp/quitar_combos.sql
docker exec mesh-postgres psql -U <DB_USER> -d <DB_NAME> -v ON_ERROR_STOP=1 -f /tmp/quitar_combos.sql
bash etl/cargar_compras.sh
```

Desde psql no se llega a ClickHouse. `quitar.sql` anota cada pedido que borra en
`pedido_quitado` (migracion 046) y el ETL de compras borra sus lineas de
`compra_producto` y `devolucion_producto` al empezar, y marca la fila. Como
`arrancar.ps1` corre ese ETL, si despues se arranca no hace falta la tercera
linea. Neo4j no necesita nada: al borrar los pedidos, los triggers de la 041
encolan las cuentas y el backend les quita sus `:Compra`.

`clasificador-resenas/semilla/quitar.sql` hace lo mismo desde el 2026-10-18.

## Probado el 2026-10-18 (base local)

- **Base existente**: el primer arranque sembro las 8 cuentas y los 18 pedidos
  (45 lineas) y el ETL los copio a ClickHouse: 854 ventas en PostgreSQL y 854 en
  ClickHouse. El segundo arranque dijo "Ya estaban" y una foto de 17 conteos
  (cuentas, pedidos, lineas, pagos, kardex, stock oferta por oferta, ClickHouse)
  salio identica.
- **Quitar y volver**: `quitar.sql` dejo el stock de cada oferta exactamente como
  antes de la siembra (mismo md5 de la lista de 16958 ofertas con su stock), el
  ETL borro las 45 lineas de ClickHouse, y el arranque siguiente volvio a la
  misma foto que el primero.
- **Base nueva** (`mesh_limpia` en el mismo contenedor): las 46 migraciones,
  `migrations/datos/`, las resenas del clasificador y esta semilla sin un error;
  una segunda pasada sin duplicar nada; quitar y sembrar otra vez, igual.
- **Backend**: `GET /productos/combos` trae los combos sembrados, "tambien
  compraron" de la Laptop Aurora 14 empieza por los audifonos y el monitor (4
  compradores cada uno), "para ti" de combo1 sale de lo que compro sin repetirlo,
  y la conciliacion del grafo cuadra (832 compras en PostgreSQL y en Neo4j).

**Lo que se ve hoy en la portada.** La ruta muestra 10 combos. Hasta el
2026-10-26 entran tambien 4 trios de los pedidos 6 y 10 de
`migrations/datos/001_catalogo.sql` (las compras grandes que respaldan las
resenas, de 6 y 8 productos, fechadas el 2026-04-29), que ocupan lugares y dejan
fuera a D, F y H. Esos pedidos salen solos de la ventana de 180 dias el 26 de
octubre. Con 20 pedidos o menos no hay reparto que gane a los cuatro; lo de fondo
seria que el worker no cuente pedidos tan grandes (`MAX_PRODUCTOS_POR_PEDIDO`
esta en 30), y eso es del backend: anotado en `docs/BACKEND-PENDIENTE.md`.
