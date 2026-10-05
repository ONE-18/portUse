#!/bin/bash
set -Eeuo pipefail

trap 'status=$?; echo "Error en la línea $LINENO (código $status)." >&2; exit "$status"' ERR

# Configuración autocontenida: modifica estos valores antes de instalar el script.
API_URL="https://api.example.com"
OUTPUT_DIR="/root/portUse"
CONNECT_TIMEOUT=10
UPLOAD_TIMEOUT=60
API_URL="${API_URL%/}"

CTIDS=(
    100
    101
    102
)

case "$API_URL" in
    https://*) ;;
    *)
        echo "API_URL debe usar HTTPS: $API_URL" >&2
        exit 1
        ;;
esac

command -v curl >/dev/null || { echo "No se encontró curl." >&2; exit 1; }
command -v jq >/dev/null || { echo "No se encontró jq." >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/docker-ports-$(date '+%Y-%m-%d_%H-%M-%S').json"
echo "Iniciando recolección para CTIDs: ${CTIDS[*]}"

echo '{' > "$OUTPUT"
echo '  "generated": "'$(date --iso-8601=seconds)'",' >> "$OUTPUT"
echo '  "containers": [' >> "$OUTPUT"

FIRST_CT=true

for CTID in "${CTIDS[@]}"; do

    # Comprobar que existe
    if ! pct status "$CTID" &>/dev/null; then
        echo "CT $CTID no existe, se omite."
        continue
    fi

    if HOSTNAME="$(pct exec "$CTID" -- hostname 2>/dev/null)"; then
        :
    else
        HOSTNAME=""
        echo "No se pudo obtener el hostname del CT $CTID; puede estar detenido." >&2
    fi

    # Escapar posibles caracteres especiales para JSON
    HOSTNAME=$(printf '%s' "$HOSTNAME" | sed 's/\\/\\\\/g; s/"/\\"/g')

    # Comprobar Docker
    if ! pct exec "$CTID" -- docker info &>/dev/null; then
        DOCKER=false
        CONTAINERS_JSON="[]"
    else
        DOCKER=true

        CONTAINERS_JSON=$(
            pct exec "$CTID" -- docker ps \
                --format '{{.Names}}|{{.Ports}}' |
            jq -Rn '
                [inputs
                | split("|")
                | {
                    name: .[0],
                    ports: (
                        if .[1] == "" then []
                        else .[1] | split(", ")
                        end
                    )
                }]
            '
        )
    fi

    # Separador entre LXC
    if [ "$FIRST_CT" = false ]; then
        echo ',' >> "$OUTPUT"
    fi
    FIRST_CT=false

    jq -n \
        --argjson ctid "$CTID" \
        --arg hostname "$HOSTNAME" \
        --argjson docker "$DOCKER" \
        --argjson containers "$CONTAINERS_JSON" \
        '{
            ctid: $ctid,
            hostname: $hostname,
            docker: $docker,
            containers: $containers
        }' | sed 's/^/    /' >> "$OUTPUT"

done

if [ "$FIRST_CT" = true ]; then
    echo "No se encontró ningún CTID válido. Revisa CTIDS antes de enviar el informe." >&2
    rm -f "$OUTPUT"
    exit 1
fi

echo >> "$OUTPUT"
echo '  ]' >> "$OUTPUT"
echo '}' >> "$OUTPUT"

jq empty "$OUTPUT" || {
    echo "El informe generado no contiene un JSON válido: $OUTPUT" >&2
    exit 1
}

echo "Informe generado en: $OUTPUT"
UPLOAD_URL="$API_URL/api/snapshots"
echo "Enviando snapshot a: $UPLOAD_URL"

RESPONSE="$(
    curl --fail-with-body --silent --show-error \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$UPLOAD_TIMEOUT" \
        -F "file=@$OUTPUT;type=application/json" \
        "$UPLOAD_URL"
)"

if ! jq -e '.id and .filename' >/dev/null <<<"$RESPONSE"; then
    echo "La API devolvió una respuesta inesperada:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi

echo "Snapshot enviado a $API_URL (id: $(jq -r '.id' <<<"$RESPONSE"))."