# Migrations

Los scripts SQL del esquema de Mesh.

## Como se nombran

```
001_nombre.sql
002_nombre.sql
```

Numero de tres digitos y guion bajo. El numero manda: se corren en orden y una
tabla no puede referenciar otra que todavia no existe.

## Reglas

Una migracion ya corrida **no se edita**. Si algo hay que cambiar, se hace un
archivo nuevo con el numero siguiente. Editar una vieja deja tu base distinta a la
de los demas sin que nadie se de cuenta.

Cada archivo hace una sola cosa y se puede leer solo.

## Como correrlas

La carpeta esta montada dentro del contenedor en `/migrations`.

```bash
docker exec -i mesh-postgres psql -U $DB_USER -d $DB_NAME -f /migrations/001_esquema.sql
```

Todas de una, en orden:

```bash
docker exec mesh-postgres sh -c "for f in /migrations/*.sql; do psql -U $DB_USER -d $DB_NAME -f \$f; done"
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
