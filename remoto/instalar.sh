#!/usr/bin/env bash
# remoto/instalar.sh -- baja los clientes de MongoDB que el modo remoto no
# puede imitar (mongosh, mongodump y mongorestore, los oficiales, para
# Windows) a remoto/herramientas/, que no se sube al repo. Una sola vez:
#
#   bash remoto/instalar.sh
#
# psql no hace falta bajarlo: se usa el de PostgreSQL para Windows si esta
# instalado (C:\Program Files\PostgreSQL\<version>\bin). redis-cli,
# clickhouse-client y cypher-shell son los de remoto/clientes, en Node.
set -euo pipefail
cd "$(dirname "$0")"
DESTINO="herramientas"
mkdir -p "$DESTINO"

MONGOSH_VERSION="2.3.8"
TOOLS_VERSION="100.10.0"

# Python para descomprimir: Git Bash no siempre trae unzip.
PYTHON=""
for candidato in python python3 py; do
    if "$candidato" -c 'import sys' >/dev/null 2>&1; then PYTHON="$candidato"; break; fi
done
[ -n "$PYTHON" ] || { echo "Hace falta Python 3 para descomprimir" >&2; exit 1; }

bajar() {
    local url="$1" zip="$DESTINO/$2"
    if [ -f "$zip" ]; then echo "  ya estaba $2"; return; fi
    echo "  bajando $url"
    curl -fL --retry 3 -o "$zip.parcial" "$url"
    mv "$zip.parcial" "$zip"
}

bajar "https://downloads.mongodb.com/compass/mongosh-${MONGOSH_VERSION}-win32-x64.zip" "mongosh.zip"
bajar "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-windows-x86_64-${TOOLS_VERSION}.zip" "mongo-tools.zip"

for zip in mongosh.zip mongo-tools.zip; do
    "$PYTHON" -m zipfile -e "$DESTINO/$zip" "$DESTINO/"
done

# Los .exe a remoto/herramientas/bin, para que los envoltorios los encuentren
# sin saber la version.
mkdir -p "$DESTINO/bin"
find "$DESTINO" -path "$DESTINO/bin" -prune -o -type f \( -name 'mongosh.exe' -o -name 'mongodump.exe' -o -name 'mongorestore.exe' -o -name '*.dll' \) -print |
    while read -r f; do cp "$f" "$DESTINO/bin/"; done
# Lo demas (los zip y lo descomprimido, unos 500 MB) no hace falta.
find "$DESTINO" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} +
echo "Listo: $(cd "$DESTINO/bin" && ls *.exe | tr '\n' ' ')($(du -sh "$DESTINO" | cut -f1))"
