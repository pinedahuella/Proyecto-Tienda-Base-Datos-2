-- ============================================================
-- 021_regla_descuento_automatico.sql
-- ============================================================
-- La configuracion de los descuentos automaticos. Un vendedor le dice a una
-- oferta suya "si se venden N unidades en M minutos, rebajala X% durante S
-- segundos", o "abre una venta relampago" en vez de solo el descuento.
--
--
-- DE DONDE SALE
-- ============================================================
-- Del commit 56ce5f8 del companero, que agrego el CRUD en
-- `backend/src/services/reglas-descuento-automatico/` y las rutas
-- POST, GET, GET paginado y PATCH de /vendedor/reglas-descuento. La tabla la
-- creo a mano en su base local y no dejo migracion, asi que aqui se escribe
-- a partir de lo que el backend lee y escribe, con los nombres de columna del
-- modelo `backend/src/models/regla-descuento-automatico.ts` y la tabla de
-- `endpoints-vendedores.md`, seccion "Reglas de descuento automatico".
--
-- Como su base ya la tiene, todo va con IF NOT EXISTS: correrla encima no
-- rompe nada, y en una base nueva la crea entera. Tambien por eso sirve que
-- `arrancar.ps1` la vuelva a correr en cada arranque.
--
--
-- LO QUE TODAVIA NO HACE NADIE
-- ============================================================
-- Esto es SOLO la configuracion. El disparo, un proceso que mire en
-- ClickHouse cuantas unidades se vendieron de la oferta en la ventana y active
-- el descuento o la venta relampago, todavia no existe en el backend. Hoy una
-- regla activa se guarda y se puede editar, pero no cambia ningun precio.
--
--
-- LAS REGLAS DE CADA COLUMNA
-- ============================================================
--   UNIQUE(id_oferta)          una regla por oferta como mucho. El backend
--                              traduce el 23505 a un 409.
--   ON DELETE CASCADE          si la oferta desaparece, su regla tambien.
--   umbral, ventana, duracion  enteros mayores que 0. La duracion NO acepta 0,
--                              a diferencia de la venta limitada: una regla
--                              siempre tiene que vencer sola.
--   porcentaje_descuento       mismo CHECK que oferta.porcentaje_descuento de
--                              la 020, mayor que 0 y menor que 100. El tope
--                              de negocio (1 a 90) lo pone el backend.
--
-- Los topes altos (100000 unidades, una semana de ventana y de duracion) viven
-- solo en el backend, en `validaciones-regla-descuento.ts`, por la misma razon
-- que el 1 a 90 del descuento: cambiarlos no deberia pedir otra migracion.
-- ============================================================

CREATE TABLE IF NOT EXISTS regla_descuento_automatico (
    id_regla_descuento_automatico bigserial PRIMARY KEY,
    id_oferta            bigint       NOT NULL UNIQUE
                                      REFERENCES oferta(id_oferta) ON DELETE CASCADE,
    umbral_unidades      integer      NOT NULL CHECK (umbral_unidades > 0),
    ventana_minutos      integer      NOT NULL CHECK (ventana_minutos > 0),
    es_venta_relampago   boolean      NOT NULL DEFAULT false,
    duracion_segundos    integer      NOT NULL CHECK (duracion_segundos > 0),
    porcentaje_descuento numeric(5,2) NOT NULL
                                      CHECK (porcentaje_descuento > 0 AND porcentaje_descuento < 100),
    activa               boolean      NOT NULL DEFAULT true,
    fecha_creacion       timestamptz  NOT NULL DEFAULT now(),
    fecha_actualizacion  timestamptz  NOT NULL DEFAULT now()
);

-- El listado del vendedor ordena por fecha_actualizacion DESC y filtra por
-- sus ofertas con un JOIN a oferta. El UNIQUE ya indexa id_oferta, que es por
-- donde entra ese JOIN, asi que no hace falta otro indice.

-- fecha_actualizacion se toca sola con el mismo trigger generico de oferta
-- (005). Se reemplaza en cada arranque para que quede igual aunque la tabla
-- venga de la base del companero con otro nombre de trigger.
DROP TRIGGER IF EXISTS trg_regla_descuento_tocar_fecha ON regla_descuento_automatico;
CREATE TRIGGER trg_regla_descuento_tocar_fecha
    BEFORE UPDATE ON regla_descuento_automatico
    FOR EACH ROW EXECUTE FUNCTION oferta_tocar_fecha();

COMMENT ON TABLE regla_descuento_automatico IS
    'Configuracion de descuento automatico por oferta: si se venden umbral_unidades en ventana_minutos, aplicar porcentaje_descuento (o abrir venta relampago) por duracion_segundos. El disparo aun no existe.';
