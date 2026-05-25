"""
AIOps Load Generator — Locust
Drives realistic + chaos traffic across all 3 services.

Run modes:
  locust --headless -u 50 -r 5 --run-time 10m   (CI / automated)
  locust                                           (web UI on :8089)
"""

import random
import time
import os
from locust import HttpUser, TaskSet, task, between, events
from locust.runners import MasterRunner, WorkerRunner


ORDER_SERVICE_URL     = os.getenv("ORDER_SERVICE_URL",     "http://order-service:8000")
PAYMENT_SERVICE_URL   = os.getenv("PAYMENT_SERVICE_URL",   "http://payment-service:8002")
INVENTORY_SERVICE_URL = os.getenv("INVENTORY_SERVICE_URL", "http://inventory-service:8001")

# ─────────────────────────────────────────────────────────────────────────────
# Realistic traffic tasks
# ─────────────────────────────────────────────────────────────────────────────
class OrderTasks(TaskSet):
    @task(5)
    def create_order(self):
        item_id  = f"item-{random.randint(1, 100):04d}"
        user_id  = f"user-{random.randint(1, 1000)}"
        quantity = random.randint(1, 10)
        self.client.post(
            f"{ORDER_SERVICE_URL}/orders",
            params={"item_id": item_id, "quantity": quantity, "user_id": user_id},
            name="/orders [POST]",
        )

    @task(3)
    def list_orders(self):
        self.client.get(f"{ORDER_SERVICE_URL}/orders", name="/orders [GET]")

    @task(2)
    def health_check(self):
        self.client.get(f"{ORDER_SERVICE_URL}/health", name="order /health")

    @task(1)
    def downstream_call(self):
        self.client.get(f"{ORDER_SERVICE_URL}/downstream/call", name="order /downstream/call")


class PaymentTasks(TaskSet):
    @task(4)
    def process_payment(self):
        amount = round(random.uniform(10.0, 5000.0), 2)
        self.client.post(
            f"{PAYMENT_SERVICE_URL}/payments",
            params={
                "order_id": f"ord-{random.randint(100000, 999999)}",
                "amount":   amount,
                "currency": random.choice(["USD", "EUR", "GBP", "INR"]),
                "user_id":  f"user-{random.randint(1, 1000)}",
            },
            name="/payments [POST]",
        )

    @task(2)
    def health_check(self):
        self.client.get(f"{PAYMENT_SERVICE_URL}/health", name="payment /health")


class InventoryTasks(TaskSet):
    @task(5)
    def list_inventory(self):
        self.client.get(
            f"{INVENTORY_SERVICE_URL}/inventory",
            params={"limit": random.randint(5, 20)},
            name="/inventory [GET]",
        )

    @task(3)
    def get_item(self):
        item_id = f"item-{random.randint(1, 100):04d}"
        self.client.get(f"{INVENTORY_SERVICE_URL}/inventory/{item_id}", name="/inventory/{id}")

    @task(2)
    def update_stock(self):
        item_id = f"item-{random.randint(1, 100):04d}"
        delta   = random.choice([-5, -3, -1, 1, 5, 10])
        self.client.put(
            f"{INVENTORY_SERVICE_URL}/inventory/{item_id}/stock",
            params={"delta": delta},
            name="/inventory/{id}/stock [PUT]",
        )

    @task(1)
    def low_stock_check(self):
        self.client.get(
            f"{INVENTORY_SERVICE_URL}/inventory",
            params={"low_stock_only": True},
            name="/inventory?low_stock_only=true",
        )


# ─────────────────────────────────────────────────────────────────────────────
# Chaos traffic tasks
# ─────────────────────────────────────────────────────────────────────────────
class ChaosTasks(TaskSet):
    """Low-weight chaos injector — fires occasionally to produce alert signals."""

    @task(3)
    def slow_order(self):
        delay = random.randint(1000, 5000)
        self.client.get(
            f"{ORDER_SERVICE_URL}/slow",
            params={"delay": delay},
            name="order /slow",
        )

    @task(2)
    def error_order(self):
        self.client.get(
            f"{ORDER_SERVICE_URL}/error",
            params={"rate": random.choice([25, 50, 75])},
            name="order /error",
        )

    @task(2)
    def slow_payment(self):
        delay = random.randint(2000, 8000)
        self.client.get(
            f"{PAYMENT_SERVICE_URL}/slow",
            params={"delay": delay},
            name="payment /slow",
        )

    @task(1)
    def cpu_stress_order(self):
        self.client.get(
            f"{ORDER_SERVICE_URL}/stress/cpu",
            params={"duration": random.randint(5, 15)},
            name="order /stress/cpu",
        )

    @task(1)
    def memory_leak_order(self):
        self.client.get(
            f"{ORDER_SERVICE_URL}/stress/memory",
            params={"mb": random.randint(10, 50)},
            name="order /stress/memory",
        )

    @task(2)
    def disk_write_stress(self):
        self.client.get(
            f"{INVENTORY_SERVICE_URL}/stress/disk/write",
            params={"files": random.randint(3, 20), "size_kb": random.randint(256, 1024)},
            name="inventory /stress/disk/write",
        )

    @task(1)
    def downstream_timeout(self):
        self.client.get(
            f"{ORDER_SERVICE_URL}/downstream/timeout",
            name="order /downstream/timeout",
        )

    @task(1)
    def retry_storm(self):
        self.client.get(
            f"{PAYMENT_SERVICE_URL}/chaos/retry-storm",
            params={"count": random.randint(10, 50)},
            name="payment /chaos/retry-storm",
        )


# ─────────────────────────────────────────────────────────────────────────────
# User classes
# ─────────────────────────────────────────────────────────────────────────────
class NormalUser(HttpUser):
    """Simulates a normal end user — mix of all three services."""
    wait_time = between(0.5, 2.0)
    weight    = 70  # 70% of virtual users

    tasks = {
        OrderTasks:     3,
        PaymentTasks:   2,
        InventoryTasks: 3,
    }

    # Locust requires a host; we override per-task above
    host = ORDER_SERVICE_URL


class ChaosUser(HttpUser):
    """Injects chaos signals — 30% of virtual users."""
    wait_time = between(2.0, 5.0)
    weight    = 30
    tasks     = [ChaosTasks]
    host      = ORDER_SERVICE_URL


# ─────────────────────────────────────────────────────────────────────────────
# Event hooks — log summary stats
# ─────────────────────────────────────────────────────────────────────────────
@events.request.add_listener
def on_request(request_type, name, response_time, response_length, exception, **kwargs):
    if exception:
        print(f"[CHAOS] FAIL  {name}  {response_time:.0f}ms  err={exception}")
    elif response_time > 3000:
        print(f"[LATENCY] SLOW {name}  {response_time:.0f}ms")
