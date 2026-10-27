# La categoría en el grafo para "también compraron", y un ACL en la aplicación por oferta

**Fecha:** 2026-10-26, de 22:30 en adelante. Los dos los pidió Meme para la
presentación final. Migración nueva, la 049. Probado contra las bases de la PC de
Meme (locales). Sin commitear todavía.

## 1. Quienes lo compraron también llevaron, por grupos (ADR-25)

Antes ordenaba solo por cuántas cuentas compraron los dos productos. Ahora va por
grupos: primero SIEMPRE los de la misma categoría que el producto de la ficha,
después el resto, y dentro de cada grupo por compradores. En la ficha de una laptop,
otra laptop con 1 comprador sale antes que un teléfono con 4.

- `:Producto` lleva `id_categoria` (Integer) y `categoria` (el nombre), de
  `producto_catalogo` y `categorias`.
- Las escriben `GrafoComprasSyncService` y `GrafoSyncService` al proyectar (sus SQL
  hacen LEFT JOIN a `producto_catalogo` y `categorias`), y `etl/extraer_grafo.sql`.
- Nuevo `services/grafo/grafo-categorias-sync.service.ts`: al arrancar y cada 60 s
  lee todos los `:Producto`, los compara con PostgreSQL y corrige solo los que no
  coinciden (`MATCH`, nunca crea nodos). Rellenó los 102 nodos que había y recoge
  un cambio de categoría hecho por la API, que no pasa por ninguna cola del grafo.
- `CYPHER_TAMBIEN_COMPRARON`: `grupo` 0 si `rec.id_categoria = base.id_categoria`,
  1 si no (o si falta), `ORDER BY grupo, compradores DESC, id`. La respuesta suma
  `misma_categoria`.
- `tambienCompraronDesdePostgres` (sin Neo4j) ordena igual, con LEFT JOIN a
  `producto_catalogo`.

Medido: los 100 productos comprados dan exactamente la misma respuesta con Neo4j, con
Neo4j apagado y con MongoDB apagado. `pruebas/tambien_compraron_categoria.sh` 32 OK.
Rompiendo el orden en el Cypher y en el respaldo, la prueba da 8 FALLA.

## 2. ACL en la aplicación, por oferta (ADR-24)

El dueño de una oferta le da a otra cuenta de vendedor (o admin) permiso para verla,
editar su precio y su existencia, o poner y quitar su descuento. Lo que no está en
la lista se niega.

- **Migración 049** (`migrations/049_acl_ofertas.sql`): `tipo_permiso_oferta` (ver,
  editar, descuento), `permiso_oferta` (oferta, cuenta, permiso, quién lo dio, hasta
  cuándo; único por los tres, nadie a sí mismo) y `auditoria_permiso_oferta` (sin FK
  a propósito: es un registro).
- **`guards/permiso-oferta.guard.ts`** con `@PermisoOferta('editar')` y
  `@PermisoResuelto()` (`decorators/permiso-oferta.decorator.ts`). Va después de
  `SesionGuard`. Sin entrada vigente, 404 y una fila `negado` en el registro.
- **`services/acl/acl-ofertas.service.ts`**: `comprobar()` (la pregunta del guard),
  la lista y una oferta compartida, y repartir (`otorgar`, `revocar`, con su
  registro en la misma transacción).
- **Rutas nuevas**, las de `/vendedor/ofertas` NO cambian:

| Ruta | Permiso |
|---|---|
| `GET /compartidas/ofertas` | cualquier entrada vigente |
| `GET /compartidas/ofertas/:id` | ver (cualquier entrada) |
| `PATCH /compartidas/ofertas/:id` | editar; solo `precio` y `ajuste_stock`, `estado` da 400 |
| `POST /compartidas/ofertas/:id/descuento` | descuento |
| `DELETE /compartidas/ofertas/:id/descuento` | descuento |
| `GET /vendedor/ofertas/:id/permisos` | el dueño (o un admin, por la tienda) |
| `POST /vendedor/ofertas/:id/permisos` `{correo, permisos[], fecha_vencimiento?}` | el dueño |
| `DELETE /vendedor/ofertas/:id/permisos/:idPermiso` | el dueño |

- Las rutas compartidas llaman a `OfertasVendedorService.editar`, `aplicarDescuento`
  y `quitarDescuento` con el id del DUEÑO y el rol de vendedor, así que valen las
  mismas validaciones de siempre. Después anotan en el registro quién lo hizo.
- Registradas en `app.module.ts`: `PermisosOfertaController`,
  `OfertasCompartidasController` y `AclOfertasService`.

Medido: `pruebas/acl_ofertas.sh` 84 OK (sin permiso, cada permiso por separado,
quitar, vencer, admin, lo propio sin cambios, limpieza).
`pruebas/acl_ofertas_azar.mjs`, cientos de vueltas al azar contra un modelo. Rompiendo
la separación de permisos, 11 FALLA; rompiendo el vencimiento, 3 FALLA.

En el frontend: botón Compartir en cada oferta (`lib/CompartirOferta.svelte`) y la
sección Compartidas del panel (`lib/OfertasCompartidas.svelte`).
