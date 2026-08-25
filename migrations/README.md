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

Los datos son todo lo demas: las cuentas, las categorias, los productos, sus
variantes, sus caracteristicas, sus ofertas y sus historiales. Sirven para las
consultas de las entregas y para que el ETL tenga algo que llevar a Mongo.

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

## Los datos los escribe un generador

El archivo `datos/001_catalogo.sql` **no se edita a mano**: lo escribe
`datos/generador.js`.

```bash
node migrations/datos/generador.js
```

El motivo del reparto: el CONTENIDO (que categorias existen, como se llaman los
productos, que caracteristicas ofrece cada hoja, que cambio con el tiempo) se
escribe a mano dentro del generador, porque eso es criterio. El REPARTO (que
vendedor oferta que variante, con cuanto stock, a que precio) es mecanico, y lo
mecanico no se escribe a mano: se calcula.

Es **determinista**. El azar sale de una semilla fija, asi que correrlo dos
veces escribe el mismo archivo. Sin eso, cada corrida cambiaria el conjunto de
datos y nadie podria comparar dos bases.

## Ningun id se escribe a mano

Esta es la regla, y ya no tiene excepciones: **todo se busca por nombre o por
correo**.

```sql
INSERT INTO productos (nombre, id_estado_producto, id_categoria)
SELECT v.nombre, ep.id_estado_producto, c.id_categoria
FROM (VALUES ('Laptop Aurora 14', 'activo', 'Laptops')) AS v(nombre, estado, hoja)
JOIN estado_producto ep ON ep.estado_producto_nombre = v.estado
JOIN categorias      c  ON c.nombre = v.hoja AND c.id_categoria_padre IS NOT NULL;
```

Antes los id se escribian a mano y se llevaba la cuenta entre archivos, con una
excepcion para las tablas que tambien escribe la aplicacion (`usuarios`,
`direcciones`). Esa excepcion existia porque un `id_usuario = 9` funciona en la
maquina donde ese usuario existe y revienta en cualquier otra con una violacion
de llave foranea -- y solo se nota corriendo contra una base vacia.

La excepcion se volvio la regla: si escribir un id a mano es peligroso para dos
tablas, lo es para todas. De paso desaparecio el problema de coordinar la
numeracion entre archivos, porque ya no hay numeracion que coordinar.

## El conjunto se comprueba a si mismo

`001_catalogo.sql` termina con tres verificaciones dentro de un `DO`, y cada una
**falla la migracion entera** si no cuadra:

1. el saldo de cada oferta es la suma de su kardex
2. el precio de cada oferta es el ultimo de su historial
3. toda variante tiene la oferta de la tienda

Un conjunto de datos que no se verifica es un conjunto de datos que miente en
silencio. Vale mas fallar al cargar que descubrirlo tres semanas despues.

## Un trigger se apaga a la mitad, a proposito

El trigger de `005_ofertas.sql` escribe una fila de `precio_historial` cada vez
que nace o cambia una oferta, y le pone `now()`. Eso es lo correcto para la
aplicacion, pero el conjunto de datos necesita fechas del **pasado**: sin ellas
no habria nada que reconstruir y la Entrega 1 se quedaria sin su demostracion.

Por eso el archivo abre con `ALTER TABLE oferta DISABLE TRIGGER`, escribe las
filas de precio con sus fechas, y lo vuelve a encender al final.

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
