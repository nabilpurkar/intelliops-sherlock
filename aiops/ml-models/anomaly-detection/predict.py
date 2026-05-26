"""
Anomaly detection inference loop.
Every 60 seconds: fetches live Prometheus metrics, scores with Isolation Forest,
publishes anomalies to SQS intelliops-anomalies, and exposes /metrics.
"""
import os
import time
import json
import logging
import threading
import joblib
import numpy as np
import requests
import boto3
from flask import Flask
from prometheus_client import Gauge, Counter, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus.monitoring.svc.cluster.local:9090")
SQS_QUEUE_URL  = os.getenv("SQS_QUEUE_URL", "")
AWS_REGION     = os.getenv("AWS_DEFAULT_REGION", "us-east-1")
MODEL_PATH     = os.getenv("MODEL_PATH", "/models/anomaly_model.pkl")
POLL_INTERVAL  = int(os.getenv("POLL_INTERVAL_SECONDS", "60"))

METRICS_QUERIES = [
    ('order_request_rate',       'sum(rate(order_requests_total[5m]))'),
    ('order_error_rate',         'sum(rate(order_errors_total[5m]))'),
    ('order_memory_leak_bytes',  'sum(order_memory_leak_bytes)'),
    ('payment_cb_open',          'sum(payment_circuit_breaker_open)'),
    ('inventory_low_stock',      'sum(inventory_low_stock_items)'),
]

anomaly_score_gauge   = Gauge('aiops_anomaly_score', 'Latest Isolation Forest anomaly score')
anomaly_total_counter = Counter('aiops_anomalies_detected_total', 'Total anomaly events published to SQS')

app = Flask(__name__)


@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}


@app.route('/healthz')
def health():
    return 'ok', 200


def query_latest(query: str) -> float:
    try:
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query",
            params={"query": query},
            timeout=10,
        )
        resp.raise_for_status()
        result = resp.json().get("data", {}).get("result", [])
        return float(result[0]["value"][1]) if result else 0.0
    except Exception as e:
        log.warning("Prometheus query failed ('%s'): %s", query, e)
        return 0.0


def publish_anomaly(features: dict, score: float):
    if not SQS_QUEUE_URL:
        log.warning("SQS_QUEUE_URL not set — skipping publish")
        return
    sqs = boto3.client("sqs", region_name=AWS_REGION)
    payload = {
        "source": "anomaly-detector",
        "timestamp": int(time.time()),
        "anomaly_score": score,
        "features": features,
        "severity": "critical" if score < -0.3 else "warning",
    }
    sqs.send_message(QueueUrl=SQS_QUEUE_URL, MessageBody=json.dumps(payload))
    log.info("Anomaly published to SQS: score=%.3f", score)
    anomaly_total_counter.inc()


def load_model():
    for attempt in range(10):
        if os.path.exists(MODEL_PATH):
            return joblib.load(MODEL_PATH)
        log.info("Waiting for model at %s (attempt %d/10)...", MODEL_PATH, attempt + 1)
        time.sleep(30)
    raise RuntimeError(f"Model not found at {MODEL_PATH} after waiting")


def inference_loop():
    model = load_model()
    log.info("Model loaded — starting inference loop (interval=%ds)", POLL_INTERVAL)

    while True:
        try:
            features = {name: query_latest(q) for name, q in METRICS_QUERIES}
            X = np.array([[features[name] for name, _ in METRICS_QUERIES]])
            score = model.decision_function(X)[0]
            prediction = model.predict(X)[0]  # -1 = anomaly, 1 = normal
            anomaly_score_gauge.set(score)

            log.debug("Score=%.3f prediction=%d features=%s", score, prediction, features)

            if prediction == -1:
                log.warning("ANOMALY DETECTED score=%.3f features=%s", score, features)
                publish_anomaly(features, score)
        except Exception as e:
            log.error("Inference loop error: %s", e)

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    t = threading.Thread(target=inference_loop, daemon=True)
    t.start()
    app.run(host="0.0.0.0", port=8080)
