import os
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

import pytest
from fastapi.testclient import TestClient
import main as svc

client = TestClient(svc.app)


@pytest.fixture(autouse=True)
def clear_state():
    svc._orders_db.clear()
    svc._memory_leak_store.clear()
    yield
    svc._orders_db.clear()
    svc._memory_leak_store.clear()


@pytest.fixture
def created_order():
    r = client.post("/orders?item_id=item-001&quantity=2&user_id=user-42")
    assert r.status_code == 200
    return r.json()


# ── ops ──────────────────────────────────────────────────────────────────────

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "order-service"
    assert "timestamp" in body


def test_ready():
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_metrics():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "order_requests_total" in r.text


# ── orders ────────────────────────────────────────────────────────────────────

def test_list_orders_empty():
    r = client.get("/orders")
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 0
    assert body["orders"] == []


def test_create_order(created_order):
    assert created_order["status"] == "created"
    assert created_order["item_id"] == "item-001"
    assert created_order["quantity"] == 2
    assert created_order["order_id"].startswith("ord-")


def test_list_orders_after_create(created_order):
    r = client.get("/orders")
    assert r.status_code == 200
    assert r.json()["total"] == 1


def test_get_order(created_order):
    order_id = created_order["order_id"]
    r = client.get(f"/orders/{order_id}")
    assert r.status_code == 200
    assert r.json()["item_id"] == "item-001"


def test_get_order_not_found():
    r = client.get("/orders/ord-000000")
    assert r.status_code == 404


# ── chaos ─────────────────────────────────────────────────────────────────────

def test_cpu_stress():
    r = client.get("/stress/cpu?duration=1")
    assert r.status_code == 200
    assert r.json()["status"] == "cpu_stress_started"
    assert r.json()["duration_seconds"] == 1


def test_memory_stress():
    r = client.get("/stress/memory?mb=1")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "memory_leaked"
    assert body["allocated_mb"] == 1


def test_memory_reset():
    client.get("/stress/memory?mb=1")
    r = client.get("/stress/memory/reset")
    assert r.status_code == 200
    assert r.json()["status"] == "memory_cleared"


def test_slow_endpoint():
    r = client.get("/slow?delay=100")
    assert r.status_code == 200
    assert r.json()["delay_ms"] == 100


def test_error_rate_zero_never_fails():
    for _ in range(5):
        r = client.get("/error?rate=0")
        assert r.status_code == 200


def test_error_rate_hundred_always_fails():
    r = client.get("/error?rate=100")
    assert r.status_code == 500
