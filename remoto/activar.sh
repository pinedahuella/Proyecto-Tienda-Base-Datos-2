# remoto/activar.sh -- entra al modo remoto en esta consola de Git Bash:
# las pruebas y los ETL usan las bases de la otra PC (la de Jose David, por
# Tailscale) como si estuvieran aqui. Se carga con source:
#
#   source remoto/activar.sh                 la IP de siempre, 100.64.42.11
#   source remoto/activar.sh 100.64.42.11
#
# Hace tres cosas:
#   1. Comprueba que la otra PC conteste (Tailscale) y que los puertos de las
#      bases esten libres aqui (con el Docker local arriba no lo estan).
#   2. Levanta remoto/tunel.cjs, que lleva localhost:5432, 27017, 27018, 6379,
#      7687, 8123 y 9200 a la otra PC.
#   3. Pone remoto/bin al principio del PATH: "docker" pasa a ser el docker
#      falso, que corre psql, mongosh, redis-cli, clickhouse-client y
#      cypher-shell aqui.
# Para salir: source remoto/desactivar.sh (o cerrar la consola).

_remoto_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_remoto_ip="${1:-100.64.42.11}"

_remoto_activar() {
    if [ -n "${MESH_REMOTO:-}" ]; then
        echo "Ya estas en el modo remoto ($MESH_REMOTO). Para salir: source remoto/desactivar.sh"
        return 0
    fi
    if ! node -e "const s=require('net').connect(5432,'$_remoto_ip');s.setTimeout(4000);s.on('connect',()=>process.exit(0));s.on('timeout',()=>process.exit(1));s.on('error',()=>process.exit(1))"; then
        echo "La PC $_remoto_ip no contesta en el 5432. Prende Tailscale (y que la otra PC tenga las bases arriba)." >&2
        return 1
    fi
    local registro="${TMPDIR:-/tmp}/mesh-tunel.log"
    node "$_remoto_dir/tunel.cjs" "$_remoto_ip" > "$registro" 2>&1 &
    local pid=$!
    local i
    for i in $(seq 1 20); do
        grep -q "tunel listo" "$registro" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.3
    done
    if ! grep -q "tunel listo" "$registro" 2>/dev/null; then
        cat "$registro" >&2
        kill "$pid" 2>/dev/null
        echo "No se pudo levantar el tunel. Si dice ocupado: apaga el Docker local (docker stop o cerrar Docker Desktop)." >&2
        return 1
    fi
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$_remoto_dir/.tunel.pid"
    export MESH_REMOTO="$_remoto_ip"
    export MESH_REMOTO_PATH_ANTES="$PATH"
    export PATH="$_remoto_dir/bin:$PATH"
    # Las pruebas que tumban una base a proposito (grafo_compras,
    # ofertas_y_seguimientos) se saltan esa parte: la base es de la otra PC.
    export SIN_CAIDA=1
    # Las contrasenas de la otra PC (las de inspeccion y operador de Redis son
    # otras alla), si estan en remoto/.env.remoto, que no se sube. Pisan al
    # .env de la raiz; desactivar.sh las quita.
    if [ -f "$_remoto_dir/.env.remoto" ]; then
        local linea nombre
        MESH_REMOTO_VARIABLES=""
        while IFS= read -r linea || [ -n "$linea" ]; do
            linea="${linea%$'\r'}"
            if [[ "$linea" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
                nombre="${BASH_REMATCH[1]}"
                export "$nombre=${BASH_REMATCH[2]}"
                MESH_REMOTO_VARIABLES="$MESH_REMOTO_VARIABLES $nombre"
            fi
        done < "$_remoto_dir/.env.remoto"
        export MESH_REMOTO_VARIABLES
        echo "Contrasenas de la otra PC cargadas de remoto/.env.remoto."
    fi
    echo "Modo remoto: bases en $_remoto_ip, tunel en el pid $pid, docker = remoto/bin/docker."
    if [ ! -x "$_remoto_dir/herramientas/bin/mongosh.exe" ]; then
        echo "Falta mongosh para las pruebas de Mongo: bash remoto/instalar.sh (una vez)."
    fi
    echo "El backend tiene que apuntar a la otra PC: .\\usar-bases-remotas.ps1 -Ip $_remoto_ip"
}
_remoto_activar
unset -f _remoto_activar
unset _remoto_dir _remoto_ip
