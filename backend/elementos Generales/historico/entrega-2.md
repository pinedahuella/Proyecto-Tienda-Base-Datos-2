# Hito: Entrega 2 cerrada (2026-09-23)

Entregada y sustentada. Percepcion del equipo (no una nota oficial verificada
en este documento): **~90%**.

## Lo que cubrio, del lado de `backend/`

Los 4 bloques que pedia `docs/BACKEND-PENDIENTE.md` para esta entrega,
completos:

- **Reseñas / comentarios / likes** — `controllers|services/resenas/`.
  Exige haber comprado y pagado al vendedor para reseñar; respuestas en un
  solo nivel, abiertas a cualquier usuario con sesion.
- **Carrito en Redis** — `controllers|services/carrito/`. HASH
  `mesh:carrito:<id_usuario>`, TTL de 24h de inactividad renovable,
  `POST /carrito/comprar` sobre `comprar_carrito()`.
- **Inventario limitado / venta relampago en Redis** — reserva atomica sin
  sobreventa bajo concurrencia, sin locks de aplicacion; candado de
  doble-submit del checkout aparte (`mesh:checkout:<id_usuario>`, Redis
  `SET EX 30 NX`).
- **Panel de fraude en Neo4j** — `GET /admin/fraude/anillos`, cuatro
  consultas Cypher (mutuo/ciclo/reiterado/direccion), solo admin.

Ademas: reportes de admin (`reservaciones`, `ventas`), y las conexiones
nuevas a Redis y Neo4j con sus health-checks (`GET /clave-valor`,
`GET /grafo`).

## Lo que se sumo despues, ya sobre la marcha

En las semanas siguientes al cierre del alcance minimo se construyeron,
tambien probados en vivo: fraude de login (contadores en Redis +
deteccion retrospectiva/geografica en Elasticsearch), el modulo de
anillos de fraude persistidos sobre reseñas, el buscador con
Elasticsearch, y los eventos de navegacion/ventas en ClickHouse (mas el
ranking de "mas vendidos" que consume de ahi). El detalle completo de
cada pieza esta en `endpoints/` y en `cambio_propuestas/`; el resumen
consolidado de todo el backend vive en la memoria de sesion
`estado-backend-tienda`.

## Pendiente que quedo fuera de esta entrega

Directiva verbal del profesor sobre `GET /admin/eventos/tendencias` y
`GET /admin/eventos/fraude/ip` (agregaciones especificas sobre
ClickHouse) — sigue sin construirse. Detalle en `estado-backend-tienda`.
