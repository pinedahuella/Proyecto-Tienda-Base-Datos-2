# remoto/comun.sh
# Lo que comparten el docker falso y los clientes de remoto/bin: donde esta
# el repo, las variables del .env de la raiz, y como se traduce una ruta de
# "dentro del contenedor" a una de esta maquina. Se carga con "source".

REMOTO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$REMOTO/.." && pwd)"

# El .env de la raiz, sin pisar lo que ya venga en el ambiente (asi se pueden
# pasar a mano las contrasenas que en la otra PC son otras, ver README).
while IFS= read -r linea || [ -n "$linea" ]; do
    linea="${linea%$'\r'}"
    if [[ "$linea" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        nombre="${BASH_REMATCH[1]}"
        valor="${BASH_REMATCH[2]}"
        [ -z "${!nombre+x}" ] && export "$nombre=$valor"
    fi
done < "$REPO/.env"
unset linea nombre valor

# El /tmp de los contenedores es el /tmp de Git Bash, tal cual: docker cp
# escribe ahi, un "sh -c 'cat > /tmp/x'" tambien, y los clientes leen de ahi.
# Una ruta de dentro del contenedor, en esta maquina (con / de Git Bash): las
# carpetas del repo que el docker-compose monta (migrations, mongo, neo4j).
# Lo demas, /tmp incluido, se queda igual.
ruta_local() {
    case "$1" in
        /migrations/*) printf '%s' "$REPO/migrations/${1#/migrations/}" ;;
        /mongo/*)      printf '%s' "$REPO/mongo/${1#/mongo/}" ;;
        /neo4j/*)      printf '%s' "$REPO/neo4j/${1#/neo4j/}" ;;
        *)             printf '%s' "$1" ;;
    esac
}

# Lo mismo, para pasarsela a un programa de Windows (C:\...). /dev/stdin pasa
# a "-", que es como lo entienden psql y compania.
ruta_windows() {
    case "$1" in
        /dev/stdin) printf '%s' '-' ;;
        /tmp/*|/migrations/*|/mongo/*|/neo4j/*) cygpath -w "$(ruta_local "$1")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Traduce cada argumento que sea una ruta de contenedor, entera o despues de
# un "=" (--archive=/tmp/x). Deja el resultado en el arreglo ARGS.
traducir_args() {
    ARGS=()
    local a
    for a in "$@"; do
        case "$a" in
            /dev/stdin|/tmp/*|/migrations/*|/mongo/*|/neo4j/*) ARGS+=("$(ruta_windows "$a")") ;;
            --*=/tmp/*|--*=/migrations/*|--*=/mongo/*|--*=/neo4j/*) ARGS+=("${a%%=*}=$(ruta_windows "${a#*=}")") ;;
            *) ARGS+=("$a") ;;
        esac
    done
}

# Los clientes de Node usan los drivers del backend. La ruta va en forma de
# Windows (C:/...): los de remoto/bin llaman a node con MSYS_NO_PATHCONV=1, y
# un /c/Proyectos/... sin traducir node lo lee como C:\c\Proyectos.
NODE_REMOTO="$(cygpath -m "$REMOTO/clientes")"
