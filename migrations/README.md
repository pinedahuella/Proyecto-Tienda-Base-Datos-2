# Migrations

Los scripts SQL del esquema de Mesh y los conjuntos de datos de prueba.

## Dos clases de archivo

```
migrations/*.sql        el esquema
migrations/datos/*.sql  los datos de prueba
```

El esquema son las tablas, sus indices y los valores de los catalogos de estado.
Los estados son parte del esquema, no datos de prueba: sin ellos no se puede
insertar ni un usuario ni un producto.

Los datos de prueba son todo lo demas: el vendedor, las categorias, los productos,
sus variantes, sus imagenes y sus tres historiales. Sirven para las consultas de
las entregas y para que el ETL tenga algo que llevar a Mongo.

## Como se nombran

```
001_nombre.sql
002_nombre.sql
```

Numero de tres digitos y guion bajo, en las dos carpetas. El numero manda: se
corren en orden y una tabla no puede referenciar otra que todavia no existe.

## En que orden corren

Primero `migrations/*.sql` en orden de nombre, y despues `migrations/datos/*.sql`
en orden de nombre. `arrancar.ps1` hace los dos pasos.

## Reglas del esquema

Una migracion ya corrida **no se edita**. Si algo hay que cambiar, se hace un
archivo nuevo con el numero siguiente. Editar una vieja deja tu base distinta a la
de los demas sin que nadie se de cuenta.

del `CREATE TABLE` de `003`, asi que una base nueva ya nace con ella, pero una
base que ya existia no la vio nunca: `003` corta en `already exists` antes de
llegar a nada nuevo. El `004` la agrega con `ADD COLUMN IF NOT EXISTS`, no hace
nada en una base nueva y no borra los datos de nadie.

Cada archivo hace una sola cosa y se puede leer solo.

## Reglas de los datos

Un conjunto nuevo es un archivo nuevo. No se abren los anteriores.

Cada archivo es dueno de un bloque de mil id, y los usa en **todas** las tablas
que llevan id escrito a mano. Un solo numero que recordar por archivo:

```
datos/001_catalogo_base.sql       1 .. 1000
datos/002_catalogo_ampliado.sql   1001 .. 2000
datos/003_lo_que_venga.sql        2001 .. 3000
```

La excepcion es `usuarios`: nunca lleva id escrito a mano. Los reparte la
aplicacion al registrarse y ya vienen salteados. Un vendedor se inserta con
`ON CONFLICT (correo_electronico) DO NOTHING` y se referencia con un `SELECT` por
correo.

Todo `INSERT` lleva `ON CONFLICT DO NOTHING`, sin nombrar la restriccion. Estos
archivos corren en cada arranque y sin eso la segunda corrida falla por llave
duplicada.

Cada archivo termina reajustando las secuencias con `setval` y `max()`, para que
la aplicacion siga numerando donde el ultimo conjunto termino.

## Como correrlas

La carpeta esta montada dentro del contenedor en `/migrations`.

```bash
docker exec -i mesh-postgres psql -U $DB_USER -d $DB_NAME -f /migrations/001_usuarios.sql
```

Todas de una, en orden:

```bash
docker exec mesh-postgres sh -c "for f in /migrations/*.sql /migrations/datos/*.sql; do psql -U $DB_USER -d $DB_NAME -f \$f; done"
```

Empezar de cero (borra todo):

```bash
docker compose down -v
docker compose up -d
```

## Comprobar

```bash
docker exec -it mesh-postgres psql -U $DB_USER -d $DB_NAME
```

Dentro de psql:

```
\dt     lista las tablas
\d      describe una tabla
\q      salir
```
