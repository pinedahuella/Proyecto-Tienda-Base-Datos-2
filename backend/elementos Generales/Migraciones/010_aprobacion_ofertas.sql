-- 010_aprobacion_ofertas.sql
-- Una oferta de un vendedor ya no nace vendiendo: nace esperando.
--
-- Hasta ahora, cuando cualquiera publicaba una oferta con POST /vendedor/ofertas
-- la oferta nacia `activa` y se podia comprar en el acto, sin que nadie la
-- mirara. La propia documentacion del backend lo admitia: "nace siempre activa,
-- sin aprobacion previa de la tienda; eso quedo pendiente de disenar".
--
-- Ahora la oferta de un vendedor normal nace `pendiente` y no circula hasta que
-- la tienda la aprueba. La tienda y los admin siguen naciendo `activa`: la
-- tienda es la autoridad y no tiene a quien pedirle permiso.
--
--
-- Estado y fecha: las dos cosas, cada una para lo suyo
-- ============================================================
-- Se guardan un ESTADO nuevo y una COLUMNA de fecha, y no es redundante:
--
--   el estado           dice la situacion de AHORA (pendiente / activa / ...)
--   fecha_aprobacion    guarda el HECHO de que se aprobo, y cuando
--
-- El estado pierde la memoria en cuanto cambia: una oferta aprobada que despues
-- se pausa ya no dice por ningun lado que alguna vez se aprobo. La fecha
-- sobrevive a eso. Es la misma regla que el proyecto ya sigue en todas partes:
-- la fila viva lleva estado, el hecho historico va aparte (ver
-- docs/base-de-datos.md, "Los historiales no llevan estado").
--
--
-- Lo que esta migracion NO pone, y es a proposito
-- ============================================================
-- 1. NO hay CHECK que ate el estado a la fecha. La regla verdadera es "una
--    oferta `activa` o `pausada` tiene que tener fecha_aprobacion", y no se
--    puede escribir como CHECK sin meter los id del catalogo a mano dentro de la
--    restriccion -- un CHECK no admite subconsultas. Meter `id_estado_oferta = 2`
--    ahi dentro seria justo el id escrito a mano que migrations/README.md
--    prohibe, y ademas se rompe el dia que alguien reordene el catalogo.
--    La regla la sostiene la aplicacion, y el conjunto de datos la comprueba al
--    cargar (ver la verificacion en migrations/datos/001_catalogo.sql).
--
-- 2. NO hay CHECK que empareje `fecha_aprobacion` con `id_usuario_aprobo`, y
--    aqui SI se podria escribir (es el que lleva `propuesta_producto`). No va,
--    porque en las ofertas las dos columnas NO van juntas: la tienda y los admin
--    nacen aprobados sin que nadie los apruebe, asi que su oferta tiene fecha y
--    no tiene aprobador. Emparejarlas prohibiria el caso normal.
--    Lo que si es imposible es lo contrario -- un aprobador sin fecha -- y eso lo
--    comprueba el conjunto de datos al cargar.


-- ============================================================
-- Los dos estados nuevos de la oferta
-- ============================================================
-- `pendiente`  -- esperando revision de la tienda. No circula.
-- `rechazada`  -- revisada y devuelta, con su motivo en rechazo_oferta.
--
-- No son datos de prueba: sin ellos no se puede publicar una oferta.
--
-- Ninguno de los dos se cuela a la tienda, y tampoco hay que acordarse de
-- excluirlos: la ficha del producto y los agregados del ETL filtran las ofertas
-- por LISTA BLANCA (`estado_oferta_nombre = 'activa'`), asi que un estado nuevo
-- queda fuera por defecto.
INSERT INTO estado_oferta (estado_oferta_nombre) VALUES
    ('pendiente'),
    ('rechazada')
ON CONFLICT (estado_oferta_nombre) DO NOTHING;

COMMENT ON TABLE estado_oferta IS
    'Catalogo de estados de una oferta: pendiente, activa, pausada, retirada, rechazada';


-- ============================================================
-- oferta.fecha_aprobacion
-- ============================================================
ALTER TABLE oferta
    ADD COLUMN IF NOT EXISTS fecha_aprobacion timestamptz;

COMMENT ON COLUMN oferta.fecha_aprobacion IS
    'Cuando se aprobo la oferta. NULL = nunca aprobada, y es lo que impide que el vendedor la active solo. La tienda y los admin nacen CON fecha; un vendedor normal nace NULL y en estado pendiente. Sobrevive a que despues se pause';


-- ============================================================
-- oferta.id_usuario_aprobo
-- ============================================================
-- Quien la aprobo. La fecha dice cuando y esta dice quien, que es la mitad util
-- del dato: sin ella no se le puede pedir cuentas a nadie de una aprobacion.
--
-- Sigue la convencion que el proyecto ya usa dos veces para lo mismo --
-- `precio_historial.id_usuario_modifico` y `stock_movimiento.id_usuario_modifico`
-- -- y se llama distinto del dueno de la oferta a proposito: el dueno sale de
-- `oferta.id_usuario` y no de aqui.
--
-- **NULL no quiere decir "no aprobada".** Quiere decir que no consta quien, y
-- hay dos casos legitimos:
--
--   la oferta de la tienda o de un admin  nace aprobada sin que nadie la revise
--   una oferta anterior a este cambio     circulaba antes de que existiera la cola
--
-- Por eso NO lleva CHECK contra `fecha_aprobacion`: emparejarlas prohibiria el
-- primer caso, que es el normal para las 202 ofertas de la tienda.
ALTER TABLE oferta
    ADD COLUMN IF NOT EXISTS id_usuario_aprobo bigint REFERENCES usuarios(id_usuario)
                             ON DELETE RESTRICT;

COMMENT ON COLUMN oferta.id_usuario_aprobo IS
    'Quien aprobo la oferta. NULL = no consta (la tienda y los admin nacen aprobados sin revisor). El dueno de la oferta sale de id_usuario, no de aqui';


-- ============================================================
-- rechazo_oferta
-- ============================================================
-- Cada vez que la tienda rechaza una oferta, con el motivo. Solo se inserta.
--
-- Tabla aparte y no dos columnas en `oferta` por lo mismo que rechazo_producto:
-- un rechazo se repite. El vendedor corrige el precio, la oferta vuelve a
-- `pendiente`, y se le puede volver a rechazar. Con columnas, el segundo rechazo
-- pisaria al primero.
CREATE TABLE IF NOT EXISTS rechazo_oferta (
    id_rechazo_oferta  bigserial PRIMARY KEY,

    -- RESTRICT como el resto de la cadena economica: una oferta que ya tuvo
    -- historia no se borra, se retira.
    id_oferta  bigint NOT NULL REFERENCES oferta(id_oferta)
               ON DELETE RESTRICT,

    -- Obligatorio y no vacio: la tienda tiene que explicar. El CHECK es lo que
    -- impide que una ruta nueva mande la cadena vacia y el vendedor se quede
    -- adivinando.
    razon_rechazo  text NOT NULL CHECK (length(trim(razon_rechazo)) > 0),

    fecha_rechazo  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE rechazo_oferta IS
    'Cada rechazo de una oferta, con su motivo. Solo insercion: es un historial';
COMMENT ON COLUMN rechazo_oferta.razon_rechazo IS
    'Por que se rechazo. Obligatorio y no vacio -- la tienda tiene que explicar';
COMMENT ON COLUMN rechazo_oferta.fecha_rechazo IS
    'Cuando se rechazo esta vez. Puede haber varias filas por oferta';

-- "los rechazos de esta oferta, del mas nuevo al mas viejo": es lo que se le
-- ensena al vendedor cuando le devuelven su publicacion.
CREATE INDEX IF NOT EXISTS idx_rechazo_oferta_oferta
    ON rechazo_oferta(id_oferta, fecha_rechazo DESC);


-- ============================================================
-- Las ofertas que ya existian
-- ============================================================
-- Igual que en la 008: en una base NUEVA esto no hace nada, porque el esquema
-- corre antes que los datos y aqui la tabla `oferta` todavia esta vacia. Quien
-- pone la fecha en una base nueva es el generador del conjunto de datos.
--
-- Esto es para las bases que ya estaban andando. Toda oferta anterior a este
-- cambio circulaba sin pedirle permiso a nadie, o sea que estaba aprobada de
-- hecho: se le pone como fecha de aprobacion la de su creacion, que es cuando
-- empezo a venderse.
--
-- El filtro es una LISTA BLANCA -- solo `activa` y `pausada` -- y esa eleccion
-- es lo mas delicado de este archivo. Vale la pena decir por que, porque la
-- version obvia (excluir `pendiente` y `rechazada`) ABRE justo la puerta que
-- esta migracion viene a cerrar:
--
--   1. un vendedor publica            -> `pendiente`, fecha_aprobacion NULL
--   2. se arrepiente y la retira      -> `retirada`,  fecha_aprobacion NULL
--      (el backend se lo permite: solo le bloquea `activa` y `pausada`)
--   3. se vuelve a correr esta migracion, que es lo que hace arrancar.ps1 en
--      CADA arranque
--   4. con una lista negra, esa `retirada` recibiria fecha de aprobacion
--   5. y entonces el vendedor la puede poner `activa` el solo, sin que la
--      tienda la haya visto nunca
--
-- El paso 5 funciona porque `fecha_aprobacion` NO es un dato de auditoria que
-- nadie lee: es EL candado. El backend calcula `nuncaAprobada` mirando si es
-- NULL (ofertas.service.ts) y solo con eso decide si el vendedor puede activar
-- su propia oferta. Escribir esa columna es repartir permisos.
--
-- Con la lista blanca no hay caso ambiguo: a `activa` y a `pausada` no se llega
-- sin aprobacion, asi que una fila en esos estados con la fecha en NULL es
-- necesariamente anterior a este cambio. Lo que se paga es que una `retirada`
-- vieja y legitima se queda sin fecha y, si su dueno la reactiva, tiene que
-- pasar por revision otra vez. Es el error seguro de los dos.
--
-- El trigger se apaga a la mitad -- `trg_oferta_tocar_fecha` corre en CUALQUIER
-- update, asi que sin apagarlo estas filas quedarian con `fecha_actualizacion`
-- de hoy y pareceria que alguien las toco. Lo que se rellena es pasado.
--
-- Y va todo dentro de una transaccion explicita, que es lo que hace el conjunto
-- de datos cuando apaga el trigger de precios. psql corre en autocommit: sin el
-- BEGIN, el DISABLE se confirma solo, y si el UPDATE falla o alguien corta el
-- arranque con Ctrl+C, **el trigger se queda apagado para siempre** y en
-- silencio. La siguiente corrida no se queja de nada, porque este archivo es
-- idempotente. Un fallo asi no se descubre hasta meses despues, cuando
-- `fecha_actualizacion` lleva tiempo sin moverse y nadie sabe desde cuando.
BEGIN;

ALTER TABLE oferta DISABLE TRIGGER trg_oferta_tocar_fecha;

UPDATE oferta o
   SET fecha_aprobacion = o.fecha_creacion
 WHERE o.fecha_aprobacion IS NULL
   AND EXISTS (
       SELECT 1
         FROM estado_oferta eo
        WHERE eo.id_estado_oferta = o.id_estado_oferta
          AND eo.estado_oferta_nombre IN ('activa', 'pausada')
   );

ALTER TABLE oferta ENABLE TRIGGER trg_oferta_tocar_fecha;

COMMIT;
