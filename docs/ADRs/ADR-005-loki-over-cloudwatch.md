# ADR-005: Loki over AWS CloudWatch for Log Aggregation

**Status:** Accepted  
**Date:** 2026-05-20  
**Deciders:** Platform team  

---

## Context

The platform needs centralised log aggregation for the five Nimbus services. Options evaluated:

| Option | Description |
|---|---|
| A | AWS CloudWatch Logs – managed, native AWS |
| B | Grafana Loki + Promtail – open-source, runs in-cluster |
| C | Elasticsearch/OpenSearch – powerful, heavyweight |

Option C was ruled out early: OpenSearch requires a minimum of 1 GiB RAM per node, adds significant operational overhead, and is disproportionate for five services at demo scale. The decision is **A vs B**.

---

## Decision

**Option B** – Grafana Loki with Promtail as the log shipper.

---

## Honest Trade-off Analysis

### The case FOR CloudWatch (rejected option)

CloudWatch is the operationally honest default for AWS-hosted workloads. EKS control plane logs (API server, scheduler, controller manager), RDS logs, ALB access logs, and VPC flow logs all go to CloudWatch natively – they cannot be redirected to Loki. This means choosing Loki creates a **split logging story**: application logs in Loki, infrastructure logs in CloudWatch. An on-call engineer investigating a cluster incident must look in two places.

CloudWatch also provides Container Insights for EKS with no additional configuration – CPU, memory, and network metrics per pod, without running a separate DaemonSet. The Fluent Bit log router for CloudWatch is maintained by AWS and tested against every EKS release.

### Why we chose Loki instead

**Cost.** CloudWatch charges $0.50/GB ingested and $0.03/GB/month stored. Five verbose microservices running continuously generate several GB per day. For a capstone project, this cost accumulates quickly with no business justification.

**Single observability UI.** Loki integrates natively with Grafana as a datasource. An engineer can correlate a Prometheus metric spike with log lines from the same service in the same Grafana panel, using the same time window. With CloudWatch, logs require switching to the AWS console, breaking the single-pane-of-glass workflow.

**Zero application config.** Promtail runs as a DaemonSet and auto-discovers all pod logs via the node's filesystem. No per-service configuration, no SDK changes, no sidecar containers.

---

## Consequences

**Positive:**
- Zero additional AWS cost
- Correlated metrics + logs in a single Grafana dashboard
- Promtail auto-discovers all pod logs with no per-service config
- LogQL provides label-based filtering consistent with PromQL mental model

**Negative:**
- Infrastructure logs (EKS control plane, RDS, ALB) remain in CloudWatch – the split logging story is real and unavoidable
- Loki uses ephemeral storage in this deployment: logs are lost when the Loki pod restarts. This is a deliberate cost trade-off, not a design oversight
- Loki is a label-indexed store, not a full-text search engine. Complex queries over high-cardinality fields are significantly slower than Elasticsearch
- Promtail adds ~50 MiB memory per node; one more DaemonSet to maintain

**Acknowledged limitation:** A production deployment would enable `loki.persistence.enabled = true` with a gp3 EBS volume for 7-day retention, and would accept that some AWS infrastructure logs remain in CloudWatch as a permanent split. The cost and UI-consistency benefits still outweigh the split.
