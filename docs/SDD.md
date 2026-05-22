# NimbusRetail – Solution Design Document

**Project:** NimbusRetail Platform on AWS EKS  
**Author:** Ibrahim Jinadu  
**AWS Account:** 022374769206  
**Region:** us-east-1  
**Status:** Complete (Phases 1–7)  

---

## 1. Executive Summary

NimbusRetail is a cloud-native e-commerce platform consisting of five microservices deployed on Amazon EKS. The platform team is responsible for taking developer-provided application code to production with the operational, observability, and security layers a real platform team would build around it.

The platform delivers:
- **Zero-downtime deployments** via ArgoCD GitOps with Helm rolling updates
- **Automated CI/CD** with Jenkins – build, scan, push to ECR, update Helm values
- **Full observability** – Prometheus metrics, Loki logs, Tempo traces, Grafana dashboards
- **Zero-trust networking** – Kubernetes NetworkPolicies with default-deny in the application namespace
- **Secret management** – External Secrets Operator pulling from AWS Secrets Manager via IRSA
- **Admission control** – Kyverno blocking privileged containers and enforcing resource limits

---

## 2. System Overview

### 2.1 Application Services

| Service | Language | Port | Responsibilities |
|---|---|---|---|
| auth-service | Node.js / Express | 3001 | User registration, login, JWT issuance |
| catalog-service | Python / FastAPI | 3002 | Product listing, inventory |
| cart-service | Node.js / Express | 3003 | User cart management |
| order-service | Node.js / Express | 3004 | Order creation, Kafka producer |
| notification-service | Node.js | 3005 | Kafka consumer, mock email dispatch |

### 2.2 Communication Patterns

**Synchronous (HTTP):**
```
ALB → auth-service       (register, login)
ALB → catalog-service    (browse products)
ALB → cart-service       (manage cart)
ALB → order-service      (place order)
order-service → cart-service  (fetch cart at checkout)
```

**Asynchronous (Kafka):**
```
auth-service  → users.registered  → notification-service
order-service → orders.created    → notification-service
```

---

## 3. AWS Architecture

### 3.1 Architecture Diagram

![NimbusRetail AWS Architecture](../assets/nimbus-architecture.png)

### 3.2 Infrastructure Summary

| Resource | Configuration | Purpose |
|---|---|---|
| VPC | 10.0.0.0/16, 2 AZs | Network isolation |
| EKS | v1.31, 2 × t3.xlarge | Application runtime |
| RDS PostgreSQL | 16.3, db.t3.micro | Persistent storage (all services) |
| ElastiCache Redis | 7.1, cache.t3.micro | Caching (catalog), sessions (cart) |
| Strimzi Kafka | 3-broker KRaft, 20 Gi/broker | Async event streaming |
| ECR | 5 repos, image scanning | Container registry |
| ALB | Internet-facing | HTTP ingress |
| Jenkins EC2 | t3.xlarge, 30 Gi EBS | CI/CD runtime |
| Secrets Manager | `nimbus-cluster/*` | Secret storage |

### 3.3 Network Topology

```
Internet
    │
    ▼ (port 80)
ALB (public subnets: 10.0.1.0/24, 10.0.2.0/24)
    │
    ▼ (target group – IP mode)
EKS Nodes (private subnets: 10.0.3.0/24, 10.0.4.0/24)
    │
    ├── nimbus namespace (app pods)
    ├── kafka namespace (Strimzi brokers)
    ├── monitoring namespace (Prometheus, Grafana, Loki, Tempo)
    ├── argocd namespace
    └── kyverno namespace
    │
    ├── RDS PostgreSQL (private subnet, port 5432)
    └── ElastiCache Redis (private subnet, port 6379)

Outbound (private subnets → internet):
    EKS Nodes → NAT Gateway (public subnet) → Internet Gateway → AWS APIs / ECR / GitHub
```

**Key isolation points:**
- RDS and Redis accept connections only from the EKS node security group
- Pods communicate within the cluster via NetworkPolicies (default-deny-all in `nimbus` namespace)
- The Jenkins EC2 is in a separate security group; SSH restricted to operator IP via `ssh_allowed_cidr`

---

## 4. Data Model

All five services share a single RDS PostgreSQL instance. Each service operates in its own schema, providing logical isolation without the cost of multiple database instances.

### 4.1 Schema Layout

```
PostgreSQL database: nimbus
├── schema: auth     → auth-service
├── schema: catalog  → catalog-service
├── schema: cart     → cart-service
└── schema: orders   → order-service
```

### 4.2 Table Definitions

**auth.users**
```sql
CREATE TABLE auth.users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,           -- bcrypt, cost factor 10
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**catalog.products**
```sql
CREATE TABLE catalog.products (
  id          TEXT PRIMARY KEY,          -- e.g. "prod-001"
  name        TEXT NOT NULL,
  description TEXT,
  price_cents INTEGER NOT NULL,          -- stored in cents to avoid float precision
  stock       INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**cart.carts**
```sql
CREATE TABLE cart.carts (
  user_id    UUID PRIMARY KEY,           -- one cart per user
  items      JSONB NOT NULL DEFAULT '[]', -- [{productId, quantity}]
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**orders.orders**
```sql
CREATE TABLE orders.orders (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL,
  items       JSONB NOT NULL,            -- snapshot of cart at checkout
  total_cents INTEGER NOT NULL,
  status      TEXT NOT NULL DEFAULT 'CREATED',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_user ON orders.orders(user_id);
```

### 4.3 Redis Data Structures

| Key pattern | Type | TTL | Owner | Purpose |
|---|---|---|---|---|
| `products:all` | String (JSON) | 60s | catalog-service | Cached product list |
| `session:<userId>` | String (JSON) | 24h | cart-service | User session state |

---

## 5. API Reference

All services expose `/healthz`, `/readyz`, and `/metrics` on their primary port. Business endpoints listed below.

### 5.1 auth-service (port 3001)

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/auth/register` | None | Create account. Body: `{email, password}`. Returns JWT. |
| POST | `/auth/login` | None | Authenticate. Body: `{email, password}`. Returns JWT. |
| GET | `/auth/me` | Bearer JWT | Return authenticated user profile. |

### 5.2 catalog-service (port 3002)

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/products` | None | List all products. Response cached in Redis (60s TTL). |
| GET | `/products/{id}` | None | Get single product by ID. |

### 5.3 cart-service (port 3003)

| Method | Path | Auth | Description |
|---|---|---|---|
| GET | `/cart` | Bearer JWT | Get current user's cart. |
| POST | `/cart/items` | Bearer JWT | Add item. Body: `{productId, quantity}`. |
| DELETE | `/cart/items/:productId` | Bearer JWT | Remove item from cart. |

### 5.4 order-service (port 3004)

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/orders` | Bearer JWT | Place order. Fetches cart from cart-service, writes to DB, publishes Kafka event. |
| GET | `/orders/:id` | Bearer JWT | Get order by ID. |

### 5.5 notification-service (port 3005)

No external HTTP endpoints. Consumes Kafka topics and logs mock email dispatch. Health and metrics endpoints only.

---

## 6. Kafka Event Schemas

Schemas are versioned and stored in `nimbus-retail-starter/schemas/`.

### 6.1 `users.registered` (v1)

Published by: auth-service on successful registration.  
Consumed by: notification-service → sends welcome email.

```json
{
  "schemaVersion": 1,
  "userId":        "<uuid>",
  "email":         "user@example.com",
  "createdAt":     "2026-05-22T15:00:00Z"
}
```

### 6.2 `orders.created` (v1)

Published by: order-service on successful order write.  
Consumed by: notification-service → sends order confirmation.

```json
{
  "schemaVersion": 1,
  "orderId":       "<uuid>",
  "userId":        "<uuid>",
  "email":         "user@example.com",
  "items":         [{ "productId": "prod-001", "quantity": 2 }],
  "totalCents":    25998,
  "createdAt":     "2026-05-22T15:00:00Z"
}
```

---

## 7. GitOps and CI/CD Pipeline

### 7.1 Repository Structure

| Repo | Contents | Audience |
|---|---|---|
| `nimbus-retail-starter` | 5 service source trees, docker-compose | Developers |
| `nimbus-retail-platform` | Terraform, Helm chart, ArgoCD apps, pipelines | Platform team |

### 7.2 CI Pipeline (Jenkins)

One parameterised `Jenkinsfile-Nimbus` handles all five services:

```
Cleanup → Checkout app repo → SonarQube analysis → Quality Gate
       → Trivy FS scan → Docker build → Trivy image scan
       → Push to ECR (:<BUILD_NUMBER> and :latest)
       → Clone platform repo → Update helm/nimbus-service/values-<name>.yaml
       → git push → ArgoCD detects → Helm sync → Rolling pod update
```

### 7.3 CD Flow (ArgoCD App-of-Apps)

```
argocd/app-of-apps.yaml          (applied once manually)
  └── argocd/apps/
        ├── nimbus-namespace.yaml
        ├── nimbus-kafka.yaml
        ├── nimbus-auth.yaml      ← helm/nimbus-service + values-auth.yaml
        ├── nimbus-catalog.yaml
        ├── nimbus-cart.yaml
        ├── nimbus-order.yaml
        ├── nimbus-notification.yaml
        ├── nimbus-monitoring.yaml
        └── nimbus-security.yaml
```

---

## 8. Helm Chart Design

A single chart (`helm/nimbus-service/`) serves all five services. Per-service `values-<name>.yaml` files override ports, image repositories, environment variables, and secret references. This avoids chart duplication while keeping each service independently configurable.

Key templates:
- `deployment.yaml` – supports `env` (plain) and `envFromSecrets` (secret refs)
- `service.yaml` – ClusterIP with named port `http` (required by ServiceMonitor)
- `hpa.yaml` – optional HPA (disabled for notification-service – Kafka consumer)

---

## 9. Observability

### 9.1 Metrics

All services expose `/metrics` in Prometheus format using `prom-client` (Node.js) and `prometheus-client` (Python). Prometheus scrapes them via `ServiceMonitor` CRs every 30 seconds.

Key metrics tracked: HTTP request rate, p95 latency, error rate (5xx), pod restarts.

### 9.2 Logs

Promtail runs as a DaemonSet on every node, tailing all container log files and shipping to Loki. No SDK changes required in the application services.

### 9.3 Traces

Tempo is deployed and ready to receive OTLP traces. Services require OpenTelemetry SDK instrumentation to emit spans – this is a future enhancement.

### 9.4 Alerts

Seven `PrometheusRule` alerts defined (`Kubernetes-Manifests-file/Monitoring/nimbus-alerts.yaml`):

| Alert | Condition | Severity |
|---|---|---|
| NimbusServiceDown | Service has 0 healthy pods | Critical |
| NimbusPodCrashLooping | Pod restarts > 5 in 15 min | Critical |
| NimbusHighErrorRate | 5xx rate > 5% for 5 min | Warning |
| NimbusHighLatency | p95 latency > 500ms for 10 min | Warning |
| NimbusHighCPU | CPU > 80% for 5 min | Warning |
| NimbusHighMemory | Memory > 85% for 5 min | Warning |
| NimbusKafkaConsumerLag | notification-service consumer lag rising | Warning |

---

## 10. Capacity Planning and Sizing

### 10.1 EKS Node Group

| Attribute | Value | Rationale |
|---|---|---|
| Instance type | t3.xlarge | 4 vCPU, 16 GiB RAM per node. Sufficient for 5 app services + 3 Kafka brokers + monitoring stack concurrently. t3.medium (4 GiB) was ruled out – Kafka brokers alone require ~512 MiB each. |
| Node count | 2 | Minimum for HA. A single node failure keeps all 2-replica services running on the surviving node. |
| Max pods per node | ~58 (AWS CNI default for t3.xlarge) | At peak: 10 app pods + 3 Kafka + ~15 monitoring + ~5 system = ~33 pods across 2 nodes. Well within limit. |

### 10.2 RDS PostgreSQL

| Attribute | Value | Rationale |
|---|---|---|
| Instance class | db.t3.micro | 1 vCPU, 1 GiB RAM. Appropriate for demo-scale read/write load from 5 services with low concurrent connections. |
| Storage | 20 GiB gp2 | Sufficient for seeded catalog + simulated order/user data. |
| Multi-AZ | Disabled | Cost decision. A single-AZ failure takes down the database. Acceptable for a lab environment; enable for production. |

### 10.3 ElastiCache Redis

| Attribute | Value | Rationale |
|---|---|---|
| Node type | cache.t3.micro | 0.5 GiB memory. Product list cache and session data are small (< 1 MB total at demo scale). |
| Cluster mode | Disabled (single node) | No replication. A Redis failure degrades catalog (no cache) and loses cart sessions, but services fall back to RDS. Acceptable for demo. |

### 10.4 Kafka (Strimzi)

| Attribute | Value | Rationale |
|---|---|---|
| Brokers | 3 | Minimum for fault tolerance. With replication factor 3, the cluster survives 1 broker failure without data loss. |
| Storage per broker | 20 Gi gp3 EBS | Demo-scale event volume. Each broker stores its partition replicas independently. |
| KRaft mode | Yes | No ZooKeeper dependency. Reduces operational complexity and resource footprint. |

---

## 11. Security

### 11.1 Network Security

| Layer | Mechanism |
|---|---|
| AWS perimeter | Security groups on RDS, ElastiCache (allow only EKS cluster SG) |
| Jenkins SSH | Restricted to operator IP via `var.ssh_allowed_cidr` in Terraform |
| Pod-to-pod | 7 NetworkPolicies – default-deny-all with explicit allows |
| External traffic | ALB security group + WAF (future) |

### 11.2 Identity and Secrets

| Concern | Solution |
|---|---|
| AWS API access for ESO | IRSA role scoped to `nimbus-cluster/*` in Secrets Manager |
| Application secrets | External Secrets Operator syncs from Secrets Manager into K8s Secrets |
| Image integrity | Trivy scans on every build (FS + image), ECR image scanning on push |

### 11.3 Admission Control (Kyverno)

| Policy | Mode | Rule |
|---|---|---|
| `disallow-privileged-containers` | Enforce | No privileged pods |
| `require-resource-limits` | Enforce | CPU + memory limits on all containers |
| `disallow-latest-tag` | Audit | Flag `:latest` image tags |
| `require-app-label` | Audit | All pods must carry `app` label |

### 11.4 Threat Model

| Threat | Blast Radius | Mitigation |
|---|---|---|
| Compromised pod | Limited to that service's IRSA permissions and outbound NetworkPolicy rules | IRSA scopes AWS access per service account; NetworkPolicies prevent lateral movement to other pods |
| Compromised Jenkins EC2 | Can push to platform repo, trigger builds, access AWS via Jenkins IAM role | Restrict SSH to known IP; rotate AWS credentials after incident; treat Jenkins IAM as a privileged role |
| Leaked Secrets Manager credentials | Read access to `nimbus-cluster/*` only | IRSA condition keys scope access; no credentials stored on disk |
| Container escape | Attacker reaches node OS | Kyverno blocks privileged containers and host network; reduces escalation surface |
| Public ALB exposure | HTTP endpoints reachable from internet | Only ALB is internet-facing; all services are ClusterIP; RDS and Redis have no public endpoint |

---

## 12. Failure Modes and Resilience

| Component | Failure | Immediate Impact | Recovery |
|---|---|---|---|
| Single EKS node | Node becomes unavailable | Pods rescheduled to surviving node (rolling restart takes ~60s) | Kubernetes reschedules automatically; 2-replica services maintain availability |
| RDS PostgreSQL | Instance unavailable | auth, cart, order services fail readiness probes and stop serving traffic; catalog degrades to cached responses | Manual failover or restore from automated backup; Multi-AZ would automate this |
| ElastiCache Redis | Instance unavailable | Cart sessions lost; catalog falls back to direct RDS queries (higher latency) | Redis restarts automatically; sessions require re-login |
| Single Kafka broker | Pod crash or node failure | No data loss (replication factor 3); Strimzi operator restarts the broker | Operator reconciles within ~2 minutes; in-flight messages may be replayed |
| All Kafka brokers | Complete Kafka outage | order-service cannot publish events; notification-service stops consuming | App services continue serving HTTP; notifications queue up on broker recovery |
| NAT Gateway | Single NAT fails | All private subnet nodes lose outbound internet access; ECR pulls fail, AWS API calls fail | Single NAT is a known limitation; redundant NAT gateways per AZ would mitigate |
| ArgoCD | ArgoCD pods crash | No new deployments; running pods unaffected | Cluster state frozen at last sync; restart ArgoCD pods to recover |
| Jenkins | EC2 unreachable | No CI builds; no new deployments | Reprovisioned via `Jenkins-Server-TF/terraform apply`; JCasC restores full config on boot |

---

## 13. Technology Decisions

| Decision | Choice | Alternative considered | Rationale |
|---|---|---|---|
| Kafka | Strimzi (in-cluster) | Amazon MSK | MSK ~$450/month minimum; Strimzi is free and CNCF-graduated |
| Helm strategy | Single shared chart | One chart per service | Less duplication; per-service values files provide full customisation |
| Secret management | ESO + Secrets Manager | Manual kubectl secrets | Automated rotation, no plaintext in Git, IRSA for auditability |
| Admission control | Kyverno | OPA/Gatekeeper | Kubernetes-native CRDs, simpler policy authoring |
| Log aggregation | Loki + Promtail | AWS CloudWatch | Cost: Loki is free; CloudWatch charges per GB ingested and stored |

Full rationale for each decision: see `docs/ADRs/`.

---

## 14. Known Limitations and Future Work

| Item | Detail |
|---|---|
| Tempo instrumentation | Services need OpenTelemetry SDK to emit traces |
| Kyverno audit policies | `disallow-latest-tag` and `require-app-label` are in audit mode – switch to enforce once all workloads comply |
| Single NAT Gateway | Cost optimisation; adds risk – a single-AZ failure takes down all outbound traffic from private subnets |
| RDS Multi-AZ | Disabled for cost; enable for production |
| TLS on Kafka | Strimzi uses PLAINTEXT – enable TLS in production |
| Alertmanager routing | Alerts fire to Alertmanager but no receiver (Slack/PagerDuty) is configured |
| Jenkins SSH exposure | SSH currently defaults to `0.0.0.0/0` unless `ssh_allowed_cidr` is set in `terraform.tfvars` before provisioning |
| No PR-gated deployments | Jenkins triggers on any push to main; a PR review gate before merging would add a human approval step |
