# GET /productos/vistos-recientemente (R1 de la propuesta de recomendaciones)

**Fecha:** 2026-09-25. Primera pieza construida del grupo "Recomendaciones"
de la propuesta del compañero (`docs/fraude-entrega3/03-consultas-clickhouse.md`,
R1-R4) -- las otras tres (R2, R3 aisladas por ahora sin caché; R4 apartada,
depende de Mongo) quedan para después. Antes de construir nada se
verificaron las tres primeras (R1, R2, R3) con datos sembrados aislados
corriendo el `.sql` del compañero directo contra ClickHouse (sin backend),
confirmando que cada una calcula exactamente lo que dice calcular.
**Alcance:** `backend/`, sin migración ni esquema nuevo.

## Decisión de diseño: sin caché

A diferencia de lo que sugiere el documento del compañero (Redis, por
cuenta, 10 min), esta ruta se dejó **sin caché** -- decisión del usuario,
confirmada tras discutir que R1 es barata (un filtro directo por
cuenta/sesión, sin cruzar con nadie más) y que la frescura importa: lo que
la persona acaba de ver tiene que aparecer ya, no hasta que expire un TTL.
R2/R3 sí quedaron con la sugerencia de caché para cuando se construyan --
ver la conversación, no se tocó nada de eso en esta ronda.

## Controller y servicio separados

`VistosRecientementeController`/`VistosRecientementeService` -- pedido
explícito del usuario, mismo criterio que `MasVendidosController`/`Service`
u `OfertasDestacadasController`/`Service`: cada feature del catálogo
público va aparte, aunque comparta el prefijo `/productos`.

## Cómo se resuelve "quién es la persona"

Reusa `idUsuarioDeCookieOpcional()` (ya existía, de
`POST /eventos/vista`/`GET /buscador/productos`): cuenta si hay sesión
válida, `null` si no -- nunca un 401. `sesion` viaja como query param
opcional, igual que `GET /buscador/productos`. `usuario = 0` es el
centinela de "no hay cuenta" que ya usa el resto de eventos (ningún id
real es 0). Sin cuenta NI `sesion`, la ruta devuelve `[]` sin tocar
ClickHouse -- no hay nada que preguntar.

## Verificación previa de R1/R2/R3 contra ClickHouse directo (sin backend)

Antes de escribir una sola línea de backend, se armó un escenario
coherente con un comprador ficticio ("Juan") y cinco sesiones ajenas, para
poder calcular las tres consultas a mano y confirmarlas:

- **R1**: Juan vio B (hace 1h, comprado) y A (hace 3h, no comprado) ->
  salió `990002 (comprado), 990001 (no comprado)`, orden y flag correctos.
- **R2** (producto A): dos sesiones ajenas vieron A y C -> afinidad
  `2/√(4×2) = 0.707`, calculado a mano y confirmado exacto. Otros dos
  productos con solo 1 sesión en común quedaron fuera (bajo el mínimo).
- **R3** (para Juan): semillas A y B con peso por decaimiento exponencial
  (vida media 72h) -> candidatos `990006 (1.401, vía B)` y
  `990003 (1.374, vía A)`, en ese orden exacto calculado a mano. Un cuarto
  producto con puntaje calculable se excluyó correctamente por estar ya
  comprado por Juan.

Los datos sembrados se borraron al terminar esa verificación
(`ALTER TABLE ... DELETE`), sin dejar nada en el repo -- fue una
verificación de las consultas, no una construcción de código.

## Qué se hizo (esta ronda: solo R1)

| Archivo | Qué es |
|---|---|
| `src/models/producto-visto-recientemente.ts` | nuevo -- `ProductoVistoRecientemente` |
| `src/dto/consultar-vistos-recientemente.ts` | nuevo -- `sesion`, `dias_historial`, `limite` |
| `src/helpers/validaciones-eventos.ts` | reusa `validarDiasVentana()`/`validarLimiteEvento()` (ya existían); docstring de `validarDiasVentana()` ampliado para dejar claro que ahora lo comparten tres rutas |
| `src/services/productos/vistos-recientemente.service.ts` | nuevo -- `listar()`: corta camino si no hay identidad, consulta ClickHouse (R1 tal cual), completa con Mongo |
| `src/controllers/productos/vistos-recientemente.controller.ts` | nuevo -- la ruta pública |
| `src/app.module.ts` | registra el controller y el servicio nuevos |
| `elementos Generales/endpoints/endpoints-productos.md` | nueva sección dedicada, con las pruebas |

## Probado en vivo -- 2026-09-25

Contra el servidor, ClickHouse y MongoDB reales:

| Caso | Resultado |
|---|---|
| Sesión real de `compradora_norte`, 2 vistas sembradas (productos 1 y 4, ambos ya comprados por ella -- el segundo fue un hallazgo real preexistente en la base, no algo sembrado en esta prueba) | orden correcto (más reciente primero), `ya_comprado: true` en las dos, confirmado contra `compra_producto` |
| Visitante sin cuenta, `?sesion=` de una sesión sembrada viendo un producto no comprado | trae ese producto, `ya_comprado: false` |
| Sin cuenta y sin `sesion` | `[]`, sin ninguna consulta a ClickHouse |
| ClickHouse real caído (`docker stop`) | `503` "No se pudo conectar con ClickHouse" |
| ClickHouse recuperado | `200` normal |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

Teardown: las filas sembradas se borraron con `ALTER TABLE ... DELETE`
(`vista_producto`, `compra_producto`); el pedido real preexistente de
`compradora_norte` que apareció durante la prueba se dejó intacto, no era
parte de esta ronda.

## Lo que queda pendiente del grupo de recomendaciones

R2 (también vieron), R3 (para ti, con caché de 10 min por cuenta) y R4
(similares, depende de que Mongo arme la lista de candidatos por categoría
y precio) -- ninguna construida todavía, quedan para cuando el usuario
decida seguir.
