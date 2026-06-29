# REST Echo Service

A minimal REST echo service written in Python (ASGI + uvicorn). Accepts all HTTP methods on any path and responds with a JSON payload containing the method, path, status code, request headers, and extracted tracing headers.

**Container image:** `quay.io/nlembers/rest-echo-service:latest`

## Endpoints

| Path | Description |
|------|-------------|
| `/*` | Echo — returns method, path, status, headers as JSON |
| `/health` | Health check — returns `UP` (plain text) |

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `PORT` | `8080` | Listen port |

## Develop

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
pip install -r requirements_dev.txt
```

### Run locally

```bash
python3 main.py
```

### Unit tests

```bash
python3 -m pytest
```

### Build container image

```bash
podman build -t quay.io/nlembers/rest-echo-service:latest -f Containerfile .
podman push quay.io/nlembers/rest-echo-service:latest
```