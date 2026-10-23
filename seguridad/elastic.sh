#!/bin/bash
# seguridad/elastic.sh
# Los usuarios de cada servicio en Elasticsearch. Lo corre el contenedor
# elastic-usuarios del docker-compose.yml en cada `docker compose up`, y
# arrancar.ps1 espera a que termine y muestra lo que dijo. Nadie lo corre a mano.
#
#   kibana_system   el usuario con que Kibana habla con Elasticsearch. Viene de
#                   fabrica sin contrasena; aqui se le pone la del .env.
#   mesh_backend    el backend, con mesh_backend_rol. Lee y escribe documentos
#                   solo en los indices mesh_*, y mira la salud del cluster. No
#                   crea ni borra indices, no cambia mapeos ni administra
#                   usuarios.
#   mesh_lectura    para entrar a Kibana y mirar, con mesh_lectura_rol. Solo lee
#                   los indices mesh_*, y en Kibana solo mira.
#
# `elastic`, el superusuario, queda para arrancar.ps1, el ETL y las pruebas, que
# son los que crean y rehacen los indices.
#
# Las contrasenas llegan por variables de entorno desde el .env. Se puede repetir
# sin miedo: los PUT de la API de seguridad crean o reemplazan.

E="${ELASTIC_URL:-http://elasticsearch:9200}"
A="elastic:${ELASTIC_PASSWORD}"

for v in ELASTIC_PASSWORD KIBANA_PASSWORD ELASTIC_BACKEND_PASSWORD ELASTIC_LECTURA_PASSWORD; do
  if [ -z "${!v}" ]; then
    echo "elastic-usuarios, falta $v"
    exit 1
  fi
done

echo "elastic-usuarios, esperando a Elasticsearch"
for i in $(seq 1 90); do
  if curl -sf -u "$A" "$E/_cluster/health?wait_for_status=yellow&timeout=5s" > /dev/null; then
    listo=1
    break
  fi
  sleep 2
done
if [ -z "$listo" ]; then
  echo "elastic-usuarios, Elasticsearch no contesto con la contrasena de elastic en 3 minutos"
  exit 1
fi

fallos=0
# poner QUE METODO RUTA CUERPO
poner() {
  local que="$1" metodo="$2" ruta="$3" cuerpo="$4" codigo
  codigo=$(curl -s -o /tmp/respuesta -w '%{http_code}' -u "$A" -X "$metodo" "$E$ruta" \
    -H 'Content-Type: application/json' -d "$cuerpo")
  if [ "$codigo" = "200" ]; then
    echo "elastic-usuarios, $que"
  else
    echo "elastic-usuarios, FALLO $que (HTTP $codigo) $(head -c 300 /tmp/respuesta)"
    fallos=$((fallos + 1))
  fi
}

poner "kibana_system con su contrasena" POST /_security/user/kibana_system/_password \
  "{\"password\":\"$KIBANA_PASSWORD\"}"

poner "rol mesh_backend_rol, leer y escribir en mesh_*" PUT /_security/role/mesh_backend_rol '{
  "cluster": ["monitor"],
  "indices": [
    { "names": ["mesh_*"], "privileges": ["read", "write", "view_index_metadata"] }
  ]
}'

poner "rol mesh_lectura_rol, solo leer mesh_* y mirar en Kibana" PUT /_security/role/mesh_lectura_rol '{
  "cluster": ["monitor"],
  "indices": [
    { "names": ["mesh_*"], "privileges": ["read", "view_index_metadata"] }
  ],
  "applications": [
    { "application": "kibana-.kibana", "privileges": ["read"], "resources": ["*"] }
  ]
}'

poner "usuario mesh_backend" PUT /_security/user/mesh_backend \
  "{\"password\":\"$ELASTIC_BACKEND_PASSWORD\",\"roles\":[\"mesh_backend_rol\"],\"full_name\":\"Backend de Mesh\"}"

poner "usuario mesh_lectura" PUT /_security/user/mesh_lectura \
  "{\"password\":\"$ELASTIC_LECTURA_PASSWORD\",\"roles\":[\"mesh_lectura_rol\"],\"full_name\":\"Solo lectura\"}"

if [ "$fallos" -gt 0 ]; then
  exit 1
fi
echo "elastic-usuarios, listo"
