# Cloud-Native EKS Project — Issues, Challenges & Solutions Report

> Documented across four full deployment cycles. Every issue below was encountered and resolved during the actual build — not hypothetical scenarios.

---

## Executive Summary

This report documents every issue encountered during four complete deployment cycles of a cloud-native three-tier application on AWS EKS. A total of **17 distinct issues** were encountered and resolved across IAM permissions, CI/CD pipeline configuration, Kubernetes scheduling, GitOps workflows, Jenkins automation, and monitoring setup.

### Issue Distribution by Category

| Category | Count | Issues |
|----------|-------|--------|
| IAM & Permissions | 4 | #1, #2, #7, #11 |
| CI/CD Pipeline | 3 | #3, #8, #9 |
| Kubernetes & Scheduling | 3 | #6, #12, #13 |
| GitOps & ArgoCD | 2 | #4, #5 |
| Jenkins Automation (JCasC) | 3 | #14, #15, #16 |
| Monitoring | 2 | #10, #17 |

### Issue Distribution by Severity

| Severity | Count | Issues |
|----------|-------|--------|
| Critical — Blocks deployment entirely | 7 | #1, #5, #6, #11, #12, #14, #15 |
| High — Feature broken, workaround needed | 6 | #2, #3, #8, #9, #10, #16 |
| Medium — Inconvenience, non-blocking | 4 | #4, #7, #13, #17 |

### Issue Distribution by Deployment Cycle

| Deployment | Issues Encountered | New Issues |
|-----------|-------------------|------------|
| Deployment 1 (t3.small, manual) | #1-#10 | 10 |
| Deployment 2 (t3.xlarge, manual) | #1, #2, #11, #12, #13 | 3 |
| Deployment 3 (JCasC + Terraform EKS) | #14, #15 | 2 |
| Deployment 4 (Full automation) | #16, #17 | 2 |

---

## Issue #1: EKS Cluster Creation Denied — DescribeClusterVersions

**Category:** IAM & Permissions | **Severity:** Critical | **Deployments:** 1, 2, 3, 4

**Error Message:**
```
User: arn:aws:sts::022374769206:assumed-role/jenkins-cloud-native-role/... 
is not authorized to perform: eks:DescribeClusterVersions
```

**Root Cause:** The Terraform-provisioned IAM role attached standard AWS managed policies (AmazonEKSClusterPolicy, AmazonEKSWorkerNodePolicy, etc.) but these managed policies do not include the newer `eks:DescribeClusterVersions` API action. The `AmazonEKSFullAccess` managed policy does not exist.

**Investigation:** Attempted to attach `AmazonEKSFullAccess` — received "Policy does not exist." Confirmed the managed policy name doesn't exist in AWS IAM.

**Solution:** Added an inline IAM policy in Terraform `main.tf`:
```hcl
resource "aws_iam_role_policy" "eks_full_access" {
  name = "EKSFullAccess"
  role = aws_iam_role.jenkins_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "eks:*"
      Resource = "*"
    }]
  })
}
```

**Prevention:** The inline policy is now part of the Terraform code — created automatically with every deployment.

**Lesson Learned:** AWS managed policies lag behind new API actions. For EKS, an explicit `eks:*` inline policy is the most reliable approach.

---

## Issue #2: Instance Profile Credential Caching

**Category:** IAM & Permissions | **Severity:** High | **Deployments:** 1, 2

**Error Message:** Same `eks:DescribeClusterVersions` error persisted after adding the inline policy and waiting 30+ seconds.

**Root Cause:** EC2 instances retrieve IAM credentials from the Instance Metadata Service (IMDS). These credentials are cached with a TTL and do not immediately reflect policy changes.

**Investigation:** Ran `aws iam list-role-policies` — confirmed `EKSFullAccess` appeared. Waited 30 seconds, retried — same error.

**Solution:** Exported `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as environment variables, overriding the instance profile.

**Prevention:** The `setup-jcasc.sh` script now configures AWS credentials for both jenkins and root users, and exports them for the current session. The EKS inline policy is also in Terraform now, so it's attached at creation time (no policy update delay).

**Lesson Learned:** When IAM policy changes appear correct but aren't taking effect on EC2, the IMDS cache is the most likely culprit. Export credentials to override.

---

## Issue #3: Docker Build Failure — npm ci Requires package-lock.json

**Category:** CI/CD Pipeline | **Severity:** High | **Deployments:** 1, 2

**Error Message:**
```
npm error: The `npm ci` command can only install with an existing package-lock.json
```

**Root Cause:** The backend Dockerfile used `RUN npm ci --only=production` which requires a `package-lock.json` file. The project scaffold only had `package.json`.

**Solution:** Changed the Dockerfile to use `npm install --omit=dev` instead of `npm ci`.

**Prevention:** For production, commit `package-lock.json` to the repo. For portfolio projects, `npm install` is acceptable.

**Lesson Learned:** Always check if Dockerfile commands match the files actually committed to the repo.

---

## Issue #4: ArgoCD CRD Annotations Too Long

**Category:** GitOps & ArgoCD | **Severity:** Medium | **Deployments:** 1, 2, 3, 4

**Error Message:**
```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: 
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Root Cause:** Newer ArgoCD versions have CRD manifests exceeding the 262144 byte Kubernetes annotation limit for client-side apply.

**Solution:** Applied with `--server-side --force-conflicts`:
```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts
```

**Lesson Learned:** Server-side apply is the future direction for large manifest installations.

---

## Issue #5: ArgoCD Overwrote Working Deployments

**Category:** GitOps & ArgoCD | **Severity:** Critical | **Deployments:** 1

**Error Message:** All pods went to `InvalidImageName` — trying to pull `<ACCOUNT_ID>.dkr.ecr...`

**Root Cause:** Deployment manifests were updated locally with `sed` but not pushed to Git. ArgoCD synced the old Git state (with `<ACCOUNT_ID>` placeholders) over the working cluster state.

**Solution:** Push manifest changes to Git immediately after updating them.

**Prevention:** The deployment guide now emphasizes: **always push to Git BEFORE enabling ArgoCD sync**.

**Lesson Learned:** Git is the single source of truth in GitOps. If Git is wrong, ArgoCD makes the cluster wrong too. There is no "temporary local override."

---

## Issue #6: Pods Stuck in Pending — t3.small ENI Pod Limit

**Category:** Kubernetes & Scheduling | **Severity:** Critical | **Deployments:** 1

**Error Message:**
```
0/3 nodes are available: 3 Too many pods
```

**Root Cause:** t3.small has an ENI-based pod limit of 11 pods per node. With 3 nodes (33 total capacity), system pods consumed ~10 slots, leaving only 23 for app + ArgoCD + monitoring (30+ pods needed).

**Solution:**
- Deployment 1: Reduced replicas, scaled down non-essential ArgoCD components
- Deployment 2+: Upgraded to t3.xlarge (58 pods/node)

**Lesson Learned:** Kubernetes scheduling considers CPU, memory, AND pod count. Pod count from ENI limits is often the first constraint hit on smaller instances.

---

## Issue #7: Cannot Scale to 4 Nodes — vCPU Quota

**Category:** IAM & Permissions | **Severity:** Medium | **Deployments:** 1

**Error Message:**
```
VcpuLimitExceeded — current vCPU limit of 8
```

**Root Cause:** AWS account default vCPU limit of 8. 3 nodes (6 vCPU) + Jenkins (2 vCPU) = 8, hitting the ceiling.

**Solution:** Requested quota increase to 20 via AWS Service Quotas.

**Prevention:** Added as a prerequisite in the deployment guide. Request quota increase BEFORE starting.

**Lesson Learned:** AWS default quotas are conservative. Always check quotas before planning infrastructure.

---

## Issue #8: Jenkins Quality Gate Timeout

**Category:** CI/CD Pipeline | **Severity:** High | **Deployments:** 1

**Error Message:**
```
Timeout has been exceeded — status is 'IN_PROGRESS'
```

**Root Cause:** No SonarQube webhook configured. SonarQube completed analysis but had no way to notify Jenkins.

**Solution:** Created webhook in SonarQube pointing to Jenkins.

**Prevention:** The `setup-jcasc.sh` script now creates the webhook automatically via SonarQube API. Uses private IP (not localhost — see Issue #16).

**Lesson Learned:** The SonarQube-Jenkins integration requires two-way configuration: Jenkins calls SonarQube for analysis, SonarQube calls Jenkins back via webhook.

---

## Issue #9: Jenkins SCM Credential Dropdown Empty

**Category:** CI/CD Pipeline | **Severity:** High | **Deployments:** 1, 2

**Error Message:** Credentials dropdown in Pipeline SCM configuration showed no options.

**Root Cause:** `github-token` was created as "Secret text" type. Jenkins SCM requires "Username with password" type.

**Solution:** Created `github-creds` as "Username with password" type.

**Prevention:** JCasC now creates both credential types automatically — `github-creds` (Username/Password for SCM) and `github-token` (Secret text for pipeline git push).

**Lesson Learned:** Jenkins has multiple credential types for different contexts. SCM plugins use Username/Password; pipeline scripts can use Secret text.

---

## Issue #10: sonar-scanner Not Found in Pipeline

**Category:** Monitoring | **Severity:** High | **Deployments:** 1, 2, 3

**Error Message:**
```
sonar-scanner: not found
```

**Root Cause:** The user-data script's sonar-scanner download/installation failed silently during EC2 boot. User-data scripts run as fire-and-forget — individual failures don't stop the script.

**Solution:**
- Deployments 1-2: Manual install after SSH
- Deployment 3+: `tools-install.sh` includes verification step and the install is more robust

**Prevention:** The tools-install.sh now verifies sonar-scanner after installation and logs a warning if it fails.

**Lesson Learned:** User-data scripts are unreliable for complex installations. Always verify tool availability after boot.

---

## Issue #11: ALB Not Provisioning — Missing IAM Permissions

**Category:** IAM & Permissions | **Severity:** Critical | **Deployments:** 2

**Error Message:**
```
elasticloadbalancing:DescribeListenerAttributes access denied
ec2:DescribeSecurityGroups unauthorized operation
```

**Root Cause:** The downloaded ALB Controller IAM policy (v2.7.1) was missing newer API actions. The Helm chart installed a newer controller binary that requires `DescribeListenerAttributes` and EC2 security group permissions.

**Solution:** Created a broader IAM policy with `elasticloadbalancing:*` and `ec2:Describe*` permissions.

**Prevention:** The `EKS-Terraform/alb-controller.tf` now includes the broad policy from day one — no manual policy updates needed.

**Lesson Learned:** IAM policy version mismatches between documentation and software are recurring. Broader permissions are safer than trying to enumerate individual actions.

---

## Issue #12: ImagePullBackOff After Redeployment

**Category:** Kubernetes & Scheduling | **Severity:** Critical | **Deployments:** 2

**Error Message:**
```
Failed to pull image "...backend:3": not found
```

**Root Cause:** After teardown and rebuild, deployment manifests in Git still had image tags (:2, :3) from previous Jenkins builds. New ECR repos only had tag :1 from fresh bootstrap.

**Solution:** Used sed with regex to replace any tag number:
```bash
sed -i 's|backend:[0-9]*|backend:1|' Kubernetes-Manifests-file/Backend/deployment.yaml
```

**Prevention:** Bootstrap step now includes a check/fix for image tags alongside the `<ACCOUNT_ID>` replacement.

**Lesson Learned:** Git retains state from the last deployment, but AWS resources (ECR) start fresh after teardown. The manifest-to-registry mismatch is inevitable unless you reset manifests.

---

## Issue #13: Ingress ADDRESS Empty After Apply

**Category:** Kubernetes & Scheduling | **Severity:** Medium | **Deployments:** 2

**Error Message:** `kubectl get ingress` showed the resource but ADDRESS column was empty for 5+ minutes.

**Root Cause:** Ingress resource was created before the ALB Controller was installed. The controller doesn't reconcile pre-existing resources.

**Solution:** Delete and reapply the ingress after the controller is running.

**Prevention:** In Terraform deployment, the ALB controller is installed before any ingress resources are created (dependency ordering via `depends_on`).

**Lesson Learned:** Kubernetes controllers reconcile resources created AFTER the controller starts. Pre-existing resources may not be detected.

---

## Issue #14: JCasC sonarGlobalConfiguration Not Recognized

**Category:** Jenkins Automation | **Severity:** Critical | **Deployments:** 3

**Error Message:**
```
Invalid configuration elements for type: class jenkins.model.GlobalConfigurationCategory$Unclassified : sonarGlobalConfiguration
```

**Root Cause:** The `sonarGlobalConfiguration` attribute name used in the JCasC YAML is not recognized by the configuration-as-code plugin in newer Jenkins versions. The SonarQube plugin's JCasC integration uses a different attribute structure than documented.

**Investigation:** Jenkins boot failed with `ConfigurationAsCodeBootFailure`. The error listed all available attributes under `unclassified:` — `sonarGlobalConfiguration` was not among them.

**Solution:** Removed SonarQube configuration from JCasC YAML entirely. Instead, configured SonarQube via a Groovy init script (`/var/lib/jenkins/init.groovy.d/sonarqube.groovy`) that runs on Jenkins boot:
```groovy
import hudson.plugins.sonar.*
import jenkins.model.Jenkins

def instance = Jenkins.getInstance()
def sonarConfig = instance.getDescriptor(SonarGlobalConfiguration.class)
def sonarInstallation = new SonarInstallation(
    'sonar', 'http://localhost:9000', 'sonar',
    null, null, null, null, null, null
)
sonarConfig.setInstallations(sonarInstallation)
sonarConfig.save()
```

**Prevention:** The `setup-jcasc.sh` script creates this Groovy init script automatically.

**Lesson Learned:** JCasC doesn't support all Jenkins plugin configurations. When JCasC fails for a specific plugin, Groovy init scripts are the reliable fallback. Always check the actual available attributes (listed in the error message) rather than trusting documentation.

---

## Issue #15: Jenkins Plugin Dependency Hell

**Category:** Jenkins Automation | **Severity:** Critical | **Deployments:** 3

**Error Message:** Multiple errors including:
```
Failed Loading plugin Jenkins Workspace Cleanup Plugin v0.49 (ws-cleanup)
version 2.4 or later of plugin 'workflow-job' needs to be installed
docker-pipeline: 404 Not Found
```

**Root Cause:** Three compounding issues:
1. Manual `.hpi` file downloads from `updates.jenkins.io/latest/` don't resolve dependencies
2. The `docker-pipeline` plugin was renamed to `docker-workflow` — the old name returns 404
3. Jenkins CLI (`jenkins-cli.jar`) requires the Jenkins URL to be configured, but JCasC (which sets the URL) requires the `configuration-as-code` plugin, which we're trying to install via CLI — a circular dependency
4. Jenkins mirror outage (503 Service Unavailable) blocked all plugin downloads for several hours

**Investigation:** Tried multiple approaches in sequence:
- `jenkins-cli.jar install-plugin` → 403 "Jenkins URL is not configured"
- Setting URL in JCasC → `configuration-as-code` plugin not installed yet
- Setting URL in `unclassified.location` → plugin not loaded
- Manual `.hpi` wget downloads → missing dependencies crash Jenkins
- `jenkins-plugin-cli` binary → not bundled with newer Jenkins

**Solution:** Used `jenkins-plugin-manager` standalone JAR from GitHub (not from Jenkins mirrors):
```bash
wget -q "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.2/jenkins-plugin-manager-2.13.2.jar" -O /tmp/jenkins-plugin-manager.jar

java -jar /tmp/jenkins-plugin-manager.jar \
  --war /usr/share/java/jenkins.war \
  --plugin-download-directory /var/lib/jenkins/plugins \
  --plugins configuration-as-code job-dsl workflow-aggregator docker-workflow sonar ...
```

Key fixes:
- `docker-workflow` instead of `docker-pipeline`
- Jenkins is STOPPED before plugin install, started AFTER all plugins are in place
- Plugin manager resolves ALL dependencies automatically
- Retry logic (3 attempts with 30-second delays) for transient mirror issues

**Prevention:** The `tools-install.sh` now downloads the plugin manager JAR from GitHub (always available), installs all plugins BEFORE Jenkins first boot, and includes retry logic.

**Lesson Learned:** Jenkins plugin management is the single hardest part of Jenkins automation. The `jenkins-plugin-manager` JAR from GitHub is the only reliable approach — it handles dependency resolution, retries, and doesn't require a running Jenkins instance.

---

## Issue #16: SonarQube Webhook Rejects Localhost

**Category:** Jenkins Automation | **Severity:** High | **Deployments:** 4

**Error Message:**
```json
{"errors":[{"msg":"Invalid URL: loopback and wildcard addresses are not allowed for webhooks."}]}
```

**Root Cause:** Newer versions of SonarQube block webhook URLs pointing to loopback addresses (localhost, 127.0.0.1) as a security measure to prevent SSRF attacks.

**Investigation:** The `setup-jcasc.sh` script tried to create a webhook at `http://localhost:8080/sonarqube-webhook/`. SonarQube rejected it with the loopback error.

**Solution:** Use the EC2 instance's private IP instead of localhost:
```bash
PRIVATE_IP=$(hostname -I | awk '{print $1}')
curl -s -u "admin:${SONAR_NEW_PASS}" -X POST \
  "http://localhost:9000/api/webhooks/create?name=jenkins&url=http://${PRIVATE_IP}:8080/sonarqube-webhook/"
```

**Prevention:** The `setup-jcasc.sh` script now uses `hostname -I` to get the private IP automatically. If that also fails, it falls back to the public IP.

**Lesson Learned:** Security improvements in third-party tools can break existing automation. Always use the actual network IP (private or public) instead of localhost for inter-service communication, even on the same machine.

---

## Issue #17: Grafana Data Source Pointing to Wrong Prometheus URL

**Category:** Monitoring | **Severity:** Medium | **Deployments:** 4

**Error Message:**
```
Post "http://monitoring-stack-kube-prom-prometheus.monitoring:9090/api/v1/query": 
dial tcp 172.20.239.226:9090: connect: connection refused
```

**Root Cause:** During Deployment 4, monitoring was first installed via ArgoCD (which created resources prefixed `monitoring-stack-*`) then reinstalled via Helm directly (which created resources prefixed `monitoring-*`). The Grafana data source provisioning configmap from the ArgoCD install (`monitoring-stack-kube-prom-grafana-datasource`) pointed to the old service name. When the old services were deleted, Grafana couldn't connect to Prometheus. The data source was marked as "Provisioned" in Grafana UI, meaning it couldn't be edited through the interface.

**Investigation:**
1. Grafana showed "connection refused" for Prometheus queries
2. `kubectl get svc -n monitoring | grep prometheus` showed both `monitoring-*` and `monitoring-stack-*` services
3. Grafana's data source pointed to `monitoring-stack-kube-prom-prometheus` (old/deleted)
4. The correct service was `monitoring-kube-prometheus-prometheus` (Helm install)
5. Found 31 old `monitoring-stack-*` configmaps still lingering

**Solution:**
```bash
# Delete ALL old monitoring-stack resources
kubectl delete configmap -n monitoring -l app.kubernetes.io/instance=monitoring-stack
kubectl delete secret monitoring-stack-grafana -n monitoring
kubectl delete alertmanager monitoring-stack-kube-prom-alertmanager -n monitoring
kubectl delete prometheus monitoring-stack-kube-prom-prometheus -n monitoring

# Restart Grafana to reload correct datasource
kubectl rollout restart deployment monitoring-grafana -n monitoring
```

**Prevention:** Monitoring is now managed by Terraform Helm provider (`EKS-Terraform/helm-monitoring.tf`), NOT ArgoCD. This was moved because ArgoCD's Helm rendering skips CRDs by design (Helm v3 policy), which caused Prometheus and Alertmanager StatefulSets to never be created. The `monitoring-stack.yaml` was removed from `argocd/apps/`.

**Lesson Learned:** Never manage the same resources through two different tools (ArgoCD + Helm). The naming conflicts create ghost resources that poison data source configurations. Choose one tool per resource group and stick with it. For kube-prometheus-stack specifically, Terraform Helm provider handles CRDs correctly while ArgoCD does not.

---

## Summary & Key Takeaways

### Top 7 Lessons for Cloud-Native Deployments

**1. IAM is the #1 source of deployment failures.** Four of seventeen issues (24%) were IAM-related. Managed policies lag behind API changes, credential caching creates invisible delays, and different components use separate IAM roles (IRSA vs instance profile).

**2. GitOps means Git is the source of truth — no exceptions.** ArgoCD enforces Git state ruthlessly. Any manual kubectl changes will be reverted. Push to Git first, always.

**3. Instance type selection is about pod capacity, not just CPU/RAM.** t3.small's 11-pod ENI limit was the binding constraint. Check ENI limits before selecting instance types.

**4. Jenkins plugin management requires the plugin-manager JAR.** Manual `.hpi` downloads, Jenkins CLI, and `jenkins-plugin-cli` all have fatal limitations. The standalone `jenkins-plugin-manager` JAR from GitHub is the only reliable approach.

**5. JCasC doesn't support everything.** The SonarQube plugin's JCasC integration is broken in newer Jenkins. Groovy init scripts are the reliable fallback for unsupported configurations.

**6. Don't manage the same resources with two tools.** ArgoCD + Helm for the same monitoring stack created naming conflicts, ghost configmaps, and broken data sources. One tool per resource group.

**7. External dependencies fail.** Jenkins plugin mirrors went down (503) for hours. SonarQube changed its localhost webhook policy. Always build retry logic and fallback mechanisms.

---

*Ibrahim | [github.com/ibrahim-2010/cloud-native-eks](https://github.com/ibrahim-2010/cloud-native-eks) | [platinum-consults.com](http://platinum-consults.com)*