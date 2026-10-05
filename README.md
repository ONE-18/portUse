# PortUse

API y panel web para cargar, visualizar y comparar snapshots JSON de infraestructura como `docker-ports-*.json`.

## Ejecutar

### Con Docker (recomendado)

```bash
docker compose up --build -d
```

Abre <http://localhost:8000>. Los snapshots se conservan en el volumen Docker
`portuse-data`, incluso si el contenedor se recrea. Para usar otro puerto:

```bash
PORTUSE_PORT=8080 docker compose up --build -d
```

Para detenerlo:

```bash
docker compose down
```

### Con Python

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Abre <http://localhost:8000>. La documentación interactiva de la API está en <http://localhost:8000/docs>.

## API

- `POST /api/snapshots` — recibe un multipart con el campo `file`.
- `GET /api/snapshots` — lista snapshots, ordenados del más reciente al más antiguo.
- `GET /api/snapshots/{id}` — devuelve metadatos y contenido completo.
- `GET /api/snapshots/{id}/random-port?host_index={index}` — obtiene un puerto libre aleatorio (1024-65535) para un host.
- `GET /api/compare?from_id={id}&to_id={id}` — detecta contenedores añadidos, eliminados y cambios de puertos.

Los datos se guardan localmente en `data/` (SQLite para metadatos y un JSON por snapshot).

## Recolector Proxmox

El script [portuse.sh](./script/portuse.sh) conserva el informe local y lo envía automáticamente
a la API mediante `POST /api/snapshots`.

```bash
# Edita API_URL, OUTPUT_DIR y CTIDS directamente en portuse.sh
chmod 700 portuse.sh
./portuse.sh
```

El script es autocontenido y no necesita ningún archivo `.conf`. `API_URL` debe ser
una dirección HTTPS; el script rechaza destinos HTTP para no enviar snapshots sin
cifrar. Al finalizar muestra la URL exacta utilizada y el identificador asignado por
cifrar. Si ninguno de los CTIDs configurados existe, termina con error y no sube un
snapshot vacío.

## Prueba de Nginx Proxy Manager

El script [npm-test.sh](./script/npm-test.sh) consulta la API de Nginx Proxy Manager sin
modificar su configuración. Autentica con JWT y obtiene proxy hosts, redirecciones,
streams, dead hosts y el esquema de la API. Los proxy hosts se muestran como
`dominio -> protocolo://forward_host:forward_port`.

Requiere `bash`, `curl` y `jq`.

```bash
chmod 700 script/npm-test.sh
NPM_URL="https://npm.example.com:81" \
NPM_USER="usuario-lectura" \
NPM_PASSWORD="contraseña" \
  ./script/npm-test.sh
```

Para conservar las respuestas completas en JSON:

```bash
NPM_URL="https://npm.example.com:81" NPM_USER="..." NPM_PASSWORD="..." \
  ./script/npm-test.sh --json > npm-report.json
```

La verificación TLS está activa por defecto. Para una prueba puntual con un certificado
interno no confiable se puede usar `--insecure`; no debe emplearse en producción.

## Recolector combinado

El script [portuse2.sh](./script/portuse2.sh) combina el recolector de puertos de
Proxmox con Nginx Proxy Manager. Mantiene `containers` compatible con los snapshots
anteriores y añade:

- `ips` en cada LXC, para identificar el destino;
- `npm.proxy_hosts`, con dominios, protocolo, `forward_host` y `forward_port`;
- `npm.redirection_hosts` y `npm.streams`.

Configura las credenciales de NPM mediante variables de entorno:

```bash
chmod 700 script/portuse2.sh
API_URL="https://portuse.example.com" \
NPM_URL="https://npm.example.com:81" \
NPM_USER="usuario-lectura" \
NPM_PASSWORD="contraseña" \
  ./script/portuse2.sh
```

La interfaz relaciona automáticamente cada proxy host con el LXC cuya lista `ips`
contiene su `forward_host`. El script no modifica ni Proxmox ni Nginx Proxy Manager.
