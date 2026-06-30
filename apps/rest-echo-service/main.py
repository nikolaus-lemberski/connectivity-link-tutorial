import json
import os

port = int(os.environ.get("PORT", default=8080))

TRACING_HEADER_PREFIXES = ("x-request-id", "x-b3-", "traceparent", "tracestate")


async def app(scope, receive, send):
    assert scope["type"] == "http"

    method = scope["method"]
    path = scope["path"]
    headers = scope["headers"]

    if path == "/health":
        body, status, content_type = "UP", 200, b"text/plain; charset=utf-8"
    else:
        status = 200
        tracing_headers = await extract_tracing_headers(headers)
        response = {
            "method": method,
            "path": path,
            "status": status,
            "headers": {k.decode(): v.decode() for k, v in headers},
            "tracing_headers": {k.decode(): v.decode() for k, v in tracing_headers},
        }
        body = json.dumps(response, indent=2)
        content_type = b"application/json"

    response_headers = [(b"content-type", content_type)]
    await send({"type": "http.response.start", "status": status, "headers": response_headers})
    await send({"type": "http.response.body", "body": body.encode("UTF-8")})


async def extract_tracing_headers(headers):
    return [
        (k, v) for k, v in headers
        if k.decode().lower().startswith(TRACING_HEADER_PREFIXES)
    ]


try:
    from opentelemetry.instrumentation.asgi import OpenTelemetryMiddleware
    app = OpenTelemetryMiddleware(app, exclude_spans=["send", "receive"])
except ImportError:
    pass


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=port, proxy_headers=True, server_header=False, access_log=False)
