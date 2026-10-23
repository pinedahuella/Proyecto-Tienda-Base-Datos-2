# Registro unico de decisiones

Cada entrega numero sus decisiones por su cuenta y los numeros chocaron: en
`docs/base-de-datos.md` el ADR-3 es el de las imagenes, y en el informe de la
Entrega 2 el ADR-3 es grafos contra columnar. Desde el 23 de octubre de 2026 hay
un solo registro, numerado en el orden en que se tomaron las decisiones. Esta es
la lista. Cada una esta escrita completa, con contexto, alternativas, decision,
justificacion y consecuencias, donde dice la ultima columna, y las 15 a 23 estan
en la seccion 5 del informe de la Entrega final.

La columna "Antes" dice como se cito cada una en los informes ya entregados, para
poder seguirla.

| Id | Decision | Cuando | Estado | Antes | Escrita completa en |
|---|---|---|---|---|---|
| ADR-1 | El catalogo de productos en MongoDB | Entrega 1 | Vigente | ADR-1 | `docs/base-de-datos.md` |
| ADR-2 | Las ofertas, el stock y el dinero se quedan en PostgreSQL | Entrega 1 | Vigente | ADR-2 | `docs/base-de-datos.md` |
| ADR-3 | Las imagenes, embebidas en su variante | Entrega 1 | Vigente | ADR-3 | `docs/base-de-datos.md` |
| ADR-4 | Quien propuso un producto se guarda en PostgreSQL | Entrega 1 | Vigente | ADR-4 | `docs/base-de-datos.md` |
| ADR-5 | Resenas, comentarios y likes se quedan en PostgreSQL | Entrega 2 | Vigente | ADR-5 | `docs/base-de-datos.md` |
| ADR-6 | El carrito en Redis con vencimiento | Entrega 2 | Revisada por ADR-21 | ADR-4 del informe de la Entrega 2 | Informe de la Entrega 2, 2.1 |
| ADR-7 | La oferta limitada con un script Lua en Redis | Entrega 2 | Vigente, la reserva tambien en PostgreSQL desde ADR-21 | ADR-5 del informe de la Entrega 2 | Informe de la Entrega 2, 3.1 |
| ADR-8 | Grafos contra columnar, decision del 3 de septiembre | Entrega 2 | Reemplazada por ADR-10 el 6 de septiembre | ADR-3 del informe de la Entrega 2 | `docs/DECISION-GRAFOS-VS-COLUMNAR.md` |
| ADR-9 | Neo4j para los anillos de resenas | Entrega 2 | Vigente, ampliada por ADR-19 | ADR-7 del informe de la Entrega 2 | Informe de la Entrega 2, 5.1 |
| ADR-10 | ClickHouse para eventos y tendencias | Entrega 2 | Vigente | ADR-6 del informe de la Entrega 2 | Informe de la Entrega 2, 6.1 |
| ADR-11 | Elasticsearch para la busqueda del catalogo | Entrega 3 | Vigente, ampliada por ADR-20 y ADR-23 | ADR-9 del informe de la Entrega 3 | Informe de la Entrega 3, 2.1 |
| ADR-12 | Los pagos se quedan en PostgreSQL y no van a NewSQL | Entrega 3 | Vigente | ADR-8 del informe de la Entrega 3 | `docs/DECISION-NEWSQL-PAGOS.md` |
| ADR-13 | Los vectores en pgvector, con dos revisiones | Entrega final | Vigente desde el 16 de octubre | ADR-10 | Informe de la Entrega final, 2.1 y 2.2 |
| ADR-14 | Control de acceso por servicio en cada base | Entrega final | Ampliada el 23 de octubre | ADR-11 | Informe de la Entrega final, 3.1, y `docs/SEGURIDAD.md` |
| ADR-15 | El registro de inicios de sesion en MongoDB con copia en Elasticsearch | 2026-09-10 | Vigente | sin registro | Informe de la Entrega final, 5.2 |
| ADR-16 | El vencimiento de los descuentos en PostgreSQL | 2026-09-26 | Vigente | sin registro | Informe de la Entrega final, 5.2 |
| ADR-17 | Un solo modelo de senales de fraude | 2026-09-30 | Vigente | propuesta ADR-14 en `docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md` | Informe de la Entrega final, 5.2 |
| ADR-18 | Comprar sin MongoDB | 2026-10-01 | Vigente | propuesta ADR-12 | Informe de la Entrega final, 5.3 |
| ADR-19 | Las compras en el grafo de Neo4j | 2026-10-16 | Vigente | sin registro | Informe de la Entrega final, 5.4 |
| ADR-20 | El buscador de ofertas y los avisos con percolator | 2026-10-17 | Vigente | sin registro | Informe de la Entrega final, 5.4 |
| ADR-21 | La verdad del carrito y de las reservas en PostgreSQL | 2026-10-17 | Vigente | propuesta ADR-13 | Informe de la Entrega final, 5.4 |
| ADR-22 | Un respaldo por base, con cortacircuitos | 2026-10-20 | Vigente | sin registro | Informe de la Entrega final, 5.4, y `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md` |
| ADR-23 | La tarjeta del buscador sale entera de Elasticsearch, con su foto | 2026-10-23 | Vigente | sin registro | Informe de la Entrega final, 5.4 |

De las seis decisiones propuestas el 28 de septiembre en
`docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md`, tres se hicieron tal cual (ADR-17,
ADR-18 y ADR-21). Las detecciones como serie de tiempo en ClickHouse y el grafo
de identidad para armar los casos no se implementaron, y la busqueda hibrida
termino con el vector solo en pgvector (ADR-13).

La regla desde ahora: una decision nueva entra a esta tabla con el siguiente
numero, en el mismo cambio que el codigo que la implementa.
