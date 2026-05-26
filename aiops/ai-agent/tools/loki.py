import os
import time
import logging
import requests
from langchain_core.tools import tool

log = logging.getLogger(__name__)
LOKI_URL = os.getenv("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")


@tool
def query_loki(query: str, time_range: str = "15m") -> str:
    """
    Query Loki for recent log lines.
    Use LogQL syntax, e.g. '{namespace="apps", app="order-service"} |= "ERROR"'.
    time_range sets how far back to look (e.g. '15m', '1h').
    Returns up to 50 recent log lines.
    """
    try:
        range_seconds = _parse_range(time_range)
        end_ns   = int(time.time() * 1e9)
        start_ns = int((time.time() - range_seconds) * 1e9)
        resp = requests.get(
            f"{LOKI_URL}/loki/api/v1/query_range",
            params={
                "query": query,
                "start": start_ns,
                "end":   end_ns,
                "limit": 50,
                "direction": "backward",
            },
            timeout=15,
        )
        resp.raise_for_status()
        streams = resp.json().get("data", {}).get("result", [])
        if not streams:
            return f"No logs found for query: {query}"
        lines = []
        for stream in streams:
            for ts, line in stream.get("values", []):
                lines.append(line)
        return "\n".join(lines[:50]) if lines else "No log lines returned"
    except Exception as e:
        log.error("Loki query error: %s", e)
        return f"Error querying Loki: {e}"


def _parse_range(r: str) -> int:
    """Convert '15m', '1h', '30s' to seconds."""
    if r.endswith("s"):
        return int(r[:-1])
    if r.endswith("m"):
        return int(r[:-1]) * 60
    if r.endswith("h"):
        return int(r[:-1]) * 3600
    return 900
