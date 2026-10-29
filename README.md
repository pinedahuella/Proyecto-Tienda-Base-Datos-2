# Mesh

Proyecto de Bases de Datos 2, Universidad del Istmo. Mesh es nuestra version de
TiendaYa, una tienda en linea donde varios vendedores comparten un mismo
catalogo, con los datos repartidos entre seis bases segun la forma de la
pregunta que cada una contesta.

| Base | Que guarda |
|---|---|
| PostgreSQL 18 con pgvector | La verdad: cuentas, ofertas, stock, pedidos, pagos, el carrito, resenas, fraude, la copia del catalogo y los vectores |
| MongoDB 8 | El catalogo con atributos por categoria, su historial y el registro de inicios de sesion |
| Redis 8 | Copia rapida del carrito, venta relampago con un script Lua, candado del checkout, contadores y rankings ya calculados |
| Neo4j 5 | Cuentas, resenas, compras y productos como grafo: anillos de fraude y recomendaciones |
| ClickHouse 25.3 | Eventos en el tiempo: vistas, carrito, busquedas, compras y tendencias |
| Elasticsearch 8.15 | Buscador de productos (con su foto) y de ofertas, avisos con percolator, copia del registro de inicios de sesion |

Ollama calcula en la misma PC los vectores de la recomendacion semantica, con el
modelo `paraphrase-multilingual`. El diagrama de todo esta en
[docs/diagrama-arquitectura.png](docs/diagrama-arquitectura.png).

```
backend/            API en NestJS con Fastify
frontend/           Interfaz en SvelteKit
migrations/         Esquema SQL (001 a 050) y el generador de datos
mongo/              Colecciones e indices de MongoDB
etl/                Cargas entre bases (catalogo, grafo, buscador, eventos, vectores)
redis/ neo4j/ clickhouse/ elastic/    Scripts y pruebas de cada base
seguridad/          Usuarios de cada base y la prueba del control de acceso
pruebas/            Pruebas de punta a punta contra el sistema corriendo
remoto/             Usar las bases desde otra PC por Tailscale
panel-comandos/     Pagina de botones para correr los comandos y las demos
presentacion-final/ Las diapositivas de la Entrega final
docs/               Documentacion
docker-compose.yml  Las seis bases y sus herramientas
```

## Que se puede hacer

El comprador busca (tolera errores de tecleo, filtra por categoria, precio, nota
y disponibilidad, y entiende frases por su significado), abre la ficha con los
parecidos y las ofertas de cada vendedor, arma el carrito, paga con la tarjeta
simulada, ve sus pedidos tal como era el producto el dia de la compra, resena y
pide un aviso cuando llegue algo o baje un precio.

El vendedor publica ofertas, les pone descuento o venta relampago, busca entre
las suyas, comparte una oferta con otra cuenta (ver, editar o poner descuento,
con vencimiento) y propone productos nuevos para el catalogo compartido. La tienda y el
administrador revisan ofertas y propuestas, administran el catalogo con su
historial por fecha, ven tendencias y el dashboard general, y revisan las
senales y casos de fraude (anillos de resenas, textos repetidos, notas que no
cuadran, fuerza bruta, viaje imposible y mas).

Si se cae una base, la tienda sigue con las que quedan, cada una con su respaldo
([docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md](docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md)).

## Seguridad

Cada servicio entra a cada base con su propio usuario: el backend como
`mesh_backend`, que solo lee y escribe datos, y las ventanas de inspeccion con
usuarios que solo miran. Elasticsearch pide contrasena. Las herramientas solo se
abren desde la misma PC. Neo4j es la excepcion, porque su edicion community no
tiene roles. Todo esta en [docs/SEGURIDAD.md](docs/SEGURIDAD.md) y se prueba con
`bash seguridad/prueba_acceso.sh` (93 comprobaciones).

Dentro de la tienda hay dos ACL mas, en PostgreSQL. El de funcionalidades
(ADR-26, migracion 050): cada ruta privada pide una accion (`ofertas.publicar`) y
la tabla `rol_permiso` dice que rol la tiene; sin ella, 403 aunque se llame a la
ruta directo, y el intento queda en `auditoria_permiso`. El admin lo cambia en
el panel, seccion Permisos, y vale en la peticion siguiente. Y el de cada oferta
(ADR-24): el dueno le da a otra cuenta permiso para ver, editar o poner
descuento. En los dos, lo que no esta en la lista se niega. Se prueban con
`node pruebas/permisos_cobertura.cjs`, `bash pruebas/permisos_rol.sh`,
`bash pruebas/acl_ofertas.sh` y `node pruebas/acl_ofertas_azar.mjs`, y se
ensenan con `.\demo-entrega-final.ps1 -Parte permisos`.

Las contrasenas viven en `.env` y `backend/.env`, que no se suben. `arrancar.ps1`
genera las que falten.

## Arranque rapido

Hace falta Node.js 24, Docker Desktop y Git, nada mas: las bases, sus ventanas y
Ollama llegan como contenedores
([docs/instalacion.md](docs/instalacion.md)).

La primera vez, despues de clonar:

```powershell
copy .env.example .env                          # contrasenas de las bases, cambialas si quieres
copy backend\.env.example backend\.env
cd backend; npm install; cd ..\frontend; npm install; cd ..
```

Y cada vez:

```powershell
.\arrancar.ps1                                  # bases, migraciones, datos, usuarios
.\panel-comandos\servicios.ps1 -Accion backend  # http://localhost:3000
.\panel-comandos\servicios.ps1 -Accion frontend # http://localhost:5173
.\panel-comandos.ps1                            # botones en http://127.0.0.1:5199
```

En Docker Desktop, `mesh-elastic-usuarios` y `mesh-kibana-vistas` aparecen
apagados. Es lo esperado: en cada arranque crean los usuarios de Elasticsearch y
las vistas de Kibana y terminan con `Exited (0)`.

Con las bases en otra PC: esa PC corre `.\preparar-pc-bases.ps1` y la de trabajo
`.\usar-bases-remotas.ps1 -Ip 100.x.y.z` (y `-Local` para volver).

Las ventanas, solo desde la misma PC: pgAdmin http://localhost:5050, DbGate
http://localhost:3001, RedisInsight http://localhost:5540, Kibana
http://localhost:5601 (entrar con `mesh_lectura`), Neo4j http://localhost:7474 y
ClickHouse http://localhost:8123/play.

Cuentas de prueba: `admin@mesh.com` con `Admin123`, y las demas en
[docs/instalacion.md](docs/instalacion.md).

## El conjunto de datos

102 productos curados en 17 categorias, con imagen, ofertas, cuentas, pedidos,
resenas y semillas de descuentos, combos y fraude, escritos por
`node migrations/datos/generador.js` con semilla fija. `.\arrancar.ps1
-Productos N` agrega copias generadas para llegar a N productos (las pruebas de
carga usaron 1000 y 3105).

## Entregas

| Entrega | Informe | Lo que sumo |
|---|---|---|
| Primera | `Reporte Primera Entrega - DABD2 - Mesh.docx` | El catalogo en MongoDB y su historial por fecha |
| Segunda | `Reporte Segunda Entrega - DABD2 - Mesh.docx` | Carrito en Redis, venta relampago sin sobreventa, fraude en resenas con Neo4j y tendencias en ClickHouse |
| Tercera | `Reporte Tercera Entrega - DABD2 - Mesh.docx` | Buscador en Elasticsearch, consistencia del checkout, la prueba de falla y por que los pagos no van a NewSQL |
| Final | `Reporte Entrega Final - DABD2 - Mesh.docx` | Recomendacion semantica con pgvector, control de acceso en las bases, diagrama final y retrospectiva |

Las diapositivas de la presentacion final se abren con
`presentacion-final/index.html`, y su guion esta en
[presentacion-final/GUION.md](presentacion-final/GUION.md).

## Pruebas y demos

```bash
bash pruebas/correr_todas.sh        # las 46 pruebas de punta a punta, mas de media hora
bash seguridad/prueba_acceso.sh     # el control de acceso de las seis bases
```

```powershell
.\demo-entrega-final.ps1 -Parte semantica -Producto laptop   # los parecidos de un producto
.\demo-entrega-final.ps1 -Parte bases                        # el control de acceso, en vivo
.\remoto\caidas.ps1 -Accion levantar                         # para apagar una base en vivo
```

Necesitan las bases y el backend arriba. Cada demo dice al principio lo que
ensena y lo que toca, y todas tienen su boton en `.\panel-comandos.ps1`.

## Documentacion

| Archivo | Contenido |
|---|---|
| [docs/instalacion.md](docs/instalacion.md) | Que instalar, como levantar todo, errores comunes |
| [docs/ARQUITECTURA.md](docs/ARQUITECTURA.md) | La arquitectura, flujo por flujo, y su historia |
| [docs/DECISIONES.md](docs/DECISIONES.md) | El registro unico de decisiones, ADR-1 a ADR-26 |
| [docs/SEGURIDAD.md](docs/SEGURIDAD.md) | Usuarios de cada base, puertos e imagenes |
| [docs/base-de-datos.md](docs/base-de-datos.md) | El modelo relacional y documental, y ADR-1 a ADR-5 |
| [docs/CONSISTENCIA-CHECKOUT.md](docs/CONSISTENCIA-CHECKOUT.md) | Que pasa en el pago si falla cada paso |
| [docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md](docs/QUE-PASA-SI-SE-CAE-UNA-BASE.md) | El respaldo de cada base y como apagarlas en vivo |
| [docs/DECISION-GRAFOS-VS-COLUMNAR.md](docs/DECISION-GRAFOS-VS-COLUMNAR.md) | ADR-8, grafos contra columnar |
| [docs/DECISION-NEWSQL-PAGOS.md](docs/DECISION-NEWSQL-PAGOS.md) | ADR-12, por que los pagos no van a NewSQL |
| [docs/FRAUDE-CATALOGO.md](docs/FRAUDE-CATALOGO.md) | Cada tipo de fraude, como se detecta y como se demuestra |
| [docs/FRAUDE-DETECCION-Y-CASOS.md](docs/FRAUDE-DETECCION-Y-CASOS.md) | Senales, casos y avisos |
| [docs/api.md](docs/api.md) | Estandar de respuestas y endpoints |
| [docs/frontend.md](docs/frontend.md) | Paginas, paleta y tema claro u oscuro |
| [remoto/README.md](remoto/README.md) | Las bases en otra PC por Tailscale |
| [migrations/README.md](migrations/README.md) | Como se nombran y se corren las migraciones |
| [etl/README.md](etl/README.md) | Las cargas entre bases |
| [comandos.txt](comandos.txt) | Todos los comandos, con lo que hace cada uno |
| [PREGUNTAS-SUSTENTACION.md](PREGUNTAS-SUSTENTACION.md) | 170 preguntas para la sustentacion, con donde se ve cada cosa |

Los informes de cada entrega estan en la raiz, en Word, y salen de los
`contenido-*.json` con sus `generar-reporte-*.py`.
