-- ============================================================
-- direccion-exacta.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion real la escribe quien lleva
-- migrations/ (el companero), integrada en 002_direcciones.sql y en
-- migrations/datos/generador.js.
--
-- Este archivo:
--   1. Deja por escrito la forma exacta del cambio (ver direccion-exacta.md
--      en este mismo folder).
--   2. Se aplica al contenedor local `mesh-postgres` para poder trabajar el
--      backend en paralelo sin esperar la migracion.
--
-- Aplicado en local el 2026-08-29.
-- Idempotente (IF NOT EXISTS). Reversible con `.\arrancar.ps1 -Reiniciar`.
-- ============================================================


BEGIN;

-- ------------------------------------------------------------
-- La columna, en las DOS tablas
-- ------------------------------------------------------------
-- `direcciones` guarda la version vigente; `direccion_historial` guarda la
-- foto de cada version, para que un pedido recuerde a que calle exacta se
-- envio ese dia aunque el usuario edite la direccion despues. La columna va
-- en las dos por la misma razon que pais/ciudad estan en las dos.
--
-- **NULLABLE a proposito, por ahora.** El backend todavia no manda este
-- campo (decision del usuario: no tocar el backend en este paso). Si
-- fuera NOT NULL sin default, el `POST /direccion-usuario` actual
-- reventaria. La migracion real la puede dejar NOT NULL una vez que el
-- backend y el generador ya la llenen siempre -- igual que pais,
-- departamento y ciudad.
--
-- varchar(255) y no varchar(100): una linea de calle completa en
-- Guatemala ("4a. Avenida 12-34, Zona 10, Edificio Plaza, Oficina 502,
-- frente al parque") pasa de 100 con facilidad. codigo_postal sigue
-- aparte y opcional.
ALTER TABLE direcciones
    ADD COLUMN IF NOT EXISTS direccion_exacta varchar(255);

ALTER TABLE direccion_historial
    ADD COLUMN IF NOT EXISTS direccion_exacta varchar(255);

COMMENT ON COLUMN direcciones.direccion_exacta IS
    'Calle, numero, zona y referencias en una sola linea. Nullable por ahora (el backend aun no la manda); la migracion real la dejara NOT NULL cuando la llene siempre';
COMMENT ON COLUMN direccion_historial.direccion_exacta IS
    'Foto de direcciones.direccion_exacta el dia que regia esa version';


-- ------------------------------------------------------------
-- Back-fill de las 2 direcciones de prueba que ya existen
-- ------------------------------------------------------------
-- Son datos de prueba (compradora_norte y comprador_sur). Se les pone una
-- calle plausible para su ciudad, para que la base local se vea completa
-- cuando se trabaje el backend. La migracion real hara esto desde
-- generador.js.
UPDATE direcciones SET direccion_exacta =
    '5a. Avenida Norte 22, frente al Arco de Santa Catalina'
    WHERE id_direccion = 1 AND direccion_exacta IS NULL;

UPDATE direcciones SET direccion_exacta =
    '6a. Avenida 9-18, Zona 1, Edificio El Centro, Nivel 3'
    WHERE id_direccion = 2 AND direccion_exacta IS NULL;

-- El historial copia lo mismo que su direccion viva (las 2 filas actuales
-- nacieron a la vez que la direccion, nunca se editaron).
UPDATE direccion_historial dh
    SET direccion_exacta = d.direccion_exacta
    FROM direcciones d
    WHERE d.id_direccion = dh.id_direccion
      AND dh.direccion_exacta IS NULL;

COMMIT;


-- ------------------------------------------------------------
-- Comprobacion
-- ------------------------------------------------------------
SELECT id_direccion, ciudad, direccion_exacta FROM direcciones ORDER BY id_direccion;
SELECT id_direccion_historial, id_direccion, direccion_exacta FROM direccion_historial ORDER BY id_direccion_historial;
