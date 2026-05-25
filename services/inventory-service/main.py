import os
import time
import random
import logging
import json
import threading
import tempfile
import shutil
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, Query, HTTPException
from fastapi.responses import Response
import uvicorn

from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes

from prometheus_client import (
    Counter, Histogram, Gauge,
    generate_latest, CONTENT_TYPE_LATEST
)

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","service":"inventory-service","msg":"%(message)s"}'
)
logger = logging.getLogger(__name__)

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
OTEL_ENDPOINT   = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
SERVICE_NAME    = "inventory-service"
SERVICE_VERSION = "1.0.0"

resource = Resource.create({
    ResourceAttributes.SERVICE_NAME: SERVICE_NAME,
    ResourceAttributes.SERVICE_VERSION: SERVICE_VERSION,
    ResourceAttributes.DEPLOYMENT_ENVIRONMENT: os.getenv("ENV", "production"),
})

tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True))
)
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer(SERVICE_NAME)

metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=OTEL_ENDPOINT, insecure=True)
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT      = Counter("inventory_requests_total",        "Total requests",          ["method", "endpoint", "status"])
REQUEST_LATENCY    = Histogram("inventory_request_duration_secs","Request latency",         ["endpoint"],
                                buckets=[0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5])
ITEMS_TOTAL        = Gauge("inventory_items_total",              "Total items in inventory")
LOW_STOCK          = Gauge("inventory_low_stock_items",          "Items below reorder threshold")
STOCK_OPS          = Counter("inventory_stock_ops_total",        "Stock operations",        ["operation"])
DISK_WRITE_LATENCY = Histogram("inventory_disk_write_secs",      "Disk write latency",
                                buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5])
DISK_READ_LATENCY  = Histogram("inventory_disk_read_secs",       "Disk read latency",
                                buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5])
DISK_BYTES_WRITTEN = Counter("inventory_disk_bytes_written_total","Bytes written to disk")
CACHE_HIT          = Counter("inventory_cache_ops_total",        "Cache operations",        ["result"])

# ── State ─────────────────────────────────────────────────────────────────────
_inventory: dict = {
    f"item-{i:04d}": {
        "name": random.choice(["Widget", "Gadget", "Doohickey", "Thingamajig", "Whatsit"]) + f"-{i}",
        "stock": random.randint(0, 500),
        "reorder_threshold": 10,
        "price": round(random.uniform(1.0, 999.0), 2),
    }
    for i in range(1, 101)
}
ITEMS_TOTAL.set(len(_inventory))
LOW_STOCK.set(sum(1 for v in _inventory.values() if v["stock"] < v["reorder_threshold"]))

TEMP_DIR = Path(tempfile.mkdtemp(prefix="inventory_stress_"))

app = FastAPI(
    title="Inventory Service",
    description="AIOps demo – inventory microservice with disk I/O stress, cache simulation, stock management",
    version=SERVICE_VERSION,
)
FastAPIInstrumentor.instrument_app(app)

# ─────────────────────────────────────────────────────────────────────────────
# Health & ops
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/health", tags=["ops"])
def health():
    return {"status": "ok", "service": SERVICE_NAME, "timestamp": datetime.utcnow().isoformat()}

@app.get("/ready", tags=["ops"])
def ready():
    disk_ok = shutil.disk_usage(TEMP_DIR).free > 100 * 1024 * 1024  # 100MB free
    return {"status": "ready" if disk_ok else "degraded", "disk_space_ok": disk_ok}

@app.get("/metrics", tags=["ops"])
def prometheus_metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# ─────────────────────────────────────────────────────────────────────────────
# Core business endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/inventory", tags=["inventory"])
def list_inventory(
    low_stock_only: bool = Query(False),
    limit: int = Query(20, ge=1, le=100),
):
    with tracer.start_as_current_span("list_inventory"):
        # Simulate cache lookup
        cache_hit = random.random() < 0.7
        CACHE_HIT.labels(result="hit" if cache_hit else "miss").inc()
        if not cache_hit:
            time.sleep(random.uniform(0.01, 0.05))  # cache miss = DB hit

        items = list(_inventory.items())
        if low_stock_only:
            items = [(k, v) for k, v in items if v["stock"] < v["reorder_threshold"]]

        REQUEST_COUNT.labels(method="GET", endpoint="/inventory", status="200").inc()
        return {"items": dict(items[:limit]), "total": len(items), "cache_hit": cache_hit}

@app.get("/inventory/{item_id}", tags=["inventory"])
def get_item(item_id: str):
    if item_id not in _inventory:
        REQUEST_COUNT.labels(method="GET", endpoint="/inventory/{id}", status="404").inc()
        raise HTTPException(status_code=404, detail="Item not found")
    REQUEST_COUNT.labels(method="GET", endpoint="/inventory/{id}", status="200").inc()
    return {item_id: _inventory[item_id]}

@app.put("/inventory/{item_id}/stock", tags=["inventory"])
def update_stock(item_id: str, delta: int = Query(..., description="+/- stock change")):
    if item_id not in _inventory:
        raise HTTPException(status_code=404, detail="Item not found")

    _inventory[item_id]["stock"] = max(0, _inventory[item_id]["stock"] + delta)
    LOW_STOCK.set(sum(1 for v in _inventory.values() if v["stock"] < v["reorder_threshold"]))
    STOCK_OPS.labels(operation="update").inc()

    logger.info(json.dumps({"event": "stock_updated", "item_id": item_id, "delta": delta,
                             "new_stock": _inventory[item_id]["stock"]}))
    return {"item_id": item_id, "new_stock": _inventory[item_id]["stock"]}

# ─────────────────────────────────────────────────────────────────────────────
# Chaos endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/stress/disk/write", tags=["chaos"])
def disk_write_stress(
    files:     int = Query(10,  ge=1,  le=200,   description="Number of files to write"),
    size_kb:   int = Query(512, ge=1,  le=10240, description="Size of each file in KB"),
):
    """
    Writes `files` × `size_kb`KB files to disk.
    Triggers disk I/O saturation and write-latency alerts.
    """
    written_bytes = 0
    latencies = []
    with tracer.start_as_current_span("disk_write_stress") as span:
        span.set_attribute("files", files)
        span.set_attribute("size_kb", size_kb)

        for i in range(files):
            fpath = TEMP_DIR / f"stress_{i}_{int(time.time())}.tmp"
            data  = os.urandom(size_kb * 1024)
            t0    = time.time()
            fpath.write_bytes(data)
            elapsed = time.time() - t0
            DISK_WRITE_LATENCY.observe(elapsed)
            latencies.append(elapsed)
            written_bytes += len(data)

        DISK_BYTES_WRITTEN.inc(written_bytes)

    avg_lat = sum(latencies) / len(latencies) if latencies else 0
    logger.warning(json.dumps({
        "event": "disk_write_stress", "files": files,
        "total_bytes": written_bytes, "avg_write_latency_ms": round(avg_lat * 1000, 2),
    }))
    return {"status": "done", "files_written": files, "total_bytes": written_bytes, "avg_write_latency_ms": round(avg_lat * 1000, 2)}

@app.get("/stress/disk/read", tags=["chaos"])
def disk_read_stress(files: int = Query(10, ge=1, le=200)):
    """
    Reads all stress files written by /stress/disk/write.
    Triggers disk read-latency alerts.
    """
    stress_files = list(TEMP_DIR.glob("stress_*.tmp"))
    if not stress_files:
        raise HTTPException(status_code=400, detail="No stress files found — run /stress/disk/write first")

    latencies = []
    total_bytes = 0
    with tracer.start_as_current_span("disk_read_stress"):
        for fpath in stress_files[:files]:
            t0 = time.time()
            data = fpath.read_bytes()
            elapsed = time.time() - t0
            DISK_READ_LATENCY.observe(elapsed)
            latencies.append(elapsed)
            total_bytes += len(data)

    avg_lat = sum(latencies) / len(latencies) if latencies else 0
    logger.warning(json.dumps({
        "event": "disk_read_stress", "files_read": len(latencies),
        "total_bytes": total_bytes, "avg_read_latency_ms": round(avg_lat * 1000, 2),
    }))
    return {"status": "done", "files_read": len(latencies), "total_bytes": total_bytes, "avg_read_latency_ms": round(avg_lat * 1000, 2)}

@app.delete("/stress/disk/cleanup", tags=["chaos"])
def disk_cleanup():
    """Remove all stress temp files."""
    removed = 0
    for f in TEMP_DIR.glob("stress_*.tmp"):
        f.unlink()
        removed += 1
    logger.info(json.dumps({"event": "disk_cleanup", "files_removed": removed}))
    return {"status": "cleaned", "files_removed": removed}

@app.get("/slow", tags=["chaos"])
def slow_inventory(delay: int = Query(3000, ge=100, le=30000)):
    """Slow DB query simulation."""
    secs = delay / 1000
    time.sleep(secs)
    REQUEST_LATENCY.labels(endpoint="/slow").observe(secs)
    logger.warning(json.dumps({"event": "slow_inventory_query", "delay_ms": delay}))
    return {"status": "ok", "delay_ms": delay}

@app.get("/error", tags=["chaos"])
def trigger_error(rate: int = Query(100, ge=0, le=100)):
    """Trigger inventory errors at `rate`% probability."""
    if random.randint(1, 100) <= rate:
        REQUEST_COUNT.labels(method="GET", endpoint="/error", status="500").inc()
        logger.error(json.dumps({"event": "simulated_inventory_error", "rate_pct": rate}))
        raise HTTPException(status_code=500, detail="Simulated inventory error")
    REQUEST_COUNT.labels(method="GET", endpoint="/error", status="200").inc()
    return {"status": "ok"}

@app.get("/chaos/stock-drain", tags=["chaos"])
def stock_drain():
    """
    Set all items to 0 stock — triggers mass low-stock alerts.
    """
    for item in _inventory.values():
        item["stock"] = 0
    LOW_STOCK.set(len(_inventory))
    STOCK_OPS.labels(operation="drain").inc()
    logger.warning(json.dumps({"event": "stock_drain", "affected_items": len(_inventory)}))
    return {"status": "all_stock_drained", "items_affected": len(_inventory)}

@app.get("/chaos/stock-restore", tags=["chaos"])
def stock_restore():
    """Restore all items to random stock levels."""
    for item in _inventory.values():
        item["stock"] = random.randint(50, 500)
    LOW_STOCK.set(0)
    logger.info(json.dumps({"event": "stock_restore"}))
    return {"status": "stock_restored"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8001, log_level="info")
