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

Cuidado con una migracion que falla a la mitad. La siguiente corrida la ve como
"ya aplicada" y se la salta, porque su primer `CREATE TABLE` choca con
`already exists` antes de llegar a lo que falto. Se sale borrando las tablas de
ese archivo y volviendo a correrlo.

Cada archivo hace una sola cosa y se puede leer solo.

## Reglas de los datos

Un conjunto nuevo es un archivo nuevo. No se reescriben los anteriores.

Los id se escriben a mano y **cuentan seguido desde 1, sin saltos**. Un archivo
nuevo continua donde termino el anterior. Para saber donde quedo:

```sql
SELECT max(id_producto) FROM productos;
```

Antes cada archivo tomaba un bloque de mil (1..1000, 1001..2000) para no tener
que mirar los otros al escribirlo. Era mas comodo de escribir y mas feo de leer:
el catalogo contaba 1, 2, 3 y de golpe 1001. Ahora cuesta un vistazo al archivo
anterior y la numeracion se lee.

`003_caracteristicas.sql` no comparte tablas con ningun otro conjunto, asi que
empieza en 1 sin ponerse de acuerdo con nadie.

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
