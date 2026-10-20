# Fraude en Mesh, deteccion, reglas de casi confirmado y casos

Este documento explica todos los tipos de fraude que existen en Mesh, como se
detecta cada uno, como se juntan las senales en casos, como se calcula el
puntaje y cuales son las reglas que suben un caso a casi confirmado. Todo sale
del codigo del backend tal como esta el 2026-10-19, despues de la limpieza de
fraude del 17-10 (migracion 042). Las demos y la semilla para ensenar cada tipo
estan en `docs/FRAUDE-CATALOGO.md`.

## 1. El recorrido de una deteccion

Un fraude pasa por cuatro pasos.

1. Un detector encuentra un patron y escribe una senal en `senal_fraude`, una
   fila por tipo y clave (la cuenta, la IP, el producto o el grupo de cuentas).
   Las cuentas de la senal van en `senal_fraude_cuenta`, con su rol (autor o
   victima). Si el mismo patron se vuelve a encontrar, la senal no se duplica,
   solo se mueve su `ultima_deteccion`.
2. Cada 15 minutos, y una vez al arrancar el backend, el agrupador lee todas
   las senales que no estan descartadas y las convierte en hallazgos, una forma
   comun para todas (motor, tipo, cuentas, metricas y fecha de la ultima
   evidencia).
3. El agrupador junta los hallazgos que comparten cuentas en grupos, decide que
   cuentas son nucleo y cuales periferia, calcula el puntaje y revisa las
   reglas de casi confirmado.
4. Cada grupo se guarda como un caso en `caso_fraude`, con su evidencia en
   `evidencia_caso_fraude`, sus cuentas y las reglas que cumplio en
   `caso_fraude_regla`. El admin lo ve en el panel, en Fraude, pestana Casos.

El codigo del agrupador esta en `backend/src/services/fraude/`.

| Archivo | Que hace |
|---|---|
| `hallazgo-fraude-adaptador.service.ts` | Lee las senales y decide cuales pueden entrar a un caso |
| `agrupador-fraude.service.ts` | Junta los hallazgos en grupos y decide nucleo y periferia |
| `puntaje-fraude.service.ts` | Calcula el puntaje del grupo |
| `reglas-casi-confirmado.service.ts` | Revisa las reglas R-CASI |
| `persistencia-caso-fraude.service.ts` | Guarda el caso, fusiona casos y pone el nivel |
| `agrupador-fraude-worker.service.ts` | Lo corre cada 15 minutos y al arrancar |
| `casos-fraude.service.ts` | Lo que hace el admin con un caso |

## 2. Los tipos de fraude

El catalogo vive en la tabla `tipo_senal_fraude` y tiene 31 tipos en cinco
familias. Los detectores generan 30. El tipo `anillo_en_el_tiempo` (B.4) esta
en el catalogo pero ningun detector lo escribe, se dejo fuera de alcance el
2026-09-25.

Cada tipo tiene un motor en el catalogo (`fuente_senal_fraude`). Ese motor es
el que cuenta para el factor de diversidad del puntaje (seccion 5). Los tipos
de texto de las resenas tienen el motor `elastic` por historia, aunque desde el
18-10 se calculan con los vectores de PostgreSQL (pgvector).

En las tablas, la columna Caso dice si el tipo entra a un caso de fraude y
cuantos puntos vale. Fuerte quiere decir que un solo hallazgo de ese tipo ya
vuelve nucleo a sus cuentas (seccion 4).

### 2.1 Anillos de resenas (Neo4j)

Archivo `anillos-detector.service.ts`. Corre cada 15 minutos y tambien al
escribir una resena, en una version acotada a esa resena. Mira 60 dias. Busca
en el grafo caminos de cuentas que se escriben resenas entre si
(`ESCRIBIO` y `CALIFICA_A`) que vuelven a la cuenta de partida, de 4 a 8
saltos, es decir de 2 a 4 cuentas, con todas las resenas dentro de la ventana.

| Tipo | Que es | Umbral | Caso |
|---|---|---|---|
| `ciclo` (A.1) | Tres o cuatro cuentas que se compran y se califican en circulo | Un ciclo de 3 a 4 cuentas | 30 puntos, fuerte |
| `mutuo` | Dos cuentas que se califican la una a la otra. Las horas entre la ida y la vuelta van en el detalle | Un par | 15 puntos mas el bono de ida y vuelta |
| `reiterado` (A.2) | El par mutuo sobre el mismo producto | Un par | 30 puntos mas el bono de ida y vuelta, fuerte |

### 2.2 Patrones de resenas en el grafo (Neo4j)

Archivo `patrones-fraude-detector.service.ts`. Corre cada 15 minutos sobre 60
dias. Coordinados y persistente tambien corren al escribir una resena. Los
umbrales son los de `neo4j/consultas/B0_parametros.cypher`. Nota alta es 4 o 5
estrellas.

| Tipo | Que es | Umbral | Caso |
|---|---|---|---|
| `satelites` (B.2) | Cuentas recien nacidas que solo le compran y le ponen notas altas a un vendedor | 3 cuentas, la primera resena a 7 dias o menos de nacer | 25 puntos, fuerte |
| `persistente` (B.3) | Una cuenta que califica alto al mismo vendedor mes tras mes y casi a nadie mas | 3 meses distintos y el 60 % de sus resenas | 15 puntos mas su bono |
| `coordinados` (B.6) | Dos cuentas que califican lo mismo al mismo vendedor casi a la vez | 3 productos, cada par de resenas a 24 horas o menos | 20 puntos, fuerte |
| `reputacion_expres` (B.7) | Un vendedor recien nacido que recibe notas altas de cuentas recien nacidas | Vendedor de 7 dias o menos, autor de 24 horas o menos | 20 puntos si el autor tenia menos de 60 minutos, 10 si no |
| `anillo_en_el_tiempo` (B.4) | Un anillo que se reactiva despues de meses | Ninguno | No se genera |

### 2.3 El texto de las resenas (PostgreSQL con pgvector)

Cada resena tiene un vector calculado con Ollama (modelo
`paraphrase-multilingual`) en `vector_comentario`, y una valoracion del texto
que hace la regresion logistica de `clasificador-resenas/`. La valoracion es
mala si la probabilidad de que el texto sea malo es 0.8 o mas, buena si es 0.2
o menos, dudosa en el medio, y corta si la resena tiene menos de 100
caracteres. Las cortas no se valoran ni cuentan para estos detectores.

Dos resenas son gemelas si el coseno entre sus vectores es 0.92 o mas. Una
resena es contradictoria si el texto es malo con 4 o 5 estrellas, o bueno con
1 o 2. Las de 3 estrellas y las dudosas nunca cuentan.

Corren cada 15 minutos sobre 180 dias. Ademas, al escribir una resena,
`chequeo-texto-inmediato.service.ts` calcula su vector y su valoracion en el
momento y la evalua en todas estas senales sin esperar al reloj.

| Tipo | Archivo | Que es | Umbral | Caso |
|---|---|---|---|---|
| `resenas_repetidas` | `resenas-repetidas-detector` | Una cuenta que repite la misma resena | 5 resenas con gemela de la misma cuenta, y el 30 % de las suyas | 15 puntos |
| `anillo_de_texto` | `anillo-de-texto-detector` | Varias cuentas con la misma plantilla sobre un vendedor | 3 cuentas con gemelas escritas a 30 dias o menos | 25 puntos |
| `notas_incoherentes_cuenta` | `notas-incoherentes-detector` | Una cuenta que pone estrellas contrarias a lo que escribe | 5 contradictorias y el 20 % de sus resenas valoradas | 10 puntos |
| `notas_incoherentes_vendedor` | `notas-incoherentes-detector` | Lo mismo en las resenas de un vendedor | 5 y el 20 % | Solo alerta |
| `notas_incoherentes_producto` | `notas-incoherentes-detector` | Lo mismo en las resenas de un producto | 5 y el 40 % | Solo alerta |
| `resenas_parecidas_vendedor` | `resenas-parecidas-detector` | Un vendedor cuyas resenas son copias entre cuentas distintas | 5 con gemela de otra cuenta, escritas a 30 dias o menos, y el 20 % | Solo alerta |
| `resenas_parecidas_producto` | `resenas-parecidas-detector` | Lo mismo sobre un producto | 5 y el 40 % | Solo alerta |

### 2.4 Resenas y compras canceladas (PostgreSQL)

Archivo `resenas-canceladas-detector.service.ts`. Corre cada 15 minutos sobre
60 dias, y tambien en el momento en que se cancela un pedido comprado, porque
es la cancelacion la que completa el patron. En Mesh una devolucion es
cancelar un pedido comprado, que deja un movimiento de stock con motivo
devolucion y reembolsa el pago. La cancelacion tiene que ser despues de la
resena y dentro de 72 horas, y no cuenta si el autor tiene otra compra vigente
de ese producto a ese vendedor.

| Tipo | Que es | Umbral | Caso |
|---|---|---|---|
| `resena_positiva_cancelada` | Una resena de 4 o 5 estrellas de una compra que despues se cancelo | Una sola vez | 20 puntos, fuerte |
| `resenas_negativas_canceladas_vendedor` | Un vendedor con muchas resenas de 1 o 2 estrellas de compras canceladas | 5 | Solo alerta |

### 2.5 Login en el momento (Redis y Elasticsearch)

Archivos `fraude-login.service.ts`, `toma-cuenta.service.ts` y
`viaje-imposible.service.ts`, en `backend/src/services/fraude-login/`. Salen en
el mismo intento de login, de los contadores de Redis o comparando con el
historial de la cuenta en Elasticsearch.

| Tipo | Que es | Umbral | Caso |
|---|---|---|---|
| `fuerza_bruta_cuenta` | Muchos fallos contra una cuenta | 5 en 60 segundos | No, la cuenta es la victima |
| `fuerza_bruta_ip` | Muchos fallos desde una IP | 8 en 60 segundos | No, no tiene cuentas |
| `multi_cuenta_ip` | Una IP que prueba muchas cuentas | 4 identificadores en 300 segundos | 10 puntos, solo como evidencia extra |
| `ip_rotacion_cuenta` | Una cuenta probada desde muchas IPs | 4 IPs en 300 segundos | 5 puntos, solo como evidencia extra |
| `toma_cuenta` | Una cuenta que entra desde una IP que nunca uso | La cuenta ya tenia 3 logins buenos | No, la cuenta es la victima |
| `viaje_imposible` | Dos logins buenos tan lejos y tan seguidos que no hay avion que llegue | Mas de 800 km por hora | No, la cuenta es la victima |

### 2.6 Login lento (Elasticsearch)

Archivo `fraude-login-retrospectivo.service.ts`. Corre cada 15 minutos sobre
las ultimas 24 horas, y en cada intento de login acotado a esa cuenta y esa IP.
La granja de registros mira 30 dias, solo corre con el reloj y no cuenta las
IPs de la propia maquina (`127.0.0.1` y `::1`).

| Tipo | Que es | Umbral | Caso |
|---|---|---|---|
| `fuerza_bruta_cuenta_lenta` | Fallos contra una cuenta repartidos en el dia | 15 en 24 horas | No, la cuenta es la victima |
| `multi_cuenta_ip_lenta` | Una IP que prueba muchas cuentas a lo largo del dia | 8 identificadores en 24 horas | 10 puntos, solo como evidencia extra |
| `ip_rotacion_cuenta_lenta` | Una cuenta probada desde muchas IPs a lo largo del dia | 5 IPs en 24 horas | 5 puntos, solo como evidencia extra |
| `granja_de_registros` | Muchas cuentas nacidas desde la misma IP | 5 en 60 minutos | 20 puntos |

### 2.7 Compras y navegacion (ClickHouse)

Archivo `hallazgos-evento-fraude-detector.service.ts`, con las consultas de
`clickhouse/consultas/`. Corre una vez al dia y Nest no lo dispara al arrancar
(para no esperar esta `node pruebas/correr_detectores_fraude.cjs`). Mira 30
dias, solo el lote real, y trae como mucho 10 resultados por consulta en cada
corrida.

| Tipo | Que es | Umbral | Caso |
|---|---|---|---|
| `vistas_infladas` (F1) | Un producto que una misma sesion abre una y otra vez | 20 vistas por sesion | No, va como aviso al panel |
| `compras_en_rafaga` (F2) | Una cuenta que compra muchas veces en minutos | 5 pedidos en 15 minutos | 15 puntos |
| `ip_multicuenta_compras` (F3) | Varias cuentas comprando desde una IP | 4 cuentas, sin contar la IP de la propia maquina | 20 puntos |
| `devoluciones_seriales` (F5) | Una cuenta que devuelve casi todo lo que compra | 3 unidades devueltas y el 50 % | 10 puntos |

## 3. Lo que nunca forma caso

El adaptador deja fuera tres clases de senales. Se siguen viendo en el panel,
cada una en su pestana, pero no suman puntos ni unen cuentas.

- Las de victima. `fuerza_bruta_cuenta`, `fuerza_bruta_cuenta_lenta`,
  `toma_cuenta` y `viaje_imposible` describen a la cuenta atacada. Sumarlas a
  su puntaje la castigaria por ser atacada. `fuerza_bruta_ip` tampoco entra
  porque no tiene ninguna cuenta.
- Las de producto y vendedor, que son solo alerta para el admin.
  `notas_incoherentes_producto`, `notas_incoherentes_vendedor`,
  `resenas_parecidas_producto`, `resenas_parecidas_vendedor` y
  `resenas_negativas_canceladas_vendedor`. Un producto con textos copiados o
  contrarios a sus estrellas puede ser tanto quien compra resenas como la
  victima de una campana en contra, asi que no se acusa a nadie.
- `vistas_infladas`, que es un aviso para el panel de tendencias y no tiene
  cuentas.

Tambien quedan fuera las senales que el admin ya descarto. Una senal marcada
como falso positivo no vuelve a sumar puntos ni a unir cuentas.

## 4. Como se unen las senales en un caso

### 4.1 Union por cuentas compartidas

Dos hallazgos van al mismo grupo si comparten al menos una cuenta, y la union
es transitiva. Si A comparte un hallazgo con B y B comparte otro con C, las
tres terminan en el mismo grupo aunque A y C nunca hayan compartido nada. Se
hace con union y busqueda (`backend/src/helpers/union-find.ts`), con
compresion de camino.

### 4.2 Las cuentas concentradoras no sirven de puente

Una cuenta que escribio o recibio resenas de mas de 10 contrapartes distintas
es concentradora, por ejemplo la tienda o un vendedor grande. Se agrega al
grupo que le toca, pero nunca une dos grupos, porque si lo hiciera cualquier
hallazgo que la toque juntaria todos los casos en uno. Para contar sus
contrapartes no se usan las resenas que ya son evidencia de un anillo. Asi un
vendedor con una granja de mas de 10 satelites no queda protegido por su
propio fraude.

### 4.3 El login nunca une

Compartir una IP es un indicio y no una prueba. Dos personas en el mismo wifi
no deben terminar en un caso de resenas solo por eso. Por eso los hallazgos de
login (`multi_cuenta_ip`, `ip_rotacion_cuenta` y sus versiones lentas) solo se
agregan como evidencia extra a un grupo que ya exista por otra evidencia. No
meten cuentas nuevas al caso, no vuelven nucleo a nadie, y si ninguna de sus
cuentas esta ya en un grupo se descartan. Por la misma razon, al guardar, una
senal de login nunca hace que dos casos se fusionen.

### 4.4 Nucleo y periferia

Despues de agrupar, cada cuenta del grupo es nucleo o periferia. Es nucleo si
aparece en 2 o mas hallazgos del grupo, o en uno solo de un tipo fuerte. Los
tipos fuertes son `ciclo`, `reiterado`, `satelites`, `coordinados` y
`resena_positiva_cancelada`. Una cuenta concentradora nunca es nucleo. Las
demas son periferia. El nucleo importa para las reglas R-CASI-2 y R-CASI-3.

## 5. El puntaje

El puntaje de un grupo es la suma por tipo, multiplicada por el factor de
diversidad y por el factor de recencia.

### 5.1 Puntos por hallazgo

Cada hallazgo vale los puntos de su tipo que estan en las tablas de la
seccion 2, mas estos bonos.

- Ida y vuelta, para `mutuo` y `reiterado`. Si el par se devolvio la nota en
  menos de 1 hora suma 20, en menos de 24 horas 12, en menos de 72 horas 8, y
  despues nada.
- Persistente. Suma 10 si la relacion es mutua y 5 si la regularidad entre
  sus resenas es menor que 0.2.
- Reputacion expres. Vale 20 si el autor tenia menos de 60 minutos de vida y
  10 si no.
- Los bonos de B.4 (olas del anillo) estan escritos pero no llegan nunca,
  porque ninguna senal guarda las olas.

### 5.2 Repeticion del mismo tipo

Por cada tipo cuenta entero el hallazgo que mas vale, y cada uno de los demas
del mismo tipo suma el 20 % de sus puntos, sin pasar del doble del que mas
vale. Asi un triangulo que aparece por tres pares no cuenta tres veces.

### 5.3 Diversidad de motores

Si toda la evidencia viene de un solo motor el factor es 1, de dos es 1.3, de
tres o mas es 1.6. Los motores son grafo (Neo4j), eventos (compras y la granja
de registros), login, elastic (el texto de las resenas) y postgres (las
canceladas). La idea es que dos motores que no se hablan apunten a las mismas
cuentas.

### 5.4 Recencia

El factor es 0.5 elevado a los dias desde la ultima evidencia divididos entre
30, y nunca baja de 0.5, para que un caso viejo no se apague del todo. La
ultima evidencia es la `ultima_deteccion` de la senal, que solo mueve el
detector. Mientras el patron siga vivo el detector la renueva en cada corrida
y el factor se queda cerca de 1.

### 5.5 Un ejemplo

Tres cuentas en ciclo (30 puntos) que ademas compran desde la misma IP
(`ip_multicuenta_compras`, 20 puntos), las dos senales detectadas hoy. Suman
50, vienen de dos motores (grafo y eventos), asi que el factor es 1.3, y la
recencia es 1. El puntaje es 65.

## 6. Los niveles

| Nivel | Cuando |
|---|---|
| `casi_confirmado` | Cumple al menos una regla R-CASI, sin importar el puntaje |
| `prioritario` | Puntaje de 50 o mas |
| `revisar` | Puntaje de 20 a menos de 50 |
| `informativo` | Puntaje menor que 20 |

El caso del ejemplo tendria 65 y seria prioritario por puntaje, pero como hay
un ciclo y compras desde la misma IP cumple R-CASI-1 y queda casi confirmado.

## 7. Las reglas de casi confirmado

Estan en `reglas-casi-confirmado.service.ts` y su descripcion en la tabla
`regla_casi_confirmado` (migraciones 026 y 042). Todas piden lo mismo, que dos
motores que no se hablan apunten al mismo grupo de cuentas. Si se cumple una,
el caso sube a casi confirmado aunque su puntaje sea bajo. Las reglas que
cumplio quedan guardadas en el caso.

| Regla | Lo que revisa el codigo | La idea |
|---|---|---|
| R-CASI-1 | En el grupo hay un `ciclo`, un `reiterado` o un `satelites`, y ademas un `ip_multicuenta_compras` o una `granja_de_registros` | Se califican entre si y son la misma persona, compran o nacieron desde la misma IP |
| R-CASI-2 | En el grupo hay un `ciclo` o un `mutuo`, y ademas 2 o mas hallazgos de `reputacion_expres` con autor de menos de 60 minutos que tocan alguna cuenta del nucleo | Nadie compra, recibe y califica en minutos, es un guion |
| R-CASI-3 | El grupo tiene algun hallazgo del grafo o del texto, y una cuenta del nucleo califico un producto y despues lo devolvio, con la resena y la devolucion del mismo autor, el mismo producto y el mismo vendedor | Compro para poder calificar y recupero el dinero |
| R-CASI-5 | En el grupo hay un `coordinados`, y ademas un `ip_multicuenta_compras` o una `granja_de_registros` | Dos teclados y una sola mano |

Detalles que conviene saber decir.

- R-CASI-1 y R-CASI-5 miran que los dos tipos esten en el mismo grupo. Que
  sean las mismas cuentas lo asegura la union de la seccion 4, porque para
  estar en el mismo grupo tienen que compartir cuentas, directo o por cadena.
- En R-CASI-2, un hallazgo de reputacion expres cuenta si cualquiera de sus
  cuentas es nucleo, sea la que escribio o la que recibio la resena.
- R-CASI-3 busca la devolucion en PostgreSQL al momento de evaluar, siguiendo
  resena, pedido del mismo autor, movimiento de stock con motivo devolucion y
  oferta del mismo producto y vendedor. Un hallazgo de `resena_positiva_cancelada`
  solo (motor postgres) no basta como el otro hallazgo de resenas, hace falta
  uno del grafo o del texto.
- La descripcion de R-CASI-2 en la base menciona tambien una cadena abierta,
  pero ese tipo (B.1) se quito y el codigo ya no la mira.
- R-CASI-4 (un ciclo con dos o mas olas) se quito el 17-10 porque las olas no
  se guardan en ninguna senal y nunca se podia cumplir. Tambien se quito la
  parte de R-CASI-1 de cuentas que comparten casa, porque nunca hubo detector
  de direcciones.

## 8. La vida de un caso

### 8.1 Se recalcula entero cada 15 minutos

En cada corrida el agrupador parte de cero con todas las senales vigentes. La
evidencia y las cuentas de cada caso se reemplazan enteras en cada corrida.
Por eso una senal nueva tarda hasta 15 minutos en verse en un caso.

### 8.2 Se encuentra, se crea o se fusiona

Para cada grupo se buscan los casos que ya tienen alguna de sus senales como
evidencia, sin contar las de login.

- Si no hay ninguno, se crea un caso nuevo en estado pendiente.
- Si hay uno, se actualiza con el puntaje, el nivel y la evidencia nuevos.
- Si hay dos o mas, se fusionan. Pasa cuando una senal nueva conecta dos
  anillos que antes estaban separados. Sobrevive el caso de menor id y los
  demas se borran. Si alguno de los fusionados ya estaba revisado o
  confirmado, el que sobrevive hereda el estado mas grave (confirmada sobre
  revisada, revisada sobre pendiente), para que no se pierda la decision del
  admin.

### 8.3 Un caso descartado puede volver

Al descartar un caso se guarda su firma, que es la lista de motor, tipo y
cuentas de cada hallazgo. Si en una corrida futura la evidencia del caso cambia
y la firma ya no es la misma, el caso se reabre como pendiente con una nota. Si
la firma es identica, se queda descartado, misma evidencia y misma decision.

### 8.4 Lo que hace el admin

Desde el panel, un caso pendiente se puede mover a revisada, descartada o
confirmada, y solo desde pendiente. Descartar exige escribir un motivo.
Confirmar marca el caso como fraude pero no aplica ninguna sancion automatica
a las cuentas.

### 8.5 Limpieza

Al final de cada corrida se borran los casos pendientes que se quedaron sin
ninguna evidencia, por ejemplo porque una prueba borro sus senales. Un caso que
el admin ya reviso, confirmo o descarto nunca se borra solo.

## 9. Cuando corre cada cosa

| Que | Cuando |
|---|---|
| Anillos y patrones del grafo | Cada 15 minutos, y al escribir una resena la parte acotada |
| Texto de las resenas | Cada 15 minutos, y al escribir una resena |
| Resenas canceladas | Cada 15 minutos, y al cancelar un pedido comprado |
| Login en el momento | En cada intento de login |
| Login lento | Cada 15 minutos, y en cada intento de login acotado |
| Granja de registros | Cada 15 minutos |
| Compras y navegacion | Una vez al dia, no al arrancar |
| Agrupador de casos | Cada 15 minutos y una vez al arrancar el backend |

Para una demo, `node pruebas/correr_detectores_fraude.cjs` corre todos los
detectores una vez y despues el agrupador, sin esperar el reloj.
