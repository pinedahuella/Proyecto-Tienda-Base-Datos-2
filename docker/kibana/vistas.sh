#!/bin/bash
# vistas.sh
# Lo corre el contenedor kibana-vistas del docker-compose.yml, una sola vez
# cada vez que se hace `docker compose up`. Nadie lo corre a mano.
#
# Deja listo Kibana para mirar Elasticsearch
#   1. Espera a que Kibana conteste, tarda cerca de un minuto.
#   2. Crea las dos vistas de datos, una por indice de Mesh
#        Eventos de autenticacion   mesh_eventos_autenticacion   con el campo fecha
#        Productos                  mesh_productos
#      Espera a que el indice exista, porque en un arranque desde cero lo crea
#      el ETL varios minutos despues de que Kibana abre.
#   3. Deja el rango de tiempo por defecto de Discover en 60 dias. Sin esto abre
#      en los ultimos 15 minutos y el indice de eventos se ve vacio.
#
# POR QUE HACE FALTA
# Las vistas de datos se guardan dentro de Elasticsearch, en el volumen
# elastic-data de cada maquina. No viajan con el repositorio, y un
# `arrancar.ps1 -Reiniciar` borra ese volumen. Sin este paso quien hace pull
# encuentra Kibana vacio.
#
# Se puede repetir sin miedo. Una vista que ya existe no se duplica, y el rango
# se vuelve a poner igual. Si Kibana no abre o el indice no aparece en el
# tiempo que se espera, avisa y sale con 0, porque no es un fallo de Mesh.

K="${KIBANA_URL:-http://kibana:5601}"
E="${ELASTIC_URL:-http://elasticsearch:9200}"
H="kbn-xsrf: true"
# Con la seguridad de Elasticsearch encendida, Kibana y Elasticsearch piden
# usuario. Este script crea vistas, asi que entra como elastic.
U="elastic:${ELASTIC_PASSWORD}"

echo "kibana-vistas, esperando a Kibana"
for i in $(seq 1 120); do
  if curl -s -u "$U" "$K/api/status" | grep -q '"overall":{"level":"available"'; then
    listo=1
    break
  fi
  sleep 5
done
if [ -z "$listo" ]; then
  echo "kibana-vistas, Kibana no abrio en 10 minutos, no se crearon las vistas"
  exit 0
fi
echo "kibana-vistas, Kibana listo"

# crear TITULO NOMBRE CAMPO_DE_FECHA_O_VACIO
crear() {
  titulo="$1"
  nombre="$2"
  campo="$3"

  if curl -s -u "$U" "$K/api/data_views" -H "$H" | grep -q "\"title\":\"$titulo\""; then
    echo "kibana-vistas, $nombre ya estaba"
    return
  fi

  # Hasta 15 minutos a que el indice exista. Una vista sin indice queda sin
  # campos y hay que rehacerla.
  for i in $(seq 1 90); do
    if curl -sf -u "$U" -o /dev/null -I "$E/$titulo"; then
      existe=1
      break
    fi
    sleep 10
  done
  if [ -z "$existe" ]; then
    echo "kibana-vistas, $nombre no se creo, el indice $titulo no aparecio en 15 minutos"
    return
  fi
  unset existe

  cuerpo="{\"data_view\":{\"title\":\"$titulo\",\"name\":\"$nombre\""
  if [ -n "$campo" ]; then
    cuerpo="$cuerpo,\"timeFieldName\":\"$campo\""
  fi
  cuerpo="$cuerpo}}"

  if curl -sf -u "$U" -o /dev/null -X POST "$K/api/data_views/data_view" \
       -H "$H" -H "Content-Type: application/json" -d "$cuerpo"; then
    echo "kibana-vistas, $nombre creada"
  else
    echo "kibana-vistas, $nombre no se pudo crear"
  fi
}

crear "mesh_eventos_autenticacion" "Eventos de autenticacion" "fecha"
crear "mesh_productos" "Productos" ""

if curl -sf -u "$U" -o /dev/null -X POST "$K/api/kibana/settings" \
     -H "$H" -H "Content-Type: application/json" \
     -d '{"changes":{"timepicker:timeDefaults":"{\"from\":\"now-60d\",\"to\":\"now\"}"}}'; then
  echo "kibana-vistas, rango por defecto de Discover en 60 dias"
else
  echo "kibana-vistas, no se pudo poner el rango por defecto"
fi

echo "kibana-vistas, listo"
exit 0
