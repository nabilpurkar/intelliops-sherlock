import os
import time
import math
import random
import logging
import threading
import tempfile
import json
from datetime import datetime
from typing import Optional

from fastapi import FastAPI, Query, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

# OpenTelemetry
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

# Prometheus
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest,
    CONTENT_TYPE_LATEST, CollectorRegistry, multiprocess
)
from starlette.responses import Response
import httpx

# ── Logging setup ─────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","service":"order-service","msg":"%(message)s"}'
)
logger = logging.getLogger(__name__)

# ── OpenTelemetry setup ───────────────────────────────────────────────────────
OTEL_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
SERVICE_NAME   = "order-service"
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
meter = metrics.get_meter(SERVICE_NAME)

# ── Prometheus metrics ────────────────────────────────────────────────────────
REQUEST_COUNT    = Counter("order_requests_total",    "Total HTTP requests",         ["method", "endpoint", "status"])
REQUEST_LATENCY  = Histogram("order_request_duration_seconds", "Request latency",    ["endpoint"],
                              buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10])
ORDERS_CREATED   = Counter("orders_created_total",    "Total orders created",        ["status"])
ACTIVE_ORDERS    = Gauge("orders_active_total",       "Currently active orders")
DB_QUERY_LATENCY = Histogram("db_query_duration_seconds", "Simulated DB query time", ["query_type"],
                              buckets=[0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1])
ERROR_COUNT      = Counter("order_errors_total",      "Total errors",                ["error_type"])
CPU_STRESS_GAUGE = Gauge("order_cpu_stress_active",   "CPU stress test active")
MEM_LEAK_GAUGE   = Gauge("order_memory_leak_bytes",   "Leaked memory bytes")

# ── In-memory state ───────────────────────────────────────────────────────────
_memory_leak_store: list = []
_orders_db: dict = {}

# ── FastAPI app ───────────────────────────────────────────────────────────────
app = FastAPI(
    title="Order Service",
    description="AIOps demo – order microservice with full observability",
    version=SERVICE_VERSION,
)
FastAPIInstrumentor.instrument_app(app)

INVENTORY_URL  = os.getenv("INVENTORY_SERVICE_URL", "http://inventory-service:8001")
PAYMENT_URL    = os.getenv("PAYMENT_SERVICE_URL",   "http://payment-service:8002")

# ── Helper ────────────────────────────────────────────────────────────────────
def _sim_db_query(query_type: str, min_ms=5, max_ms=50):
    delay = random.uniform(min_ms, max_ms) / 1000
    time.sleep(delay)
    DB_QUERY_LATENCY.labels(query_type=query_type).observe(delay)
    return delay

# ─────────────────────────────────────────────────────────────────────────────
# Health & readiness
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/health", tags=["ops"])
def health():
    return {"status": "ok", "service": SERVICE_NAME, "timestamp": datetime.utcnow().isoformat()}

@app.get("/ready", tags=["ops"])
def ready():
    return {"status": "ready", "service": SERVICE_NAME}

@app.get("/metrics", tags=["ops"])
def prometheus_metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# ─────────────────────────────────────────────────────────────────────────────
# Core business endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.post("/orders", tags=["orders"])
async def create_order(
    item_id: str = Query(..., description="Item to order"),
    quantity: int = Query(1, ge=1, le=100),
    user_id: str = Query(..., description="Customer user ID"),
):
    start = time.time()
    with tracer.start_as_current_span("create_order") as span:
        span.set_attribute("order.item_id", item_id)
        span.set_attribute("order.quantity", quantity)
        span.set_attribute("order.user_id", user_id)

        # Simulate DB insert
        _sim_db_query("INSERT_ORDER", 5, 30)

        order_id = f"ord-{random.randint(100000, 999999)}"
        _orders_db[order_id] = {"item_id": item_id, "quantity": quantity, "user_id": user_id, "status": "pending"}
        ACTIVE_ORDERS.inc()
        ORDERS_CREATED.labels(status="created").inc()

        elapsed = time.time() - start
        REQUEST_COUNT.labels(method="POST", endpoint="/orders", status="200").inc()
        REQUEST_LATENCY.labels(endpoint="/orders").observe(elapsed)

        logger.info(json.dumps({"event": "order_created", "order_id": order_id, "item_id": item_id, "user_id": user_id}))
        return {"order_id": order_id, "status": "created", "item_id": item_id, "quantity": quantity}

@app.get("/orders", tags=["orders"])
def list_orders():
    _sim_db_query("SELECT_ORDERS", 2, 20)
    REQUEST_COUNT.labels(method="GET", endpoint="/orders", status="200").inc()
    return {"orders": list(_orders_db.values()), "total": len(_orders_db)}

@app.get("/orders/{order_id}", tags=["orders"])
def get_order(order_id: str):
    _sim_db_query("SELECT_ORDER", 1, 15)
    if order_id not in _orders_db:
        REQUEST_COUNT.labels(method="GET", endpoint="/orders/{id}", status="404").inc()
        raise HTTPException(status_code=404, detail="Order not found")
    REQUEST_COUNT.labels(method="GET", endpoint="/orders/{id}", status="200").inc()
    return _orders_db[order_id]

# ─────────────────────────────────────────────────────────────────────────────
# Chaos / stress endpoints  (AIOps signal generators)
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/stress/cpu", tags=["chaos"])
def cpu_stress(duration: int = Query(10, ge=1, le=60, description="Seconds to stress CPU")):
    """
    Spin CPU at 100% for `duration` seconds on a background thread.
    Triggers CPU usage alerts in your monitoring stack.
    """
    CPU_STRESS_GAUGE.set(1)
    logger.warning(json.dumps({"event": "cpu_stress_start", "duration_seconds": duration}))

    def _burn(secs):
        end = time.time() + secs
        while time.time() < end:
            _ = math.sqrt(random.random()) ** 2
        CPU_STRESS_GAUGE.set(0)
        logger.info(json.dumps({"event": "cpu_stress_end"}))

    threading.Thread(target=_burn, args=(duration,), daemon=True).start()
    return {"status": "cpu_stress_started", "duration_seconds": duration}

@app.get("/stress/memory", tags=["chaos"])
def memory_stress(mb: int = Query(50, ge=1, le=500, description="MB to allocate and leak")):
    """
    Allocates `mb` MB that is NOT freed.
    Triggers memory usage / OOMKilled alerts.
    """
    chunk = " " * (mb * 1024 * 1024)
    _memory_leak_store.append(chunk)
    leaked = sum(len(s) for s in _memory_leak_store)
    MEM_LEAK_GAUGE.set(leaked)
    logger.warning(json.dumps({"event": "memory_leak", "allocated_mb": mb, "total_leaked_bytes": leaked}))
    return {"status": "memory_leaked", "allocated_mb": mb, "total_leaked_bytes": leaked}

@app.get("/stress/memory/reset", tags=["chaos"])
def memory_reset():
    """Clear the leaked memory."""
    _memory_leak_store.clear()
    MEM_LEAK_GAUGE.set(0)
    return {"status": "memory_cleared"}

@app.get("/slow", tags=["chaos"])
def slow_endpoint(delay: int = Query(3000, ge=100, le=30000, description="Delay in ms")):
    """
    Sleeps for `delay` ms.
    Triggers latency / SLO breach alerts.
    """
    secs = delay / 1000
    with tracer.start_as_current_span("slow_operation") as span:
        span.set_attribute("delay_ms", delay)
        time.sleep(secs)
    REQUEST_LATENCY.labels(endpoint="/slow").observe(secs)
    REQUEST_COUNT.labels(method="GET", endpoint="/slow", status="200").inc()
    logger.warning(json.dumps({"event": "slow_request", "delay_ms": delay}))
    return {"status": "ok", "delay_ms": delay}

@app.get("/error", tags=["chaos"])
def trigger_error(rate: int = Query(100, ge=0, le=100, description="Error rate 0-100%")):
    """
    Returns HTTP 500 with probability = `rate`%.
    Triggers error-rate / error-budget burn alerts.
    """
    if random.randint(1, 100) <= rate:
        ERROR_COUNT.labels(error_type="simulated_500").inc()
        REQUEST_COUNT.labels(method="GET", endpoint="/error", status="500").inc()
        logger.error(json.dumps({"event": "simulated_error", "rate_pct": rate}))
        raise HTTPException(status_code=500, detail="Simulated error for AIOps testing")
    REQUEST_COUNT.labels(method="GET", endpoint="/error", status="200").inc()
    return {"status": "ok", "message": "Lucky — no error this time"}

@app.get("/downstream/timeout", tags=["chaos"])
async def downstream_timeout():
    """
    Calls inventory-service with a very short timeout — always fails.
    Triggers downstream dependency / cascade-failure alerts.
    """
    with tracer.start_as_current_span("downstream_call_timeout") as span:
        span.set_attribute("target", INVENTORY_URL)
        try:
            async with httpx.AsyncClient(timeout=0.001) as client:
                await client.get(f"{INVENTORY_URL}/health")
        except Exception as e:
            ERROR_COUNT.labels(error_type="downstream_timeout").inc()
            REQUEST_COUNT.labels(method="GET", endpoint="/downstream/timeout", status="503").inc()
            logger.error(json.dumps({"event": "downstream_timeout", "target": INVENTORY_URL, "error": str(e)}))
            raise HTTPException(status_code=503, detail=f"Downstream timeout: {e}")

@app.get("/downstream/call", tags=["chaos"])
async def downstream_call():
    """
    Normal call to inventory + payment services.
    Shows distributed trace across 3 services.
    """
    results = {}
    async with httpx.AsyncClient(timeout=5.0) as client:
        with tracer.start_as_current_span("call_inventory"):
            try:
                r = await client.get(f"{INVENTORY_URL}/health")
                results["inventory"] = r.json()
            except Exception as e:
                results["inventory"] = {"error": str(e)}

        with tracer.start_as_current_span("call_payment"):
            try:
                r = await client.get(f"{PAYMENT_URL}/health")
                results["payment"] = r.json()
            except Exception as e:
                results["payment"] = {"error": str(e)}

    return {"status": "ok", "downstream": results}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
