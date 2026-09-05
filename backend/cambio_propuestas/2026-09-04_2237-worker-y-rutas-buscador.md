# Cambio: el worker del buscador y las dos rutas -- ya de punta a punta

**Fecha:** 2026-09-04, noche.
**Alcance:** solo `backend/`. No toca `mongo/`, `etl/` ni `elastic/`.
**Cierra el paso 2 y 3** de la serie que empezo en
`cambio_propuestas/2026-09-04_2124-pendiente-busqueda-cola-elastic.md`
(la bandera `pendiente_busqueda`) y siguio en
`2026-09-04_2208-elastic-indexar-todos-los-estados.md` (indexar todos los
estados). Con esto, el buscador de la Entrega 3 queda completo del lado de
`backend/`.

## Que se agrego

### El worker -- `BuscadorSyncService`

`src/services/buscador/buscador-sync.service.ts`. Mismo patron que
`GrafoSyncService` (`@Interval`, con una bandera para que una corrida lenta
no se pise con la siguiente), pero mas simple: como el indice ahora guarda
TODOS los estados, no hay que decidir entre "indexar" o "borrar" -- siempre
es la misma operacion.

Cada 10 s, hasta 200 por corrida:

```
1. db.productos.find({ pendiente_busqueda: true })
2. por cada uno: elasticClient.index({ id, document }) -- crea o
   reemplaza, es la misma llamada para las dos cosas
3. si salio bien: $unset de la bandera en Mongo
4. si fallo (Elasticsearch caido, o ese documento en particular): se deja
   pendiente, se reintenta en la proxima corrida. No se pierde nada.
```

El documento que arma para Elasticsearch (`aDocumentoIndice`) es la MISMA
forma que ya arma `etl/extraer_busqueda.js` -- mismos nombres de campo,
mismo tratamiento de `Decimal128` y de las variantes. Si esa forma cambia
algun dia, hay que cambiar las dos a la par (esta anotado en el codigo).

### Las dos rutas -- `BuscadorProductosController` / `Service`

`GET /buscador/productos` (publica) dejo de ser una consulta directa: ahora
envuelve el `multi_match` en un `bool` con `filter: [{ term: { estado:
"activo" } }]`, fijo en el codigo -- no es un query param, no se le puede
pedir lo contrario.

`GET /buscador/productos/admin` (nueva) es la misma consulta, sin ese
filter. Protegida con `SesionGuard` + `@Roles(ID_ROL_ADMIN)`, igual que
`GET /admin/fraude/anillos` -- ni la tienda, es un vendedor mas.

Las dos comparten un metodo privado (`ejecutar`) para no duplicar la
construccion del `multi_match`; lo unico que cambia entre una y otra es si
se agrega el filtro. La respuesta de las dos ahora trae `estado` (antes no
estaba, porque hasta el cambio anterior siempre iba a decir "activo" y no
aportaba nada).

## Probado en vivo, contra el servidor real y las dos bases

**El worker se valido solo, sin que se le pidiera:** apenas compilo y
arranco, encontro dos productos que habian quedado con
`pendiente_busqueda: true` de pruebas anteriores y los sincronizo
(`[BuscadorSyncService] worker del buscador: 2 producto(s)
sincronizados`, en el log). Se volvio a probar a proposito: se edito un
producto, se confirmo la bandera en `true`, se esperaron 12 s sin tocar
nada, y la bandera ya no estaba.

**Las dos rutas, con un producto de prueba en `inactivo`:**

```
publica, sin sesion, buscando el producto inactivo   -> [] (no aparece)
publica, sin sesion, buscando algo activo ("labtop")  -> 9 resultados, igual que antes
admin, sin sesion                                     -> 401
admin, con sesion de tienda (vendedor, no admin)      -> 403
admin, con sesion de admin@mesh.com                   -> lo encuentra, con "estado":"inactivo"
```

`npx tsc --noEmit`, `eslint` y `prettier --check` limpios en los cinco
archivos tocados. El producto de prueba y su documento en Elasticsearch se
borraron al terminar; el indice volvio a 102.

## Un efecto colateral bueno, y uno a vigilar

**Bueno:** como el worker corre solo (`@Interval`), no hizo falta escribir
ningun script de prueba aparte para validarlo -- las pruebas de las rutas
de arriba (crear/editar productos por la API) lo ejercitan solo, de fondo,
mientras el backend esta arriba.

**A vigilar:** el worker asume que Elasticsearch existe y que el indice
`mesh_productos` ya fue creado al menos una vez (por
`etl/cargar_busqueda.sh`). Si alguien levanta el backend contra una base
nueva sin haber corrido el ETL de busqueda todavia, el primer intento de
`elasticClient.index()` va a fallar (indice inexistente) y esos productos
se quedan pendientes -- se resuelven solos en cuanto el indice exista,
sin intervencion.

## Lo que queda

Del lado del compañero, sigue pendiente lo que ya decia
`2026-09-04_2208-elastic-indexar-todos-los-estados.md`:

1. El cambio de una linea en `etl/extraer_busqueda.js` (quitar el
   `FILTRO = { estado: 'activo' }`), para que una reconstruccion completa
   del indice tambien traiga todos los estados -- hoy eso solo lo logra el
   worker, producto por producto, a medida que se editan.
2. Actualizar la parte 4 de `pruebas/busqueda.sh` (el rechazado ya no va a
   dar 404 en Elasticsearch -- ahora hay que probar que la ruta PUBLICA del
   backend no lo devuelva, no que el indice no lo tenga).

Del lado de `mongo/` (tambien del compañero, informativo): el indice
parcial sobre `pendiente_busqueda` que evita que el worker recorra el
catalogo entero en cada corrida -- ver el bloque final de
`2026-09-04_2124-pendiente-busqueda-cola-elastic.md`. No es urgente con el
tamano actual del catalogo (102 productos), pero si con miles.
