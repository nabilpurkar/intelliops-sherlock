"""
IntelliOps Sherlock — Locust Load Generator

User classes:
  NormalUser    — realistic e-commerce traffic (80% of users)
  ChaosUser     — triggers chaos endpoints to generate AIOps signals (20%)

Run modes:
  Web UI:   kubectl port-forward svc/locust 8089:8089 -n locust
  Headless: locust --headless -u 50 -r 5 --run-time 10m
"""
import random
from locust import HttpUser, task, between, tag
from locust.clients import HttpSession


ORDER_SERVICE_URL     = "http://order-service.apps.svc.cluster.local:8000"
PAYMENT_SERVICE_URL   = "http://payment-service.apps.svc.cluster.local:8002"
INVENTORY_SERVICE_URL = "http://inventory-service.apps.svc.cluster.local:8001"

ITEMS = [f"item-{i}" for i in range(1, 21)]
CUSTOMERS = [f"cust-{i}" for i in range(1, 101)]


class NormalUser(HttpUser):
    """Simulates real e-commerce traffic. 80% of virtual users."""
    wait_time = between(0.5, 2.0)
    weight = 4   # 4× weight vs ChaosUser → ~80% of traffic

    @task(5)
    @tag("normal", "orders")
    def create_order(self):
        self.client.post(
            "/orders",
            json={
                "item_id": random.choice(ITEMS),
                "quantity": random.randint(1, 5),
                "customer_id": random.choice(CUSTOMERS),
            },
            name="/orders [POST]",
        )

    @task(3)
    @tag("normal", "inventory")
    def check_inventory(self):
        item = random.choice(ITEMS)
        self.client.get(f"/inventory/check?item_id={item}", name="/inventory/check")

    @task(2)
    @tag("normal", "inventory")
    def get_item(self):
        item = random.choice(ITEMS)
        self.client.get(f"/inventory/{item}", name="/inventory/{item_id}")

    @task(1)
    @tag("normal", "payments")
    def process_payment(self):
        self.client.post(
            "/payments/process",
            json={"amount": round(random.uniform(10, 500), 2), "order_id": random.randint(1000, 9999)},
            name="/payments/process [POST]",
        )

    @task(1)
    @tag("normal", "orders")
    def get_order(self):
        order_id = random.randint(1000, 9999)
        self.client.get(f"/orders/{order_id}", name="/orders/{order_id}")

    @task(1)
    @tag("normal", "downstream")
    def distributed_call(self):
        """Generates a full multi-service distributed trace."""
        self.client.get("/downstream/call", name="/downstream/call")


class ChaosUser(HttpUser):
    """
    Triggers chaos endpoints to generate anomalies for AIOps pipeline.
    Use sparingly — these endpoints cause real alerts.
    Run with: locust --tags chaos --headless -u 5 -r 1 --run-time 5m

    self.client → order-service (host from ConfigMap/--host flag)
    _payment / _inventory → separate HttpSession instances for cross-service chaos
    """
    wait_time = between(3.0, 8.0)
    weight = 1   # 1× weight → ~20% of traffic

    def on_start(self):
        self._payment   = HttpSession(base_url=PAYMENT_SERVICE_URL,   request_event=self.environment.events.request, user=self)
        self._inventory = HttpSession(base_url=INVENTORY_SERVICE_URL,  request_event=self.environment.events.request, user=self)

    @task(3)
    @tag("chaos", "latency")
    def inject_slow_response(self):
        """Injects 1-3s latency on order-service — triggers P95 SLO alert."""
        delay = random.choice([1000, 1500, 2000, 3000])
        self.client.get(f"/slow?delay={delay}", name="/slow [chaos]", timeout=10)

    @task(2)
    @tag("chaos", "errors")
    def inject_errors(self):
        """Injects 20-60% error rate on order-service — burns error budget."""
        rate = random.choice([20, 30, 50, 60])
        self.client.get(f"/error?rate={rate}", name="/error [chaos]")

    @task(1)
    @tag("chaos", "cpu")
    def cpu_stress(self):
        """Spikes order-service CPU for 10s — triggers node CPU alert."""
        self.client.get("/stress/cpu?duration=10", name="/stress/cpu [chaos]", timeout=15)

    @task(1)
    @tag("chaos", "memory")
    def memory_leak(self):
        """Allocates 50MB on order-service — contributes to memory growth metric."""
        self.client.get("/stress/memory?mb=50", name="/stress/memory [chaos]")

    @task(1)
    @tag("chaos", "cascade")
    def downstream_timeout(self):
        """Forces downstream timeout on order-service — creates cascade failure trace."""
        self.client.get("/downstream/timeout", name="/downstream/timeout [chaos]")

    @task(1)
    @tag("chaos", "circuit")
    def open_circuit_breaker(self):
        """Opens payment-service circuit breaker for 30s — all payments return 503."""
        self._payment.post(
            "/chaos/circuit-open?duration=30",
            name="/chaos/circuit-open [chaos]",
        )

    @task(1)
    @tag("chaos", "inventory")
    def drain_stock(self):
        """Drains all inventory-service stock — triggers low-stock alert."""
        self._inventory.get("/chaos/stock-drain", name="/chaos/stock-drain [chaos]")
        # Auto-restore after short delay would normally be done externally
