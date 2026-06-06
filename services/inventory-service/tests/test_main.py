"""
Unit tests for inventory-service.

Tests cover: health endpoints, inventory lookup, stock chaos,
disk stress endpoints, Prometheus metrics, and error boundaries.
"""
import pytest
from fastapi.testclient import TestClient

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import app, _stock, _STOCK_BACKUP

client = TestClient(app, raise_server_exceptions=False)


# ── Health / readiness ────────────────────────────────────────────────────────

def test_health_returns_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "inventory-service"


def test_ready_returns_ready():
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json()["status"] == "ready"


def test_metrics_returns_prometheus_text():
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "inventory_requests_total" in r.text


# ── Core inventory endpoints ──────────────────────────────────────────────────

def test_check_inventory_returns_available_quantity():
    r = client.get("/inventory/check")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert "available" in body
    assert isinstance(body["available"], int)


def test_get_inventory_known_item():
    # item-1 always exists in stock
    r = client.get("/inventory/item-1")
    assert r.status_code == 200
    body = r.json()
    assert body["item_id"] == "item-1"
    assert "quantity" in body
    assert "reserved" in body


def test_get_inventory_unknown_item_returns_404():
    r = client.get("/inventory/item-9999")
    assert r.status_code == 404
    assert "not found" in r.json()["error"]


# ── Chaos: stock drain / restore ──────────────────────────────────────────────

def test_stock_drain_sets_all_quantities_to_zero():
    r = client.get("/chaos/stock-drain")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "drained"
    assert body["items_affected"] == 20

    r = client.get("/inventory/item-1")
    assert r.status_code == 200
    assert r.json()["quantity"] == 0


def test_stock_restore_resets_quantities():
    # Drain first
    client.get("/chaos/stock-drain")

    r = client.get("/chaos/stock-restore")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "restored"
    assert body["items"] == 20

    r = client.get("/inventory/item-1")
    assert r.status_code == 200
    assert r.json()["quantity"] > 0


# ── Chaos: disk stress ────────────────────────────────────────────────────────

def test_disk_write_creates_files():
    r = client.get("/stress/disk/write?files=2&size_kb=1")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "written"
    assert body["files"] == 2
    assert body["size_kb_each"] == 1


def test_disk_write_limit_enforced():
    r = client.get("/stress/disk/write?files=0&size_kb=1")
    assert r.status_code == 422

    r = client.get("/stress/disk/write?files=51&size_kb=1")
    assert r.status_code == 422


def test_disk_read_after_write():
    client.get("/stress/disk/write?files=2&size_kb=1")
    r = client.get("/stress/disk/read?files=2")
    assert r.status_code == 200
    assert r.json()["status"] == "read"


def test_disk_cleanup_removes_files():
    client.get("/stress/disk/write?files=2&size_kb=1")
    r = client.delete("/stress/disk/cleanup")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "cleaned"
    assert "files_removed" in body


# ── Chaos: slow / error ───────────────────────────────────────────────────────

def test_slow_returns_ok():
    r = client.get("/slow?delay=100")  # 100 ms minimum
    assert r.status_code == 200
    assert r.json()["delayed_ms"] == 100


def test_slow_delay_bounds_enforced():
    r = client.get("/slow?delay=0")
    assert r.status_code == 422


def test_error_rate_zero_always_succeeds():
    r = client.get("/error?rate=0")
    assert r.status_code == 200


def test_error_rate_hundred_always_fails():
    r = client.get("/error?rate=100")
    assert r.status_code == 500


def test_error_rate_out_of_range_rejected():
    r = client.get("/error?rate=101")
    assert r.status_code == 422


# ── Catch-all ─────────────────────────────────────────────────────────────────

def test_catch_all_returns_service_name():
    r = client.get("/unknown/path")
    assert r.status_code == 200
    assert r.json()["service"] == "inventory-service"
