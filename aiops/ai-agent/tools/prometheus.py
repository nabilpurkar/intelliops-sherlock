import os
import time
import logging
import requests
from langchain_core.tools import tool

log = logging.getLogger(__name__)
PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus.monitoring.svc.cluster.local:9090")


@tool
def query_prometheus(query: str, time_range: str = "5m") -> str:
    """
    Query Prometheus for current metric values.
    Use PromQL syntax. time_range sets the range vector window (e.g. '5m', '1h').
    Returns a JSON string with metric results.
    """
    try:
        # Wrap bare metric names in a range query if time_range is set
        full_query = query if "[" in query else f"{query}[{time_range}]" if time_range else query
        # Use instant query for point-in-time values
        resp = requests.get(
            f"{PROMETHEUS_URL}/api/v1/query",
            params={"query": query, "time": int(time.time())},
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json().get("data", {}).get("result", [])
        if not data:
            return f"No data returned for query: {query}"
        lines = []
        for series in data[:10]:  # cap at 10 series
            labels = series.get("metric", {})
            value  = series.get("value", [None, "N/A"])[1]
            lines.append(f"{labels}: {value}")
        return "\n".join(lines)
    except Exception as e:
        log.error("Prometheus query error: %s", e)
        return f"Error querying Prometheus: {e}"
