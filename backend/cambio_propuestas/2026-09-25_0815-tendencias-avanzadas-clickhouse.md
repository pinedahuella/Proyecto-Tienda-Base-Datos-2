# Tres consultas de "Tendencias" de la propuesta de fraude, conectadas al backend (T1/T2/T3)

**Fecha:** 2026-09-25. Primer recorte, chico a propósito, de la propuesta
completa del compañero en `docs/fraude-entrega3/` (13 consultas de
ClickHouse + 7 de Neo4j + el agrupador de casos, todavía sin aprobar como
conjunto). El usuario pidió empezar solo por las tres que de verdad son
reportería (T1, T2, T3) -- las demás (R1-R4 recomendaciones, F1-F6
operaciones sospechosas) son otra cosa, quedan para después.
**Alcance:** `backend/`, sin migración ni esquema nuevo -- las tablas y la
vista materializada que usan ya existen.

## Qué se decidió, antes de tocar código

- **Controller y servicio SEPARADOS** de `AdminTendenciasController`/`Service`
  (pedido explícito del usuario) -- mismo prefijo de ruta (`/admin/eventos`)
  porque es el mismo dominio, pero clases distintas:
  `AdminTendenciasAvanzadasController`/`AdminTendenciasAvanzadasService`.
- **Los umbrales de cada consulta quedan fijos**, no configurables por query
  param -- los mismos valores que el compañero ya probó en
  `clickhouse/consultas/parametros.txt` (`min_vistas`, `min_crecimiento`,
  `min_sesiones_embudo`, `max_conversion`, `min_tasa_devolucion`,
  `min_sesiones_busqueda`). Solo quedan tunables las ventanas de días
  (`dias_recientes`/`dias_base` en tendencias, `dias_ventana` en las otras
  dos) y `limite`, mismo criterio que las seis rutas ya existentes.
- Las consultas SQL se copiaron **tal cual** de
  `clickhouse/consultas/T1_en_ascenso.sql`/`T2_embudo.sql`/`T3_busquedas_sin_respuesta.sql`
  -- ya vienen escritas con `{nombre:Tipo}`, el mismo formato que
  `query_params` del driver de Node, sin necesidad de reescribirlas.

## Por qué `GET /admin/eventos/tendencias` es una ruta especial

Es la ruta EXACTA que el profesor pidió el 2026-09-06 (directiva verbal,
`docs/BACKEND-PENDIENTE.md` de esa fecha) y que nunca se había construido
-- se reemplazó en su momento por el explorador genérico de
`AdminTendenciasController`. Con esta pieza queda cerrado ese pendiente
viejo, de paso.

## Qué se hizo

| Archivo | Qué es |
|---|---|
| `src/models/tendencia-avanzada.ts` | nuevo -- `TendenciaEnAscenso`, `TendenciaEmbudo`, `TendenciaBusquedaSinRespuesta` |
| `src/dto/consultar-tendencia-ascenso.ts` | nuevo -- query params de T1 (`dias_recientes`, `dias_base`, `limite`) |
| `src/dto/consultar-tendencia-ventana.ts` | nuevo -- query params compartidos de T2/T3 (`dias_ventana`, `limite`) |
| `src/helpers/validaciones-eventos.ts` | `validarDiasBase()` (defecto 21) y `validarDiasVentana()` (defecto 30) nuevos; reusa `validarDiasEvento()`/`validarLimiteEvento()` existentes para el resto |
| `src/services/admin/admin-tendencias-avanzadas.service.ts` | nuevo -- `enAscenso()`, `embudo()`, `busquedasSinRespuesta()` |
| `src/controllers/admin/admin-tendencias-avanzadas.controller.ts` | nuevo -- las tres rutas, mismo guard que `AdminTendenciasController` |
| `src/app.module.ts` | registra el controller y el servicio nuevos |
| `elementos Generales/endpoints/endpoints-eventos.md` | nueva sección dedicada, con las pruebas |

`enAscenso()`/`embudo()` reusan el mismo patrón de segunda consulta a
Mongo que `AdminTendenciasService.rankingPorProducto()` (sin filtrar por
estado, un id sin documento sale con `producto: null`, nunca se
descarta). `busquedasSinRespuesta()` no necesita Mongo -- el término ya es
todo el dato.

## Probado en vivo -- 2026-09-25

Contra el servidor y las bases reales (Postgres, ClickHouse, MongoDB,
Redis), con sesión real de `admin_mesh`:

| Caso | Resultado |
|---|---|
| Las tres rutas contra datos reales, sin sembrar nada | `tendencias`/`busquedas-sin-respuesta`: `[]` (pocos eventos reales, consistente con lo que el compañero ya había medido); `embudo`: 2 productos reales con `devolucion_alta` (Laptop Lienzo 15 1/1, Laptop Ambar Campus 14 5/15), con nombre y categoría resueltos desde Mongo |
| **T1 aislado**: producto ficticio, 25 vistas en 3 sesiones (últimos 7 días), 0 en los 21 anteriores | `por_dia_ahora: 3.6`, `por_dia_antes: 0`, `veces: 4.57`, `vistas_por_persona: 8.3` -- las cuatro verificadas a mano contra la fórmula |
| Control T1: producto ficticio con 5 vistas (bajo el mínimo de 20) | no aparece |
| **T2 aislado**: producto ficticio, 20 sesiones, 0 pedidos | `diagnostico: "mucho_interes_poca_compra"` -- caso que los datos reales no habían disparado |
| Control T2: producto ficticio, 20 sesiones, 1 pedido (conversión 5%) | no aparece |
| **T3 aislado**: término con 3 sesiones, 0 resultados siempre | `diagnostico: "no_tenemos"` |
| Término con 3 sesiones, resultados sin clics | `diagnostico: "no_convence"` |
| Control T3: término con 3 sesiones, resultados y 1 clic | no aparece |
| ClickHouse real caído (`docker stop mesh-clickhouse`) | `503` "No se pudo conectar con ClickHouse", resto de la app sin afectarse |
| ClickHouse recuperado | siguiente consulta `200` normal |
| `npx tsc --noEmit` y `npx eslint "src/**/*.ts"` sobre el repo completo | limpios |

**Bug de limpieza encontrado a mitad de las pruebas, no de las consultas
en sí:** al sembrar datos para T2 en `vista_producto`, esas mismas filas
alimentaron automáticamente `vistas_por_producto_dia` (la vista
materializada que usa T1) -- al limpiar solo la tabla base, dos productos
de la prueba de T2 quedaron viéndose como falsos positivos en
`tendencias`. Se corrigió borrando también de la tabla derivada. Anotado
para la próxima vez: sembrar en `vista_producto` obliga a limpiar TAMBIÉN
`vistas_por_producto_dia`.

Teardown completo verificado con un barrido final por los cuatro
ids/términos ficticios usados en la prueba: cero filas residuales en
ninguna de las tablas tocadas.

## Lo que queda pendiente de la propuesta completa

Las diez consultas restantes del compañero (R1-R4 recomendaciones, F1-F6
operaciones sospechosas), el agrupador de casos (`02-reglas-backend.md`) y
las rutas de recomendaciones/casos -- ninguna se tocó en esta ronda,
quedan para cuando el usuario decida seguir con la propuesta.
