# Cloud-Native EKS Project — Complete Deployment Guide

> Tested and verified across four deployment cycles. Every command is the one that actually worked.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Phase 1: Bootstrap](#phase-1-bootstrap)
- [Phase 2: Deploy Jenkins Server](#phase-2-deploy-jenkins-server)
- [Phase 3: Configure Jenkins (Automated)](#phase-3-configure-jenkins-automated)
- [Phase 4: Deploy EKS Cluster](#phase-4-deploy-eks-cluster)
- [Phase 5: Deploy Application Stack](#phase-5-deploy-application-stack)
- [Phase 6: ArgoCD & App-of-Apps](#phase-6-argocd--app-of-apps)
- [Phase 7: Run CI/CD Pipelines](#phase-7-run-cicd-pipelines)
- [Phase 8: Verify Everything](#phase-8-verify-everything)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before starting, ensure you have:

- AWS account with IAM user credentials (Access Key + Secret Key)
- IAM user with these permissions: EC2, EKS, ECR, S3, Route 53, IAM, VPC, CloudFormation full access
- **vCPU quota of at least 20** — check and request increase:
  ```bash
  # Check current quota
  aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A \
    --region us-east-1 --query "Quota.Value"

  # Request increase if below 20
  aws service-quotas request-service-quota-increase \
    --service-code ec2 --quota-code L-1216C47A \
    --desired-value 20 --region us-east-1
  ```
  Small increases are usually approved within 15-30 minutes. **Do not proceed until quota shows 20.0.**

- AWS CLI v2 installed and configured locally
- Terraform >= 1.9.0
- Git & GitHub account with Personal Access Token (PAT with `repo` + `write:packages` scopes)
- A domain name with ability to change nameservers
- SSH key pair in us-east-1 (bootstrap creates this if it doesn't exist)

---

## Phase 1: Bootstrap

Creates all prerequisite AWS resources. This script is **idempotent** — safe to run multiple times. Existing resources are skipped.

```bash
bash bootstrap.sh
```

**Creates:**
- S3 bucket for Terraform state (`ibrahim-cloud-native-tf-state`)
- DynamoDB table for state locking (`ibrahim-cloud-native-tf-lock`)
- ECR repositories (`frontend`, `backend`)
- EC2 key pair (`test`)

**Expected output:**
```
╔══════════════════════════════════════════════════╗
║         BOOTSTRAP COMPLETE                        ║
╚══════════════════════════════════════════════════╝
```

> **Note:** S3 and DynamoDB are NOT destroyed during teardown — they persist between deployments and cost almost nothing.

---

## Phase 2: Deploy Jenkins Server

```bash
cd Jenkins-Server-TF
terraform init
terraform apply -auto-approve
```

**What Terraform creates:**
- EC2 instance (m7i-flex.large) with Ubuntu 22.04
- Security group (ports 22, 8080, 9000)
- IAM role with managed policies + EKS inline policy
- IAM instance profile

**What user-data installs automatically (wait 5 minutes):**
- Jenkins (stopped before plugins install)
- 102 Jenkins plugins via `jenkins-plugin-manager` JAR (with dependency resolution)
- JCasC YAML with Jenkins URL auto-configured from EC2 metadata
- systemd override for JCasC environment variables
- Docker + SonarQube container
- sonar-scanner
- AWS CLI v2, kubectl, eksctl, Terraform, Trivy, Helm

**Verification (after 5 minutes):**
```bash
ssh -i test.pem ubuntu@<jenkins-ip>
sudo su -

jenkins --version && docker --version && terraform --version
aws --version && kubectl version --client && eksctl version
helm version && trivy --version && sonar-scanner --version

# Check plugins were installed
ls /var/lib/jenkins/plugins/*.jpi /var/lib/jenkins/plugins/*.hpi 2>/dev/null | wc -l
# Should show 100+

# Check SonarQube is running
docker ps | grep sonar

# Check JCasC config is in place
ls -la /var/lib/jenkins/casc_configs/jenkins.yaml
```

---

## Phase 3: Configure Jenkins (Automated)

One interactive command that configures everything:

```bash
sudo bash /opt/setup-jcasc.sh
```

**Prompts for:**
- GitHub username
- GitHub PAT
- AWS Account ID (12 digits)
- Jenkins admin password (choose your own)
- AWS Access Key ID
- AWS Secret Access Key

**Automatically configures:**
- ✅ 6 Jenkins credentials (github-creds, github-token, ACCOUNT_ID, ECR_REPO1, ECR_REPO2, sonar)
- ✅ SonarQube password change (admin:admin → admin:SonarAdmin2026!)
- ✅ SonarQube token generation via API
- ✅ SonarQube webhook creation via API (uses private IP, not localhost)
- ✅ SonarQube server configuration in Jenkins (via Groovy init script)
- ✅ 2 pipeline jobs (three-tier-backend, three-tier-frontend)
- ✅ AWS CLI configured for both jenkins and root users
- ✅ Exports AWS credentials for current session

**Expected output:**
```
╔══════════════════════════════════════════════════╗
║         JCASC SETUP COMPLETE                      ║
╚══════════════════════════════════════════════════╝

Auto-configured:
  ✅ 6 credentials
  ✅ SonarQube server
  ✅ SonarQube webhook
  ✅ 2 pipeline jobs
  ✅ AWS CLI configured
```

**Verify:** Open `http://<jenkins-ip>:8080` — login with admin and your chosen password. You should see two pipeline jobs already created.

---

## Phase 4: Deploy EKS Cluster

Run this from the Jenkins server (as root, same terminal as Phase 3):

```bash
cd /tmp
git clone https://github.com/ibrahim-2010/cloud-native-eks.git
cd cloud-native-eks/EKS-Terraform
terraform init
terraform apply -auto-approve
```

**Takes 15-20 minutes. Creates 41 resources:**
- VPC with public/private subnets across 2 AZs
- Internet Gateway + NAT Gateway
- EKS cluster (v1.31) with managed node group (2x t3.xlarge)
- OIDC provider for IRSA
- EBS CSI driver addon + IAM role
- AWS Load Balancer Controller (Helm) + IAM role
- ExternalDNS (Helm) + IAM role + Route 53 hosted zone
- Prometheus + Grafana monitoring stack (Helm)
- 3 namespaces (three-tier, monitoring, argocd)

**After completion:**
```bash
# Configure kubectl
aws eks update-kubeconfig --name cloud-native-cluster --region us-east-1
kubectl get nodes
# Should show 2 nodes in Ready status

# Copy kubeconfig to jenkins user
mkdir -p /var/lib/jenkins/.kube
cp /root/.kube/config /var/lib/jenkins/.kube/config
chown -R jenkins:jenkins /var/lib/jenkins/.kube
```

**Update nameservers at your domain registrar** with the Route 53 NS records from the Terraform output (`route53_nameservers`).

---

## Phase 5: Deploy Application Stack

### 5.1 Deploy Database Layer

```bash
cd /tmp/cloud-native-eks
kubectl apply -f Kubernetes-Manifests-file/Database/
```

Verify:
```bash
kubectl get pods -n three-tier
# postgres and redis should be Running
```

### 5.2 Bootstrap Application Images (One-Time)

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS \
  --password-stdin 022374769206.dkr.ecr.us-east-1.amazonaws.com

# Build and push backend
cd /tmp/cloud-native-eks/Application-Code/backend
docker build -t 022374769206.dkr.ecr.us-east-1.amazonaws.com/backend:1 .
docker push 022374769206.dkr.ecr.us-east-1.amazonaws.com/backend:1

# Build and push frontend
cd ../frontend
docker build -t 022374769206.dkr.ecr.us-east-1.amazonaws.com/frontend:1 .
docker push 022374769206.dkr.ecr.us-east-1.amazonaws.com/frontend:1
```

### 5.3 Update Manifests and Deploy

```bash
cd /tmp/cloud-native-eks

# Replace placeholders with actual values
sed -i 's|<ACCOUNT_ID>|022374769206|g' Kubernetes-Manifests-file/Backend/deployment.yaml
sed -i 's|<ACCOUNT_ID>|022374769206|g' Kubernetes-Manifests-file/Frontend/deployment.yaml
sed -i 's|backend:[0-9]*|backend:1|' Kubernetes-Manifests-file/Backend/deployment.yaml
sed -i 's|frontend:[0-9]*|frontend:1|' Kubernetes-Manifests-file/Frontend/deployment.yaml

kubectl apply -f Kubernetes-Manifests-file/Backend/
kubectl apply -f Kubernetes-Manifests-file/Frontend/
kubectl apply -f Kubernetes-Manifests-file/ingress.yaml
```

### 5.4 Push to Git (CRITICAL — Before ArgoCD)

```bash
git add -A
git commit -m "fix: set ECR image paths"
git push origin main
```

> ⚠️ **Do this BEFORE Phase 6.** If ArgoCD syncs before you push, it overwrites working deployments with placeholder values.

Verify:
```bash
kubectl get pods -n three-tier
# All 4 pods should be Running

kubectl get ingress -n three-tier
# ADDRESS should show ALB DNS name
```

---

## Phase 6: ArgoCD & App-of-Apps

### 6.1 Install ArgoCD

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts

kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Wait 60 seconds, then get credentials
sleep 60
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
kubectl get svc argocd-server -n argocd
```

### 6.2 Connect Repository

Open ArgoCD UI (`https://<EXTERNAL-IP>`), login as admin, then:
Settings → Repositories → Connect Repo Using HTTPS:
- URL: `https://github.com/ibrahim-2010/cloud-native-eks.git`
- Username: your GitHub username
- Password: your GitHub PAT

### 6.3 Deploy All Apps (One Command)

```bash
kubectl apply -f argocd/app-of-apps.yaml
```

**This creates 5 child applications automatically:**
- `three-tier-database` — PostgreSQL + Redis
- `three-tier-backend` — API deployment
- `three-tier-frontend` — Frontend deployment
- `three-tier-ingress` — ALB ingress with ExternalDNS
- `monitoring-ingress` — Grafana ALB with ExternalDNS subdomain

Verify:
```bash
kubectl get applications -n argocd
# All should show Synced + Healthy
```

### 6.4 Apply Custom Monitoring Alerts

```bash
kubectl apply -f Kubernetes-Manifests-file/monitoring-alerts.yaml
```

---

## Phase 7: Run CI/CD Pipelines

Go to Jenkins (`http://<jenkins-ip>:8080`) and click **Build Now** on both:
- `three-tier-backend`
- `three-tier-frontend`

Both should pass all 9 stages:
1. Cleanup → 2. Checkout → 3. SonarQube → 4. Quality Gate → 5. Trivy FS → 6. Docker Build → 7. Trivy Image → 8. ECR Push → 9. Update Manifest

After Stage 9, ArgoCD detects the Git change and auto-deploys.

---

## Phase 8: Verify Everything

### Application
- Open `http://platinum-consults.com` — should show Cloud Native Task Manager with green health dots

### Grafana
- Open `http://grafana.platinum-consults.com` — login: admin / CloudNative2026!
- Go to Dashboards → Browse → "Kubernetes / Compute Resources / Namespace (Pods)" → select `three-tier`

### DNS (auto-created by ExternalDNS)
```bash
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> \
  --query "ResourceRecordSets[?Type=='A'].[Name]" --output text
# Should show: platinum-consults.com AND grafana.platinum-consults.com
```

### Full Status
```bash
kubectl get pods -n three-tier
kubectl get pods -n monitoring
kubectl get ingress -n three-tier
kubectl get ingress -n monitoring
kubectl get applications -n argocd
```

---

## Cleanup

### Automated Teardown

```bash
bash destroy.sh
```

### Manual Teardown (if destroy.sh fails)

```bash
# 1. ArgoCD apps
kubectl delete applications --all -n argocd

# 2. ArgoCD itself
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. EKS infrastructure
cd EKS-Terraform && terraform destroy -auto-approve

# 4. ECR repos
aws ecr delete-repository --repository-name frontend --region us-east-1 --force
aws ecr delete-repository --repository-name backend --region us-east-1 --force

# 5. Jenkins server
cd Jenkins-Server-TF && terraform destroy -auto-approve

# 6. Manual check: EC2, EBS, ELBs, CloudFormation, Elastic IPs, NAT Gateways
```

> **S3 bucket and DynamoDB table are NOT deleted** — they persist between deployments and cost almost nothing. Delete them only when completely done with the project.

---

## Troubleshooting

### Quick Reference

| Problem | Check | Fix |
|---------|-------|-----|
| `eks:DescribeClusterVersions` denied | IAM inline policy | Already in Terraform — shouldn't occur |
| Cached credentials | `aws sts get-caller-identity` | Export `AWS_ACCESS_KEY_ID/SECRET` |
| `npm ci` fails | Dockerfile | Change to `npm install --omit=dev` |
| ArgoCD CRD too large | Always happens | Use `--server-side --force-conflicts` |
| Pods stuck Pending | `kubectl describe pod` | Check ENI pod limits, use t3.xlarge |
| vCPU limit exceeded | `aws service-quotas get-service-quota` | Request increase to 20 |
| Quality Gate timeout | SonarQube webhooks | Check webhook uses private IP |
| sonar-scanner not found | `which sonar-scanner` | Manual install from `/tmp` |
| ALB not provisioning | `kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller` | Check IAM policy |
| ImagePullBackOff | `kubectl describe pod` | Check image tag matches ECR |
| Ingress ADDRESS empty | Controller running? | Delete and reapply ingress |
| JCasC boot failure | `journalctl -u jenkins` | Check YAML syntax, remove unsupported attributes |
| Plugin mirrors down | `curl -s -o /dev/null -w "%{http_code}" https://updates.jenkins.io/latest/configuration-as-code.hpi` | Wait for 200, retry |
| Grafana wrong datasource | Check configmap names | Delete old `monitoring-stack-*` configmaps |

### Checking Jenkins Plugin Mirror Status

```bash
curl -s -o /dev/null -w "%{http_code}" https://updates.jenkins.io/latest/configuration-as-code.hpi
# 200 or 302 = mirrors are up
# 503 = mirrors are down, wait and retry
```

### Checking Logs

```bash
# Jenkins
journalctl -u jenkins.service --no-pager | grep -i "SEVERE\|error" | tail -20

# ALB Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20

# ArgoCD
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=20

# User data script
cat /var/log/tools-install.log
```

---

*Ibrahim | [github.com/ibrahim-2010/cloud-native-eks](https://github.com/ibrahim-2010/cloud-native-eks) | [platinum-consults.com](http://platinum-consults.com)*