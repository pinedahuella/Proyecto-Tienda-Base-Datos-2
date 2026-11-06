# Presentacion de la Entrega final

Una sola pagina HTML de 1920x1080 que se escala a la pantalla, con la misma
tecnica de las presentaciones de LECTORTIE e ITIL. 25 laminas en tres partes,
la tienda y sus seis bases (1 a 7), lo que la tienda aprende y como resiste (8 a
13) y la Entrega final con los vectores y el control de acceso (14 a 25).

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
  `docs/diagrama-arquitectura.png`), las fotos del equipo y el escudo.
- `GUION.md` dice quien presenta cada lamina, que decir, que se hace en la
  pantalla y en que archivo y linea esta cada cosa.
- `postman/` tiene la coleccion de Postman de la lamina 24, 62 peticiones, 54
  que comprueban los 401 y 403 y 8 que intentan una inyeccion SQL. Las claves
  de las bases van en `postman/secrets/`, que no se sube a git.
  `postman/importar-a-postman.ps1` lee esas claves del `.env` de la raiz y mete
  la coleccion y su ambiente en el Postman de quien lo corra. Como se usa esta
  en `docs/GUIA-ESTUDIO-ACL.md`, seccion 6.

Los colores de cada base son los del diagrama de arquitectura. El fondo es una
malla de puntos de esos seis colores que se mueve despacio y se queda quieta si
el sistema pide menos movimiento.

Si cambia una cifra, cambiarla aqui y en el informe a la vez. Las de hoy salen
de la prueba de acceso (93), de la recomendacion (1000 de 1001 y 3,8 ms del 16
de octubre, y del 5 de noviembre 68 por ciento solo por el vector y 1000 de 1000
iguales al calculo exacto con el orden por bloques), de la prueba de caidas (51)
y de la coleccion de Postman (62).
