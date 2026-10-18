-- ============================================================
-- carrito-postgres-verdad.sql  --  SOLO REFERENCIA / APLICADO EN LOCAL
-- ============================================================
-- Esto NO es una migracion. La migracion de verdad la escribe quien lleva
-- migrations/ (el companero), despues de la de seguimiento-ofertas.sql. El
-- plan completo esta en carrito-postgres-verdad.md.
--
-- Directiva del profesor: Redis NUNCA es la fuente de verdad. El carrito se
-- escribe en Redis (rapido) y debajo, en un intento asincrono, en el pedido
-- `pendiente` del usuario en PostgreSQL, que es la verdad. Las reservas de una
-- venta relampago igual: Redis decide primero (Lua atomico) y la reserva de
-- verdad vive en `reserva_venta_relampago`.
--
-- Lo que cambia en `pedido`:
--   - `fecha_ultima_actividad`: el reloj de las 24 h de inactividad. Si Redis
--     pierde el carrito (vencio, se reinicio) la verdad decide si sigue vivo.
--   - `version`: sube en cada escritura del carrito. Redis guarda la version
--     que conoce; si no coincide, hubo escrituras que Redis no vio (por
--     ejemplo mientras estaba caido) y el carrito se marca desincronizado.
--   - `id_direccion_historial` deja de ser NOT NULL, pero SOLO mientras el
--     pedido esta pendiente: en el carrito la direccion se elige al pagar.
--   - Un solo pedido pendiente por usuario: es su carrito.
--
-- Los ids de los estados (`pendiente`, `activa`) no se escriben a mano: se
-- leen del catalogo dentro de un DO y se arma el SQL con format().
--
-- Aplicado en local con:
--   docker exec -i mesh-postgres psql -U meme -d mesh -f - < este_archivo
--
-- Es idempotente.
-- ============================================================

BEGIN;

-- ============================================================
-- pedido: el carrito de verdad
-- ============================================================
ALTER TABLE pedido
    ADD COLUMN IF NOT EXISTS fecha_ultima_actividad timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS version bigint NOT NULL DEFAULT 0 CHECK (version >= 0);

COMMENT ON COLUMN pedido.fecha_ultima_actividad IS
    'Pendiente (= carrito): ultima vez que se toco. Pasadas 24 h sin tocarlo, el carrito vence y se borra (al leerlo o en el barrido). En los demas estados no se usa';
COMMENT ON COLUMN pedido.version IS
    'Pendiente (= carrito): sube en cada escritura. Redis guarda la que conoce; si no coincide, el carrito de Redis esta desincronizado';

-- Los pedidos que ya existian: su ultima actividad es cuando se crearon. El
-- trigger del grafo solo mira id_estado_pedido e id_usuario, asi que este
-- UPDATE no encola nada.
UPDATE pedido SET fecha_ultima_actividad = fecha_creacion
 WHERE fecha_ultima_actividad > fecha_creacion
   AND id_estado_pedido <> (SELECT id_estado_pedido FROM estado_pedido
                             WHERE estado_pedido_nombre = 'pendiente');

ALTER TABLE pedido ALTER COLUMN id_direccion_historial DROP NOT NULL;

DO $pedido$
DECLARE
    v_pendiente smallint;
BEGIN
    SELECT id_estado_pedido INTO v_pendiente
      FROM estado_pedido WHERE estado_pedido_nombre = 'pendiente';
    IF v_pendiente IS NULL THEN
        RAISE EXCEPTION 'No existe el estado de pedido pendiente';
    END IF;

    -- Sin direccion solo mientras es carrito. comprar_pedido() pasa el pedido
    -- a `comprado`: si nadie le puso direccion, este CHECK lo rechaza.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'pedido'::regclass
                      AND conname = 'pedido_direccion_salvo_pendiente') THEN
        EXECUTE format(
            'ALTER TABLE pedido ADD CONSTRAINT pedido_direccion_salvo_pendiente
                 CHECK (id_direccion_historial IS NOT NULL OR id_estado_pedido = %s)',
            v_pendiente);
    END IF;

    -- Un carrito por usuario.
    EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS uq_pedido_pendiente_usuario
             ON pedido (id_usuario) WHERE id_estado_pedido = %s',
        v_pendiente);

    -- El barrido de carritos vencidos lee por aqui.
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS ix_pedido_pendiente_actividad
             ON pedido (fecha_ultima_actividad) WHERE id_estado_pedido = %s',
        v_pendiente);
END
$pedido$;


-- ============================================================
-- estado_reserva_venta_relampago
-- ============================================================
CREATE TABLE IF NOT EXISTS estado_reserva_venta_relampago (
    id_estado_reserva      smallserial PRIMARY KEY,
    estado_reserva_nombre  varchar(30) NOT NULL UNIQUE
);

COMMENT ON TABLE estado_reserva_venta_relampago IS
    'Catalogo de estados de una reserva de venta relampago: activa, confirmada (se compro), devuelta (se solto o cerro la venta), vencida (pasaron los 15 min)';

INSERT INTO estado_reserva_venta_relampago (estado_reserva_nombre)
VALUES ('activa'), ('confirmada'), ('devuelta'), ('vencida')
ON CONFLICT (estado_reserva_nombre) DO NOTHING;


-- ============================================================
-- reserva_venta_relampago
-- ============================================================
CREATE TABLE IF NOT EXISTS reserva_venta_relampago (
    id_reserva  bigserial PRIMARY KEY,

    -- El carrito (pedido pendiente) que la tiene. SET NULL: si el carrito
    -- vence y se borra, la reserva se queda como historial. Si se compra, el
    -- pedido sigue existiendo y la reserva confirmada apunta a la compra.
    id_pedido  bigint REFERENCES pedido(id_pedido) ON DELETE SET NULL,

    -- Quien la tiene, aunque el pedido ya no este.
    id_usuario  bigint NOT NULL REFERENCES usuarios(id_usuario)
                ON DELETE RESTRICT,

    -- CASCADE y no RESTRICT para no trabar el borrado de productos generados
    -- (arrancar.ps1 -Borrar), igual que aviso_seguimiento_oferta.
    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta) ON DELETE CASCADE,

    cantidad  integer NOT NULL CHECK (cantidad > 0),

    -- El numero que reparte el script de Redis. NULL = se reservo solo en
    -- PostgreSQL (Redis estaba caido); se le pone uno al restaurar Redis.
    ticket  bigint CHECK (ticket > 0),

    fecha_reserva  timestamptz NOT NULL DEFAULT now(),
    -- Los 15 min. Una reserva activa con esto en el pasado ya no vale, aunque
    -- el barrido todavia no la haya pasado a `vencida`.
    fecha_vence    timestamptz NOT NULL,

    id_estado_reserva  smallint NOT NULL
                       REFERENCES estado_reserva_venta_relampago(id_estado_reserva)
                       ON DELETE RESTRICT,

    -- Cuando dejo de estar activa (se compro, se solto, vencio o cerro la venta).
    fecha_cierre  timestamptz,

    CONSTRAINT reserva_venta_relampago_vence_despues CHECK (fecha_vence > fecha_reserva)
);

COMMENT ON TABLE reserva_venta_relampago IS
    'La verdad de las reservas de venta relampago (15 min). Redis decide primero con su script atomico y esto lo registra; si Redis cae, se reserva aqui directo. Lo reservado de una oferta es la suma de las activas que no vencieron';
COMMENT ON COLUMN reserva_venta_relampago.ticket IS
    'El ticket que dio Redis. NULL = reservada solo en PostgreSQL (Redis caido); restaurar Redis le asigna uno';

-- Ticket por oferta: para devolver o confirmar del lado de Redis, y para que
-- restaurar sepa desde que numero seguir.
CREATE INDEX IF NOT EXISTS ix_reserva_venta_relampago_ticket
    ON reserva_venta_relampago (id_oferta, ticket);

CREATE INDEX IF NOT EXISTS ix_reserva_venta_relampago_pedido
    ON reserva_venta_relampago (id_pedido);

DO $reserva$
DECLARE
    v_activa smallint;
BEGIN
    SELECT id_estado_reserva INTO v_activa
      FROM estado_reserva_venta_relampago WHERE estado_reserva_nombre = 'activa';

    -- Una sola reserva activa por carrito y oferta.
    EXECUTE format(
        'CREATE UNIQUE INDEX IF NOT EXISTS uq_reserva_venta_relampago_activa
             ON reserva_venta_relampago (id_pedido, id_oferta)
          WHERE id_estado_reserva = %s',
        v_activa);

    -- Lo reservado de una oferta: solo las activas, que son pocas.
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS ix_reserva_venta_relampago_activas
             ON reserva_venta_relampago (id_oferta, fecha_vence)
          WHERE id_estado_reserva = %s',
        v_activa);
END
$reserva$;

COMMIT;


-- ============================================================
-- Se comprueba a si misma
-- ============================================================
DO $verificar$
DECLARE
    v_n integer;
BEGIN
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_name = 'pedido'
       AND column_name IN ('fecha_ultima_actividad', 'version');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'Faltan columnas en pedido';
    END IF;

    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_name = 'pedido' AND column_name = 'id_direccion_historial'
       AND is_nullable = 'YES';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'pedido.id_direccion_historial sigue siendo NOT NULL';
    END IF;

    SELECT count(*) INTO v_n FROM pg_indexes
     WHERE indexname IN ('uq_pedido_pendiente_usuario', 'ix_pedido_pendiente_actividad',
                         'uq_reserva_venta_relampago_activa', 'ix_reserva_venta_relampago_activas');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'Faltan indices (hay % de 4)', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM estado_reserva_venta_relampago;
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'Faltan estados de reserva';
    END IF;

    RAISE NOTICE 'Carrito con verdad en PostgreSQL listo.';
END
$verificar$;
