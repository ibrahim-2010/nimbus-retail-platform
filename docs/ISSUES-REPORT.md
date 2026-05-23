# NimbusRetail EKS Deployment – Issues, Challenges & Solutions Report

**Project:** NimbusRetail Cloud-Native Microservices Platform  
**Stack:** AWS EKS 1.31 · Terraform · Helm · ArgoCD · Jenkins · Strimzi Kafka · ESO · Kyverno  
**Date:** May 2026  

---

## Issue 1 – Only 2 Jenkins Jobs Instead of 6

**Symptom:**  
After running `setup-jcasc.sh`, Jenkins showed only 2 jobs (`nimbus-auth-service`, `nimbus-infrastructure`) instead of the expected 6 (5 service pipelines + infrastructure).

**Root Cause:**  
`tools-install.sh` embedded a full JCasC config inline as a heredoc and wrote it to `/var/lib/jenkins/casc_configs/jenkins.yaml` at EC2 provisioning time. This inline copy only defined 2 jobs and was never kept in sync with `jcasc/jenkins.yaml` – the authoritative file in the repo that had all 6 jobs. Any time `jcasc/jenkins.yaml` was updated, `tools-install.sh` had to be manually updated too, and it wasn't.

**Temporary Fix (applied to running server):**  
SCP'd the correct `jcasc/jenkins.yaml` to the server and restarted Jenkins:

```bash
scp -i test.pem jcasc/jenkins.yaml ubuntu@<jenkins-ip>:/tmp/jenkins-fix.yaml
ssh ubuntu@<jenkins-ip> "sudo cp /tmp/jenkins-fix.yaml /var/lib/jenkins/casc_configs/jenkins.yaml"
sudo systemctl restart jenkins
```

**Permanent Fix:**  
Removed the 99-line inline JCasC heredoc from `tools-install.sh` entirely. Replaced with a `wget` that downloads `jcasc/jenkins.yaml` from GitHub at EC2 boot time:

```bash
wget -q -O /tmp/jenkins-casc.yaml \
  "https://raw.githubusercontent.com/ibrahim-2010/nimbus-retail-platform/main/Jenkins-Server-TF/jcasc/jenkins.yaml" \
  || { echo "ERROR: Could not download jenkins.yaml from GitHub"; exit 1; }
```

`jcasc/jenkins.yaml` is now the single source of truth. Future job changes only require editing that one file.

**Files Changed:** `Jenkins-Server-TF/tools-install.sh`

---

## Issue 2 – Kubernetes Provider Connecting to localhost:80

**Symptom:**  
Terraform Apply failed with `connection refused` – the Kubernetes/Helm provider was connecting to `localhost:80` instead of the EKS cluster endpoint.

**Root Cause:**  
Terraform evaluates provider configuration before resources exist. `aws_eks_cluster.main.endpoint` is empty until the cluster is created, so the provider defaulted to `localhost`.

**Fix:**  
Split Terraform apply into two stages in `Jenkinsfile-Infrastructure`:

- **Stage 1:** Deploy NAT gateway + private routes + EKS cluster + node group via `-target`
- **Stage 2:** Full apply once EKS endpoint is resolvable

```groovy
sh '''
    terraform apply \
      -target=aws_nat_gateway.main \
      -target=aws_route_table.private \
      -target=aws_route_table_association.private \
      -target=aws_eks_cluster.main \
      -target=aws_eks_node_group.main \
      -var-file="nimbus.tfvars" \
      -auto-approve
'''
// then
sh 'terraform apply -var-file="nimbus.tfvars" -auto-approve'
```

> Note: NAT gateway and private route tables were added to Stage 1 targets after Issue 15 – nodes need outbound internet access to bootstrap. See Issue 15.

**Files Changed:** `Jenkins-Pipeline-Code/Jenkinsfile-Infrastructure`

---

## Issue 3 – AccessDenied for RDS and ElastiCache

**Symptom:**  
Infrastructure pipeline failed with `elasticache:CreateCacheSubnetGroup` and `rds:CreateDBSubnetGroup` AccessDenied errors.

**Root Cause:**  
Jenkins IAM role had no RDS or ElastiCache permissions. The AWS managed policy limit (10 policies per role) was already reached, so attaching new managed policies was blocked.

**Fix:**  
Added an inline policy (bypasses the 10-policy limit) to the Jenkins IAM role in Terraform:

```hcl
resource "aws_iam_role_policy" "nimbus_infra_access" {
  name = "NimbusInfraAccess"
  role = aws_iam_role.jenkins_role.name
  policy = jsonencode({
    Statement = [{ Effect = "Allow", Action = ["rds:*", "elasticache:*"], Resource = "*" }]
  })
}
```

**Files Changed:** `Jenkins-Server-TF/main.tf`

---

## Issue 4 – Wrong Cluster Name (cloud-native-cluster vs nimbus-cluster)

**Symptom:**  
Terraform created a cluster named `cloud-native-cluster` instead of `nimbus-cluster`, causing all subsequent `kubectl` and ArgoCD operations to fail.

**Root Cause:**  
`*.tfvars` was in `.gitignore`, so `nimbus.tfvars` was never pushed to GitHub. Jenkins cloned the repo without it, and Terraform used the default variable value `cloud-native-cluster`.

**Fix:**  
Added an explicit exception to `.gitignore`:

```
!EKS-Terraform/nimbus.tfvars
```

**Files Changed:** `.gitignore`

---

## Issue 5 – ESO Error: namespace "nimbus" Not Found

**Symptom:**  
External Secrets Operator failed to create SecretStores because the `nimbus` namespace did not exist at deploy time.

**Root Cause:**  
`namespaces.tf` only created `three-tier`, `monitoring`, and `argocd` namespaces. The `nimbus` namespace was supposed to be created by ArgoCD, which hadn't run yet when ESO deployed.

**Fix:**  
Added `kubernetes_namespace.nimbus` to `namespaces.tf` and added it to ESO's `depends_on`:

```hcl
resource "kubernetes_namespace" "nimbus" {
  metadata { name = "nimbus" }
}
```

**Files Changed:** `EKS-Terraform/namespaces.tf`, `EKS-Terraform/helm-eso.tf`

---

## Issue 6 – Kyverno ALB Webhook Errors (6 Errors)

**Symptom:**  
Kyverno installation failed with 6 webhook admission errors during Helm install.

**Root Cause:**  
Kyverno creates Service resources during installation, which triggered the ALB mutating webhook. The ALB controller pod was not yet ready to respond to webhook calls.

**Fix:**  
Added `depends_on = [helm_release.alb_controller]` to Kyverno's Helm release so it waits for ALB controller to be fully ready:

**Files Changed:** `EKS-Terraform/helm-kyverno.tf`

---

## Issue 7 – nimbus-security ArgoCD App OutOfSync

**Symptom:**  
ArgoCD showed `nimbus-security` as OutOfSync/Missing. `ExternalSecret` and `SecretStore` resources failed to apply.

**Root Cause:**  
`external-secrets.yaml` used `apiVersion: external-secrets.io/v1beta1`, but the installed ESO version only supports `v1`.

**Fix:**  
Updated all 3 resources in `external-secrets.yaml`:

```yaml
# Before
apiVersion: external-secrets.io/v1beta1
# After
apiVersion: external-secrets.io/v1
```

**Files Changed:** `Kubernetes-Manifests-file/Security/external-secrets.yaml`

---

## Issue 8 – Kafka Brokers All Pending (PVCs Unbound)

**Symptom:**  
All 3 Kafka broker pods were stuck in `Pending` state. PVCs showed `STATUS: Pending` with `STORAGECLASS: <unset>`.

**Root Cause:**  
No StorageClass existed in the cluster. The EBS CSI driver was installed but no gp3 StorageClass was configured, so Kafka PVCs could not be bound.

**Fix:**  
Created a `gp3` StorageClass in Terraform and set it as the cluster default:

```hcl
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner = "ebs.csi.aws.com"
  parameters          = { type = "gp3", encrypted = "true" }
}
```

Also added `class: gp3` to `kafka-cluster.yaml`.

**Files Changed:** `EKS-Terraform/ebs-csi.tf`, `Kubernetes-Manifests-file/Kafka/kafka-cluster.yaml`

---

## Issue 9 – Services 0/1 Running (RDS SSL Errors)

**Symptom:**  
Auth, cart, and order services were `0/1 Running`. Readiness probe returning 503. Service logs showed:

```
no pg_hba.conf entry for host, no encryption
```

Then after SSL fix:

```
self-signed certificate in certificate chain
```

**Root Cause:**  
- RDS enforces SSL by default – Node.js `pg` module doesn't use SSL unless told to.
- After adding `?sslmode=require`, Node.js rejected the RDS self-signed certificate.

**Fix (Step 1):** Updated `DATABASE_URL` in Secrets Manager to include `?sslmode=require`.  
**Fix (Step 2):** Added `NODE_TLS_REJECT_UNAUTHORIZED: "0"` to all three service Helm values files.

**Files Changed:**  
`helm/nimbus-service/values-auth.yaml`  
`helm/nimbus-service/values-cart.yaml`  
`helm/nimbus-service/values-order.yaml`  
`Jenkins-Pipeline-Code/Jenkinsfile-Infrastructure` (DATABASE_URL now includes `?sslmode=require` permanently)

---

## Issue 10 – Grafana CrashLoopBackOff

**Symptom:**  
Grafana pod (2/3) was in `CrashLoopBackOff`. Logs showed:

```
Only one datasource per organization can be marked as default
```

**Root Cause:**  
`kube-prometheus-stack` marks Prometheus as `isDefault: true` by default. The additional Loki and Tempo datasources conflicted.

**Fix:**  
Added `sidecar.datasources.isDefaultDatasource: false` to `helm-monitoring.tf`:

```hcl
sidecar = {
  datasources = {
    isDefaultDatasource = false
  }
}
```

**Files Changed:** `EKS-Terraform/helm-monitoring.tf`

---

## Issue 11 – ExternalDNS Conflict Between Two Ingresses

**Symptom:**  
`platinum-consults.com` kept pointing to the old three-tier ALB instead of the NimbusRetail ALB. ExternalDNS was upserting the wrong ALB every 60 seconds.

**Root Cause:**  
Both the three-tier ingress and the nimbus ingress claimed `platinum-consults.com` – the three-tier ingress had it in both the `external-dns` annotation AND `spec.rules[].host`. ExternalDNS read the host from the spec even after the annotation was removed.

**Fix:**  
Removed `host: platinum-consults.com` from the three-tier ingress spec in Git so ArgoCD would apply the change and ExternalDNS would stop claiming the hostname:

**Files Changed:** `Kubernetes-Manifests-file/ingress.yaml`

---

## Issue 12 – ALB 503 on All API Calls

**Symptom:**  
All API calls from the NimbusRetail frontend returned `503 Service Temporarily Unavailable`.

**Root Cause:**  
The ALB health check path was set to `/` (the nginx default), but backend microservices don't expose a `/` endpoint – only `/healthz`, `/readyz`, and `/metrics`. ALB marked all backend target groups as unhealthy.

**Fix:**  
Changed health check path to `/healthz` and added a custom nginx config to the frontend that responds 200 to `/healthz`:

```yaml
alb.ingress.kubernetes.io/healthcheck-path: /healthz
```

```nginx
location /healthz {
  return 200 'ok';
  add_header Content-Type text/plain;
}
```

**Files Changed:**  
`Kubernetes-Manifests-file/Nimbus-Frontend/ingress.yaml`  
`Kubernetes-Manifests-file/Nimbus-Frontend/deployment.yaml`

---

## Issue 13 – Database Schemas Not Initialized on RDS

**Symptom:**  
Auth service returned `{"error":"internal error"}` on register. Logs showed:

```
relation "auth.users" does not exist
```

**Root Cause:**  
The `scripts/init-db.sql` in the app repo only runs automatically via Docker's `docker-entrypoint-initdb.d` mechanism in docker-compose. There was no equivalent step for EKS – the RDS database existed but had no schemas or tables.

**Fix:**  
Ran a one-time Kubernetes Job using the `nimbus-secrets` DATABASE_URL to execute the init SQL against RDS:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-init
  namespace: nimbus
spec:
  template:
    spec:
      containers:
      - name: psql
        image: postgres:16-alpine
        command: ["sh", "-c"]
        args: ["psql $DATABASE_URL -c 'CREATE SCHEMA IF NOT EXISTS auth' ..."]
        envFrom:
        - secretRef:
            name: nimbus-secrets
```

**Lesson:** Database initialization must be an explicit step in the infrastructure pipeline for EKS deployments. Added to Jenkinsfile-Infrastructure as a permanent fix.

---

## Issue 14 – Kyverno Blocked Kubernetes Job (No Resource Limits)

**Symptom:**  
```
admission webhook "validate.kyverno.svc-fail" denied the request:
require-resource-limits: CPU and memory limits are required
```

**Root Cause:**  
Kyverno policy `require-resource-limits` enforces that all containers in the `nimbus` namespace must declare resource limits. The db-init Job had no `resources` block.

**Fix:**  
Added resource requests and limits to the Job container:

```yaml
resources:
  requests:
    memory: "64Mi"
    cpu: "50m"
  limits:
    memory: "128Mi"
    cpu: "100m"
```

---

## Issue 15 – EKS Nodes Failed to Join Cluster (NodeCreationFailure)

**Symptom:**  
Terraform Apply – EKS Cluster stage failed after ~44 minutes with:

```
Error: waiting for EKS Node Group (nimbus-cluster:worker-nodes) create:
unexpected state 'CREATE_FAILED', wanted target 'ACTIVE'.
last error: NodeCreationFailure: Instances failed to join the kubernetes cluster
```

Node console output showed `nodeadm` retrying `EC2/DescribeInstances` indefinitely – never completing bootstrap.

**Root Cause:**  
Stage 1 of the two-stage Terraform apply only targeted `aws_eks_cluster.main` and `aws_eks_node_group.main`. The NAT gateway and private subnet route tables were not yet created at that point. Nodes launched into private subnets with no outbound route – they could not reach AWS APIs to complete bootstrap.

**Fix:**  
Added the NAT gateway and private route table resources to the Stage 1 `-target` list so they exist before the node group is created:

```groovy
sh '''
    terraform apply \
      -target=aws_nat_gateway.main \
      -target=aws_route_table.private \
      -target=aws_route_table_association.private \
      -target=aws_eks_cluster.main \
      -target=aws_eks_node_group.main \
      -var-file="nimbus.tfvars" \
      -auto-approve
'''
```

**Files Changed:** `Jenkins-Pipeline-Code/Jenkinsfile-Infrastructure`

---

## Issue 16 – NodeCreationFailure (Second Occurrence) – NAT Gateway No Path to Internet

**Symptom:**  
Same as Issue 15 – nodes stuck in `NodeCreationFailure`, `nodeadm` retrying `EC2/DescribeInstances` indefinitely. Stage 1 now included NAT gateway and private route table targets, but the failure persisted.

**Root Cause:**  
The NAT gateway existed and the private route table correctly pointed `0.0.0.0/0 → NAT`. However, the **public route table** (`aws_route_table.public`) was not in the Stage 1 target list. The public subnets fell back to the VPC main route table which had no internet gateway route. Without `0.0.0.0/0 → IGW` on the public subnet, the NAT gateway itself had no path to the internet – traffic from private subnets reached the NAT, then went nowhere.

Confirmed by inspecting route tables: `rtb-06fb27588b632635f` (the nimbus VPC main table) had only a local route with no IGW entry.

**Fix:**  
Added `aws_route_table.public` and `aws_route_table_association.public` to Stage 1 targets, ensuring the full routing chain is in place before the node group is created:

```
Public subnet → aws_route_table.public (0.0.0.0/0 → IGW)
Private subnet → aws_route_table.private (0.0.0.0/0 → NAT)
NAT gateway → public subnet → IGW → internet
```

```groovy
sh '''
    terraform apply \
      -target=aws_route_table.public \
      -target=aws_route_table_association.public \
      -target=aws_nat_gateway.main \
      -target=aws_route_table.private \
      -target=aws_route_table_association.private \
      -target=aws_eks_cluster.main \
      -target=aws_eks_node_group.main \
      -var-file="nimbus.tfvars" \
      -auto-approve
'''
```

**Files Changed:** `Jenkins-Pipeline-Code/Jenkinsfile-Infrastructure`

---

## Issue 17 – Prometheus DNS Not Resolving After Redeploy

**Symptom:**  
`http://prometheus.platinum-consults.com/` was unreachable after a destroy/redeploy cycle. `nslookup` returned the name but no IP – the DNS record existed but resolved to a dead ALB.

**Root Cause:**  
Route 53 had an alias record for `prometheus.platinum-consults.com` pointing to the old ALB hostname (`k8s-monitoring-2e5cdba1f8-1817786535`) from the previous deployment. After destroy, that ALB no longer existed (NXDOMAIN). ExternalDNS could not auto-correct it because the required TXT ownership record (`heritage=external-dns,...`) was missing – ExternalDNS only updates records it owns, and without the TXT record it treated the alias as externally managed and left it alone.

**Temporary Fix (applied live):**  
Updated the Route 53 alias to the current live ALB via AWS Console.

**Permanent Fix:**  
Added two TXT ownership records to Route 53 so ExternalDNS takes ownership and auto-updates on every future deployment:

```
prometheus.platinum-consults.com.       TXT  "heritage=external-dns,external-dns/owner=nimbus-cluster,external-dns/resource=ingress/monitoring/prometheus-ingress"
cname-prometheus.platinum-consults.com. TXT  "heritage=external-dns,external-dns/owner=nimbus-cluster,external-dns/resource=ingress/monitoring/prometheus-ingress"
```

**Files Changed:** Route 53 (live -no Terraform file change required)

---

## Issue 18 – Tempo Datasource `i/o timeout` in Grafana

**Symptom:**  
Grafana showed Tempo datasource error:

```
Get "http://tempo:3100/api/echo": dial tcp 172.20.24.215:3100: i/o timeout
```

**Root Cause:**  
`helm-monitoring.tf` configured the Tempo datasource URL as `http://tempo:3100`. Port 3100 is Loki's port. Tempo exposes its HTTP query API on port **3200**. Port 3100 on the Tempo pod does not exist, so all connection attempts timed out.

**Fix:**  
Corrected the Tempo datasource URL to `http://tempo:3200` in `helm-monitoring.tf`. Patched the live Grafana ConfigMap via `kubectl` and restarted the Grafana deployment to apply immediately without waiting for a full Terraform redeploy.

```hcl
{
  name   = "Tempo"
  type   = "tempo"
  url    = "http://tempo:3200"   # was http://tempo:3100
  access = "proxy"
}
```

**Files Changed:** `EKS-Terraform/helm-monitoring.tf`

---

## Issue 19 – Loki "Unable to Connect" in Grafana (Grafana 13 + Loki 2.x Incompatibility)

**Symptom:**  
Grafana showed Loki datasource error: `Unable to connect with Loki. Please check the server logs for more details.`

Loki itself was healthy – `wget loki:3100/ready` returned `ready`, and logs from all 6 namespaces (argocd, kafka, kube-system, kyverno, monitoring, nimbus) were actively being ingested.

**Root Cause:**  
Grafana 13.0.1 changed its Loki health check to use a newer LogQL meta-query syntax. `loki-stack` chart v2.10.3 ships Loki 2.9.3, which cannot parse the new query. Grafana logs confirmed:

```
logger=tsdb.loki endpoint=checkHealth msg="Loki health check failed"
error="error from loki: parse error at line 1, col 1: syntax error: unexpected IDENTIFIER"
```

The `loki-stack` chart is deprecated and capped at Loki 2.9.x – it will never receive a fix for this.

**Fix:**  
Replaced the deprecated `loki-stack` chart with the new `loki` chart (Loki 3.6.7, singleBinary mode) plus a separate `promtail` chart. The entire `helm-loki.tf` was rewritten.

Key config decisions for singleBinary mode:
- `persistence.enabled = true` with `storageClass = "gp3"` -Loki 3.x requires a writable volume at `/var/loki`; first install attempt without persistence failed with `mkdir /var/loki: read-only file system`
- `read/write/backend replicas = 0` -required to disable distributed mode and use singleBinary exclusively
- `gateway.enabled = false` -not needed for single-node filesystem storage
- `monitoring.selfMonitoring.enabled = false` -avoids circular dependency on itself during install

Upgraded live on the cluster via Helm on Jenkins. Grafana health check now returns:

```json
{"message": "Data source successfully connected.", "status": "OK"}
```

**Files Changed:** `EKS-Terraform/helm-loki.tf`

---

## Summary Table

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | Only 2 of 6 Jenkins jobs | tools-install.sh had stale inline JCasC (2 jobs) | Removed inline JCasC from tools-install.sh; wget jcasc/jenkins.yaml at boot |
| 2 | Kubernetes provider → localhost | EKS endpoint empty at plan time | Two-stage Terraform apply |
| 3 | RDS/ElastiCache AccessDenied | Missing IAM permissions, policy limit hit | Inline IAM policy |
| 4 | Wrong cluster name | nimbus.tfvars gitignored | Added !nimbus.tfvars to .gitignore |
| 5 | ESO namespace not found | nimbus namespace created too late | Added namespace to Terraform |
| 6 | Kyverno webhook errors | ALB controller not ready | depends_on ALB controller |
| 7 | ExternalSecret v1beta1 error | Wrong API version | Changed to v1 |
| 8 | Kafka PVCs unbound | No StorageClass in cluster | Added gp3 StorageClass via EBS CSI |
| 9 | Services 0/1 (SSL errors) | RDS requires SSL, CA not trusted | sslmode=require + NODE_TLS_REJECT_UNAUTHORIZED=0 |
| 10 | Grafana CrashLoopBackOff | Multiple default datasources | isDefaultDatasource = false |
| 11 | ExternalDNS DNS conflict | Two ingresses claiming same host | Removed host from three-tier ingress spec |
| 12 | ALB 503 on API calls | Wrong health check path (/) | Changed to /healthz + nginx config |
| 13 | Database schemas missing | init-db.sql only runs in docker-compose | One-time Kubernetes Job against RDS |
| 14 | Kyverno blocked Job | Missing resource limits | Added requests/limits to Job spec |
| 15 | NodeCreationFailure – nodes can't join cluster (first fix) | NAT gateway + private routes not created before node group | Added NAT gateway + private route table targets to Stage 1 |
| 16 | NodeCreationFailure – nodes can't join cluster (second fix) | Public route table missing IGW route – NAT gateway had no path to internet | Added public route table + association targets to Stage 1 Terraform apply |
| 17 | Prometheus DNS not resolving after redeploy | Stale Route 53 alias pointing to dead ALB; ExternalDNS couldn't update it (missing TXT ownership record) | Updated Route 53 alias + added TXT ownership records |
| 18 | Tempo `i/o timeout` in Grafana | Datasource URL used port 3100 (Loki's port); Tempo HTTP API is on port 3200 | Corrected URL to http://tempo:3200 in helm-monitoring.tf |
| 19 | Loki "Unable to connect" in Grafana | Grafana 13 health check uses newer LogQL syntax incompatible with Loki 2.9.3 (loki-stack chart, deprecated) | Replaced loki-stack with loki 3.x (singleBinary) + promtail chart |
