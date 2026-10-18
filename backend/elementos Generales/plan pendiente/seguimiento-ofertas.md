# Plan pendiente — Seguimientos de ofertas con percolator ("avísame")

> **Estado (2026-10-17): tablas, percolator, rutas y disparo HECHOS y probados en
> local (prueba ligera). Falta la migración real y el índice en `elastic/` (le
> tocan a quien lleva `migrations/` y `elastic/`), y la prueba a fondo.** Depende
> de `evento-oferta.md`: el disparo corre dentro del worker de ofertas.

## Qué es

El segundo uso nuevo de Elasticsearch que pidió el profesor: el **percolator**.
Una búsqueda normal guarda documentos y les lanza consultas; el percolator guarda
**consultas** y les lanza cada documento nuevo para ver a quién le interesa. Es
lo que usan las alertas de empleo, las búsquedas guardadas de los portales de
inmuebles o el "avísame cuando esté disponible" de las tiendas.

Aquí el comprador pide:

- **`busqueda`**: buscó, no encontró, "avísame cuando llegue", con o sin precio
  máximo.
- **`baja_precio`**: viendo una variante, "avísame cuando baje": solo la oferta de
  la tienda (`solo_tienda`) o la de cualquier vendedor.

## Decisiones (cerradas con el usuario)

- **Avisar a pedido, no en silencio.** El comprador lo pide; no se guardan
  búsquedas suyas sin que lo sepa (las búsquedas sin resultados ya están en
  ClickHouse).
- **Un solo disparo.** Cuando el percolator encuentra una oferta: se crea el
  aviso, se pone `fecha_cumplido` y se borra la consulta del percolator.
  `aviso_seguimiento_oferta.id_seguimiento` es UNIQUE, así que es imposible un
  segundo aviso aunque dos ofertas coincidan en el mismo lote (se queda la más
  barata). Si lo quiere otra vez, crea uno nuevo.
- **El seguimiento no se borra al cumplirse**, se marca: el aviso necesita saber
  qué se había pedido. Lo borra el comprador si quiere (el aviso se va con él).
- **El seguimiento guarda el par producto + variante; el aviso guarda la
  oferta.** Al comprador le interesa la variante al mejor precio de cualquiera; lo
  que la cumplió es una oferta concreta, que lleva directo a comprar.
- **`fecha_leida` y no un booleano**: NULL = no leído; marcar como no leído
  vuelve a NULL.
- **Nombres**: `tipo_seguimiento_oferta`, `seguimiento_oferta`,
  `aviso_seguimiento_oferta`, índice `mesh_seguimientos`. Se evitó "alerta" y
  "notificación" porque ya existen `alerta_fraude` y `notificacion_fraude`.

SQL de referencia, aplicado en local: `seguimiento-ofertas.sql`.
Mapping de referencia: `seguimientos-indice.json` (los campos de
`ofertas-indice.json` + `consulta` de tipo `percolator` + `nombre_completo`, que
junta producto y variante con `copy_to` para que "laptop 16 gb" coincida aunque
las palabras estén en los dos).

## Las consultas guardadas

Las dos piden que la oferta se pueda comprar: `estado = activa`, `stock > 0`,
`estado_variante = activa`, `estado_vendedor = activo`.

- `busqueda`: `match` sobre `nombre_completo` con `operator: and` (todas las
  palabras) y `fuzziness: AUTO`; con precio máximo, `precio_final <= X`.
- `baja_precio`: esa variante, `precio_final < precio_referencia`; con
  `solo_tienda`, `id_vendedor` = la tienda. Sin referencia del comprador, se toma
  el precio final más bajo al crearlo (de la tienda si `solo_tienda`).

**Solo avisa cuando una oferta cambia** (alta, precio, descuento, stock, estado, o
los nombres): el percolator corre en el worker. Una oferta que ya cumplía al
crear el seguimiento y nunca se mueve no avisa. Para `busqueda` es lo esperado
(se crea justo porque no había nada); para `baja_precio` la referencia por
defecto es el mínimo actual, así que tampoco hay caso.

## Backend (HECHO)

- `services/compradores/seguimientos-oferta.service.ts` — crear, listar, borrar,
  avisos y marcar. Crear y borrar: PostgreSQL (sin COMMIT) → Elasticsearch →
  COMMIT; si Elasticsearch falla, ROLLBACK; si el COMMIT falla al crear, se borra
  la consulta (compensación). Tope de 20 seguimientos vivos por comprador.
- `services/compradores/percolar-seguimientos.service.ts` — una consulta
  `percolate` con todas las ofertas del lote, y por cada coincidencia: aviso +
  `fecha_cumplido` en una transacción, luego borrar del percolator.
- `services/vendedores/evento-oferta-sync.service.ts` — llama a percolar
  **antes** de marcar las ofertas como procesadas: si percolar falla, la corrida
  se repite y no se pierde ningún aviso.
- `controllers/compradores/seguimientos-oferta.controller.ts`,
  `dto/seguimientos-oferta.ts`, `helpers/validaciones-seguimiento.ts`,
  `helpers/cuenta-tienda.ts` (el id de la tienda por correo, compartido con el
  buscador de ofertas).
- Variable `ELASTIC_INDICE_SEGUIMIENTOS` (por defecto `mesh_seguimientos`) en
  `.env.example`.
- Rutas documentadas en `endpoints/endpoints-compradores.md`.

## Le toca a otros (no tocar desde backend/)

- **Migración real**, después de la de `evento_oferta`: el contenido de
  `seguimiento-ofertas.sql`.
- **`elastic/`**: `seguimientos-indice.json` como `005_seguimientos.json`, creado
  al arrancar (hoy se creó a mano con
  `curl -X PUT localhost:9200/mesh_seguimientos --data-binary @seguimientos-indice.json`).
  Ojo: si se reconstruye el índice, las consultas guardadas se pierden. Habría
  que volver a cargarlas desde `seguimiento_oferta` (las vivas); hoy no hay un
  script para eso.
- **Frontend**: el botón "avísame" cuando la búsqueda no trae nada, el de "avísame
  si baja" en la ficha, y la lista de avisos con su contador de no leídos.

## Probado en local (ligero) — 2026-10-17

Ver la tabla en `endpoints/endpoints-compradores.md`. Resumen: la búsqueda se
cumple al activar una oferta que coincide; el precio máximo y `solo_tienda`
filtran bien; tocar dos veces la misma oferta da un solo aviso; el percolator
queda vacío al borrar.

**Falta la prueba a fondo:** producto nuevo que llega, baja de precio real,
Elasticsearch caído al crear o al percolar, y reconstruir el índice.
