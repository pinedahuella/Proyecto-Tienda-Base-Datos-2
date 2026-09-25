-- Referencia para la migracion real del companero (workflow de siempre,
-- ver memoria "solo-backend"). Aplicado a mano en la base LOCAL para
-- desarrollar el backend en paralelo. Idempotente.
--
-- Regla de descuento por PERIODO: a diferencia de regla_descuento_automatico
-- (dispara por umbral de ventas en una ventana), esta dispara por calendario.
-- El rango se arma con dia/mes/anio de inicio y fin; la ausencia de un campo
-- amplia la repeticion en cascada:
--   - con anio       -> ocurre una sola vez, en ese anio exacto.
--   - sin anio       -> se repite cada anio, mismo dia/mes de inicio y fin.
--   - sin mes (y por lo tanto sin anio) -> se repite en TODOS los meses de
--     TODOS los anios, usando solo el rango de dia.

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

CREATE INDEX IF NOT EXISTS idx_regla_descuento_periodo_oferta
  ON regla_descuento_periodo (id_oferta);

CREATE INDEX IF NOT EXISTS idx_regla_descuento_periodo_activa
  ON regla_descuento_periodo (id_oferta) WHERE activa;

DROP TRIGGER IF EXISTS trg_regla_descuento_periodo_tocar_fecha
  ON regla_descuento_periodo;
CREATE TRIGGER trg_regla_descuento_periodo_tocar_fecha
  BEFORE UPDATE ON regla_descuento_periodo
  FOR EACH ROW EXECUTE FUNCTION oferta_tocar_fecha();
