-- 008_direccion_exacta.sql
-- La calle: lo que le faltaba a una direccion para poder entregar un pedido.
--
-- Hasta la 007 una direccion llegaba hasta la ciudad -- pais, departamento,
-- ciudad y un codigo postal opcional. Con eso se sabe el punto del mapa pero
-- no la casa: "Guatemala, Guatemala, Guatemala" no lleva a ninguna puerta.
--
--
-- Por que UNA linea y no cuatro columnas
-- ============================================================
-- Lo natural seria partirla en calle, numero, zona y referencia. No se hizo, y
-- el motivo es que una direccion guatemalteca no se deja partir sin pelear:
--
--   5a. Avenida Norte 22, frente al Arco de Santa Catalina
--   6a. Avenida 9-18, Zona 1, Edificio El Centro, Nivel 3
--
-- No tienen la misma forma. Una lleva referencia y no lleva zona; la otra lleva
-- zona, edificio y nivel. Cuatro columnas fijas obligarian a inventar una regla
-- que la mitad de las direcciones no cumple, y acabarian siendo justo lo que el
-- enunciado del curso critica: columnas mayormente nulas.
--
-- Y el unico que lee este dato es quien tiene que llegar a la puerta. No se
-- filtra por el, no se agrupa por el y no se ordena por el: se imprime en la
-- etiqueta del paquete y se lee. Un dato que solo se lee entero no gana nada
-- partido.
--
--
-- Por que va en las DOS tablas
-- ============================================================
-- No es duplicar. `direccion_historial` es la foto de la direccion el dia que
-- regia, y el pedido apunta ahi (`pedido.id_direccion_historial`), no a la fila
-- viva. Si la calle viviera solo en `direcciones`, editar la direccion de hoy
-- cambiaria a donde dice que se mando un pedido de hace tres meses. La columna
-- va en las dos por la misma razon por la que ya estan las otras cuatro.
--
--
-- Por que nace NULLABLE
-- ============================================================
-- Las filas que ya existen se escribieron cuando la columna no existia, y no hay
-- forma honesta de adivinarles la calle. Ponerla NOT NULL de una vez obligaria a
-- rellenarlas con algo inventado, que es peor que dejarlas vacias: una direccion
-- falsa se entrega mal y nadie se entera hasta que el paquete se pierde.
--
-- El backend SI la exige al crear una direccion nueva, asi que todo lo que entre
-- de hoy en adelante la lleva, y el conjunto de datos de prueba la trae de
-- nacimiento (ver migrations/datos/generador.js). Cuando no quede ninguna fila en
-- NULL se puede cerrar con un ALTER ... SET NOT NULL en una migracion posterior.
--
--
-- Por que esta migracion es idempotente
-- ============================================================
-- Las tres migraciones de esta tanda (008, 009 y 010) usan IF NOT EXISTS y
-- ON CONFLICT DO NOTHING. El motivo es que el backend que las necesita se
-- escribio y se probo antes contra una base parchada a mano, asi que hay bases
-- por ahi que ya tienen parte de esto. Con IF NOT EXISTS la misma migracion
-- sirve para una base nueva y para una parchada, y no quedan dos esquemas
-- distintos segun quien la corrio.


-- ============================================================
-- direcciones
-- ============================================================
ALTER TABLE direcciones
    ADD COLUMN IF NOT EXISTS direccion_exacta varchar(255);

COMMENT ON COLUMN direcciones.direccion_exacta IS
    'Calle, numero, zona y referencias en una sola linea. Sin ella no se entrega un pedido';


-- ============================================================
-- direccion_historial
-- ============================================================
ALTER TABLE direccion_historial
    ADD COLUMN IF NOT EXISTS direccion_exacta varchar(255);

COMMENT ON COLUMN direccion_historial.direccion_exacta IS
    'La calle que regia el dia de esta version. El pedido lee de aqui, no de direcciones';


-- ============================================================
-- Las filas que ya existian
-- ============================================================
-- OJO, y es la trampa de esta tanda: en una base NUEVA esto no hace nada, y no
-- es un error.
--
-- El orden de arranque es primero migrations/*.sql y despues
-- migrations/datos/*.sql (ver migrations/README.md), asi que cuando corre este
-- archivo la tabla `direcciones` esta VACIA. No hay nada que rellenar.
--
-- Quien pone la calle en una base nueva es el generador del conjunto de datos,
-- que ya la escribe en el INSERT. Este bloque existe solo para las bases que ya
-- estaban andando cuando llego la columna: les copia al historial la calle que
-- tenga la fila viva, para que las dos tablas no se contradigan.
--
-- Van dos pasos, y el segundo tiene una trampa que costo ver.
--
--
-- Paso 1: las dos direcciones del conjunto de datos
-- ------------------------------------------------------------
-- Son las unicas direcciones que pudieron existir antes de esta columna en
-- cualquier base de Mesh, porque las escribe la semilla y sabemos exactamente
-- cual es la calle de cada una. Se emparejan por CORREO, nunca por id.
--
-- Las direcciones que haya creado gente desde la aplicacion NO se tocan: de
-- esas no sabemos la calle, y una direccion inventada se entrega mal sin que
-- nadie se entere. Se quedan en NULL, que es la respuesta honesta.
UPDATE direcciones d
   SET direccion_exacta = v.calle
  FROM (VALUES
      ('compradora.norte@mesh.com', '6a. Avenida 9-18, Zona 10, Edificio Vista Real, Nivel 3'),
      ('comprador.sur@mesh.com',    '5a. Avenida Norte 22, frente al Arco de Santa Catalina')
  ) AS v(correo, calle)
  JOIN usuarios u ON u.correo_electronico = v.correo
 WHERE d.id_usuario = u.id_usuario
   AND d.direccion_exacta IS NULL;


-- Paso 2: la version VIGENTE de cada direccion, y solo esa
-- ------------------------------------------------------------
-- La trampa: `direccion_historial` guarda VARIAS filas por direccion, una por
-- cada vez que se edito. Un UPDATE que empareje solo por `id_direccion` le
-- copia la calle de HOY a todas las versiones viejas -- y eso es exactamente lo
-- que el encabezado de este archivo dice que no puede pasar: la etiqueta de un
-- pedido de marzo acabaria imprimiendo la calle que se puso en junio.
--
-- Por eso se toca UNA sola fila por direccion: la ultima, que es la que rige
-- ahora y la unica que de verdad corresponde a lo que dice `direcciones`. Las
-- versiones anteriores se quedan en NULL, porque nadie sabe que calle tenian
-- cuando la columna no existia, y NULL dice justo eso.
UPDATE direccion_historial dh
   SET direccion_exacta = d.direccion_exacta
  FROM direcciones d,
       LATERAL (
           SELECT h.id_direccion_historial
             FROM direccion_historial h
            WHERE h.id_direccion = d.id_direccion
            ORDER BY h.fecha_creacion DESC, h.id_direccion_historial DESC
            LIMIT 1
       ) ultima
 WHERE dh.id_direccion_historial = ultima.id_direccion_historial
   AND dh.direccion_exacta IS NULL
   AND d.direccion_exacta IS NOT NULL;
