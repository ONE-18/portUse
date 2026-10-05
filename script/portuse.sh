#!/bin/bash
set -Eeuo pipefail

# Configuración autocontenida: modifica estos valores antes de instalar el script.
API_URL="https://api.example.com"
OUTPUT_DIR="/root/portUse"
CONNECT_TIMEOUT=10
UPLOAD_TIMEOUT=60

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

    HOSTNAME=$(pct exec "$CTID" -- hostname 2>/dev/null)

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

echo >> "$OUTPUT"
echo '  ]' >> "$OUTPUT"
echo '}' >> "$OUTPUT"

echo "Informe generado en: $OUTPUT"

RESPONSE="$(
    curl --fail --silent --show-error \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$UPLOAD_TIMEOUT" \
        -F "file=@$OUTPUT;type=application/json" \
        "$API_URL/api/snapshots"
)"

if ! jq -e '.id and .filename' >/dev/null <<<"$RESPONSE"; then
    echo "La API devolvió una respuesta inesperada:" >&2
    echo "$RESPONSE" >&2
    exit 1
fi

echo "Snapshot enviado a $API_URL (id: $(jq -r '.id' <<<"$RESPONSE"))."