import os, random, time, glob
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
    resource = Resource.create({SERVICE_NAME: os.getenv("OTEL_SERVICE_NAME", "inventory-service")})
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

_init_otel()

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUESTS     = Counter("inventory_requests_total", "HTTP requests", ["method", "endpoint", "status"])
LATENCY      = Histogram("inventory_request_duration_secs", "Request latency", ["endpoint"],
                  buckets=[0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5])
DISK_WRITE   = Histogram("inventory_disk_write_secs", "Disk write latency",
                  buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0])
LOW_STOCK    = Gauge("inventory_low_stock_items", "Items below reorder threshold")
CACHE_OPS    = Counter("inventory_cache_ops_total", "Cache operations", ["result"])

# Chaos state — stock levels (item_id → quantity)
_stock: dict = {f"item-{i}": random.randint(50, 500) for i in range(1, 21)}
_STOCK_BACKUP: dict = dict(_stock)
_DISK_STRESS_DIR = "/tmp/inventory-stress"

LOW_STOCK.set(sum(1 for v in _stock.values() if v < 20))


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


app = FastAPI(title="inventory-service", version="1.3.0")
app.add_middleware(MetricsMiddleware)
FastAPIInstrumentor.instrument_app(app)

# ── Core endpoints ────────────────────────────────────────────────────────────
@app.get("/health")
def health(): return {"status": "ok", "service": "inventory-service"}

@app.get("/ready")
def ready(): return {"status": "ready"}

@app.get("/metrics")
def metrics(): return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/inventory/check")
async def check_inventory():
    # Simulate cache hit/miss
    if random.random() < 0.85:
        CACHE_OPS.labels("hit").inc()
        time.sleep(random.uniform(0.001, 0.003))
    else:
        CACHE_OPS.labels("miss").inc()
        time.sleep(random.uniform(0.005, 0.012))
    item_id = f"item-{random.randint(1, 20)}"
    qty = _stock.get(item_id, random.randint(0, 500))
    return {"available": qty, "status": "ok", "item_id": item_id}

@app.get("/inventory/{item_id}")
async def get_inventory(item_id: str):
    time.sleep(random.uniform(0.001, 0.006))
    qty = _stock.get(item_id)
    if qty is None:
        return JSONResponse({"error": "item not found"}, status_code=404)
    return {"item_id": item_id, "quantity": qty, "reserved": random.randint(0, min(qty, 50))}

# ── Chaos / stress endpoints ──────────────────────────────────────────────────
@app.get("/stress/disk/write")
def disk_write_stress(files: int = Query(default=10, ge=1, le=50), size_kb: int = Query(default=512, ge=1, le=4096)):
    """Write <files> × <size_kb>KB temp files to /tmp — triggers disk I/O saturation metric."""
    os.makedirs(_DISK_STRESS_DIR, exist_ok=True)
    written = 0
    for i in range(files):
        path = f"{_DISK_STRESS_DIR}/stress-{int(time.time())}-{i}.tmp"
        t = time.time()
        with open(path, "wb") as f:
            f.write(os.urandom(size_kb * 1024))
        DISK_WRITE.observe(time.time() - t)
        written += 1
    return {"status": "written", "files": written, "size_kb_each": size_kb, "dir": _DISK_STRESS_DIR}

@app.get("/stress/disk/read")
def disk_read_stress(files: int = Query(default=10, ge=1, le=50)):
    """Read all stress files from /tmp — triggers disk read latency."""
    pattern = f"{_DISK_STRESS_DIR}/stress-*.tmp"
    found = glob.glob(pattern)[:files]
    read = 0
    for path in found:
        try:
            with open(path, "rb") as f:
                f.read()
            read += 1
        except OSError:
            pass
    return {"status": "read", "files_read": read}

@app.delete("/stress/disk/cleanup")
def disk_cleanup():
    """Delete all stress temp files."""
    pattern = f"{_DISK_STRESS_DIR}/stress-*.tmp"
    removed = 0
    for path in glob.glob(pattern):
        try:
            os.remove(path)
            removed += 1
        except OSError:
            pass
    return {"status": "cleaned", "files_removed": removed}

@app.get("/chaos/stock-drain")
def stock_drain():
    """Set all item stock to 0 — triggers low-stock threshold alert."""
    for k in _stock:
        _stock[k] = 0
    LOW_STOCK.set(len(_stock))
    return {"status": "drained", "items_affected": len(_stock)}

@app.get("/chaos/stock-restore")
def stock_restore():
    """Restore all items to original stock levels."""
    _stock.update(_STOCK_BACKUP)
    LOW_STOCK.set(sum(1 for v in _stock.values() if v < 20))
    return {"status": "restored", "items": len(_stock)}

@app.get("/slow")
def slow_response(delay: int = Query(default=2000, ge=100, le=30000)):
    """Simulate slow DB query — triggers P95 latency SLO alert."""
    time.sleep(delay / 1000)
    return {"status": "ok", "delayed_ms": delay}

@app.get("/error")
def inject_error(rate: int = Query(default=50, ge=0, le=100)):
    """Return 500 with <rate>% probability."""
    if random.randint(0, 99) < rate:
        return JSONResponse({"error": "injected failure"}, status_code=500)
    return {"status": "ok"}

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def catch_all(request: Request, path: str):
    return {"service": "inventory-service", "path": path}
