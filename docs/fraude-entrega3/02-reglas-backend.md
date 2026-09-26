# Reglas del backend para agrupar y priorizar las alertas

Hoy el panel de fraude tiene dos listas que no se hablan. Las alertas de login (`alerta_fraude`, 160 pendientes el 2026-09-23) y los anillos de resenas (`anillo_fraude`, 9). Con las consultas nuevas de Neo4j y ClickHouse aparecen otros once tipos de hallazgo. Si cada uno llega como una alerta suelta, el admin recibe cientos de filas y la que importa queda en la pagina cuatro.

Este documento propone como juntarlas. Nada de esto esta implementado. `backend/` es de Jose David y no se toco.

La idea en cinco pasos.

1. Cada detector produce hallazgos con la misma forma.
2. Los hallazgos que comparten cuentas se juntan en un caso.
3. Cada caso tiene un puntaje que sube con la cantidad y la variedad de la evidencia.
4. El puntaje da un nivel, y unas pocas reglas explicitas suben un caso a casi confirmado sin importar el puntaje.
5. El panel ordena por nivel y despues por puntaje, y cada nivel hace algo distinto.

## 1. El hallazgo

Todo detector, sea Cypher, ClickHouse o el login, entrega lo mismo.

| Campo | Que es |
|---|---|
| `fuente` | grafo, eventos o login |
| `tipo` | el nombre de la consulta, por ejemplo `ciclo`, `cadena_abierta`, `compras_en_rafaga` |
| `cuentas` | los ids de usuario involucrados |
| `clave` | esos ids ordenados y unidos con guion, igual que `anillo_fraude.clave` |
| `evidencia` | los ids concretos (resenas, pedidos, registros) |
| `metricas` | los numeros que dio la consulta (horas, vueltas, exclusividad) |
| `ultima_evidencia` | la fecha del evento mas nuevo |

El mismo hallazgo encontrado en dos corridas es la misma fila, identificada por fuente, tipo y clave. Es lo que ya hace `registrarAnilloFraude` con su UPSERT, y se mantiene.

### Victima o autor

Las alertas de login mezclan dos cosas. `multi_cuenta_ip` e `ip_rotacion_cuenta` describen a quien actua (muchas cuentas desde una IP). `fuerza_bruta_cuenta`, `toma_cuenta` y `viaje_imposible` describen a la cuenta atacada, que es la victima. Sumar un ataque de fuerza bruta al puntaje de fraude de la cuenta atacada la castigaria por ser atacada. Las tres de victima van a una cola aparte de seguridad de cuentas y no entran en los casos.

## 2. Los casos

Dos hallazgos van al mismo caso si comparten al menos una cuenta. Se resuelve con union y busqueda sobre las cuentas cada vez que corre un detector, solo para los casos que ese detector toco.

Hay tres excepciones, y las tres salieron de mirar los datos reales.

- Una cuenta concentradora no une casos. Una tienda recibe resenas de casi todos, y si cualquier hallazgo que la toque la usara de puente, todos los casos terminarian siendo uno. Se propone que una cuenta que escribio o recibio resenas de mas de 10 contrapartes distintas se agregue al caso pero no sirva para juntar dos casos. Hoy ninguna cuenta pasa de 10 (medido, la tienda tiene 3, porque casi todas las resenas son de los dos compradores de la semilla), asi que la regla todavia no cambia nada. Con clientes de verdad la primera tienda que reciba 11 ya uniria todo sin ella.
- Una IP de confianza no une nada. `127.0.0.1` sale en las alertas `multi_cuenta_ip` de todas las cuentas de prueba porque el equipo prueba desde la misma maquina. Si juntara casos, todos los anillos de prueba serian un solo caso gigante. Es la misma lista `ips_de_confianza` de las consultas de ClickHouse, mas la IP vacia `::`.
- Nucleo y periferia. Una cuenta que aparece en dos o mas hallazgos, o en uno fuerte (ciclo, reiterado, granja, coordinados), es del nucleo. Una que solo aparece en un hallazgo debil (una cadena abierta sin agravantes, por ejemplo) es periferia. Se lista en el caso pero ninguna accion automatica la toca. Pasa hoy con admin y compradora.norte, que calificaron a una cuenta de un anillo de prueba y por eso aparecen en una cadena abierta.

## 3. El puntaje

Cada tipo de hallazgo vale unos puntos base.

| Fuente | Tipo | Puntos | Por que ese peso |
|---|---|---|---|
| grafo | ciclo (A.1, 3 o 4 cuentas) | 30 | Estructura dificil de explicar sin acuerdo |
| grafo | reiterado (A.2) | 30 | El mismo producto en los dos sentidos |
| grafo | mutuo (A.1, 2 cuentas) | 15 | Dos cuentas que se compraron entre si puede pasar |
| grafo | granja (B.2) | 25 por el peso en la reputacion del vendedor | Tres satelites en una tienda grande pesan poco |
| grafo | coordinados (B.6) | 20 | Sin relacion entre ellas, solo el reloj las une |
| grafo | favor devuelto (B.5) | 20 si tardo menos de 1 hora, 12 si menos de 24, 8 si menos de 72 | Cuanto mas rapido, menos se explica como compra |
| grafo | reputacion expres (B.7) | 20 si el autor tenia menos de 60 minutos, 10 si no | Minutos no alcanzan para comprar, recibir y escribir |
| grafo | cadena abierta (B.1) | 15, mas 10 si nacieron juntas, mas 10 si los extremos comparten casa | Sola es comun, con agravantes no |
| grafo | persistente (B.3) | 15, mas 10 si es mutuo, mas 5 si la regularidad es menor que 0.2 | Un fan fiel existe, un reloj no |
| grafo | misma casa con calle (A.4) | 10, solo si el caso ya tiene otro hallazgo de resenas | Una familia comparte casa |
| eventos | varias cuentas por IP al comprar (F3) | 20 | La huella fisica que el grafo no ve |
| eventos | granja de registros (F6) | 20 | El nacimiento de lo que el grafo ve despues |
| eventos | compras en rafaga (F2) | 15 | Un anillo tiene que comprar antes de calificar |
| eventos | devoluciones seriales (F5) | 10 | Comprar para calificar y devolver |
| login | multi cuenta por IP (y su version lenta) | 10 | Lo mismo que F3, en la entrada |
| login | rotacion de IP por cuenta | 5 | Puede ser un celular cambiando de red |

B.4 no es un tipo aparte. Modifica al ciclo o al mutuo que describe. Suma 10 si el anillo tuvo dos o mas olas (se reactivo), 10 si el detector de hoy no lo ve y 5 si la ronda va en orden.

Con eso se arma el puntaje del caso.

1. Por cada tipo se toma el hallazgo que mas vale, y cada hallazgo mas del mismo tipo suma el 20 % de sus propios puntos, sin pasar del doble. Asi un triangulo que aparece por tres pares no cuenta tres veces.
2. Se suman los tipos.
3. Se multiplica por la variedad de motores. Si toda la evidencia viene de un solo motor el factor es 1. Si viene de dos (por ejemplo grafo y eventos) es 1.3, y de tres es 1.6. Dos bases que no comparten datos y dicen lo mismo valen mas que una base que lo dice dos veces.
4. Se multiplica por la recencia, 0.5 elevado a los dias desde la ultima evidencia divididos entre 30, sin bajar de 0.5. El piso de 0.5 es a proposito. Un anillo viejo no se apaga del todo, porque el hallazgo de B.4 dice que los viejos son justo los que hoy nadie ve.

El puntaje no tiene tope. Sirve para ordenar, y los niveles se cortan en umbrales.

## 4. Los niveles

| Nivel | Cuando |
|---|---|
| informativo | puntaje menor que 20 |
| revisar | puntaje de 20 a 49 |
| prioritario | puntaje de 50 o mas |
| casi confirmado | cumple al menos una regla R-CASI, sin importar el puntaje |

Las reglas de casi confirmado son pocas y cada una exige evidencia de dos familias distintas, la estructura de las resenas y algo sobre la identidad o el tiempo de las cuentas. Ninguna consulta sola basta. Si una sola bastara, bajar un umbral convertiria a cualquiera en culpable.

| Regla | Condicion | Lo que quiere decir |
|---|---|---|
| R-CASI-1 | Un ciclo, un reiterado o una granja, y ademas las cuentas del nucleo comparten casa con calle (A.4), o compraron desde la misma IP (F3), o nacieron desde la misma IP (F6) | Se califican entre si y son la misma persona fisica |
| R-CASI-2 | Un ciclo, un mutuo o una cadena abierta, y ademas al menos dos cuentas del nucleo recibieron resenas expres de autores con menos de 60 minutos de vida (B.7) | Nadie compra, recibe y califica en minutos. Es un guion |
| R-CASI-3 | Una cuenta del nucleo califico un producto y despues lo devolvio (la resena y la devolucion comparten autor, producto y vendedor), y el caso tiene otro hallazgo de resenas | Compro para poder calificar y recupero el dinero |
| R-CASI-4 | Un ciclo con dos o mas olas (B.4) y todas sus notas altas | El anillo se usa cada tanto, como un recurso |
| R-CASI-5 | Coordinados (B.6), y ademas las dos cuentas compraron o nacieron desde la misma IP (F3 o F6) | Dos teclados, una mano |

Cada caso guarda que reglas cumplio. El panel las muestra en palabras, para que quien revisa sepa por que esta ahi.

## 5. Que pasa en cada nivel

| Nivel | Que hace el sistema solo | Que queda para el admin |
|---|---|---|
| casi confirmado | Las resenas de las cuentas del nucleo dejan de contar para el promedio publico del vendedor, sin borrarse. Aviso inmediato en la campana de admin, arriba de todo | Confirmar o descartar. Suspender cuentas solo despues de confirmar |
| prioritario | Aviso en la campana de admin | Revisar |
| revisar | Aparece en el panel | Revisar cuando pueda |
| informativo | Aparece en el panel solo si se filtra por el | Nada |

Ninguna cuenta se suspende sola. Esconder resenas del promedio se puede deshacer con un clic y protege a los compradores mientras alguien mira. Suspender una cuenta no se deshace igual de facil, y si la regla se equivoco el costo lo paga una persona. Por eso lo decide alguien con nombre, y queda registrado quien.

### El ciclo de vida

Los estados son los de hoy (pendiente, revisada, descartada) mas uno nuevo, confirmada, que es el unico que permite sanciones.

Descartar pide un motivo y guarda la firma de la evidencia que habia en ese momento (los tipos de hallazgo y sus claves). El caso no vuelve a aparecer mientras la evidencia sea la misma. Si llega un hallazgo de un tipo nuevo o de cuentas nuevas, el caso se reabre como pendiente con una nota que dice que cambio. Hoy un anillo marcado revisado deja de contar para siempre, aunque despues de otra vuelta.

### En que orden se ve el panel

1. Nivel, de casi confirmado a informativo.
2. Puntaje, de mayor a menor.
3. Ultima evidencia, de la mas nueva a la mas vieja.

## 6. Cuando corre cada cosa

| Que | Cada cuanto | Donde |
|---|---|---|
| A.1, A.2 (como hoy), B.5, B.7 | Al momento, despues de proyectar cada resena nueva | Donde hoy corre `detectarInmediato` |
| A.1, A.2, B.1, B.2, B.6 | Cada 15 minutos | El worker de hoy |
| B.3, B.4, A.4 | Una vez al dia | Worker nuevo. Miran la historia entera y son los que cubren el punto ciego de 60 dias |
| F2, F3, F6 | Cada 15 minutos | Worker nuevo, igual que `MasVendidosSyncService` |
| F5 | Una vez al dia | Mismo worker |
| El agrupador | Despues de cada corrida, solo sobre los casos tocados | |

F1 (vistas infladas) y F4 (carrito acaparador) no entran en los casos de fraude de resenas. F1 va al panel de tendencias como aviso y saca al producto de mas vistos. F4 va a una cola de operaciones de venta relampago, y se propone ademas un tope de unidades por cuenta en cada oferta limitada.

## 7. Tablas y rutas que harian falta

Tablas nuevas, propuestas para una migracion 026 que no se escribio en `migrations/` a proposito, porque `arrancar.ps1` aplica todo lo que encuentra ahi. Era la 022. El 2026-09-25 la 022 se la quedaron las reglas de descuento por periodo y la 023 la familia B de anillos, asi que esta paso a la 024, y esa misma noche la 024 se la quedaron los vectores de la recomendacion semantica, y la 025 los hallazgos F1 a F6 que implemento el companero. Queda en la 026.

```sql
CREATE TABLE nivel_caso_fraude (
    id_nivel_caso_fraude  smallserial PRIMARY KEY,
    nivel_nombre          varchar(20) NOT NULL UNIQUE   -- informativo, revisar, prioritario, casi_confirmado
);

CREATE TABLE caso_fraude (
    id_caso_fraude           bigserial PRIMARY KEY,
    id_nivel_caso_fraude     smallint NOT NULL REFERENCES nivel_caso_fraude,
    puntaje                  numeric(8,2) NOT NULL,
    reglas_cumplidas         text[] NOT NULL DEFAULT '{}',
    id_estado_alerta_fraude  smallint NOT NULL REFERENCES estado_alerta_fraude,
    firma_al_descartar       text,
    motivo                   text,
    ultima_evidencia         timestamptz NOT NULL,
    fecha_creacion           timestamptz NOT NULL DEFAULT now(),
    fecha_actualizacion      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE hallazgo_fraude (
    id_hallazgo_fraude  bigserial PRIMARY KEY,
    id_caso_fraude      bigint NOT NULL REFERENCES caso_fraude ON DELETE RESTRICT,
    fuente              varchar(10) NOT NULL CHECK (fuente IN ('grafo', 'eventos', 'login')),
    tipo                varchar(40) NOT NULL,
    clave               varchar(255) NOT NULL,
    puntos              numeric(6,2) NOT NULL,
    metricas            jsonb NOT NULL DEFAULT '{}',
    ultima_evidencia    timestamptz NOT NULL,
    UNIQUE (fuente, tipo, clave)
);

CREATE TABLE hallazgo_fraude_cuenta (
    id_hallazgo_fraude  bigint NOT NULL REFERENCES hallazgo_fraude ON DELETE CASCADE,
    id_usuario          bigint NOT NULL REFERENCES usuarios ON DELETE RESTRICT,
    es_nucleo           boolean NOT NULL,
    PRIMARY KEY (id_hallazgo_fraude, id_usuario)
);

CREATE TABLE hallazgo_fraude_resena (
    id_hallazgo_fraude  bigint NOT NULL REFERENCES hallazgo_fraude ON DELETE CASCADE,
    id_resena           bigint NOT NULL REFERENCES resena ON DELETE RESTRICT,
    PRIMARY KEY (id_hallazgo_fraude, id_resena)
);

INSERT INTO estado_alerta_fraude (estado_alerta_fraude_nombre) VALUES ('confirmada');
```

`metricas` va en jsonb porque cada tipo trae numeros distintos y solo se muestran. Las resenas de evidencia van en su propia tabla con llave foranea, igual que `anillo_fraude_resena`, para que no puedan apuntar a una resena borrada. `anillo_fraude` se queda como esta y el agrupador la lee como una fuente mas, asi no hay que tocar el detector de hoy para empezar.

Rutas nuevas.

```
GET   /admin/fraude/casos?nivel=&estado=&pagina=     ordenado como dice el punto 5
GET   /admin/fraude/casos/:id                        hallazgos, cuentas (nucleo y periferia), evidencia y reglas cumplidas
PATCH /admin/fraude/casos/:id                        estado y motivo
```

## 8. El ejemplo, con los datos del 2026-09-23

Se aplicaron las reglas a mano sobre lo que devolvieron las consultas reales. Sale esto.

| Caso | Cuentas del nucleo | Hallazgos | Regla | Nivel |
|---|---|---|---|---|
| 1 | anillo.uno, anillo.dos, anillo.tres | ciclo, reiterado, misma casa, favor devuelto en 1.48 h, invisible para el detector | R-CASI-1 | casi confirmado |
| 2 | anit9543251 a anit9543254 y anit2038151 a anit2038154 (y admin y compradora.norte en la periferia) | dos ciclos, dos cadenas abiertas con los dos agravantes, expres en 0.2 minutos, las ocho cuentas en la misma casa | R-CASI-1 y R-CASI-2 | casi confirmado |
| 3 | pareja1, pareja2 | reiterado, favor devuelto en menos de un minuto, expres | R-CASI-2 | casi confirmado |
| 4 a 9 | los seis triangulos de prueba (desarrollador, pruebaui, desarrollador123, desarrolladorXD, desarrolladorMemes, memitospro) | ciclo, expres | R-CASI-2 | casi confirmado |
| 10 | Meme#gordo | compras en rafaga, 8 pedidos en 15 minutos | ninguna | informativo |
| 11 | ventas.norte | devolvio 3 de 6 unidades | ninguna | informativo |

El caso 2 muestra para que sirve agrupar. Los dos anillos anit se crearon en dias distintos, no se califican entre ellos y el grafo los ve como dos circulos separados. Pero el arnes que los creo usa siempre la misma direccion, y A.4 encuentra a las ocho cuentas en la misma casa (28 pares). Juntos son un solo caso, que es lo que son, el mismo guion corrido dos veces.

Todos los casi confirmados son cuentas que crearon los arneses de prueba o la semilla del anillo. Lo son de verdad, un guion las creo, las hizo comprar y las hizo calificar. Los dos informativos son una cuenta del equipo y un vendedor de la semilla, y el admin los descartaria con un motivo.

El puntaje del caso 1 paso a paso, porque es el que hoy no aparece en ningun lado.

1. Ciclo, 30, mas 10 porque el detector no lo ve y 5 porque va en orden, 45.
2. Reiterado del par anillo.uno y anillo.dos, 30, con los mismos dos agregados de B.4, 45. Reemplaza al mutuo del mismo par, como ya hace el detector.
3. Misma casa con calle, 10.
4. Favor devuelto en 1.48 horas, 12.
5. Suma 112. Un solo motor, factor 1. La ultima resena es del 8 de marzo, 199 dias, y la recencia cae al piso de 0.5. Puntaje 56, que por si solo ya seria prioritario, y por R-CASI-1 queda casi confirmado.

Y lo que no aparece. comprador.sur y compradora.norte, que escriben 87 de las 122 resenas, califican a los mismos vendedores durante meses y coinciden en 14 productos, no tienen ningun caso. compradora.norte solo aparece en la periferia del caso 2, por una resena a una cuenta de prueba. Era lo que habia que conseguir.

## 9. Lo que estas reglas no hacen

- No deciden culpas. El nivel mas alto esconde resenas del promedio y avisa. Sancionar lo hace una persona.
- Los puntos base y los umbrales son una primera propuesta, calibrada con 122 resenas. Con datos reales de mas volumen hay que volver a medir, como se hizo aqui con los dos compradores.
- Las pruebas de este diseno pasan por Neo4j, PostgreSQL y ClickHouse, no por el backend. Cuando se implemente, la prueba de punta a punta tiene que crear cuentas, comprar y calificar por HTTP, como `pruebas/anillos.sh`.
