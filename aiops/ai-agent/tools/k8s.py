import logging
from kubernetes import client, config
from langchain_core.tools import tool

log = logging.getLogger(__name__)

try:
    config.load_incluster_config()
except Exception:
    config.load_kube_config()

v1   = client.CoreV1Api()
apps = client.AppsV1Api()
hpa  = client.AutoscalingV1Api()


@tool
def restart_pod(namespace: str, pod_name: str) -> str:
    """
    Delete a pod so Kubernetes recreates it (rolling restart).
    Use when a pod is stuck, OOMKilled, or in a crash loop.
    """
    try:
        v1.delete_namespaced_pod(name=pod_name, namespace=namespace)
        return f"Pod {namespace}/{pod_name} deleted — Kubernetes will recreate it"
    except Exception as e:
        log.error("restart_pod error: %s", e)
        return f"Error restarting pod {namespace}/{pod_name}: {e}"


@tool
def scale_deployment(namespace: str, deployment_name: str, replicas: int) -> str:
    """
    Scale a Kubernetes Deployment to the specified replica count.
    Use to scale up under load or scale down a misbehaving deployment.
    replicas must be between 0 and 20.
    """
    if not 0 <= replicas <= 20:
        return "Error: replicas must be between 0 and 20"
    try:
        body = {"spec": {"replicas": replicas}}
        apps.patch_namespaced_deployment_scale(
            name=deployment_name, namespace=namespace, body=body
        )
        return f"Deployment {namespace}/{deployment_name} scaled to {replicas} replicas"
    except Exception as e:
        log.error("scale_deployment error: %s", e)
        return f"Error scaling {namespace}/{deployment_name}: {e}"


@tool
def get_events(namespace: str) -> str:
    """
    Get recent Kubernetes Warning events in a namespace.
    Useful for diagnosing pod scheduling failures, OOMKills, or probe failures.
    """
    try:
        events = v1.list_namespaced_event(
            namespace=namespace,
            field_selector="type=Warning",
        )
        if not events.items:
            return f"No Warning events in namespace {namespace}"
        lines = []
        for e in sorted(events.items, key=lambda x: x.last_timestamp or "", reverse=True)[:20]:
            lines.append(
                f"{e.last_timestamp} [{e.reason}] {e.involved_object.name}: {e.message}"
            )
        return "\n".join(lines)
    except Exception as e:
        log.error("get_events error: %s", e)
        return f"Error fetching events in {namespace}: {e}"


@tool
def get_pod_logs(namespace: str, pod_name: str, tail_lines: int = 100) -> str:
    """
    Fetch the last N log lines from a pod's main container.
    Use to investigate application errors before deciding on a remediation action.
    """
    try:
        logs = v1.read_namespaced_pod_log(
            name=pod_name,
            namespace=namespace,
            tail_lines=tail_lines,
            timestamps=True,
        )
        return logs or f"No logs from {namespace}/{pod_name}"
    except Exception as e:
        log.error("get_pod_logs error: %s", e)
        return f"Error fetching logs for {namespace}/{pod_name}: {e}"


@tool
def get_hpa_status(namespace: str) -> str:
    """
    Get HorizontalPodAutoscaler status for all HPAs in a namespace.
    Returns current/desired/min/max replicas and current CPU utilisation.
    """
    try:
        hpa_list = hpa.list_namespaced_horizontal_pod_autoscaler(namespace=namespace)
        if not hpa_list.items:
            return f"No HPAs found in namespace {namespace}"
        lines = []
        for h in hpa_list.items:
            spec   = h.spec
            status = h.status
            lines.append(
                f"{h.metadata.name}: current={status.current_replicas} "
                f"desired={status.desired_replicas} "
                f"min={spec.min_replicas} max={spec.max_replicas} "
                f"cpu%={status.current_cpu_utilization_percentage}"
            )
        return "\n".join(lines)
    except Exception as e:
        log.error("get_hpa_status error: %s", e)
        return f"Error fetching HPA status in {namespace}: {e}"
