# Guion de la presentacion final

Unos 15 minutos, mas la demo y las preguntas. Cada uno presenta lo que hizo. El
texto es una guia para decirlo con las propias palabras, no para leerlo.

| Laminas | Quien | Tiempo |
|---|---|---|
| 1 a 6, la tienda y la arquitectura | Jose Manuel | 4 min |
| 7 a 9, la recomendacion semantica | Jose David | 3 min |
| 10 a 13, el control de acceso por servicio y por persona | Jose Manuel | 4 min |
| 14, si se cae una base | Juan Pablo | 1 min |
| 15 y 16, el buscador y las decisiones | Jose David | 2 min |
| 17 y 18, la retrospectiva | Juan Pablo | 2 min |
| 19, la demo | los tres | 5 min |

## 1. Portada (Jose Manuel)
Somos Mesh. Hicimos TiendaYa con seis bases de datos, y cada una entro por la
forma de la pregunta que contesta, no por tener muchas.

## 2. El equipo (Jose Manuel)
Jose David llevo el backend, yo los datos, el frontend y el arranque, y Juan
Pablo los modulos de ClickHouse y Neo4j.

## 3. El reto (Jose Manuel)
Muchos vendedores comparten un catalogo. El producto no es de nadie y la oferta
si. Las cifras, seis bases, 89 tablas de 49 migraciones, 25 decisiones con su
registro y 93 comprobaciones del control de acceso, ninguna mal.

## 4. Cada base por su pregunta (Jose Manuel)
Recorrer las seis tarjetas de izquierda a derecha. PostgreSQL es el dinero,
MongoDB el catalogo, Redis lo rapido y atomico, Neo4j las relaciones, ClickHouse
los eventos y Elasticsearch la busqueda.

## 5. La regla (Jose Manuel)
PostgreSQL es la verdad y lo demas se puede rehacer. Si preguntan por que no todo
en PostgreSQL, cada base contesta mejor su pregunta, pero solo una guarda la
verdad.

## 6. El diagrama (Jose Manuel)
Flechas continuas, lo que hace el backend. Punteadas y numeradas, datos que
viajan entre bases. Ollama tiene su caja y cada base dice con que usuario entra
el backend. Sale de `docs/generar-arquitectura.py`.

## 7. Recomendacion semantica (Jose David)
Los cuatro pasos. El texto sale de MongoDB, Ollama lo vuelve 768 numeros, se
guarda en pgvector con un indice HNSW y la ficha pide los seis mas cercanos.
Las cifras, 1000 de 1001 contra el coseno exacto, 3,8 ms, y 66 por ciento en la
misma categoria contra 6 al azar.

## 8. En la tienda (Jose David)
Una frase sin ninguna palabra en comun encuentra audifonos por lo que dicen las
resenas. Y la ficha con sus parecidos.

## 9. El viaje del vector (Jose David)
pgvector, despues Elasticsearch por comodidad, y de vuelta a pgvector cuando se
midio la precision. La leccion, una decision comoda tambien hay que medirla.

## 10. Control de acceso (Jose Manuel)
Cada servicio entra con lo justo. El backend lee y escribe datos y no puede
crear ni borrar tablas, colecciones o indices. Las herramientas solo miran.

## 11. Lo que encontramos (Jose Manuel)
Ser honestos. Elasticsearch estaba abierto con un comentario que decia lo
contrario, DbGate entraba como root, y Neo4j no puede porque su edicion gratuita
no trae roles. Los tres estan corregidos o explicados.

## 12. La prueba (Jose Manuel)
93 bien y 0 mal. Cada negativa tiene su control, y lo peligroso nunca se intenta
a ciegas.

## 13. Un ACL por oferta (Jose Manuel)
Lo de antes es por servicio, y lo hacen cumplir las bases. Pero ninguna base
sabe que persona pide, todo llega como mesh_backend. Por eso el permiso de cada
persona vive en la aplicacion, como dijo el profesor. Cada oferta lleva su
lista en PostgreSQL, quien puede verla, editarla o ponerle descuento y hasta
cuando, y un guard del backend la revisa antes de cada ruta. Lo que no esta en
la lista se niega con el mismo 404 de una oferta ajena. Si preguntan si es un
ACL de verdad, si, es una lista pegada a cada objeto que niega por defecto. Si
preguntan por que no en la base, porque la base no conoce a las personas de la
tienda. 84 comprobaciones de cada regla y casi cinco mil al azar contra un
modelo, ninguna mal.

## 14. Si se cae una base (Juan Pablo)
Cada base tiene su respaldo. Con cualquiera caida menos PostgreSQL se sigue
comprando. Con PostgreSQL caido no se cobra nada a medias.

## 15. La foto en el buscador (Jose David)
Lo pidio el profesor. La foto viaja en el mismo documento de Elasticsearch,
guardada sin indexar, y la tarjeta sale de una sola consulta.

## 16. Las 25 decisiones (Jose David)
Los numeros chocaban entre entregas y ahora hay un solo registro. Las verdes son
las que faltaban, como comprar sin MongoDB o el carrito en PostgreSQL.

## 17. Retrospectiva (Juan Pablo)
Siete que sostendriamos y ocho que no. La mas clara, el carrito solo en Redis,
que el 17 de octubre paso a tener su verdad en PostgreSQL.

## 18. Lo aprendido (Juan Pablo)
Cada dato con un solo dueno escrito.

## 19. Demo (los tres)
En el panel de comandos (`.\panel-comandos.ps1`), en este orden.
1. Buscar `labtop` y luego una frase, en la tienda. Se ven las fotos.
2. Abrir una laptop y bajar a Parecidos a este.
3. `.\demo-entrega-final.ps1 -Parte acceso`, y si hay tiempo
   `bash seguridad/prueba_acceso.sh`.
4. Caida de una base, apagar Redis o MongoDB y recargar la tienda.
5. Compartir una oferta. En Edge, ventas.norte abre Ofertas, Compartir, y le da
   ver y editar a ventas.sur. En otra ventana privada, ventas.sur abre
   Compartidas y cambia el precio. ventas.norte le quita editar, ventas.sur
   intenta otra vez y la pagina le dice que ya no tiene permiso. En el registro
   de la oferta queda todo, con el intento negado en rojo. Las dos cuentas usan
   Vendedor123.

## 20. Gracias
Preguntas. Las respuestas cortas estan en `PREGUNTAS-SUSTENTACION.md`, 161.

## Antes de presentar
- Las dos PC en la misma red y sin cambiarse de red durante la demo. El 23 de
  octubre un cambio de red corto las bases de la PC de Jose David unos 20
  minutos, y la tienda siguio con sus respaldos pero las demos que hablan con
  las bases fallaron.
- Con las bases en la PC de Jose David, Tailscale prendido en las dos y
  `.\usar-bases-remotas.ps1 -Ip 100.64.42.11` antes de prender el backend.
- `ollama serve` prendido en la PC del backend y una busqueda por frase de
  prueba antes de empezar. El backend le pide a Ollama que deje el modelo
  cargado, asi que despues de esa primera busqueda las demas tardan un segundo.
- Para apagar una base en vivo con las bases en otra PC, correr
  `.\remoto\caidas.ps1 -Accion levantar` unos minutos antes (tarda unos 3).
- No correr la bateria de pruebas el mismo dia. Deja cuentas, ofertas a Q15 y
  senales de fraude de prueba.
