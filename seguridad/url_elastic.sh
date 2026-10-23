# seguridad/url_elastic.sh
# Lo cargan con `.` los scripts de bash que le hablan a Elasticsearch con curl
# (el ETL del buscador y tres pruebas), justo despues de fijar ES.
#
# Desde el 2026-10-23 Elasticsearch tiene la seguridad encendida. Esto mete el
# usuario elastic dentro de la URL (http://elastic:clave@localhost:9200), y asi
# cada curl del script sigue igual sin tocar una sola llamada. ES_VER es la misma
# URL sin la contrasena, para los mensajes en pantalla.
#
# La contrasena sale de ELASTIC_PASSWORD si ya viene en el ambiente (el modo
# remoto la exporta) o del .env de la raiz. Si no hay ninguna, ES queda igual,
# que es lo que pide un Elasticsearch sin seguridad.

_raiz_mesh="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${ELASTIC_PASSWORD:-}" ] && [ -f "$_raiz_mesh/.env" ]; then
    ELASTIC_PASSWORD="$(grep -E '^ELASTIC_PASSWORD=' "$_raiz_mesh/.env" | head -1 | cut -d= -f2- | tr -d '\r')"
fi
ES_VER="$ES"
case "$ES" in
    *@*) ES_VER="$(printf '%s' "$ES" | sed -E 's#//[^@/]*@#//#')" ;;
    *) [ -n "${ELASTIC_PASSWORD:-}" ] && ES="$(printf '%s' "$ES" | sed -E "s#^(https?://)#\\1elastic:${ELASTIC_PASSWORD}@#")" ;;
esac
unset _raiz_mesh
