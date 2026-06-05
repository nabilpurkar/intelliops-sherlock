package main

import future.keywords.in

# Deny containers running as root (UID 0).
deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  container.securityContext.runAsUser == 0
  msg := sprintf("container '%s' must not run as root (runAsUser: 0)", [container.name])
}

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot
  msg := sprintf("Deployment '%s' must set spec.template.spec.securityContext.runAsNonRoot: true", [input.metadata.name])
}

# Deny missing readOnlyRootFilesystem.
deny[msg] {
  input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
  container := input.spec.template.spec.containers[_]
  not container.securityContext.readOnlyRootFilesystem
  msg := sprintf("container '%s' in '%s' must set securityContext.readOnlyRootFilesystem: true", [container.name, input.metadata.name])
}

# Deny allowPrivilegeEscalation not explicitly set to false.
deny[msg] {
  input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
  container := input.spec.template.spec.containers[_]
  container.securityContext.allowPrivilegeEscalation != false
  msg := sprintf("container '%s' in '%s' must set securityContext.allowPrivilegeEscalation: false", [container.name, input.metadata.name])
}

# Deny missing resource limits.
deny[msg] {
  input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf("container '%s' in '%s' must set resources.limits.memory", [container.name, input.metadata.name])
}

deny[msg] {
  input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf("container '%s' in '%s' must set resources.limits.cpu", [container.name, input.metadata.name])
}

# Deny images with :latest tag.
deny[msg] {
  input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("container '%s' in '%s' uses ':latest' tag — pin to a specific digest or version", [container.name, input.metadata.name])
}

# Deny missing liveness and readiness probes on Deployment containers.
warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.livenessProbe
  msg := sprintf("container '%s' in Deployment '%s' has no livenessProbe", [container.name, input.metadata.name])
}

warn[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.readinessProbe
  msg := sprintf("container '%s' in Deployment '%s' has no readinessProbe", [container.name, input.metadata.name])
}

# Deny Services of type NodePort (use ClusterIP + Kong ingress instead).
deny[msg] {
  input.kind == "Service"
  input.spec.type == "NodePort"
  msg := sprintf("Service '%s' uses NodePort — use ClusterIP with Kong ingress instead", [input.metadata.name])
}

# Deny hostPath volumes (escape risk).
deny[msg] {
  input.kind in {"Deployment", "StatefulSet", "DaemonSet"}
  volume := input.spec.template.spec.volumes[_]
  volume.hostPath
  msg := sprintf("workload '%s' mounts a hostPath volume '%s' — use PVC or emptyDir instead", [input.metadata.name, volume.name])
}
