"""
Paso 2. Entrena dos clasificadores con los vectores del paso 1 y los deja en
modelo/ listos para el backend.

    python 2_entrenar.py

Los dos responden lo mismo: la probabilidad de que el texto de una resena sea
MALO (0 = claramente bueno, 1 = claramente malo).

  A. Regresion logistica. Una suma con un peso por cada uno de los 768 numeros
     del vector, y la curva sigmoide para volverla probabilidad.
  B. Red neuronal de una capa oculta. 768 entradas, 32 neuronas con ReLU y una
     salida sigmoide. Puede aprender combinaciones que la regresion no ve.

Las dos estan hechas a mano con numpy, sin librerias de aprendizaje, para ver
que pasa por dentro. Para no creerle a ciegas al codigo propio:
  - la regresion se compara con la de scikit-learn (tienen que dar lo mismo)
  - el backpropagation de la red pasa un gradient check numerico
  - las notas se miden con resenas que el modelo nunca vio

Sale:
  modelo/regresion_logistica.json   pesos y sesgo
  modelo/red_neuronal.json          las dos capas
  modelo/verificacion.json          vectores con la probabilidad esperada, para
                                    comprobar que el backend calcula lo mismo
  modelo/reporte.txt                todo lo que este script imprime
"""

import json
import sys
from collections import defaultdict
from datetime import datetime

import numpy as np

from comun import ETIQUETAS, MODELO, VECTORES

SEMILLA = 42
UMBRAL = 0.5            # para decir "buena" o "mala"
UMBRAL_FRAUDE = 0.8     # para decir "el texto contradice las estrellas"

lineas_reporte = []


def decir(texto=''):
    print(texto)
    lineas_reporte.append(texto)


def sigmoide(z):
    # Se parte en dos para que exp() no se desborde con numeros muy negativos.
    return np.where(z >= 0, 1 / (1 + np.exp(-np.clip(z, 0, None))),
                    np.exp(np.clip(z, None, 0)) / (1 + np.exp(np.clip(z, None, 0))))


def perdida_logaritmica(p, y):
    """Que tan sorprendido queda el modelo con la respuesta correcta. Menos es mejor."""
    p = np.clip(p, 1e-12, 1 - 1e-12)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


# ----------------------------------------------------------------- los datos
def separar(y, rng):
    """70 % entrenar, 15 % validar (elegir ajustes) y 15 % prueba (la nota final).
    Se separa por clase para que las tres partes tengan mitad buenas y mitad malas."""
    entrenar, validar, probar = [], [], []
    for clase in (0, 1):
        indices = rng.permutation(np.where(y == clase)[0])
        n = len(indices)
        a, b = int(n * 0.70), int(n * 0.85)
        entrenar += list(indices[:a]); validar += list(indices[a:b]); probar += list(indices[b:])
    return np.array(entrenar), np.array(validar), np.array(probar)


def medir(p, y):
    prediccion = (p >= UMBRAL).astype(int)
    vp = int(np.sum((prediccion == 1) & (y == 1)))   # dijo mala y era mala
    fp = int(np.sum((prediccion == 1) & (y == 0)))   # dijo mala y era buena
    fn = int(np.sum((prediccion == 0) & (y == 1)))   # dijo buena y era mala
    vn = int(np.sum((prediccion == 0) & (y == 0)))   # dijo buena y era buena
    precision = vp / (vp + fp) if vp + fp else 0.0
    exhaustividad = vp / (vp + fn) if vp + fn else 0.0
    f1 = 2 * precision * exhaustividad / (precision + exhaustividad) if precision + exhaustividad else 0.0
    return {'exactitud': (vp + vn) / len(y), 'precision_mala': precision,
            'exhaustividad_mala': exhaustividad, 'f1_mala': f1, 'perdida': perdida_logaritmica(p, y),
            'matriz': {'buena_dijo_buena': vn, 'buena_dijo_mala': fp,
                       'mala_dijo_buena': fn, 'mala_dijo_mala': vp}}


def contar(nombre, m):
    decir(f'   {nombre:<22} exactitud {m["exactitud"]:.1%}   F1 de "mala" {m["f1_mala"]:.3f}   '
          f'perdida {m["perdida"]:.3f}')
    c = m['matriz']
    decir(f'   {"":<22} buenas bien {c["buena_dijo_buena"]}, buenas tomadas por malas {c["buena_dijo_mala"]}, '
          f'malas bien {c["mala_dijo_mala"]}, malas tomadas por buenas {c["mala_dijo_buena"]}')


# --------------------------------------------------- A. regresion logistica
class RegresionLogistica:
    """
    p = sigmoide(x . w + b)

    Se entrena con descenso de gradiente: se mira hacia donde sube el error y se
    da un paso hacia el otro lado, miles de veces. `lam` castiga los pesos
    grandes (regularizacion L2) para que no se aprenda las resenas de memoria.
    """

    def __init__(self, lam):
        self.lam = lam

    def entrenar(self, X, y, max_pasos=50000, tolerancia=1e-8):
        n, d = X.shape
        self.w, self.b = np.zeros(d), 0.0
        # Paso seguro: 1 / (la curvatura mas grande posible del error).
        paso = 1 / (np.linalg.eigvalsh(X.T @ X / n).max() / 4 + self.lam)
        for self.pasos in range(1, max_pasos + 1):
            error = sigmoide(X @ self.w + self.b) - y
            grad_w = X.T @ error / n + self.lam * self.w
            grad_b = error.mean()
            self.w -= paso * grad_w
            self.b -= paso * grad_b
            if np.sqrt(grad_w @ grad_w + grad_b ** 2) < tolerancia:
                break
        return self

    def probabilidad(self, X):
        return sigmoide(X @ self.w + self.b)

    def exportar(self):
        return {'tipo': 'regresion_logistica', 'lam': self.lam,
                'pesos': self.w.tolist(), 'sesgo': float(self.b)}


# ------------------------------------------------------- B. red neuronal
class RedNeuronal:
    """
    oculta = relu(x W1 + b1)          32 neuronas
    p      = sigmoide(oculta W2 + b2)

    Se entrena por tandas de 32 resenas con Adam (descenso de gradiente con
    impulso y un paso propio para cada peso). Mientras entrena se apaga al azar
    el 20 % de las neuronas en cada tanda (dropout), para que ninguna cargue
    sola con la decision. Se guarda el momento en que menos se equivoco con las
    resenas de validacion y se para si en `paciencia` vueltas no mejora.
    """

    def __init__(self, entradas, ocultas=32, decaimiento=1e-3, apagar=0.2, semilla=SEMILLA):
        self.rng = np.random.default_rng(semilla)
        # Inicio de He: pesos chicos al azar, a la medida de la ReLU.
        self.W1 = self.rng.normal(0, np.sqrt(2 / entradas), (entradas, ocultas))
        self.b1 = np.zeros(ocultas)
        self.W2 = self.rng.normal(0, np.sqrt(2 / ocultas), (ocultas, 1))
        self.b2 = np.zeros(1)
        self.decaimiento, self.apagar = decaimiento, apagar

    def parametros(self):
        return [self.W1, self.b1, self.W2, self.b2]

    def adelante(self, X, entrenando=False):
        z1 = X @ self.W1 + self.b1
        a1 = np.maximum(z1, 0)
        mascara = None
        if entrenando and self.apagar:
            mascara = (self.rng.random(a1.shape) >= self.apagar) / (1 - self.apagar)
            a1 = a1 * mascara
        p = sigmoide(a1 @ self.W2 + self.b2).ravel()
        return p, (X, z1, a1, mascara)

    def perdida(self, p, y):
        castigo = self.decaimiento / 2 * (np.sum(self.W1 ** 2) + np.sum(self.W2 ** 2))
        return perdida_logaritmica(p, y) + castigo

    def atras(self, p, y, guardado):
        """Backpropagation: la regla de la cadena, de la salida hacia la entrada."""
        X, z1, a1, mascara = guardado
        m = len(y)
        dz2 = (p - y).reshape(-1, 1) / m              # error en la salida
        dW2 = a1.T @ dz2 + self.decaimiento * self.W2
        db2 = dz2.sum(axis=0)
        da1 = dz2 @ self.W2.T                          # el error vuelve a la capa oculta
        if mascara is not None:
            da1 = da1 * mascara
        dz1 = da1 * (z1 > 0)                           # la ReLU solo deja pasar donde estaba encendida
        dW1 = X.T @ dz1 + self.decaimiento * self.W1
        db1 = dz1.sum(axis=0)
        return [dW1, db1, dW2, db2]

    def entrenar(self, X, y, Xv, yv, vueltas=3000, tanda=32, aprender=3e-3, paciencia=150):
        momento = [np.zeros_like(q) for q in self.parametros()]
        energia = [np.zeros_like(q) for q in self.parametros()]
        b1m, b2m, eps, t = 0.9, 0.999, 1e-8, 0
        mejor, mejor_vuelta, copia = np.inf, 0, None
        self.historia = []
        for vuelta in range(1, vueltas + 1):
            orden = self.rng.permutation(len(y))
            for desde in range(0, len(y), tanda):
                i = orden[desde:desde + tanda]
                p, guardado = self.adelante(X[i], entrenando=True)
                t += 1
                for k, (q, g) in enumerate(zip(self.parametros(), self.atras(p, y[i], guardado))):
                    momento[k] = b1m * momento[k] + (1 - b1m) * g
                    energia[k] = b2m * energia[k] + (1 - b2m) * g * g
                    q -= aprender * (momento[k] / (1 - b1m ** t)) / (np.sqrt(energia[k] / (1 - b2m ** t)) + eps)
            pv = self.probabilidad(Xv)
            error_validacion = perdida_logaritmica(pv, yv)
            self.historia.append(error_validacion)
            if error_validacion < mejor - 1e-5:
                mejor, mejor_vuelta = error_validacion, vuelta
                copia = [q.copy() for q in self.parametros()]
            elif vuelta - mejor_vuelta >= paciencia:
                break
        self.W1, self.b1, self.W2, self.b2 = copia
        self.mejor_vuelta, self.vueltas_hechas = mejor_vuelta, vuelta
        return self

    def probabilidad(self, X):
        return self.adelante(X)[0]

    def exportar(self):
        return {'tipo': 'red_neuronal',
                'capas': [
                    {'entradas': self.W1.shape[0], 'salidas': self.W1.shape[1], 'activacion': 'relu',
                     'pesos': self.W1.tolist(), 'sesgos': self.b1.tolist()},
                    {'entradas': self.W2.shape[0], 'salidas': 1, 'activacion': 'sigmoide',
                     'pesos': self.W2.tolist(), 'sesgos': self.b2.tolist()}],
                'decaimiento': self.decaimiento, 'apagar_en_entrenamiento': self.apagar}


def revisar_gradiente(X, y):
    """
    Gradient check. Para unos pesos al azar se mueve cada uno un poquito hacia
    arriba y hacia abajo, se mide cuanto cambia el error y se compara con lo que
    dijo el backpropagation. Si el backprop tuviera un error, aqui no cuadraria.
    """
    red = RedNeuronal(X.shape[1], ocultas=5, decaimiento=1e-3, apagar=0, semilla=7)
    p, guardado = red.adelante(X)
    analitico = red.atras(p, y, guardado)
    rng = np.random.default_rng(1)
    peor, h = 0.0, 1e-5
    for q, g in zip(red.parametros(), analitico):
        for _ in range(8):
            i = tuple(rng.integers(0, s) for s in q.shape)
            original = q[i]
            q[i] = original + h; arriba = red.perdida(red.adelante(X)[0], y)
            q[i] = original - h; abajo = red.perdida(red.adelante(X)[0], y)
            q[i] = original
            numerico = (arriba - abajo) / (2 * h)
            peor = max(peor, abs(numerico - g[i]) / max(1e-8, abs(numerico) + abs(g[i])))
    return peor


# ------------------------------------------------------------------ main
def main():
    datos = json.loads(VECTORES.read_text(encoding='utf-8'))
    items = datos['items']
    pool = [i for i in items if i['conjunto'] == 'entrenamiento']
    unicos = [i for i in items if i['conjunto'] == 'casos_unicos']
    X = np.array([i['vector'] for i in pool])
    y = np.array([ETIQUETAS[i['etiqueta']] for i in pool], dtype=float)
    Xu = np.array([i['vector'] for i in unicos])
    yu = np.array([ETIQUETAS[i['etiqueta']] for i in unicos], dtype=float)

    rng = np.random.default_rng(SEMILLA)
    ie, iv, ip = separar(y, rng)
    decir(f'Clasificador de resenas, {datetime.now():%Y-%m-%d %H:%M}')
    decir(f'Vectores {datos["modelo_vectores"]}, {datos["dimensiones"]} numeros, generados {datos["generado"]}')
    decir(f'Entrenar {len(ie)}, validar {len(iv)}, prueba {len(ip)}, casos unicos {len(unicos)} '
          f'(estos dos ultimos nunca se usan para aprender)')

    # ---- A
    decir('\n== A. Regresion logistica (a mano)')
    candidatos = []
    for lam in (1e-1, 3e-2, 1e-2, 3e-3, 1e-3):
        m = RegresionLogistica(lam).entrenar(X[ie], y[ie])
        pv = m.probabilidad(X[iv])
        candidatos.append((perdida_logaritmica(pv, y[iv]), lam, m))
        decir(f'   lam {lam:<6} validacion perdida {candidatos[-1][0]:.4f}  '
              f'exactitud {medir(pv, y[iv])["exactitud"]:.1%}  ({m.pasos} pasos)')
    _, lam, regresion = min(candidatos, key=lambda c: c[0])
    decir(f'   Elegido lam {lam}')
    m_reg_prueba = medir(regresion.probabilidad(X[ip]), y[ip])
    m_reg_unicos = medir(regresion.probabilidad(Xu), yu)
    contar('prueba', m_reg_prueba)
    contar('casos unicos', m_reg_unicos)

    try:
        from sklearn.linear_model import LogisticRegression
        # Mismo castigo: el de sklearn suma los errores y el nuestro los promedia, C = 1 / (n * lam).
        sk = LogisticRegression(C=1 / (len(ie) * lam), tol=1e-12, max_iter=100000).fit(X[ie], y[ie])
        diferencia = np.abs(sk.predict_proba(X[ip])[:, 1] - regresion.probabilidad(X[ip])).max()
        coinciden = np.mean((sk.predict_proba(Xu)[:, 1] >= UMBRAL) == (regresion.probabilidad(Xu) >= UMBRAL))
        decir(f'   Contra scikit-learn: diferencia maxima de probabilidad {diferencia:.2e}, '
              f'misma respuesta en {coinciden:.0%} de los casos unicos')
    except ImportError:
        decir('   scikit-learn no esta instalado, se salta la comparacion')

    # ---- B
    decir('\n== B. Red neuronal 768 > 32 ReLU > 1 sigmoide (a mano)')
    peor = revisar_gradiente(X[ie[:20]], y[ie[:20]])
    decir(f'   Gradient check del backpropagation: error relativo maximo {peor:.1e} '
          f'({"bien" if peor < 1e-6 else "MAL, el backprop tiene un error"})')
    if peor >= 1e-6:
        sys.exit(1)
    red = RedNeuronal(X.shape[1]).entrenar(X[ie], y[ie], X[iv], y[iv])
    decir(f'   Mejor momento en la vuelta {red.mejor_vuelta} de {red.vueltas_hechas} '
          f'(parada temprana), validacion perdida {min(red.historia):.4f}')
    m_red_prueba = medir(red.probabilidad(X[ip]), y[ip])
    m_red_unicos = medir(red.probabilidad(Xu), yu)
    contar('prueba', m_red_prueba)
    contar('casos unicos', m_red_unicos)
    try:
        from sklearn.neural_network import MLPClassifier
        mlp = MLPClassifier(hidden_layer_sizes=(32,), alpha=1e-3, max_iter=3000, random_state=SEMILLA,
                            early_stopping=True, n_iter_no_change=150).fit(X[np.r_[ie, iv]], y[np.r_[ie, iv]])
        decir(f'   Referencia, MLP de scikit-learn con la misma forma: prueba '
              f'{np.mean(mlp.predict(X[ip]) == y[ip]):.1%}, casos unicos {np.mean(mlp.predict(Xu) == yu):.1%}')
    except ImportError:
        pass

    # ---- casos unicos, uno por uno
    decir('\n== Casos unicos por tipo (aciertos regresion / red)')
    pr, pn = regresion.probabilidad(Xu), red.probabilidad(Xu)
    por_caso = defaultdict(lambda: [0, 0, 0])
    for item, a, b, real in zip(unicos, pr, pn, yu):
        c = por_caso[item['caso']]
        c[0] += 1; c[1] += int((a >= UMBRAL) == real); c[2] += int((b >= UMBRAL) == real)
    for caso, (n, ar, an) in sorted(por_caso.items()):
        decir(f'   {caso:<28} {ar}/{n}  {an}/{n}')
    decir('\n   Fallos (probabilidad de mala segun regresion / red)')
    for item, a, b, real in zip(unicos, pr, pn, yu):
        if (a >= UMBRAL) != real or (b >= UMBRAL) != real:
            decir(f'   {item["id"]} {item["caso"]:<26} era {item["etiqueta"]:<5}  {a:.2f} / {b:.2f}')

    # ---- el uso que importa: texto contra estrellas
    decir(f'\n== Nota que no cuadra con el texto (umbral {UMBRAL_FRAUDE})')
    for item, a, b in zip(unicos, pr, pn):
        if item['caso'] != 'nota_no_cuadra':
            continue
        e = item['estrellas']
        marca = lambda p: (p >= UMBRAL_FRAUDE and e >= 4) or (p <= 1 - UMBRAL_FRAUDE and e <= 2)
        decir(f'   {item["id"]} {e} estrellas, texto {item["etiqueta"]}: regresion {a:.2f} '
              f'{"MARCA" if marca(a) else "no marca"}, red {b:.2f} {"MARCA" if marca(b) else "no marca"}')

    # ---- cual se recomienda
    # Primero manda la prueba dura (casos unicos) y despues el F1 en prueba. Si
    # empatan, gana la regresion: es mas simple, mas facil de explicar y de portar.
    # Medido el 2026-10-02 con cinco semillas: la red dio 90 a 91 % en casos
    # unicos y la regresion 89 a 90 %. Gana la red, pero por una o dos resenas.
    puntaje_reg = (round(m_reg_unicos['exactitud'], 3), round(m_reg_prueba['f1_mala'], 3))
    puntaje_red = (round(m_red_unicos['exactitud'], 3), round(m_red_prueba['f1_mala'], 3))
    recomendado = 'red_neuronal' if puntaje_red > puntaje_reg else 'regresion_logistica'
    decir(f'\n== Recomendado para el backend: {recomendado}')

    # ---- exportar
    MODELO.mkdir(exist_ok=True)
    comun_json = {
        'version': 1, 'generado': datetime.now().isoformat(timespec='seconds'),
        'modelo_vectores': datos['modelo_vectores'], 'dimensiones': datos['dimensiones'],
        'normalizar_l2': True, 'salida': 'probabilidad de que el texto de la resena sea malo',
        'umbral': UMBRAL, 'umbral_fraude': UMBRAL_FRAUDE, 'recomendado': recomendado,
    }
    for nombre, modelo, mp, mu in (('regresion_logistica', regresion, m_reg_prueba, m_reg_unicos),
                                   ('red_neuronal', red, m_red_prueba, m_red_unicos)):
        salida = {**comun_json, **modelo.exportar(), 'metricas': {'prueba': mp, 'casos_unicos': mu}}
        (MODELO / f'{nombre}.json').write_text(json.dumps(salida), encoding='utf-8')

    muestras = [pool[i] for i in ip[:15]] + unicos[:15]
    Xm = np.array([m['vector'] for m in muestras])
    (MODELO / 'verificacion.json').write_text(json.dumps([
        {'id': m['id'], 'vector': m['vector'], 'regresion_logistica': float(a), 'red_neuronal': float(b)}
        for m, a, b in zip(muestras, regresion.probabilidad(Xm), red.probabilidad(Xm))]), encoding='utf-8')
    decir(f'Escritos en {MODELO.name}/: regresion_logistica.json, red_neuronal.json, verificacion.json, reporte.txt')
    (MODELO / 'reporte.txt').write_text('\n'.join(lineas_reporte) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
