# NimbusRetail – Full Stack Deployment Guide

**Cluster:** nimbus-cluster | **Region:** us-east-1 | **Account:** 022374769206  
**Total time:** ~45–55 min | **Cost while running:** ~$0.51/hr

---

## Deployment Overview

| Step | When | Where | What |
|---|---|---|---|
| 1 – Push repos to GitHub | One-time | Local | ArgoCD + JCasC pull from GitHub |
| 2 – Bootstrap | One-time | Local (Git Bash) | S3, DynamoDB, key pair, Route 53 zone |
| 3 – Update registrar nameservers | One-time (after Step 2) | Domain registrar | Point domain to Route 53 – never repeat |
| 4 – Deploy Jenkins server | Every deployment | Local (Git Bash) | Provision Jenkins EC2 with SSH IP lock |
| 5 – Configure Jenkins | Every deployment | SSH into Jenkins EC2 | Inject credentials, verify 7 jobs |
| 6 – Infrastructure pipeline | Every deployment | Jenkins UI | EKS, RDS, Redis, ArgoCD, all k8s apps |
| 7 – Service builds | Every deployment | Jenkins UI | Build + push 6 images, ArgoCD deploys |
| 7b – Operator-copilot build | Every deployment | SSH: Jenkins EC2 | Build image, push to ECR, create Anthropic secret |
| 8 – Verify | Every deployment | Local | Check pods, URLs, smoke test |

**Steps 1–3** are done once when you first set up the project.  
**Steps 4–8** run every time you spin up the stack.

---

## Cost While Running

| Resource | Instance | ~$/hr |
|---|---|---|
| EKS control plane | – | $0.10 |
| 2× worker nodes | t3.xlarge | $0.33 |
| RDS PostgreSQL | db.t3.micro | $0.017 |
| ElastiCache Redis | cache.t3.micro | $0.017 |
| Jenkins EC2 | t3.medium | $0.042 |
| **Total** | | **~$0.51/hr** |

---

## ONE-TIME SETUP

### Step 1 – Push Both Repos to GitHub

> ArgoCD watches the platform repo live – nothing deploys until code is on GitHub.  
> The Jenkins EC2 downloads `jcasc/jenkins.yaml` from GitHub on first boot.

```bash
# Platform repo
cd /c/Users/19122/nimbus-retail-platform
git add .
git commit -m "feat: platform stack"
git push origin main

# App repo
cd /c/Users/19122/Desktop/nimbus-retail-starter
git add .
git commit -m "feat: app stack"
git push origin main
```

**Success:** both `git push` commands exit 0, changes visible on GitHub.

---

### Step 2 – Bootstrap (3 min, idempotent)

```bash
cd /c/Users/19122/nimbus-retail-platform
bash bootstrap.sh
```

This creates:
- S3 state bucket (versioned + encrypted)
- DynamoDB lock table
- EC2 key pair (`test.pem`)
- Route 53 hosted zone for `platinum-consults.com`

**Success:** Script prints `BOOTSTRAP COMPLETE` and displays 4 Route 53 nameservers.

Safe to re-run at any time – every step checks before creating.

> **Where is test.pem?** It is saved in the repo root (`nimbus-retail-platform/test.pem`).
> Keep it secure – it cannot be re-downloaded. If you re-run bootstrap and the key already
> exists, the existing `.pem` file is used as-is.

---

### Step 3 – Update Registrar Nameservers (ONE TIME ONLY)

**Do this once after Step 2. The zone and its nameservers never change between deployments
– once set at your registrar, you never need to touch this again.**

Bootstrap printed 4 nameservers. Copy them and update your domain registrar:

1. Log in to wherever you registered `platinum-consults.com`
2. Find **Nameservers / DNS** settings
3. Replace all existing nameservers with the 4 from bootstrap output
4. Save – propagation takes 5–30 minutes

**Verify propagation before continuing:**
```bash
nslookup -type=NS platinum-consults.com 8.8.8.8
# Must show ns-XXXX.awsdns-XX.* – not your registrar's default nameservers
```

> If you already did this on a previous deployment, skip Step 3 entirely.
> The nameservers are the same every time because the zone is created in bootstrap,
> not by Terraform, so it survives teardown and redeployment.

---

## EVERY DEPLOYMENT

### Step 4 – Set SSH Restriction + Deploy Jenkins (5 min)

**Get your current public IP and lock all Jenkins ports to it:**

```bash
curl ifconfig.me
# Note the IP shown (e.g., 1.2.3.4)
```

```bash
cd /c/Users/19122/nimbus-retail-platform/Jenkins-Server-TF
echo 'ssh_allowed_cidr = "YOUR_IP/32"' > terraform.tfvars
# Replace YOUR_IP with the actual output of curl ifconfig.me above
```

Verify it looks correct:
```bash
cat terraform.tfvars
# Expected: ssh_allowed_cidr = "x.x.x.x/32"
```

> **Security:** `ssh_allowed_cidr` locks **all three ports** -SSH (22), Jenkins UI (8080), and
> SonarQube (9000) -to your IP only. Never leave 8080 or 9000 open to `0.0.0.0/0`. Exposed
> Jenkins instances are discovered and exploited within hours via the Groovy script console,
> causing AWS to issue an abuse report (`AWS_ABUSE_DOS_REPORT`) that can lead to account
> suspension. This was fixed in Terraform -the variable now controls all three ports.

**Deploy:**
```bash
terraform init
terraform plan
terraform apply
```

**Get connection details:**
```bash
terraform output jenkins_public_ip   # note this IP – used in Steps 5–7
terraform output ssh_command         # full ssh command – copy this
```

**Fix key permissions:**
```bash
chmod 400 ../test.pem
```

**Verify security group -confirm no port is open to 0.0.0.0/0:**
```bash
aws ec2 describe-security-groups --group-names jenkins-nimbus-sg --region us-east-1 \
  --query "SecurityGroups[0].IpPermissions[*].{Port:FromPort,CIDR:IpRanges[0].CidrIp}" \
  --output table
# Expected: all 3 rows show YOUR IP (/32) -never 0.0.0.0/0
```

**Success:** `terraform apply` exits 0, `jenkins_public_ip` shows a valid IP address, all ports show your IP in the security group check.

> **IP changed since last session?** Re-run `curl ifconfig.me`, update `terraform.tfvars`,
> then run `terraform apply` again to update the security group rule. Home IPs change.

---

### Step 5 – Configure Jenkins (10 min)

**SSH in as ubuntu and watch the install log:**
```bash
ssh -i ../test.pem ubuntu@<JENKINS_IP>
sudo tail -f /var/log/tools-install.log
```

Wait until you see:
```
Installation Complete
```

This installs Jenkins, Docker, Terraform, kubectl, Helm, Trivy, and SonarQube (~5 min).

**Run the credential injection script:**
```bash
sudo bash /opt/setup-jcasc.sh
```

Enter when prompted:

| Prompt | Value |
|---|---|
| GitHub Username | `ibrahim-2010` |
| GitHub PAT | your PAT with `repo` scope (read + write both repos) |
| AWS Account ID | `022374769206` |
| Jenkins Admin Password | choose a strong password – write it down |
| AWS Access Key ID | **press Enter** – instance role handles all permissions |

**Success check:** The script output ends with:
```
✅ 7 pipeline jobs (nimbus-infrastructure, 6x nimbus-*-service)
Jenkins is live at http://<JENKINS_IP>:8080
```

**Exit the SSH session:**
```bash
exit
```

Open Jenkins in a browser to verify 7 jobs are listed:
- `http://<JENKINS_IP>:8080` – login: `admin` / your chosen password

Verify all 7 jobs exist:
- `nimbus-infrastructure`
- `nimbus-auth-service`
- `nimbus-audit-service`
- `nimbus-catalog-service`
- `nimbus-cart-service`
- `nimbus-order-service`
- `nimbus-notification-service`

SonarQube is also available: `http://<JENKINS_IP>:9000` – login: `admin` / `SonarAdmin2026!`

> **Only 2 jobs instead of 7?** This means `tools-install.sh` ran with a stale cached image
> before the fix was applied. Re-run `setup-jcasc.sh` to reload JCasC from GitHub:
> `ssh -i ../test.pem jenkins@<JENKINS_IP>` → `sudo bash /opt/setup-jcasc.sh`

> **Future SSH sessions:** After setup-jcasc.sh completes, use the jenkins user:
> `ssh -i ../test.pem jenkins@<JENKINS_IP>`

---

### Step 6 – Run the Infrastructure Pipeline (~30 min)

Open Jenkins: `http://<JENKINS_IP>:8080`

Navigate to **`nimbus-infrastructure`** → **Build Now**

The pipeline runs these stages in sequence:

| Stage | ~Time | What happens |
|---|---|---|
| Checkout | 1 min | Clones platform repo from GitHub |
| Terraform Init | 2 min first run, 30s cached | Downloads AWS/Kubernetes/Helm providers |
| Terraform Apply – EKS Cluster | 15 min | Public subnets, NAT gateway, private subnets + route tables, EKS cluster, node group |
| Terraform Apply – Full Stack | 20 min | RDS, Redis, Strimzi Kafka, ESO, Kyverno, Loki, Tempo, Prometheus/Grafana, ECR, IRSA roles |
| Configure kubectl | 30s | Updates `/var/lib/jenkins/.kube/config` – no manual step needed |
| Populate Secrets Manager | 1 min | Creates `nimbus-cluster/nimbus-secrets` and `nimbus-cluster/nimbus-catalog-secrets` with real RDS + Redis endpoints |
| Install ArgoCD | 2 min | Installs ArgoCD, waits for it to be ready, **prints admin password** |
| Deploy App-of-Apps | 30s | `kubectl apply -f argocd/app-of-apps.yaml` – ArgoCD takes over from here |
| Initialize Database | 2 min | Runs psql Kubernetes Job to create all schemas and seed catalog products against RDS |

**At the end of the pipeline, look for in the console output:**
```
ArgoCD admin password: <copy this>
ArgoCD server URL:     <copy this>
Pipeline complete.
```

**After pipeline succeeds – verify ArgoCD sync from local machine:**
```bash
# Configure kubectl locally
aws eks update-kubeconfig --name nimbus-cluster --region us-east-1

# Check all 15 ArgoCD apps
kubectl get applications -n argocd
```

Expected output – all apps `Synced` + `Healthy`:
```
NAME                         SYNC STATUS   HEALTH STATUS
nimbus-app-of-apps           Synced        Healthy
nimbus-frontend              Synced        Healthy
nimbus-security              Synced        Healthy
nimbus-kafka                 Synced        Healthy
nimbus-monitoring            Synced        Healthy
nimbus-auth                  Synced        Healthy
nimbus-catalog               Synced        Healthy
nimbus-cart                  Synced        Healthy
nimbus-order                 Synced        Healthy
nimbus-notification          Synced        Healthy
nimbus-audit                 Synced        Healthy
nimbus-ollama                Synced        Healthy
nimbus-operator-copilot      Synced        Healthy
...
```

> **GPU apps (Ollama, operator-copilot):** Require the GPU node group to have `desiredSize >= 1`.
> If GPU nodes are scaled to 0, these apps will show `Degraded` — that is expected. Scale up before demos:
> ```bash
> aws eks update-nodegroup-config \
>   --cluster-name nimbus-cluster --nodegroup-name gpu-nodes \
>   --scaling-config minSize=0,maxSize=2,desiredSize=1 --region us-east-1
> ```

> **Kafka takes ~5 min** to elect a KRaft leader – it will show `Progressing` briefly,
> then become `Healthy`. All other apps sync in 2–3 min.

> **ArgoCD URL:** printed in pipeline output. Also retrieve anytime:
> ```bash
> kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
> ```
> Open at `https://<that-value>` – accept the self-signed certificate warning.

---

### Step 7 – Trigger Service Builds

Still in Jenkins – run each job once (**Build with Parameters → Build**):

| Job | Service built |
|---|---|
| `nimbus-auth-service` | auth-service |
| `nimbus-audit-service` | audit-service (minimal stub — see note below) |
| `nimbus-catalog-service` | catalog-service |
| `nimbus-cart-service` | cart-service |
| `nimbus-order-service` | order-service |
| `nimbus-notification-service` | notification-service |

All 6 can be triggered at the same time – they are independent.

Each build runs: SonarQube scan → Trivy image scan → Docker build → ECR push → Helm values update → ArgoCD rollout.

**Success:** All 6 jobs show blue (passing) in Jenkins.

In ArgoCD, all service apps show `Running 1/1` after the rollout completes.

> **audit-service note:** The image tagged `:1` was manually built and pushed directly to ECR
> (the `services/audit-service/` source is not yet in the app repo). The `nimbus-audit-service`
> Jenkins pipeline will fail at the SonarQube stage until real source code is added to
> `nimbus-retail-starter/services/audit-service/`. For demos, nimbus-audit is already Healthy
> because image `:1` is already in ECR — skip this job for now.

---

### Step 7b – Build Operator-Copilot (Manual)

operator-copilot is not in the Jenkins JCasC jobs — it requires a manual build because it needs your `ANTHROPIC_API_KEY` secret. Run these commands **on the Jenkins server** (SSH in as `jenkins` user first):

```bash
ssh -i ../test.pem jenkins@<JENKINS_IP>
```

**Set variables:**
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
```

**Clone the app repo and build the image:**
```bash
cd ~
git clone https://github.com/ibrahim-2010/nimbus-retail-starter.git
cd nimbus-retail-starter/services/operator-copilot

# Login to ECR
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin \
    $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Build and push
docker build -t operator-copilot:latest .
docker tag operator-copilot:latest \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/operator-copilot:latest
docker push \
  $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/operator-copilot:latest
```

**Create the Kubernetes secret** (ArgoCD will deploy operator-copilot once this exists):
```bash
# Ensure namespace exists
kubectl get namespace operator-copilot 2>/dev/null \
  || kubectl create namespace operator-copilot

# Create secret — paste your actual Anthropic API key
kubectl create secret generic operator-copilot-secrets \
  --namespace operator-copilot \
  --from-literal=ANTHROPIC_API_KEY=<your-anthropic-api-key>
```

**Verify Ollama is ready before testing the agent** (Ollama must finish loading the model first):
```bash
kubectl logs -n ai deploy/ollama --tail=20
# Wait for: "Listening on [::]:11434"
```

**Test operator-copilot:**
```bash
kubectl get pods -n operator-copilot
# Expected: operator-copilot pod Running 1/1

kubectl logs -n operator-copilot deploy/operator-copilot --tail=20
# Expected: server started / listening on port 3000
```

> **Secret already exists?** If you're redeploying, delete and recreate:
> ```bash
> kubectl delete secret operator-copilot-secrets -n operator-copilot
> kubectl create secret generic operator-copilot-secrets \
>   --namespace operator-copilot \
>   --from-literal=ANTHROPIC_API_KEY=<your-key>
> ```

---

### Step 8 – Verify the Deployment

Run these from your local machine:

```bash
kubectl get nodes
# Expected: 2 nodes, STATUS: Ready
```

```bash
kubectl get pods -n nimbus
# Expected: 6 services + frontend, STATUS: Running, READY: 1/1
```

```bash
kubectl get pods -n kafka
# Expected: 3 nimbus-kafka-dual-role-* pods, Running
```

```bash
kubectl get pods -n monitoring
# Expected: prometheus, grafana, loki-0, tempo, promtail-* pods, Running
# promtail runs as a DaemonSet – one pod per worker node (2 pods on a 2-node cluster)
```

```bash
kubectl get applications -n argocd
# Expected: all SYNC: Synced, HEALTH: Healthy
```

```bash
kubectl get externalsecrets -n nimbus
# Expected: READY: True, STATUS: SecretSynced
```

```bash
kubectl get networkpolicies -n nimbus
# Expected: 7 policies listed
```

```bash
kubectl get clusterpolicies
# Expected: 4 Kyverno policies listed
```

**Service health smoke test:**
```bash
kubectl exec -n nimbus deploy/auth-service -- wget -qO- http://localhost:3001/healthz
# Expected: {"status":"ok"}
```

**Check DNS (allow 2–5 min after pipeline for ExternalDNS to write the A record):**
```bash
nslookup platinum-consults.com 8.8.8.8
# Expected: returns ALB IP – no NXDOMAIN

curl -s -o /dev/null -w "%{http_code}" http://platinum-consults.com
# Expected: 200
```

**End-to-end test:** open `http://platinum-consults.com` and complete the full flow:
register → login → browse catalog → add to cart → place order.

---

## Accessing the Platform

All URLs are live once the infrastructure pipeline completes and DNS propagates (~5 min after pipeline finishes).

| Service | URL | Credentials |
|---|---|---|
| **NimbusRetail Website** | `http://platinum-consults.com` | Register a new account |
| **Grafana** | `http://grafana.platinum-consults.com` | admin / retrieve: `aws secretsmanager get-secret-value --secret-id nimbus-cluster/grafana/admin-password --query SecretString --output text --region us-east-1` |
| **Prometheus** | `http://prometheus.platinum-consults.com` | No login |
| **ArgoCD** | `https://<argocd-lb>` printed in Step 6 output | admin / printed in Step 6 output |
| **Jenkins** | `http://<JENKINS_IP>:8080` | admin / your chosen password from Step 5 |
| **SonarQube** | `http://<JENKINS_IP>:9000` | admin / SonarAdmin2026! |

---

## Secret Management

All credentials are randomly generated and stored in AWS Secrets Manager – nothing is hardcoded in code or config files.

| Secret path | Contents | Created by |
|---|---|---|
| `nimbus-cluster/rds/master-password` | RDS PostgreSQL master password | Terraform |
| `nimbus-cluster/grafana/admin-password` | Grafana admin password | Terraform |
| `nimbus-cluster/nimbus-secrets` | JWT_SECRET, DATABASE_URL, REDIS_URL (auth/cart/order) | Jenkins pipeline Stage 6 |
| `nimbus-cluster/nimbus-catalog-secrets` | DATABASE_URL, REDIS_URL (catalog, asyncpg format) | Jenkins pipeline Stage 6 |

**Retrieve Grafana password:**
```bash
aws secretsmanager get-secret-value \
  --secret-id nimbus-cluster/grafana/admin-password \
  --query SecretString --output text --region us-east-1
```

---

## Teardown (when done testing)

```bash
cd /c/Users/19122/nimbus-retail-platform
bash destroy.sh
```

Takes ~15 min. Runs 11 phases in dependency order.

The Route 53 hosted zone is **intentionally preserved** – nameservers at your registrar stay valid for the next deployment.

After destroy.sh finishes, verify everything is clean:
```bash
aws eks list-clusters --region us-east-1
# Expected: []

aws ec2 describe-instances --region us-east-1 \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId"
# Expected: []
```

**Delete S3 + DynamoDB only when done with the project permanently:**
```bash
# Delete all versions + delete markers first (required for versioned bucket)
aws s3api delete-objects --bucket ibrahim-cloud-native-tf-state \
  --delete "$(aws s3api list-object-versions --bucket ibrahim-cloud-native-tf-state \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"
aws s3api delete-objects --bucket ibrahim-cloud-native-tf-state \
  --delete "$(aws s3api list-object-versions --bucket ibrahim-cloud-native-tf-state \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)"
aws s3api delete-bucket --bucket ibrahim-cloud-native-tf-state --region us-east-1
aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region us-east-1
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `nimbus-infrastructure` fails at Terraform Init | Provider download timeout | Re-run the job – transient network issue |
| `nimbus-infrastructure` fails at Terraform Apply – EKS Cluster | IAM permissions or network issue | Check Jenkins EC2 instance role has all 8 policies; check route tables in VPC |
| `nimbus-infrastructure` fails at Terraform Apply – Full Stack | IAM permission issue | Check Jenkins EC2 instance role; re-run job |
| Only 2 jobs in Jenkins instead of 7 | JCasC loaded from stale cached image | Re-run `sudo bash /opt/setup-jcasc.sh` on the Jenkins EC2 |
| `data.aws_route53_zone.main` not found | Route 53 zone doesn't exist | Run `bash bootstrap.sh` – it creates the zone idempotently |
| ArgoCD app stuck `OutOfSync` | Kyverno blocking | `kubectl get policyreport -n nimbus` |
| ESO `SecretSyncedError` | Secrets not yet in Secrets Manager | Check pipeline Populate Secrets Manager stage output; re-run pipeline if needed |
| Pod `ImagePullBackOff` | Service build job not run yet | Trigger that service's Jenkins build job |
| Pod crash – `secret not found` | ESO hasn't synced yet | `kubectl annotate externalsecret nimbus-secrets -n nimbus force-sync=$(date +%s) --overwrite` |
| Kafka pods pending | EBS volume not provisioned | `kubectl describe pod -n kafka` – check StorageClass is `gp3` |
| ArgoCD password not shown in output | Secret already rotated | `kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' \| base64 -d` |
| Register returns `relation "auth.users" does not exist` | Database Initialize stage failed | Re-run db-init Job: `kubectl delete job db-init -n nimbus --ignore-not-found && kubectl apply -f <job-yaml>` |
| Services 0/1, logs show `no encryption` | DATABASE_URL missing `?sslmode=require` | Check `nimbus-cluster/nimbus-secrets` in Secrets Manager – URL must end with `?sslmode=require` |
| `platinum-consults.com` shows registrar page | Nameservers not updated at registrar | Complete Step 3 – update registrar nameservers to the 4 Route 53 nameservers from bootstrap output |
| `platinum-consults.com` returns NXDOMAIN | DNS not propagated yet | Wait 5–30 min after updating registrar nameservers; verify with `nslookup -type=NS platinum-consults.com 8.8.8.8` |
| Site resolves but shows 503 on API calls | ALB health check wrong | Should be auto-fixed – check `alb.ingress.kubernetes.io/healthcheck-path: /healthz` in ingress |
| ExternalDNS AccessDenied on Route 53 | Two hosted zones exist (orphan from old deployment) | `aws route53 list-hosted-zones` – identify and delete the orphan zone that doesn't match bootstrap's zone ID |
| `prometheus.platinum-consults.com` unreachable after redeploy | Stale Route 53 alias pointing to old ALB; ExternalDNS won't update records it doesn't own | Check TXT ownership records exist in Route 53 for `prometheus.platinum-consults.com` – they are preserved in the hosted zone across deployments. If missing, ExternalDNS will create them on the first successful ingress sync |
| Grafana shows Loki or Tempo datasource error | Wrong port or outdated Loki version | Tempo must use port 3200 (not 3100). Loki requires the `loki` chart (3.x) not the deprecated `loki-stack` – both are set correctly in Terraform |

---

## Quick Reference

| What | Where |
|---|---|
| Jenkins UI | `http://<JENKINS_IP>:8080` |
| SonarQube UI | `http://<JENKINS_IP>:9000` (admin / SonarAdmin2026!) |
| NimbusRetail Website | `http://platinum-consults.com` |
| Grafana | `http://grafana.platinum-consults.com` |
| Prometheus | `http://prometheus.platinum-consults.com` |
| ArgoCD | `https://$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')` |
| Infrastructure pipeline | `nimbus-infrastructure` job in Jenkins |
| Service pipelines | `nimbus-auth/audit/catalog/cart/order/notification-service` |
| Platform repo | `https://github.com/ibrahim-2010/nimbus-retail-platform` |
| App repo | `https://github.com/ibrahim-2010/nimbus-retail-starter` |
| Runbook | `nimbus-retail-platform/docs/RUNBOOK.md` |
