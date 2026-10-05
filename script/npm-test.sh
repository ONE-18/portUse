#!/usr/bin/env bash
set -Eeuo pipefail

# Prueba de lectura para Nginx Proxy Manager. No modifica la configuración de NPM.
NPM_URL="${NPM_URL:-http://localhost:81}"
NPM_USER="${NPM_USER:-}"
NPM_PASSWORD="${NPM_PASSWORD:-}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
INSECURE="${INSECURE:-0}"
OUTPUT_FORMAT="table"

usage() {
    cat <<'EOF'
Uso:
  NPM_URL=https://npm.example.com:81 NPM_USER=... NPM_PASSWORD=... \
    ./script/npm-test.sh [--json] [--insecure]

Variables:
  NPM_URL             URL base de NPM (por defecto: http://localhost:81)
  NPM_USER            Usuario de NPM
  NPM_PASSWORD        Contraseña de NPM
  CONNECT_TIMEOUT     Tiempo de conexión en segundos (por defecto: 10)
  REQUEST_TIMEOUT     Tiempo máximo por petición en segundos (por defecto: 30)
  INSECURE=1          Desactiva la verificación TLS (solo pruebas controladas)

Opciones:
  --json              Imprime un informe JSON normalizado
  --insecure          Equivalente a INSECURE=1
  -h, --help          Muestra esta ayuda
EOF
}

for arg in "$@"; do
    case "$arg" in
        --json) OUTPUT_FORMAT="json" ;;
        --insecure) INSECURE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Opción desconocida: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

command -v curl >/dev/null || { echo "No se encontró curl." >&2; exit 1; }
command -v jq >/dev/null || { echo "No se encontró jq." >&2; exit 1; }

NPM_URL="${NPM_URL%/}"
if [[ ! "$NPM_URL" =~ ^https?://[^/]+$ ]]; then
    echo "NPM_URL debe ser una URL http(s) sin ruta adicional: $NPM_URL" >&2
    exit 2
fi

if [[ -z "$NPM_USER" || -z "$NPM_PASSWORD" ]]; then
    echo "Define NPM_USER y NPM_PASSWORD; no se solicitan interactivamente." >&2
    exit 2
fi

curl_options=(
    --silent --show-error --fail-with-body
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$REQUEST_TIMEOUT"
)
if [[ "$INSECURE" == "1" ]]; then
    curl_options+=(--insecure)
fi

request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    if [[ "$method" == "POST" ]]; then
        curl "${curl_options[@]}" -X POST \
            -H "Content-Type: application/json" \
            --data "$body" \
            "$NPM_URL$path"
    else
        curl "${curl_options[@]}" \
            -H "Authorization: Bearer $TOKEN" \
            "$NPM_URL$path"
    fi
}

TOKEN_RESPONSE="$(
    request POST /api/tokens \
        "$(jq -cn --arg identity "$NPM_USER" --arg secret "$NPM_PASSWORD" \
            '{identity: $identity, secret: $secret}')"
)" || {
    echo "Falló la autenticación contra $NPM_URL/api/tokens." >&2
    exit 1
}

TOKEN="$(jq -er '.token // empty' <<<"$TOKEN_RESPONSE")" || {
    echo "La respuesta de autenticación no contiene un token JWT." >&2
    exit 1
}

declare -A RESPONSES=()
declare -A ERRORS=()
for endpoint in \
    proxy_hosts:/api/nginx/proxy-hosts \
    redirection_hosts:/api/nginx/redirection-hosts \
    streams:/api/nginx/streams \
    dead_hosts:/api/nginx/dead-hosts \
    schema:/api/schema
do
    name="${endpoint%%:*}"
    path="${endpoint#*:}"
    error_file="$(mktemp)"
    if response="$(request GET "$path" 2>"$error_file")"; then
        RESPONSES["$name"]="$response"
        rm -f "$error_file"
    else
        ERRORS["$name"]="$(cat "$error_file")"
        rm -f "$error_file"
    fi
done

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -n \
        --arg url "$NPM_URL" \
        --argjson proxy_hosts "${RESPONSES[proxy_hosts]:-null}" \
        --argjson redirection_hosts "${RESPONSES[redirection_hosts]:-null}" \
        --argjson streams "${RESPONSES[streams]:-null}" \
        --argjson dead_hosts "${RESPONSES[dead_hosts]:-null}" \
        --argjson schema "${RESPONSES[schema]:-null}" \
        --argjson errors "$(printf '%s\n' "${ERRORS[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
        '{
          npm_url: $url,
          proxy_hosts: $proxy_hosts,
          redirection_hosts: $redirection_hosts,
          streams: $streams,
          dead_hosts: $dead_hosts,
          schema: $schema,
          errors: $errors
        }'
else
    echo "NPM: $NPM_URL"
    echo "Autenticación: OK"
    echo
    echo "Proxy hosts:"
    if [[ -n "${RESPONSES[proxy_hosts]:-}" ]]; then
        jq -r '
          (if type == "array" then . else (.items // .data // []) end)[] |
          .domain_names[]? as $domain |
          "\($domain) -> \(.forward_scheme // "http")://\(.forward_host // "?"):\(.forward_port // "?") [id=\(.id), enabled=\(.enabled)]"
        ' <<<"${RESPONSES[proxy_hosts]}"
    else
        echo "  ERROR: ${ERRORS[proxy_hosts]:-sin respuesta}"
    fi
    for name in redirection_hosts streams dead_hosts schema; do
        if [[ -n "${RESPONSES[$name]:-}" ]]; then
            echo "$name: OK"
        else
            echo "$name: ERROR: ${ERRORS[$name]:-sin respuesta}"
        fi
    done
fi

if ((${#ERRORS[@]} > 0)); then
    exit 1
fi
