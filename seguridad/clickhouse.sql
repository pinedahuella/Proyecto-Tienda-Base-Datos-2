-- seguridad/clickhouse.sql
-- Los usuarios de cada servicio en ClickHouse. Lo corre arrancar.ps1 con
-- clickhouse-client, como el usuario que crea el contenedor (CLICKHOUSE_USER),
-- en cada arranque. Antes cambia __BASE__, __CLAVE_BACKEND__ y
-- __CLAVE_LECTURA__ por los valores del .env, asi las contrasenas nunca quedan
-- escritas en el repositorio. ClickHouse las guarda como hash y las tapa en su
-- propio registro de consultas.
--
--   mesh_backend   el backend, con mesh_backend_rol. Lee y agrega eventos en la
--                  base de eventos, y nada mas. No borra, no cambia tablas, no
--                  ve otras bases ni administra usuarios.
--   mesh_lectura   para consultar a mano (http://localhost:8123/play), con
--                  mesh_lectura_rol. Solo lee.
--
-- El usuario del contenedor queda para arrancar.ps1, el ETL y las pruebas.
--
-- Se puede correr cuantas veces sea: crea lo que falta y vuelve a poner las
-- contrasenas y los permisos.

CREATE ROLE IF NOT EXISTS mesh_backend_rol;
REVOKE ALL ON *.* FROM mesh_backend_rol;
GRANT SELECT, INSERT ON __BASE__.* TO mesh_backend_rol;

CREATE ROLE IF NOT EXISTS mesh_lectura_rol;
REVOKE ALL ON *.* FROM mesh_lectura_rol;
GRANT SELECT ON __BASE__.* TO mesh_lectura_rol;

CREATE USER IF NOT EXISTS mesh_backend IDENTIFIED WITH sha256_password BY '__CLAVE_BACKEND__';
ALTER USER mesh_backend IDENTIFIED WITH sha256_password BY '__CLAVE_BACKEND__' DEFAULT DATABASE __BASE__;
REVOKE ALL ON *.* FROM mesh_backend;
GRANT mesh_backend_rol TO mesh_backend;
ALTER USER mesh_backend DEFAULT ROLE mesh_backend_rol;

CREATE USER IF NOT EXISTS mesh_lectura IDENTIFIED WITH sha256_password BY '__CLAVE_LECTURA__';
ALTER USER mesh_lectura IDENTIFIED WITH sha256_password BY '__CLAVE_LECTURA__' DEFAULT DATABASE __BASE__;
REVOKE ALL ON *.* FROM mesh_lectura;
GRANT mesh_lectura_rol TO mesh_lectura;
ALTER USER mesh_lectura DEFAULT ROLE mesh_lectura_rol;

SHOW GRANTS FOR mesh_backend_rol, mesh_lectura_rol;
