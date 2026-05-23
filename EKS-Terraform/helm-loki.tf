# ──────────────────────────────────────────────
#  Loki 3.x — log aggregation (singleBinary mode)
#  Promtail runs as a DaemonSet and ships all
#  pod logs to Loki. Grafana (deployed by
#  kube-prometheus-stack) uses Loki as a datasource
#  via helm-monitoring.tf additionalDataSources.
#  Using the new `loki` chart (replaces deprecated
#  loki-stack) for Grafana 13 compatibility.
# ──────────────────────────────────────────────

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  namespace  = "monitoring"
  timeout    = 600
  wait       = false

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      commonConfig = {
        replication_factor = 1
      }
      storage = {
        type = "filesystem"
      }
      auth_enabled = false
      schemaConfig = {
        configs = [{
          from        = "2024-01-01"
          store       = "tsdb"
          object_store = "filesystem"
          schema      = "v13"
          index = {
            prefix = "index_"
            period = "24h"
          }
        }]
      }
    }
    singleBinary = {
      replicas = 1
      resources = {
        requests = { memory = "256Mi", cpu = "100m" }
        limits   = { memory = "512Mi", cpu = "500m" }
      }
      persistence = {
        enabled      = true
        size         = "10Gi"
        storageClass = "gp3"
      }
    }
    read    = { replicas = 0 }
    write   = { replicas = 0 }
    backend = { replicas = 0 }
    gateway = { enabled = false }
    monitoring = {
      selfMonitoring = { enabled = false }
      lokiCanary     = { enabled = false }
    }
    test = { enabled = false }
  })]

  depends_on = [helm_release.monitoring]
}

resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = "monitoring"
  timeout    = 300
  wait       = false

  values = [yamlencode({
    config = {
      clients = [{
        url = "http://loki:3100/loki/api/v1/push"
      }]
    }
    resources = {
      requests = { memory = "64Mi", cpu = "25m" }
      limits   = { memory = "128Mi", cpu = "100m" }
    }
  })]

  depends_on = [helm_release.loki]
}
