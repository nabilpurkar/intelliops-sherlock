"""
Trains an Isolation Forest model on Prometheus metrics.
Saves the model to /models/anomaly_model.pkl.
Run once at startup or on a schedule via a Kubernetes Job.
"""
import os
import time
import logging
import joblib
import numpy as np
import requests
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus.monitoring.svc.cluster.local:9090")
MODEL_PATH = os.getenv("MODEL_PATH", "/models/anomaly_model.pkl")

METRICS = [
    'sum(rate(order_requests_total[5m]))',
    'sum(rate(order_errors_total[5m]))',
    'sum(order_memory_leak_bytes)',
    'sum(payment_circuit_breaker_open)',
    'sum(inventory_low_stock_items)',
]


def query_prometheus(query: str, lookback_hours: int = 24) -> list[float]:
    end = int(time.time())
    start = end - lookback_hours * 3600
    resp = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query_range",
        params={"query": query, "start": start, "end": end, "step": "60"},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    results = data.get("data", {}).get("result", [])
    if not results:
        log.warning("No data for query: %s", query)
        return []
    return [float(v[1]) for v in results[0].get("values", [])]


def collect_features(lookback_hours: int = 24) -> np.ndarray:
    series = []
    min_len = None
    for q in METRICS:
        try:
            vals = query_prometheus(q, lookback_hours)
            if not vals:
                vals = [0.0] * 100
            series.append(vals)
            if min_len is None or len(vals) < min_len:
                min_len = len(vals)
        except Exception as e:
            log.error("Failed to query '%s': %s", q, e)
            series.append([0.0] * 100)
            min_len = min(min_len or 100, 100)

    min_len = min_len or 100
    trimmed = [s[:min_len] for s in series]
    return np.array(trimmed).T  # shape: (timesteps, n_features)


def train():
    log.info("Collecting %d hours of Prometheus data...", 24)
    X = collect_features(lookback_hours=24)
    log.info("Feature matrix shape: %s", X.shape)

    pipeline = Pipeline([
        ("scaler", StandardScaler()),
        ("iforest", IsolationForest(
            n_estimators=100,
            contamination=0.05,
            random_state=42,
            n_jobs=-1,
        )),
    ])

    pipeline.fit(X)
    os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
    joblib.dump(pipeline, MODEL_PATH)
    log.info("Model saved to %s", MODEL_PATH)


if __name__ == "__main__":
    train()
