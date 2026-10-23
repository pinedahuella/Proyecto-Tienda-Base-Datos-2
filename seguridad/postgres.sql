-- seguridad/postgres.sql
-- Los usuarios de cada servicio en PostgreSQL. Lo corre arrancar.ps1 despues de
-- las migraciones, como el dueno de la base, en cada arranque:
--
--   psql -v base=mesh -v dueno=... -v clave_backend=... -v clave_lectura=... -f -
--
-- Las contrasenas llegan como variables de psql desde el .env y nunca quedan
-- escritas en el repositorio.
--
--   mesh_backend   el backend. Lee, agrega, cambia y borra filas, usa las
--                  secuencias y llama a las funciones. NO crea, cambia ni borra
--                  tablas (eso es de las migraciones, que corren como el dueno),
--                  no vacia tablas con TRUNCATE, no crea usuarios ni bases.
--   mesh_lectura   para mirar, revisar o sacar un reporte. Solo SELECT.
--
-- El dueno (DB_USER del .env) queda para arrancar.ps1, las migraciones, el ETL,
-- las pruebas y pgAdmin.
--
-- Se puede correr cuantas veces sea. Crea lo que falte y vuelve a poner la
-- contrasena y los permisos, asi que tambien sirve para cambiar una contrasena.

\set ON_ERROR_STOP on

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mesh_backend') AS falta_backend,
       NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'mesh_lectura') AS falta_lectura
\gset

\if :falta_backend
CREATE ROLE mesh_backend LOGIN;
\endif
\if :falta_lectura
CREATE ROLE mesh_lectura LOGIN;
\endif

-- Sin ningun atributo especial, aunque alguien se los haya dado a mano.
ALTER ROLE mesh_backend WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'clave_backend';
ALTER ROLE mesh_lectura WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'clave_lectura';

-- mesh_lectura no escribe nada ni aunque se le olvide a alguien un GRANT de mas.
ALTER ROLE mesh_lectura SET default_transaction_read_only = on;

GRANT CONNECT ON DATABASE :"base" TO mesh_backend, mesh_lectura;
GRANT USAGE ON SCHEMA public TO mesh_backend, mesh_lectura;

-- Desde PostgreSQL 15 nadie mas que el dueno crea objetos en public. Se dice
-- igual, por si la base viene de una version anterior.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Lo que ya existe.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO mesh_backend;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO mesh_backend;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO mesh_backend;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO mesh_lectura;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO mesh_lectura;

-- Lo que creen las migraciones que vengan. Sin esto, una tabla nueva nace sin
-- permisos para el backend y la ruta que la usa da 500 hasta el siguiente
-- arranque.
ALTER DEFAULT PRIVILEGES FOR ROLE :"dueno" IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO mesh_backend;
ALTER DEFAULT PRIVILEGES FOR ROLE :"dueno" IN SCHEMA public
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO mesh_backend;
ALTER DEFAULT PRIVILEGES FOR ROLE :"dueno" IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO mesh_backend;
ALTER DEFAULT PRIVILEGES FOR ROLE :"dueno" IN SCHEMA public
    GRANT SELECT ON TABLES TO mesh_lectura;
ALTER DEFAULT PRIVILEGES FOR ROLE :"dueno" IN SCHEMA public
    GRANT SELECT ON SEQUENCES TO mesh_lectura;

SELECT rolname AS usuario,
       rolsuper AS superusuario,
       rolcreatedb AS crea_bases,
       rolcreaterole AS crea_usuarios,
       (SELECT count(*) FROM information_schema.role_table_grants g
         WHERE g.grantee = r.rolname AND g.table_schema = 'public') AS permisos_en_tablas
  FROM pg_roles r
 WHERE rolname IN ('mesh_backend', 'mesh_lectura')
 ORDER BY rolname;
