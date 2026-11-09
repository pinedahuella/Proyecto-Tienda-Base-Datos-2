# Presentacion de la Entrega final

Una sola pagina HTML de 1920x1080 que se escala a la pantalla, con la misma
tecnica de las presentaciones de LECTORTIE e ITIL. 29 laminas para 30 minutos,
en tres partes, la tienda y todo lo que hace, con un producto nuevo de punta a
punta (1 a 9), lo que la tienda aprende y como resiste, con el panel del admin
(10 a 17), y la Entrega final con los vectores y el control de acceso (18 a 29).

- Abrir `index.html` en Edge o Chrome. Flechas, espacio o clic avanzan, flecha
  izquierda o clic en el cuarto izquierdo retroceden, F pantalla completa,
  Inicio vuelve a la portada. En el telefono se desliza.
- En la lamina del diagrama, un clic sobre el diagrama lo abre a tamano
  completo para leer la leyenda (se recorre con la rueda del mouse). Otro clic
  o Esc lo cierra, y mientras esta abierto no se cambia de lamina.
- Las letras vienen de Google Fonts, asi que se ve mejor con internet.
- Para imprimir o sacar un PDF, imprimir desde el navegador: sale una lamina por
  pagina.
- `img/` tiene las capturas de la tienda, el diagrama de arquitectura (copia de
  `docs/diagrama-arquitectura.png`, que escribe `docs/dibujar-arquitectura.py`),
  las fotos del equipo y el escudo. `img/ficha-bloques.png`, la de la lamina 19,
  se saco de nuevo el 8 de noviembre con el puntaje nuevo, con Edge sin ventana.
- `GUION.md` va por orden de importancia. Arriba lo que se hace antes de
  presentar, despues las tres partes lamina por lamina, despues lo que pregunta
  el profesor con el codigo, los flujos de toda la tienda, los apoyos y el
  glosario. Cada funcionalidad dice la accion y entre parentesis el service que
  hace la logica, con su archivo y linea. Los modulos grandes y sus services,
  para buscarlos rapido, estan en `docs/MAPA-FUNCIONALIDADES.md`.
- `postman/` tiene la coleccion de Postman de la lamina 28, 64 peticiones, 56
  que comprueban los 401, 403 y 409 y 8 que intentan una inyeccion SQL. Las claves
  de las bases van en `postman/secrets/`, que no se sube a git.
  `postman/importar-a-postman.ps1` lee esas claves del `.env` de la raiz y mete
  la coleccion y su ambiente en el Postman de quien lo corra. Como se usa esta
  en `docs/GUIA-ESTUDIO-ACL.md`, seccion 6.

Los colores de cada base son los del diagrama de arquitectura anterior, el de
draw.io. El de hoy va en blanco y negro a proposito, para que se lea igual
impreso. El fondo es una
malla de puntos de esos seis colores que se mueve despacio y se queda quieta si
el sistema pide menos movimiento.

Si cambia una cifra, cambiarla aqui y en el informe a la vez. Las de hoy salen
de la prueba de acceso (93), de la recomendacion (1000 de 1001 y 3,8 ms del 16
de octubre, 68 por ciento solo por el vector del 5 de noviembre, y del 8 de
noviembre 60 de 60 iguales al puntaje calculado aparte y 58 de 60 que cambian de
orden por las caracteristicas y la nota), de la prueba de caidas (51) y de la
coleccion de Postman (64).
