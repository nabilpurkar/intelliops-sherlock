import os, random, time, threading
import httpx
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
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

def _init_otel():
    resource = Resource.create({SERVICE_NAME: os.getenv("OTEL_SERVICE_NAME", "order-service")})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)
    HTTPXClientInstrumentor().instrument()

_init_otel()

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUESTS       = Counter("order_requests_total", "HTTP requests", ["method", "endpoint", "status"])
LATENCY        = Histogram("order_request_duration_seconds", "Request latency", ["endpoint"],
                    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5])
ORDERS_CREATED = Counter("orders_created_total", "Orders created", ["status"])
ACTIVE_ORDERS  = Gauge("orders_active_total", "Active orders")
ERRORS         = Counter("order_errors_total", "Order errors", ["error_type"])
DB_LATENCY     = Histogram("db_query_duration_seconds", "DB query latency", ["query_type"],
                    buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5])
MEMORY_LEAK    = Gauge("order_memory_leak_bytes", "Simulated leaked memory bytes")
CPU_STRESS     = Gauge("order_cpu_stress_active", "1 if CPU stress is active")

ACTIVE_ORDERS.set(random.randint(20, 150))

INVENTORY_URL = os.getenv("INVENTORY_SERVICE_URL", "http://inventory-service:8000")
PAYMENT_URL   = os.getenv("PAYMENT_SERVICE_URL",   "http://payment-service:8000")

# Chaos state
_leaked_memory: list = []
_cpu_stress_active = False


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


app = FastAPI(title="order-service", version="1.2.2")
app.add_middleware(MetricsMiddleware)
FastAPIInstrumentor.instrument_app(app)

# ── Core endpoints ────────────────────────────────────────────────────────────
@app.get("/health")
def health(): return {"status": "ok", "service": "order-service"}

@app.get("/ready")
def ready(): return {"status": "ready"}

@app.get("/metrics")
def metrics(): return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/orders")
async def create_order():
    t = time.time()
    time.sleep(random.uniform(0.002, 0.012))
    DB_LATENCY.labels("insert").observe(time.time() - t)

    async with httpx.AsyncClient(timeout=2.0) as client:
        try: await client.get(f"{INVENTORY_URL}/inventory/check")
        except Exception: pass
        try: await client.post(f"{PAYMENT_URL}/payments/process")
        except Exception: pass

    if random.random() < 0.02:
        ERRORS.labels("payment_declined").inc()
        ORDERS_CREATED.labels("failed").inc()
        return JSONResponse({"error": "payment declined"}, status_code=500)

    ORDERS_CREATED.labels("success").inc()
    ACTIVE_ORDERS.inc()
    return {"order_id": random.randint(1000, 9999), "status": "created"}

@app.get("/orders/{order_id}")
async def get_order(order_id: int):
    t = time.time()
    time.sleep(random.uniform(0.001, 0.006))
    DB_LATENCY.labels("select").observe(time.time() - t)
    if random.random() < 0.005:
        return JSONResponse({"error": "not found"}, status_code=404)
    return {"order_id": order_id, "status": "processing", "total": round(random.uniform(10, 500), 2)}

# ── Chaos / stress endpoints ──────────────────────────────────────────────────
@app.get("/stress/cpu")
def stress_cpu(duration: int = Query(default=10, ge=1, le=60)):
    """Burn CPU for <duration> seconds — triggers CPU alert in Prometheus."""
    global _cpu_stress_active
    _cpu_stress_active = True
    CPU_STRESS.set(1)

    def _burn():
        global _cpu_stress_active
        end = time.time() + duration
        while time.time() < end:
            _ = sum(i * i for i in range(10000))
        _cpu_stress_active = False
        CPU_STRESS.set(0)

    threading.Thread(target=_burn, daemon=True).start()
    return {"status": "started", "duration_seconds": duration, "metric": "order_cpu_stress_active"}

@app.get("/stress/memory")
def stress_memory(mb: int = Query(default=50, ge=1, le=500)):
    """Allocate <mb> MB and hold it — triggers memory alert."""
    global _leaked_memory
    chunk = b"x" * (mb * 1024 * 1024)
    _leaked_memory.append(chunk)
    total = sum(len(c) for c in _leaked_memory)
    MEMORY_LEAK.set(total)
    return {"status": "allocated", "requested_mb": mb, "total_leaked_mb": total // (1024 * 1024)}

@app.get("/stress/memory/reset")
def reset_memory():
    """Release all held memory."""
    global _leaked_memory
    _leaked_memory.clear()
    MEMORY_LEAK.set(0)
    return {"status": "cleared"}

@app.get("/slow")
async def slow_response(delay: int = Query(default=2000, ge=100, le=30000)):
    """Sleep for <delay> ms — triggers latency SLO alert."""
    time.sleep(delay / 1000)
    return {"status": "ok", "delayed_ms": delay}

@app.get("/error")
def inject_error(rate: int = Query(default=50, ge=0, le=100)):
    """Return 500 with <rate>% probability — triggers error budget burn."""
    if random.randint(0, 99) < rate:
        ERRORS.labels("injected").inc()
        return JSONResponse({"error": "injected failure"}, status_code=500)
    return {"status": "ok"}

@app.get("/downstream/timeout")
async def downstream_timeout():
    """Force a timeout calling inventory — triggers cascade failure trace."""
    async with httpx.AsyncClient(timeout=0.001) as client:
        try:
            await client.get(f"{INVENTORY_URL}/inventory/check")
        except Exception as e:
            ERRORS.labels("timeout").inc()
            return JSONResponse({"error": "downstream timeout", "detail": str(e)}, status_code=504)
    return {"status": "ok"}

@app.get("/downstream/call")
async def downstream_call():
    """Normal fan-out call — generates a multi-service distributed trace."""
    results = {}
    async with httpx.AsyncClient(timeout=3.0) as client:
        try:
            r = await client.get(f"{INVENTORY_URL}/inventory/check")
            results["inventory"] = r.status_code
        except Exception as e:
            results["inventory"] = str(e)
        try:
            r = await client.post(f"{PAYMENT_URL}/payments/process")
            results["payment"] = r.status_code
        except Exception as e:
            results["payment"] = str(e)
    return {"status": "ok", "downstream": results}

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request, path: str):
    return {"service": "order-service", "path": path}
