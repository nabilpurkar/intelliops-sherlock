import os
import logging
import requests
from langchain_core.tools import tool

log = logging.getLogger(__name__)
ARGOCD_URL   = os.getenv("ARGOCD_URL", "http://argocd-server.argocd.svc.cluster.local")
ARGOCD_TOKEN = os.getenv("ARGOCD_AUTH_TOKEN", "")


def _headers() -> dict:
    return {"Authorization": f"Bearer {ARGOCD_TOKEN}", "Content-Type": "application/json"}


@tool
def rollback_argocd(app_name: str) -> str:
    """
    Roll back an ArgoCD Application to its previous healthy revision.
    Use when a recent deployment caused errors and the fix is to revert.
    app_name must match an ArgoCD Application name (e.g. 'microservices').
    """
    try:
        # Get current app state to find the previous revision
        resp = requests.get(
            f"{ARGOCD_URL}/api/v1/applications/{app_name}",
            headers=_headers(),
            timeout=10,
        )
        resp.raise_for_status()
        app     = resp.json()
        history = app.get("status", {}).get("history", [])

        if len(history) < 2:
            return f"ArgoCD app '{app_name}' has fewer than 2 history entries — cannot roll back"

        # The second-to-last entry is the previous deployment
        prev  = sorted(history, key=lambda h: h.get("deployedAt", ""))[-2]
        rev   = prev.get("revision", "")
        deployed_at = prev.get("deployedAt", "unknown")

        rollback_resp = requests.post(
            f"{ARGOCD_URL}/api/v1/applications/{app_name}/rollback",
            headers=_headers(),
            json={"id": prev.get("id", 0), "prune": True},
            timeout=30,
        )
        rollback_resp.raise_for_status()
        return (
            f"ArgoCD rollback triggered for '{app_name}' "
            f"→ revision {rev[:8] if rev else 'unknown'} (deployed {deployed_at})"
        )
    except Exception as e:
        log.error("rollback_argocd error: %s", e)
        return f"Error rolling back ArgoCD app '{app_name}': {e}"
