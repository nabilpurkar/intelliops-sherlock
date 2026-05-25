import os
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

import pytest
from fastapi.testclient import TestClient
import main as svc

client = TestClient(svc.app)


@pytest.fixture(autouse=True)
def reset_state():
    svc._circuit_open = False
    svc._circuit_open_until = 0.0
    svc._payments_db.clear()
    yield
    svc._circuit_open = False
    svc._circuit_open_until = 0.0
    svc._payments_db.clear()


# ── ops ──────────────────────────────────────────────────────────────────────

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "payment-service"


def test_ready_circuit_closed():
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["circuit_breaker"] == "closed"


def test_metrics():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "payment_requests_total" in r.text


# ── payments ─────────────────────────────────────────────────────────────────

def test_get_payment_not_found():
    r = client.get("/payments/pay-000000")
    assert r.status_code == 404


# ── chaos ─────────────────────────────────────────────────────────────────────

def test_open_circuit():
    r = client.post("/chaos/circuit-open?duration=60")
    assert r.status_code == 200
    assert r.json()["status"] == "circuit_breaker_opened"
    assert r.json()["duration_seconds"] == 60


def test_close_circuit():
    client.post("/chaos/circuit-open?duration=60")
    r = client.post("/chaos/circuit-close")
    assert r.status_code == 200
    assert r.json()["status"] == "circuit_breaker_closed"


def test_ready_circuit_open():
    client.post("/chaos/circuit-open?duration=60")
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["circuit_breaker"] == "open"


def test_payment_rejected_when_circuit_open():
    client.post("/chaos/circuit-open?duration=60")
    r = client.post("/payments?order_id=ord-1&amount=99.99&user_id=user-1")
    assert r.status_code == 503


def test_slow_payment():
    r = client.get("/slow?delay=100")
    assert r.status_code == 200
    assert r.json()["simulated_gateway_delay_ms"] == 100


def test_error_rate_zero():
    for _ in range(5):
        r = client.get("/error?rate=0")
        assert r.status_code == 200


def test_error_rate_hundred():
    r = client.get("/error?rate=100")
    assert r.status_code == 500


def test_retry_storm():
    r = client.get("/chaos/retry-storm?count=5")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "retry_storm_simulated"
    assert body["retries"] == 5
