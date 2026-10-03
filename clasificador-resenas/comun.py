"""
Lo que comparten los dos scripts: rutas, leer y validar el set de resenas y
pedirle los vectores a Ollama.

El vector se pide igual que en el backend (backend/src/database/ollama.ts):
POST /api/embed al mismo Ollama y con el mismo modelo, paraphrase-multilingual,
768 numeros. Despues se normaliza a largo 1. El backend tiene que hacer
exactamente lo mismo antes de usar el modelo, o las probabilidades no cuadran.
"""

import hashlib
import json
import math
import os
import urllib.request
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
DATOS = RAIZ / 'datos'
VECTORES = RAIZ / 'vectores' / 'vectores.json'
MODELO = RAIZ / 'modelo'

LARGO_MINIMO = 150
ETIQUETAS = {'buena': 0, 'mala': 1}   # el modelo da la probabilidad de "mala"


def leer_env_backend():
    """OLLAMA_URL y el modelo salen del .env del backend, como en el resto del proyecto."""
    valores = {}
    archivo = RAIZ.parent / 'backend' / '.env'
    if archivo.exists():
        for linea in archivo.read_text(encoding='utf-8').splitlines():
            if '=' in linea and not linea.lstrip().startswith('#'):
                llave, valor = linea.split('=', 1)
                valores[llave.strip()] = valor.strip().strip('"').strip("'")
    return valores


_env = leer_env_backend()
OLLAMA_URL = os.environ.get('OLLAMA_URL') or _env.get('OLLAMA_URL') or 'http://localhost:11434'
OLLAMA_MODELO = (os.environ.get('OLLAMA_MODELO_VECTORES')
                 or _env.get('OLLAMA_MODELO_VECTORES') or 'paraphrase-multilingual')


def md5(texto):
    return hashlib.md5(texto.encode('utf-8')).hexdigest()


def conjunto_de(archivo):
    """casos_unicos.json nunca se usa para entrenar: es la prueba dura."""
    return 'casos_unicos' if archivo.stem == 'casos_unicos' else 'entrenamiento'


def cargar_resenas():
    """Lee todos los .json de datos/ y corta con un mensaje claro si algo no cuadra."""
    resenas, problemas = [], []
    ids, textos = set(), set()
    for archivo in sorted(DATOS.glob('*.json')):
        for r in json.loads(archivo.read_text(encoding='utf-8')):
            donde = f'{archivo.name} {r.get("id")}'
            for campo in ('id', 'categoria', 'estrellas', 'etiqueta', 'texto'):
                if campo not in r:
                    problemas.append(f'{donde}: falta el campo {campo}')
            if r.get('etiqueta') not in ETIQUETAS:
                problemas.append(f'{donde}: etiqueta "{r.get("etiqueta")}" no es buena ni mala')
            texto = r.get('texto', '')
            if len(texto) <= LARGO_MINIMO:
                problemas.append(f'{donde}: tiene {len(texto)} caracteres, pide mas de {LARGO_MINIMO}')
            if r.get('id') in ids:
                problemas.append(f'{donde}: id repetido')
            if texto in textos:
                problemas.append(f'{donde}: texto repetido')
            ids.add(r.get('id'))
            textos.add(texto)
            # En el set de entrenamiento las estrellas y el texto dicen lo mismo.
            # Solo los casos "nota_no_cuadra" llevan estrellas contrarias, a proposito.
            estrellas = r.get('estrellas', 0)
            if r.get('caso') != 'nota_no_cuadra':
                if r.get('etiqueta') == 'buena' and estrellas < 4:
                    problemas.append(f'{donde}: buena con {estrellas} estrellas')
                if r.get('etiqueta') == 'mala' and estrellas > 2:
                    problemas.append(f'{donde}: mala con {estrellas} estrellas')
            r['conjunto'] = conjunto_de(archivo)
            resenas.append(r)
    if problemas:
        raise SystemExit('El set de resenas tiene problemas:\n  ' + '\n  '.join(problemas))
    return resenas


def normalizar(vector):
    largo = math.sqrt(sum(x * x for x in vector))
    return [x / largo for x in vector] if largo else vector


def pedir_vectores(textos):
    """Una sola llamada a Ollama para varios textos. Devuelve los vectores ya normalizados."""
    cuerpo = json.dumps({'model': OLLAMA_MODELO, 'input': textos}).encode('utf-8')
    peticion = urllib.request.Request(f'{OLLAMA_URL}/api/embed', data=cuerpo,
                                      headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(peticion, timeout=300) as respuesta:
            datos = json.loads(respuesta.read())
    except OSError as error:
        raise SystemExit(f'Ollama no responde en {OLLAMA_URL} ({error}). '
                         'Encendelo o corre etl/cargar_vectores.ps1, que lo enciende solo.')
    vectores = datos.get('embeddings') or []
    if len(vectores) != len(textos):
        raise SystemExit(f'Ollama devolvio {len(vectores)} vectores para {len(textos)} textos')
    return [normalizar(v) for v in vectores]
