import os
os.environ.setdefault("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")

import pytest
from fastapi.testclient import TestClient
import main as svc

client = TestClient(svc.app)

KNOWN_ITEM = "item-0001"


@pytest.fixture(autouse=True)
def restore_stock():
    # Snapshot stock before each test, restore after
    original = {k: dict(v) for k, v in svc._inventory.items()}
    yield
    for k, v in original.items():
        svc._inventory[k].update(v)


# ── ops ──────────────────────────────────────────────────────────────────────

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "inventory-service"


def test_ready():
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] in ("ready", "degraded")


def test_metrics():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "inventory_requests_total" in r.text


# ── inventory ─────────────────────────────────────────────────────────────────

def test_list_inventory():
    r = client.get("/inventory")
    assert r.status_code == 200
    body = r.json()
    assert "items" in body
    assert "total" in body
    assert len(body["items"]) <= 20  # default limit


def test_list_inventory_low_stock():
    r = client.get("/inventory?low_stock_only=true")
    assert r.status_code == 200
    body = r.json()
    for item in body["items"].values():
        assert item["stock"] < item["reorder_threshold"]


def test_list_inventory_limit():
    r = client.get("/inventory?limit=5")
    assert r.status_code == 200
    assert len(r.json()["items"]) <= 5


def test_get_item():
    r = client.get(f"/inventory/{KNOWN_ITEM}")
    assert r.status_code == 200
    assert KNOWN_ITEM in r.json()


def test_get_item_not_found():
    r = client.get("/inventory/nonexistent-item")
    assert r.status_code == 404


def test_update_stock_increase():
    before = svc._inventory[KNOWN_ITEM]["stock"]
    r = client.put(f"/inventory/{KNOWN_ITEM}/stock?delta=10")
    assert r.status_code == 200
    body = r.json()
    assert body["item_id"] == KNOWN_ITEM
    assert body["new_stock"] == max(0, before + 10)


def test_update_stock_decrease_no_negative():
    svc._inventory[KNOWN_ITEM]["stock"] = 3
    r = client.put(f"/inventory/{KNOWN_ITEM}/stock?delta=-10")
    assert r.status_code == 200
    assert r.json()["new_stock"] == 0  # clamped at 0


def test_update_stock_not_found():
    r = client.put("/inventory/nonexistent-item/stock?delta=1")
    assert r.status_code == 404


# ── chaos ─────────────────────────────────────────────────────────────────────

def test_error_rate_zero():
    for _ in range(5):
        r = client.get("/error?rate=0")
        assert r.status_code == 200


def test_error_rate_hundred():
    r = client.get("/error?rate=100")
    assert r.status_code == 500


def test_stock_drain_and_restore():
    client.get("/chaos/stock-drain")
    for item in svc._inventory.values():
        assert item["stock"] == 0

    client.get("/chaos/stock-restore")
    total_stock = sum(v["stock"] for v in svc._inventory.values())
    assert total_stock > 0


def test_slow_inventory():
    r = client.get("/slow?delay=100")
    assert r.status_code == 200
    assert r.json()["delay_ms"] == 100
