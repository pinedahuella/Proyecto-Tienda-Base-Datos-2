# Consultas de ClickHouse para recomendaciones, tendencias y operaciones

ClickHouse guarda lo que pasa en la tienda (vistas, carritos, compras, devoluciones, busquedas, registros), y eso permite preguntas que PostgreSQL no puede contestar porque solo guarda el final de la historia. Este documento propone trece consultas en tres grupos.

| # | Archivo | Pregunta |
|---|---|---|
| R1 | `R1_vistos_recientemente.sql` | Que miro esta persona hace poco |
| R2 | `R2_tambien_vieron.sql` | Quienes vieron este producto que otros vieron |
| R3 | `R3_para_ti.sql` | Que recomendarle segun lo ultimo que miro |
| R4 | `R4_populares_de_lista.sql` | De estos productos parecidos, cuales quiere la gente ahora |
| T1 | `T1_en_ascenso.sql` | Que se esta calentando antes de venderse |
| T2 | `T2_embudo.sql` | En que producto se cae la venta, y si vuelve mucho |
| T3 | `T3_busquedas_sin_respuesta.sql` | Que busca la gente y la tienda no tiene |
| F1 | `F1_vistas_infladas.sql` | Que producto esta inflando alguien a punta de vistas |
| F2 | `F2_compras_en_rafaga.sql` | Que cuenta hizo muchos pedidos en pocos minutos |
| F3 | `F3_ip_multicuenta_compras.sql` | Desde que IP compran varias cuentas |
| F4 | `F4_carrito_acaparador.sql` | Quien llena el carrito y no compra |
| F5 | `F5_devoluciones_seriales.sql` | Quien devuelve casi todo |
| F6 | `F6_granja_de_registros.sql` | Desde que IP nacieron muchas cuentas en poco tiempo |

**Desde el 2026-10-17** la F4 no se usa (con el carrito en PostgreSQL apartar sin comprar ya no retiene unidades) y la F6 la calcula el backend sobre Elasticsearch, donde estan los registros (`evento_registro` de ClickHouse esta vacia desde el 2026-09-10). La R3 ("para ti") sale del grafo de compras de Neo4j desde el 2026-10-16. Los tres archivos siguen aqui como historia.

## Decisiones comunes

Las trece usan parametros de ClickHouse, `{nombre:Tipo}`. Es el mismo formato que recibe el driver de Node del backend en `query_params`, asi que el backend puede copiar cada archivo sin tocarlo. Los umbrales viven en `clickhouse/consultas/parametros.txt`. Lo que depende de quien pregunta (la cuenta, la sesion, el producto, la lista de candidatos) lo pone el backend en cada llamada.

Todas filtran por `lote`, que separa lo que mando el portal (`real`) de lo inventado por `clickhouse/lote` (`generado-N`). Mezclarlos seria recomendar o acusar por un patron que dibujo un script.

Las que leen `compra_producto` y `devolucion_producto` usan `FINAL`. Son tablas ReplacingMergeTree, y sin `FINAL` una compra que el ETL cargo dos veces cuenta dos veces hasta que ClickHouse fusione las partes.

Dos trampas de ClickHouse aparecieron al probar y quedaron anotadas en los archivos. Un alias del SELECT tapa a la columna del mismo nombre en el WHERE. Con `min(fecha) AS fecha` el filtro de fecha se volvio un agregado y la consulta no corrio (F2). Y con `toString(ip) AS ip` la comparacion contra la IP vacia fue texto contra IPv6 (F3). En PostgreSQL ninguna de las dos pasa.

## Recomendaciones

### R1 Vistos recientemente

Los ultimos productos distintos que miro una persona, del mas nuevo al mas viejo, con cuantas veces y si ya los compro. La persona es su cuenta si entro, o su sesion si no, y las dos a la vez, para que quien mira sin cuenta y despues entra vea tambien lo de antes. `ya_comprado` no filtra, informa, y el portal decide si esconderlos.

### R2 Quienes vieron esto tambien vieron

Para un producto P, los productos que aparecen en las mismas sesiones, ordenados por afinidad. La afinidad es el coseno, sesiones en comun divididas entre la raiz de las sesiones de P por las de Q. Con el conteo pelado el producto mas visto de la tienda saldria parecido a todo, porque esta en todas las sesiones.

Medido en la prueba, con P visto en 8 sesiones. Un producto con 4 sesiones en comun pero visto en 24 da 0.289. Otro con 3 en comun visto en solo 3 da 0.612 y sale primero. Ordenando por conteo el orden se invierte, y el arnes lo detecta.

### R3 Para ti

Toma los ultimos cinco productos que miro la persona. Cada uno pesa segun que tan reciente es, con vida media de 72 horas (lo de hace una hora pesa casi 1, lo de hace tres dias 0.5, lo de hace seis 0.25). Busca las sesiones de otras personas que vieron esos productos y todo lo demas que vieron es candidato. El puntaje de un candidato es la suma de los pesos que lo trajeron dividida entre la raiz de su popularidad. Se quitan lo que acaba de mirar y lo que ya compro.

La division por la popularidad salio de probar. Sin ella el producto mas popular de la prueba salia primero para la cuenta de ejemplo solo por estar en todas partes, y con ella sale ultimo. La columna `porque_viste` dice que productos trajeron cada recomendacion, y es el porque viste X que el portal puede mostrar.

### R4 Similares

Similar en esta tienda quiere decir de la misma categoria y parecido precio, y la categoria vive en MongoDB. ClickHouse guarda ids sueltos a proposito. Por eso R4 no busca los parecidos, recibe una lista de candidatos y dice cuales se mueven mas en los ultimos 7 dias, con un puntaje de 1 por sesion que lo vio, 3 por cuenta que lo agrego al carrito y 5 por unidad vendida. Mongo contesta que es parecido y ClickHouse contesta que quiere la gente.

### Como las usaria el backend

| Donde | Que se muestra | De donde sale |
|---|---|---|
| Ficha de producto | Quienes vieron esto tambien vieron | R2. Si da menos de 4, se completa con los de la misma categoria en Mongo (precio mas o menos 30 %) ordenados por R4 |
| Portada con sesion | Vistos recientemente | R1 por cuenta |
| Portada con sesion | Para ti | R3. Si la cuenta no tiene historial, T1 |
| Portada sin sesion | Vistos recientemente | R1 por sesion |
| Portada sin sesion | Lo que esta subiendo | T1 |

R3 se guardaria en Redis por cuenta 10 minutos y R2 por producto una hora, igual que hoy se guarda mas vendidos. Lo que se vio hace un minuto puede esperar diez para cambiar la recomendacion.

`vista_producto` esta ordenada por producto y fecha, que es lo que piden R2 y T1. R1 y R3 filtran por cuenta y hoy leen la tabla entera. Con 63 vistas reales no importa. Cuando crezca, la salida es una proyeccion ordenada por cuenta (`ALTER TABLE vista_producto ADD PROJECTION ...`), que ClickHouse elige sola. No se aplico.

## Tendencias

### T1 En ascenso

Compara el promedio diario de vistas de los ultimos 7 dias contra el de los 21 anteriores y ordena por cuantas veces crecio. Lee el resumen `vistas_por_producto_dia` que mantiene la vista materializada, asi que no depende de cuantas vistas haya.

Corrige dos cosas de la consulta que estaba en `clickhouse/README.md`. Compara promedios diarios y no totales, porque 7 dias contra todo lo anterior hacia ver mas frio a un producto con historia. Y suma 1 arriba y abajo, para que pasar de 0 a 1 vista no sea crecer infinito. Ademas exige 20 vistas recientes y un crecimiento de 1.5 veces.

Al lado va `vistas_por_persona`. En la prueba el producto inflado de F1 sale primero en T1, con 100 vistas por persona. Sin esa columna alguien lo celebraria como tendencia.

### T2 Embudo

Por producto, cuantas sesiones lo vieron, cuantas cuentas lo agregaron al carrito, cuantos pedidos y unidades salieron y cuantas volvieron. Solo lista los que tienen un problema. `mucho_interes_poca_compra` es al menos 20 sesiones con conversion de 2 % o menos, y apunta a precio, fotos o descripcion. `devolucion_alta` es al menos 30 % de lo vendido de vuelta, y apunta a que el producto no es lo que dice.

### T3 Busquedas sin respuesta

Terminos buscados por al menos 3 sesiones con un problema. `no_tenemos` es cuando todas las busquedas dieron cero resultados, demanda que se va a otra tienda. `no_convence` es cuando hubo resultados y nadie hizo clic. Compara en minusculas y sin espacios en las puntas, porque el backend guarda el termino tal como se escribio.

## Operaciones sospechosas

F2, F3, F5 y F6 devuelven cuentas, y son las que el documento 02 junta con los hallazgos del grafo. F1 devuelve productos y va al panel de tendencias. F4 va a una cola de operaciones de venta relampago.

### F1 Vistas infladas

Productos con 20 o mas vistas por sesion en promedio. Un vendedor que refresca su ficha 300 veces desde tres pestanas sube a mas vistos sin que nadie lo haya querido ver.

### F2 Compras en rafaga

Cuentas con 5 o mas pedidos dentro de 15 minutos. Para calificar hace falta una compra pagada, asi que un anillo tiene que comprar antes de calificar, y un guion compra en rafaga. Es la huella de compra de lo que Neo4j ve como anillo.

Usa ventana movil y no cubetas fijas de 15 minutos. Con cubetas, una rafaga que cruza el cambio de cuarto de hora queda partida en dos y no alcanza el minimo. Se comprobo saboteando la consulta con cubetas, y la rafaga de 6 pedidos de la prueba quedo en 5 en esa corrida.

### F3 Varias cuentas comprando desde la misma IP

IPs desde las que compraron 4 o mas cuentas, con la lista. Es la senal que el grafo no puede ver, y la lista de ids es la que el backend cruza con los anillos para la regla R-CASI-1.

Deja fuera `ips_de_confianza` (las del equipo, `::1` y `127.0.0.1`) y la IP vacia `::`. La segunda salio de la base real. Las compras que `etl/cargar_compras.sh` copia de PostgreSQL no traen IP porque pedidos no la guarda, y quedan con `::`. Sin excluirla salian cuatro cuentas compartiendo IP con 33 pedidos, y eran los dos compradores y dos vendedores de la semilla.

### F4 Carrito acaparador

Pares de cuenta y producto con 20 o mas unidades agregadas al carrito y 20 % o menos compradas. La venta relampago aparta existencias al agregar al carrito, y quien agrega 40 unidades y no compra las deja secuestradas hasta que el carrito vence. `veces` distingue un error de dedo (40 de un golpe) de un guion (de a 4, diez veces).

### F5 Devoluciones seriales

Cuentas con 3 o mas unidades devueltas y una tasa de 50 % o mas. El minimo absoluto evita que 1 de 1 cuente como 100 %.

### F6 Granja de registros

IPs desde las que se registraron 5 o mas cuentas dentro de 60 minutos, con las cuentas de la peor ventana. Es el nacimiento de lo que el grafo ve despues como granja o como reputacion expres. Ventana movil, igual que F2.

## Como se probo

`bash clickhouse/correr_consultas.sh` crea una base aparte, `mesh_prueba_consultas`, con el mismo `clickhouse/001_esquema.sql`, le carga `clickhouse/pruebas/siembra_consultas.sql` (848 filas) y corre las trece consultas. `clickhouse/pruebas/comprobar.py` revisa que cada escenario salga y cada control no. Despues borra la base y corre las trece contra la base real, solo leyendo.

No se siembra en la base real porque ClickHouse no tiene transacciones que deshacer, y borrar filas de `vista_producto` no le quita nada al resumen materializado.

| Consulta | Tiene que salir | Control que no tiene que salir |
|---|---|---|
| R1 | lo visto por la cuenta 1001 en orden 3, 2, 1, con el 2 comprado | lo visto hace 40 dias, lo de otra sesion sin cuenta |
| R2 | el 10 antes que el 15, afinidad 0.612 | productos con una sola sesion en comun |
| R3 | el 10 primero y el popular ultimo, con su porque | lo que acaba de mirar, lo que ya compro |
| R4 | 15, 11, 12, 10 | el candidato sin eventos |
| T1 | el producto que paso de 1 a 10 vistas por dia | el que va parejo, el que crecio con 15 vistas |
| T2 | 25 sesiones y ninguna compra, 4 devoluciones de 10 | el que convierte al 20 % |
| T3 | dron acuatico sin resultados (contando la escrita con mayusculas), cable hdmi sin clics | mouse con clics, una sola sesion buscando asdf |
| F1 | 300 vistas de 3 sesiones | |
| F2 | 6 pedidos en 10 minutos | 6 pedidos en 6 dias |
| F3 | 5 cuentas en una IP | 3 cuentas, la IP del equipo con 7, la IP vacia con 6 |
| F4 | 40 unidades al carrito y ninguna comprada | las mismas 40 compradas, 5 sin comprar |
| F5 | 4 de 5 devueltas | 1 de 5, 2 de 2 |
| F6 | 6 cuentas en media hora | 6 en seis dias, 10 desde la IP del equipo |

Resultado del 2026-09-23, 34 comprobaciones y ninguna falla, y la base de prueba borrada.

La prueba corrigio una expectativa. La asercion de R2 decia que el producto 3 estaba en 7 sesiones y la consulta dijo 8. Tenia razon la consulta, la octava es la de la propia cuenta 1001.

### Los sabotajes

| Sabotaje | Que dijo el arnes |
|---|---|
| R3 sin dividir por la popularidad | FALLA, el popular sale primero |
| R2 ordenando por sesiones en comun | FALLA, el 15 sale antes que el 10 |
| F3 sin excluir la IP vacia | FALLA, salen las 6 cuentas de la IP vacia |
| F2 con cubetas fijas de 15 minutos | FALLA, la rafaga de 6 queda en 5 |

### Lo que encontraron en la base real

Con la cuenta de mas vistas (admin) y el producto de mas sesiones.

| Consulta | Filas | Que es |
|---|---|---|
| R1 | 10 | Lo que miro admin, 5 ya comprados |
| R2 | 1 | Un producto con 3 sesiones en comun |
| R3 | 5 | Recomendaciones con su porque |
| R4 | 8 | Los 8 mas vistos, ordenados |
| T2 | 2 | Dos productos con todo lo vendido de vuelta (9 de 9 y 2 de 2) |
| F2 | 1 | Meme#gordo, cuenta del equipo, con 8 pedidos en 15 minutos el 31 de agosto |
| F5 | 1 | ventas.norte devolvio 3 de 6 |
| T1, T3, F1, F3, F4, F6 | 0 | Hay muy pocos eventos reales (63 vistas, 42 busquedas, 1 registro) para que alcancen los minimos |
