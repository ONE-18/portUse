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
