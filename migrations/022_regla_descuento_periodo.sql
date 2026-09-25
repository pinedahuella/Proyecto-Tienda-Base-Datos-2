-- ============================================================
-- 022_regla_descuento_periodo.sql
-- ============================================================
-- La configuracion de los descuentos por PERIODO. Un vendedor le dice a una
-- oferta suya "del 20 al 31 de diciembre, rebajala X%", o "abre una venta
-- relampago" en vez de solo el descuento. A diferencia de la 021 (dispara por
-- ventas en una ventana), esta dispara por calendario.
--
--
-- DE DONDE SALE
-- ============================================================
-- Del SQL de referencia del companero, en
-- `backend/elementos Generales/plan pendiente/reglas-descuento-periodos.sql`,
-- copiado tal cual. Ese SQL ya se corrio a mano en su base local, y por eso
-- tiene que ser identico: el `CREATE TABLE IF NOT EXISTS` se salta si la
-- tabla ya existe, y una columna de mas aqui existiria en unas bases y en
-- otras no.
--
-- Las rutas son POST, GET, GET paginado y PATCH de
-- /vendedor/reglas-descuento-periodos. Sin esta tabla esas rutas contestan
-- 500, y tambien las de descuento manual y venta relampago, porque la
-- exclusion entre mecanismos (`helpers/exclusion-mecanismos-descuento.ts`)
-- pregunta por ella en cada una.
--
--
-- COMO SE LEE EL RANGO
-- ============================================================
-- dia/mes/anio de inicio y fin. La ausencia de un campo amplia la repeticion
-- en cascada:
--   con anio                -> una sola vez, en ese anio exacto.
--   sin anio                -> cada anio, mismo dia/mes de inicio y fin.
--   sin mes (ni anio)       -> todos los meses de todos los anios, solo con
--                              el rango de dia.
-- Los dos CHECK de abajo son esa cascada: los meses van juntos, y no hay anio
-- sin mes.
--
--
-- LO QUE NO ESTA AQUI
-- ============================================================
-- Que dos reglas activas de la misma oferta no se solapen en dias, y que una
-- regla no conviva con otro mecanismo de descuento, lo decide el backend
-- (`helpers/solape-regla-descuento-periodo.ts` y la exclusion de arriba), y
-- contesta 409. Un CHECK no ve otras filas.
--
-- El disparo lo hace DisparadorReglasPeriodoService cada 15 minutos,
-- reusando las mismas rutas de descuento y venta relampago.
--
-- Es idempotente: todo va con IF NOT EXISTS y el trigger se reemplaza.
-- ============================================================

CREATE TABLE IF NOT EXISTS regla_descuento_periodo (
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

-- El listado del vendedor entra por la oferta, y el disparador y la exclusion
-- preguntan solo por las activas.
CREATE INDEX IF NOT EXISTS idx_regla_descuento_periodo_oferta
  ON regla_descuento_periodo (id_oferta);

CREATE INDEX IF NOT EXISTS idx_regla_descuento_periodo_activa
  ON regla_descuento_periodo (id_oferta) WHERE activa;

-- fecha_actualizacion se toca sola con el trigger generico de oferta (005),
-- igual que en la 021.
DROP TRIGGER IF EXISTS trg_regla_descuento_periodo_tocar_fecha
  ON regla_descuento_periodo;
CREATE TRIGGER trg_regla_descuento_periodo_tocar_fecha
  BEFORE UPDATE ON regla_descuento_periodo
  FOR EACH ROW EXECUTE FUNCTION oferta_tocar_fecha();

COMMENT ON TABLE regla_descuento_periodo IS
    'Descuento por calendario de una oferta: entre dia/mes/anio de inicio y fin aplicar porcentaje_descuento (o abrir venta relampago). Sin anio se repite cada anio; sin mes, cada mes. Varias activas por oferta si no se solapan; lo vigila el backend.';
