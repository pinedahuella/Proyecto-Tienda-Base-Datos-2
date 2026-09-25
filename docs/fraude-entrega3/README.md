# Fraude, tendencias y recomendaciones (propuesta para aprobar)

Este folder junta el diseno de tres cosas que se piden para la Entrega 3.

1. Consultas de Neo4j que buscan patrones de resenas mas complejos que el anillo cerrado. Cadenas que no se cierran, cuentas que califican al mismo vendedor mes tras mes, anillos que se reactivan con el tiempo y otros cuatro.
2. Las reglas que tendria que aplicar el backend para juntar las alertas en casos, ordenarlas por importancia y decidir cuales se tratan como fraude casi confirmado.
3. Consultas de ClickHouse para recomendaciones (vistos recientemente, quienes vieron esto tambien vieron, para ti, similares), para tendencias y para operaciones sospechosas.

Todo esta escrito y probado contra las bases levantadas el 2026-09-23. ~~El backend todavia no corre nada de esto. Por eso son propuestas y por eso las pruebas prueban el texto del repositorio y no una ruta HTTP.~~ Desde el 2026-09-24 el backend corre buena parte, y lo que falta sigue siendo propuesta.

## Lo que ya esta implementado

Lo conecto Jose David en los commits ad20dcd, 4e93bba y 99891a8. Sus notas estan en `backend/cambio_propuestas/2026-09-24_*` y `2026-09-25_*`.

| Pieza | Estado | Donde vive | Donde se ve | Prueba por HTTP |
|---|---|---|---|---|
| B.1 cadena abierta | Implementado | PatronesFraudeDetectorService, cada 15 min y al llegar una resena | panel, Fraude | `pruebas/anillos_familia_b.sh` (solo el filtro) |
| B.2 satelites | Implementado, solo el worker de 15 min | idem | idem | idem (solo el filtro) |
| B.3 persistente | Implementado | idem | idem | idem (solo el filtro) |
| B.4 anillo en el tiempo | **No**. Queda como consulta de diagnostico, el id 7 del catalogo reservado | `neo4j/consultas/B4_*` | no | `?tipo=anillo_en_el_tiempo` da 400 |
| B.5 favor devuelto | Implementado | idem | idem | `pruebas/anillos_familia_b.sh` |
| B.6 coordinados | Implementado. El vendedor no entra en las cuentas del caso | idem | idem | `pruebas/anillos_familia_b.sh` |
| B.7 reputacion expres | Implementado, solo el worker de 15 min | idem | idem | `pruebas/anillos_familia_b.sh` con `ESPERA_B7=960` |
| Tablas de B | Implementado | `migrations/023_anillos_fraude_familia_b.sql` | | |
| T1 en ascenso | Implementado | `GET /admin/eventos/tendencias` | panel, Tendencias, Señales | `pruebas/tendencias_avanzadas.sh` |
| T2 embudo | Implementado | `GET /admin/eventos/embudo` | idem | idem |
| T3 busquedas sin respuesta | Implementado | `GET /admin/eventos/busquedas-sin-respuesta` | idem | idem |
| R1 vistos recientemente | Implementado, sin cache | `GET /productos/vistos-recientemente` | portada | `pruebas/recomendaciones.sh` |
| R2 tambien vieron | Implementado, worker de 15 min a Redis | `GET /productos/:id/tambien-vieron` | ficha del producto | idem |
| R3 para ti | Implementado, worker de 15 min a Redis | `GET /productos/para-ti` | portada con sesion | idem |
| R4 similares | No. Depende de que Mongo arme los candidatos | | | |
| F1 a F6 operaciones sospechosas | No | | | |
| El agrupador de casos, el puntaje y R-CASI | No | `02-reglas-backend.md` | | |
| La migracion de casos | No. Era la 022, ahora la 024 | `02-reglas-backend.md`, seccion 7 | | |

Dos cosas que cambiaron al implementarlo y que este folder no decia:

- **Las consultas B del backend llevan ventana de 60 dias**, como A.1 y A.2. Las del repositorio no, y por eso B.3 y B.4 aqui ven la historia entera y alla no. B.4 se dejo fuera justo por eso.
- **Para ti vacio cae a lo mas visto.** La tabla de "Como las usaria el backend" (en `03-consultas-clickhouse.md`) proponia T1, pero T1 quedo solo para admin. Desde d1b670b hay una ruta publica, `GET /productos/mas-vistos`, y la portada la usa cuando para ti viene vacio, con el titulo "Lo mas visto".

## Los archivos

| Archivo | Que tiene |
|---|---|
| [01-consultas-neo4j.md](01-consultas-neo4j.md) | Las siete consultas nuevas de Cypher (B.1 a B.7), por que cada una, que encontraron en los datos reales y como se comprobaron contra PostgreSQL |
| [02-reglas-backend.md](02-reglas-backend.md) | Como se agrupan las alertas en casos, el puntaje, los niveles, las reglas de caso casi confirmado y un ejemplo con los datos de hoy |
| [03-consultas-clickhouse.md](03-consultas-clickhouse.md) | Las trece consultas de ClickHouse, como las usaria el backend y que encontraron |

El codigo vive donde vive el de cada base.

```
neo4j/consultas/B0_parametros.cypher      los umbrales de B.1 a B.7, en un solo lugar
neo4j/consultas/B1..B7_*.cypher           las siete consultas
neo4j/pruebas/siembra_patrones.sql        60 resenas de prueba, cada patron con su control
neo4j/pruebas/equivalentes.sql            las mismas siete preguntas escritas en SQL
neo4j/pruebas/comparar.py                 pone las dos salidas en el mismo formato
neo4j/correr_patrones.sh                  el arnes

clickhouse/consultas/parametros.txt       los umbrales de las trece
clickhouse/consultas/R*, T*, F*.sql       las trece consultas
clickhouse/pruebas/siembra_consultas.sql  los eventos de prueba, cada escenario con su control
clickhouse/pruebas/comprobar.py           las aserciones
clickhouse/correr_consultas.sh            el arnes
```

## Como se corre

Desde Git Bash, con las bases arriba (`.\arrancar.ps1`).

```bash
bash neo4j/correr_patrones.sh
bash clickhouse/correr_consultas.sh
```

Los dos terminan en `Todo bien.` o salen con 1 y dicen que fallo. Ninguno deja nada escrito. El de Neo4j siembra dentro de una transaccion de PostgreSQL que se deshace y despues borra del grafo lo que proyecto. El de ClickHouse siembra en una base aparte que crea y tira.

## Lo que salio al medir, en corto

- El detector de anillos del backend solo mira los ultimos 60 dias, y por eso ya no ve el anillo anillo.uno, anillo.dos y anillo.tres de marzo, el unico que se sembro en PostgreSQL como fraude de verdad. La consulta B.4 lo marca como invisible para el detector.
- Los dos compradores de la semilla califican a los mismos vendedores durante meses, con notas altas, y a primera vista parecen el peor caso. Lo que los separa de una cuenta que infla reputacion es que reparten sus resenas entre cinco vendedores, y con eso B.3 los deja fuera. B.6 tambien, porque coinciden en lo que compran pero casi nunca en el momento.
- 86 resenas de la semilla tienen fecha anterior al alta de su autor. Sin cuidar eso, los dos compradores salian como cuentas recien nacidas con menos 296 674 minutos de vida.
- En ClickHouse las compras que el ETL copia de PostgreSQL no traen IP y quedan con la IP vacia. Sin excluirla, cuatro cuentas aparecian compartiendo esa IP.
- Hoy hay 160 alertas de login pendientes y 9 anillos persistidos. Con las reglas propuestas, lo de resenas se junta en 9 casos casi confirmados, que son justo los anillos que dejan los arneses de prueba (dos de ellos se juntan en uno porque viven en la misma casa), y los compradores reales quedan sin ningun caso.
