"""
Unit tests for order-service.

Tests cover: health endpoints, core business logic, chaos endpoints,
Prometheus metrics emission, and error boundary behaviour.
"""
import pytest
from fastapi.testclient import TestClient
from unittest.mock import patch, AsyncMock

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import app

client = TestClient(app, raise_server_exceptions=False)


# ── Health / readiness ────────────────────────────────────────────────────────

def test_health_returns_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "order-service"


def test_ready_returns_ready():
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_metrics_endpoint_returns_prometheus_text():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "order_requests_total" in r.text


# ── Core order endpoints ──────────────────────────────────────────────────────

def test_get_order_returns_order_data():
    r = client.get("/orders/1234")
    assert r.status_code in (200, 404)
    if r.status_code == 200:
        body = r.json()
        assert "order_id" in body
        assert body["order_id"] == 1234


def test_get_order_bad_id_returns_422():
    r = client.get("/orders/not-a-number")
    assert r.status_code == 422


@patch("main.httpx.AsyncClient")
def test_create_order_success(mock_client_cls):
    mock_resp = AsyncMock()
    mock_resp.status_code = 200
    mock_http = AsyncMock()
    mock_http.__aenter__ = AsyncMock(return_value=mock_http)
    mock_http.__aexit__ = AsyncMock(return_value=False)
    mock_http.get = AsyncMock(return_value=mock_resp)
    mock_http.post = AsyncMock(return_value=mock_resp)
    mock_client_cls.return_value = mock_http

    r = client.post("/orders")
    # 200 (success) or 500 (2% simulated failure) both valid
    assert r.status_code in (200, 500)
    if r.status_code == 200:
        body = r.json()
        assert "order_id" in body
        assert body["status"] == "created"


# ── Chaos endpoints ───────────────────────────────────────────────────────────

def test_slow_endpoint_returns_ok():
    r = client.get("/slow?delay=100")  # 100 ms minimum — fastest allowed value
    assert r.status_code == 200
    body = r.json()
    assert body["delayed_ms"] == 100


def test_slow_endpoint_rejects_invalid_delay():
    r = client.get("/slow?delay=0")
    assert r.status_code == 422


def test_error_endpoint_returns_valid_status():
    r = client.get("/error?rate=0")   # 0% error rate — always OK
    assert r.status_code == 200

    r = client.get("/error?rate=100")  # 100% error rate — always 500
    assert r.status_code == 500


def test_error_rate_out_of_range_rejected():
    r = client.get("/error?rate=101")
    assert r.status_code == 422


def test_stress_cpu_starts_background_thread():
    r = client.get("/stress/cpu?duration=1")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "started"
    assert body["duration_seconds"] == 1


def test_stress_cpu_duration_capped():
    r = client.get("/stress/cpu?duration=999")
    assert r.status_code == 422


def test_stress_memory_allocates():
    r = client.get("/stress/memory?mb=1")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "allocated"
    assert body["requested_mb"] == 1
    assert body["total_leaked_mb"] >= 1


def test_stress_memory_reset():
    client.get("/stress/memory?mb=1")
    r = client.get("/stress/memory/reset")
    assert r.status_code == 200
    assert r.json()["status"] == "cleared"


def test_stress_memory_limit_enforced():
    r = client.get("/stress/memory?mb=501")
    assert r.status_code == 422


@patch("main.httpx.AsyncClient")
def test_downstream_timeout_returns_504(mock_client_cls):
    mock_http = AsyncMock()
    mock_http.__aenter__ = AsyncMock(return_value=mock_http)
    mock_http.__aexit__ = AsyncMock(return_value=False)
    mock_http.get = AsyncMock(side_effect=Exception("timeout"))
    mock_client_cls.return_value = mock_http

    r = client.get("/downstream/timeout")
    assert r.status_code == 504
    assert "timeout" in r.json()["error"]


@patch("main.httpx.AsyncClient")
def test_downstream_call_returns_results(mock_client_cls):
    mock_resp = AsyncMock()
    mock_resp.status_code = 200
    mock_http = AsyncMock()
    mock_http.__aenter__ = AsyncMock(return_value=mock_http)
    mock_http.__aexit__ = AsyncMock(return_value=False)
    mock_http.get = AsyncMock(return_value=mock_resp)
    mock_http.post = AsyncMock(return_value=mock_resp)
    mock_client_cls.return_value = mock_http

    r = client.get("/downstream/call")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert "downstream" in body
    assert "inventory" in body["downstream"]
    assert "payment" in body["downstream"]


# ── Catch-all ─────────────────────────────────────────────────────────────────

def test_catch_all_returns_service_name():
    r = client.get("/unknown/path")
    assert r.status_code == 200
    assert r.json()["service"] == "order-service"
