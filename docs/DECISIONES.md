# Registro unico de decisiones

Cada entrega numero sus decisiones por su cuenta y los numeros chocaron: en
`docs/base-de-datos.md` el ADR-3 es el de las imagenes, y en el informe de la
Entrega 2 el ADR-3 es grafos contra columnar. Desde el 23 de octubre de 2026 hay
un solo registro, numerado en el orden en que se tomaron las decisiones. Esta es
la lista. Cada una esta escrita completa, con contexto, alternativas, decision,
justificacion y consecuencias, donde dice la ultima columna, y las 15 a 23 estan
en la seccion 5 del informe de la Entrega final.

La columna "Antes" dice como se cito cada una en los informes ya entregados, para
poder seguirla.

| Id | Decision | Cuando | Estado | Antes | Escrita completa en |
|---|---|---|---|---|---|
| ADR-1 | El catalogo de productos en MongoDB | Entrega 1 | Vigente | ADR-1 | `docs/base-de-datos.md` |
| ADR-2 | Las ofertas, el stock y el dinero se quedan en PostgreSQL | Entrega 1 | Vigente | ADR-2 | `docs/base-de-datos.md` |
| ADR-3 | Las imagenes, embebidas en su variante | Entrega 1 | Vigente | ADR-3 | `docs/base-de-datos.md` |
| ADR-4 | Quien propuso un producto se guarda en PostgreSQL | Entrega 1 | Vigente | ADR-4 | `docs/base-de-datos.md` |
| ADR-5 | Resenas, comentarios y likes se quedan en PostgreSQL | Entrega 2 | Vigente | ADR-5 | `docs/base-de-datos.md` |
| ADR-6 | El carrito en Redis con vencimiento | Entrega 2 | Revisada por ADR-21 | ADR-4 del informe de la Entrega 2 | Informe de la Entrega 2, 2.1 |
| ADR-7 | La oferta limitada con un script Lua en Redis | Entrega 2 | Vigente, la reserva tambien en PostgreSQL desde ADR-21 | ADR-5 del informe de la Entrega 2 | Informe de la Entrega 2, 3.1 |
| ADR-8 | Grafos contra columnar, decision del 3 de septiembre | Entrega 2 | Reemplazada por ADR-10 el 6 de septiembre | ADR-3 del informe de la Entrega 2 | `docs/DECISION-GRAFOS-VS-COLUMNAR.md` |
| ADR-9 | Neo4j para los anillos de resenas | Entrega 2 | Vigente, ampliada por ADR-19 | ADR-7 del informe de la Entrega 2 | Informe de la Entrega 2, 5.1 |
| ADR-10 | ClickHouse para eventos y tendencias | Entrega 2 | Vigente | ADR-6 del informe de la Entrega 2 | Informe de la Entrega 2, 6.1 |
| ADR-11 | Elasticsearch para la busqueda del catalogo | Entrega 3 | Vigente, ampliada por ADR-20 y ADR-23 | ADR-9 del informe de la Entrega 3 | Informe de la Entrega 3, 2.1 |
| ADR-12 | Los pagos se quedan en PostgreSQL y no van a NewSQL | Entrega 3 | Vigente | ADR-8 del informe de la Entrega 3 | `docs/DECISION-NEWSQL-PAGOS.md` |
| ADR-13 | Los vectores en pgvector, con dos revisiones | Entrega final | Vigente desde el 16 de octubre | ADR-10 | Informe de la Entrega final, 2.1 y 2.2 |
| ADR-14 | Control de acceso por servicio en cada base | Entrega final | Ampliada el 23 de octubre | ADR-11 | Informe de la Entrega final, 3.1, y `docs/SEGURIDAD.md` |
| ADR-15 | El registro de inicios de sesion en MongoDB con copia en Elasticsearch | 2026-09-10 | Vigente | sin registro | Informe de la Entrega final, 5.2 |
| ADR-16 | El vencimiento de los descuentos en PostgreSQL | 2026-09-26 | Vigente | sin registro | Informe de la Entrega final, 5.2 |
| ADR-17 | Un solo modelo de senales de fraude | 2026-09-30 | Vigente | propuesta ADR-14 en `docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md` | Informe de la Entrega final, 5.2 |
| ADR-18 | Comprar sin MongoDB | 2026-10-01 | Vigente | propuesta ADR-12 | Informe de la Entrega final, 5.3 |
| ADR-19 | Las compras en el grafo de Neo4j | 2026-10-16 | Vigente | sin registro | Informe de la Entrega final, 5.4 |
| ADR-20 | El buscador de ofertas y los avisos con percolator | 2026-10-17 | Vigente | sin registro | Informe de la Entrega final, 5.4 |
| ADR-21 | La verdad del carrito y de las reservas en PostgreSQL | 2026-10-17 | Vigente | propuesta ADR-13 | Informe de la Entrega final, 5.4 |
| ADR-22 | Un respaldo por base, con cortacircuitos | 2026-10-20 | Vigente | sin registro | Informe de la Entrega final, 5.4, y `docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md` |
| ADR-23 | La tarjeta del buscador sale entera de Elasticsearch, con su foto | 2026-10-23 | Vigente | sin registro | Informe de la Entrega final, 5.4 |
| ADR-24 | Un ACL en la aplicacion, por oferta | 2026-10-26 | Vigente | sin registro | Aqui abajo, y `docs/SEGURIDAD.md` |
| ADR-25 | La categoria del producto vive tambien en el grafo, para ordenar por grupos | 2026-10-26 | Vigente | sin registro | Aqui abajo |
| ADR-26 | Un ACL de funcionalidades, por rol, en PostgreSQL | 2026-10-28 | Vigente | sin registro | Aqui abajo, y `docs/SEGURIDAD.md` |

De las seis decisiones propuestas el 28 de septiembre en
`docs/PROPUESTAS-FRAUDE-Y-DEPENDENCIAS.md`, tres se hicieron tal cual (ADR-17,
ADR-18 y ADR-21). Las detecciones como serie de tiempo en ClickHouse y el grafo
de identidad para armar los casos no se implementaron, y la busqueda hibrida
termino con el vector solo en pgvector (ADR-13).

La regla desde ahora: una decision nueva entra a esta tabla con el siguiente
numero, en el mismo cambio que el codigo que la implementa.

Las tres ultimas son posteriores al informe de la Entrega final y estan
escritas completas aqui.

## ADR-24. Un ACL en la aplicacion, por oferta

**Contexto.** El control de acceso de las bases (ADR-14) es por servicio. El
backend entra como `mesh_backend`, las herramientas con usuarios que solo
miran, y Redis tiene su ACL nativo. Pero ninguna base sabe que persona esta
detras de una peticion, porque todas llegan con el mismo usuario. Dentro de la
tienda la regla era fija y estaba escrita en el SQL, una oferta la toca solo
su dueno (`WHERE o.id_usuario = $...`, siete veces en el servicio de ofertas).
No habia forma de que la tienda dejara a un empleado cambiar el precio de una
oferta sin darle su contrasena. El profesor comento que el ACL puede vivir en
la aplicacion.

**Alternativas.**
1. No cambiar nada, con los roles (comprador, vendedor, admin) y la regla del
   dueno.
2. Usuarios de base por persona y Row Level Security en PostgreSQL. Habria que
   pasarle a la base quien es la persona en cada peticion y escribir politicas
   para cada tabla, y filtraria tambien las rutas de lo propio.
3. Reescribir cada `WHERE` del dueno como mio o compartido conmigo. Toca unos
   veinte lugares (ofertas, reglas, venta relampago, el buscador de ofertas) y
   basta con olvidar uno.
4. Un ACL en tablas de PostgreSQL, revisado por un guard del backend, en rutas
   nuevas para lo compartido, sin tocar las de lo propio.

**Decision.** La 4, con la migracion 049. `permiso_oferta` guarda la oferta, la
cuenta, el permiso (`ver`, `editar` o `descuento`), quien lo dio y hasta
cuando, y `auditoria_permiso_oferta` guarda el registro. `PermisoOfertaGuard`
va despues de `SesionGuard` en `/compartidas/ofertas` y busca una entrada
vigente de esa cuenta, esa oferta y ese permiso. Sin ninguna entrada contesta
404, para no confirmar que la oferta existe. Con alguna, pero no la que pide la
ruta, contesta 403 con el permiso que falta (desde el 28 de octubre; antes era
404 tambien, y quien ya veia la oferta leia "no existe"). El dueno reparte en
`/vendedor/ofertas/:id/permisos`. Desde ADR-26 la ruta pasa antes por el permiso
del rol (`ofertas.usar_compartidas`).

**Justificacion.** Es un ACL en el sentido clasico, la lista va pegada al
objeto y lo que no esta se niega, y vive donde se conoce a la persona. Las
rutas nuevas llaman al mismo `OfertasVendedorService` de siempre a nombre del
dueno, asi que las reglas de precio, descuento, existencia y venta relampago no
se copian. Como las rutas de lo propio no se tocan, lo que ya estaba probado
sigue igual y la prueba se concentra en lo nuevo.

**Consecuencias.** Cada permiso se revisa por separado (`ver` no deja editar),
vence solo y se quita al instante. Cada accion por la via compartida queda en el
registro con quien la hizo de verdad, porque el historial de precios la anota a
nombre del dueno. Ese registro se escribe despues de que la accion salio bien y
no en su misma transaccion, asi que si fallara la accion queda hecha y el
backend lo avisa en su log. Un permiso compartido no abre `/vendedor/ofertas`.
Pruebas, `bash pruebas/acl_ofertas.sh` y `node pruebas/acl_ofertas_azar.mjs`.
El control de acceso de las bases sigue siendo el que pide el enunciado, y este
lo complementa con la capa de las personas.

## ADR-25. La categoria del producto vive tambien en el grafo

**Contexto.** Quienes lo compraron tambien llevaron (Neo4j, ADR-19) ordenaba
solo por cuantas cuentas compraron los dos productos. En la ficha de una laptop
salia primero un telefono con cuatro compradores que otra laptop con uno. Se
pidio que los de la misma categoria vayan siempre primero, como un grupo. El
`:Producto` del grafo solo tenia `id` y `nombre`.

**Alternativas.**
1. No cambiar nada.
2. Reordenar en el backend despues de la consulta, con la categoria que trae la
   ficha de cada candidato.
3. Guardar en el grafo toda la ficha (nombre, foto, precio, existencia) para no
   depender de MongoDB.
4. Guardar solo la categoria en el `:Producto` y ordenar en el Cypher.

**Decision.** La 4. `:Producto` lleva `id_categoria` y `categoria`, que salen de
`producto_catalogo`. Las escriben los workers de compras y de resenas y el ETL
del grafo al crear o tocar un nodo, y `GrafoCategoriasSyncService` compara cada
minuto todos los `:Producto` con PostgreSQL y corrige los que no coinciden. El
Cypher pone `grupo` 0 a la misma categoria y 1 al resto y ordena por grupo,
compradores e id. El respaldo de PostgreSQL ordena igual.

**Justificacion.** La regla queda en la misma consulta que la recomendacion, y
el `LIMIT` corta con el grupo ya puesto. La categoria casi no cambia, asi que la
copia cuesta poco. El precio y la existencia si cambian a cada rato, y por eso
no se copian, la 3 seria una cuarta copia del catalogo. Con MongoDB caido la
recomendacion ya funcionaba, porque las tarjetas salen de la copia del catalogo
en PostgreSQL.

**Consecuencias.** Un cambio de categoria por la API llega al grafo en menos de
un minuto (medido entre 14 y 59 s), y mientras tanto el orden puede usar la
categoria vieja. Un producto que no esta en la copia del catalogo no tiene
categoria y cae en el grupo del resto. Prueba,
`bash pruebas/tambien_compraron_categoria.sh`.

## ADR-26. Un ACL de funcionalidades, por rol, en PostgreSQL

**Contexto.** El profesor pidio el control de acceso en dos niveles, el de las
bases y el de las funcionalidades, y que se pueda ensenar llamando al backend
directo, sin la pagina, con una cuenta que no tiene permiso y recibe un error.
El de las bases ya estaba (ADR-14). El de las funciones existia como roles, con
`@Roles(...)` en 38 lugares del codigo, revisados por `SesionGuard`. Funcionaba
(403 al rol equivocado), pero la lista de que rol puede que vivia en el codigo,
no se podia ensenar como datos y cambiarla obligaba a compilar. En sentido
estricto eso es control por roles escrito a mano, no una lista de control de
acceso. El ACL de ADR-24 si lo es, pero solo para las ofertas compartidas.

**Alternativas.**
1. No cambiar nada y explicar los `@Roles` como el control de las funciones.
2. Una tabla de permisos por persona para cada funcion. Se pisaria con
   `permiso_oferta` (dos lugares para darle algo a una cuenta) y con tres roles
   no hace falta.
3. Usuarios de PostgreSQL por persona con Row Level Security. Mismo problema que
   en ADR-24: la base no sabe que persona esta detras de cada peticion.
4. Las acciones y quien las tiene en tablas de PostgreSQL, por rol, revisadas en
   cada peticion por un guard del backend.

**Decision.** La 4, con la migracion 050, en tercera forma normal.
`modulo_permiso` (17 modulos) y `permiso` (38 acciones, cada una dentro de su
modulo; el codigo `ofertas.publicar` se arma con un JOIN y no se guarda)
son los catalogos. `rol_permiso` es el ACL, una fila por rol y permiso con quien
lo dio y cuando. `auditoria_permiso` guarda cada intento negado con su ruta y
cada permiso dado o quitado. La vista `permisos_por_rol` la ensena como matriz.
Cada una de las 136 rutas privadas declara su accion con `@Permiso(...)`, y
`PermisoGuard`, despues de `SesionGuard`, pregunta a `rol_permiso` en ese momento
si el rol de la cuenta la tiene. Sin ella, 403 con el codigo que falta. Los
`@Roles` desaparecieron y `SesionGuard` solo autentica (401). El admin ve y
cambia la matriz en el panel, seccion Permisos, por `/admin/permisos`.

**Justificacion.** La lista ahora son datos: se lee con un SELECT, se cambia con
una fila y vale en la peticion siguiente, sin compilar ni reiniciar. Negar por
defecto es literal, una ruta privada sin `@Permiso` tambien se niega. La semilla
reproduce exactamente los roles de antes, ruta por ruta, asi que el primer dia
nada cambio para nadie; `pruebas/permisos_cobertura.cjs` lo comprueba contra la
matriz guardada antes de la 050 (`pruebas/permisos_matriz_antes_050.json`). Los
permisos por persona siguen siendo los de las ofertas (ADR-24), y una ruta de
`/compartidas/ofertas` pasa por los dos: primero el rol, despues la oferta.

**Consecuencias.** Son tres capas que no se pisan: las bases por servicio
(ADR-14), las funciones por rol (esta) y cada oferta por persona (ADR-24). Cada
peticion privada hace una consulta mas, por llave, con el mismo limite corto
que la de la sesion. Si PostgreSQL no contesta, el guard usa la ultima matriz que
leyo entera (al arrancar y cada minuto), igual que la sesion se cree a su token,
y la tienda se sigue pudiendo mirar. El rol que cuenta es el del token, como con
los `@Roles`: un cambio de rol de una cuenta vale cuando vuelve a entrar.
`cuenta.ver` (la sesion no abriria sin el) y `permisos.*` del admin (nadie
podria devolverlos) no se pueden quitar por la API; con SQL a mano si. Pruebas,
`node pruebas/permisos_cobertura.cjs` y `bash pruebas/permisos_rol.sh`. Demo,
`.\demo-entrega-final.ps1 -Parte permisos`.
