# DNS Hostnames — infrastructurepath.online

All hostnames are managed automatically by ExternalDNS (Route53 zone: Z09505612LJLVLH4DJD2G).
Traffic flows: Route53 → ALB (ingress-kong-gateway) → Kong proxy → internal service.

| Hostname | Namespace | Service | Port |
|---|---|---|---|
| argocd.infrastructurepath.online | argocd | argocd-server | 80 |
| grafana.infrastructurepath.online | monitoring | kube-prometheus-stack-grafana | 80 |
| prometheus.infrastructurepath.online | monitoring | kube-prometheus-stack-prometheus | 9090 |
| alertmanager.infrastructurepath.online | monitoring | kube-prometheus-stack-alertmanager | 9093 |
| sonarqube.infrastructurepath.online | sonarqube | sonarqube-sonarqube | 9000 |
| locust.infrastructurepath.online | locust | locust | 8089 |
| apps.infrastructurepath.online/orders | apps | order-service | 8080 |
| apps.infrastructurepath.online/payments | apps | payment-service | 8080 |
| apps.infrastructurepath.online/inventory | apps | inventory-service | 8080 |
| kong-admin.infrastructurepath.online | kong | kong-kong-admin | 8001 |

## ACM Certificate
`arn:aws:acm:us-east-1:007066145518:certificate/8f1d859b-5bdf-420d-a286-2bf7ea3ec3ef`
Covers: `*.infrastructurepath.online`

## Architecture
```
Internet
  └─ Route53 (*.infrastructurepath.online → ALB)
       └─ ALB (ingress-kong-gateway, group: intelliops-alb)
            └─ Kong proxy (ClusterIP, namespace: kong)
                 ├─ argocd.infrastructurepath.online → argocd-server:80
                 ├─ grafana.infrastructurepath.online → kube-prometheus-stack-grafana:80
                 ├─ prometheus.infrastructurepath.online → kube-prometheus-stack-prometheus:9090
                 ├─ alertmanager.infrastructurepath.online → kube-prometheus-stack-alertmanager:9093
                 ├─ sonarqube.infrastructurepath.online → sonarqube-sonarqube:9000
                 ├─ locust.infrastructurepath.online → locust:8089
                 ├─ apps.infrastructurepath.online/orders → order-service:8080
                 ├─ apps.infrastructurepath.online/payments → payment-service:8080
                 ├─ apps.infrastructurepath.online/inventory → inventory-service:8080
                 └─ kong-admin.infrastructurepath.online → kong-kong-admin:8001
```
