"""
Trains Facebook Prophet forecasting models on Prometheus metrics.
Saves one model per metric to /models/<metric>.pkl.
Designed to run as a Kubernetes CronJob every 6 hours.
"""
import os
import time
import logging
import joblib
import requests
import pandas as pd
from prophet import Prophet

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus.monitoring.svc.cluster.local:9090")
MODEL_DIR      = os.getenv("MODEL_DIR", "/models")

FORECAST_METRICS = {
    "cpu_usage":      'sum(rate(container_cpu_usage_seconds_total{namespace="apps"}[5m]))',
    "memory_bytes":   'sum(container_memory_working_set_bytes{namespace="apps"})',
    "request_rate":   'sum(rate(order_requests_total[5m])) + sum(rate(payment_requests_total[5m]))',
}


def query_range(query: str, lookback_hours: int = 48) -> pd.DataFrame:
    end   = int(time.time())
    start = end - lookback_hours * 3600
    resp  = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query_range",
        params={"query": query, "start": start, "end": end, "step": "300"},
        timeout=30,
    )
    resp.raise_for_status()
    results = resp.json().get("data", {}).get("result", [])
    if not results:
        log.warning("No data for: %s", query)
        return pd.DataFrame(columns=["ds", "y"])
    rows = [(pd.Timestamp(v[0], unit="s"), float(v[1])) for v in results[0]["values"]]
    df = pd.DataFrame(rows, columns=["ds", "y"])
    df["y"] = df["y"].clip(lower=0)
    return df


def train_metric(name: str, query: str):
    log.info("Training Prophet model for '%s'", name)
    df = query_range(query)
    if df.empty or len(df) < 10:
        log.warning("Insufficient data for '%s' — skipping", name)
        return

    model = Prophet(
        changepoint_prior_scale=0.05,
        seasonality_prior_scale=10,
        daily_seasonality=True,
        weekly_seasonality=False,
        interval_width=0.95,
    )
    model.fit(df)
    path = os.path.join(MODEL_DIR, f"{name}.pkl")
    joblib.dump(model, path)
    log.info("Saved %s → %s", name, path)


def train():
    os.makedirs(MODEL_DIR, exist_ok=True)
    for name, query in FORECAST_METRICS.items():
        try:
            train_metric(name, query)
        except Exception as e:
            log.error("Failed to train '%s': %s", name, e)


if __name__ == "__main__":
    train()
