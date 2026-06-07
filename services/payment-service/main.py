from __future__ import annotations
import os, random, time, threading
from fastapi import FastAPI, Query
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response, JSONResponse
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource, SERVICE_NAME
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

def _init_otel():
    resource = Resource.create({SERVICE_NAME: os.getenv("OTEL_SERVICE_NAME", "payment-service")})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

_init_otel()

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUESTS        = Counter("payment_requests_total", "HTTP requests", ["method", "endpoint", "status"])
LATENCY         = Histogram("payment_request_duration_secs", "Request latency", ["endpoint"],
                     buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5])
PAYMENTS        = Counter("payments_processed_total", "Payments processed", ["result"])
GW_LATENCY      = Histogram("payment_gateway_latency_secs", "Gateway call latency",
                     buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5])
CIRCUIT_OPEN    = Gauge("payment_circuit_breaker_open", "1 if circuit breaker is open")
RETRIES         = Counter("payment_retries_total", "Payment retries")
FRAUD_DETECTED  = Counter("payment_fraud_detected_total", "Fraud detections")
ERRORS          = Counter("payment_errors_total", "Payment errors", ["error_type"])

# Chaos state
_circuit_open = False
_circuit_timer: threading.Timer | None = None


class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if path in ("/metrics", "/health", "/ready"):
            return await call_next(request)
        start = time.time()
        response = await call_next(request)
        REQUESTS.labels(request.method, path, str(response.status_code)).inc()
        LATENCY.labels(path).observe(time.time() - start)
        return response


app = FastAPI(title="payment-service", version="1.2.1")
app.add_middleware(MetricsMiddleware)
FastAPIInstrumentor.instrument_app(app)

# ── Core endpoints ────────────────────────────────────────────────────────────
@app.get("/health")
def health(): return {"status": "ok", "service": "payment-service"}

@app.get("/ready")
def ready(): return {"status": "ready"}

@app.get("/metrics")
def metrics(): return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/payments/process")
async def process_payment():
    if _circuit_open:
        ERRORS.labels("circuit_open").inc()
        return JSONResponse({"error": "circuit breaker open — payment gateway unavailable"}, status_code=503)

    t = time.time()
    time.sleep(random.uniform(0.005, 0.025))
    GW_LATENCY.observe(time.time() - t)

    # ~0.5% fraud detection
    if random.random() < 0.005:
        FRAUD_DETECTED.inc()
        PAYMENTS.labels("fraud").inc()
        return JSONResponse({"error": "transaction flagged as fraud"}, status_code=402)

    if random.random() < 0.015:
        PAYMENTS.labels("declined").inc()
        return JSONResponse({"error": "card declined"}, status_code=402)

    PAYMENTS.labels("success").inc()
    return {"payment_id": random.randint(10000, 99999), "status": "approved"}

@app.post("/payments/{order_id}")
async def create_payment(order_id: int):
    if _circuit_open:
        return JSONResponse({"error": "circuit breaker open"}, status_code=503)
    time.sleep(random.uniform(0.005, 0.020))
    if random.random() < 0.015:
        PAYMENTS.labels("declined").inc()
        return JSONResponse({"error": "card declined"}, status_code=402)
    PAYMENTS.labels("success").inc()
    return {"payment_id": random.randint(10000, 99999), "order_id": order_id, "status": "approved"}

# ── Chaos / stress endpoints ──────────────────────────────────────────────────
@app.post("/chaos/circuit-open")
def open_circuit(duration: int = Query(default=60, ge=5, le=300)):
    """Open the circuit breaker for <duration> seconds — all payments return 503."""
    global _circuit_open, _circuit_timer
    _circuit_open = True
    CIRCUIT_OPEN.set(1)

    if _circuit_timer:
        _circuit_timer.cancel()

    def _auto_close():
        global _circuit_open
        _circuit_open = False
        CIRCUIT_OPEN.set(0)

    _circuit_timer = threading.Timer(duration, _auto_close)
    _circuit_timer.daemon = True
    _circuit_timer.start()
    return {"status": "circuit_open", "auto_close_seconds": duration}

@app.post("/chaos/circuit-close")
def close_circuit():
    """Manually close the circuit breaker."""
    global _circuit_open, _circuit_timer
    _circuit_open = False
    CIRCUIT_OPEN.set(0)
    if _circuit_timer:
        _circuit_timer.cancel()
    return {"status": "circuit_closed"}

@app.get("/slow")
def slow_response(delay: int = Query(default=2000, ge=100, le=30000)):
    """Simulate slow gateway — triggers P99 latency alert."""
    time.sleep(delay / 1000)
    return {"status": "ok", "delayed_ms": delay}

@app.get("/error")
def inject_error(rate: int = Query(default=50, ge=0, le=100)):
    """Return 500 with <rate>% probability."""
    if random.randint(0, 99) < rate:
        ERRORS.labels("injected").inc()
        return JSONResponse({"error": "injected failure"}, status_code=500)
    return {"status": "ok"}

@app.get("/chaos/retry-storm")
def retry_storm(count: int = Query(default=20, ge=1, le=100)):
    """Simulate <count> retry attempts — inflates retry metric."""
    for _ in range(count):
        RETRIES.inc()
    return {"status": "ok", "retries_incremented": count, "metric": "payment_retries_total"}

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request, path: str):
    return {"service": "payment-service", "path": path}
