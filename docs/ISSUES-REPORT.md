# NimbusRetail EKS Deployment – Issues, Challenges & Solutions Report

**Project:** NimbusRetail Cloud-Native Microservices Platform  
**Stack:** AWS EKS 1.31 · Terraform · Helm · ArgoCD · Jenkins · Strimzi Kafka · ESO · Kyverno  
**Date:** May 2026  

---

## Issue 1 – Only 2 Jenkins Jobs Instead of 8

**Symptom:**  
After running `setup-jcasc.sh`, Jenkins showed only 2 jobs (`three-tier-backend`, `three-tier-frontend`) instead of the expected 8.

**Root Cause:**  
`tools-install.sh` writes a minimal 2-job JCasC config during EC2 provisioning. `setup-jcasc.sh` never replaced it with the full 8-job config from the GitHub repo.

**Fix:**  
Added a `wget` step inside `setup-jcasc.sh` to download the full `jenkins.yaml` from GitHub before restarting Jenkins:

```bash
sudo wget -q -O /var/lib/jenkins/casc_configs/jenkins.yaml \
  "https://raw.githubusercontent.com/ibrahim-2010/nimbus-retail-platform/main/Jenkins-Server-TF/jcasc/jenkins.yaml"
sudo chown jenkins:jenkins /var/lib/jenkins/casc_configs/jenkins.yaml
```

**Files Changed:** `Jenkins-Server-TF/jcasc/setup-jcasc.sh`

---

## Issue 2 – Kubernetes Provider Connecting to localhost:80

**Symptom:**  
Terraform Apply failed with `connection refused` – the Kubernetes/Helm provider was connecting to `localhost:80` instead of the EKS cluster endpoint.

**Root Cause:**  
Terraform evaluates provider configuration before resources exist. `aws_eks_cluster.main.endpoint` is empty until the cluster is created, so the provider defaulted to `localhost`.

**Fix:**  
Split Terraform apply into two stages in `Jenkinsfile-Infrastructure`:

- **Stage 1:** Deploy only EKS cluster + node group via `-target`
- **Stage 2:** Full apply once EKS endpoint is resolvable

```groovy
sh 'terraform apply -target=aws_eks_cluster.main -target=aws_eks_node_group.main -auto-approve'
// then
sh 'terraform apply -auto-approve'
```

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

## Summary Table

| # | Issue | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | Only 2 Jenkins jobs | tools-install.sh overwrote JCasC | wget full jenkins.yaml in setup-jcasc.sh |
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
