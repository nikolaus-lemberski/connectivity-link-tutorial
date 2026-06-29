import main
import pytest


@pytest.mark.asyncio
async def test_tracing_headers():
    request_headers = [
        (b"x-request-id", b"myRequestId"),
        (b"x-b3-traceid", b"myTraceId"),
        (b"traceparent", b"00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
        (b"tracestate", b"congo=t61rcWkgMzE"),
        (b"foo", b"bar")
    ]

    tracing_headers = await main.extract_tracing_headers(request_headers)
    assert len(tracing_headers) == 4
    assert "x-request-id" in str(tracing_headers)
    assert "myRequestId" in str(tracing_headers)
    assert "x-b3-traceid" in str(tracing_headers)
    assert "myTraceId" in str(tracing_headers)
    assert "traceparent" in str(tracing_headers)
    assert "tracestate" in str(tracing_headers)
