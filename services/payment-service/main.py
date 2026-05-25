import os
import time
import random
import logging
import json
import threading
from datetime import datetime
from typing import Optional

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
    Counter, Histogram, Gauge, Summary,
    generate_latest, CONTENT_TYPE_LATEST
)
import httpx

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","service":"payment-service","msg":"%(message)s"}'
)
logger = logging.getLogger(__name__)

# ── OpenTelemetry ─────────────────────────────────────────────────────────────
OTEL_ENDPOINT   = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
SERVICE_NAME    = "payment-service"
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
REQUEST_COUNT       = Counter("payment_requests_total",          "Total requests",              ["method", "endpoint", "status"])
REQUEST_LATENCY     = Histogram("payment_request_duration_secs", "Request latency",             ["endpoint"],
                                 buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10])
PAYMENTS_PROCESSED  = Counter("payments_processed_total",        "Payments processed",          ["result"])
PAYMENT_AMOUNT      = Summary("payment_amount_dollars",          "Payment amounts processed")
FRAUD_DETECTED      = Counter("payment_fraud_detected_total",    "Fraud checks triggered")
RETRY_COUNT         = Counter("payment_retries_total",           "Payment retry attempts",      ["reason"])
CIRCUIT_OPEN        = Gauge("payment_circuit_breaker_open",      "Circuit breaker state (1=open)")
GATEWAY_LATENCY     = Histogram("payment_gateway_latency_secs",  "External gateway call latency",
                                 buckets=[0.05, 0.1, 0.25, 0.5, 1, 2, 5])

# ── State ─────────────────────────────────────────────────────────────────────
_circuit_open      = False
_circuit_open_until = 0.0
_payments_db: dict = {}

app = FastAPI(
    title="Payment Service",
    description="AIOps demo – payment microservice with circuit breaker, fraud detection, retry simulation",
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
    cb_state = "open" if _circuit_open and time.time() < _circuit_open_until else "closed"
    return {"status": "ready", "circuit_breaker": cb_state}

@app.get("/metrics", tags=["ops"])
def prometheus_metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# ─────────────────────────────────────────────────────────────────────────────
# Core business endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.post("/payments", tags=["payments"])
async def process_payment(
    order_id:  str   = Query(...),
    amount:    float = Query(..., gt=0, le=100000),
    currency:  str   = Query("USD"),
    user_id:   str   = Query(...),
):
    global _circuit_open, _circuit_open_until
    start = time.time()

    with tracer.start_as_current_span("process_payment") as span:
        span.set_attribute("payment.order_id", order_id)
        span.set_attribute("payment.amount",   amount)
        span.set_attribute("payment.currency", currency)

        # Circuit breaker check
        if _circuit_open and time.time() < _circuit_open_until:
            CIRCUIT_OPEN.set(1)
            REQUEST_COUNT.labels(method="POST", endpoint="/payments", status="503").inc()
            logger.error(json.dumps({"event": "circuit_open", "order_id": order_id}))
            raise HTTPException(status_code=503, detail="Circuit breaker OPEN — payment gateway unavailable")

        # Fraud check simulation
        if amount > 10000 or random.random() < 0.02:
            FRAUD_DETECTED.inc()
            logger.warning(json.dumps({"event": "fraud_check_triggered", "amount": amount, "user_id": user_id}))

        # Simulate gateway latency (50-300ms normally, 2-5s when degraded)
        degraded = random.random() < 0.05
        gw_latency = random.uniform(2.0, 5.0) if degraded else random.uniform(0.05, 0.3)
        time.sleep(gw_latency)
        GATEWAY_LATENCY.observe(gw_latency)

        # Random 3% failure — open circuit for 30s
        if random.random() < 0.03:
            _circuit_open = True
            _circuit_open_until = time.time() + 30
            CIRCUIT_OPEN.set(1)
            PAYMENTS_PROCESSED.labels(result="failed").inc()
            RETRY_COUNT.labels(reason="gateway_error").inc()
            logger.error(json.dumps({"event": "payment_failed", "order_id": order_id, "circuit_opened": True}))
            raise HTTPException(status_code=502, detail="Payment gateway error — circuit breaker tripped")

        _circuit_open = False
        CIRCUIT_OPEN.set(0)

        payment_id = f"pay-{random.randint(100000, 999999)}"
        _payments_db[payment_id] = {"order_id": order_id, "amount": amount, "currency": currency, "status": "success"}
        PAYMENTS_PROCESSED.labels(result="success").inc()
        PAYMENT_AMOUNT.observe(amount)

        elapsed = time.time() - start
        REQUEST_LATENCY.labels(endpoint="/payments").observe(elapsed)
        REQUEST_COUNT.labels(method="POST", endpoint="/payments", status="200").inc()
        logger.info(json.dumps({"event": "payment_processed", "payment_id": payment_id, "amount": amount}))

        return {"payment_id": payment_id, "status": "success", "amount": amount, "currency": currency}

@app.get("/payments/{payment_id}", tags=["payments"])
def get_payment(payment_id: str):
    if payment_id not in _payments_db:
        raise HTTPException(status_code=404, detail="Payment not found")
    return _payments_db[payment_id]

# ─────────────────────────────────────────────────────────────────────────────
# Chaos endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.post("/chaos/circuit-open", tags=["chaos"])
def open_circuit(duration: int = Query(60, ge=5, le=300)):
    """Manually open circuit breaker for `duration` seconds."""
    global _circuit_open, _circuit_open_until
    _circuit_open = True
    _circuit_open_until = time.time() + duration
    CIRCUIT_OPEN.set(1)
    logger.warning(json.dumps({"event": "circuit_manually_opened", "duration_seconds": duration}))
    return {"status": "circuit_breaker_opened", "duration_seconds": duration}

@app.post("/chaos/circuit-close", tags=["chaos"])
def close_circuit():
    """Manually close circuit breaker."""
    global _circuit_open
    _circuit_open = False
    CIRCUIT_OPEN.set(0)
    logger.info(json.dumps({"event": "circuit_manually_closed"}))
    return {"status": "circuit_breaker_closed"}

@app.get("/slow", tags=["chaos"])
def slow_payment(delay: int = Query(5000, ge=100, le=30000)):
    """Slow payment gateway simulation — triggers P99 latency alerts."""
    secs = delay / 1000
    GATEWAY_LATENCY.observe(secs)
    time.sleep(secs)
    REQUEST_LATENCY.labels(endpoint="/slow").observe(secs)
    logger.warning(json.dumps({"event": "slow_payment", "delay_ms": delay}))
    return {"status": "ok", "simulated_gateway_delay_ms": delay}

@app.get("/error", tags=["chaos"])
def trigger_error(rate: int = Query(100, ge=0, le=100)):
    """Trigger payment errors at `rate`% probability."""
    if random.randint(1, 100) <= rate:
        REQUEST_COUNT.labels(method="GET", endpoint="/error", status="500").inc()
        logger.error(json.dumps({"event": "simulated_payment_error", "rate_pct": rate}))
        raise HTTPException(status_code=500, detail="Simulated payment error")
    REQUEST_COUNT.labels(method="GET", endpoint="/error", status="200").inc()
    return {"status": "ok"}

@app.get("/chaos/retry-storm", tags=["chaos"])
def retry_storm(count: int = Query(20, ge=1, le=100)):
    """Simulate a retry storm — increments retry counter rapidly."""
    for _ in range(count):
        RETRY_COUNT.labels(reason="timeout").inc()
    logger.warning(json.dumps({"event": "retry_storm_simulated", "retry_count": count}))
    return {"status": "retry_storm_simulated", "retries": count}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8002, log_level="info")
