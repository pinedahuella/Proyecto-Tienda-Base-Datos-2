# Refactor de fraude: un solo modelo de señales

Documento vivo de trabajo. Se va llenando etapa por etapa. Cada etapa se prueba antes de pasar a la siguiente.

**Estado (2026-09-30): etapas 1 a 5 HECHAS, la 6 es OPCIONAL (sin construir), la 7 está EN CURSO (parte 1 hecha: el agrupador y los casos ya leen `senal_fraude`) y la 8 está PENDIENTE. Todo aplicado y probado en la base local; nada en `migrations/` todavía.**

Archivos de este refactor: este documento y `refactor-fraude-senales.sql` (mismo folder, es de REFERENCIA; la migración real la sube quien lleva `migrations/`).

## Por qué

El profesor pidió el refactor completo de fraude. Hoy cada detector guarda su resultado a su manera:

| Familia | Se detecta en | Se guarda en |
|---|---|---|
| Anillos de reseñas (A) y patrones de reseñas (B) | Neo4j | `anillo_fraude`, `anillo_fraude_resena` |
| Compras y navegación (F1 a F6) | ClickHouse | `hallazgo_evento_fraude`, `hallazgo_evento_fraude_cuenta` |
| Login | Redis, Elasticsearch y MongoDB | `alerta_fraude`, `notificacion_fraude` |

El agrupador de casos necesita tres adaptadores para leer tres tablas, `evidencia_caso_fraude` tiene tres llaves que pueden ser nulas, y de ahí salen los problemas medidos (C4: la fecha que mueve el admin se confunde con la fecha del fraude; y no queda historia de cuántas veces se detectó algo).

Fuentes: `docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md` sección 1 (raíz del repo, del compañero, solo lectura) y `docs/fraude-entrega3/02-reglas-backend.md`.

## El modelo

Cuatro piezas con el mismo nombre para todas las fuentes:

- **Señal** (PostgreSQL, `senal_fraude`): un patrón sobre un conjunto de entidades, identificado por tipo y clave. Ejemplo: "mutuo entre las cuentas 9 y 10". Si el detector lo vuelve a ver es la MISMA fila.
- **Detección** (ClickHouse, `deteccion_fraude`): cada vez que un detector ve una señal, con su fecha. Da el historial. ETAPA 6.
- **Evidencia**: una señal metida en un caso, con sus puntos. Una sola llave a `senal_fraude`.
- **Caso**: igual que hoy.

Normalizado al máximo: familia, fuente y rol son catálogos; las cuentas, reseñas, pedidos y productos de una señal viven cada uno en su pivote.

## Etapas

| Etapa | Qué se hace | Estado |
|---|---|---|
| 1 | Catálogos, `senal_fraude`, `senal_fraude_cuenta`, `senal_fraude_resena`, copiando SOLO desde `anillo_fraude`. Nada existente se toca | HECHO (local) |
| 2 | El backend escribe en `senal_fraude` cuando registra un anillo (doble escritura, `registrarAnilloFraude`). Aquí `total_detecciones` y `ultima_deteccion` empiezan a moverse de verdad | HECHO (2026-09-30, probado en vivo: `registrarSenalDelAnillo` en `registrar-anillo-fraude.ts`, misma transacción; el PATCH de revisión del admin todavía NO se refleja en la señal) |
| 3 | Sumar `hallazgo_evento_fraude` (F1 a F6) y su pivote de cuentas a `senal_fraude` | HECHO (2026-09-30). Copia inicial en el `.sql` (sección 7) y doble escritura en `registrar-hallazgo-evento-fraude.ts` (`registrarSenalDelHallazgo`), con la regla de reabrir. Probado en vivo. Ver "Etapa 3: decisiones" abajo |
| 4 | Sumar `alerta_fraude` (login). Aquí aparecen los casos difíciles: el rol víctima, la ventana por minuto y `notificacion_fraude` | HECHO (2026-09-30). Copia inicial en el `.sql` (sección 8) y doble escritura en `registrar-alerta-fraude.ts` (`registrarSenalDeLaAlerta`). Probado en vivo. `notificacion_fraude` NO se toca hasta la etapa 7. Ver "Etapa 4: decisiones" abajo |
| 5 | Pivotes `senal_fraude_pedido` y `senal_fraude_producto` (este último con `id_producto_mongo`, sin llave foránea, es por producto y no por variante). HECHO (2026-09-30): `senal_fraude_producto` y `senal_fraude_pedido` creadas y llenas (F1 y F4 los productos; F2, F3 y F5 los pedidos). Ver "Etapa 5: decisiones" abajo |
| 6 | `deteccion_fraude` en ClickHouse: cada detección con su fecha, y la vista materializada por día | OPCIONAL, sin construir en el backend. **Primero necesita que el compañero cree las tablas en ClickHouse** (`clickhouse/002_detecciones.sql`, ver "Etapa 6: lo que hay que crear" abajo); con las tablas creadas, el backend agrega el `INSERT` en una sola pieza (ver ese apartado). Se hace solo si el profesor o el compañero piden historial o un panel de tendencias |
| 7 | Cambiar `evidencia_caso_fraude` a una sola llave a `senal_fraude` y `notificacion_fraude` a apuntar a la señal. El agrupador lee solo `senal_fraude` y los tres adaptadores desaparecen | EN CURSO. PARTE 1 HECHA (2026-09-30): el agrupador, su persistencia y `casos-fraude.service.ts` leen y escriben `senal_fraude`; migración de referencia `refactor-fraude-senales-etapa7.sql` aplicada en local. PARTE 2 HECHA (2026-09-30): las tres rutas del admin (`alertas-resenas`, `alertas-eventos` y `alertas-login`) leen y actualizan `senal_fraude`. PARTE 3 HECHA (2026-09-30): `notificacion_fraude` cuelga de la señal y las rutas `GET`/`PATCH /perfil/alertas-fraude` la leen. Con eso, nada lee ya `anillo_fraude`, `hallazgo_evento_fraude` ni `alerta_fraude` para decidir nada: queda solo quitar las llaves viejas y las tablas en la etapa 8. Ver "Etapa 7, partes 1, 2 y 3: decisiones" abajo |
| 8 | Apagar las tablas viejas (`anillo_fraude`, `anillo_fraude_resena`, `hallazgo_evento_fraude`, `hallazgo_evento_fraude_cuenta`, `alerta_fraude`, `tipo_anillo_fraude`, `tipo_hallazgo_evento`, `tipo_alerta_fraude`), primero como vistas y al final borrarlas | EN CURSO. HECHO (2026-09-30): el agrupador lee `senal_fraude_resena` (C6) y los 3 helpers `registrar-*` ya NO escriben en las tablas viejas (probado en vivo: las viejas no cambian, la señal suma 2 detecciones en 2 llamadas). Las llaves viejas de `evidencia_caso_fraude` y `notificacion_fraude` ya se quitaron (paso 1, `refactor-fraude-senales-etapa8.sql`, aplicado en local, `id_senal_fraude` NOT NULL en las dos). Las vistas (paso 3) se OMITEN por decisión del 2026-09-30 (ver "Etapa 8: decisión sobre las vistas"). Los `ID_TIPO_*` de `models/` desaparecieron: `registrarAlertaFraude` y `registrarHallazgoEventoFraude` reciben el nombre del tipo (`tipo`) y lo buscan en `tipo_senal_fraude` (probado en vivo, `tsc` y `eslint` limpios). Paso 4 ESCRITO, NO APLICADO: `refactor-fraude-senales-etapa8-borrado.sql` borra los 2 pivotes, las 3 tablas viejas y los 3 catálogos de tipo (ensayado con `ROLLBACK`); solo falta aplicarlo cuando se decida con el compañero |

Cambios de esquema posteriores que ya se anticipan: `peso_base` y ventana en `tipo_senal_fraude` (cuando el puntaje deje de vivir en el código) y el rol por defecto de cada tipo de login (etapa 4).

## Tablas de la etapa 1 (las que hay que revisar)

Orden de prioridad para revisar, de la más importante a la menos.

| Prioridad | Tabla | Para qué sirve |
|---|---|---|
| 1 | `senal_fraude` | La tabla central. Una fila por patrón detectado. Identificada por (tipo, clave). Guarda el estado, `detalle` en jsonb, `primera_deteccion`, `ultima_deteccion`, `total_detecciones`, quién la revisó y cuándo. Lo más importante a entender: `ultima_deteccion` la mueve solo el detector y `fecha_actualizacion` solo la revisión del admin, para que revisar algo viejo no lo "rejuvenezca" en el puntaje (C4) |
| 2 | `senal_fraude_cuenta` | Pivote de las cuentas de la señal, cada una con su rol y con `es_nucleo`. Es donde se resuelve víctima vs. autor. Todavía solo tiene autores (los anillos no tienen víctimas) |
| 3 | `tipo_senal_fraude` | El catálogo único de los 25 tipos, con su familia y su fuente. Reemplaza a los tres catálogos de hoy. Sin peso ni ventana todavía |
| 4 | `senal_fraude_resena` | Pivote de las reseñas que son la evidencia. Es la copia de `anillo_fraude_resena` |
| 5 | `rol_cuenta_senal` | Catálogo de dos filas: `autor` y `victima`. El rol es del par señal-cuenta, no de la señal |
| 6 | `familia_senal_fraude` | Catálogo de cuatro filas: `anillo_resenas`, `patron_resenas`, `compras_navegacion`, `login` |
| 7 | `fuente_senal_fraude` | Catálogo de tres filas: `neo4j`, `clickhouse`, `login` |

Las tres últimas son catálogos triviales; lo que hay que decidir de ellas es solo si los nombres están bien.

## Cómo se comprobó la etapa 1

Contra la base local (`mesh-postgres`), 2026-09-29:

- Las 7 tablas se crean sin error. Catálogos: 4 familias, 3 fuentes, 2 roles, 25 tipos (los mismos nombres de los tres catálogos viejos, ninguno choca con otro).
- La copia se corrió DOS veces: la segunda no duplica nada (las filas de `senal_fraude_resena` y `senal_fraude_cuenta` no cambian, `senal_fraude` se refresca en sitio).
- Comparación contra el origen: 1 anillo → 1 señal (`reputacion_expres`, clave `14-16-17`), 2 reseñas en `anillo_fraude_resena` → 2 en `senal_fraude_resena`, y las 3 cuentas de `senal_fraude_cuenta` son exactamente las de la clave del anillo (14, 16, 17), todas autor y núcleo.
- Límite de la prueba: la base local solo tiene un anillo, de un tipo. Los demás tipos de anillo pasan por la misma consulta pero no se ejercitaron con datos.

## Lo que NO hace la etapa 1

- No cambia el backend. Ninguna ruta, detector ni el agrupador lee o escribe las tablas nuevas todavía.
- No guarda historia. Las tablas viejas no la tienen; por eso todo `total_detecciones` nace en 1. La historia real empieza con la etapa 2 (y se completa con la 6).
- La copia se debe volver a correr para refrescar `senal_fraude` mientras la etapa 2 no exista.

## Etapa 3: decisiones

`hallazgo_evento_fraude` tiene una fila por DÍA (el detector corre cada 24 h y mira los últimos 30 días, así que la evidencia de un día y la del siguiente casi coinciden). La señal es UNA por `(tipo, clave)`:

- Cada corrida suma 1 a `total_detecciones` (significa "veces vista", no frecuencia real) y refresca `detalle` y `ultima_deteccion`.
- **Regla de reabrir:** una señal `revisada` o `descartada` vuelve a `pendiente` SOLO si la detección trae evidencia nueva: una cuenta o un producto que la señal no tenía, o que la métrica principal del tipo suba respecto a la última lectura. Al reabrir se limpia quién y cuándo la revisó y se mueve `fecha_actualizacion`. Una `confirmada` nunca se reabre.
- Las cuentas van en `senal_fraude_cuenta` con rol `autor` (son las sospechosas, no se notifica a nadie) y los productos en `senal_fraude_producto`.

| Tipo | Métrica principal (clave del `detalle`) |
|---|---|
| F1 `vistas_infladas` | `vistas_por_sesion` |
| F2 `compras_en_rafaga` | `pedidos_en_la_peor_rafaga` |
| F3 `ip_multicuenta_compras` | `cuentas_distintas` |
| F4 `carrito_acaparador` | `agregadas` |
| F5 `devoluciones_seriales` | `devueltas` |
| F6 `granja_de_registros` | `cuentas_en_la_peor_ventana` |

Límite conocido: como `detalle` se sobrescribe con la última lectura, si la métrica baja y luego vuelve a subir al valor anterior, cuenta como crecimiento y reabre. Se afina después con un umbral mínimo si molesta.

Comprobado en vivo (datos sembrados y borrados): detección nueva, misma ventana, día siguiente, descartada + misma evidencia (no reabre), descartada + cuenta nueva (reabre), descartada + métrica igual o más baja (no reabre), descartada + métrica más alta (reabre), F1 con producto y sin cuentas, F4 con cuenta y producto.

## Etapa 4: decisiones

Las nueve alertas de login pasan por `registrarAlertaFraude`, así que la doble escritura vive en un solo lugar.

- **Una señal por `(tipo, clave)`**, no una por ventana (minuto o hora). Cada llamada suma 1 a `total_detecciones` ("veces vista") y refresca `detalle` y `ultima_deteccion`.
- **Cuentas:** todas con rol `victima`. Salen de la misma resolución que ya usaba la notificación (el `id_usuario` de la alerta, o los `identificadores` del `detalle` resueltos contra `usuarios`).
- **IP:** nuevas tablas `direccion_ip` (una fila por IP, tipo `inet`) y `senal_fraude_ip` (pivote). Se llenan con la `clave` en `fuerza_bruta_ip`, `multi_cuenta_ip` y `multi_cuenta_ip_lenta`, con `detalle.ips` en `ip_rotacion_cuenta` (y `_lenta`) y con `detalle.ip_nueva` en `toma_cuenta`. `fuerza_bruta_cuenta` y `viaje_imposible` no traen IP. Una IP que no sea válida se descarta sin romper la transacción. Las señales de F3 (`ip_multicuenta_compras`) y F6 (`granja_de_registros`), cuya `clave` es la IP, también llenan este pivote, tanto en la copia inicial (sección 7 del `.sql`) como en la doble escritura (`registrar-hallazgo-evento-fraude.ts`); ahí la IP nunca cuenta como evidencia nueva, porque es la misma `clave` de la señal. El enlace lo hace `vincular-ip-a-senal-fraude.ts`, compartido con el login.
- **Regla de reabrir:** una señal `revisada` o `descartada` vuelve a `pendiente` solo si hay evidencia nueva: una cuenta o IP que la señal no tenía, una métrica principal mayor, o, en los tipos de ventana corta, que hayan pasado más de 60 minutos desde la última detección (un episodio nuevo). Al reabrir se limpia quién y cuándo revisó. Una `confirmada` nunca se reabre.
- **Por qué el episodio nuevo:** los contadores de Redis se reinician, así que un ataque nuevo días después NO supera la última lectura de la métrica. Sin esa regla, una señal descartada nunca se reabriría aunque el ataque volviera. Los `_lenta` miran 24 h móviles y no lo necesitan.

| Tipo | Métrica principal | Ventana corta (episodio) |
|---|---|---|
| `fuerza_bruta_ip`, `fuerza_bruta_cuenta`, `fuerza_bruta_cuenta_lenta` | `fallos` | las dos primeras |
| `multi_cuenta_ip`, `multi_cuenta_ip_lenta` | `cuentas_distintas` | la primera |
| `ip_rotacion_cuenta`, `ip_rotacion_cuenta_lenta` | `ips_distintas` | la primera |
| `viaje_imposible` | `velocidad_kmh` | sí |
| `toma_cuenta` | ninguna (su evidencia nueva es la IP nueva) | sí |

- **Notificaciones:** `notificacion_fraude` sigue apuntando a `alerta_fraude`, sin cambios. La etapa 7 la cambia para que apunte a la señal.

Comprobado en vivo (datos sembrados y borrados): señal nueva, misma ventana, minuto siguiente, descartada + misma métrica (no reabre), + métrica mayor (reabre), + 5 h después con métrica menor (reabre por episodio nuevo), multi_cuenta_ip con cuentas reales (nueva cuenta reabre, mismas no), rotación con IP nueva (reabre) y con una IP inválida en la lista (no rompe), `toma_cuenta` con su IP, `viaje_imposible` sin IP.

## Etapa 5: decisiones

- **`senal_fraude_pedido`** (`id_senal_fraude`, `id_pedido` con llave foránea real a `pedido`, `ON DELETE RESTRICT`). Sin copia inicial: las tablas viejas nunca guardaron ids de pedido, solo el conteo dentro de `detalle`.
- **Quién la llena:** F2 (los pedidos de la peor ráfaga), F3 (los pedidos de las cuentas en esa IP) y F5 (los pedidos devueltos). Las tres consultas de `hallazgos-evento-fraude-detector.service.ts` ganaron una columna `ids_pedidos` (`groupUniqArray` o `groupArrayIf`, ordenada de mayor a menor y cortada a 50 con `MAX_PEDIDOS_POR_SENAL`). **Es la única diferencia con los F2, F3 y F5 de `clickhouse/consultas/` del compañero**: si él regenera esos archivos, debe agregar la misma columna.
- **Solo en la señal.** `hallazgo_evento_fraude` no tiene dónde guardar los ids y se apaga en la etapa 8, así que los ids de pedido NO se escriben en la tabla vieja. *Mejora pendiente:* si se quisiera verlos en el panel viejo, habría que agregarle un pivote o leerlos de la señal.
- **Pedidos que no existen:** el registro solo enlaza los ids que existen en `pedido` (la llave foránea reventaría con uno que no está, por ejemplo un evento de prueba o un pedido borrado). Esos ids tampoco cuentan como evidencia nueva, o la señal se reabriría en cada corrida por algo que nunca se puede enlazar.
- **Regla de reabrir:** un pedido que existe y la señal no tenía cuenta como evidencia nueva, igual que una cuenta o un producto.
- **IPv4 mapeadas:** ClickHouse guarda las IPv4 como IPv6 mapeadas (`::ffff:1.2.3.4`) y el login como `1.2.3.4`. `vincular-ip-a-senal-fraude.ts` (y `pg_temp.ip_segura` en la copia) las normalizan a IPv4, para que `direccion_ip` tenga una sola fila por máquina y se pueda cruzar por IP.

Comprobado en vivo con eventos sembrados en ClickHouse (ya borrados; ClickHouse volvió a sus 113 compras y 5 devoluciones): F2 con 7 pedidos (5 existen), F3 con 4 cuentas en una IP y F5 con 3 devoluciones; las tres enlazan solo los pedidos que existen; una segunda corrida suma 1 sin duplicar; con F3 descartada y los mismos pedidos no reabre, y con un pedido "nuevo" reabre.

## Etapa 7, partes 1 y 2: decisiones

**Archivo de referencia:** `refactor-fraude-senales-etapa7.sql` (va después de `refactor-fraude-senales.sql`; la migración real la sube el compañero). Es aditivo: `evidencia_caso_fraude` gana `id_senal_fraude` (con llave a `senal_fraude`, borrado en cascada y un índice único parcial), y el CHECK pasa de "exactamente una de las tres llaves viejas" a "al menos una de las cuatro". Las tres llaves viejas se quitan en la etapa 8.

- **Relleno de la evidencia que ya existe:** cada evidencia se enlaza con la señal de su mismo `(tipo, clave)`. Varias filas viejas (una por día o por ventana) dan la misma señal; si chocan dentro del MISMO caso eran el mismo hecho contado dos veces, y la más reciente gana y las otras se borran. Si chocan en casos DISTINTOS, la perdedora se queda con su llave vieja y sale un `NOTICE` para revisarla a mano antes de la etapa 8.
- **Adaptador:** `HallazgoFraudeAdaptadorService` tiene ahora un solo método, `obtener()`, que lee `senal_fraude` con su familia y sus cuentas (`senal_fraude_cuenta`, cualquier rol). Los tres `obtenerDe…` desaparecieron. La fuente del agrupador (`grafo`, `eventos`, `login`) sale de la familia de la señal. Se mantienen los mismos tipos incluidos y el filtro de `descartada`.
- **`idOrigen` es el id de la señal** y `ultimaEvidencia` sale de `ultima_deteccion`, que solo mueve el detector (resuelve C4: revisar una señal vieja ya no la "rejuvenece" en el puntaje).
- **Persistencia:** guarda `id_senal_fraude`; `COLUMNA_POR_FUENTE` desapareció.
- **Casos:** `casos-fraude.service.ts` resuelve la evidencia con un solo `JOIN` a la señal y mantiene la misma forma de respuesta de la API (`fuente`, `tipo`, `clave`, `metricas`).
- **Cambio de comportamiento esperado:** una señal agrupa todas sus ventanas, así que ya no cuenta dos veces el mismo hecho (bajan los puntos) y reúne las cuentas de todas las ventanas (suben las cuentas). En la base local, el caso 13 pasó de 54.08 puntos, nivel `prioritario` y 6 cuentas a 38.82, `revisar` y 11 cuentas.

Comprobado en vivo: (1) adaptador viejo contra nuevo sobre los datos reales: mismas cuentas en los tres tipos, y un solo hallazgo por señal donde antes había uno por ventana (3 → 1 y 7 → 1); (2) dos anillos separados, y un login que los une: se fusionan en un solo caso que hereda `confirmada`, con las 3 evidencias y las 4 cuentas; (3) un caso descartado con la misma evidencia sigue descartado (la firma de `casos-fraude.service.ts` y la de la persistencia coinciden), y llega una señal nueva que comparte una cuenta: se reabre; (4) el detalle del caso sale con la forma de siempre; (5) un ciclo completo del worker sobre la base local, dos veces seguidas, deja el mismo caso, sin duplicar ni perder evidencia.

**Pendiente fuera de `backend/`:** `pruebas/casos_fraude_fusion.cjs` y `pruebas/casos_fraude_granja.cjs` (del compañero) pasan ids de las tablas viejas como `idOrigen` y leen `anillo_fraude`; con este cambio fallarían. Hay que actualizarlas para que siembren señales.

## Etapa 7, parte 2: decisiones

Las tres rutas del admin de fraude por fuente (`GET`/`PATCH /admin/fraude/alertas-resenas` y `.../:id/detalle-grafo`, `GET`/`PATCH .../alertas-eventos` y `GET`/`PATCH .../alertas-login`) leen y actualizan `senal_fraude`. **Mismas URL, mismos filtros, mismos códigos de error y misma forma de respuesta.** Documentado en `endpoints/endpoints-fraude.md`.

- **El id de la API es el id de la señal** (`id_anillo_fraude`, `id_hallazgo_evento_fraude` e `id_alerta_fraude` valen `senal_fraude.id_senal_fraude`). Cada ruta solo ve las señales de su familia: `alertas-resenas` las de `anillo_resenas` y `patron_resenas`, `alertas-eventos` las de `compras_navegacion` y `alertas-login` las de `login`. El id de otra familia da `404`.
- **Campos que cambian de significado:** `contador` es `total_detecciones` y `ventana_inicio` es `ultima_deteccion` (en los eventos y en el login); `ultima_vez_confirmado_activo` (anillos) es `ultima_deteccion`; `id_producto_mongo` (eventos) sale de `senal_fraude_producto`.
- **`PATCH`:** marca la señal entera, solo si está `pendiente` (mismo 404 y 409 de antes). Como antes, no guarda quién revisó (`id_usuario_reviso` se queda en `NULL`; las columnas ya existen si se quiere atribuir). Si después llega evidencia nueva, el detector la reabre.
- **Cuentas:** salen del pivote `senal_fraude_cuenta`. *Corregido en esta parte:* las cuentas de un anillo ahora salen de su `clave` (el conjunto exacto que detectó el detector) y no de un join con las reseñas, que metía al vendedor también en `coordinados` (B.6), donde es un tercero ajeno al patrón. Cambió en `registrar-anillo-fraude.ts` y en la copia del `.sql` (sección 6).
- **`cuentas_afectadas` (login):** las cuentas son las víctimas del pivote; `fecha_lectura` es la de su notificación de la señal (`null` si no la ha leído). Antes de la parte 3 esto era provisional.
- **Las tablas viejas ya no se actualizan desde el `PATCH`:** el estado de revisión vive solo en la señal. Siguen recibiendo la doble escritura de los detectores hasta la etapa 8, pero nada las lee para decidir nada.

Comprobado en vivo (dentro de una transacción que se deshizo, con la señal real de la base y señales sembradas): listar, filtrar por tipo y estado, `PATCH` revisada o descartada, `PATCH` repetido (`409`), id que no existe (`404`), id de otra familia por la ruta equivocada (`404`), `detalle-grafo` de un anillo (Neo4j, 2 reseñas), F1 con producto y sin cuentas, F2 con una cuenta, y en el login el estado de lectura (una cuenta leyó y otra no, luego leen las dos).

## Etapa 7, parte 3: decisiones (notificaciones)

**Archivo de referencia:** la sección 5 y la 6 de `refactor-fraude-senales-etapa7.sql`. Aditivo, igual que la evidencia: `notificacion_fraude` gana `id_senal_fraude` (llave a `senal_fraude`, borrado en cascada), `id_alerta_fraude` pasa a ser opcional (se quita en la etapa 8) y hay un índice único parcial por `(id_senal_fraude, id_usuario)`.

- **Una notificación por señal y cuenta**, con su propio estado de lectura, en vez de una por cada alerta de minuto u hora. Se avisa **la primera vez que la cuenta aparece en la señal** y **cuando la señal se reabre** (por evidencia nueva): ahí la lectura vuelve a `NULL` y `fecha_creacion` se renueva, para que suba en la lista del usuario. Se resolvió así la pregunta abierta de las notificaciones del login.
- **`registrarAlertaFraude` ya no escribe notificaciones por alerta**; las crea `registrarSenalDeLaAlerta`, a partir de las cuentas víctima de la señal.
- **Pasar lo que ya existe (sección 6):** las 44 notificaciones de la base local quedaron en 14, una por (señal, cuenta); se conserva la más vieja y se borran las demás. Queda leída solo si leyó TODAS las de esa señal (con la fecha de la última lectura). Las cuentas víctima sin notificación (2 en la base local) se crean sin leer. Las 2 que estaban leídas pasaron a sin leer, porque pertenecían a señales con otras notificaciones sin leer.
- **Rutas del usuario** (`GET` y `PATCH /perfil/alertas-fraude`): mismas URL y forma de respuesta. `id_alerta_fraude` es el id de la señal, `contador` sus detecciones y `fecha_creacion` la última vez que se le avisó a esa cuenta. Una alerta de otra cuenta sigue dando `404`, y `detalle` sigue sin los `identificadores` de las demás cuentas.
- **Ruta del admin de login:** `cuentas_afectadas.fecha_lectura` sale de la notificación de cada cuenta.

Comprobado en vivo (dentro de una transacción que se deshizo): la alerta nace con 2 cuentas afectadas y 0 notificaciones viejas; dos ventanas más con las mismas cuentas no duplican nada; el usuario afectado la ve y un usuario no afectado no; marcarla leída es idempotente; marcar la alerta de otra cuenta o un id que no existe da `404`; el admin ve quién leyó; al descartarla y llegar una cuenta nueva, la señal se reabre, las tres cuentas quedan con la alerta sin leer y la cuenta nueva la ve.

## Etapa 8: PLAN para la próxima sesión (nada construido todavía)

Última actualización: 2026-09-30, al cerrar la sesión. Lo que sigue es un plan, no hay código ni SQL de la etapa 8 escrito.

**Propuesta acordada:** hacer los pasos 1 a 3 y dejar el 4 (borrar) como un archivo aparte, para decidirlo con el compañero después de un tiempo con las vistas.

1. **Quitar las llaves viejas.**
   - `evidencia_caso_fraude`: quitar `id_anillo_fraude`, `id_hallazgo_evento_fraude` e `id_alerta_fraude` (y sus tres índices únicos y llaves foráneas), dejar `id_senal_fraude` `NOT NULL` y reemplazar el CHECK `evidencia_caso_fraude_alguna_llave_check`.
   - `notificacion_fraude`: quitar `id_alerta_fraude` (y su `UNIQUE (id_alerta_fraude, id_usuario)`), dejar `id_senal_fraude` `NOT NULL` y quitar `notificacion_fraude_alguna_llave_check`.
   - Antes de tocar `NOT NULL`, comprobar que no queden filas con la llave nueva en `NULL` (el `NOTICE` de la parte 1 avisa de las evidencias que quedaron sin señal por chocar con otro caso).
2. **Dejar de escribir en las tablas viejas.** `registrar-anillo-fraude.ts`, `registrar-hallazgo-evento-fraude.ts` y `registrar-alerta-fraude.ts` escriben hoy la tabla vieja Y la señal (doble escritura, dentro de la misma transacción). Dejar solo la señal, y quitar la consulta previa a la tabla vieja (por ejemplo, la búsqueda de `mutuo`/`ciclo`/`reiterado` en `anillo_fraude`).
3. **Convertir las tablas viejas en vistas** sobre `senal_fraude` (`anillo_fraude`, `anillo_fraude_resena`, `hallazgo_evento_fraude`, `hallazgo_evento_fraude_cuenta`, `alerta_fraude`), para que nada se rompa de golpe y para detectar quién las sigue leyendo.
4. **Borrar** (archivo aparte, al final): las vistas, `tipo_anillo_fraude`, `tipo_hallazgo_evento` y `tipo_alerta_fraude`. No tiene vuelta atrás en una base real.

## Etapa 8: decisión sobre las vistas (2026-09-30)

**El paso 3 (convertir las tablas viejas en vistas) se omite.** Se pasa del paso 2 (ya hecho: los helpers no escriben en las tablas viejas) y del paso 1 (ya hecho: `refactor-fraude-senales-etapa8.sql`) directo al paso 4, el borrado, en un archivo aparte.

Por qué:
- El backend ya no lee las tablas viejas. Las leen los scripts de `pruebas/` y los demos `.ps1` (del compañero), y casi todos también escriben o borran en ellas (`alertas_login.sh` hace `DELETE FROM alerta_fraude`, `casos_fraude_granja.cjs` hace `INSERT INTO anillo_fraude`). Sobre una vista eso falla igual, así que habría que reescribirlos de todos modos.
- `alerta_fraude` y `hallazgo_evento_fraude` no se pueden reconstruir como vista (la señal es una por tipo y clave, no una por ventana); solo se podrían hacer las de anillos, que son las más pequeñas (1 anillo y 2 reseñas en la base local).
- Sin vistas, al borrar, esos scripts fallan con un error claro de "no existe la tabla", que le dice al compañero qué actualizar.

Si se quisiera un período de transición (por ejemplo, para la sustentación), las únicas vistas viables serían `anillo_fraude` y `anillo_fraude_resena`, de solo lectura.

**Antes de empezar, revisar (ya resuelto, ver la tabla de etapas):**
- **Quién más lee las tablas viejas**: el backend (buscar `anillo_fraude`, `hallazgo_evento_fraude`, `alerta_fraude`), `pruebas/` (el compañero), los ETL (`etl/`, `clickhouse/`) y `docs/`.
- **Los ids de catálogo fijos** en `models/alerta-fraude.ts`, `models/anillo-fraude.ts` y `models/hallazgo-evento-fraude.ts`: los `ID_TIPO_*` apuntan a los catálogos viejos y los candados de las migraciones 016, 019 y 025 comprueban que coincidan. Decidir cuáles se siguen usando (los registros y los filtros de los admin usan nombres de tipo, no ids).
- **Las dos tablas viejas que quedan sin vista posible:** `alerta_fraude` tiene una fila por ventana y la señal una sola; una vista no puede reconstruir las ventanas. Decidir si la vista de `alerta_fraude` y la de `hallazgo_evento_fraude` se hacen igual (una fila por señal) o se omiten.
- **Migración real:** la sube el compañero (fuera de `backend/`). Las tres piezas de SQL de referencia que hay que convertir en migraciones, en orden: `refactor-fraude-senales.sql` (etapas 1 a 5), `refactor-fraude-senales-etapa7.sql` (etapa 7) y las de la etapa 8.

**Pendiente fuera de `backend/` (del compañero):**
- Migración real de las tres piezas de SQL: `refactor-fraude-senales.sql`, `refactor-fraude-senales-etapa7.sql` y `refactor-fraude-senales-etapa8.sql` (en ese orden; la 8 se detiene con un error si queda una evidencia o notificación sin señal, y no tiene vuelta atrás).
- `refactor-fraude-senales-etapa8-borrado.sql` (borra las tablas viejas, sin vuelta atrás): no está aplicado ni en local; decidir con el equipo cuándo, y antes actualizar los scripts de `pruebas/` y los demos `.ps1` que leen o escriben en ellas.
- `clickhouse/consultas/` F2, F3 y F5: agregar la columna `ids_pedidos` (ver "Etapa 5").
- `pruebas/casos_fraude_fusion.cjs` y `pruebas/casos_fraude_granja.cjs`: pasan ids de las tablas viejas como `idOrigen` y leen `anillo_fraude`; hay que actualizarlas para que siembren señales.
- `docs/base-de-datos.md`.

## Etapa 6: lo que hay que crear (del compañero, ClickHouse)

Estado (2026-09-30): **nada construido.** Para poder agregarla del lado del backend, primero hacen falta estas dos tablas en ClickHouse, que lleva el compañero (`clickhouse/` está fuera de `backend/`). Es un archivo nuevo, `clickhouse/002_detecciones.sql`, **idempotente** (`IF NOT EXISTS`) y con el mismo estilo que `001_esquema.sql` (cada tabla dice cuál es su pregunta antes de sus columnas; `arrancar.ps1` lo correría en cada arranque). Lo de abajo es una **propuesta de referencia**, no un archivo aplicado.

**Qué guarda.** Cada vez que un detector ve una señal, una fila. `senal_fraude` (PostgreSQL) sigue siendo UNA por (tipo, clave) y solo guarda `total_detecciones` ("veces vista") y `ultima_deteccion`; la historia de cuándo y con cuánta evidencia se vio cada vez solo puede vivir en una tabla de eventos.

```sql
-- Pregunta: "que le paso a ESTA senal a lo largo del tiempo".
CREATE TABLE IF NOT EXISTS deteccion_fraude
(
    fecha             DateTime64(3),
    id_senal_fraude   UInt64,
    tipo              LowCardinality(String),   -- tipo_senal_fraude_nombre
    familia           LowCardinality(String),   -- anillo_resenas, patron_resenas, compras_navegacion, login
    clave             String,
    metrica           Nullable(Float64),        -- la metrica principal de la deteccion (ver METRICA_PRINCIPAL en los helpers); NULL si el tipo no tiene (toma_cuenta, anillos)
    reabrio           UInt8                     -- 1 si esta deteccion reabrio una senal revisada o descartada
)
ENGINE = MergeTree
ORDER BY (id_senal_fraude, fecha);

-- Pregunta: "cuantas detecciones y cuantas senales distintas hubo por dia y por tipo".
CREATE TABLE IF NOT EXISTS deteccion_fraude_por_dia
(
    dia          Date,
    tipo         LowCardinality(String),
    detecciones  UInt64,
    senales      AggregateFunction(uniq, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (dia, tipo);

CREATE MATERIALIZED VIEW IF NOT EXISTS deteccion_fraude_por_dia_mv
TO deteccion_fraude_por_dia AS
SELECT toDate(fecha) AS dia, tipo,
       count() AS detecciones,
       uniqState(id_senal_fraude) AS senales
  FROM deteccion_fraude
 GROUP BY dia, tipo;
```

**Lo que hace el backend cuando las tablas existan** (pendiente, pequeño y en un solo lugar por helper):
- Insertar en `deteccion_fraude` desde `registrarSenalDelAnillo`, `registrarSenalDelHallazgo` y `registrarSenalDeLaAlerta`, **después del `COMMIT`** (nunca dentro de la transacción de PostgreSQL), con `async_insert`.
- **Un fallo de ClickHouse nunca debe romper el registro de la señal:** se captura, se deja en el log y se sigue.
- Los helpers de eventos y de login ya calculan si la detección reabrió la señal y su métrica principal; solo falta devolverlos para insertarlos.
- Los anillos no reabren ni tienen métrica principal: van con `reabrio = 0` y `metrica` NULL.

**Cómo probarlo cuando exista:** crear una señal de prueba con dos detecciones, comprobar que `deteccion_fraude` tiene 2 filas y `deteccion_fraude_por_dia` una con `detecciones = 2` y `uniqMerge(senales) = 1`; con ClickHouse apagado, comprobar que la señal se sigue registrando en PostgreSQL.

## Prueba de punta a punta del backend final (2026-09-30)

Con el backend arrancado de verdad (`nest start`) y las tablas viejas ya sin escrituras:

- **Login (intentos reales, IP de prueba por `X-Forwarded-For`): 27 de 27.** `fuerza_bruta_cuenta`, `fuerza_bruta_ip` y `multi_cuenta_ip` nacen como señal con sus víctimas, su IP enlazada y una notificación por cuenta; las tablas viejas no cambian; la víctima ve sus alertas (sin los identificadores de las otras cuentas), las marca leídas (idempotente) y otra cuenta recibe `404`; el admin las ve con el estado de lectura por cuenta, las descarta (`409` si se repite, `404` si no existe). Reabrir: los mismos 4 intentos no reabren la descartada; una cuenta nueva sí, avisa a la cuenta nueva y deja las otras sin leer.
- **Anillos (`pruebas/anillos.sh`, checkout y reseñas reales): 24 OK y 3 FALLA, las 3 por el script.** El detector guardó el ciclo a los 2 s, la cuenta de control quedó fuera y el detalle salió de Neo4j. Las 3 fallas leen `anillo_fraude_resena` y `anillo_fraude` por el id que devuelve la API, que ahora es el de la señal; las comprobaciones equivalentes sobre `senal_fraude` cumplen (3 reseñas, estado `revisada`). El script debe leer `senal_fraude`/`senal_fraude_resena` (del compañero).
- **F1 a F6 (eventos sembrados en ClickHouse, luego borrados): las 6 señales nacen** con sus cuentas, productos, pedidos e IP (F3 enlaza solo los pedidos que existen; F6 con sus 5 cuentas y su IP). `alertas-eventos`: listado, filtro por tipo, `PATCH` (`409` al repetir), id de otra familia por la ruta equivocada `404`, tipo inválido `400`: 12 de 12.
- **Agrupador:** arrancó con el código final y en cada corrida agrupó las señales nuevas; al borrar las de prueba, su caso sin evidencia se borró solo.
- **Efecto que queda:** `anillos.sh` no es reversible y sus cuentas (`anit*`) entraron por `127.0.0.1` a `multi_cuenta_ip`, así que el caso 13 ya existente quedó con 8 evidencias y 107.90 puntos (antes 38.82 y 11 cuentas). Se revierte borrando esas cuentas y sus señales.
- **Sin probar:** una segunda corrida del detector de F1 a F6 sobre la misma evidencia (el conteo de detecciones y la regla de reabrir se probaron por separado en los helpers) y la etapa 6.

## Decisiones cerradas

- Productos: el pivote es por PRODUCTO y no por variante (las reseñas y las señales F1 a F6 son de producto). Una señal futura de precio usaría un pivote aparte de oferta.
- El rol vive en el pivote de cuentas, no en la señal.
- Las tablas viejas se apagan al final, nunca antes de que el agrupador lea solo `senal_fraude`.

## Pendiente de decidir

- Etapa 4: cómo pasan a la señal las alertas de login que hoy tienen una ventana por minuto (`ventana_inicio`). La propuesta: la señal es única por (tipo, clave) y cada ventana pasa a ser una detección.
- Qué parte de este documento (la migración 029) sube el compañero y cuándo.

## Al compañero (fuera de `backend/`)

Nada de esto se aplicó en `migrations/`. Le toca:
- La migración real de la etapa 1 a partir de `refactor-fraude-senales.sql`.
- Si se quiere la etapa 6: `clickhouse/002_detecciones.sql` con las dos tablas y la vista materializada de "Etapa 6: lo que hay que crear". Sin eso, el backend no puede agregar el historial. Y `docs/base-de-datos.md`.
