# NimbusRetail – Full Stack Deployment Guide

**Cluster:** nimbus-cluster | **Region:** us-east-1 | **Account:** 022374769206
**Total time:** ~45–55 min | **Cost while running:** ~$0.51/hr

---

## Deployment Overview

| Step | Where it runs | What it does |
|---|---|---|
| 0 – Push to GitHub | Local | All code must be on GitHub before anything deploys |
| 1 – Bootstrap | Local (Git Bash) | S3, DynamoDB, key pair |
| 2 – Jenkins server | Local (Git Bash) | Provision the Jenkins EC2 |
| 3 – Configure Jenkins | SSH into Jenkins EC2 | Inject credentials, create jobs |
| 4 – Infrastructure pipeline | Jenkins UI | **Everything else** – EKS, RDS, Redis, ArgoCD |
| 5 – Service builds | Jenkins UI | Build + push images, ArgoCD deploys pods |

Steps 0–3 are one-time local setup. Steps 4–5 run entirely from the Jenkins server.

---

## Cost while running

| Resource | Instance | ~$/hr |
|---|---|---|
| EKS control plane | – | $0.10 |
| 2× worker nodes | t3.xlarge | $0.33 |
| RDS PostgreSQL | db.t3.micro | $0.017 |
| ElastiCache Redis | cache.t3.micro | $0.017 |
| Jenkins EC2 | t3.medium | $0.042 |
| **Total** | | **~$0.51/hr** |

---

## Step 0 – Push Both Repos to GitHub

> ArgoCD watches the platform repo live. Nothing deploys until code is on GitHub.
> The Jenkins EC2 also downloads `setup-jcasc.sh` from GitHub on first boot.

```bash
# Platform repo
cd /c/Users/19122/nimbus-retail-platform
git add .
git commit -m "feat: NimbusRetail platform stack – phases 2-7 + infra pipeline"
git push origin main

# App repo
cd /c/Users/19122/Desktop/nimbus-retail-starter
git add .
git commit -m "feat: docker-compose fixes and documentation"
git push origin main
```

---

## Step 1 – Bootstrap (3 min, idempotent)

```bash
cd /c/Users/19122/nimbus-retail-platform
bash bootstrap.sh
```

Creates: S3 state bucket, DynamoDB lock table, EC2 key pair (`test.pem`). ECR repos are created by Terraform later.
Safe to skip if these already exist – the script checks before creating.

---

## Step 2 – Deploy the Jenkins Server (5 min)

```bash
cd /c/Users/19122/nimbus-retail-platform/Jenkins-Server-TF
terraform init
terraform plan
terraform apply
```

Get the IP:
```bash
terraform output jenkins_public_ip
terraform output ssh_command   # copy this for Step 3
```

Fix key permissions:
```bash
chmod 400 ../test.pem
```

---

## Step 3 – Configure Jenkins (5 min on EC2)

Wait ~5 min for the EC2 user-data (tools-install.sh) to finish installing
Jenkins, Docker, Terraform, kubectl, Helm, Trivy, and SonarQube.

Watch the progress:
```bash
ssh -i ../test.pem ubuntu@<JENKINS_IP>
sudo tail -f /var/log/tools-install.log
# Wait until you see "Installation Complete"
```

Then run the secret injection script:
```bash
sudo bash /opt/setup-jcasc.sh
```

After the script completes, **all future SSH sessions use the jenkins user directly** (no `sudo su` needed):
```bash
ssh -i ../test.pem jenkins@<JENKINS_IP>
```

Enter when prompted:

| Prompt | Value |
|---|---|
| GitHub Username | `ibrahim-2010` |
| GitHub PAT | your PAT with `repo` scope (read + write both repos) |
| AWS Account ID | `022374769206` |
| Jenkins Admin Password | choose a strong password – **write it down** |
| AWS Access Key ID | **press Enter** – instance role handles all permissions |

Script output confirms 6 jobs created and Jenkins is live. Exit the SSH session.

| URL | Credentials |
|---|---|
| `http://<JENKINS_IP>:8080` | admin / your chosen password |
| `http://<JENKINS_IP>:9000` | admin / SonarAdmin2026! |

---

## Step 4 – Run the Infrastructure Pipeline (~30 min)

Open Jenkins at `http://<JENKINS_IP>:8080`.

Navigate to **`nimbus-infrastructure`** → **Build Now**.

This single pipeline runs 7 stages automatically:

| Stage | What happens |
|---|---|
| Checkout | Clones platform repo from GitHub |
| Terraform Init | Downloads AWS/Kubernetes/Helm providers (~500 MB, first run only) |
| Terraform Apply – EKS Cluster | Creates EKS cluster + node group only (provider needs endpoint before k8s resources) |
| Terraform Apply – Full Stack | Creates RDS, Redis, Strimzi, ESO, Kyverno, Loki, Tempo, Prometheus/Grafana, ECR, IRSA (~20 min) |
| Configure kubectl | Updates `/var/lib/jenkins/.kube/config` – no manual copy needed |
| Populate Secrets Manager | Creates `nimbus-cluster/nimbus-secrets` and `nimbus-cluster/nimbus-catalog-secrets` with real RDS + Redis values (idempotent – skips if already exists) |
| Install ArgoCD | Installs ArgoCD, waits for it to be ready, prints admin password |
| Deploy App-of-Apps | `kubectl apply -f argocd/app-of-apps.yaml` – ArgoCD takes over from here |
| Initialize Database | Waits for ESO to sync `nimbus-secrets`, then runs a psql Job to create all schemas and seed catalog products against RDS (idempotent – uses IF NOT EXISTS) |

**When the pipeline finishes, the console output shows:**
- The ArgoCD admin password
- A list of all ArgoCD apps (syncing)
- A reminder to run the service builds

> **Kafka takes ~5 min** to elect a KRaft leader after ArgoCD syncs the Kafka app.
> All other apps sync in 2–3 min.

---

## Step 5 – Trigger Service Builds

Still in Jenkins, run each of these jobs once (**Build with Parameters** → **Build**):

| Job | Builds and deploys |
|---|---|
| `nimbus-auth-service` | auth-service |
| `nimbus-catalog-service` | catalog-service |
| `nimbus-cart-service` | cart-service |
| `nimbus-order-service` | order-service |
| `nimbus-notification-service` | notification-service |

Each build: SonarQube → Trivy → Docker build → ECR push → Helm values update → ArgoCD rollout.
All 5 can run in parallel – they are independent.

---

## Accessing the Platform

All URLs are live once the infrastructure pipeline completes and DNS propagates (~5 min).

| Service | URL | Credentials |
|---|---|---|
| **NimbusRetail Website** | `http://platinum-consults.com` | – |
| **Grafana** | `http://grafana.platinum-consults.com` | admin / (retrieve: `aws secretsmanager get-secret-value --secret-id nimbus-cluster/grafana/admin-password --query SecretString --output text`) |
| **Prometheus** | `http://prometheus.platinum-consults.com` | – |
| **ArgoCD** | `https://<argocd-lb>` (printed in pipeline output) | admin / (printed in pipeline) |
| **Jenkins** | `http://<JENKINS_IP>:8080` | admin / your chosen password |
| **SonarQube** | `http://<JENKINS_IP>:9000` | admin / SonarAdmin2026! |

> **ArgoCD URL:** The pipeline prints it at the end of the Install ArgoCD stage.
> You can also retrieve it any time:
> ```bash
> kubectl get svc argocd-server -n argocd
> # Copy the EXTERNAL-IP column value → https://<that-value>
> # Accept the self-signed certificate warning in the browser
> ```

> **DNS propagation:** `platinum-consults.com`, `grafana.platinum-consults.com`, and
> `prometheus.platinum-consults.com` are managed automatically by ExternalDNS.
> Allow 2–5 minutes after the pipeline finishes for DNS to resolve.

---

## Secret Management – No Hardcoded Credentials

### Why hardcoded passwords are a production risk

Early versions of this project had the Grafana admin password written directly in
`EKS-Terraform/helm-monitoring.tf`:

```hcl
# BEFORE – never do this in production
adminPassword = "CloudNative2026!"
```

This is a critical security problem for four reasons:

1. **Committed to git history** – the password is permanently visible in every clone,
   fork, and `git log` of the repository, even after the line is removed.
2. **Same password on every deployment** – every environment (dev, staging, prod) gets
   identical credentials. Compromising one environment compromises all of them.
3. **No rotation path** – changing the password requires a code change, a PR, a pipeline
   run, and a Helm upgrade. Under incident conditions this is too slow.
4. **Exposed in CI logs** – any Terraform plan or apply that prints values would leak the
   password into Jenkins console output, which may be accessible to anyone with Jenkins
   read access.

### How this project handles it

The Grafana password follows the same pattern as the RDS master password – generated
randomly by Terraform and stored in AWS Secrets Manager:

```hcl
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana_password" {
  name                    = "${var.cluster_name}/grafana/admin-password"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_password" {
  secret_id     = aws_secretsmanager_secret.grafana_password.id
  secret_string = random_password.grafana.result
}
```

The Helm release then references the Terraform resource directly – the password never
appears as a string in any file:

```hcl
adminPassword = random_password.grafana.result
```

### Secrets stored in AWS Secrets Manager

| Secret path | Contents | Created by |
|---|---|---|
| `nimbus-cluster/rds/master-password` | RDS PostgreSQL master password | Terraform (`rds.tf`) |
| `nimbus-cluster/grafana/admin-password` | Grafana admin password | Terraform (`helm-monitoring.tf`) |
| `nimbus-cluster/nimbus-secrets` | JWT_SECRET, DATABASE_URL, REDIS_URL (auth/cart/order) | Jenkins pipeline |
| `nimbus-cluster/nimbus-catalog-secrets` | DATABASE_URL, REDIS_URL (catalog, asyncpg format) | Jenkins pipeline |

### Retrieving the Grafana password

The infrastructure pipeline prints it automatically in the success banner. You can also
retrieve it any time:

```bash
aws secretsmanager get-secret-value \
  --secret-id nimbus-cluster/grafana/admin-password \
  --query SecretString \
  --output text \
  --region us-east-1
```

### Rotating the Grafana password

```bash
# Generate a new password and update Secrets Manager
NEW_PASS=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24)))")
aws secretsmanager put-secret-value \
  --secret-id nimbus-cluster/grafana/admin-password \
  --secret-string "$NEW_PASS" \
  --region us-east-1

# Apply the new value to the running Grafana instance
cd /c/Users/19122/nimbus-retail-platform/EKS-Terraform
terraform apply -var-file="nimbus.tfvars" -target=helm_release.monitoring -auto-approve
```

> **Note:** `terraform apply -target=helm_release.monitoring` will detect that
> `random_password.grafana.result` has not changed (it's stored in Terraform state),
> so the manual Secrets Manager update above is required for true rotation. For
> fully automated rotation, configure AWS Secrets Manager rotation with a Lambda
> and trigger a Helm upgrade from the rotation Lambda.

---

## Final Verification

Run these from your local machine after configuring kubectl:
```bash
aws eks update-kubeconfig --name nimbus-cluster --region us-east-1
```

```bash
kubectl get nodes                          # 2 nodes Ready
kubectl get pods -n nimbus                 # 5 services + frontend Running
kubectl get pods -n kafka                  # 3 nimbus-kafka-dual-role-* Running
kubectl get pods -n monitoring             # prometheus, grafana, loki, tempo Running
kubectl get applications -n argocd         # all Synced + Healthy
kubectl get externalsecrets -n nimbus      # READY=True, STATUS=SecretSynced
kubectl get networkpolicies -n nimbus      # 7 policies listed
kubectl get clusterpolicies                # 4 Kyverno policies listed

# Smoke test
kubectl exec -n nimbus deploy/auth-service -- wget -qO- http://localhost:3001/healthz
# Expected: {"status":"ok"}
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `nimbus-infrastructure` fails at Terraform Init | Provider download timeout | Re-run the job – transient network issue |
| `nimbus-infrastructure` fails at Terraform Apply | IAM permission issue | Check Jenkins EC2 instance role has all 8 policies |
| ArgoCD app stuck `OutOfSync` | Kyverno blocking | `kubectl get policyreport -n nimbus` |
| ESO `SecretSyncedError` | Secrets not in Secrets Manager | Check pipeline Populate Secrets Manager stage output |
| Pod `ImagePullBackOff` | Jenkins build not run yet | Trigger that service's build job |
| Pod crash – `secret not found` | ESO hasn't synced yet | `kubectl annotate externalsecret nimbus-secrets -n nimbus force-sync=$(date +%s) --overwrite` |
| Kafka pods pending | EBS volume not provisioned | `kubectl describe pod -n kafka` – check StorageClass |
| ArgoCD password not shown | Secret already rotated | `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' \| base64 -d` |
| Register returns `relation "auth.users" does not exist` | Database Initialize stage failed or was skipped | Re-run the db-init Job manually: `kubectl delete job db-init -n nimbus --ignore-not-found && kubectl apply -f <job-yaml>` |
| Services 0/1, logs show `no encryption` | DATABASE_URL missing `?sslmode=require` | Check `nimbus-cluster/nimbus-secrets` in Secrets Manager – URL must end with `/nimbus?sslmode=require` |

---

## Teardown (when done testing)

```bash
cd /c/Users/19122/nimbus-retail-platform
bash destroy.sh
```

Takes ~15 min. Runs 11 phases in dependency order. After it finishes:
```bash
aws eks list-clusters --region us-east-1                          # expect []
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId"                 # expect []
```

Delete S3 + DynamoDB only when done with the project permanently:
```bash
aws s3 rm s3://ibrahim-cloud-native-tf-state --recursive
aws s3api delete-bucket --bucket ibrahim-cloud-native-tf-state
aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region us-east-1
```

---

## Quick Reference

| What | Where |
|---|---|
| Jenkins UI | `http://<JENKINS_IP>:8080` |
| SonarQube UI | `http://<JENKINS_IP>:9000` (admin / SonarAdmin2026!) |
| NimbusRetail Website | `http://platinum-consults.com` |
| Grafana | `http://grafana.platinum-consults.com` (admin / (retrieve: `aws secretsmanager get-secret-value --secret-id nimbus-cluster/grafana/admin-password --query SecretString --output text`)) |
| Prometheus | `http://prometheus.platinum-consults.com` |
| ArgoCD | `https://$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')` |
| Infrastructure pipeline | `nimbus-infrastructure` job in Jenkins |
| Service pipelines | `nimbus-auth/catalog/cart/order/notification-service` |
| Platform repo | `C:\Users\19122\nimbus-retail-platform` |
| App repo | `C:\Users\19122\Desktop\nimbus-retail-starter` |
| Runbook | `nimbus-retail-platform/docs/RUNBOOK.md` |
| Full setup guide | `nimbus-retail-starter/docs/SETUP_GUIDE.md` |
