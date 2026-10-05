from __future__ import annotations

import json
import random
import re
import sqlite3
import uuid
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles


BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
DB_PATH = DATA_DIR / "snapshots.db"
STATIC_DIR = BASE_DIR / "static"
DATA_DIR.mkdir(exist_ok=True)

app = FastAPI(title="PortUse", description="Visualizador y comparador de inventarios JSON")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


def connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    with closing(connection()) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS snapshots (
                id TEXT PRIMARY KEY,
                filename TEXT NOT NULL,
                generated TEXT,
                uploaded_at TEXT NOT NULL,
                size INTEGER NOT NULL
            )
            """
        )
        conn.commit()


def read_snapshot(snapshot_id: str) -> tuple[sqlite3.Row, Any]:
    with closing(connection()) as conn:
        row = conn.execute("SELECT * FROM snapshots WHERE id = ?", (snapshot_id,)).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Snapshot no encontrado")
    path = DATA_DIR / f"{snapshot_id}.json"
    try:
        return row, json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail="No se pudo leer el snapshot") from exc


def snapshot_summary(row: sqlite3.Row, payload: Any) -> dict[str, Any]:
    hosts = payload.get("containers", []) if isinstance(payload, dict) else []
    containers = [container for host in hosts if isinstance(host, dict) for container in host.get("containers", [])]
    published_ports = sum(
        1
        for container in containers
        for port in container.get("ports", [])
        if "->" in str(port)
    )
    return {
        "id": row["id"],
        "filename": row["filename"],
        "generated": row["generated"],
        "uploaded_at": row["uploaded_at"],
        "size": row["size"],
        "host_count": len(hosts),
        "container_count": len(containers),
        "published_port_count": published_ports,
    }


def flatten_containers(payload: Any) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for host in payload.get("containers", []) if isinstance(payload, dict) else []:
        if not isinstance(host, dict):
            continue
        hostname = str(host.get("hostname") or f"ctid-{host.get('ctid', 'unknown')}")
        for container in host.get("containers", []):
            if isinstance(container, dict) and container.get("name"):
                key = f"{hostname}/{container['name']}"
                result[key] = {"host": hostname, **container}
    return result


def host_used_ports(host: Any) -> set[int]:
    used: set[int] = set()
    for container in host.get("containers", []) if isinstance(host, dict) else []:
        for value in container.get("ports", []) if isinstance(container, dict) else []:
            text = str(value).split("->", 1)[0]
            numbers = re.findall(r"\d+", text)
            if len(numbers) >= 2 and "-" in text:
                used.update(range(int(numbers[-2]), int(numbers[-1]) + 1))
            elif numbers:
                used.add(int(numbers[-1]))
    return {port for port in used if 1 <= port <= 65535}


@app.on_event("startup")
def startup() -> None:
    init_db()


@app.get("/", response_class=FileResponse)
def index() -> Path:
    return STATIC_DIR / "index.html"


@app.get("/api/snapshots")
def list_snapshots() -> list[dict[str, Any]]:
    with closing(connection()) as conn:
        rows = conn.execute("SELECT * FROM snapshots ORDER BY uploaded_at DESC").fetchall()
    snapshots = []
    for row in rows:
        path = DATA_DIR / f"{row['id']}.json"
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise HTTPException(status_code=500, detail="No se pudo leer un snapshot") from exc
        snapshots.append(snapshot_summary(row, payload))
    return snapshots


@app.post("/api/snapshots", status_code=201)
async def upload_snapshot(file: UploadFile = File(...)) -> dict[str, Any]:
    if not file.filename or not file.filename.lower().endswith(".json"):
        raise HTTPException(status_code=400, detail="El archivo debe tener extensión .json")
    raw = await file.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail=f"JSON inválido: {exc.msg}") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="El JSON debe contener un objeto en la raíz")

    snapshot_id = uuid.uuid4().hex
    uploaded_at = datetime.now(timezone.utc).isoformat()
    generated = payload.get("generated")
    (DATA_DIR / f"{snapshot_id}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    with closing(connection()) as conn:
        conn.execute(
            "INSERT INTO snapshots VALUES (?, ?, ?, ?, ?)",
            (snapshot_id, file.filename, generated, uploaded_at, len(raw)),
        )
        conn.commit()
    with closing(connection()) as conn:
        row = conn.execute("SELECT * FROM snapshots WHERE id = ?", (snapshot_id,)).fetchone()
    return snapshot_summary(row, payload)


@app.get("/api/snapshots/{snapshot_id}")
def get_snapshot(snapshot_id: str) -> dict[str, Any]:
    row, payload = read_snapshot(snapshot_id)
    return {"metadata": snapshot_summary(row, payload), "data": payload}


@app.get("/api/snapshots/{snapshot_id}/random-port")
def random_available_port(snapshot_id: str, host_index: int) -> dict[str, int]:
    _, payload = read_snapshot(snapshot_id)
    hosts = payload.get("containers", []) if isinstance(payload, dict) else []
    if host_index < 0 or host_index >= len(hosts):
        raise HTTPException(status_code=404, detail="Host no encontrado")
    used = host_used_ports(hosts[host_index])
    available = [port for port in range(1024, 65536) if port not in used]
    if not available:
        raise HTTPException(status_code=409, detail="No quedan puertos disponibles para este host")
    return {"port": random.choice(available), "host_index": host_index}


@app.get("/api/compare")
def compare_snapshots(from_id: str, to_id: str) -> dict[str, Any]:
    from_row, from_payload = read_snapshot(from_id)
    to_row, to_payload = read_snapshot(to_id)
    before, after = flatten_containers(from_payload), flatten_containers(to_payload)
    added_keys = sorted(set(after) - set(before))
    removed_keys = sorted(set(before) - set(after))
    changed_keys = sorted(
        key for key in set(before) & set(after) if before[key].get("ports", []) != after[key].get("ports", [])
    )
    return {
        "from": snapshot_summary(from_row, from_payload),
        "to": snapshot_summary(to_row, to_payload),
        "added": [{"key": key, **after[key]} for key in added_keys],
        "removed": [{"key": key, **before[key]} for key in removed_keys],
        "changed": [
            {"key": key, "before": before[key].get("ports", []), "after": after[key].get("ports", [])}
            for key in changed_keys
        ],
    }
