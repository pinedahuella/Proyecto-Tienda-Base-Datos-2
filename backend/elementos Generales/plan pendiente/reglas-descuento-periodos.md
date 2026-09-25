# Reglas de descuento por período (calendario)

> **Estado: TERMINADA (iniciado 2026-09-23, CRUD + exclusión mutua +
> solape entre reglas propias + disparador terminados el 2026-09-24).**
> Tabla aplicada en la base LOCAL (`reglas-descuento-periodos.sql`, en esta
> misma carpeta). El CRUD completo (crear/listar/paginar/editar, incluye
> pausar vía `activa`) está construido y probado en vivo. Además:
> - Esta regla y las otras tres formas de descuento/venta relámpago
>   (descuento manual, venta relámpago manual, regla automática) son
>   mutuamente excluyentes entre sí -- ver la sección "Exclusión mutua..."
>   de `endpoints/endpoints-vendedores.md` y
>   `cambio_propuestas/2026-09-24_2300-exclusion-mecanismos-descuento.md`.
> - Varias reglas de período de la MISMA oferta pueden convivir activas,
>   pero se rechaza con 409 si sus rangos de días se solapan en algún día
>   real -- ver la sección "Solape entre reglas de período..." y
>   `cambio_propuestas/2026-09-24_2330-solape-regla-descuento-periodo.md`.
> - **El disparador real ya existe**: `DisparadorReglasPeriodoService`
>   (`@Interval`, 15 min) revisa la fecha de hoy contra las reglas activas
>   y prende/apaga el descuento o la venta relámpago de la oferta asociada,
>   reusando `OfertasVendedorService`/`VentasLimitadasService` -- ver "El
>   disparador de `regla_descuento_periodo`" de
>   `endpoints/endpoints-vendedores.md` y
>   `cambio_propuestas/2026-09-24_2359-disparador-reglas-periodo.md`
>   (incluye dos bugs reales encontrados y corregidos: el disparador se
>   rechazaba a sí mismo por el chequeo de exclusión mutua).
>
> No queda nada pendiente de esta feature en particular. El disparador de
> `regla_descuento_automatico` sigue bloqueado por el pendiente de "cuándo
> se activó" (ver `models/regla-descuento-automatico.ts`), pero es un
> pendiente de esa OTRA regla, no de esta.

Pedido del compañero del usuario (no del profesor): una segunda forma de
regla de descuento automático, además de `regla_descuento_automatico`
(que dispara por umbral de ventas en una ventana de tiempo, ver
`descuentos-oferta.md`). Esta dispara por **calendario**: un rango de
fechas que se repite con distintos niveles de granularidad según qué
campos se omiten.

## Decisión cerrada con el usuario (confirmada antes de tocar nada)

El rango de un período se arma con `dia_inicio`, `dia_fin`, `mes_inicio`,
`mes_fin` y **un solo** `anio` (no dos) — y la ausencia de un campo amplía
la repetición en cascada, de más específico a más general:

1. **Con `anio`** → ocurre una sola vez, en ese año exacto (ej: del
   2026-12-20 al 2026-12-31, no se repite).
2. **Sin `anio`** (pero con mes) → se repite cada año, en el mismo rango
   de día/mes de inicio y fin (ej: todos los 20-31 de diciembre, de
   cualquier año).
3. **Sin mes** (y por lo tanto sin `anio` — un año sin mes no tiene
   sentido) → se repite en todos los meses de todos los años, usando solo
   el rango de día (ej: día 1 al día 5 de cada mes).

Cuando la fecha de hoy entra en el rango que le corresponde a la regla
(según su nivel de repetición), se activa el descuento o la venta
relámpago asociado a la oferta; cuando sale del rango, se desactiva. A
diferencia de `regla_descuento_automatico`, aquí no hace falta
`duracion_segundos`: el propio período define cuándo termina.

## Esquema (tabla nueva, ya aplicada en local)

```sql
CREATE TABLE regla_descuento_periodo (
  id_regla_descuento_periodo BIGSERIAL PRIMARY KEY,
  id_oferta BIGINT NOT NULL REFERENCES oferta(id_oferta) ON DELETE CASCADE,

  dia_inicio SMALLINT NOT NULL CHECK (dia_inicio BETWEEN 1 AND 31),
  dia_fin SMALLINT NOT NULL CHECK (dia_fin BETWEEN 1 AND 31),
  mes_inicio SMALLINT CHECK (mes_inicio BETWEEN 1 AND 12),
  mes_fin SMALLINT CHECK (mes_fin BETWEEN 1 AND 12),
  anio INTEGER CHECK (anio BETWEEN 2000 AND 2100),

  es_venta_relampago BOOLEAN NOT NULL,
  porcentaje_descuento NUMERIC(5, 2) NOT NULL
    CHECK (porcentaje_descuento > 0 AND porcentaje_descuento < 100),
  activa BOOLEAN NOT NULL DEFAULT TRUE,

  fecha_creacion TIMESTAMPTZ NOT NULL DEFAULT now(),
  fecha_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),

  CHECK ((mes_inicio IS NULL) = (mes_fin IS NULL)),
  CHECK (anio IS NULL OR mes_inicio IS NOT NULL)
);
```

Notas de diseño sobre el esquema:

- **Sin `UNIQUE(id_oferta)`**, a diferencia de `regla_descuento_automatico`:
  una misma oferta puede tener varios períodos (por ejemplo, un período
  fijo de Black Friday 2026 Y un período mensual recurrente de "del 1 al
  5 de cada mes").
- Las dos `CHECK` de la parte de abajo son las que hacen cumplir la
  cascada: `mes_inicio`/`mes_fin` van siempre juntos (los dos nulos o los
  dos presentes), y `anio` no puede existir si no hay mes.
- No hay validación a nivel de base de que `dia_fin`/`mes_fin` sea
  "posterior" a `dia_inicio`/`mes_inicio`: un período puede cruzar el fin
  de año (ej: del 20 de diciembre al 5 de enero) o el fin de mes, así que
  esa comparación depende de la lógica de la aplicación, no de un CHECK
  simple.
- Mismo patrón que `regla_descuento_automatico`: FK a `oferta` con
  `ON DELETE CASCADE`, índice sobre `id_oferta` (`WHERE activa` para el
  caso de solo las activas), y el trigger compartido `oferta_tocar_fecha()`
  para `fecha_actualizacion`.

## Hecho (2026-09-24)

Modelo (`models/regla-descuento-periodo.ts`), los tres DTOs (crear/editar/
paginar), el helper de validaciones propio (`dia`/`mes`/`anio` y la
cascada -- reutilizando `validarIdOfertaCuerpo`/`validarEsVentaRelampago`/
`validarActiva` de `validaciones-regla-descuento.ts` y
`validarPorcentajeDescuento` de `validaciones-oferta.ts` tal cual, mismos
mensajes), y `ReglasDescuentoPeriodoController`/`Service` completos --
`POST`/`GET`/`GET .../paginado`/`PATCH :id` en
`vendedor/reglas-descuento-periodos`, mismo criterio de autorización que
`vendedor/reglas-descuento` (vendedor o admin, admin actúa como la tienda).

Un detalle que no estaba en el diseño de papel: en `PATCH`, la cascada se
valida contra el estado FINAL de la fila (lo que llega en la petición
mezclado con lo que ya tenía guardado), no solo contra los campos que
vienen en esa petición puntual -- así, editar solo `mes_inicio` sobre una
regla que no tenía mes rechaza con 400 aunque la petición nunca haya
tocado `mes_fin`, con el mismo mensaje que usa `crear()`. Probado en vivo
contra el servidor real (login, `curl`, Postgres) -- ver el detalle y la
tabla de casos en `endpoints/endpoints-vendedores.md`, sección "Reglas de
descuento por período / calendario". `tsc`/`eslint` limpios.

## Hecho, segunda ronda (2026-09-24, más tarde el mismo día)

**Exclusión mutua entre los cuatro mecanismos** (descuento manual, venta
relámpago manual, regla automática, regla de período) y **solape entre
reglas de período de la misma oferta** -- ver
`endpoints/endpoints-vendedores.md` y los `cambio_propuestas/` de
`2300-exclusion-mecanismos-descuento` y `2330-solape-regla-descuento-periodo`.

**El disparador real** (`DisparadorReglasPeriodoService`, `@Interval` cada
15 min) ya está construido, probado en vivo, y documentado en
`endpoints/endpoints-vendedores.md` ("El disparador de
`regla_descuento_periodo`") y en
`cambio_propuestas/2026-09-24_2359-disparador-reglas-periodo.md` -- incluye
dos bugs reales encontrados y corregidos (el disparador se rechazaba a sí
mismo por el propio chequeo de exclusión mutua, en dos formas distintas).
Reusa `OfertasVendedorService.aplicarDescuento()`/`quitarDescuento()` y
`VentasLimitadasService.abrir()`/`cerrar()` en vez de SQL propio.

`regla_descuento_automatico` sigue sin su disparador -- bloqueado por el
pendiente de "cuándo se activó" (es un disparo de una sola vez con
duración fija, no una condición de estado como la de período), no por
nada relacionado con lo de arriba.

No hay tampoco validación de que `dia_fin`/`mes_fin` sea "posterior" a
`dia_inicio`/`mes_inicio` en el CRUD -- un período puede cruzar fin de año
o de mes; el disparador ya construido no necesitó esa validación porque
compara contra la fecha de HOY, un solo día, no contra un rango.

**Le toca al compañero (fuera de `backend/`, workflow de siempre):**
convertir `reglas-descuento-periodos.sql` en la migración real, en el
orden que le corresponda después de la última migración existente.
