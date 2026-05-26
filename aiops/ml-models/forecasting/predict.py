"""
Forecasting inference service.
Loads Prophet models and exposes /forecast/<metric> and /metrics endpoints.
Re-runs predictions every 5 minutes; publishes results as Prometheus gauges.
"""
import os
import time
import glob
import logging
import threading
import joblib
import pandas as pd
from flask import Flask, jsonify
from prometheus_client import Gauge, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

MODEL_DIR      = os.getenv("MODEL_DIR", "/models")
HORIZON_HOURS  = int(os.getenv("FORECAST_HORIZON_HOURS", "4"))

app = Flask(__name__)
forecast_cache: dict = {}
forecast_gauges: dict[str, Gauge] = {}


def load_models() -> dict:
    models = {}
    for path in glob.glob(os.path.join(MODEL_DIR, "*.pkl")):
        name = os.path.splitext(os.path.basename(path))[0]
        try:
            models[name] = joblib.load(path)
            log.info("Loaded model: %s", name)
        except Exception as e:
            log.error("Failed to load %s: %s", path, e)
    return models


def run_forecast(name: str, model) -> dict:
    future = model.make_future_dataframe(periods=HORIZON_HOURS * 12, freq="5min")
    forecast = model.predict(future)
    tail = forecast[["ds", "yhat", "yhat_lower", "yhat_upper"]].tail(HORIZON_HOURS * 12)
    result = {
        "metric": name,
        "horizon_hours": HORIZON_HOURS,
        "forecast": tail.to_dict(orient="records"),
        "next_value": float(tail["yhat"].iloc[0]),
        "peak_value": float(tail["yhat"].max()),
    }
    return result


def forecast_loop():
    while True:
        try:
            models = load_models()
            if not models:
                log.warning("No models found in %s — waiting...", MODEL_DIR)
                time.sleep(60)
                continue

            for name, model in models.items():
                try:
                    result = run_forecast(name, model)
                    forecast_cache[name] = result
                    if name not in forecast_gauges:
                        forecast_gauges[name] = Gauge(
                            f'aiops_forecast_{name.replace("-", "_")}',
                            f'Forecasted next value for {name}'
                        )
                    forecast_gauges[name].set(result["next_value"])
                    log.info("Forecast %s: next=%.3f peak=%.3f", name, result["next_value"], result["peak_value"])
                except Exception as e:
                    log.error("Forecast error for '%s': %s", name, e)
        except Exception as e:
            log.error("Forecast loop error: %s", e)

        time.sleep(300)


@app.route('/forecast/<metric>')
def get_forecast(metric: str):
    if metric not in forecast_cache:
        return jsonify({"error": f"No forecast for metric '{metric}'"}), 404
    return jsonify(forecast_cache[metric])


@app.route('/forecast')
def list_forecasts():
    return jsonify({"metrics": list(forecast_cache.keys())})


@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}


@app.route('/healthz')
def health():
    return 'ok', 200


if __name__ == "__main__":
    t = threading.Thread(target=forecast_loop, daemon=True)
    t.start()
    app.run(host="0.0.0.0", port=8080)
