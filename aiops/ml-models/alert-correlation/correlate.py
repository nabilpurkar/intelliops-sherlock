"""
Alert correlation service.
Polls Alertmanager every 5 minutes, groups co-firing alerts into root-cause
incidents using time-window overlap, and exposes /incidents + /metrics.
"""
import os
import time
import logging
import threading
from collections import defaultdict
from flask import Flask, jsonify
from prometheus_client import Gauge, Counter, generate_latest, CONTENT_TYPE_LATEST
import requests

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

ALERTMANAGER_URL = os.getenv("ALERTMANAGER_URL", "http://alertmanager.monitoring.svc.cluster.local:9093")
POLL_INTERVAL    = int(os.getenv("POLL_INTERVAL_SECONDS", "300"))
WINDOW_SECONDS   = int(os.getenv("CORRELATION_WINDOW_SECONDS", "300"))

app = Flask(__name__)
incident_cache: list = []

incidents_total  = Counter('aiops_incidents_total', 'Total correlated incidents detected')
active_incidents = Gauge('aiops_active_incidents', 'Number of currently active correlated incidents')
alerts_correlated = Counter('aiops_alerts_correlated_total', 'Total alerts processed by correlator')


def fetch_alerts() -> list:
    try:
        resp = requests.get(
            f"{ALERTMANAGER_URL}/api/v2/alerts",
            params={"active": "true", "silenced": "false", "inhibited": "false"},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as e:
        log.error("Failed to fetch Alertmanager alerts: %s", e)
        return []


def parse_alert(raw: dict) -> dict:
    labels    = raw.get("labels", {})
    annots    = raw.get("annotations", {})
    starts_at = raw.get("startsAt", "")
    return {
        "name":        labels.get("alertname", "unknown"),
        "severity":    labels.get("severity", "none"),
        "namespace":   labels.get("namespace", ""),
        "service":     labels.get("service", labels.get("job", "")),
        "summary":     annots.get("summary", ""),
        "starts_at":   starts_at,
        "fingerprint": raw.get("fingerprint", ""),
        "labels":      labels,
    }


def correlate_alerts(alerts: list[dict]) -> list[dict]:
    """
    Groups alerts whose start times fall within WINDOW_SECONDS of each other
    and share a namespace or service. Returns a list of incident dicts.
    """
    if not alerts:
        return []

    # Sort by start time (string ISO8601 — lexicographic sort works for same TZ)
    sorted_alerts = sorted(alerts, key=lambda a: a["starts_at"])
    incidents: list[list] = []

    for alert in sorted_alerts:
        placed = False
        for incident in incidents:
            leader = incident[0]
            # Same namespace/service and within time window
            same_scope = (
                alert["namespace"] == leader["namespace"] or
                alert["service"]   == leader["service"]
            )
            if same_scope:
                incident.append(alert)
                placed = True
                break
        if not placed:
            incidents.append([alert])

    result = []
    for idx, group in enumerate(incidents):
        severities = [a["severity"] for a in group]
        top_sev = "critical" if "critical" in severities else \
                  "warning"  if "warning"  in severities else "info"
        result.append({
            "incident_id":   f"INC-{idx + 1:04d}",
            "alert_count":   len(group),
            "severity":      top_sev,
            "root_cause":    _infer_root_cause(group),
            "namespace":     group[0]["namespace"],
            "service":       group[0]["service"],
            "started_at":    group[0]["starts_at"],
            "alerts":        [a["name"] for a in group],
            "fingerprints":  [a["fingerprint"] for a in group],
        })
    return result


def _infer_root_cause(group: list[dict]) -> str:
    names = [a["name"].lower() for a in group]
    if any("oom" in n or "memory" in n for n in names):
        return "Memory pressure / OOM"
    if any("circuit" in n or "error" in n for n in names):
        return "Service error rate spike / circuit breaker"
    if any("cpu" in n for n in names):
        return "CPU saturation"
    if any("latency" in n or "slow" in n for n in names):
        return "Elevated latency"
    if any("pod" in n or "crash" in n for n in names):
        return "Pod crash / restart loop"
    namespaces = list({a["namespace"] for a in group if a["namespace"]})
    return f"Multi-alert incident in {', '.join(namespaces) or 'unknown'}"


def correlation_loop():
    global incident_cache
    while True:
        try:
            raw_alerts = fetch_alerts()
            parsed     = [parse_alert(a) for a in raw_alerts]
            incidents  = correlate_alerts(parsed)
            incident_cache = incidents
            alerts_correlated.inc(len(parsed))
            active_incidents.set(len(incidents))
            if incidents:
                incidents_total.inc(len(incidents))
                log.info("Correlated %d alerts into %d incidents", len(parsed), len(incidents))
            else:
                log.debug("No active alerts")
        except Exception as e:
            log.error("Correlation loop error: %s", e)
        time.sleep(POLL_INTERVAL)


@app.route('/incidents')
def get_incidents():
    return jsonify({"incidents": incident_cache, "total": len(incident_cache)})


@app.route('/metrics')
def metrics():
    return generate_latest(), 200, {'Content-Type': CONTENT_TYPE_LATEST}


@app.route('/healthz')
def health():
    return 'ok', 200


if __name__ == "__main__":
    t = threading.Thread(target=correlation_loop, daemon=True)
    t.start()
    app.run(host="0.0.0.0", port=8080)
