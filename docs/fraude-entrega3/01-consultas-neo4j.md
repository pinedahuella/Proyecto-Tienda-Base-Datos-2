# Consultas de Neo4j para patrones de resenas (B.1 a B.7)

Las consultas A.1 a A.5 (ver `neo4j/README.md`) contestan una pregunta cada una. Hay circulo, hay par mutuo sobre el mismo producto, hay rafaga, hay casa compartida. Las siete de este documento buscan lo que esas cinco no ven por construccion.

| # | Archivo | Que busca |
|---|---|---|
| B.1 | `B1_cadena_abierta.cypher` | Cadena de 3 a 5 cuentas que se pasan notas altas y la reputacion nunca vuelve al origen |
| B.2 | `B2_satelites.cypher` | Un vendedor rodeado de cuentas desechables que solo lo califican a el |
| B.3 | `B3_persistente.cypher` | Una cuenta que califica al mismo vendedor mes tras mes y casi a nadie mas |
| B.4 | `B4_anillo_en_el_tiempo.cypher` | Los anillos de A.1 contados como historia, con vueltas, olas y si el detector de hoy los ve |
| B.5 | `B5_favor_devuelto.cypher` | A califica a B y B le devuelve la nota en pocas horas |
| B.6 | `B6_coordinados.cypher` | Dos cuentas que califican lo mismo del mismo vendedor casi al mismo tiempo, varias veces |
| B.7 | `B7_reputacion_expres.cypher` | Resenas de cuentas con minutos de vida a vendedores con dias de vida |

Ninguna prueba fraude sola. Cada una senala un conjunto de cuentas para que alguien lo mire, y el documento 02 dice como se suman.

## Decisiones comunes a las siete

Los umbrales no van escritos dentro de las consultas. Viven en `B0_parametros.cypher` como `:param` y las consultas los leen como `$nombre`. Asi el backend puede copiar el texto sin tocarlo y pasarle los mismos nombres al driver. Hoy el detector del backend tiene su propia copia de A.1 y A.2 con la ventana escrita a mano, y por eso ya no son el mismo texto que el del repositorio. Con parametros eso no vuelve a pasar.

Cada consulta devuelve una columna `clave` con los ids de las cuentas ordenados y unidos con guion, igual que `anillo_fraude.clave` en PostgreSQL. El backend puede guardar lo que encuentra en el mismo formato, y el arnes la usa para comparar contra SQL.

Las que recorren caminos de largo variable (B.1 y B.4) exigen que las cuentas del camino sean todas distintas. Cypher garantiza que un camino no repite relaciones, pero si puede repetir nodos, y con eso A.1 llego a inventar un anillo de cuatro cuentas donde habia dos. El filtro es el mismo que el de A.1.

Ninguna usa APOC. Ordenar una lista se hace con `COLLECT { UNWIND ... ORDER BY ... }`, que viene en Neo4j 5.

Una nota alta es 4 o 5. Los anillos regalan 5, pero se acepta 4 para que bajar una estrella a proposito no alcance para esconderse.

## B.1 Cadena abierta

La pregunta es si hay cuentas que se pasan estrellas en fila, A a B, B a C, C a D, sin que nadie le devuelva nada a A. Es el anillo con un eslabon de menos, y A.1 no lo ve porque busca caminos que vuelven al inicio.

Se piden tres cosas a la vez. Todas las notas altas, toda la cadena dentro de 30 dias, y que no exista ningun camino de resenas de D de vuelta a A de hasta tres cuentas. Lo ultimo se agrego al medir. La primera version solo pedia que D no calificara a A directamente, y dentro de un anillo de cuatro el tramo A, B, C salia como cadena abierta aunque la reputacion vuelve a A por D.

Si A, B, C, D es cadena, tambien lo son A, B, C y B, C, D. La consulta se queda solo con la mas larga, porque tres filas para un hallazgo es contarlo tres veces.

Informa tres agravantes. Si las cuentas nacieron con menos de 48 horas de diferencia, si los extremos viven en la misma casa con calle, y si la cadena desemboca en un anillo cerrado.

En los datos reales salen cuatro cadenas y las cuatro desembocan en un anillo. Dos son la cuenta de mas que los arneses de prueba ponen alrededor de sus anillos (anit9543254 y anit2038154), nacidas junto con las otras y en la misma casa. Las otras dos empiezan en admin y en compradora.norte, que calificaron a una cuenta de un anillo de prueba, sin ningun agravante.

## B.2 Satelites

La pregunta es si hay un vendedor rodeado de cuentas que en toda su vida solo lo calificaron a el, siempre con nota alta, y que escribieron su primera resena a los pocos dias de abrirse. Hacen falta al menos tres. Es la forma de estrella del fraude. El vendedor no le devuelve nada a nadie, asi que ni A.1, ni A.2, ni B.1 la ven.

Para no confundir una granja con una tienda chica con clientes fieles, sale `peso_en_su_reputacion`, que es la parte de lo que el vendedor recibio que viene de sus satelites. Tres satelites en un vendedor con 200 resenas no mueven nada. Tres en uno con cuatro resenas son toda su reputacion.

Por que se pide que califiquen solo a ese vendedor y no que lo califiquen mucho. Se midio con los dos compradores reales. comprador.sur le escribio 10 resenas a ventas.sur y compradora.norte 15 a la tienda, asi que por volumen serian los primeros sospechosos. Pero reparten lo que escriben entre cinco vendedores. Un satelite hace lo contrario.

En los datos reales no sale nada. El vendedor mas cercano es anit9543251, con dos satelites y un tercer autor (admin) que tambien califica a otros.

## B.3 Persistente

La pregunta es si hay una cuenta que califica al mismo vendedor con nota alta en al menos tres meses distintos y que le dedica a ese vendedor al menos el 60 % de todo lo que escribe.

A.3 busca la rafaga. Quien ya sabe que la rafaga se ve hace lo contrario, una nota cada tantas semanas, siempre al mismo, para que ninguna ventana corta lo junte. Esta consulta mira la historia entera.

El numero que separa al inflador del cliente fiel salio de medir. comprador.sur califico a ventas.sur 10 veces en 5 meses, todas altas, y eso es el 63 % de lo que ventas.sur recibio. Por tiempo y por nota seria el primer sospechoso. Pero esas 10 son solo el 23 % de lo que el escribe. Los dos compradores reales estan entre 0.09 y 0.37 de exclusividad con cualquier vendedor, y el umbral de 0.6 los deja fuera con margen.

| Columna | Que mide |
|---|---|
| `exclusividad` | resenas de A a B entre todas las que escribio A. Filtra |
| `dependencia` | resenas de A a B entre todas las que recibio B. Ordena, porque dice cuanto de la reputacion de B se cae si A es falsa |
| `regularidad` | la desviacion de los dias entre resenas sobre su promedio. Cerca de 0 es un reloj, y una persona no compra como un reloj |
| `es_mutuo` | si B tambien le devuelve notas a A |

En los datos reales no sale nada. En la prueba sale la cuenta sembrada que califica una vez cada 30 dias, con regularidad 0, y no sale el cliente fiel sembrado al lado, que tiene exclusividad 0.4.

## B.4 Anillo en el tiempo

Toma los mismos circulos que A.1, pero en vez de preguntar si existen pregunta como vivieron. Para cada anillo junta todas las resenas que van de una cuenta a la siguiente en el sentido del circulo, no solo las de un camino, y mide esto.

| Columna | Que mide |
|---|---|
| `vueltas` | cuantas veces se completo el circulo entero. Manda el tramo con menos resenas |
| `olas` | cuantas tandas separadas por mas de 14 dias |
| `dias_de_vida` | de la primera resena a la ultima |
| `en_orden` | si alguna vuelta sigue el orden del circulo en el reloj, A a B, despues B a C, despues C a A, arrancando en cualquier tramo. Es la ronda de una sola persona manejando las cuentas una tras otra |
| `visible_para_el_detector` | lo que haria hoy `AnillosDetectorService`, que solo ve un anillo si cada tramo tiene una resena en los ultimos 60 dias |

Esta es la consulta que encontro el hallazgo mas importante. El anillo anillo.uno, anillo.dos y anillo.tres es de marzo de 2026 y es el unico que se sembro en PostgreSQL como fraude de verdad. Con la ventana de 60 dias el detector del backend ya no lo ve, y por eso no esta en `anillo_fraude` (se comprobo, la tabla tiene 9 anillos y ese no esta). La ventana existe para no revivir anillos viejos, y esta bien que exista, pero deja un punto ciego. Un anillo lento, que tarda mas de 60 dias en cerrar, nunca entra.

La primera version de `en_orden` tenia dos errores que el arnes encontro. Juntaba los tramos sin ordenarlos, y como `collect()` junta en el orden en que llegan las filas, el tramo cero no siempre era el que sale de la primera cuenta. Y solo probaba la ronda que arranca en el primer tramo, cuando la que arranca en cualquier otro tambien es ronda.

En los datos reales salen 11 anillos, todos de una vuelta y una ola. Todos los de prueba estan en orden y cerraron en segundos. El de marzo sale con `visible_para_el_detector` en FALSE.

## B.5 Favor devuelto

La pregunta es si A le pone nota alta a B y B le devuelve nota alta a A en menos de 72 horas.

A.2 pide que el intercambio sea sobre el mismo producto. Es la version mas fuerte y tambien la mas facil de esquivar, basta con calificar productos distintos. B.5 no mira el producto, mira el reloj. Para calificar a A, B tiene que haberle comprado a A, recibido el paquete y sentarse a escribir, y que eso pase horas despues de que A lo califico se explica mal como compra.

Dice quien empezo el primer intercambio y cuantas horas tardo la vuelta. En los datos reales salen pareja1 y pareja2 (la vuelta en menos de un minuto) y anillo.uno y anillo.dos (1.48 horas). En la prueba sale el par sembrado con 5 horas sobre productos distintos, que A.2 no ve, y no sale el par que devolvio la nota diez dias despues.

## B.6 Coordinados

La pregunta es si hay dos cuentas que califican el mismo producto del mismo vendedor con menos de 24 horas de diferencia, al menos tres veces. Es fraude sin ninguna relacion entre las dos cuentas. No se califican entre si ni forman circulo, van juntas como una sola mano con dos teclados.

Por que a la vez y no solamente lo mismo. Los dos compradores reales coinciden en 14 pares de producto y vendedor, porque son los que mas compran y los productos populares son pocos. Pero solo 2 de esas 14 cayeron dentro de 24 horas. Coincidir en lo que se compra es normal, y coincidir tres veces en el momento ya no.

En los datos reales no sale nada. En la prueba sale el par sembrado con tres coincidencias de menos de una hora, y no sale la tercera cuenta que califica lo mismo una semana despues.

## B.7 Reputacion expres

La pregunta es si hay resenas altas escritas por una cuenta con menos de 24 horas de vida a un vendedor con menos de 7 dias de vida. Se agrupan por vendedor y se informa cuantos minutos de vida tenia el autor mas rapido.

Para calificar el backend exige una compra pagada. Una persona se registra, busca, compra, espera y despues califica. Hacerlo en minutos es lo que hace un guion.

Es la unica consulta de esta familia que dispara en los datos reales sin sembrar nada, y lo que encuentra es cierto. Los anillos que dejan los arneses de prueba son cuentas que un guion crea, hace comprar y hace calificar en segundos. Salen 26 filas, todas de esos arneses, con autores de 0 a 1.6 minutos de vida.

La primera version tenia un error que costo un resultado falso. La semilla del proyecto carga resenas de febrero a agosto sobre cuentas cuya fecha de alta es el dia en que se cargo la base, asi que 86 resenas quedan antes de que su autor existiera. La resta daba negativa, menor que 24 horas, y los dos compradores reales salian como cuentas recien nacidas con menos 296 674 minutos de vida. Ahora se exige que la resena sea posterior al alta del autor y del vendedor. B.2 tenia el mismo error con la edad de la cuenta desechable y se arreglo igual.

## Como se probo

`bash neo4j/correr_patrones.sh` hace tres cosas y termina en `Todo bien.` solo si las tres salen.

### Primero, contra los datos reales

Corre las siete consultas en Neo4j y las siete equivalentes de `neo4j/pruebas/equivalentes.sql` en PostgreSQL, que es la fuente de verdad, y compara fila por fila. Cada una se escribio en SQL con la misma regla. Resultado del 2026-09-23.

```
IGUALES, 43 filas (B.1 4, B.4 11, B.5 2, B.7 26)
```

### Despues, contra datos sembrados

`neo4j/pruebas/siembra_patrones.sql` mete 60 resenas en PostgreSQL dentro de una transaccion. En la misma sesion corren el extractor del grafo (`etl/extraer_grafo.sql`) y las equivalentes, y despues se hace ROLLBACK. PostgreSQL no guarda nada, y el arnes lo comprueba. Lo extraido se carga en Neo4j, se corren las mismas siete consultas y se compara otra vez.

Sembrar en PostgreSQL y no directo en Neo4j, como hace `siembra.cypher`, es lo que permite comparar. Asi las dos bases ven exactamente los mismos datos, y se prueba ademas que el ETL los lleva al grafo.

Cada patron tiene su caso que tiene que salir y al menos un control parecido que no.

| Escenario | Tiene que salir | Control que no tiene que salir |
|---|---|---|
| B.1 | cadena de 4 cuentas nacidas juntas, extremos en la misma casa, una sola fila | la misma forma con un 3 en medio, una cadena de 60 dias, los tramos cortos por separado |
| B.2 | granja de 4 satelites | una cuenta nueva que tambien califico a otro vendedor, un vendedor con solo 2 |
| B.3 | una nota cada 30 dias durante 5 meses | el cliente fiel con exclusividad 0.4 |
| B.4 | anillo de 3 vueltas en 3 olas, y un anillo lento de 95 dias fuera de orden e invisible para el detector | |
| B.5 | favor devuelto en 5 horas sobre productos distintos | el mismo intercambio con 10 dias de espera |
| B.6 | dos cuentas, tres coincidencias de menos de una hora | una tercera que califica lo mismo una semana despues |
| B.7 | vendedor con dos notas de cuentas de minutos | cuenta nueva que califica a una tienda vieja, satelites de tres dias, una resena anterior al alta de su autor |

Resultado del 2026-09-23.

```
IGUALES, 56 filas (B.1 5, B.2 1, B.3 4, B.4 15, B.5 3, B.6 1, B.7 27)
8 escenarios que salen, 13 controles que no, las 43 filas reales siguen con la siembra puesta
```

La siembra misma tuvo que corregirse dos veces por lo que dijo el arnes. Un control de B.3 mandaba resenas a cuentas de B.1 y armaba una cadena abierta que nadie habia sembrado a proposito. Y el anillo lento, que el comentario decia fuera de orden, era una ronda que arrancaba en el tercer tramo. Las dos veces la consulta tenia razon.

### Al final, la limpieza

Borra del grafo todo lo que tenga id negativo, que es la siembra, y compara los conteos de nodos y relaciones con los de antes. Quedaron iguales, 30 direcciones, 53 productos, 122 resenas, 102 usuarios y sus 405 relaciones.

### Los sabotajes

Un arnes que siempre da verde no prueba nada. Se rompio a proposito cada consulta, una por una, y se corrio el arnes.

| Sabotaje | Que dijo el arnes |
|---|---|
| B.1 sin la condicion de que no haya vuelta | FALLA, los tramos de los anillos salen como cadenas |
| B.3 sin el filtro de exclusividad | FALLA, los dos compradores reales salen como persistentes |
| B.4 con la ronda siempre en orden | FALLA, el anillo lento sale en orden y el SQL dice que no |
| B.7 sin exigir resena posterior al alta del autor | primero verde, y eso destapo un hueco |
| B.2 sin el mismo limite | FALLA |

El verde de B.7 se investigo. En los datos reales el alta del vendedor tapaba el error, porque los vendedores de la semilla tambien nacieron despues de sus resenas. Se agrego a la siembra un control con una resena anterior al alta de su autor sobre un vendedor nuevo, y con eso el mismo sabotaje dio FALLA en B.7 y en B.2.

## Lo que cuestan

Medido con PROFILE sobre el grafo real (102 usuarios, 122 resenas, 53 productos, 30 direcciones).

| Consulta | Accesos a la base | Lineas de Cypher | Lineas de SQL equivalente |
|---|---|---|---|
| B.1 | 2577 | 43 | 41, con CTE recursivo y una funcion para el camino de vuelta |
| B.2 | 1340 | 25 | 13 |
| B.3 | 2338 | 33 | 12 |
| B.4 | 5440 | 41 | 56, con CTE recursivo y una funcion en plpgsql para la ronda |
| B.5 | 4819 | 24 | 7 |
| B.6 | 5455 | 21 | 5 |
| B.7 | 1423 | 18 | 10 |

La comparacion con SQL dice algo claro. Donde la pregunta es de caminos de largo variable (B.1 y B.4) el SQL necesita recursion con control de ciclos escrito a mano y una funcion aparte, y en Cypher es un patron. Donde la pregunta es un self-join con una condicion de tiempo (B.5, B.6) el SQL es mas corto que el Cypher, porque lo largo en Cypher es armar las columnas de salida. Las lineas de Cypher incluyen esas columnas y los agravantes, que el SQL no calcula.

## Cuando conviene correr cada una

B.5 y B.7 dependen de una sola resena nueva y pueden correr al momento, en el mismo lugar donde hoy corre el chequeo acotado de A.1 y A.2 despues de crear una resena. B.1, B.2 y B.6 pueden ir en el worker de 15 minutos. B.3 y B.4 miran la historia entera y conviene correrlas una vez al dia, y son justo las que cubren el punto ciego de la ventana de 60 dias. El detalle de como se juntan esta en el documento 02.
