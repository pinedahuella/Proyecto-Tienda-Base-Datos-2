-- ============================================================
-- aceptacion-de-ofertas.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), integrada en el orden correcto de los
-- archivos 005/006/007 y en migrations/datos/generador.js.
--
-- Este archivo existe para dos cosas:
--   1. Dejar por escrito, en la forma exacta, que cambios de esquema pide
--      el plan `aceptacion-de-ofertas.md` (mismo folder).
--   2. Poder aplicarlos al contenedor local `mesh-postgres` mientras se
--      desarrolla el backend en paralelo, sin esperar la migracion.
--
-- Aplicado en local el 2026-08-28 con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente (IF NOT EXISTS / ON CONFLICT) y reversible: un
-- `.\arrancar.ps1 -Reiniciar` reconstruye la base desde las migraciones
-- reales y borra todo esto.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- 1. estado_oferta: dos estados nuevos
-- ------------------------------------------------------------
-- pendiente  -> la oferta de un vendedor normal espera revision de la
--               tienda. No circula: la ficha publica, los campos calculados
--               del catalogo y el flujo de compra ya filtran por
--               id_estado_oferta = 'activa' (lista blanca), asi que
--               pendiente y rechazada quedan fuera sin tocar esa logica.
-- rechazada  -> la tienda la reviso y la rechazo, con un motivo guardado en
--               rechazo_oferta.
--
-- Se insertan sin id explicito, igual que el bloque de 005_ofertas.sql: la
-- smallserial esta en 3, asi que quedan 4 (pendiente) y 5 (rechazada).
INSERT INTO estado_oferta (estado_oferta_nombre) VALUES
    ('pendiente'),
    ('rechazada')
ON CONFLICT (estado_oferta_nombre) DO NOTHING;

COMMENT ON TABLE estado_oferta IS
    'Catalogo de estados de una oferta: pendiente, activa, pausada, retirada, rechazada';


-- ------------------------------------------------------------
-- 2. oferta.fecha_aprobacion
-- ------------------------------------------------------------
-- El hecho historico de cuando la tienda aprobo la oferta. NULL hasta que
-- se aprueba, y sobrevive a que despues la oferta se pause o se retire (a
-- diferencia del estado, que es solo la situacion de ahora). Mismo criterio
-- que el resto del proyecto: la fila viva lleva estado, el dato historico
-- va aparte.
--
-- Las ofertas de la tienda y de un admin nacen con esta fecha puesta (no
-- pasan por aprobacion); las de un vendedor normal nacen con NULL y estado
-- pendiente.
ALTER TABLE oferta ADD COLUMN IF NOT EXISTS fecha_aprobacion timestamptz;

COMMENT ON COLUMN oferta.fecha_aprobacion IS
    'Cuando la tienda aprobo la oferta. NULL = nunca aprobada. La tienda/admin nacen con fecha; un vendedor normal nace NULL + estado pendiente';


-- ------------------------------------------------------------
-- 3. rechazo_oferta: historial de rechazos
-- ------------------------------------------------------------
-- Tabla de solo insercion. Si una oferta se rechaza, se corrige (vuelve a
-- pendiente) y se rechaza de nuevo, quedan dos filas -- cada una con su
-- fecha_rechazo. FK con ON DELETE RESTRICT como toda la cadena economica
-- del proyecto: nada de esto se borra.
CREATE TABLE IF NOT EXISTS rechazo_oferta (
    id_rechazo_oferta  bigserial PRIMARY KEY,

    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta)
               ON DELETE RESTRICT,

    razon_rechazo  text NOT NULL CHECK (length(trim(razon_rechazo)) > 0),

    fecha_rechazo  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE rechazo_oferta IS
    'Cada vez que la tienda rechaza una oferta pendiente, con el motivo. Solo insercion';
COMMENT ON COLUMN rechazo_oferta.razon_rechazo IS
    'Por que se rechazo. Obligatorio y no vacio -- la tienda tiene que explicar';
COMMENT ON COLUMN rechazo_oferta.fecha_rechazo IS
    'Cuando se rechazo esta vez. Puede haber varias filas por oferta';

-- "los rechazos de esta oferta, del mas reciente al mas viejo"
CREATE INDEX IF NOT EXISTS idx_rechazo_oferta_oferta
    ON rechazo_oferta(id_oferta, fecha_rechazo DESC);


-- ------------------------------------------------------------
-- 4. Back-fill: lo que ya existe queda como aprobado
-- ------------------------------------------------------------
-- Sin esto, al agregar la columna todas las ofertas quedarian con
-- fecha_aprobacion NULL y, en cuanto el backend empiece a mirar ese campo,
-- el catalogo entero se leeria como "sin aprobar".
--
-- El estado NO se toca: una oferta que hoy esta activa/pausada/retirada se
-- queda igual. Solo se les pone la fecha.
--
-- Se desactiva trg_oferta_tocar_fecha durante el UPDATE: ese trigger salta
-- en CUALQUIER update de oferta y pondria fecha_actualizacion = now() en
-- las 552 filas, desincronizando la base local de una carga limpia. La
-- migracion real no tiene este problema porque generador.js escribe
-- fecha_aprobacion directo al generar los datos.
ALTER TABLE oferta DISABLE TRIGGER trg_oferta_tocar_fecha;

UPDATE oferta
   SET fecha_aprobacion = fecha_creacion
 WHERE fecha_aprobacion IS NULL;

ALTER TABLE oferta ENABLE TRIGGER trg_oferta_tocar_fecha;

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_estado_oferta, estado_oferta_nombre FROM estado_oferta ORDER BY id_estado_oferta;
SELECT count(*) AS ofertas_totales,
       count(*) FILTER (WHERE fecha_aprobacion IS NOT NULL) AS con_fecha_aprobacion,
       count(*) FILTER (WHERE fecha_aprobacion IS NULL)     AS sin_fecha_aprobacion
FROM oferta;
SELECT to_regclass('public.rechazo_oferta') AS tabla_rechazo_oferta;
