# Preguntas y respuestas para la sustentación

Mesh, backend y bases de datos. Proyecto de Bases de Datos 2.

Este archivo reúne 138 preguntas que el profesor puede hacer sobre el backend y las bases de datos de Mesh. Cada respuesta es corta y trae tres cosas. Dónde se ve, con el archivo y las líneas exactas. Lo que pide el profesor, según el enunciado y su rúbrica. Y por qué se hizo así.

Las líneas son las del código en main al 20 de septiembre de 2026, salvo las preguntas 32 a 34 y la 119, que están al 23 de septiembre. Si el código cambia después, los números se pueden correr unas líneas, pero el nombre del archivo sigue sirviendo para encontrar el sitio.

## Lo que pide el profesor, en corto

- Fase inicial. Modelo relacional normalizado hasta tercera forma normal, diagrama entidad relación, compra como transacción atómica y datos de prueba en el repositorio.
- Entrega 1, 5 puntos. Catálogo en base documental con la decisión de embeber o referenciar, un índice compuesto, una agregación, historial de cambios como eventos y consulta del estado en una fecha.
- Entrega 2, 10 puntos. Carrito con expiración en clave valor, oferta limitada con operaciones atómicas bajo concurrencia, comparación de grafos contra columnar y una de las dos implementada.
- Entrega 3, 15 puntos. Buscador con mapping propio, autocompletado o corrección ortográfica, filtros facetados, estrategia de consistencia del checkout y una prueba de falla simulada.
- Entrega final, 20 puntos. Recomendación semántica con vectores, control de acceso en un componente NoSQL, diagrama final, retrospectiva y presentación.

## Índice

- [Parte 1. Modelo relacional y checkout en PostgreSQL](#parte-1-modelo-relacional-y-checkout-en-postgresql), preguntas 1 a 16
- [Parte 2. Catálogo documental en MongoDB](#parte-2-catálogo-documental-en-mongodb), preguntas 17 a 31
- [Parte 3. Carrito y oferta limitada en Redis](#parte-3-carrito-y-oferta-limitada-en-redis), preguntas 32 a 49
- [Parte 4. Grafo de reseñas en Neo4j y tendencias en ClickHouse](#parte-4-grafo-de-reseñas-en-neo4j-y-tendencias-en-clickhouse), preguntas 50 a 65
- [Parte 5. Buscador en Elasticsearch y consistencia del checkout](#parte-5-buscador-en-elasticsearch-y-consistencia-del-checkout), preguntas 66 a 82
- [Parte 6. Fraude de login y de IP](#parte-6-fraude-de-login-y-de-ip), preguntas 83 a 101
- [Parte 7. Arquitectura, seguridad y entrega final](#parte-7-arquitectura-seguridad-y-entrega-final), preguntas 102 a 115
- [Parte 8. Entrega final, lo que hoy hay en el repositorio](#parte-8-entrega-final-lo-que-hoy-hay-en-el-repositorio), preguntas 116 a 131
- [Parte 9. Lo que cambió el 16 y 17 de octubre](#parte-9-lo-que-cambió-el-16-y-17-de-octubre), preguntas 132 a 138

---

## Parte 1. Modelo relacional y checkout en PostgreSQL

*Fase inicial.*

Archivos que más se usan en esta parte.

- `migrations/006_pedidos.sql`
- `docs/base-de-datos.md`
- `migrations/README.md`
- `migrations/005_ofertas.sql`
- `migrations/007_flujo_pedido.sql`
- `docs/CONSISTENCIA-CHECKOUT.md`

### 1. ¿Por qué el esquema está normalizado y cómo se ve en el repositorio?
El modelo está en tercera forma normal. Cada hecho vive en un solo lugar y lo que se puede calcular no se guarda. Por eso `pedido` no tiene total, porque se suma de sus líneas. Los estados y los roles son tablas de catálogo aparte.
El esquema se reparte en 19 archivos numerados, uno por tema, y el número marca el orden porque una tabla no puede referenciar otra que aún no existe.

- Dónde se ve. `migrations/README.md` lineas 20 a 33 explican el nombre numerado y el orden, y lineas 69 a 89 dan una línea por archivo. `migrations/006_pedidos.sql` lineas 107 a 108 explican por qué no hay total. `docs/base-de-datos.md` lineas 1255 a 1259 lo justifican con 3FN.
- Lo que pide el profesor. Fase inicial, modelo relacional en al menos tercera forma normal con usuarios, direcciones, categorías, productos, pedidos, líneas, pagos e inventario, más el diagrama y la justificación breve de normalización. Se evalúa en la Entrega 1, diseño y normalización 0.5 pts.
- Por qué así. Un dato derivado guardado se puede desincronizar y nadie se entera. Calcularlo cuando se necesita evita esa segunda verdad.

### 2. ¿Por qué la compra es una transacción atómica y dónde están el BEGIN, el COMMIT y el ROLLBACK?
La compra corre dentro de una sola función de PostgreSQL, `comprar_carrito()`. Esa función crea el pedido, mete las líneas, descuenta el stock, escribe el kardex y registra el pago. Si algo falla al final, se deshace todo lo anterior y no queda ni un pedido a medias. El cuerpo de una función ya es una transacción, por eso no lleva BEGIN escrito. En el camino de un pedido ya armado, el backend sí abre BEGIN, hace COMMIT y en el error hace ROLLBACK.

- Dónde se ve. `migrations/012_comprar_carrito.sql` lineas 84 a 139 es la función y lineas 24 a 33 explican la atomicidad. `backend/src/services/carrito/carrito.service.ts` lineas 562 a 573 la llaman con un solo `SELECT`. `backend/src/services/compradores/pedidos.service.ts` lineas 636 a 656 tienen BEGIN y COMMIT, y lineas 668 a 679 el ROLLBACK y el `release` de la conexión.
- Lo que pide el profesor. Fase inicial, flujo de compra como transacción atómica que registra pedido, líneas, pago y descuento de inventario. Entrega 3, documento de estrategia de consistencia del checkout, 5 pts.
- Por qué así. Meter todo en la base evita que una ruta nueva se olvide de abrir la transacción. `comprar_carrito()` reutiliza `crear_pedido`, `agregar_linea` y `comprar_pedido` en vez de copiarlas, para que no existan dos versiones de las reglas.

### 3. ¿Cómo se descuenta el inventario y cómo se evita vender dos veces la última unidad?
`comprar_pedido()` recorre las líneas ordenadas por oferta y bloquea cada fila de `oferta` con `FOR UPDATE`. Si hay stock, escribe un movimiento en el kardex y resta la cantidad. La segunda compra de la misma oferta espera y lee el saldo ya descontado. Además el stock tiene un `CHECK` que impide números negativos.

- Dónde se ve. `migrations/007_flujo_pedido.sql` lineas 459 a 474 tienen el orden fijo y el bloqueo, y lineas 481 a 497 revisan el stock, escriben el kardex y restan. `migrations/006_pedidos.sql` lineas 236 a 259 definen el kardex `stock_movimiento`. `migrations/005_ofertas.sql` linea 100 tiene el `CHECK` de stock. `docs/base-de-datos.md` lineas 374 a 399 traen la prueba con dos compras a la vez.
- Lo que pide el profesor. Fase inicial, descuento de inventario dentro de la transacción. Es el mismo problema de sobreventa que la Entrega 2 resuelve con Redis para la oferta limitada, que vale 3 pts.
- Por qué así. Sin el bloqueo las dos compras leen queda 1 y las dos venden. El orden fijo por oferta evita que dos compras se traben esperándose entre sí.

### 4. ¿Cómo se guardan pedidos, líneas y pagos, y qué pasa con el precio de la línea?
`pedido` es la cabecera con usuario, dirección y estado. `pedido_producto` son las líneas y `pago` es uno por pedido. La línea no copia el precio ni el vendedor, guarda un solo puntero a `precio_historial`. De ahí salen el precio cobrado, la oferta y quien vendió.

- Dónde se ve. `migrations/006_pedidos.sql` lineas 113 a 125 son el pedido, lineas 138 a 159 las líneas y lineas 200 a 217 el pago. Las lineas 18 a 31 explican el puntero y por qué todas las llaves van con `ON DELETE RESTRICT`.
- Lo que pide el profesor. Fase inicial, pedidos con sus líneas y pagos en el modelo normalizado. Tabla del alcance, pedidos y pagos se mantienen en el modelo relacional desde el inicio.
- Por qué así. Cada fila de `precio_historial` no se actualiza nunca, así que el precio queda congelado igual que si se copiara. Lo que sí se copia son los nombres, porque cambian y no se pueden deducir. Nada de esa cadena se borra, por eso se retira una oferta cambiando su estado.

### 5. ¿Cuáles son los estados del pedido y cómo fluye?
Son cinco, `pendiente`, `comprado`, `enviado`, `entregado` y `cancelado`. Un pedido nace `pendiente`, `comprar_pedido()` lo pasa a `comprado` y `cancelar_pedido()` a `cancelado`. Al cancelar uno comprado se devuelve el stock con un movimiento de devolución y el pago pasa a reembolsado. Hoy `enviado` y `entregado` existen en el catálogo, pero ningún código del repositorio mueve un pedido a esos estados.

- Dónde se ve. `migrations/006_pedidos.sql` lineas 279 a 284 tienen los cinco estados. `migrations/007_flujo_pedido.sql` lineas 70 a 76 crean el pedido pendiente, lineas 524 a 526 lo pasan a comprado, y lineas 585 a 630 cancelan y devuelven stock. Lineas 513 a 522 registran el pago como pagado de una vez.
- Lo que pide el profesor. Fase inicial, flujo de compra atómico. El estado del pedido y el del pago son columnas distintas, cada una con su catálogo.
- Por qué así. Se llama comprado y no pagado porque un pedido contra entrega está comprado y aún no pagado. Registrar todo pago como pagado es una simplificación que el equipo dejó escrita en el comentario de la función.

### 6. ¿Por qué pedidos y pagos se quedaron en PostgreSQL en vez de migrarlos?
Porque el dinero y el stock necesitan una transacción atómica con bloqueo de filas, y eso lo da PostgreSQL. En una base documental habría que sostener copias en dos sitios y no habría una transacción que abarque todo. La postura del proyecto es que el dinero y el stock son transaccionales y lo demás puede ser eventual.

- Dónde se ve. `docs/base-de-datos.md` lineas 571 a 579 es el ADR-2, la decisión de no migrar las ofertas, con el mismo criterio de consistencia. `docs/CONSISTENCIA-CHECKOUT.md` lineas 29 a 31 dicen la postura. `docs/ARQUITECTURA.md` linea 136 lista qué vive en PostgreSQL.
- Lo que pide el profesor. Sección 5.5, mantener un componente relacional se evalúa con la misma exigencia que migrarlo. Entrega 3 menciona de forma opcional evaluar un motor NewSQL para pagos. Ese análisis NewSQL no está escrito en el repositorio todavía.
- Por qué así. Consistencia manda sobre lo demás. Mongo reescribe el documento entero en cada cambio, y comprar una camisa reescribiría todo su catálogo.

### 7. ¿Qué es el outbox hacia el grafo y cómo funciona su worker?
Es una cola en PostgreSQL llamada `evento_grafo`. Un trigger sobre `resena` escribe un evento en la misma transacción que la reseña. Un worker del backend corre cada 10 segundos, toma cada evento con `FOR UPDATE SKIP LOCKED` y lo proyecta a Neo4j con `MERGE`. Si el evento falla 5 veces queda apartado.

- Dónde se ve. `migrations/015_outbox_grafo.sql` lineas 95 a 102 crean la tabla, lineas 143 a 179 el trigger, y lineas 135 a 137 el índice parcial de pendientes. `backend/src/services/grafo/grafo-sync.service.ts` lineas 85 a 96 son el `@Interval` y lineas 183 a 232 toman, procesan y cuentan intentos. `backend/src/app.module.ts` lineas 78 a 79 activan el planificador.
- Lo que pide el profesor. Entrega 3, estrategia de consistencia con una ventana de consistencia eventual aceptada y documentada. La cabecera de la 015 lo dice en las lineas 39 a 43.
- Por qué así. Si el backend escribiera a Neo4j después del COMMIT y el proceso se cayera en medio, la reseña existiría sin rastro de que falta en el grafo. Con el outbox entran las dos cosas o ninguna.

### 8. ¿Cómo se comprueba que el grafo está al día con PostgreSQL?
Con la conciliación. El endpoint `GET /admin/grafo/conciliacion` cuenta reseñas y relaciones en las dos bases y compara. Devuelve si cuadra, qué falta y qué eventos quedaron apartados. Solo avisa, no repara. Para reparar hay que correr el ETL del grafo con la opción de limpiar.

- Dónde se ve. `backend/src/controllers/grafo/grafo.controller.ts` lineas 29 a 31 es la ruta, solo para admin. `backend/src/services/grafo/grafo-sync.service.ts` lineas 343 a 369 comparan los conteos y calculan el veredicto. `docs/CONSISTENCIA-CHECKOUT.md` lineas 273 a 275 lo explican.
- Lo que pide el profesor. Entrega 3, documento de estrategia de consistencia, 5 pts, con los puntos de falla y su mitigación.
- Por qué así. Un panel de fraude que muestra datos viejos sin avisar engaña. Medir la deriva evita afirmar que está al día sin comprobarlo.

### 9. ¿Cómo se garantiza que solo puede reseñar quien compró?
La regla la aplica el backend antes de insertar. Busca un pedido del usuario, con pago pagado, no cancelado, con una línea de ese producto cuya oferta es del vendedor calificado. Si no existe responde 409. La tabla además impide reseñarse a sí mismo y repetir la reseña del mismo comprador, vendedor y producto.

- Dónde se ve. `backend/src/services/resenas/resenas.service.ts` lineas 560 a 594 es `exigirCompraPagada`, y la línea 297 la llama. `migrations/011_resenas.sql` lineas 208 a 219 tienen el `UNIQUE` y el `CHECK`. `migrations/datos/001_catalogo.sql` lineas 4754 a 4773 revisan que toda reseña sembrada tenga su compra.
- Lo que pide el profesor. No aparece como requisito literal del enunciado. Es una regla del equipo que respalda la detección de reseñas manipuladas de la Entrega 2.
- Por qué así. La base no puede exigirlo con una llave foránea, porque hay que cruzar `pedido_producto`, `precio_historial` y `oferta`. Por eso la regla vive en el backend y la semilla la vigila aparte.

### 10. ¿Cómo se modelan usuarios y direcciones?
`usuarios` guarda cuenta, contraseña con hash y llaves a rol y estado. Los roles son comprador, vendedor y admin. `direcciones` es la versión vigente de cada dirección y `direccion_historial` guarda cada versión anterior, que solo se inserta. El pedido apunta al historial, no a la dirección viva.

- Dónde se ve. `migrations/001_usuarios.sql` lineas 33 a 54 es la tabla y lineas 106 a 110 los tres roles. `migrations/002_direcciones.sql` lineas 26 a 48 son las direcciones y lineas 65 a 83 el historial.
- Lo que pide el profesor. Fase inicial, usuarios y direcciones, y registro con roles de comprador, vendedor y administrador.
- Por qué así. Si el usuario edita su dirección meses después, el pedido debe seguir diciendo a dónde se envió de verdad.

### 11. ¿Cómo se modelan categorías y productos en el relacional?
`categorias` es un árbol de exactamente dos niveles, raíz y hoja, y un trigger impide un tercer nivel. Los productos solo cuelgan de una hoja, y otro trigger lo exige. Cada producto tiene variantes, que son lo que realmente se compra. Precio y stock no están aquí, viven en `oferta`.

- Dónde se ve. `migrations/003_productos.sql` lineas 82 a 109 son las categorías con sus índices únicos, lineas 113 a 151 el trigger de dos niveles, lineas 165 a 181 los productos y lineas 222 a 243 las variantes.
- Lo que pide el profesor. Fase inicial, categorías y productos en el modelo relacional. Desde la Entrega 1 el catálogo se lee desde MongoDB, y las tablas siguen como punto de partida y origen del ETL.
- Por qué así. Un `CHECK` no puede mirar otra fila, por eso las reglas del árbol las aplican triggers. El catálogo es compartido y varios vendedores ofertan la misma variante.

### 12. ¿Por qué `id_producto_mongo` no es una llave foránea?
Porque el producto ahora vive en MongoDB y PostgreSQL no puede garantizar integridad referencial contra otra base. Las líneas de pedido, las ofertas y las reseñas guardan el id del catálogo como número suelto. El sufijo `_mongo` avisa a quien lea la tabla que no debe buscar una llave foránea.

- Dónde se ve. `migrations/006_pedidos.sql` lineas 37 a 40 lo explican y lineas 149 a 151 tienen las dos columnas de la línea. `migrations/005_ofertas.sql` lineas 74 a 91 hacen lo mismo en `oferta`. `docs/base-de-datos.md` línea 569 lo lista como consecuencia de la migración.
- Lo que pide el profesor. Entrega 1, documentar cómo las líneas de pedido referencian productos que ahora están en otro componente, sin exigir integridad referencial garantizada.
- Por qué así. Es el precio de mover el catálogo. El enlace lo sostiene la aplicación y se acepta a propósito.

### 13. ¿Qué índices hay en el modelo relacional y por qué esos?
Cada índice responde a una consulta concreta que está escrita en su comentario. Por ejemplo, los pedidos de un cliente del más nuevo al más viejo, el libro de una oferta para reconstruir el stock, o las ofertas de una variante de la más barata a la más cara. Algunos son parciales, como la cola del outbox, que solo indexa lo pendiente.

- Dónde se ve. `migrations/006_pedidos.sql` línea 130 y lineas 168 a 170 y lineas 266 a 269. `migrations/005_ofertas.sql` lineas 141 a 142. `migrations/015_outbox_grafo.sql` lineas 130 a 137 para el parcial.
- Lo que pide el profesor. Fase inicial, esquema en DDL. La Entrega 1 pide un índice compuesto, pero sobre el catálogo en MongoDB. Los de PostgreSQL son parte del diseño de la base.
- Por qué así. Un índice parcial mantiene el tamaño de lo que se consulta y no del histórico entero. Un índice compuesto también sirve por su prefijo.

### 14. ¿Cómo se cargan los datos de prueba y por qué se pueden confiar?
Los escribe un generador, `migrations/datos/generador.js`, con una semilla fija, así que da siempre el mismo archivo. El conjunto trae 102 productos, 202 variantes, 556 ofertas, 11 usuarios, 90 reseñas y 13 pedidos con 101 líneas. El archivo va dentro de un BEGIN y un COMMIT y termina con 11 verificaciones que hacen fallar la carga si algo no cuadra.

- Dónde se ve. `migrations/datos/generador.js` lineas 8 a 14 explican que es determinista. `migrations/datos/001_catalogo.sql` línea 33 abre con BEGIN, lineas 4592 a 4845 son las verificaciones y línea 4847 hace COMMIT. `migrations/README.md` lineas 251 a 261 traen los conteos.
- Lo que pide el profesor. Fase inicial, un conjunto de datos de prueba suficientemente representativo para sustentar las consultas de las entregas posteriores.
- Por qué así. Datos con semilla fija permiten comparar dos bases. Las verificaciones revisan, por ejemplo, que el stock de cada oferta sea la suma de su kardex.

### 15. ¿Las migraciones son idempotentes y cómo las corre `arrancar.ps1`?
El esquema se puede correr en cada arranque. Desde la 007 en adelante son `CREATE OR REPLACE` o `IF NOT EXISTS`. Las primeras, de la 001 a la 006, fallan con already exists en una base ya migrada y el script lo toma como ya aplicada. Los datos no son idempotentes, por eso solo entran si la base no tiene productos.

- Dónde se ve. `arrancar.ps1` lineas 1715 a 1737 es `Correr-Migraciones`, con `ON_ERROR_STOP` y el perdón solo cuando la línea del ERROR dice already exists. Lineas 1739 a 1740 corren el esquema y lineas 1775 a 1786 la guardia de datos. `migrations/README.md` lineas 39 a 52 lo explican.
- Lo que pide el profesor. Sección 5.4, archivo de documentación con las instrucciones para poner el sistema en funcionamiento, y Fase inicial, repositorio con el DDL.
- Por qué así. Cualquier otro error corta el arranque con salida 1, para que una migración rota no quede disfrazada de ya aplicada. Los datos no tienen guardia en 17 de sus inserts, y eso aún no se arregló.

### 16. ¿Cómo se generó el diagrama entidad-relación y por qué no está dibujado a mano?
Lo genera el script `docs/generar-er.py`, que lee la base viva. Consulta `information_schema` y `pg_constraint` dentro del contenedor y dibuja una caja por tabla y una línea por llave foránea. Hoy tiene las 50 tablas. Al final comprueba que ninguna tabla ni llave quede sin dibujo, y si algo no cuadra sale con error.

- Dónde se ve. `docs/generar-er.py` lineas 2 a 19 explican el método, lineas 55 a 77 hacen las consultas y lineas 372 a 405 la comprobación final. El resultado editable es `docs/diagrama-general.drawio`. `docs/base-de-datos.md` lineas 38 a 46 lo cuentan.
- Lo que pide el profesor. Fase inicial, diagrama entidad-relación con la justificación de normalización. Cada entrega que agrega componentes pide actualizar el diagrama de arquitectura, que es otro dibujo aparte.
- Por qué así. El diagrama anterior, dibujado a mano, se quedó en 42 cajas cuando la base ya tenía 50. Generarlo desde la base evita que envejezca sin avisar.


---

## Parte 2. Catálogo documental en MongoDB

*Entrega 1.*

Archivos que más se usan en esta parte.

- `docs/base-de-datos.md`
- `backend/src/services/productos/productos.service.ts`
- `mongo/001_productos.js`
- `etl/cargar.js`
- `mongo/002_resenas.js`
- `etl/README.md`

### 17. ¿Por qué el catálogo de productos está en MongoDB y no en PostgreSQL?
Cada categoría tiene atributos distintos, los de una laptop no se parecen a los de una camisa. Medimos que ningún producto llena todo lo que su categoría ofrece y el promedio es 59%, así que columnas fijas quedarían casi vacías. En Mongo cada producto lleva un arreglo de características con nombre, valor y unidad, y se filtra por ellas sin cambiar el esquema.

- Dónde se ve. `docs/base-de-datos.md` lineas 561 a 569, la decisión ADR-1 con contexto, alternativas y consecuencias. `backend/src/models/categoria.ts` lineas 13 a 42, la paleta de características que ofrece cada categoría. `backend/src/services/productos/productos.service.ts` lineas 972 a 987, el filtro por característica con elemMatch.
- Lo que pide el profesor. Entrega 1, diagnóstico del problema y justificación de la migración a un modelo documental, 0.75 pts. También pide que cada categoría muestre solo sus atributos relevantes.
- Por qué así. Entidad atributo valor en Postgres necesita un JOIN por cada atributo consultado. Se descartó jsonb en Postgres porque el enunciado pide ejercitar una base documental, con sus índices y su agregación.

### 18. ¿Cómo se migró el catálogo de Postgres a Mongo y por qué se puede repetir sin duplicar?
Es un ETL en la carpeta `etl`. `extraer.sql` arma el JSON de cada producto dentro de Postgres, la salida entra directo al contenedor de Mongo y `cargar.js` la escribe con mongosh. El `_id` del documento es el `id_producto` de Postgres y el de cada evento junta el id y el número, y se escribe con replaceOne y upsert. Por eso correrlo dos veces actualiza y no duplica.

- Dónde se ve. `etl/correr.sh` lineas 69 a 84, los pasos de extraer, pasar y cargar. `etl/cargar.js` lineas 503 a 508, replaceOne con upsert. `etl/README.md` lineas 549 a 553. `mongo/001_productos.js` lineas 74 a 87, crea las colecciones solo si no existen. En Windows lo hace la función Correr-Etl de `arrancar.ps1` linea 1021.
- Lo que pide el profesor. Entrega 1, migración de la entidad de productos con un proceso documentado y reproducible, y repositorio con el script de migración.
- Por qué así. Con id calculado el mismo documento cae siempre en el mismo lugar. No hay nada que instalar porque se usan el psql y el mongosh que ya vienen dentro de los contenedores.

### 19. ¿Qué decidieron embeber y qué referenciar entre reseñas, imágenes y vendedor?
Las imágenes van embebidas dentro de su variante. Las reseñas van referenciadas y se quedan en Postgres. Producto y vendedor van referenciados, porque la oferta con su precio, su stock y su vendedor se queda en Postgres y apunta al producto por id. Cada caso se decidió con frecuencia de acceso conjunto, volumen y tasa de cambio.

- Dónde se ve. `docs/base-de-datos.md` lineas 744 a 750, las tres respuestas juntas. Lineas 581 a 589, ADR-3 de imágenes. Lineas 571 a 579, ADR-2 de ofertas. Las lineas 544 a 547 explican el formato de decisión que pide el enunciado.
- Lo que pide el profesor. Entrega 1, decisión fundamentada por escrito para reseñas, imágenes y relación producto vendedor, apoyada en esos tres criterios, 1 pt.
- Por qué así. Mongo reescribe el documento entero en cada actualización. Solo conviene embeber lo que se lee junto, es pequeño y cambia lento.

### 20. ¿Por qué las reseñas no van dentro del documento del producto?
Porque su volumen no tiene techo y cada reseña nueva reescribiría el producto completo. La lista del catálogo nunca las usa y la ficha las pide paginadas de diez en diez. Además la reseña califica a un vendedor, que es una llave foránea a usuarios en Postgres. Dentro del producto solo viajan dos números, la nota promedio y el total.

- Dónde se ve. `docs/base-de-datos.md` lineas 683 a 734, el razonamiento criterio por criterio. `mongo/002_resenas.js` lineas 29 a 35, solo los dos números agregados van embebidos. `mongo/002_resenas.js` lineas 188 a 191, el índice para ordenar por nota.
- Lo que pide el profesor. Entrega 1, decisión de embeber o referenciar reseñas con frecuencia de acceso conjunto, volumen y tasa de cambio, dentro del punto de 1 pt.
- Por qué así. Variantes y características están acotadas por el modelo y por eso van embebidas. Las reseñas crecen mientras el producto se venda.

### 21. ¿Por qué el precio y el stock por vendedor no están en el documento del producto?
Porque cambian en cada venta. Copiarlos a Mongo obligaría a mantenerlos al día en dos bases, y embebidos harían que comprar una camisa reescriba todo su documento. Lo que sí viaja son cinco números calculados para pintar la tarjeta del catálogo, precio_tienda, precio_desde, stock_tienda, stock_total y total_ofertas. Son una copia y se recalculan después de cada cambio de oferta.

- Dónde se ve. `mongo/001_productos.js` lineas 24 a 38, la decisión escrita. `backend/src/services/productos/productos.service.ts` lineas 546 a 571, el recálculo, y lineas 705 a 722, el cierre que no deshace la venta si falla. `docs/base-de-datos.md` lineas 571 a 579, ADR-2.
- Lo que pide el profesor. Entrega 1, la relación producto vendedor con el criterio de tasa de cambio. El enunciado en el punto 5.5 evalúa igual de exigente una decisión de no migrar.
- Por qué así. El descuento de inventario tiene que ser atómico y eso lo sostiene un SELECT con FOR UPDATE en Postgres, medido sin sobreventas sobre 555 ofertas. Si el recálculo falla, la tarjeta muestra un número viejo un rato pero no se vende de más.

### 22. ¿Qué índices compuestos hay en Mongo y a qué consulta responde cada uno?
catalogo_categoria va sobre categoría, estado y _id, para navegar una categoría sin ocultos y ordenada por id. catalogo_precio va sobre estado y precio_desde, para el filtro por rango de precio. eventos_por_producto_fecha va sobre id_producto y fecha, para leer los eventos de un producto en orden. catalogo_rating añade la nota promedio para ordenar por mejor calificados.

- Dónde se ve. `mongo/001_productos.js` lineas 137 a 153 y lineas 167 a 170. `mongo/002_resenas.js` lineas 188 a 191. `mongo/demostracion_indices.js` lineas 1 a 22, mide cada consulta con explain y otra vez forzando a no usar índice, para comparar documentos examinados.
- Lo que pide el profesor. Entrega 1, al menos un índice compuesto que corresponda a un patrón de consulta del catálogo, dentro del punto de implementación funcional, 1 pt junto con la agregación.
- Por qué así. Primero van los campos de igualdad y al final el campo de orden, así el resultado sale ordenado del índice sin ordenar en memoria (lineas 115 a 117). Medido, catalogo_categoria examina 6 documentos contra 105 sin índice (lineas 103 a 110).

### 23. ¿Qué consulta usa el marco de agregación y cuáles son sus etapas?
La reconstrucción del producto por fecha. Sobre la colección de eventos hace match por producto y fecha, sort por número de evento, group que junta los eventos en un arreglo, y project con reduce y mergeObjects que los fusiona en orden. Todo lo hace Mongo y no se traen los eventos a Node. El listado paginado también usa aggregate con un facet, que trae la página y el conteo en la misma consulta.

- Dónde se ve. `backend/src/services/productos/productos.service.ts` lineas 338 a 373, el pipeline de reconstrucción, y lineas 160 a 172, el facet. `etl/reconstruir.js` lineas 43 a 66, la misma idea corrida desde mongosh.
- Lo que pide el profesor. Entrega 1, al menos una consulta que use el marco de agregación, dentro del punto de implementación funcional del catálogo, 1 pt.
- Por qué así. Cada modificación guarda solo lo que cambió, así que hay que aplicar todos los eventos en orden. mergeObjects deja el último valor de cada campo y conserva los que nadie volvió a tocar.

### 24. ¿Cómo modelaron el historial de cambios del producto como registro de eventos?
En la colección productos_eventos hay un documento por evento. El primero es la creación y lleva el producto completo en datos. Cada edición inserta un evento nuevo con el siguiente número y solo los campos que cambiaron en cambios. Nunca se actualiza ni se borra un evento que ya existe.

- Dónde se ve. `backend/src/services/vendedores/productos.service.ts` lineas 1052 a 1071, el evento de creación. Lineas 1304 a 1305, actualiza el producto y agrega el evento. Lineas 1342 a 1369, calcula el siguiente número e inserta. `backend/src/models/producto-evento.ts` lineas 11 a 46, la forma de los dos tipos de evento.
- Lo que pide el profesor. Entrega 1, historial mediante registro de eventos donde cada modificación se agrega como evento nuevo sin sobrescribir el estado anterior. Vale 1.25 pts junto con la consulta de reconstrucción.
- Por qué así. Un modelo que solo guarda el estado actual no puede decir cómo estaba el producto ayer. El `_id` del evento junta id y número, así que dos eventos del mismo producto no chocan.

### 25. ¿Cómo se consulta el estado de un producto en una fecha cualquiera?
Con la ruta de historial del producto y el parámetro fecha. El servicio toma el evento de creación y todas las modificaciones hasta ese momento y las fusiona en orden con la agregación. Acepta solo el día, que cuenta completo en hora de Guatemala, o día con hora, que llega hasta ese instante en UTC. Si no hay eventos responde que el producto no existía en esa fecha.

- Dónde se ve. `backend/src/controllers/productos/productos.controller.ts` lineas 54 a 69, la ruta `/productos/<id>/historial`. `backend/src/services/productos/productos.service.ts` lineas 319 a 392. `backend/src/helpers/momento-historial.ts` lineas 45 a 93, interpreta la fecha. `frontend/src/lib/PanelVendedor.svelte` linea 686, el panel que la llama.
- Lo que pide el profesor. Entrega 1, una consulta que reconstruya el estado vigente en una fecha arbitraria a partir de los eventos, y verla desde el panel administrativo. Vale 1.25 pts junto con el modelado de eventos.
- Por qué así. Quedarse solo con el último evento perdería los cambios anteriores que tocaron otros campos. Por eso se aplican todos, en orden.

### 26. ¿Se pueden reconstruir el precio y la disponibilidad desde Mongo?
No del todo, y está documentado. Mongo reconstruye nombre, descripción, categoría y estado del producto. El precio y las unidades disponibles viven por oferta en Postgres, y otra consulta los reconstruye con precio_historial y stock_movimiento. Las características siempre salen las de hoy, porque el relacional no las historiza.

- Dónde se ve. `backend/src/services/productos/productos.service.ts` lineas 394 a 415 y 444 a 448, la reconstrucción de oferta en Postgres. `docs/base-de-datos.md` lineas 824 a 841. `etl/cargar.js` lineas 20 a 33.
- Lo que pide el profesor. Entrega 1, reconstruir precio, descripción y disponibilidad en un punto anterior. En la base documental quedan la descripción y el estado, y el cambio de lugar del precio se explica en `docs/base-de-datos.md` lineas 832 a 836.
- Por qué así. Al volverse multivendedor un producto dejó de tener un precio, tiene tantos como vendedores y cada uno es de su oferta.

### 27. ¿Cómo referencian las líneas de pedido a productos que están en Mongo sin llave foránea?
La tabla pedido_producto guarda id_producto_mongo e id_producto_variante_mongo, sin FK porque Postgres no garantiza integridad contra otra base. El sufijo mongo avisa que ahí no hay llave foránea. Se guardan los dos ids porque la variante va embebida y su id solo es único junto con el del producto. Para mitigarlo, la línea copia los nombres de producto, variante y vendedor, el precio queda congelado con id_precio_historial, y la aplicación revisa en Mongo que el producto y la variante existan antes de crear la oferta o la línea.

- Dónde se ve. `migrations/006_pedidos.sql` lineas 149 a 158, los dos ids sin FK y los nombres copiados. `migrations/005_ofertas.sql` lineas 74 a 91, lo mismo en oferta. `backend/src/services/vendedores/ofertas.service.ts` lineas 265 a 300, valida producto y variante en Mongo antes del INSERT. `backend/src/services/compradores/pedidos.service.ts` lineas 242 a 262, lo mismo al agregar una línea.
- Lo que pide el profesor. Entrega 1, documentar el mecanismo por el cual las líneas de pedido referencian productos que ahora viven en otro componente, sin exigir integridad referencial garantizada.
- Por qué así. La integridad la sostiene la aplicación y no la base. Además el controlador de productos del vendedor no tiene ruta de borrado, solo se pone el producto inactivo, así que el id no queda colgado. Decisión completa en `docs/base-de-datos.md` lineas 632 a 640.

### 28. ¿Qué pasa si se cae MongoDB en mitad de un checkout?
La compra responde 503 con el mensaje de que no se pudo conectar con MongoDB y no queda nada a medias. Mongo no participa del COMMIT, pero las dos rutas de compra lo leen antes para traer el nombre del producto y el estado de la variante. Falla en unos 5 segundos porque se bajó el timeout del driver de 30 a 3 segundos. Cómo manejar esa dependencia de disponibilidad sigue por decidir con el profesor.

- Dónde se ve. `backend/elementos Generales/prueba-falla-mongo-checkout.md` lineas 14 a 34 la dependencia, lineas 69 a 84 el resultado con el ajuste, lineas 103 a 124 lo pendiente. `backend/src/database/mongo.ts` lineas 30 a 33. `backend/src/services/carrito/carrito.service.ts` lineas 975 a 998, la lectura a Mongo. `backend/src/helpers/manejar-error-mongo.ts` lineas 11 a 25, lo convierte en 503. `pruebas/falla_checkout.sh` lineas 746 a 750, el escenario de Mongo parado. `docs/CONSISTENCIA-CHECKOUT.md` lineas 298 a 339.
- Lo que pide el profesor. Entrega 3, evidencia de la prueba de falla simulada y su manejo, 4 pts, y el documento de estrategia de consistencia del checkout, 5 pts.
- Por qué así. Es una dependencia de disponibilidad y no de consistencia. La venta sigue siendo atómica en Postgres y pedido, pago y stock quedan iguales antes y después.

### 29. ¿Las ofertas están en Mongo? ¿Qué es ofertas_mongo.sql?
No, las ofertas viven solo en la tabla oferta de Postgres. El archivo `ofertas_mongo.sql` se llama así porque da precio y stock a los productos que nacieron solo en Mongo, generados por `mongo/lote/generar_lote_mongo.js`. Las ofertas de un vendedor se crean con un INSERT en Postgres, después de comprobar en Mongo que el producto y la variante existen.

- Dónde se ve. `migrations/lote/ofertas_mongo.sql` lineas 1 a 16, por qué no pueden vivir en Mongo, y lineas 43 a 52, lo que el archivo no hace. `backend/src/services/vendedores/ofertas.service.ts` lineas 243 a 311, crear una oferta.
- Lo que pide el profesor. Entrega 1, la decisión sobre la relación producto vendedor, y el punto 5.5 pide defender igual de bien una decisión de no migrar.
- Por qué así. Sostener precio y stock en dos bases duplica el riesgo de inconsistencia, y la atomicidad del descuento de stock se logra con FOR UPDATE en Postgres.

### 30. ¿Hay validación de esquema en Mongo?
No hay validador de esquema en las colecciones, no existe ningún jsonSchema en `mongo`, `etl` ni `backend/src`. Las reglas las aplica el backend antes de escribir. Valida nombre, estado y cada característica contra la paleta de la categoría, que vive en la colección categorias con su tipo de dato.

- Dónde se ve. `mongo/001_productos.js` lineas 127 a 132, dice que no hay validador sobre estado y que la lista vive en Postgres. `backend/src/helpers/validaciones-crear-producto.ts` lineas 56 a 73, 125 y 182, validan estado, tipo de valor y características.
- Lo que pide el profesor. El enunciado de la Entrega 1 no pide validación de esquema. Se dice con honestidad que no está implementada en la base y que la validación vive en la aplicación.
- Por qué así. La paleta de características cambia con los datos de cada categoría, así que se valida contra ella en el código y no con un esquema fijo.

### 31. ¿Qué pasa si se corre el ETL después de que alguien editó un producto desde el panel?
Ese producto no se reemplaza. El ETL nota que en Mongo hay un evento con número mayor que los que él arma, así que solo refresca los agregados y no toca ningún evento ajeno. Antes el replaceOne deshacía la edición y borraba su historial, y se corrigió el 2026-09-18. Los productos sin editar siguen derivándose enteros de Postgres.

- Dónde se ve. `etl/cargar.js` lineas 53 a 96, la regla explicada, y lineas 460 a 464, la comparación. `pruebas/etl_mongo.sh` lineas 20 a 33, lo que comprueba, incluido un caso mutante que la prueba debe atrapar.
- Lo que pide el profesor. Entrega 1, proceso de migración reproducible, y el historial que no se sobrescribe.
- Por qué así. El error se deja del lado de conservar de más y no de borrar, porque una edición hecha desde la aplicación no se puede recuperar. Ojo, `etl/README.md` lineas 555 a 559 todavía dice que el ETL es dueño único de esas colecciones, y eso ya no es cierto.


---

## Parte 3. Carrito y oferta limitada en Redis

*Entrega 2.*

Archivos que más se usan en esta parte.

- `backend/src/services/carrito/carrito.service.ts`
- `redis/inventario_limitado.lua`
- `redis/prueba_concurrencia.sh`
- `redis/README.md`
- `redis/carrito.lua`
- `pruebas/carrito.sh`

### 32. ¿Por qué el carrito está en Redis y en PostgreSQL?
Desde el 17 de octubre, porque el profesor pidió que Redis nunca sea la fuente de verdad. Cada cambio se escribe en Redis y se contesta al momento, y debajo, sin hacer esperar a nadie, se copia al pedido `pendiente` de la cuenta en PostgreSQL, que es la verdad. Hay uno solo por cuenta, nace con el primer producto y muere a las 24 horas sin tocarlo. Si Redis se cae, el carrito se lee y se compra directo contra PostgreSQL, más lento. Agregar al carrito sigue sin reservar stock, salvo en una venta relámpago.

- Dónde se ve. `migrations/045_carrito_en_postgres.sql`, las columnas `version` y `fecha_ultima_actividad` del pedido, el índice de un pendiente por cuenta y la tabla `reserva_venta_relampago`. `backend/src/services/carrito/carrito.service.ts` (la orquestación) y `carrito-postgres.service.ts` (la verdad). `pruebas/carrito.sh`, 42 OK, mide que lo escrito llega a PostgreSQL y que si Redis pierde el carrito vuelve desde ahí.
- Lo que pide el profesor. Entrega 2, carrito sobre un almacén clave-valor con expiración por inactividad (1.5 pts), y su directiva posterior de que Redis no sea la verdad.
- Por qué así. Redis contesta en microsegundos y se queda como la puerta rápida; PostgreSQL guarda lo que no se puede perder. Hasta el 17 de octubre el carrito vivía solo en Redis y un Redis vaciado se lo llevaba.
- Ojo si preguntan qué pasa si las dos copias no coinciden. Redis guarda la versión de PostgreSQL que conoce. Si la copia falla o choca, el carrito queda marcado como desincronizado, la pantalla lo dice con un botón para guardarlo (`POST /carrito/sincronizar`) y el checkout no cobra hasta que se arregle.

### 33. ¿Qué tipo de dato y qué estructura de claves usa el carrito?
Un hash por cuenta. El campo es el id de la oferta y el valor es la línea en JSON, una foto con la cantidad, el precio (ya con descuento), el porcentaje de descuento, el nombre, la imagen y el vendedor. Si la línea es de venta relámpago, hay un segundo campo con el ticket de la reserva. Desde el 17 de octubre lleva dos campos más: `_v`, la versión de PostgreSQL que conoce, y `_d`, la marca de desincronizado. Ver el carrito lee Redis; solo si Redis no lo tiene se reconstruye desde PostgreSQL. Al pagar, el backend compara la foto con el precio de hoy y avisa si cambió.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 83 a 107, la línea que se guarda (`LineaCarritoRedis`). Lineas 115 a 129, la forma del hash y por qué guarda una foto. Lineas 175 a 178, la clave `mesh:carrito:<id_usuario>`. Lineas 947 a 950, el campo `t:<id_oferta>` del ticket.
- Lo que pide el profesor. Entrega 2, carrito sobre almacén clave-valor, 1.5 pts.
- Por qué así. Con un hash cada línea se cambia sola sin leer y reescribir el carrito entero. La foto hace que ver el carrito no dependa de PostgreSQL ni de Mongo; el precio que puede quedar viejo se revisa al pagar.

### 34. ¿Cuál es el TTL del carrito y dónde está configurado?
El TTL es de 24 horas, o sea 86400 segundos, de inactividad. Está escrito de forma explícita como una constante estática y se aplica con EXPIRE después de cada escritura. Hay que decir con honestidad que es una constante del código y no una variable de entorno. Desde el 17 de octubre las 24 horas las decide PostgreSQL (`pedido.fecha_ultima_actividad`): si no fuera así, un carrito que Redis soltó volvería a nacer desde la copia. Un carrito vencido se borra al leerlo o en un barrido cada 10 minutos (`pruebas/carrito_vencimiento.sh`, 25 OK).

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 172 a 173, la constante `TTL_SEGUNDOS`. Lineas 481 a 492, el HSET seguido del EXPIRE. `redis/README.md` lineas 82 a 95, la justificación de las 24 horas.
- Lo que pide el profesor. Entrega 2, tiempo de expiración configurado explícitamente y expiración justificada, 1.5 pts.
- Por qué así. Menos tiempo castiga a quien arma el carrito de noche y paga en la mañana, y más tiempo guarda precios que ya no existen.

### 35. ¿Cómo se renueva la expiración y por qué es por inactividad?
Cada toque al carrito vuelve a poner el TTL completo. Agregar, cambiar cantidad, quitar y hasta ver el carrito renuevan las 24 horas. Quien compra seis horas seguidas no pierde nada, y quien lo abandona lo pierde 24 horas después del último toque.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 148 a 157, ver el carrito renueva. Lineas 921 a 927, el método `renovarTtl`. `pruebas/carrito.sh` lineas 114 a 131, prueba que un GET y un PUT suben el TTL de nuevo.
- Lo que pide el profesor. Entrega 2, expiración por inactividad, 1.5 pts.
- Por qué así. Es distinto al JWT, que dura 2 horas fijas. Una credencial debe morir siempre, un carrito solo debe morir cuando ya nadie lo usa (`redis/carrito.lua` lineas 55 a 70).

### 36. ¿Qué pasa en el checkout si el carrito ya venció?
El carrito vacío no se puede pagar. El checkout lo lee de Redis, ve que no hay líneas y responde 409 con el mensaje de carrito vacío. No queda pedido ni stock retenido porque agregar al carrito nunca reservó nada, y la prueba lo mide contando pedidos y stock antes y después.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 497 a 500, el 409 de carrito vacío. `redis/prueba_carrito.sh` lineas 184 a 185 y 491 a 492, stock y pedidos antes y después del vencimiento. `pruebas/carrito.sh` lineas 105 a 111, agregar no reserva stock.
- Lo que pide el profesor. Entrega 2, el efecto del TTL documentado sobre el flujo de checkout.
- Por qué así. Como el carrito no reserva, vencer no deja basura. Solo el usuario pierde lo que armó y tiene que volver a agregarlo.

### 37. ¿Cómo se evita la sobreventa en la oferta de inventario limitado?
Con un script Lua en Redis. La operación reservar compara la cantidad pedida contra el stock y descuenta en el mismo paso. Si no alcanza, responde AGOTADO y no toca el contador. Todas las salidas de rechazo están antes del primer descuento.

- Dónde se ve. `redis/inventario_limitado.lua` lineas 269 a 344, la operación `reservar`. Lineas 298 a 301, la comparación contra la cantidad pedida. Lineas 303 a 306, el descuento.
- Lo que pide el profesor. Entrega 2, oferta de inventario limitado con operaciones atómicas del almacén y sin bloqueos a nivel de aplicación, 3 pts.
- Por qué así. Redis corre el script entero como un solo comando, así que nadie se mete entre comprobar y descontar y no hace falta ningún candado.

### 38. Si Redis es de un solo hilo, ¿para qué hace falta Lua?
Un solo hilo hace atómico cada comando suelto, pero no una decisión de dos pasos. Con GET y luego DECRBY, cincuenta clientes leen que queda una y los cincuenta descuentan. Lua junta la comprobación y el descuento en un solo comando atómico.

- Dónde se ve. `redis/inventario_limitado.lua` lineas 9 a 34, las dos formas ingenuas que fallan. Lineas 45 a 52, lo que hace el script. `redis/prueba_concurrencia.sh` lineas 316 a 337, el control con DECRBY pelado que termina en menos 900.
- Lo que pide el profesor. Entrega 2, operaciones atómicas del almacén clave-valor.
- Por qué así. DECRBY es atómico y sobrevende igual, porque la comprobación quedó fuera del paso que descuenta.

### 39. ¿Cuál es la evidencia de que aguanta solicitudes concurrentes?
Se lanzan 1000 solicitudes con 50 clientes a la vez sobre 100 unidades usando `redis-benchmark`. El resultado es exactamente 100 reservas, 900 rechazos y stock 0. Una segunda ronda pide 3 unidades por solicitud y da 33 reservas y sobra 1 unidad. La prueba también mide que se abrieron los 50 sockets. Es una prueba directa contra Redis con EVALSHA, no pasa por HTTP.

- Dónde se ve. `redis/prueba_concurrencia.sh` lineas 104 a 106, los parámetros. Lineas 160 a 168, el `redis-benchmark`. Lineas 188 a 202, la medición de conexiones simultáneas. Lineas 254 a 257, lo que se espera de cada ronda. `redis/README.md` lineas 537 a 560, la salida real.
- Lo que pide el profesor. Entrega 2, evidencia de que el mecanismo se sostiene bajo solicitudes concurrentes simuladas, 3 pts.
- Por qué así. El conteo sale de cuatro números que se escriben en lugares distintos del script, así que uno solo no puede mentir por sí mismo.

### 40. ¿Usaron candados o bloqueos en la aplicación?
Para el inventario no, todo se decide dentro del script Lua. Sí hay un candado corto en el checkout, pero sirve para otra cosa. Evita que un doble clic en pagar cree dos pedidos de la misma cuenta. Es un SET con NX y vence a los 30 segundos, y no protege el stock.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 642 a 660, el candado por cuenta con `SET NX EX 30`. `redis/inventario_limitado.lua` lineas 36 a 42, por qué un candado de aplicación está descartado para el stock.
- Lo que pide el profesor. Entrega 2, sin recurrir a bloqueos a nivel de aplicación en la oferta limitada.
- Por qué así. Un candado de aplicación puede quedar tomado si el proceso muere, y hay que adivinar cuánto esperar. El script no tiene ese problema.

### 41. ¿Qué pasa con una reserva que el usuario abandona?
Cada reserva tiene un ticket y un plazo de 15 minutos. Los tickets se guardan en un conjunto ordenado con el milisegundo en que vencen. Al llegar la siguiente reserva, el mismo script devuelve al stock las que ya vencieron. No hace falta proceso de fondo.

- Dónde se ve. `backend/src/helpers/constantes.ts` lineas 29 a 37, el plazo de 900 segundos. `redis/inventario_limitado.lua` lineas 175 a 206, la cosecha de reservas vencidas. Lineas 315 a 321, el ZADD con el vencimiento. `redis/prueba_concurrencia.sh` lineas 343 a 388, la prueba de que lo abandonado vuelve solo.
- Lo que pide el profesor. Entrega 2, inventario limitado sin sobreventa y sin unidades perdidas.
- Por qué así. El EXPIRE de una clave borra sin avisar y el stock se perdería. Con el conjunto ordenado, las unidades vuelven dentro del mismo paso atómico.

### 42. ¿Cómo se cambia la cantidad de una reserva sin perder las unidades?
Con la operación redimensionar, que suelta la reserva vieja y toma la nueva en un solo paso. Se compara contra el stock libre más lo que la reserva vieja va a soltar. Si fueran dos llamadas, otro comprador podría llevarse las unidades en el medio. Hoy el backend carga un script aparte, `redimensionar-reserva.lua`, y la misma operación también existe dentro de `inventario_limitado.lua`.

- Dónde se ve. `redis/inventario_limitado.lua` lineas 486 a 569, la operación. Lineas 530 y 536 a 539, el stock efectivo y el rechazo. `backend/src/services/inventario-limitado/inventario-limitado.service.ts` lineas 56 a 64, qué archivo carga el backend. `backend/src/services/carrito/carrito.service.ts` lineas 291 a 302, cuándo se llama. `backend/cambio_propuestas/2026-09-03_1700-redimensionar-reserva-lua.md` explica el porqué.
- Lo que pide el profesor. Entrega 2, operaciones atómicas sin bloqueos, 3 pts.
- Por qué así. Es lo que necesita `PUT /carrito/lineas/:idOferta`, que fija la cantidad absoluta y no suma uno.

### 43. ¿Cómo se sincronizan el stock de Redis y el de PostgreSQL al comprar?
Primero se paga en PostgreSQL con `comprar_carrito`, que descuenta el stock con FOR UPDATE. Después se confirma la reserva en Redis y se vacía el carrito. Si el pago falla se devuelven las reservas al contador. Son dos contadores del mismo stock, y la confirmación en Redis es de mejor esfuerzo. PostgreSQL es el libro contable que manda.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 562 a 592, pagar y luego confirmar y vaciar. Lineas 574 a 579, devolver reservas si falla. Lineas 823 a 855, `confirmarReservas`. `docs/CONSISTENCIA-CHECKOUT.md` lineas 208 a 236, la decisión documentada. `migrations/007_flujo_pedido.sql` lineas 469 a 474, el FOR UPDATE.
- Lo que pide el profesor. Entrega 2, sin sobreventa. Es la base de la Entrega 3, fallos parciales en el checkout.
- Por qué así. Si Redis falla después del pago no se deshace la venta. A lo sumo el contador queda bajo y se dejan de vender unidades, pero nunca se sobrevende.

### 44. ¿Cómo abre y cierra el vendedor una venta relámpago?
Con dos rutas del controlador de ventas limitadas, POST y DELETE sobre la venta limitada de una oferta suya. Abrir siembra el contador de Redis con el stock que la oferta tiene en ese momento en PostgreSQL y marca la oferta. Trae una duración opcional de hasta 7 días. Cerrar borra las claves de Redis y descarta las reservas en curso.

- Dónde se ve. `backend/src/controllers/vendedores/ventas-limitadas.controller.ts` lineas 33 a 77, las dos rutas y los roles vendedor y admin. `backend/src/services/vendedores/ventas-limitadas.service.ts` lineas 54 a 71 y 118 a 133, abrir y validar la duración. `backend/src/services/inventario-limitado/inventario-limitado.service.ts` lineas 186 a 250, `activar` con la siembra.
- Lo que pide el profesor. Entrega 2, oferta de cantidad limitada disponible durante una ventana de tiempo.
- Por qué así. La ventana de tiempo es el EXPIRE de la clave de la oferta. Al vencer, las claves desaparecen solas y una revisión cada minuto apaga la marca en PostgreSQL.

### 45. ¿Qué pasa si Redis se cae?
Nada se cuelga. El cliente tiene límite de 10 segundos por comando y 3 reintentos, y cualquier fallo de Redis se convierte en un 503 con el mensaje de que no se pudo conectar con Redis. En la prueba de fallas, con Redis parado no se compra, PostgreSQL queda intacto y el carrito sigue entero. Si cae después del pago, la venta queda cerrada.

- Dónde se ve. `backend/src/database/redis.ts` lineas 17 a 40, timeouts y reintentos. `backend/src/helpers/manejar-error-redis.ts` lineas 11 a 14, el paso a error de conexión. `pruebas/falla_checkout.sh` lineas 722 a 732, el escenario de Redis parado. `docs/CONSISTENCIA-CHECKOUT.md` lineas 404 a 417, el resultado.
- Lo que pide el profesor. Entrega 3, manejo explícito de fallos parciales en el checkout con una falla simulada.
- Por qué así. Sin Redis no hay carrito ni candado de checkout, y cobrar sin poder leer el carrito sería peor que rechazar.

### 46. ¿Cómo está configurado Redis en Docker? ¿Tiene persistencia, contraseña o ACL?
El servicio usa la imagen de Redis 8 con contraseña obligatoria y persistencia AOF sobre un volumen. La contraseña sale del `.env`. No hay usuarios ACL, el backend se conecta solo con contraseña. Tampoco hay maxmemory configurado, se queda el valor por defecto, que es rechazar escrituras al llenarse en vez de borrar claves.

- Dónde se ve. `docker-compose.yml` lineas 119 a 137, el servicio, `--requirepass` en la línea 125, `--appendonly yes` en la línea 126, el volumen y el healthcheck. `backend/src/database/redis.ts` lineas 13 a 16 y 31 a 36, la conexión con contraseña. `redis/README.md` lineas 809 a 823, la razón de cada ajuste.
- Lo que pide el profesor. Entrega final, control de acceso. En Redis lo cubre requirepass. Un usuario ACL por rol no está en el código.
- Por qué así. Con AOF un reinicio no borra carritos ni contadores de ventas limitadas. La contraseña es necesaria porque el puerto 6379 es de los más barridos en redes.

### 47. ¿Cómo se muestra el TTL de Redis en vivo, con llaves que vencen y llaves que no?
Con un comando del panel de comandos, la demostración de Redis. Deja tres llaves bajo `mesh:demo`. Dos no llevan TTL, un texto con el valor 42 y un hash de configuración, y Redis las reporta con TTL -1, que RedisInsight muestra como No limit. La tercera es un hash con la forma del carrito y un TTL de 600 segundos que baja hasta que Redis la borra sola. Otro botón lista todas las llaves de Mesh con su TTL y otro quita solo las de la demostración.

- Dónde se ve. `demo-redis-sin-ttl.ps1` lineas 98 a 109, las tres llaves y el EXPIRE solo en la tercera. `demo-redis-sin-ttl.ps1` lineas 66 a 82, cómo se lee el TTL de cada llave y qué significa -1. `panel-comandos/servidor.mjs` lineas 269 a 291, los tres botones del grupo Demo de Redis.
- Lo que pide el profesor. Entrega 2, carrito con un tiempo de expiración configurado explícitamente y su efecto documentado, 1.5 pts. La demostración enseña la diferencia entre una llave que vence y una que no.
- Por qué así. Sin TTL una llave se queda hasta que alguien la borre. El carrito lleva TTL para que uno abandonado no llene la memoria, y el ranking de más vendidos no lo lleva porque un worker lo reescribe.

### 48. ¿El vencimiento del carrito se prueba pasando por el backend, o solo con Redis?
Hay dos pruebas y conviene decir cuál es cuál. `redis/prueba_carrito.sh` prueba el diseño con script Lua de `redis/carrito.lua`, que el backend todavía no usa, así que no pasa por el backend. `pruebas/carrito_vencimiento.sh` sí pasa. Todo lo hace por las rutas HTTP y solo mira Redis y PostgreSQL. Lo único que toca a mano es el reloj, con un `EXPIRE` que baja el TTL de 24 horas a unos segundos. Comprueba que quien sigue tocando el carrito no lo pierde, que quien se va lo pierde, y que al vencer el checkout contesta 409 sin mover pedidos ni stock.

- Dónde se ve. `pruebas/carrito_vencimiento.sh` lineas 111 a 132, la renovación por inactividad. Lineas 134 a 143, el vencimiento solo. Lineas 145 a 168, el checkout del carrito vencido con 409 y sin cambios en la base. `redis/prueba_carrito.sh` lineas 3 a 7, el aviso de que prueba el diseño Lua.
- Lo que pide el profesor. Entrega 2, carrito con expiración configurada explícitamente y su efecto documentado sobre el checkout (1.5 pts). La prueba tiene que ejercer lo que de verdad corre.
- Por qué así. Una prueba que habla directo con Redis puede pasar aunque el servicio del backend esté mal, porque no lo toca. Por eso la evidencia principal pasa por las rutas.

### 49. ¿La prueba de concurrencia de la oferta limitada pasa por el backend, con usuarios reales?
Hay dos. `redis/prueba_concurrencia.sh` manda 1000 solicitudes con redis-benchmark directo al script Lua, que es el mismo archivo que carga el backend, y llega a una escala que el HTTP no alcanza. `pruebas/oferta_limitada.sh` sí pasa por el backend. Registra 60 cuentas reales, un vendedor abre una venta relámpago de 20 unidades con `POST /vendedor/ofertas/:id/venta-limitada`, y las 60 piden una unidad a la vez con `PUT /carrito/lineas/:idOferta`. Ganan exactamente 20, los otros 40 reciben 409, el stock en Redis queda en 0 y nunca baja de cero. Después sueltan la reserva, y una segunda ola vuelve a dar 20.

- Dónde se ve. `pruebas/oferta_limitada.sh` lineas 172 a 183, la ola de solicitudes a la vez. Lineas 208 a 221, lo que se comprueba en cada ola. Lineas 223 a 247, las dos olas y la liberación. `redis/prueba_concurrencia.sh` lineas 3 a 8, el aviso de que va directo a Redis.
- Lo que pide el profesor. Entrega 2, oferta con operaciones atómicas validada bajo solicitudes concurrentes simuladas, sin bloqueos de la aplicación (3 pts).
- Por qué así. La decisión de quién gana es una sola operación atómica dentro de Redis. Se mira desde afuera, con cuentas de verdad y por la ruta real, para que la prueba no pueda pasar mientras el servicio hace otra cosa.


---

## Parte 4. Grafo de reseñas en Neo4j y tendencias en ClickHouse

*Entrega 2.*

Archivos que más se usan en esta parte.

- `docs/DECISION-GRAFOS-VS-COLUMNAR.md`
- `migrations/019_anillo_fraude.sql`
- `backend/src/helpers/registrar-anillo-fraude.ts`
- `backend/src/services/fraude/anillos-detector.service.ts`
- `backend/src/services/resenas/resenas.service.ts`
- `clickhouse/README.md`

### 50. ¿Qué familia eligió el equipo para la Entrega 2, grafos o columnar, y cuál quedó como alternativa?
Primero se eligió grafos con Neo4j para detectar fraude en reseñas, en el ADR del 3 de septiembre. Ese ADR dejó la columnar fuera porque PostgreSQL resolvía las tendencias en 16 ms sobre 32 pedidos. Después, el 6 de septiembre, entró ClickHouse para el panel de tendencias, cuando aparecieron los eventos de navegación. Hoy las dos familias están implementadas y Cassandra es la referencia del enunciado que se descartó.

- Dónde se ve. `docs/DECISION-GRAFOS-VS-COLUMNAR.md` lineas 118 a 123, la decisión original. `docs/ARQUITECTURA.md` lineas 143 a 156, por qué ClickHouse entró después.
- Lo que pide el profesor. Entrega 2, seleccionar al menos una de las dos familias y evaluar las dos frente al problema del sistema. Vale 1.5 pts la evaluación comparativa y 3 pts la implementación.
- Por qué así. El enunciado califica la calidad del análisis y no la cantidad de tecnologías. La decisión cambió porque cambió el dato, ya no eran 32 pedidos sino clics de navegación.

### 51. ¿Por qué grafos y no dejar la detección de anillos en SQL?
Se midió. Un `WITH RECURSIVE` en PostgreSQL encuentra los mismos anillos que Neo4j y tarda 28.7 ms, así que la velocidad no decide. Lo que decide es que en SQL hay que cortar la recursión y evitar cuentas repetidas a mano. Sin esa guarda, dos anillos reales salen como siete y se acusa a gente que no hizo nada.

- Dónde se ve. `docs/DECISION-GRAFOS-VS-COLUMNAR.md` lineas 104 a 114, la tabla que compara los dos motores. Lineas 148 a 160, la guarda que convierte dos anillos en siete.
- Lo que pide el profesor. Entrega 2, evaluación comparativa con criterios aplicados al caso del sistema y no genéricos, 1.5 pts. Incluye la opción de no introducir cambios.
- Por qué así. La consulta de fraude es de largo variable, y en Cypher eso es una sola línea mientras que en SQL son cuatro sitios donde equivocarse.

### 52. ¿Cómo es el modelo del grafo, qué nodos y qué relaciones tiene?
Hay nodos Usuario, Resena y Producto, y después se agregó Direccion. Las relaciones son ESCRIBIO de la cuenta a su reseña, CALIFICA_A de la reseña a la cuenta calificada, SOBRE de la reseña al producto y VIVE_EN de la cuenta a su dirección. La reseña es un nodo porque conecta tres cosas, autor, vendedor y producto. No hay nodo Vendedor, es el mismo Usuario.

- Dónde se ve. `neo4j/README.md` lineas 13 a 33, el modelo y sus razones. `neo4j/001_esquema.cypher` lineas 49 a 56 y 86 a 87, las restricciones de unicidad de los cuatro nodos.
- Lo que pide el profesor. Entrega 2, si se elige grafos, un modelo de relaciones entre cuentas, reseñas y productos. Forma parte de los 3 pts de la implementación.
- Por qué así. Con la reseña como nodo se puede exigir que sea sobre el mismo producto. Si el vendedor fuera otro nodo, la misma persona sería dos nodos y el anillo nunca cerraría.

### 53. ¿Cuál es la consulta de varios saltos que detecta los anillos?
Es A.1, un camino que sale de una cuenta y vuelve a ella pasando por ESCRIBIO y CALIFICA_A de 4 a 8 saltos. Cada cuenta cuesta dos saltos, porque alterna cuenta y reseña. Así 4 saltos son 2 cuentas, 6 son un triángulo y 8 son un cuadrado. Dos filtros evitan que un mismo anillo salga repetido por rotación o con cuentas repetidas.

- Dónde se ve. `neo4j/consultas/A1_anillo.cypher` lineas 41 a 44, el patrón. Línea 54, el filtro de rotación. Lineas 74 a 75, el filtro de cuentas repetidas.
- Lo que pide el profesor. Entrega 2, al menos una consulta de varios saltos que señale un conjunto de cuentas con patrón anómalo. Es el reto específico de los 3 pts.
- Por qué así. En Cypher un camino no repite relaciones pero sí puede repetir nodos. Sin el segundo filtro, una pareja que se califica dos veces salía como anillo de cuatro cuentas que no existe.

### 54. ¿Qué tipos de anillo distingue el sistema?
Tres. Mutuo son dos cuentas que se califican entre sí. Ciclo son tres o cuatro cuentas en círculo. Reiterado es un mutuo que además ocurre sobre el mismo producto, y pisa al tipo mutuo del mismo par. El tipo sale de cuántas cuentas trae el camino y de cuál de las dos consultas lo encontró.

- Dónde se ve. `backend/src/services/fraude/anillos-detector.service.ts` lineas 141 a 155, donde se decide el tipo. Lineas 259 a 268, la consulta del reiterado. `migrations/019_anillo_fraude.sql` lineas 59 a 69, el catálogo de los tres tipos.
- Lo que pide el profesor. Entrega 2, señalar conjuntos de cuentas que se califican entre sí de forma reiterada sobre los mismos productos. Es la frase del enunciado.
- Por qué así. Mutuo y reiterado son la misma pareja con señal más fuerte, por eso comparten fila y el tipo sube o baja sin crear un caso nuevo.

### 55. ¿Cada cuánto se buscan anillos y qué es la ventana de 60 días?
El worker corre cada 15 minutos. Solo cuenta anillos cuyas reseñas caen todas dentro de los últimos 60 días. Un ciclo con una sola reseña vieja ya no cuenta como activo. Los 60 días son una constante que se puede ajustar.

- Dónde se ve. `backend/src/services/fraude/anillos-detector.service.ts` línea 29, el intervalo de 15 minutos. Línea 32, la ventana de 60 días. Línea 249, el filtro de fecha dentro de la consulta Cypher.
- Lo que pide el profesor. Entrega 2, una detección que corra sobre el grafo y se pueda demostrar. La ventana y el intervalo son decisión del equipo.
- Por qué así. Sin ventana, un anillo de hace años seguiría marcado como fraude vigente. La constante quedó documentada como ajustable y no se midió contra datos reales de fraude.

### 56. ¿Hay que esperar los 15 minutos cuando alguien publica una reseña nueva?
No. Al crear la reseña el backend llama a `procesarAhora` para proyectarla al grafo y, cuando termina, llama a `detectarInmediato`. Esa versión acotada corre las mismas consultas pero exige que el camino pase por la reseña recién creada. Va sin await, así que no retrasa la respuesta al usuario.

- Dónde se ve. `backend/src/services/resenas/resenas.service.ts` lineas 317 a 328, la llamada encadenada. `backend/src/services/fraude/anillos-detector.service.ts` lineas 84 a 115, el chequeo inmediato, y línea 288, la condición de la reseña nueva.
- Lo que pide el profesor. Entrega 2, que la señal de fraude no dependa solo de un reloj. También la Entrega 3, por el manejo de consistencia eventual.
- Por qué así. La reseña nueva es la única arista nueva del grafo, así que un ciclo que no pase por ella ya lo vio una corrida anterior. Está encadenado porque necesita que la reseña ya esté en Neo4j.

### 57. ¿Dónde se guardan los anillos que se detectan?
En PostgreSQL, como una señal en `senal_fraude`, la misma tabla donde van las de compras y las de login. Hay una fila por tipo y clave, y la clave son los ids de las cuentas ordenados y unidos con guion. Las cuentas van en `senal_fraude_cuenta`, todas como autor, y las reseñas que son la evidencia en `senal_fraude_resena`. Si el detector vuelve a encontrar el anillo es la misma fila, suma una detección y mueve `ultima_deteccion`. Hasta la migración 033 iban a `anillo_fraude` y `anillo_fraude_resena`, que siguen en la base sin escrituras.

- Dónde se ve. `migrations/031_senales_fraude.sql` línea 168, la tabla `senal_fraude`, con su UNIQUE de tipo y clave en la 204, y lineas 232 y 265, los pivotes de cuentas y reseñas. `backend/src/helpers/registrar-anillo-fraude.ts` lineas 90 a 177, la función registrarSenalDelAnillo.
- Lo que pide el profesor. Entrega 2, un panel visible para el equipo administrativo que señale la manipulación de reseñas. Se lee por `GET /admin/fraude/alertas-resenas`, solo para admin. Y en la revisión del 28-09, que todo el fraude se guarde con un solo modelo.
- Por qué así. Las cuentas salen de la clave, que es exactamente el conjunto que encontró el detector. Antes se sacaban con un join contra reseña, y en coordinados metía al vendedor, que no es sospechoso.

### 58. ¿Qué significan los estados pendiente, revisada y descartada?
Todo anillo nuevo nace pendiente. Un admin lo puede pasar a revisada o a descartada con un PATCH. Solo se puede cambiar si sigue pendiente, y si no, contesta 409. Aunque el worker vuelva a encontrar el mismo anillo, no lo reabre.

- Dónde se ve. `backend/src/services/fraude/fraude-anillos-persistidos.service.ts` línea 215, el UPDATE de la señal con su condición, y la 238, la distinción entre 404 y 409. `backend/src/helpers/registrar-anillo-fraude.ts` lineas 135 a 141, el INSERT con ON CONFLICT que no toca el estado. `backend/src/models/alerta-fraude.ts` lineas 16 a 18, los tres ids.
- Lo que pide el profesor. Entrega 2, un panel para el equipo administrativo. La revisión humana es parte del flujo.
- Por qué así. Si el worker reabriera lo ya descartado, un falso positivo volvería cada 15 minutos. Los tres estados son el mismo catálogo que usan las alertas de login.

### 59. ¿Por qué a las cuentas del anillo no se les envía notificación?
Porque son las sospechosas y no las víctimas. En el fraude de login se avisa al dueño de la cuenta, porque le están robando. En un anillo de reseñas avisarle daría la oportunidad de evadir la detección. El caso es interno y lo revisa solo un admin.

- Dónde se ve. `migrations/019_anillo_fraude.sql` lineas 40 a 46, la razón escrita. `backend/src/helpers/registrar-anillo-fraude.ts` lineas 40 a 42, la misma decisión en el código.
- Lo que pide el profesor. No es un requisito literal del enunciado, es una decisión de diseño del equipo que puede defender.
- Por qué así. Notificar a un sospechoso es lo contrario de detectarlo. La diferencia con login es quién es la persona señalada.

### 60. ¿Cómo se demuestra el anillo en vivo?
Con `demo-anillo-resenas.ps1`. Registra 2, 3 o 4 cuentas de demostración, las pasa a vendedor, cada una publica una oferta y el admin la aprueba. Luego cada cuenta le compra a la siguiente con el checkout real y le escribe una reseña de 5 estrellas. Con 2 cuentas ofertan el mismo producto y sale un reiterado. Con 3 o 4 cada una vende uno distinto y sale un ciclo.

- Dónde se ve. `demo-anillo-resenas.ps1` lineas 10 a 26, los pasos, y lineas 182 a 213, la compra y la reseña. `backend/src/services/resenas/resenas.service.ts` lineas 267 a 272, la regla que exige haber comprado.
- Lo que pide el profesor. Entrega 2, evidencia de que la consulta de varios saltos señala un patrón anómalo. También sirve de demostración ante el curso.
- Por qué así. Las compras son reales porque la regla de reseñas exige haber comprado y pagado. Por eso la demo no se puede deshacer, deja pedidos, pagos y kardex.

### 61. ¿Por qué ClickHouse y no Cassandra, que era la referencia del enunciado?
Con Cassandra hay que saber la pregunta antes de guardar el dato, porque se diseña una tabla por consulta. Con ClickHouse se guarda el evento una vez y se pregunta lo que sea después con SQL. El enunciado permite alternativas equivalentes en la sección 5.2. Además el ADR dejó escritas las condiciones para incorporar la columnar, entre ellas que crezca el volumen de eventos, que es lo que pasó.

- Dónde se ve. `clickhouse/README.md` lineas 24 a 46, la razón completa. `docs/DECISION-GRAFOS-VS-COLUMNAR.md` lineas 291 a 299, el inicio de las condiciones para la alternativa no elegida.
- Lo que pide el profesor. Entrega 2, para la alternativa no seleccionada, documentar las condiciones bajo las cuales su incorporación estaría justificada. También el criterio de la sección 5.2 de componentes equivalentes.
- Por qué así. Las condiciones del ADR se escribieron pensando en Cassandra, antes de que ClickHouse entrara. La razón de fondo es que las tendencias y el fraude piden preguntas que hoy no se conocen.

### 62. ¿Cómo está modelado ClickHouse para consultar por intervalos de tiempo?
Cada tabla de eventos se ordena por su pregunta, por ejemplo vista_producto por producto y fecha. Así una consulta sobre un producto lee un tramo seguido del disco. Los eventos se borran solos a los 12 meses con TTL. Un resumen diario por producto se mantiene solo con una vista materializada, sin ETL. Todas las tablas llevan una columna lote que separa lo real de lo generado.

- Dónde se ve. `clickhouse/001_esquema.sql` lineas 31 a 75, la tabla vista_producto con su ORDER BY y su TTL. Lineas 318 a 350, el resumen diario con vista materializada.
- Lo que pide el profesor. Entrega 2, si se elige la columnar, un modelo orientado a consultas por intervalos de tiempo. Forma parte de los 3 pts de la implementación.
- Por qué así. En ClickHouse el ORDER BY es el orden físico en disco y decide cuánto se lee. La columna lote evita que un panel muestre como tendencia lo que sembró un script.

### 63. ¿Cuál es la consulta que compara un periodo contra el anterior para hallar productos en ascenso?
Hay dos formas. En ClickHouse está escrita con countMergeIf sobre el resumen diario, cuenta vistas de los últimos 7 días contra los anteriores y calcula cuántas veces creció. Esa consulta hoy se corre a mano en la consola de ClickHouse y todavía no es una ruta del backend. Lo que sí funciona en el panel es Compras en ascenso, que pide la ventana de N días y la de 2N y resta para sacar el periodo anterior.

- Dónde se ve. `clickhouse/README.md` lineas 131 a 140, la consulta con countMergeIf. `frontend/src/lib/TendenciasAuto.svelte` lineas 210 a 265, la comparación de compras contra el periodo anterior. `docs/BACKEND-PENDIENTE.md` lineas 1858 a 1866, donde se documentó que falta la ruta.
- Lo que pide el profesor. Entrega 2, al menos una consulta que identifique variaciones de demanda entre periodos. Es el reto específico de los 3 pts si se elige la columnar.
- Por qué así. Restar 2N menos N solo es exacto cuando el total suma, como compras y devoluciones. Las vistas cuentan sesiones distintas y no se pueden restar, por eso hace falta la consulta sobre el resumen.

### 64. ¿Cómo llegan los datos a ClickHouse, hay un ETL?
Depende del evento. Las vistas y los agregados al carrito nacen en ClickHouse, el backend los escribe sin esperar respuesta. Las compras se escriben igual al cerrar el checkout, y un ETL de respaldo copia desde PostgreSQL las que faltan y compara conteos al final. El ETL de Mongo del catálogo es otro, es de la Entrega 1 y no alimenta a ClickHouse. Mongo solo se consulta después, para traer el nombre del producto de cada ranking.

- Dónde se ve. `backend/src/services/eventos/eventos.service.ts` lineas 29 a 42, el insert de vistas. `backend/src/services/carrito/carrito.service.ts` lineas 594 a 608, la compra sin await. `etl/cargar_compras.sh` lineas 26 a 29 y 106 a 119, no duplica y comprueba que cuadre. `backend/src/services/admin/admin-tendencias.service.ts` lineas 120 a 153, el detalle desde Mongo.
- Lo que pide el profesor. Entrega 2, mantener explícito cómo se alimenta cada componente NoSQL. La coherencia entre bases se retoma en la Entrega 3.
- Por qué así. La escritura es fire-and-forget porque la venta ya quedó cerrada en PostgreSQL y ClickHouse caído no debe deshacerla. Por eso el ETL de respaldo recupera lo perdido.

### 65. ¿La detección de anillos se prueba con el detector del backend, o con las consultas sueltas?
Hay dos pruebas. `neo4j/correr_fraude.sh` corre los archivos `neo4j/consultas/A*.cypher` directo contra Neo4j. El detector del backend tiene sus propias copias de esas consultas dentro del código, así que esa prueba demuestra las consultas del repositorio y no las que corren. `pruebas/anillos.sh` pasa por el backend. Registra cuentas nuevas, las hace vendedoras, hace compras y reseñas reales por el checkout, y espera al detector. Encuentra un ciclo con las tres cuentas al primer segundo, y la cuenta de control, que compra y reseña pero a la que nadie le compra, no aparece en ningún anillo.

- Dónde se ve. `pruebas/anillos.sh` lineas 130 a 142, cada compra y reseña por las rutas reales. Lineas 144 a 152, el control y el ciclo. Lineas 154 a 189, la espera al detector y que la cuenta de control quede fuera. Lineas 191 a 208, el detalle que sale de Neo4j y el caso marcado como revisado con 409 al repetirlo. `neo4j/correr_fraude.sh` lineas 3 a 7, el aviso de que va directo a Neo4j.
- Lo que pide el profesor. Entrega 2, un modelo de relaciones con al menos una consulta de varios saltos que señale cuentas con un patrón anómalo, con la reseña como caso (3 pts).
- Por qué así. El detector del backend guarda sus consultas dentro del código, así que la única forma de probar las que corren es pasar por el backend. La prueba deja compras reales y por eso marca el anillo como revisado.


---

## Parte 5. Buscador en Elasticsearch y consistencia del checkout

*Entrega 3.*

Archivos que más se usan en esta parte.

- `elastic/001_indice.json`
- `docs/CONSISTENCIA-CHECKOUT.md`
- `elastic/README.md`
- `backend/src/services/buscador/productos.service.ts`
- `pruebas/busqueda.sh`
- `backend/src/services/carrito/carrito.service.ts`

### 66. ¿Cómo está construido el mapping del índice de productos y por qué no lo dejaron por defecto?
Lo escribimos a mano en un archivo JSON. Define un analizador propio que pasa a minúsculas y quita tildes, y le da a cada campo su tipo. El nombre es texto con dos subcampos, uno para escribir a medias y otro keyword para ordenar y agrupar. Estado y categoría son keyword, los precios son double, y hay un solo shard sin réplicas porque es un nodo.

- Dónde se ve. `elastic/001_indice.json` lineas 6 a 13 el analizador espanol_llano, y lineas 16 a 62 los campos. La razón de no usar el analizador spanish está en `elastic/README.md` lineas 81 a 88.
- Lo que pide el profesor. Entrega 3, índice de búsqueda con mapping construido deliberadamente y no dejado en su configuración por defecto. Cuenta dentro de los 5 puntos del buscador.
- Por qué así. Sin mapping Elasticsearch adivina los tipos con el primer documento, y no tendríamos quitar tildes ni campos listos para agrupar. No se usa spanish porque corta raíces y estos son nombres de marca y modelo.

### 67. ¿Cómo corrige el buscador los errores de ortografía, por ejemplo escribir labtop y encontrar Laptop?
Usa una consulta multi_match con fuzziness AUTO, que acepta una o dos letras equivocadas según el largo de la palabra. Además el analizador quita las tildes, así que ámbar encuentra Ambar. Busca en nombre, descripción y variantes.

- Dónde se ve. `backend/src/services/buscador/productos.service.ts` lineas 86 a 92, la consulta con fuzziness. La prueba con labtop está en `pruebas/busqueda.sh` lineas 201 a 220.
- Lo que pide el profesor. Entrega 3, búsqueda por texto libre con tolerancia a variaciones ortográficas, y al menos una función de autocompletado o de corrección de ortografía. Cuenta dentro de los 5 puntos del buscador.
- Por qué así. El $text de Mongo no tiene búsqueda difusa, y por eso se trajo el motor dedicado (`elastic/README.md` lineas 17 a 18).

### 68. ¿Cómo funciona el autocompletado?
El mapping tiene un subcampo search_as_you_type llamado nombre.escribiendo, pensado para contestar con la palabra a medias. El arnés lo prueba con la palabra lap. La ruta del backend hoy no consulta ese subcampo. La caja de la cabecera reutiliza la búsqueda difusa mientras se escribe, con espera de 250 milisegundos y mínimo de dos letras.

- Dónde se ve. `elastic/001_indice.json` lineas 22 a 25, el subcampo. `pruebas/busqueda.sh` lineas 365 a 373, la prueba con bool_prefix. `frontend/src/lib/BuscadorCabecera.svelte` lineas 85 a 86 y 117 a 135, la espera y el disparo. `frontend/src/lib/buscador.ts` línea 65, el mínimo de letras.
- Lo que pide el profesor. Entrega 3, al menos una función de autocompletado o de corrección ortográfica. La corrección con fuzziness ya cubre el requisito.
- Por qué así. Con una sola letra la búsqueda difusa trae medio catálogo, por eso se exigen dos letras (`frontend/src/lib/buscador.ts` lineas 74 a 76).

### 69. ¿Cómo se ordenan los resultados por relevancia y qué son los boosts?
No hay un sort escrito, así que Elasticsearch ordena por su puntaje de relevancia. El campo nombre pesa el triple que descripción y variantes, eso es el boost. El filtro de estado activo va en un filter, que no cambia el puntaje.

- Dónde se ve. `backend/src/services/buscador/productos.service.ts` lineas 86 a 92, el nombre con peso 3, y lineas 95 a 106, la consulta bool con el filter. Las notas de reseñas se indexan en `elastic/001_indice.json` lineas 55 a 56, pero esta consulta no las usa.
- Lo que pide el profesor. Entrega 3, ordenamiento por relevancia en la búsqueda por texto libre.
- Por qué así. Quien busca casi siempre escribe el nombre, así que una coincidencia ahí debe valer más que una en la descripción.

### 70. ¿Cómo se calculan los filtros facetados con agregaciones?
Honestamente, en el código del backend todavía no hay una agregación sobre el catálogo. La consulta del buscador devuelve solo hits. El mapping ya dejó listos los campos que una faceta necesita, categoría como keyword y precio como double. Las agregaciones sí existen en el índice de eventos de login, que es otro índice.

- Dónde se ve. `docs/PENDIENTES.md` lineas 211 a 225, el punto 10 que lo declara abierto. `elastic/001_indice.json` lineas 41 a 50, los campos listos. Un ejemplo real de agregación terms está en `backend/src/services/fraude-login/toma-cuenta.service.ts` lineas 69 a 82.
- Lo que pide el profesor. Entrega 3, filtros facetados calculados con las capacidades de agregación del motor, y al menos una agregación empleada para ellos. Está dentro de los 5 puntos del buscador.
- Por qué así. Una faceta cuenta cuántos resultados hay por categoría o rango de precio, y eso solo lo hace bien el motor con una agregación terms sobre un campo keyword.

### 71. ¿Cómo llegan a Elasticsearch los cambios de un producto?
Cuando el backend crea o edita un producto en Mongo, marca el mismo documento con pendiente_busqueda en true. Un worker corre cada 10 segundos, toma hasta 200 marcados, los indexa con el mismo id y les quita la marca. Si Elasticsearch falla, la marca se queda y se reintenta en la siguiente vuelta. Reindexar dos veces el mismo id no duplica.

- Dónde se ve. `backend/src/services/buscador/buscador-sync.service.ts` lineas 39 a 55 el intervalo y la búsqueda de pendientes, y lineas 58 a 78 el index, el unset y el catch que deja la marca. La marca nace en `backend/src/services/vendedores/productos.service.ts` lineas 190 a 192, y su definición en `backend/src/models/producto.ts` lineas 128 a 137.
- Lo que pide el profesor. Entrega 3, mantener el índice de búsqueda coherente con la base de origen. Es parte del buscador implementado.
- Por qué así. Mongo corre como servidor único y no permite change streams ni transacciones entre documentos, así que la bandera va dentro de la misma escritura y es atómica gratis (`backend/cambio_propuestas/2026-09-04_2124-pendiente-busqueda-cola-elastic.md` lineas 28 a 40).

### 72. ¿Por qué se indexan todos los estados de producto y no solo los activos?
Porque el administrador necesita encontrar justo lo que no circula, como lo rechazado o en revisión. El filtro se movió al backend. La ruta pública agrega siempre estado activo, fijo en el código, y solo la ruta de admin se lo salta y exige rol admin.

- Dónde se ve. `backend/src/services/buscador/productos.service.ts` lineas 98 a 105, el filter fijo. `backend/src/controllers/buscador/productos.controller.ts` lineas 71 a 74, la ruta admin protegida. `etl/extraer_busqueda.js` lineas 26 a 50, la explicación y el filtro vacío.
- Lo que pide el profesor. Entrega 3, buscador funcional. Aquí se ve una decisión de arquitectura justificada, que el enunciado pide registrar (sección 5.3).
- Por qué así. Si el ETL seguía filtrando, una reconstrucción completa borraba lo que el worker ya había indexado, sin dar error (`backend/cambio_propuestas/2026-09-04_2208-elastic-indexar-todos-los-estados.md`).

### 73. ¿Cómo prueban que el buscador funciona, y por qué el índice sale de Mongo y no de PostgreSQL?
El arnés pruebas/busqueda.sh comprueba la difusa, las tildes, la palabra a medias y que un rechazado no lo ve un comprador. También comprueba que los productos 103, 104 y 106 están en el índice y no tienen fila en PostgreSQL. Esos productos los publica un vendedor y nacen solo en Mongo, así que un índice armado desde PostgreSQL diría que no existen.

- Dónde se ve. `pruebas/busqueda.sh` lineas 239 a 264 los productos que solo viven en Mongo, y lineas 266 a 360 la regla del rechazado. La decisión está en `etl/extraer_busqueda.js` lineas 7 a 13.
- Lo que pide el profesor. Entrega 3, buscador implementado y probado. Ayuda a los 5 puntos del buscador y a la calidad del repositorio.
- Por qué así. Sin esa prueba el fallo sería silencioso, un producto que se vende y que el buscador jura que no existe.

### 74. ¿Qué componentes intervienen en el checkout y cuáles participan de la transacción?
El checkout toca diez componentes. Solo tres están dentro del COMMIT de PostgreSQL, que son la oferta, la función comprar_carrito y la cola evento_grafo. Redis, MongoDB, Neo4j y Elasticsearch quedan fuera. Por eso comprar se reduce a una transacción de PostgreSQL rodeada de escrituras en otras bases.

- Dónde se ve. `docs/CONSISTENCIA-CHECKOUT.md` lineas 35 a 53, la lista de componentes. `backend/src/services/carrito/carrito.service.ts` lineas 474 a 485 y 562 a 572, el flujo y la llamada a comprar_carrito. `migrations/012_comprar_carrito.sql` lineas 111 a 127, las tres funciones en una sola llamada.
- Lo que pide el profesor. Entrega 3, documento de estrategia de consistencia que identifique cada componente involucrado. Vale 5 puntos.
- Por qué así. Un COMMIT de PostgreSQL no puede deshacer una escritura de Redis. Por eso el dinero y el stock son transaccionales y lo demás se acepta como eventual.

### 75. ¿Cuáles son los puntos de falla del checkout y qué mitigación tiene cada uno?
El documento lista once. Doble clic se cubre con un candado en Redis. Stock agotado y compras simultáneas se cubren con la transacción y FOR UPDATE. La falla con reservas tomadas se compensa devolviéndolas. Redis al confirmar, carrito sin vaciar, agregados de Mongo y el índice se aceptan como ventana eventual. Mongo caído da 503 sin escribir nada. Ojo con la fila 10, dice que el índice solo se reconstruye con el ETL, pero el recálculo tras la compra también marca el producto para el worker, que lo refresca en unos 10 segundos.

- Dónde se ve. `docs/CONSISTENCIA-CHECKOUT.md` lineas 127 a 139, la tabla de puntos de falla. `backend/src/services/productos/productos.service.ts` línea 679, la marca pendiente_busqueda que pone el recálculo. `backend/src/services/carrito/carrito.service.ts` línea 611, donde el checkout lo llama.
- Lo que pide el profesor. Entrega 3, identificar los puntos de falla y el mecanismo de mitigación, sea reintento idempotente, compensación o ventana de consistencia eventual documentada. Vale 5 puntos.
- Por qué así. Cada punto se clasifica en una de esas tres categorías para que se vea que ninguna falla queda sin decisión.

### 76. ¿Cómo evitan que un doble clic en Pagar cobre dos veces?
Antes de comprar se toma un candado en Redis por usuario con SET NX y vencimiento de 30 segundos. La segunda petición no lo consigue y recibe un 409 que dice que ya hay una compra en curso. El candado se suelta en un finally, y si eso fallara el vencimiento lo limpia. Debajo hay una segunda defensa, el FOR UPDATE sobre la oferta en PostgreSQL.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 646 a 672, el candado y su liberación. `migrations/007_flujo_pedido.sql` lineas 467 a 474, el bloqueo FOR UPDATE con orden fijo. `backend/src/dto/comprar-carrito.ts` lineas 57 a 61, el reintento seguro con confirmar_cambios.
- Lo que pide el profesor. Entrega 3, mecanismo de mitigación por reintentos idempotentes. También cuenta para la prueba de falla, 4 puntos.
- Por qué así. Sin candado, dos peticiones idénticas creaban dos pedidos. El candado ahorra el trabajo y quien impide de verdad vender la misma unidad dos veces es PostgreSQL.

### 77. ¿Dónde está el patrón de compensación en el checkout?
Está en las reservas de la venta relámpago. Si la compra falla, se llama devolverReservas y las unidades vuelven al contador de Redis en el acto, sin esperar los 15 minutos del ticket. Si la compra sale bien, confirmarReservas las pasa a vendidas, pero es best effort. Si Redis falla ahí, no se deshace la venta, se registra y se sigue.

- Dónde se ve. `backend/src/services/carrito/carrito.service.ts` lineas 573 a 584 el catch que compensa, lineas 833 a 856 la confirmación best effort y lineas 866 a 884 la devolución. La explicación está en `docs/CONSISTENCIA-CHECKOUT.md` lineas 204 a 235.
- Lo que pide el profesor. Entrega 3, mitigación con un patrón de compensación o con la aceptación documentada de una ventana eventual. Aquí hay una de cada una.
- Por qué así. La venta ya está pagada en PostgreSQL, que manda. Deshacerla por un fallo del contador auxiliar dejaría sin compra a quien pagó, solo para arreglar un número.

### 78. ¿Qué prueba de falla simulada hicieron y qué resultado dio?
El arnés falla_checkout.sh compra con todo vivo como línea base. Luego para Redis, Mongo y PostgreSQL con docker stop, uno por vez, y pide la compra. Después compara pedidos, pagos, kardex y stock antes y después. El resultado fue 31 OK y 0 FALLA. Ninguna caída cobró a medias, y el hallazgo fue que Mongo caído también impide comprar.

- Dónde se ve. `pruebas/falla_checkout.sh` lineas 604 a 622 el stop, la compra y su clasificación, lineas 679 a 686 la comprobación de que PostgreSQL quedó intacto, y lineas 728 a 732, 746 a 750 y 761 a 765 los tres escenarios. El trap que levanta los contenedores está en la línea 511. La evidencia está en `docs/CONSISTENCIA-CHECKOUT.md` lineas 389 a 448.
- Lo que pide el profesor. Entrega 3, evidencia de al menos una prueba de falla simulada sobre el checkout y el comportamiento resultante. Vale 4 puntos.
- Por qué así. La línea base evita que un escenario sin compra parezca prueba. Es una parada ordenada y no un corte de luz, y el documento lo dice.

### 79. ¿Qué ve el usuario cuando el checkout falla?
Si una base no responde, el backend contesta 503 con el nombre de la base, por ejemplo No se pudo conectar con MongoDB. El pedido, el pago y el stock quedan como estaban, el candado queda suelto y el carrito sigue entero, así que puede reintentar de inmediato. Con Mongo caído tarda unos 5 segundos en fallar, porque el tiempo de espera del driver se bajó a 3 segundos.

- Dónde se ve. `backend/src/helpers/manejar-error-http.ts` lineas 37 a 42, el 503. `frontend/src/lib/Checkout.svelte` lineas 1126 a 1139, cómo se muestra el mensaje. `backend/src/database/mongo.ts` lineas 31 a 32, los 3 segundos. Lo medido está en `backend/elementos Generales/prueba-falla-mongo-checkout.md` lineas 69 a 84.
- Lo que pide el profesor. Entrega 3, manejo explícito de fallos parciales con un comportamiento definido y comunicado al usuario, al menos en un escenario simulado. Vale 4 puntos.
- Por qué así. Mongo no escribe nada del pedido, pero se lee antes del COMMIT, así que es una dependencia de disponibilidad. Cómo manejarla queda por decidir con el profesor, y el documento propone tres salidas en las líneas 341 a 351 de `docs/CONSISTENCIA-CHECKOUT.md`.

### 80. ¿Cómo se mapea el índice de eventos de autenticación y para qué sirven los subcampos keyword?
Es una plantilla para todo índice llamado mesh_eventos_autenticacion. Con dynamic en false, cada campo tiene un tipo elegido, y ip es de tipo ip y fecha es date. Los campos de texto exacto como tipo, resultado e id_usuario son keyword y además tienen un subcampo keyword. Las consultas de fraude piden esos subcampos, por ejemplo ip.keyword, y sin ellos daban cero resultados sin error.

- Dónde se ve. `elastic/002_eventos_autenticacion.json` lineas 25 a 53 los campos con sus subcampos, y lineas 34 a 45 el subcampo minusculas. Las consultas que los usan están en `backend/src/services/fraude-login/toma-cuenta.service.ts` lineas 60 a 82. La explicación está en `elastic/README.md` lineas 194 a 209. El worker es `backend/src/services/eventos-autenticacion/eventos-autenticacion-sync.service.ts` lineas 93 a 128.
- Lo que pide el profesor. Este índice no lo pide la Entrega 3 por sí mismo. Sirve para mostrar agregaciones reales, que el enunciado exige para el buscador.
- Por qué así. Es una plantilla porque el worker autocrea el índice al escribir, y con mapeo dinámico la ip saldría como texto y dejaría de servir para rangos.

### 81. ¿Cómo está configurado Elasticsearch en el docker-compose?
Usa la imagen 8.15.3 en un solo nodo. El heap se fija en 512 megas con mínimo y máximo iguales para no competir por memoria con Neo4j. La seguridad está apagada porque es un entorno de clase que solo escucha en local. Expone el puerto 9200, guarda datos en un volumen y tiene un healthcheck que acepta estado yellow.

- Dónde se ve. `docker-compose.yml` líneas 231 a 232 la imagen, línea 238 el nodo único, línea 248 la seguridad apagada, línea 262 el heap y líneas 275 a 288 el healthcheck.
- Lo que pide el profesor. Entrega 3, componente de búsqueda en la arquitectura, con Elasticsearch como opción de referencia. El enunciado pide documentar las decisiones (sección 5.3).
- Por qué así. Con la 8.x la seguridad viene encendida y genera credenciales nuevas en cada reinicio. Apagarla es una decisión de desarrollo escrita en el propio archivo, y ahí mismo dice que es la primera línea a quitar fuera de desarrollo.

### 82. ¿Cómo se inspecciona el índice de Elasticsearch desde una interfaz gráfica?
Con Kibana, en la misma versión que Elasticsearch, la 8.15.3. Es un servicio más del docker compose, abre en el puerto 5601 solo en localhost y se conecta a Elasticsearch por su nombre de servicio. Un contenedor de un solo uso crea solo las vistas de datos de Productos y de Eventos de autenticación, así que en Discover ya se ven los documentos, con un rango de tiempo por defecto de 60 días.

- Dónde se ve. `docker-compose.yml` lineas 295 a 334, el servicio kibana con su tope de memoria. `docker-compose.yml` lineas 336 a 361, el contenedor que crea las vistas. `docker/kibana/vistas.sh` lineas 1 a 24, qué hace y por qué existe. `arrancar.ps1` lineas 3371 a 3398, el paso que espera y cuenta el resultado.
- Lo que pide el profesor. El enunciado no pide una interfaz gráfica. Sirve para enseñar en vivo el mapping construido a propósito y los documentos del índice, que es lo que la Entrega 3 pide justificar en el buscador (5 pts).
- Por qué así. Kibana lleva un tope de memoria de 640 MB porque la máquina va justa, y solo escucha en localhost porque Elasticsearch corre con la seguridad apagada.


---

## Parte 6. Fraude de login y de IP

*Valor extra del grupo.*

Archivos que más se usan en esta parte.

- `backend/src/services/fraude-login/fraude-login.service.ts`
- `backend/src/services/fraude-login/fraude-login-retrospectivo.service.ts`
- `backend/src/controllers/usuario.controller.ts`
- `backend/src/helpers/registrar-alerta-fraude.ts`
- `migrations/018_notificacion_fraude.sql`
- `frontend/src/lib/PanelFraude.svelte`

### 83. ¿Qué detecta el módulo de fraude de login y cuántas señales tiene?
Detecta intentos sospechosos de entrar a una cuenta. Tiene nueve señales. Cuatro se cuentan en Redis dentro del propio login (fuerza bruta por IP, fuerza bruta por cuenta, multi cuenta por IP y rotación de IP). Cinco se consultan en Elasticsearch (toma de cuenta, viaje imposible y tres versiones lentas de 24 horas).

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 119 a 150, las cuatro revisiones de Redis corriendo juntas. `backend/src/models/alerta-fraude.ts` lineas 20 a 28, los nueve ids de tipo. `migrations/017_alertas_fraude_extendidas.sql` lineas 47 a 58, los seis tipos que se suman a los tres de la 016.
- Lo que pide el profesor. El enunciado no pide fraude de login, es valor extra del grupo. Se apoya en la Entrega 2 (10 puntos, almacén clave-valor con operaciones atómicas) y en la Entrega 3 (15 puntos, agregaciones del motor de búsqueda). También sirve al panel administrativo del alcance funcional, que consume varias fuentes.
- Por qué así. Lo rápido se cuenta en Redis para no frenar el login, y lo lento se mira en Elasticsearch sobre el historial.

### 84. ¿Qué umbrales y ventanas tienen los contadores de Redis?
Fuerza bruta por IP salta con 8 fallos en 60 segundos. Fuerza bruta por cuenta salta con 5 fallos en 60 segundos. Multi cuenta por IP salta con 4 cuentas distintas en 300 segundos. Rotación de IP salta con 4 IPs distintas contra una cuenta en 300 segundos.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 99 a 113, las seis constantes de ventana y umbral.
- Lo que pide el profesor. Entrega 2, almacén clave-valor con tiempo de expiración configurado de forma explícita. Aquí es la misma idea que el carrito, pero aplicada a ventanas de conteo.
- Por qué así. Las ventanas son cortas, por eso los umbrales son bajos. Las versiones lentas de 24 horas usan umbrales más altos, 15, 8 y 5, en `backend/src/services/fraude-login/fraude-login-retrospectivo.service.ts` lineas 68 a 70.

### 85. ¿Cómo cuenta Redis en tiempo real y para qué sirven INCR, EXPIRE NX, SADD y SCARD?
En fuerza bruta se hace INCR sobre una clave por IP o por cuenta. En multi cuenta y rotación se hace SADD a un conjunto y SCARD dice cuántos elementos distintos hay. Después de cada uno se pone EXPIRE con NX para que el conteo se borre solo al terminar la ventana.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 159 a 165, INCR y EXPIRE con NX. Lineas 212 a 219, SADD, EXPIRE y SCARD. Lineas 90 a 93, el comentario que explica el NX.
- Lo que pide el profesor. Entrega 2, operaciones atómicas del almacén clave-valor sin bloqueos a nivel de aplicación.
- Por qué así. INCR es atómico, así que dos intentos a la vez no se pisan. NX pone el tiempo de vida solo al crear la clave, y así la ventana no se alarga con cada intento nuevo. El conjunto no repite elementos, por eso SCARD cuenta distintos.

### 86. ¿Por qué Redis para contar en tiempo real y Elasticsearch para los patrones de 24 horas?
Redis responde en el mismo intento de login, sin esperar a ningún worker, pero solo recuerda ventanas de uno a cinco minutos. Un ataque repartido en horas nunca cruza esos umbrales cortos. Elasticsearch guarda el historial de eventos y con agregaciones puede mirar las últimas 24 horas completas.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 55 a 62, el comentario que separa Redis del índice de Elasticsearch. `backend/src/services/fraude-login/fraude-login-retrospectivo.service.ts` lineas 22 a 26 y 33 a 38, por qué se re-evalúan 24 horas. Lineas 156 a 200, la agregación con terms, cardinality y bucket_selector.
- Lo que pide el profesor. Entrega 3, agregaciones del motor de búsqueda. Entrega 2, almacén clave-valor.
- Por qué así. Cada base hace lo que mejor sabe. Redis para contar rápido con expiración, Elasticsearch para agrupar mucho historial. El worker no decide a quién mirar, Elasticsearch ya devuelve filtrada la lista de sospechosos.

### 87. ¿Cómo detecta que una IP prueba muchas cuentas distintas?
En cada intento, bueno o malo, se agrega lo que se tecleó a un conjunto de Redis con clave por IP. Si el conjunto llega a 4 elementos dentro de 300 segundos, se crea la alerta multi cuenta por IP. La alerta guarda hasta 20 identificadores como evidencia. Cuentan también las entradas buenas y los correos inventados.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 205 a 237, la revisión completa. Línea 135, se llama sin importar si el intento falló. Línea 233, el tope de 20 identificadores.
- Lo que pide el profesor. No es un requisito literal, es parte del valor extra sobre Entrega 2 con Redis.
- Por qué así. Es el patrón de credential stuffing, una sola IP probando muchas cuentas. El tope de 20 evita guardar un jsonb enorme si el ataque es de miles de correos.

### 88. ¿Qué es la rotación de IP por cuenta y en qué se distingue de multi cuenta por IP?
Es el espejo de multi cuenta. En vez de agrupar por IP y contar cuentas, agrupa por cuenta y cuenta IPs distintas. Si una misma cuenta es probada desde 4 IPs distintas en 300 segundos, alguien está cambiando de IP para esquivar un bloqueo por IP.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 239 a 280, el método completo con SADD, EXPIRE NX y SCARD. Lineas 112 a 113, ventana y umbral.
- Lo que pide el profesor. Nada literal, es valor extra sobre Entrega 2.
- Por qué así. Usa el mismo mecanismo con la clave armada al revés, así que no hace falta código nuevo de conteo. Su versión lenta en Elasticsearch usa 5 IPs en 24 horas.

### 89. ¿Cómo funciona el viaje imposible y cómo se calcula la velocidad?
Cada login exitoso se compara con el login exitoso anterior de la misma cuenta, buscado en Elasticsearch. Con la fórmula de haversine se saca la distancia en kilómetros entre las dos ubicaciones. Se divide entre las horas transcurridas y, si la velocidad pasa de 800 km/h, se crea la alerta.

- Dónde se ve. `backend/src/services/fraude-login/viaje-imposible.service.ts` lineas 70 a 84, la consulta del login anterior con geo. Lineas 93 a 130, el cálculo y la alerta. Lineas 139 a 149, haversine. La ubicación sale de `backend/src/helpers/contexto-peticion.ts` lineas 67 a 87, con geoip-lite en memoria.
- Lo que pide el profesor. Nada literal, es valor extra que usa el Elasticsearch de la Entrega 3.
- Por qué así. 800 km/h es más rápido que un vuelo comercial. Un usuario con VPN da un falso positivo, y el código lo deja escrito como limitación aceptada en las lineas 43 a 47. Una IP local como 127.0.0.1 no tiene ubicación y no se evalúa, lineas 60 a 65 del helper.

### 90. ¿Cómo detecta la toma de cuenta por IP nueva?
Solo corre en login exitoso. Pregunta a Elasticsearch las IPs desde las que esa cuenta ya entró bien. Si la IP actual no está entre ellas, crea la alerta y anota si la huella del cliente también es nueva. Si la cuenta tiene menos de 3 logins exitosos previos, no evalúa nada.

- Dónde se ve. `backend/src/services/fraude-login/toma-cuenta.service.ts` lineas 51 a 83, la consulta con agregaciones de IPs y huellas. Lineas 90 a 99, el mínimo de historial y la comparación. Línea 33, el mínimo de 3.
- Lo que pide el profesor. Nada literal, es valor extra sobre la Entrega 3, agregaciones en el motor de búsqueda.
- Por qué así. El mínimo evita marcar como sospechoso el primer login de una cuenta nueva, que siempre tendría IP nueva. Los contadores de Redis no pueden ver esto porque solo recuerdan minutos.

### 91. ¿Cada cuánto corren los patrones lentos y hay que esperar a que corran?
Un worker corre cada 15 minutos y revisa las últimas 24 horas con tres señales. Son fallos contra una cuenta con umbral 15, cuentas distintas desde una IP con umbral 8 y IPs distintas contra una cuenta con umbral 5. Además, después de cada login se corre una versión acotada solo a esa cuenta y esa IP, para no esperar los 15 minutos.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login-retrospectivo.service.ts` lineas 64 a 70, intervalo, ventana y umbrales. Lineas 77 a 100, el worker. Lineas 293 a 321, la evaluación inmediata. `backend/src/controllers/usuario.controller.ts` lineas 88 a 108, donde se encadena tras cada login.
- Lo que pide el profesor. Entrega 3, agregaciones del motor de búsqueda, aquí con terms, min_doc_count y bucket_selector.
- Por qué así. El disparo inmediato y el worker usan el mismo tipo y la misma hora, así que se juntan en una sola alerta y no se duplican. El worker queda de respaldo si Elasticsearch estaba caído en ese instante.

### 92. ¿Cómo se guarda una alerta sin duplicarla y qué es la llave de conflicto?
Cada alerta es una señal en `senal_fraude`, y la llave es el tipo y la clave, por ejemplo fuerza bruta por IP y la IP. Si la misma señal vuelve a cruzar el umbral no nace otra fila, se le suma una detección en `total_detecciones` y se refrescan el detalle y `ultima_deteccion`. Hasta la migración 033 la llave llevaba además el minuto, y cada minuto nacía una fila nueva en `alerta_fraude`. Ahora hay una sola y la historia es el contador.

- Dónde se ve. `backend/src/helpers/registrar-alerta-fraude.ts` lineas 193 a 322, la función registrarSenalDeLaAlerta, con el INSERT en la 227 y la suma en la 244. `migrations/031_senales_fraude.sql` línea 204, el UNIQUE de tipo y clave.
- Lo que pide el profesor. En la revisión del 28-09, un solo modelo para todo el fraude en vez de una tabla por detector.
- Por qué así. Sin la llave, un ataque de mil intentos dejaría mil filas. El conflicto no toca el estado, así que una alerta ya revisada solo vuelve a pendiente si llega evidencia nueva, una cuenta o IP que no tenía, una métrica más alta o un episodio nuevo después de una hora. Una confirmada nunca se reabre.

### 93. ¿Cuándo se crea una notificación y cuándo se vuelve a avisar?
La tabla `notificacion_fraude` guarda una fila por señal y por cuenta afectada, con su propia fecha de lectura. La fila nace la primera vez que la cuenta aparece en la señal. Si la señal se reabre por evidencia nueva, la notificación vuelve a quedar sin leer y sube en la lista del usuario. Antes había una por cada minuto en que saltaba la alerta, y al usuario le llegaba el mismo aviso varias veces.

- Dónde se ve. `backend/src/helpers/registrar-alerta-fraude.ts` lineas 268 a 275, el INSERT de la notificación, y lineas 313 a 320, cuando se reabre. `migrations/032_evidencia_y_aviso_por_senal.sql` línea 181, el índice único de señal y usuario, y `migrations/033_sin_llaves_viejas_de_fraude.sql`, donde la llave a la señal pasa a ser obligatoria.
- Lo que pide el profesor. Entrega final, panel administrativo que consume varias fuentes. La migración 018 anota que el profesor pidió que también el usuario afectado vea sus alertas.
- Por qué así. Una columna no puede apuntar a varias cuentas, una tabla sí. Todo va en la misma transacción que la señal, así no queda una alerta a medio notificar.

### 94. ¿Cómo decide el sistema a qué cuentas les llega una alerta?
Depende de la forma de la alerta. Si trae una cuenta resuelta, le llega a esa cuenta. Si trae una lista de identificadores, como multi cuenta por IP, se busca cada uno por usuario o por correo y le llega a todas las cuentas reales. Si no trae ninguna de las dos, como fuerza bruta por IP, no le llega a nadie y queda solo para el panel del admin.

- Dónde se ve. `backend/src/helpers/registrar-alerta-fraude.ts` línea 80, la función resolverCuentasDestino. Esas cuentas quedan en `senal_fraude_cuenta` con el rol víctima.
- Lo que pide el profesor. Nada literal, es la parte de notificar del pedido del profesor sobre el fraude de login.
- Por qué así. Un correo inventado no genera fila porque no hay cuenta a quien avisar. Mira la forma de detalle y no el nombre del tipo, así una señal nueva con la misma forma queda cubierta sin tocar el archivo.

### 95. ¿Qué ve el usuario afectado y qué no se le enseña?
Ve una campana en la cabecera con el número de alertas sin leer y una pestaña Alertas en su panel. Solo ve las de su propia cuenta y las puede marcar como leídas. En multi cuenta se le quita la lista de las demás cuentas probadas y solo se le deja el conteo.

- Dónde se ve. `frontend/src/lib/NotificacionesFraude.svelte` lineas 5 a 19 y línea 72, la campana y su consulta. `frontend/src/lib/AlertasFraudeUsuario.svelte` lineas 5 a 20, la pestaña. `backend/src/controllers/perfil.controller.ts` lineas 87 a 119, GET y PATCH de alertas-fraude. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 579 a 598, cómo se quitan los identificadores ajenos.
- Lo que pide el profesor. Se pidió que el usuario también vea sus alertas, según el encabezado de `migrations/018_notificacion_fraude.sql` lineas 4 a 7.
- Por qué así. El id de la cuenta sale siempre de la sesión y nunca de un parámetro, y marcar leída tiene el chequeo de dueño dentro del UPDATE, lineas 501 a 527 del servicio. Así nadie se entera de quiénes fueron las otras víctimas.

### 96. ¿Por qué nadie se bloquea solo y para qué sirve el botón Bloquear?
El sistema solo avisa, nunca frena el login. Cruzar un umbral deja una alerta para que un admin la revise. Si el admin decide actuar, pulsa Bloquear junto a la cuenta afectada. Pide una confirmación y suspende la cuenta, y se puede deshacer.

- Dónde se ve. `backend/src/services/fraude-login/fraude-login.service.ts` lineas 63 a 71, el comentario de que es best-effort y solo alerta. `backend/src/controllers/usuario.controller.ts` lineas 178 a 183, se llama sin await. `frontend/src/lib/BloquearCuenta.svelte` lineas 22 a 36 y 57 a 78, el botón. `frontend/src/lib/PanelFraude.svelte` línea 1042 del commit, donde se pone junto a cada cuenta afectada. Una cuenta suspendida no entra, `backend/src/services/usuario.service.ts` lineas 153 a 155.
- Lo que pide el profesor. No es requisito del enunciado, es decisión del equipo escrita en el comentario del servicio.
- Por qué así. Una regla automática bloquearía a un usuario legítimo con VPN o a todo el equipo probando desde la misma máquina. Un fallo de Redis tampoco debe tumbar el login. El humano decide con la evidencia a la vista.

### 97. ¿Cómo se ve cada alerta desglosada en el panel del admin?
Cada alerta es una tarjeta con qué pasó y su estado. Muestra la IP o la cuenta intentada, las cuentas afectadas con un punto que dice si ya la leyeron, y lo que se vio en una frase. Muestra cuántas veces se detectó, la última vez, y la lista de correos o usuarios tecleados o de IPs vistas. En viaje imposible añade de dónde a dónde.

- Dónde se ve. `frontend/src/lib/PanelFraude.svelte` lineas 1016 a 1070, los campos de la tarjeta. Lineas 1072 a 1091, la lista de tecleados. El backend la arma en `backend/src/services/fraude-login/fraude-login.service.ts` lineas 381 a 396, con las cuentas afectadas de las lineas 44 a 53. La ruta es `backend/src/controllers/fraude/fraude.controller.ts` lineas 22 a 37, solo admin.
- Lo que pide el profesor. Entrega final, panel administrativo que consume múltiples fuentes. Este panel junta PostgreSQL, Redis y Elasticsearch.
- Por qué así. Las alertas se leen de PostgreSQL porque ahí quedan todas, vengan de Redis o de Elasticsearch. Los textos tecleados se recortan a 80 caracteres y se pintan escapados, porque los escribe cualquiera.

### 98. ¿Qué estados tiene una alerta y cómo pasa de pendiente a revisada o descartada?
Tiene tres estados, pendiente, revisada y descartada. Nace pendiente. El admin pulsa Marcar revisada o Descartar y solo se permite el cambio desde pendiente. Si la alerta ya no está pendiente el backend contesta 409, y si no existe contesta 404.

- Dónde se ve. `migrations/016_alerta_fraude.sql` lineas 109 a 122, el catálogo de estados, que ahora usa `senal_fraude`. `backend/src/controllers/admin/admin-fraude-login.controller.ts` lineas 58 a 73, el PATCH. `backend/src/services/fraude-login/fraude-login-exploracion.service.ts` línea 242, el UPDATE de la señal con condición, y la 265, la distinción entre 404 y 409. `frontend/src/lib/PanelFraude.svelte` lineas 1093 a 1112, los botones.
- Lo que pide el profesor. Nada literal, es el triage del panel administrativo.
- Por qué así. La condición de estado pendiente va dentro del propio UPDATE, así dos admins a la vez no se pisan y el segundo recibe el 409. Los estados son una tabla catálogo y no un texto libre.

### 99. ¿Cómo se muestran las señales de fraude en clase sin esperar un ataque real?
Hay dos scripts. `demo-evento-fraude.ps1` manda peticiones HTTP directas y dispara una sola señal por corrida, la que se elija con el parámetro Tipo, y luego abre el panel. `demo-fraude-login.ps1` abre un Chrome que escribe solo, para una escena más teatral. Ninguno cubre viaje imposible, rotación de IP ni toma de cuenta porque necesitan una IP distinta.

- Dónde se ve. `demo-evento-fraude.ps1` lineas 12 a 24, qué dispara cada tipo con sus umbrales. Línea 46, los tres tipos permitidos. Lineas 25 a 33, lo que no cubre. `demo-fraude-login.ps1` lineas 1 a 8 y línea 82, los 8 intentos por defecto.
- Lo que pide el profesor. Entrega final, presentación del proyecto ante el curso.
- Por qué así. La versión sin ventanas es la que hay que usar si el tiempo es corto, porque no depende del foco de Windows. Los contadores de multi cuenta se acumulan durante 5 minutos, así que conviene esperar entre corridas, lineas 35 a 42 del script.

### 100. ¿Cómo se simulan IPs de otros países con Tor?
Se levanta un Tor de Docker por país, obligado a salir por ese país. Cada país tiene su propio link, por ejemplo mesh-singapur.ledkid.com, que se abre en cualquier navegador, también en el celular. Un proxy pequeño reenvía ese link a la dirección pública de Mesh saliendo por el Tor de ese país, así que el backend ve la IP de la salida de Tor y su país sale de geoip. Con eso se ven rotación de IP, toma de cuenta y viaje imposible, entrando con la misma cuenta desde dos países seguidos.

- Dónde se ve. `tor-demo.ps1` lineas 1 a 4 y línea 21, un Tor por país y el puerto de cada uno. `tor-demo.ps1` líneas 62 a 65, el comando de tor con ExitNodes y StrictNodes. `pais-enlace.ps1` lineas 1 a 12, el link por país y el proxy que reenvía. `demo-entrar-otro-pais.ps1` lineas 1 a 26, cómo abrir países, ver el estado y cerrar. `docs/DEMO-OTRO-PAIS.md` lineas 62 a 66, qué hace falta para el viaje imposible.
- Lo que pide el profesor. Entrega final, presentación del proyecto. No es requisito del enunciado, es la forma de demostrar la señal sin gente real en otros países.
- Por qué así. Desde una sola máquina el origen siempre es el mismo, así que sin Tor esas tres señales no se pueden mostrar. La demo no para el backend ni las bases. Cada país es un Tor de casi 100 MB, con los ocho a la vez la máquina va lenta y bastan dos o tres. La salida de Tor cambia de IP dentro del mismo país.

### 101. ¿Por qué correr la demo de anillos de reseñas también dispara la alerta multi cuenta por IP?
Porque el script entra con admin y con las cuentas del anillo, todas desde la misma máquina y la misma IP. Con 3 cuentas del anillo más el admin son 4 identificadores distintos, que es justo el umbral de multi cuenta. No es un error, es la señal funcionando bien. Los intentos buenos también cuentan.

- Dónde se ve. `demo-anillo-resenas.ps1` lineas 127 a 131, el login del admin. Lineas 135 a 137, un login por cada cuenta del anillo. Lineas 152 a 153, un login más de cada cuenta para refrescar el rol. `backend/src/services/fraude-login/fraude-login.service.ts` líneas 106 y 135, el umbral de 4 y el conteo en cada intento.
- Lo que pide el profesor. Entrega 2, panel de manipulación de reseñas con grafo. La alerta de login es otra señal distinta que aparece de rebote.
- Por qué así. El contador de Redis solo mira cuántos identificadores distintos entraron desde una IP en 300 segundos. No sabe si vienen de una demo. Por eso la alerta aparece en el panel de intentos de entrada aunque la demo sea de reseñas.


---

## Parte 7. Arquitectura, seguridad y entrega final

*Entrega final.*

Archivos que más se usan en esta parte.

- `docs/ARQUITECTURA.md`
- `docker-compose.yml`
- `backend/src/database/redis.ts`
- `docs/base-de-datos.md`
- `backend/src/services/usuario.service.ts`
- `docs/TRASPASO.md`

### 102. ¿Cuál es la arquitectura completa y qué hace cada base de datos?
Son seis motores y cada uno tiene un trabajo. PostgreSQL es la fuente de verdad con usuarios, pedidos, pagos, ofertas y stock. MongoDB guarda el catálogo, su historial y el log de login. Redis lleva el carrito, las reservas y los contadores de fraude, Neo4j las relaciones entre cuentas y reseñas, Elasticsearch la búsqueda y ClickHouse los eventos con fecha.

- Dónde se ve. `docs/ARQUITECTURA.md` lineas 132 a 141, tabla de qué guarda cada motor, y lineas 27 a 67, el diagrama. `docker-compose.yml` declara los motores en las lineas 7 a 26 (PostgreSQL), 55 a 83 (MongoDB), 119 a 137 (Redis), 183 a 218 (Neo4j), 231 a 292 (Elasticsearch) y 315 a 408 (ClickHouse).
- Lo que pide el profesor. Entrega final, diagrama de arquitectura que refleje todos los componentes de persistencia y sus relaciones (3 pts). La sección 3 del enunciado da el reparto por módulo.
- Por qué así. Cada base responde una pregunta que las otras hacen mal, como transacción, atributos variables, expiración atómica, varios saltos, texto difuso y eventos en el tiempo.

### 103. ¿Por qué una arquitectura políglota y no todo en PostgreSQL?
Porque ninguna base sola cubre bien todos los patrones de acceso. PostgreSQL se quedó con lo que necesita transacción e integridad, como la compra y el descuento de stock. El catálogo pasó a MongoDB porque los atributos cambian por categoría. Y no se migró todo, las ofertas y lo social se quedaron en PostgreSQL con su argumento escrito.

- Dónde se ve. `docs/base-de-datos.md` linea 561 (ADR-1, catálogo a MongoDB), linea 571 (ADR-2, ofertas se quedan) y linea 990 (ADR-5, lo social se queda). `docs/ARQUITECTURA.md` lineas 179 a 190, la regla de producto en Mongo y ofertas en PostgreSQL.
- Lo que pide el profesor. Secciones 1 y 5.5 del enunciado, justificar mantener un componente relacional con el mismo nivel de exigencia que una migración. También cuenta en la presentación (4 pts).
- Por qué así. El descuento de stock no puede vender dos veces la última unidad, y eso lo garantiza una transacción relacional.

### 104. ¿Qué autenticación hay configurada en cada base NoSQL?
Cuatro de las cinco piden usuario y contraseña. MongoDB crea su usuario root al arrancar, Redis usa requirepass, Neo4j usa NEO4J_AUTH y ClickHouse crea un usuario propio. Elasticsearch tiene la seguridad apagada a propósito, porque solo escucha en localhost y no guarda nada que no esté en PostgreSQL. Todas las contraseñas salen del `.env`.

- Dónde se ve. `docker-compose.yml` lineas 59 a 63 (MongoDB), 123 a 126 (Redis), 188 (Neo4j), 324 a 326 (ClickHouse) y 240 a 248 (Elasticsearch sin seguridad). El backend entra con esas credenciales en `backend/src/database/mongo.ts` linea 16, `backend/src/database/redis.ts` lineas 31 a 36, `backend/src/database/neo4j.ts` lineas 29 a 34 y `backend/src/database/clickhouse.ts` lineas 25 a 32.
- Lo que pide el profesor. Entrega final, autenticación y autorización configuradas explícitamente en al menos un componente NoSQL (4 pts).
- Por qué así. Un Redis sin contraseña acepta a cualquiera que alcance el puerto 6379, y en la red de la universidad eso es un riesgo real. El comentario está en `docker-compose.yml` lineas 110 a 114.

### 105. ¿Cómo funciona el inicio de sesión, la contraseña y la expiración de 2 horas?
Al iniciar sesión el backend compara la contraseña contra su hash y firma un JWT con el id y el rol. El token viaja en la cookie mesh_token, httpOnly y sameSite lax, y vence a las 2 horas. La contraseña se guarda con scrypt de Node y un salt al azar por usuario. Un comentario de usuario.service dice bcrypt pero el código usa scrypt.

- Dónde se ve. `backend/src/helpers/token.ts` lineas 6 a 30 (HS256, 2 horas y opciones de la cookie) y 48 a 54 (firma). `backend/src/helpers/contrasena.ts` lineas 9 a 21 (hash) y 23 a 48 (comparación con timingSafeEqual). `backend/src/services/usuario.service.ts` lineas 113 a 165, iniciarSesion. `backend/src/controllers/usuario.controller.ts` linea 166, donde se pone la cookie.
- Lo que pide el profesor. Fase inicial, registro y autenticación con roles de comprador, vendedor y administrador. Entrega final, control de acceso (4 pts).
- Por qué así. Un solo número de 2 horas sirve para el token y para la cookie y no se pueden desincronizar. La cookie httpOnly impide que JavaScript robe el token, y los tres fallos de login dan el mismo mensaje para no revelar qué cuentas existen.

### 106. ¿Cómo se protege una ruta y cómo funcionan los roles comprador, vendedor y admin?
Se pone SesionGuard en el controller y, si hace falta, Roles con los ids de rol. El guard revisa la cookie y el token (401), revisa que la cuenta siga activa en la base (401) y compara el rol contra la lista (403). Los ids son 1 comprador, 2 vendedor y 3 admin. Las rutas de admin llevan Roles de admin en la clase, las de vendedor admiten vendedor y admin, y carrito y pedidos solo piden sesión.

- Dónde se ve. `backend/src/guards/sesion.guard.ts` lineas 41 a 98. `backend/src/decorators/roles.decorator.ts` lineas 3 a 18. `backend/src/models/rol-usuario.ts` lineas 11 a 13. `backend/src/controllers/admin/admin-usuarios.controller.ts` lineas 20 a 22, y el mismo patrón en `backend/src/controllers/admin/admin-reportes.controller.ts` lineas 22 a 24. Para vendedor, `backend/src/controllers/vendedores/productos.controller.ts` lineas 37 a 38.
- Lo que pide el profesor. Entrega final, control de acceso con autorización por rol (4 pts). Fase inicial, roles de comprador, vendedor y administrador.
- Por qué así. El token vale 2 horas aunque suspendan la cuenta, por eso el guard consulta la base en cada petición con estaActivo, en `backend/src/services/usuario.service.ts` linea 206.

### 107. ¿Cómo consume el panel administrativo varias fuentes de datos?
El panel es una sola pantalla con pestañas para el admin y cada pestaña llama rutas de admin del backend que leen una base distinta. Reportes y Cuentas leen PostgreSQL y Tendencias lee ClickHouse. Fraude junta alertas de PostgreSQL, el log de login de Elasticsearch y el detalle de anillos de Neo4j. Esconder una pestaña no protege nada, el backend responde 403.

- Dónde se ve. `frontend/src/routes/panel/+page.svelte` lineas 132 a 148 (pestañas del admin), 815 a 834 (Cuentas y Fraude) y 842 a 850 (Tendencias). `backend/src/controllers/admin/admin-tendencias.controller.ts` lineas 30 a 32, y `backend/src/services/admin/admin-tendencias.service.ts` linea 2, cliente de ClickHouse. `backend/src/controllers/admin/admin-fraude-login.controller.ts` lineas 44 a 48, ruta del log de Elasticsearch. `frontend/src/lib/sesion.ts` lineas 50 a 62, donde se explica que el rol solo decide qué se pinta.
- Lo que pide el profesor. Panel administrativo, componente transversal que consume múltiples fuentes. Entrega 2 pide los paneles de fraude y de tendencias.
- Por qué así. Cada pestaña usa la base que mejor contesta su pregunta, y el navegador nunca sabe de cuál sale el dato porque toda respuesta trae ok, mensaje y payload.

### 108. ¿Dónde está el diagrama de arquitectura final y cómo se generó?
Está en docs/diagrama-arquitectura.drawio con su PNG. Dibuja los seis motores, lo que hace el backend con cada uno y ocho rutas de datos entre motores. Lo genera un script de Python que al final comprueba que cada flecha nombre cajas que existen. Desde la Entrega final dibuja también la ruta 11, que lleva el texto de MongoDB a Ollama. Desde el 4 de octubre el vector ya no termina en PostgreSQL sino en el documento del producto en Elasticsearch, y las reseñas llegan a `mesh_comentarios` por la cola `evento_comentario`.

- Dónde se ve. `docs/generar-arquitectura.py` lineas 1 a 18. `docs/ARQUITECTURA.md` lineas 3 a 14. El diagrama entidad relación es otro archivo, `docs/diagrama-general.drawio`, que dibuja `docs/generar-er.py` leyendo la base viva, lineas 1 a 19.
- Lo que pide el profesor. Entrega final, diagrama de arquitectura completo y correcto (3 pts). Las entregas 2 y 3 también piden actualizarlo.
- Por qué así. El ER se genera de la base porque el dibujado a mano se quedó en 42 cajas cuando ya había 50 tablas.

### 109. ¿Dónde está el registro de decisiones arquitectónicas y qué estructura tiene?
Está repartido en docs. base-de-datos.md trae cinco ADR sobre catálogo, ofertas, imágenes, proponente y lo social. DECISION-GRAFOS-VS-COLUMNAR.md sigue los campos que pide el enunciado y además dice cuándo estaría justificada la alternativa no elegida. La consistencia del checkout tiene su propio documento. DECISION-NEWSQL-PAGOS.md es el ADR-8, no migrar los pagos a una NewSQL. Los de la Entrega final están en el informe, el ADR-10 de los vectores en la sección 2.1 y el ADR-11 del control de acceso en Redis en la 3.1. El ADR-10 se replanteó el 4 de octubre, de pgvector a Elasticsearch, y el porqué está en `docs/ARQUITECTURA.md`.

- Dónde se ve. `docs/base-de-datos.md` lineas 561, 571, 581, 591 y 990, encabezados de ADR-1 a ADR-5. `docs/DECISION-GRAFOS-VS-COLUMNAR.md` linea 14 (contexto), 66 (alternativas) y 256 (consecuencias). `docs/CONSISTENCIA-CHECKOUT.md` linea 122, los puntos de falla.
- Lo que pide el profesor. Sección 5.3, un registro breve con contexto, alternativas (al menos dos, incluida no cambiar), decisión, justificación y consecuencias.
- Por qué así. El enunciado califica la calidad del análisis y no la cantidad de tecnologías, por eso hay ADR de decisiones de no migrar.

### 110. ¿Cómo está estructurado el backend en NestJS?
Es NestJS sobre Fastify en el puerto 3000. El archivo app.module registra cada controller y cada servicio, y si una clase no está ahí su ruta no existe. El controller recibe la petición y traduce errores a HTTP, el service tiene la lógica y el SQL a mano, dto define la forma de las peticiones y database tiene un cliente por base.

- Dónde se ve. `backend/src/app.module.ts` lineas 76 a 151. `backend/src/main.ts` lineas 32 a 35 y 54, servidor Fastify y puerto. `backend/src/database/postgres.ts` lineas 16 a 22 y `backend/src/database/redis.ts` lineas 33 a 40, dos de los seis clientes.
- Lo que pide el profesor. Sección 5.2, backend a elección del equipo. Entrega final, repositorio completo del sistema.
- Por qué así. Cada cliente lleva tiempos límite propios, así una base caída da un 503 rápido y no una petición colgada. La explicación está en `backend/src/database/redis.ts` lineas 17 a 28.

### 111. ¿Cómo se manejan los errores en el backend?
Los servicios lanzan errores de dominio y un solo helper los traduce a HTTP. Validación es 400, conflicto 409, sesión 401, no encontrado 404, pago 402 y conexión 503. Lo que no se reconoce sale como 500 con un mensaje genérico y el detalle va al log. Toda respuesta, buena o mala, trae ok, mensaje y payload.

- Dónde se ve. `backend/src/helpers/errores.ts` lineas 10 a 49. `backend/src/helpers/manejar-error-http.ts` lineas 18 a 48. `backend/src/helpers/manejar-error-db.ts` lineas 14 a 22 y 39 a 59, que decide si un fallo de PostgreSQL es de conexión. `backend/src/helpers/respuesta.ts` lineas 12 a 30.
- Lo que pide el profesor. Entrega 3, manejo explícito de fallos parciales con un comportamiento definido y comunicado al usuario. La consistencia del checkout vale 5 pts y la prueba de falla 4 pts.
- Por qué así. El mismo mapeo sirve a controllers y guards y vive en un solo lugar. Cada base tiene su propio manejador, por ejemplo `backend/src/helpers/manejar-error-redis.ts` lineas 11 a 14.

### 112. ¿Dónde se guardan las contraseñas de las bases y cómo se evita subirlas al repositorio?
Están en el `.env` de la raíz y en `backend/.env`, que git ignora. Solo se sube `.env.example` con valores de relleno. Si falta una variable Docker Compose se detiene con un mensaje, y el backend tampoco arranca. El secreto del JWT sale del mismo archivo.

- Dónde se ve. `.gitignore` lineas 4 a 6. `docker-compose.yml` lineas 1 a 3. `backend/src/helpers/entorno.ts` lineas 9 a 17. `backend/.env.example` lineas 57 a 61, el JWT_SECRET.
- Lo que pide el profesor. Entrega final, autenticación configurada de forma explícita. Sección 5.4, documentación con las instrucciones para poner el sistema en marcha.
- Por qué así. Una contraseña con valor por defecto escrito en el código queda para siempre en el historial de git. Es mejor que el sistema no arranque a que arranque con una credencial publicada.

### 113. ¿Cómo se prueba el sistema y cómo se corren los arneses de prueba?
Hay arneses en shell que prueban contra el sistema vivo. Se corren con bash y la ruta, por ejemplo bash pruebas/carrito.sh. Los dos más importantes son redis/prueba_concurrencia.sh, que lanza más solicitudes que unidades con redis-benchmark y cuenta que no haya sobreventa, y pruebas/falla_checkout.sh, que para un contenedor con docker stop y mide qué pasa en el checkout. El backend tiene jest configurado pero no hay archivos de prueba unitaria.

- Dónde se ve. `redis/prueba_concurrencia.sh` lineas 19 a 26. `pruebas/falla_checkout.sh` lineas 1 a 8. `docs/TRASPASO.md` lineas 364 a 379, la lista de los arneses. `backend/package.json` linea 16, el script de jest.
- Lo que pide el profesor. Entrega 2, evidencia de la oferta limitada bajo concurrencia sin bloqueos de aplicación (3 pts). Entrega 3, prueba de falla simulada del checkout (4 pts).
- Por qué así. El código puede estar bien escrito y sobrevender igual, y solo lanzarle más gente de la que cabe lo demuestra.

### 114. ¿Cómo se arranca todo el sistema y qué es el panel de comandos?
Desde la raíz se corre .\arrancar.ps1, que levanta los diez contenedores, más uno de un solo uso que prepara las vistas de Kibana, corre las migraciones que faltan y comprueba los ETL. Después se arrancan el backend en el puerto 3000 y el frontend en el 5173. Con .\panel-comandos.ps1 se abre una página de botones en el puerto 5199 que ejecuta esos mismos comandos. Ese panel solo escucha en 127.0.0.1, solo corre una lista fija de comandos y exige un token, y borrar todo pide escribir BORRAR TODO.

- Dónde se ve. `ARRANCAR.txt` lineas 8 a 35 y 64 a 70. `arrancar.ps1` lineas 1 a 9, las opciones. `comandos.txt` lineas 4 a 21 (el panel) y 84 a 88 (seguridad). `panel-comandos/servidor.mjs` lineas 12 a 23, por qué es seguro, y linea 620, donde escucha solo en 127.0.0.1.
- Lo que pide el profesor. Sección 5.4, archivo de documentación con las instrucciones para poner en funcionamiento el sistema completo.
- Por qué así. Los botones de arrancar hacen falta justo cuando el backend y el frontend están apagados, por eso el panel vive aparte de la aplicación. Está explicado en `panel-comandos/servidor.mjs` lineas 8 a 10.

### 115. ¿Cómo se organizó el equipo y cómo se trabajó con el backend?
El equipo es de tres y cada uno tiene su área. Uno lleva el frontend, los datos y las migraciones, otro lleva el backend y el tercero apoya en lo que haga falta. Lo que el resto necesita del backend se escribe en un archivo de pendientes. Cada cambio ya construido deja una nota fechada en backend/cambio_propuestas con su contexto y sus pruebas, que solo se agrega y no se reescribe.

- Dónde se ve. `docs/TRASPASO.md` lineas 406 a 407 (el equipo) y 302 a 305 (las reglas de trabajo). `docs/BACKEND-PENDIENTE.md` lineas 1 a 4. `backend/elementos Generales/README.md` lineas 29 a 31, qué es cambio_propuestas. `backend/cambio_propuestas/2026-09-18_0015-anillos-fraude-persistencia.md` lineas 1 a 12, un ejemplo del formato.
- Lo que pide el profesor. Sección 5.1, equipos de dos a tres integrantes con la distribución de responsabilidades. Sección 5.4, repositorio único con historial del progreso.
- Por qué así. Una sola persona toca el backend para no pisarse, y todo va a la rama main sin ramas paralelas.


---

## Parte 8. Entrega final, lo que hoy hay en el repositorio

*Entrega final.*

Estas preguntas piden cosas de la entrega final. Cada respuesta dice con claridad qué existe hoy y dónde. Puestas al día el 26 de septiembre.

### 116. ¿Hay roles y permisos acotados por servicio en algún componente NoSQL, y hay evidencia de que un usuario sin permisos sea rechazado?
Sí, en Redis. Hay tres usuarios de ACL, cada uno con lo justo. `default` es el del backend, trabaja con datos y corre el Lua de la venta relámpago, pero no puede vaciar, configurar ni listar con KEYS. `inspeccion` es el de RedisInsight y solo lee. `operador` es para mantenimiento a mano y puede todo. La evidencia es una prueba que intenta lo prohibido con cada usuario y ve el NOPERM. Lo que borraría algo no se ejecuta, se le pregunta antes a Redis con ACL DRYRUN.

- Dónde se ve. `docker-compose.yml` lineas 121 a 170, los tres usuarios con sus reglas, y 213, RedisInsight entrando como inspeccion. `redis/prueba_acceso.sh`, 31 OK, con el ACL DRYRUN en las lineas 53 a 63. En vivo, `.\demo-entrega-final.ps1 -Parte acceso` o el botón Quien puede que en Redis del panel de comandos. El ADR-11 está en el informe, sección 3.1.
- Lo que pide el profesor. Entrega final, roles y permisos acotados según el servicio, con evidencia de que quien no tiene permiso no puede operar fuera de su alcance (4 pts).
- Por qué así. Redis es el que guarda lo más delicado en caliente, el carrito, los contadores de fraude y las ventas relámpago, y un FLUSHALL por error se lleva todo eso. Además sigue la autorización por rol en la API, con 401 y 403, en `backend/src/guards/sesion.guard.ts` lineas 41 a 98.

### 117. ¿Qué hay hoy del componente vectorial y la recomendación por similitud semántica?
Está hecho y se ve en la ficha de cada producto, en el estante Parecidos a este. El texto de cada producto (nombre, categoría y descripción) sale de MongoDB, Ollama lo convierte en un vector de 768 números con el modelo paraphrase-multilingual, y el vector se guarda en PostgreSQL con pgvector, tabla `vector_producto`, con un índice HNSW de coseno. `SimilaresService` pide los 200 vecinos más cercanos que estén activos y no sean el propio producto ni sus copias, y se queda con uno por grupo. Después pide a MongoDB cómo se ven. Los 3105 productos tienen vector. Las reseñas tienen el suyo en `vector_comentario`.

- Dónde se ve. `migrations/040_vectores_en_postgres.sql`, las dos tablas. `etl/cargar_vectores.ps1`, paso 7d de arrancar. `backend/src/services/productos/similares.service.ts` y `helpers/vectores-pgvector.ts` (`buscarCercanos()`, que sube `hnsw.ef_search` y activa `iterative_scan` para que el filtro no deje la lista corta). `vectores-sync.service.ts` recalcula cada 10 segundos los productos editados. `pruebas/recomendacion_semantica.py`, 15 OK. En vivo, `.\demo-entrega-final.ps1 -Parte semantica`, que compara el índice HNSW con la búsqueda exacta: 1,6 ms contra 7,4 ms, los mismos seis.
- Lo que pide el profesor. Entrega final, recomendación por similitud semántica de la descripción con representaciones vectoriales (5 pts). La sección 5.2 da como referencia una extensión vectorial sobre PostgreSQL, y el 16 de octubre pidió explícitamente pgvector.
- Por qué así. Es más exacto. Medido por Jose David con el mismo catálogo, pgvector da el coseno exacto en 1000 de 1001 productos y el índice `int8_hnsw` de Elasticsearch en 317, porque cuantiza los vectores. Y las comparaciones de todas las reseñas contra todas las hace PostgreSQL sin sacar los vectores de la base.
- Ojo si preguntan por la historia. Estuvo en pgvector del 25 de septiembre al 2 de octubre, en Elasticsearch del 2 al 16 de octubre, y volvió. Al volver, arrancar copió los 3105 vectores de Elasticsearch a PostgreSQL sin llamar a Ollama (mismo hash, mismo modelo). El ADR-10 de `docs/ARQUITECTURA.md` lo cuenta con números.

### 118. ¿Qué decisiones de arquitectura se sostendrían y cuáles se replantearían? (retrospectiva)
Está en el capítulo 5 del informe de la Entrega final. Son siete decisiones que sostendríamos, entre ellas el dinero y el stock en PostgreSQL sin migrar a NewSQL, el catálogo en MongoDB y Elasticsearch como copia reconstruible. Y seis que replantearíamos, cada una con lo que pasó y lo que haríamos distinto. Un ejemplo que sirve para contarlo es la base columnar, que se rechazó el 3 de septiembre con dos números medidos y entró el 6 como ClickHouse porque el dato cambió.

- Dónde se ve. `Reporte Entrega Final - DABD2 - Mesh.docx`, capítulo 5, que sale de `contenido-entrega-final.json`. `docs/ARQUITECTURA.md` lineas 143 a 156 (la columnar y el cambio) y 219 a 234 (lo que el diagrama no esconde). `docs/DECISION-GRAFOS-VS-COLUMNAR.md` linea 256, consecuencias.
- Lo que pide el profesor. Entrega final, documento de retrospectiva con las decisiones que se sostendrían y las que se replantearían, justificadas en ambos casos (4 pts).
- Por qué así. El cambio de la columnar muestra el criterio, la decisión se sostuvo con números y se revisó cuando el volumen de eventos cambió.
- Ojo, una que el informe da por sostenida se replanteó dos veces. El informe sostiene pgvector sobre el mismo PostgreSQL; el 4 de octubre los vectores se mudaron a Elasticsearch, cuando aparecieron las reseñas con vector y la búsqueda por intención, y el 16 volvieron a pgvector a pedido del profesor y porque se midió que era más exacto. Es el mismo criterio: la decisión cambió cuando cambió lo que había que buscar o lo que se midió.

### 119. ¿Cómo funciona el descuento de una oferta y por qué una venta relámpago lo exige?
La oferta guarda su precio de lista y aparte un porcentaje de descuento que puede ser nulo. El precio final no se guarda en ninguna columna, se calcula en cada consulta con `ROUND(precio * (1 - COALESCE(porcentaje_descuento, 0) / 100), 2)`. El trigger del historial escucha el precio y el porcentaje, así que cambiar solo el descuento deja una fila nueva en `precio_historial`, y la compra cobra el precio final. Una venta relámpago no se puede abrir sin descuento (409), y el descuento no se puede quitar con la venta abierta (409).

- Dónde se ve. `migrations/020_descuentos_oferta.sql` lineas 109 a 129, las dos columnas. Lineas 196 a 198, el trigger. Lineas 314 a 317, el cobro con descuento. `backend/src/helpers/precio-descuento.ts` lineas 20 a 21, la misma fórmula en el backend. `backend/src/services/vendedores/ventas-limitadas.service.ts` lineas 73 a 77, el 409 al abrir sin descuento. `pruebas/descuentos.sh` lineas 379 a 386 y 471 a 484, los dos 409 medidos por HTTP.
- Lo que pide el profesor. No es un requisito aparte del enunciado; se apoya en el historial de precios de la fase inicial y en la venta relámpago de la Entrega 2.
- Por qué así. Guardar el precio final sería una segunda verdad que puede quedar vieja. Con el de lista y el porcentaje, el historial y el pedido saben qué se publicó y qué se cobró.

### 120. ¿Cómo se juntan las alertas de fraude en casos y cómo se decide quién es el núcleo?
Las cuatro familias de detección (anillos y patrones de reseñas en Neo4j, compras y navegación en ClickHouse, y el login en Elasticsearch) dejan hallazgos, cada uno con las cuentas que toca. El agrupador une en un mismo grupo los hallazgos que comparten cuentas, pero el login nunca une por sí solo, porque compartir una IP es un indicio y no una prueba. Una cuenta es núcleo si aparece en dos o más hallazgos del grupo o en uno fuerte (ciclo, reiterado, satélites, coordinados), y el resto es periferia, que se lista pero ninguna acción automática toca. El puntaje suma los puntos por tipo, los multiplica por la diversidad de fuentes y los reduce si la evidencia es vieja. El agrupador corre al arrancar el backend y después cada 15 minutos.

- Dónde se ve. `backend/src/services/fraude/agrupador-fraude.service.ts` linea 60 (agrupar) y 156 (las cuentas concentradoras). `puntaje-fraude.service.ts` linea 65. `agrupador-fraude-worker.service.ts` linea 68, la corrida al arrancar. `migrations/026_casos_fraude.sql` lineas 48, 102 y 152, el caso, su evidencia y sus cuentas. En la app, el panel de Fraude, pestaña Casos. Pruebas `node pruebas/casos_fraude_fusion.cjs` y `node pruebas/casos_fraude_granja.cjs`.
- Ojo si preguntan por el vendedor de una granja. Una cuenta con más de 10 contrapartes en reseñas es concentradora y nunca es núcleo. Antes contaban también las reseñas del propio fraude, así que el vendedor que armaba una granja de 11 cuentas quedaba fuera del núcleo de su caso. Ahora esas reseñas no cuentan para el umbral, y la prueba de la granja lo demuestra (saboteada falla).
- Desde el refactor de fraude. El agrupador ya no tiene tres adaptadores, lee una sola tabla, `senal_fraude` (`hallazgo-fraude-adaptador.service.ts` línea 79). La evidencia del caso apunta a la señal, y la recencia sale de `ultima_deteccion`, que solo mueve el detector, así que revisar algo viejo ya no lo rejuvenece (era el C4).
- Cerrado el 17 de octubre. Una IP compartida ya no une casos, tampoco al guardar (era el C1): la evidencia es única por caso y señal, y una señal de login puede estar en varios casos con las cuentas de cada uno (`migrations/042_limpieza_fraude.sql`).

### 121. ¿Dónde vive el vencimiento de un descuento y qué pasa si se vacía Redis?
En PostgreSQL. La oferta guarda `fecha_vencimiento_descuento` y `fecha_vencimiento_venta_limitada`, y nulo quiere decir que no vence. Un worker del backend revisa cada minuto las que ya pasaron su fecha y las apaga. Hasta el 26 de septiembre el vencimiento era una clave de Redis con TTL, y un Redis vaciado se llevaba los descuentos. Ahora Redis solo lleva el contador de la venta relámpago. El panel del vendedor muestra hasta cuándo dura cada uno, y si la venta relámpago vence sola se lleva también el descuento, así que la etiqueta muestra la fecha que llega primero.

- Dónde se ve. `migrations/028_vencimiento_oferta.sql` lineas 44 y 45. `backend/src/services/vendedores/ventas-limitadas.service.ts` lineas 364 y 422. `frontend/src/lib/descuento.ts` linea 76 y `OfertasVendedor.svelte` linea 571. En vivo, `.\demo-descuentos-solos.ps1 -Parte manual`, que muestra la fecha en PostgreSQL, por la ruta del vendedor y el worker quitándolo.
- Por qué así. Una fecha en la base de verdad no se pierde con un FLUSHALL, y el worker puede saber qué venció sin preguntarle a Redis.

### 122. ¿Por qué todo el fraude se guarda en una sola tabla de señales?
Porque cada detector guardaba a su manera. Los anillos en `anillo_fraude`, las compras en `hallazgo_evento_fraude` y el login en `alerta_fraude`, con tres catálogos de tipo que no se hablaban. El agrupador de casos necesitaba tres adaptadores y la evidencia de un caso tenía tres llaves, de las que solo una podía ir llena. Ahora todo es una señal en `senal_fraude`, una fila por tipo y clave, con catálogos de familia, fuente, tipo y rol, y pivotes para las cuentas, reseñas, productos, pedidos e IP. El caso y el aviso al usuario cuelgan de la señal con una sola llave.

- Dónde se ve. `migrations/031_senales_fraude.sql`, las tablas y la copia de lo que había. `migrations/032_evidencia_y_aviso_por_senal.sql` y `migrations/033_sin_llaves_viejas_de_fraude.sql`, la evidencia y las notificaciones. El diseño por etapas en `backend/elementos Generales/plan pendiente/refactor-fraude-senales.md` y el resumen en `docs/base-de-datos.md`, sección Un solo modelo de señales de fraude.
- Lo que pide el profesor. Lo pidió en la revisión del 28-09, decisiones menos genéricas en el fraude (`docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md` sección 1).
- Ojo si preguntan por las tablas viejas. Siguen en la base, sin escrituras. No se borraron porque las migraciones viejas se vuelven a correr en cada arranque y las volverían a crear vacías; borrarlas es una decisión aparte.
- Por qué así. La detección del detector y la revisión del admin quedan en fechas distintas, `ultima_deteccion` y `fecha_actualizacion`. Un mismo patrón visto diez veces es una fila con diez detecciones, no diez filas que el agrupador contaba como evidencia distinta.

### 123. ¿Cómo consigue cada reseña su vector?
Por una cola en PostgreSQL, igual que el grafo. La tabla `evento_comentario` la llenan dos triggers en la misma transacción que el comentario o la reseña, con una sola fila pendiente por comentario. Un worker del backend cada 10 segundos toma las pendientes, mira si el comentario todavía existe, le pide el vector a Ollama solo si el texto cambió y lo guarda en `vector_comentario` de PostgreSQL, o lo quita si ya no existe. Hasta el 16 de octubre lo escribía en el índice `mesh_comentarios` de Elasticsearch.

- Dónde se ve. `migrations/034_evento_comentario.sql`, la cola y los triggers. `migrations/040_vectores_en_postgres.sql`, la tabla. `backend/src/services/resenas/evento-comentario-sync.service.ts`, el worker. En `arrancar.ps1`, el paso Vectores de los comentarios encola todo una vez si la tabla está vacía (así se pasaron los 700 comentarios de Elasticsearch a PostgreSQL) y borra el índice viejo.
- Por qué así. Un like no encola nada, porque el trigger solo mira la columna del texto. Las respuestas cortas, de menos de 15 letras, se quedan sin vector. Tabla aparte y no una columna en `comentario`: si el worker escribiera en la misma fila, el trigger lo volvería a encolar.

### 124. ¿Qué señales de fraude salen del texto de las reseñas?
Cuatro familias, todas con los vectores de `vector_comentario` y en la tabla de señales. `resenas_repetidas`, una cuenta con 5 o más reseñas que tienen una gemela suya y el 30 % o más de las que escribe. `anillo_de_texto`, tres o más cuentas con reseñas casi iguales sobre el mismo vendedor. `resenas_parecidas_vendedor` y `_producto`, muchas reseñas con una gemela de otra cuenta. Y las `notas_incoherentes`, que usan el clasificador de la pregunta 125. Una gemela es otra reseña con coseno de 0,92 o más; solo cuentan las de más de 100 caracteres.

- Dónde se ve. `migrations/035_senales_fraude_por_texto.sql` y `migrations/038_senales_resenas_parecidas.sql`, los tipos. Los detectores en `backend/src/services/fraude/`, uno por familia, cada 15 minutos. El panel de Fraude del admin las enseña con su nombre.
- Por qué así. El grafo de Neo4j ve quién reseña a quién; esto ve lo que dicen. Las de cuenta son por porcentaje y no por cantidad, porque quien escribe mucho repite alguna frase por casualidad.
- Ojo si preguntan si dan falsos positivos. Se midió sembrando las 480 reseñas del clasificador en 40 cuentas: ninguna sale en una señal. Las dos cuentas compradoras de la semilla vieja sí salen en `resenas_repetidas`, y con razón: sus reseñas salen de 20 textos que se repiten.

### 125. ¿Qué hace el clasificador de reseñas y cómo se entrenó?
Lee el texto de una reseña y da la probabilidad de que sea mala. Son dos modelos hechos a mano con numpy sobre el vector de Ollama, una regresión logística y una red de 768 entradas, 32 neuronas y una salida. Se entrenaron con 400 reseñas escritas a mano, y se probaron con otras 80 difíciles que nunca se usaron para aprender: la red acierta el 91,2 % y la regresión el 90 %. Con eso el backend marca la nota incoherente, un texto malo con 4 o 5 estrellas o uno bueno con 1 o 2, y la cuenta por cuenta, producto y vendedor.

- Dónde se ve. `clasificador-resenas/`, los datos, el entrenamiento y `modelo/reporte.txt`. `predecir.mjs`, la misma cuenta en JavaScript, que da lo mismo que Python. El backend usa la regresión en `backend/src/helpers/valoracion-texto.ts` y guarda la valoración en `vector_comentario` (hasta el 16 de octubre, en `mesh_comentarios`). `migrations/037_senales_notas_incoherentes.sql`, los tres tipos. `pruebas/clasificador_en_postgres.mjs` comprueba que el vector guardado es el del entrenamiento (391 de 480 idénticos, el resto con coseno 0,999998) y que `prob_mala` es la que da el modelo del backend.
- Ojo si preguntan por sus límites. No entiende el sarcasmo (0 de 3), porque lee palabras. Por eso la señal va al admin y nunca bloquea sola.
- Ojo si preguntan de dónde salen las reseñas de la tienda. Las mismas 480 están sembradas como reseñas de verdad, de 40 cuentas con su compra pagada, cada una en el producto del que habla su texto (`clasificador-resenas/semilla/`).

### 126. ¿Qué es la búsqueda por intención?
Buscar por lo que la persona quiere lograr y no por el nombre del producto. "Algo para salir a pedalear" no es el nombre de nada, pero la reseña de unos guantes de ciclismo habla de eso. La frase se convierte en vector y se buscan las reseñas y los productos más parecidos, y cada resultado trae la reseña que lo explica.

- Dónde se ve. `GET /buscador/productos/intencion` en el backend. En `/buscar`, cuando lo escrito parece una frase, sale arriba la sección Lo que cuentan otros compradores.
- Por qué así. Las reseñas hablan como alguien que usó el producto y la descripción habla como vendedor, así que para una intención las reseñas encuentran mejor.

### 127. ¿Qué cambió en el buscador y en las reseñas el 4 de octubre?
El buscador dice "Tal vez quisiste decir" cuando una palabra está mal escrita, con el sugeridor de términos de Elasticsearch en la misma consulta. Y el texto de una reseña pasó a ser de 40 a 350 caracteres, y el de una respuesta de hasta 350, sin mínimo.

- Dónde se ve. `backend/src/helpers/correccion-busqueda.ts` y `validaciones-resena.ts`. En el frontend, `/buscar` y el formulario de reseñas, con su contador.
- Por qué el mínimo. El clasificador no sirve con textos muy cortos. Las señales de texto solo miran reseñas de más de 100 caracteres.

### 128. ¿Qué es la búsqueda híbrida y por qué combina por posición?
Junta en una sola lista la búsqueda por palabras y la búsqueda por significado. "labtop gamer" encuentra por las palabras aunque esté mal escrito, y "algo para escuchar música mientras corro" encuentra por el significado. Es la lista de `/buscar` cuando no hay filtros elegidos.

- Dónde se ve. `GET /buscador/productos/hibrida` en el backend. En vivo, `.\demo-entrega-final.ps1 -Parte hibrida`, que enseña el lugar de cada producto en las dos búsquedas.
- Por qué por posición. La relevancia de las palabras y el coseno están en escalas distintas y no se pueden sumar. Se usa RRF: cada búsqueda aporta uno entre sesenta más su posición, y un producto que sale bien en las dos sube. Si Ollama no contesta, la lista sale solo con las palabras y no se cae.
- Ojo si preguntan por los filtros. Con un filtro elegido manda la búsqueda facetada, que es la única que sabe filtrar y la que registra la búsqueda para las tendencias.

### 129. ¿Cómo se evita que un vendedor proponga un producto que ya existe?
Al escribir el nombre del producto que va a proponer, el formulario le dice en qué categoría suele ir algo así y qué productos parecidos ya hay, y marca los que pueden ser el mismo. El nombre se vuelve vector y se miran los 30 productos activos más cercanos: sus categorías votan, ponderadas por el parecido.

- Dónde se ve. `POST /vendedor/productos/sugerencias` en el backend y el formulario de proponer en el panel del vendedor. En vivo, `.\demo-entrega-final.ps1 -Parte sugerencias`.
- Por qué así. Es una ayuda y no un bloqueo: la decisión es de quien propone. Se pide al terminar de escribir y no en cada tecla, porque cada llamada le pide un vector a Ollama.

### 130. ¿Qué pasa si alguien reseña y después cancela la compra?
Antes la reseña se quedaba y nadie lo veía. Ahora es una señal. Una reseña de 4 o 5 estrellas con la compra cancelada después, dentro de 72 horas, basta para la señal `resena_positiva_cancelada`, que es fuerte y entra a los casos. Cinco o más de 1 o 2 estrellas contra el mismo vendedor dan `resenas_negativas_canceladas_vendedor`, con el vendedor como víctima.

- Dónde se ve. `migrations/039_senales_resenas_canceladas.sql`, la fuente `postgres` y los dos tipos. El detector en `backend/src/services/fraude/resenas-canceladas-detector.service.ts` cruza el kardex de devoluciones con la reseña. En vivo, `.\demo-resenas-texto.ps1 -Caso cancelada` y `-Caso negativas`.
- Por qué al cancelar y no al reseñar. Al escribir la reseña la cancelación todavía no pasó. Se revisa en cuanto se cancela, y la señal sale en unos 3 segundos.
- Ojo si preguntan cómo evitarlo. Pedir que el pedido esté entregado para reseñar lo cerraría de raíz, porque un pedido entregado ya no se cancela. Queda como mejora.

### 131. ¿Las señales de texto esperan 15 minutos?
No. Al escribir una reseña el backend la indexa, la valora y la evalúa en las señales de texto en ese momento, sin hacer esperar a quien la escribe, y el worker de cada 15 minutos recoge lo que haya fallado. Medido en la demo, las señales salen a los 3 o 4 segundos.

- Dónde se ve. `backend/src/services/fraude/chequeo-texto-inmediato.service.ts`. En vivo, `.\demo-resenas-texto.ps1`, que dice cuántos segundos tardó cada señal.

---

## Parte 9. Lo que cambió el 16 y 17 de octubre

Lo de 25f0fe0 de Jose David, a pedido del profesor, con las migraciones 040 a 045. Todo probado el 18 de octubre en la base local, con el backend real.

### 132. ¿Qué pasa si Redis se cae en plena compra?
Se compra igual. Desde el 17 de octubre el carrito de verdad es el pedido `pendiente` de PostgreSQL, así que con Redis caído el backend lee el carrito y lo compra directo ahí, sin el candado de Redis: el `SELECT ... FOR UPDATE` del pedido evita el doble cobro. La venta relámpago también sigue vendiendo: PostgreSQL reserva solo, con el mismo control de unidades, y la reserva queda sin ticket hasta que Redis vuelve.

- Dónde se ve. `pruebas/falla_checkout.sh`, 32 OK: con Redis parado compra, con MongoDB parado compra, con PostgreSQL parado no, y en los tres nada queda a medias. `docs/CONSISTENCIA-CHECKOUT.md`, sección 0 bis.
- Lo que pide el profesor. Entrega 3, estrategia de consistencia y prueba de falla simulada, y su directiva de que Redis nunca sea la verdad.
- Ojo si preguntan por lo que no se cubre. `SesionGuard` mira PostgreSQL en cada petición con sesión, así que con PostgreSQL caído nada con sesión responde. Es un control de seguridad de todo el backend y se dejó así.

### 133. ¿Dónde viven las reservas de una venta relámpago?
En dos lugares con roles distintos. Redis decide primero con su script Lua, atómico, y rechaza al que llega tarde sin bloquear a nadie. La reserva de verdad queda en `reserva_venta_relampago` de PostgreSQL, con su ticket, su vencimiento de 15 minutos y su estado (`activa`, `confirmada`, `devuelta`, `vencida`). Si Redis pierde la venta, `ReservasVentaRelampagoSyncService` la reconstruye desde PostgreSQL con la operación `restaurar`.

- Dónde se ve. `migrations/045_carrito_en_postgres.sql`. `redis/inventario_limitado.lua`, la rama `restaurar`, y `redis/prueba_restaurar.sh`, 20 OK contra el script provisional de David. `pruebas/oferta_limitada.sh`, 33 OK: 60 cuentas sobre 20 unidades, y PostgreSQL registró las 40 reservas de las dos olas, todas con su ticket, y las devolvió al cerrar la venta.
- Por qué así. Abrir la venta con `restaurar` y no con `sembrar` sigue numerando los tickets desde el más alto de la historia, así que un ticket viejo de un carrito nunca choca con el de otra persona.

### 134. ¿Para qué se metieron las compras al grafo?
Para que cada base resuelva lo suyo. "Para ti" (lo que compraron quienes compraron lo mismo que tú) es un recorrido de dos saltos desde una cuenta, la pregunta típica de un grafo. Cada línea comprada es un nodo `:Compra`, `(:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)`, y "para ti" y "también compraron" se leen de Neo4j en vivo. Antes "para ti" salía de las vistas en ClickHouse cada 15 minutos.

- Dónde se ve. `migrations/041_grafo_compras.sql`, la cola `evento_grafo_compra` por cuenta y sus triggers. `neo4j/001_esquema.cypher`, la restricción `compra_id`. `pruebas/grafo_compras.sh`, 30 OK: las compras llegan al grafo en segundos, para ti y también compraron dan lo que deben, con Neo4j parado el pedido se cobra igual y se proyecta al volver, y cancelar se lleva las compras.
- Por qué así. Mismo patrón que las reseñas: el pedido commitea sin esperar a Neo4j y un worker proyecta. La cola va por cuenta y no por pedido, así un pedido nuevo, uno cancelado o uno borrado se resuelven igual.

### 135. ¿Qué es el buscador de ofertas?
Que un vendedor encuentre "la laptop de 16 GB" entre sus 2000 ofertas escribiéndolo, aunque lo escriba mal. Es un índice propio en Elasticsearch, `mesh_ofertas`, con un documento por oferta. Lo mantiene una cola, `evento_oferta`, con triggers en la oferta y en lo que la rodea: el nombre del producto, la variante y el nombre y estado del vendedor. La ruta trae además un resumen con agregaciones sobre todo lo que cumple la búsqueda.

- Dónde se ve. `migrations/043_evento_oferta.sql`, `elastic/004_ofertas.json`, `GET /vendedor/ofertas/buscar`, y en el panel del vendedor el bloque Buscar ofertas. `pruebas/ofertas_y_seguimientos.sh`, 56 OK, incluye renombrar y suspender al vendedor y apagar Elasticsearch.
- Lo que pide el profesor. Darle más uso a Elasticsearch (16 de octubre).

### 136. ¿Qué es el "avísame" y por qué usa un percolator?
El comprador pide que le avisen cuando llegue algo que buscó y no estaba, o cuando una variante baje de precio. Un percolator guarda CONSULTAS en vez de documentos: cada "avísame" es una consulta en `mesh_seguimientos`, y cada oferta que cambia se lanza contra todas. La primera que cumple genera un solo aviso y la consulta se borra. La verdad es `seguimiento_oferta` de PostgreSQL.

- Dónde se ve. `migrations/044_seguimiento_ofertas.sql` (`aviso_seguimiento_oferta.id_seguimiento` es UNIQUE: imposible avisar dos veces), `elastic/005_seguimientos.json`. En la app, el botón Avísame si baja de precio en la ficha, Avísame cuando llegue en una búsqueda sin resultados, y la pestaña Avisos del perfil con el número en la cabecera. `pruebas/ofertas_y_seguimientos.sh` prueba una búsqueda que se cumple con una oferta nueva, el precio máximo que la frena y una baja de precio de verdad.
- Ojo si preguntan qué pasa si se pierde el índice. arrancar lo rehace y vuelve a cargar las consultas de los seguimientos vivos, armadas por PostgreSQL con la misma forma que el backend. Probado borrando el índice: las tres consultas volvieron idénticas.

### 137. ¿Qué son los combos y las búsquedas sin resultados?
Dos usos más de ClickHouse. Los combos son los grupos de 2 y 3 productos que más se compran en el mismo pedido, un conteo sobre todas las compras que un worker deja en Redis cada 30 minutos y la portada enseña como Se compran juntos. Las búsquedas sin resultados son lo más buscado que no dio nada, juntando las formas de escribir lo mismo: la columna `termino_normalizado` (minúsculas, sin tildes, sin espacios de más) la calcula ClickHouse sola en cada inserción, y los errores de tecleo se unen con distancia de edición.

- Dónde se ve. `GET /productos/combos` y `frontend/src/lib/EstanteCombos.svelte`. `clickhouse/001_esquema.sql`, la columna. `GET /admin/eventos/busquedas-sin-resultados`, en el panel de Tendencias, Señales, Lo que no tenemos. `pruebas/busquedas_sin_resultados.sh`, 13 OK: cuatro formas de escribir lo mismo y un error de tecleo salen como un grupo de 5 sesiones.
- De dónde salen los combos que se ven. De `semilla-combos/`, 18 pedidos de 2 y 3 productos que tienen sentido juntos (una laptop con su monitor y sus audífonos, el escritorio con su lámpara, el casco con los guantes y el candado) de 8 cuentas `combo1@mesh.com` a `combo8@mesh.com`, cada combo en 2 o 3 pedidos. Se compran con las mismas funciones de la aplicación, así que tienen pago, kardex y stock descontado, y llegan a ClickHouse por el ETL de compras y al grafo por la cola de la 041. Antes casi todos los pedidos eran de un solo producto y había 4 combos. arrancar la siembra en el paso 5d y no hace nada si las cuentas ya existen.
- Ojo si preguntan si eso es fraude. No: cada cuenta compra 2 o 3 veces con semanas de diferencia (la ráfaga pide 5 pedidos en 15 minutos), no hay devoluciones, reseñas ni logins, y la IP de las compras copiadas es la comodín que la consulta de IP compartida descarta. Medido con el backend corriendo, cero señales y cero casos con esas cuentas.
- Ojo si preguntan cómo se quita. `semilla-combos/quitar.sql` borra todo y deja anotados los pedidos en `pedido_quitado` (la 046); el ETL de compras los borra también de ClickHouse, porque desde PostgreSQL no se llega a ClickHouse. Antes ClickHouse se quedaba con las líneas de lo quitado y por eso las ventas no cuadraban.

### 138. ¿Qué se quitó del fraude el 17 de octubre y por qué?
Tres señales que no aportaban. La cadena abierta, porque una cadena A, B, C no concentra reputación en nadie y en los datos solo repetía anillos que ya salían. El favor devuelto, porque siempre salía sobre el mismo par que el mutuo: ahora las horas entre la ida y la vuelta van en el detalle del mutuo y suman como bono (+20 en menos de una hora). El carrito acaparador, porque con el carrito en PostgreSQL apartar sin comprar ya no retiene unidades. Además la granja de registros pasó a Elasticsearch, donde sí están los registros, y una IP compartida dejó de unir casos.

- Dónde se ve. `migrations/042_limpieza_fraude.sql` y `backend/elementos Generales/plan pendiente/limpieza-fraude.md`. `pruebas/anillos_familia_b.sh`, 40 OK: el favor devuelto sale como mutuo con 1 segundo entre ida y vuelta, y los tipos quitados dan 400. Las consultas viejas (`B1`, `B5`, `F4`, `F6`) quedan en el repositorio marcadas como fuera de uso.
