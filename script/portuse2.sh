#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; echo "Error en la línea $LINENO (código $status)." >&2; exit "$status"' ERR

# PortUse + Nginx Proxy Manager. Este script solo lee Proxmox y NPM.
API_URL="${API_URL:-https://api.example.com}"
OUTPUT_DIR="${OUTPUT_DIR:-/root/portUse}"
NPM_URL="${NPM_URL:-http://localhost:81}"
NPM_USER="${NPM_USER:-}"
NPM_PASSWORD="${NPM_PASSWORD:-}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
UPLOAD_TIMEOUT="${UPLOAD_TIMEOUT:-60}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30}"
INSECURE="${INSECURE:-0}"

CTIDS=(100 101)

case "$API_URL" in
    https://*) ;;
    *) echo "API_URL debe usar HTTPS: $API_URL" >&2; exit 1 ;;
esac
[[ "$NPM_URL" =~ ^https?://[^/]+$ ]] || {
    echo "NPM_URL debe ser una URL http(s) sin ruta adicional: $NPM_URL" >&2
    exit 1
}
[[ -n "$NPM_USER" && -n "$NPM_PASSWORD" ]] || {
    echo "Define NPM_USER y NPM_PASSWORD." >&2
    exit 1
}

for command_name in curl jq pct; do
    command -v "$command_name" >/dev/null || {
        echo "No se encontró $command_name." >&2
        exit 1
    }
done

mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/portuse-$(date '+%Y-%m-%d_%H-%M-%S').json"

echo "Recolectando LXC: ${CTIDS[*]}"
containers='[]'
for CTID in "${CTIDS[@]}"; do
    if ! pct status "$CTID" &>/dev/null; then
        echo "CT $CTID no existe, se omite."
        continue
    fi

    hostname="$(pct exec "$CTID" -- hostname 2>/dev/null || true)"
    ips="$(
        pct exec "$CTID" -- hostname -I 2>/dev/null |
        jq -Rc 'split(" ") | map(select(test("^192\\.168\\.1\\.[0-9]+$")))' ||
        echo '[]'
    )"

    if pct exec "$CTID" -- docker info &>/dev/null; then
        docker=true
        lxc_containers="$(
            pct exec "$CTID" -- docker ps --format '{{.Names}}|{{.Ports}}' |
            jq -Rn '[inputs | split("|") | {
                name: .[0],
                ports: (if .[1] == "" then [] else .[1] | split(", ") end)
            }]'
        )"
    else
        docker=false
        lxc_containers='[]'
    fi

    containers="$(
        jq -cn \
            --argjson existing "$containers" \
            --argjson ctid "$CTID" \
            --arg hostname "$hostname" \
            --argjson ips "$ips" \
            --argjson docker "$docker" \
            --argjson lxc_containers "$lxc_containers" \
            '$existing + [{
                ctid: $ctid,
                hostname: $hostname,
                ips: $ips,
                docker: $docker,
                containers: $lxc_containers
            }]'
    )"
done

if [[ "$containers" == "[]" ]]; then
    echo "No se encontró ningún CTID válido." >&2
    exit 1
fi

curl_options=(
    --silent --show-error --fail-with-body
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$REQUEST_TIMEOUT"
)
[[ "$INSECURE" == "1" ]] && curl_options+=(--insecure)

npm_request() {
    local method="$1" path="$2" body="${3:-}"
    if [[ "$method" == "POST" ]]; then
        curl "${curl_options[@]}" -X POST \
            -H "Content-Type: application/json" --data "$body" "${NPM_URL%/}$path"
    else
        curl "${curl_options[@]}" \
            -H "Authorization: Bearer $NPM_TOKEN" "${NPM_URL%/}$path"
    fi
}

token_response="$(
    npm_request POST /api/tokens \
        "$(jq -cn --arg identity "$NPM_USER" --arg secret "$NPM_PASSWORD" \
            '{identity: $identity, secret: $secret}')"
)"
NPM_TOKEN="$(jq -er '.token // empty' <<<"$token_response")" || {
    echo "NPM no devolvió un token JWT." >&2
    exit 1
}

proxy_hosts="$(npm_request GET /api/nginx/proxy-hosts)"
redirections="$(
    npm_request GET /api/nginx/redirection-hosts 2>/dev/null || {
        echo "Aviso: no se pudieron obtener las redirecciones de NPM." >&2
        echo '[]'
    }
)"
streams="$(
    npm_request GET /api/nginx/streams 2>/dev/null || {
        echo "Aviso: no se pudieron obtener los streams de NPM." >&2
        echo '[]'
    }
)"

enriched_containers="$(
    jq -cn \
        --argjson hosts "$containers" \
        --argjson proxy_hosts "$proxy_hosts" \
        '
        ($proxy_hosts
          | if type == "array" then . else (.items // .data // []) end) as $routes
        | $hosts | map(
            . as $host
            | .npm_routes = [
                $routes[] as $route
                | select(($host.ips // []) | index($route.forward_host))
                | ([ $host.containers[]?
                    | select(any(.ports[]?;
                        test("(^|[^0-9])" + ($route.forward_port | tostring) + "->")))
                    | {name, ports}
                  ] | first) as $container
                | $route + {
                    target_port: $route.forward_port,
                    lxc: {
                        ctid: $host.ctid,
                        hostname: $host.hostname,
                        ip: $route.forward_host
                    },
                    container: ($container.name // null)
                  }
            ]
        )
        '
)"

jq -n \
    --arg generated "$(date --iso-8601=seconds)" \
    --arg npm_url "${NPM_URL%/}" \
    --argjson containers "$enriched_containers" \
    --argjson proxy_hosts "$proxy_hosts" \
    --argjson redirections "$redirections" \
    --argjson streams "$streams" \
    '{
      generated: $generated,
      containers: $containers,
      npm: {
        url: $npm_url,
        proxy_hosts: (if ($proxy_hosts | type) == "array" then $proxy_hosts else ($proxy_hosts.items // $proxy_hosts.data // []) end),
        redirection_hosts: (if ($redirections | type) == "array" then $redirections else ($redirections.items // $redirections.data // []) end),
        streams: (if ($streams | type) == "array" then $streams else ($streams.items // $streams.data // []) end)
      }
    }' > "$OUTPUT"

jq empty "$OUTPUT"
echo "Informe generado en: $OUTPUT"

UPLOAD_URL="${API_URL%/}/api/snapshots"
response="$(
    curl --fail-with-body --silent --show-error \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$UPLOAD_TIMEOUT" \
        -F "file=@$OUTPUT;type=application/json" "$UPLOAD_URL"
)"
jq -e '.id and .filename' >/dev/null <<<"$response" || {
    echo "La API devolvió una respuesta inesperada: $response" >&2
    exit 1
}
echo "Snapshot enviado a ${API_URL%/} (id: $(jq -r '.id' <<<"$response"))."
