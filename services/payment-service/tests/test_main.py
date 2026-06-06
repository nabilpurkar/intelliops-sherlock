"""
Unit tests for payment-service.

Tests cover: health endpoints, payment processing, circuit breaker chaos,
Prometheus metrics emission, and fraud/decline simulation.
"""
import pytest
from fastapi.testclient import TestClient

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import app, _circuit_open

client = TestClient(app, raise_server_exceptions=False)


# ── Health / readiness ────────────────────────────────────────────────────────

def test_health_returns_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "payment-service"


def test_ready_returns_ready():
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_metrics_returns_prometheus_text():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "payment_requests_total" in r.text


# ── Payment processing ────────────────────────────────────────────────────────

def test_process_payment_returns_valid_response():
    import main as m
    m._circuit_open = False           # ensure circuit is closed

    r = client.post("/payments/process")
    # Normal traffic: success (200), fraud (402), or decline (402)
    assert r.status_code in (200, 402)
    if r.status_code == 200:
        body = r.json()
        assert "payment_id" in body
        assert body["status"] == "approved"


def test_payment_by_order_id_returns_valid_response():
    import main as m
    m._circuit_open = False

    r = client.post("/payments/9999")
    assert r.status_code in (200, 402)


# ── Circuit breaker chaos ─────────────────────────────────────────────────────

def test_open_circuit_returns_503_on_payment():
    r = client.post("/chaos/circuit-open?duration=60")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "circuit_open"
    assert body["auto_close_seconds"] == 60

    r = client.post("/payments/process")
    assert r.status_code == 503
    assert "circuit breaker" in r.json()["error"]


def test_close_circuit_restores_payments():
    import main as m
    m._circuit_open = True

    r = client.post("/chaos/circuit-close")
    assert r.status_code == 200
    assert r.json()["status"] == "circuit_closed"

    r = client.post("/payments/process")
    assert r.status_code in (200, 402)  # no longer 503


def test_circuit_duration_limits_enforced():
    r = client.post("/chaos/circuit-open?duration=5")  # ge=5 minimum
    assert r.status_code == 200

    r = client.post("/chaos/circuit-open?duration=4")  # below min
    assert r.status_code == 422

    r = client.post("/chaos/circuit-open?duration=999")  # above max (300)
    assert r.status_code == 422


# ── Chaos slow / error ────────────────────────────────────────────────────────

def test_slow_returns_ok():
    r = client.get("/slow?delay=100")  # 100 ms minimum
    assert r.status_code == 200
    assert r.json()["delayed_ms"] == 100


def test_error_rate_zero_always_succeeds():
    r = client.get("/error?rate=0")
    assert r.status_code == 200


def test_error_rate_hundred_always_fails():
    r = client.get("/error?rate=100")
    assert r.status_code == 500


def test_retry_storm_increments_counter():
    r = client.get("/chaos/retry-storm?count=5")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["retries_incremented"] == 5


def test_retry_storm_limit_enforced():
    r = client.get("/chaos/retry-storm?count=0")
    assert r.status_code == 422

    r = client.get("/chaos/retry-storm?count=101")
    assert r.status_code == 422


# ── Catch-all ─────────────────────────────────────────────────────────────────

def test_catch_all_returns_service_name():
    r = client.get("/unknown/path")
    assert r.status_code == 200
    assert r.json()["service"] == "payment-service"
