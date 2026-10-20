# Clasificador de resenas

Dice si el TEXTO de una resena es bueno o malo, sin mirar las estrellas. Sirve
para la senal de fraude "nota que no cuadra": una resena de 5 estrellas cuyo
texto dice "llego roto y nadie contesta", o al reves.

Esta aparte del backend a proposito. Aqui se entrena; el backend solo carga el
JSON de `modelo/` y hace la cuenta.

## Como se corre

Pide Python 3 con numpy (scikit-learn es opcional, solo para comparar) y Ollama
encendido con `paraphrase-multilingual`, el mismo de la recomendacion semantica.
`etl/cargar_vectores.ps1` lo enciende y lo baja si falta.

```
python 1_vectorizar.py      datos/*.json a vectores/vectores.json (un minuto la primera vez)
python 2_entrenar.py        entrena los dos modelos y escribe modelo/
node predecir.mjs --verificar
node predecir.mjs "llego roto y nadie contesta" --estrellas 5
```

## Que hay en cada carpeta

```
datos/          480 resenas escritas a mano, de hasta 250 caracteres (la app acepta de 40 a 350)
                buenas_1 y buenas_2   200 buenas (4 y 5 estrellas)
                malas_1 y malas_2     200 malas (1 y 2 estrellas)
                casos_unicos          80 casos dificiles que NUNCA se usan para entrenar,
                                      cada uno con su campo `caso` (sarcasmo, sin tildes,
                                      calo chapin, actualizaciones, nota que no cuadra...)
vectores/       el vector de cada resena (no se sube, se regenera)
semilla/        generar.js escribe resenas.sql (las 480 sembradas como resenas de
                verdad, de 40 cuentas con su compra pagada, cada una en el producto
                del que habla su texto) y quitar.sql (la deshace, y desde el 18-10
                anota sus pedidos en pedido_quitado para que el ETL de compras los
                borre tambien de ClickHouse). arrancar.ps1 corre resenas.sql en cada
                arranque, en el paso Resenas del clasificador. generar.js lee los
                vectores de los productos de vector_producto de PostgreSQL (desde el
                19-10; antes de Elasticsearch) por localhost con el .env de la raiz.
                Al pasarlo, 20 resenas que caian en productos de prueba del panel
                (crepas, barbuchin) pasaron a productos de verdad: 464 de 480 caen
                en el producto del que habla su texto
modelo/         regresion_logistica.json y red_neuronal.json, listos para el backend;
                verificacion.json para comprobar que el backend calcula lo mismo;
                reporte.txt con las notas de la ultima corrida
```

La etiqueta es lo que dice el texto. En `casos_unicos` los casos
`nota_no_cuadra` llevan a proposito estrellas contrarias a su texto.

## Los dos modelos

Los dos estan hechos a mano con numpy para ver que pasa por dentro, y dan la
probabilidad de que el texto sea malo.

- Regresion logistica. `p = sigmoide(x . w + b)`, un peso por cada numero del
  vector. Se comprueba contra la de scikit-learn y dan lo mismo.
- Red neuronal. 768 entradas, 32 neuronas ReLU y una salida sigmoide, con
  Adam, dropout y parada temprana. El backpropagation pasa un gradient check.

Medido el 2026-10-02. En la prueba normal los dos aciertan el 100 % (ese set
es facil). En los 80 casos unicos la red acierta 91 % y la regresion 90 %, y
con otras semillas la diferencia sigue siendo de una o dos resenas. Los dos
fallan el sarcasmo (0 de 3), porque las palabras dicen lo contrario de lo que
se quiere decir. Por eso la senal va al admin para que revise y nunca bloquea
sola.

## Como lo usaria el backend

1. Pedir el vector del texto a Ollama, igual que `VectoresSyncService`
   (`POST /api/embed`, mismo modelo).
2. Normalizarlo a largo 1.
3. Hacer la cuenta de `predecir.mjs` (`probabilidadMala`) con los pesos del JSON.
4. Si la probabilidad pasa de `umbral_fraude` (0.8) y la resena tiene 4 o 5
   estrellas, o baja de 0.2 con 1 o 2 estrellas, la nota no cuadra con el texto.

Si se cambia el modelo de vectores hay que volver a correr los dos pasos: los
pesos solo sirven para los vectores con los que se entrenaron.
