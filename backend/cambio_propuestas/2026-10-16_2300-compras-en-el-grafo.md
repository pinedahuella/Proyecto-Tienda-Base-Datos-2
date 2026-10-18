# Las compras al grafo de Neo4j, y "para ti" desde el grafo

**Fecha:** 2026-10-16.
**Alcance:** `backend/`. En local, `plan pendiente/grafo-compras.sql` está
aplicado a mano (se pierde con `.\arrancar.ps1 -Reiniciar`). Lo de fuera de
`backend/` está en `plan pendiente/grafo-compras.md`.

## Qué se hizo

- Las compras pasan al grafo como ya pasaban las reseñas:
  un nodo `:Compra` por línea de pedido, `(:Usuario)-[:HIZO]->(:Compra)-[:DE]->(:Producto)`
  y `(:Compra)-[:A_VENDEDOR]->(:Usuario)` (la variante como propiedad), con su propio
  outbox (`evento_grafo_compra`, triggers en `pedido` y `pedido_producto`) y su
  worker (`GrafoComprasSyncService`).
- "Para ti" (`GET /productos/para-ti`) deja ClickHouse: ahora es lo que
  compraron las cuentas que compraron lo mismo que tú, consultado en vivo al
  grafo. Se borró `ParaTiSyncService`.
- La conciliación del grafo compara también las compras.
- Documentado en `endpoints-productos.md` y `endpoints-fraude.md`.

## Cómo se probó

Contra PostgreSQL, Neo4j, MongoDB y el backend reales, con la base local (61
cuentas con pedidos, 610 líneas compradas). Primero se probó con una relación
`COMPRO` por cuenta y producto; después se cambió a nodo `:Compra` y se repitió
lo principal (las filas marcadas con *).

| Qué | Resultado |
|---|---|
| * La siembra (61 cuentas) y una pasada del worker | 610 nodos `:Compra` (uno por línea comprada); la conciliación cuadra y `cola_compras` queda en 0 |
| * Cada `:Compra` contra PostgreSQL (cuenta, producto, vendedor, variante, cantidad) | las 610 idénticas |
| * "Para ti" de las 61 cuentas contra el mismo cálculo hecho en SQL sobre PostgreSQL | iguales en las 61 (productos, orden y `compradores`) |
| Que no recomiende algo ya comprado y que cada `porque_compraste` sí lo esté | se cumple |
| Cuenta sin compras / inexistente | `[]` |
| * Cancelar un pedido y volverlo a `comprado` | se van sus compras y la conciliación sigue cuadrando; al restaurarlo vuelven exactamente las mismas |
| Volver a encolar todas las cuentas | el grafo queda igual; sin `:Producto` duplicados |
| Neo4j apagado con un evento en la cola | queda pendiente sin gastar intentos; al volver, se proyecta |
| HTTP con la sesión de `comprador.sur@mesh.com` | `200`, 10 recomendaciones, 0.38 s |
| HTTP sin sesión / con Neo4j apagado / de vuelta | `401` / `503` "No se pudo conectar con Neo4j" / `200` sin reiniciar |

`npx tsc --noEmit` y `nest build` limpios. El pedido de la prueba de
cancelación quedó en su estado original.
