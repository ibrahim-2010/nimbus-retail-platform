# Cloud-Native EKS Project — Issues, Challenges & Solutions Report

> Documented across two full deployment cycles. Every issue below was encountered and resolved during the actual build — not hypothetical scenarios.

---

## Executive Summary

This report documents every issue encountered during two complete deployment cycles of a cloud-native three-tier application on AWS EKS. The project includes a React frontend, Node.js backend, PostgreSQL database, Redis cache, Jenkins CI/CD pipelines with SonarQube and Trivy security scanning, ArgoCD GitOps, and Prometheus/Grafana monitoring — all accessible via a custom domain (platinum-consults.com) through Route 53 and an Application Load Balancer.

A total of **13 distinct issues** were encountered and resolved. Each issue is documented with the exact error message, root cause analysis, investigation steps, solution, prevention strategy, and lesson learned.

### Issue Distribution by Category

| Category | Count | Issues |
|----------|-------|--------|
| IAM & Permissions | 4 | #1, #2, #7, #11 |
| CI/CD Pipeline | 3 | #3, #8, #9 |
| Kubernetes & Scheduling | 3 | #6, #12, #13 |
| GitOps & ArgoCD | 2 | #4, #5 |
| Tooling & Installation | 1 | #10 |

### Issue Distribution by Severity

| Severity | Count | Issues |
|----------|-------|--------|
| Critical — Blocks deployment entirely | 5 | #1, #5, #6, #11, #12 |
| High — Feature broken, workaround needed | 5 | #2, #3, #8, #9, #10 |
| Medium — Inconvenience, non-blocking | 3 | #4, #7, #13 |

---

## Issue #1: EKS Cluster Creation Denied — DescribeClusterVersions

**Category:** IAM & Permissions | **Severity:** Critical

**Error Message:**
```
User: arn:aws:sts::022374769206:assumed-role/jenkins-cloud-native-role/i-076e99b8c4cc5ee56 
is not authorized to perform: eks:DescribeClusterVersions on resource: 
arn:aws:eks:us-east-1:022374769206:* because no identity-based policy allows the 
eks:DescribeClusterVersions action
```

**Root Cause:** The Terraform-provisioned IAM role attached standard AWS managed policies (AmazonEKSClusterPolicy, AmazonEKSWorkerNodePolicy, etc.) but these managed policies do not include the newer `eks:DescribeClusterVersions` API action. AWS periodically adds new API actions that existing managed policies do not cover. The `AmazonEKSFullAccess` managed policy does not exist.

**Investigation:** First attempted to attach `AmazonEKSFullAccess` managed policy — received "Policy does not exist or is not attachable." Confirmed the managed policy name does not exist in AWS IAM. Pivoted to creating an inline policy with broad EKS permissions.

**Solution:** Created an inline IAM policy granting `eks:*` on all resources, attached directly to the Jenkins instance role.
```bash
aws iam put-role-policy \
  --role-name jenkins-cloud-native-role \
  --policy-name EKSFullAccess \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"eks:*","Resource":"*"}]}'
```

**Prevention:** Include the inline EKS policy in the Terraform `main.tf` as an `aws_iam_role_policy` resource so it is provisioned automatically with every deployment.

**Lesson Learned:** AWS managed policies are not comprehensive and lag behind new API actions. Always verify that managed policies cover the specific API calls your tools need. For EKS, an explicit `eks:*` inline policy is the most reliable approach.

---

## Issue #2: Instance Profile Credential Caching

**Category:** IAM & Permissions | **Severity:** High

**Error Message:** Same `eks:DescribeClusterVersions` error persisted after adding the inline policy and waiting 30+ seconds.

**Root Cause:** EC2 instances retrieve IAM credentials from the Instance Metadata Service (IMDS). These credentials are cached with a TTL and do not immediately reflect policy changes. The new inline policy was correctly attached (verified via `aws iam list-role-policies`) but the cached credentials on the instance had not expired yet.

**Investigation:** Ran `aws iam list-role-policies` and confirmed `EKSFullAccess` appeared. Waited 30 seconds, retried — same error. Concluded the IMDS was serving stale credentials.

**Solution:** Exported `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` as environment variables, which override the instance profile credentials entirely.
```bash
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
```

**Prevention:** Either wait for the IMDS credential cache to expire (can take up to 6 hours in worst case), or always use exported credentials for initial cluster creation. Alternatively, run eksctl from a local machine where credentials are not cached via IMDS.

**Lesson Learned:** Instance profile credential caching is an invisible delay that can waste significant debugging time. When IAM policy changes appear correct but aren't taking effect on EC2, the IMDS cache is the most likely culprit.

---

## Issue #3: Docker Build Failure — npm ci Requires package-lock.json

**Category:** CI/CD Pipeline | **Severity:** High

**Error Message:**
```
npm error: The `npm ci` command can only install with an existing package-lock.json or 
npm-shrinkwrap.json with lockfileVersion >= 1.
```

**Root Cause:** The backend Dockerfile used `RUN npm ci --only=production` which is a strict install command designed for CI environments. `npm ci` requires a `package-lock.json` file to exist in the project directory. The project scaffold was created with `package.json` only — `package-lock.json` was never generated because `npm install` was never run locally.

**Investigation:** The error was clear and immediate during `docker build`. Two options: generate a `package-lock.json` by running `npm install` locally, or change the Dockerfile to use `npm install` instead.

**Solution:** Modified the Dockerfile to use `npm install --omit=dev` instead of `npm ci`.
```bash
sed -i 's|npm ci --only=production|npm install --omit=dev|' Dockerfile
```

**Prevention:** For production projects, always run `npm install` locally to generate `package-lock.json` and commit it to the repository. This ensures deterministic builds with `npm ci`. For scaffold/portfolio projects, `npm install` is acceptable.

**Lesson Learned:** `npm ci` vs `npm install` is a common CI/CD gotcha. `npm ci` is faster and more reliable for production but requires the lock file. Always check if your Dockerfile commands match the files actually committed to the repo.

---

## Issue #4: ArgoCD Installation — CRD Annotations Too Long

**Category:** GitOps & ArgoCD | **Severity:** Medium

**Error Message:**
```
The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: 
metadata.annotations: Too long: may not be more than 262144 bytes
```

**Root Cause:** Newer versions of ArgoCD have CRD (Custom Resource Definition) manifests with annotations exceeding the 262144 byte Kubernetes limit for client-side apply. Standard `kubectl apply` tracks the entire manifest in a `last-applied-configuration` annotation, which exceeds this limit for ArgoCD's large CRDs.

**Investigation:** The initial `kubectl apply` failed with the size error. Retried with `--server-side` flag, which avoids the large annotation. This produced ownership conflict errors between `kubectl-client-side-apply` and the server-side manager.

**Solution:** Applied with both `--server-side` and `--force-conflicts` flags. Server-side apply uses a different tracking mechanism that doesn't store the full manifest in annotations.
```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts
```

**Prevention:** Always use `--server-side --force-conflicts` for ArgoCD installation. This should be the documented default, not a fallback.

**Lesson Learned:** As Kubernetes CRDs grow in complexity, client-side apply will increasingly fail. Server-side apply is the future direction and should be the default for large manifest installations.

---

## Issue #5: ArgoCD Overwrote Working Deployments with Placeholder Values

**Category:** GitOps & ArgoCD | **Severity:** Critical

**Error Message:** All application pods went to `InvalidImageName` status. `kubectl describe` showed pods trying to pull image `<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/backend:latest` — with the literal string `<ACCOUNT_ID>`.

**Root Cause:** The deployment manifests were updated locally on the Jenkins server (using `sed` to replace `<ACCOUNT_ID>` with the real account ID) but these changes were not pushed to Git. When ArgoCD was enabled with automatic sync, it compared the cluster state against Git (which still had placeholders) and "corrected" the cluster to match Git — replacing working image references with broken placeholders.

**Investigation:** Checked pod events with `kubectl describe` — saw `InvalidImageName`. Checked Git repo — confirmed manifests still had `<ACCOUNT_ID>`. This was the classic GitOps trap: Git is the source of truth, and ArgoCD enforces it ruthlessly.

**Solution:** Ran `sed` to fix the manifests, committed, and pushed to Git. ArgoCD then synced the correct values automatically.
```bash
sed -i 's|<ACCOUNT_ID>|022374769206|g' Kubernetes-Manifests-file/Backend/deployment.yaml
sed -i 's|<ACCOUNT_ID>|022374769206|g' Kubernetes-Manifests-file/Frontend/deployment.yaml
git add -A && git commit -m 'fix: set ECR paths' && git push origin main
```

**Prevention:** ALWAYS push manifest changes to Git BEFORE enabling ArgoCD sync. The order is: update manifests → push to Git → then create ArgoCD applications. Never rely on local `kubectl apply` when ArgoCD is managing the same resources.

**Lesson Learned:** This is the single most important GitOps lesson: Git is the source of truth. If Git is wrong, ArgoCD will make the cluster wrong too. There is no "temporary local override" in a GitOps workflow.

---

## Issue #6: Pods Stuck in Pending — t3.small ENI Pod Limit

**Category:** Kubernetes & Scheduling | **Severity:** Critical

**Error Message:**
```
Warning: FailedScheduling — 0/3 nodes are available: 3 Too many pods. 
no new claims to deallocate, preemption: 0/3 nodes are available: 
3 No preemption victims found for incoming pod.
```

**Root Cause:** AWS EC2 instances have a maximum number of pods determined by their Elastic Network Interface (ENI) capacity. t3.small supports only 3 ENIs with 4 IPv4 addresses each, yielding a maximum of 11 pods per node. With 3 nodes, the total cluster capacity was 33 pods. System pods (kube-proxy, CoreDNS, VPC CNI, aws-node) consumed ~10 slots. The application (4 pods), ArgoCD (7 pods), and monitoring stack (7+ pods) exceeded the remaining 23 slots.

**Investigation:** `kubectl describe pod` showed "Too many pods" — not insufficient memory or CPU. This pointed to the ENI pod limit, not a resource issue. Checked instance type ENI limits in AWS documentation.

**Solution:**
- **Deployment 1 (workaround):** Reduced application replicas to 1, scaled down non-essential ArgoCD components (dex, notifications, applicationset-controller).
- **Deployment 2 (permanent fix):** Upgraded worker nodes to t3.xlarge which supports 58 pods per node.

```bash
# Deployment 1 workaround:
kubectl scale deployment argocd-dex-server -n argocd --replicas=0
kubectl scale deployment argocd-notifications-controller -n argocd --replicas=0

# Deployment 2 permanent fix:
eksctl create cluster ... --node-type t3.xlarge ...
```

**Prevention:** Choose instance types based on pod capacity (ENI limits), not just CPU/RAM. For clusters running app workloads + ArgoCD + monitoring, t3.xlarge (58 pods/node) is the minimum practical choice.

**Lesson Learned:** Kubernetes scheduling considers CPU, memory, AND pod count. Pod count is often the first limit hit on smaller instances. The "Too many pods" error is distinct from resource exhaustion and requires a different solution (bigger instance type, not more memory).

---

## Issue #7: Cannot Scale to 4 Worker Nodes — vCPU Quota

**Category:** IAM & Permissions | **Severity:** Medium

**Error Message:**
```
Could not launch On-Demand Instances. VcpuLimitExceeded — You have requested more vCPU 
capacity than your current vCPU limit of 8 allows for the instance bucket that the 
specified instance type belongs to.
```

**Root Cause:** AWS accounts have default vCPU limits per instance family. The account had a limit of 8 vCPUs for standard instances. 3 EKS nodes (3 × 2 vCPU = 6) plus the Jenkins server (2 vCPU) = 8 vCPUs, hitting the ceiling exactly.

**Investigation:** `eksctl scale nodegroup` succeeded but the node never appeared. Checked `aws autoscaling describe-scaling-activities` which showed the `VcpuLimitExceeded` error. The nodegroup status showed `DEGRADED`.

**Solution:** Requested a vCPU quota increase to 20 via AWS Service Quotas.
```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 20 \
  --region us-east-1
```

**Prevention:** Request vCPU quota increases as a prerequisite BEFORE starting infrastructure provisioning. Small increases (8 → 20) are usually approved within 15-30 minutes.

**Lesson Learned:** AWS default quotas are designed for new accounts and are intentionally conservative. Any production or portfolio project will likely hit these limits. Always check quotas before planning infrastructure.

---

## Issue #8: Jenkins Quality Gate Timeout

**Category:** CI/CD Pipeline | **Severity:** High

**Error Message:**
```
Timeout has been exceeded — Checking status of SonarQube task ... status is 'IN_PROGRESS'. 
Cancelling nested steps due to timeout.
```

**Root Cause:** The Jenkins pipeline's Quality Gate stage uses `waitForQualityGate()` which polls SonarQube for the analysis result. However, SonarQube notifies Jenkins via a webhook callback — it does not respond to polling. Without the webhook configured, SonarQube completed the analysis but had no way to tell Jenkins, so Jenkins waited until the 2-minute timeout expired.

**Investigation:** The SonarQube Analysis stage succeeded (logs showed "ANALYSIS SUCCESSFUL"). The next stage (Quality Gate) started polling but the status remained "IN_PROGRESS" until timeout. This indicated a notification mechanism issue, not an analysis failure.

**Solution:** Created a webhook in SonarQube pointing to Jenkins' SonarQube webhook endpoint.
```
SonarQube: Administration > Configuration > Webhooks > Create
Name: jenkins
URL: http://localhost:8080/sonarqube-webhook/
```

**Prevention:** Add webhook creation to the Jenkins configuration phase documentation. This step is easy to miss because SonarQube analysis works fine without it — only the Quality Gate stage fails.

**Lesson Learned:** The SonarQube-Jenkins integration has two parts: the Jenkins plugin calls SonarQube for analysis, and SonarQube calls Jenkins back with the result. Both directions must be configured. The webhook is the return path that is often forgotten.

---

## Issue #9: Jenkins SCM Credential Dropdown Empty

**Category:** CI/CD Pipeline | **Severity:** High

**Error Message:** When creating a Pipeline job with "Pipeline script from SCM", the Credentials dropdown showed no options despite having the `github-token` credential configured.

**Root Cause:** The `github-token` credential was created as "Secret text" type. Jenkins SCM (Source Code Management) integration requires "Username with password" type credentials to authenticate with Git repositories. "Secret text" credentials are designed for use within pipeline scripts (e.g., `credentials('github-token')`) and are not compatible with the SCM plugin's authentication mechanism.

**Investigation:** Clicked the Credentials dropdown in the Pipeline SCM configuration — empty. Checked Manage Jenkins → Credentials — `github-token` existed as Secret text. Researched Jenkins credential types and confirmed SCM requires Username with password.

**Solution:** Created a new credential (ID: `github-creds`) with Kind set to "Username with password."
```
Manage Jenkins > Credentials > System > Global > Add Credentials
Kind: Username with password
Username: ibrahim-2010
Password: <GitHub PAT>
ID: github-creds
```

**Prevention:** Document both credential types clearly: `github-creds` (Username with password) for SCM checkout, `github-token` (Secret text) for pipeline git push operations. Both are needed and serve different purposes.

**Lesson Learned:** Jenkins has multiple credential types for different contexts. SCM plugins use Username/Password; pipeline scripts can use Secret text. Using the wrong type produces silent failures (empty dropdowns) rather than error messages.

---

## Issue #10: sonar-scanner Not Found in Jenkins Pipeline

**Category:** Tooling & Installation | **Severity:** High

**Error Message:**
```
/var/lib/jenkins/workspace/three-tier-****/.../script.sh.copy: 2: sonar-scanner: not found
```

**Root Cause:** The `tools-install.sh` user data script included sonar-scanner installation steps (wget, unzip, mv to `/opt/sonar-scanner`, symlink). However, the download or extraction failed silently during EC2 boot. User data scripts run as a fire-and-forget process — individual command failures do not stop subsequent commands or generate user-visible alerts.

**Investigation:** Ran `which sonar-scanner` — command not found. Checked `/opt/sonar-scanner` — directory did not exist. Checked `/usr/local/bin/sonar-scanner` — dangling symlink pointing to non-existent target. Confirmed the wget/unzip step had failed silently during boot.

**Solution:** Manually downloaded, extracted, and installed sonar-scanner.
```bash
cd /tmp
wget -q https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
unzip -o sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
sonar-scanner --version
```

**Prevention:** Add a verification step in the deployment guide: after SSH-ing into the Jenkins server, run all version checks (jenkins, docker, terraform, kubectl, eksctl, helm, trivy, sonar-scanner) and install anything missing before proceeding.

**Lesson Learned:** User data scripts are unreliable for complex installations. Always verify tool availability after server boot. Consider using configuration management (Ansible) or building a custom AMI with all tools pre-installed.

---

## Issue #11: ALB Not Provisioning — Missing IAM Permissions for LB Controller

**Category:** IAM & Permissions | **Severity:** Critical

**Error Message:** Two errors in sequence:
```
1) elasticloadbalancing:DescribeListenerAttributes access denied
2) ec2:DescribeSecurityGroups unauthorized operation
```

**Root Cause:** The AWS Load Balancer Controller IAM policy was downloaded from the v2.7.1 release of the kubernetes-sigs repository. However, the Helm chart installed a newer version of the controller binary that calls API actions not present in the v2.7.1 policy (`DescribeListenerAttributes` was added in later AWS API versions). Additionally, the policy lacked EC2 security group permissions needed for backend SG auto-creation.

**Investigation:** `kubectl get ingress` showed no ADDRESS for several minutes. Checked controller logs (`kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller`) which showed the exact permission errors. First fix (adding `elasticloadbalancing:*` only) revealed the second missing permission (`ec2:DescribeSecurityGroups`).

**Solution:** Created a new policy version with comprehensive permissions.
```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Action":["elasticloadbalancing:*","ec2:Describe*",
    "ec2:AuthorizeSecurityGroupIngress","ec2:RevokeSecurityGroupIngress",
    "ec2:CreateSecurityGroup","ec2:DeleteSecurityGroup",
    "ec2:CreateTags","ec2:DeleteTags","iam:CreateServiceLinkedRole",
    "acm:ListCertificates","acm:DescribeCertificate",
    "wafv2:*","waf-regional:*","shield:*",
    "tag:GetResources","tag:TagResources"],
    "Resource":"*"}]}' --set-as-default

kubectl rollout restart deployment aws-load-balancer-controller -n kube-system
```

**Prevention:** Immediately after creating the initial policy from the downloaded JSON, create a policy version with broader permissions. Do not rely on the downloaded policy being complete.

**Lesson Learned:** IAM policy version mismatches between the documented policy and the actual software version are a recurring AWS pattern. The controller evolves faster than the policy documentation. Broader permissions (`elasticloadbalancing:*`, `ec2:Describe*`) are safer than trying to enumerate individual actions.

---

## Issue #12: ImagePullBackOff After Redeployment

**Category:** Kubernetes & Scheduling | **Severity:** Critical

**Error Message:**
```
Failed to pull image "022374769206.dkr.ecr.us-east-1.amazonaws.com/backend:3": not found
```

**Root Cause:** After tearing down and rebuilding the infrastructure, the deployment manifests in Git still referenced image tags from previous Jenkins builds (`:2` for frontend, `:3` for backend). The new ECR repositories were empty — only tag `:1` existed from the fresh manual bootstrap build. The `sed` command that replaced `<ACCOUNT_ID>` did not touch the image tag number.

**Investigation:** `kubectl describe pod` showed "Failed to pull image" with a specific tag number. Ran `grep` on the manifest to confirm the tag. Checked ECR repos to see which tags actually existed.

**Solution:** Used `sed` with a regex pattern to replace any numeric tag with `:1`.
```bash
sed -i 's|backend:[0-9]*|backend:1|' Kubernetes-Manifests-file/Backend/deployment.yaml
sed -i 's|frontend:[0-9]*|frontend:1|' Kubernetes-Manifests-file/Frontend/deployment.yaml
kubectl apply -f Kubernetes-Manifests-file/Backend/
kubectl apply -f Kubernetes-Manifests-file/Frontend/
git add -A && git commit -m 'fix: correct image tags' && git push origin main
```

**Prevention:** When redeploying from scratch, always check both the account ID AND the image tag in deployment manifests. Use a sed command that handles any existing tag rather than targeting a specific one.

**Lesson Learned:** Teardown and rebuild cycles require careful state management. Git retains the state from the last deployment, but AWS resources (ECR images) start fresh. The manifest-to-registry mismatch is inevitable unless you either keep ECR repos between cycles or reset the manifests.

---

## Issue #13: Ingress ADDRESS Empty After Apply

**Category:** Kubernetes & Scheduling | **Severity:** Medium

**Error Message:** `kubectl get ingress` showed the ingress resource existed but the ADDRESS column remained empty for over 5 minutes.

**Root Cause:** The Ingress resource was created (`kubectl apply`) before the AWS Load Balancer Controller was installed. Without the controller running, no component was watching for Ingress resources to reconcile. When the controller was later installed, it did not automatically reconcile pre-existing Ingress resources.

**Investigation:** Checked `kubectl get ingress` — no ADDRESS. Checked controller pods — they were running. Checked controller logs — no errors, but also no reconciliation activity for the existing ingress.

**Solution:** Deleted the existing ingress and reapplied it.
```bash
kubectl delete ingress cloud-native-ingress -n three-tier
kubectl apply -f Kubernetes-Manifests-file/ingress.yaml
# Wait 1-2 minutes
kubectl get ingress -n three-tier
```

**Prevention:** Always install the ALB Controller BEFORE applying any Ingress resources. The correct order is: install controller → verify controller pods are running → apply ingress.

**Lesson Learned:** Kubernetes controllers use a watch/reconcile pattern. They reconcile resources that are created or modified after the controller starts. Pre-existing resources may not be detected. When in doubt, delete and reapply the resource after the controller is running.

---

## Summary & Key Takeaways

### Top 5 Lessons for Cloud-Native Deployments

**1. IAM is the #1 source of deployment failures.** Four of thirteen issues (31%) were IAM-related. AWS managed policies lag behind API changes, credential caching creates invisible delays, and different components (EC2 instance profile vs. Kubernetes service account) use separate IAM roles. Always verify permissions with the actual API calls your tools make, not just the policy names.

**2. GitOps means Git is the source of truth — no exceptions.** ArgoCD enforces Git state ruthlessly. Any manual kubectl changes will be reverted. Any placeholder values in Git will be applied to the cluster. The deployment workflow must be: change Git first, then let ArgoCD sync.

**3. Instance type selection is about pod capacity, not just CPU/RAM.** t3.small's 11-pod ENI limit was the binding constraint, not memory. Kubernetes scheduling considers CPU, memory, AND pod count. Always check ENI pod limits before selecting instance types for EKS.

**4. User data scripts fail silently.** EC2 user data runs at boot with no interactive feedback. Individual command failures don't stop the script. Always SSH in and verify every tool is installed before proceeding with the deployment.

**5. Version mismatches between documentation and software are inevitable.** The ALB Controller IAM policy (v2.7.1 docs) didn't match the actual controller binary (newer). The ArgoCD CRDs outgrew kubectl's client-side apply. Always plan for the documentation to be slightly behind the software.

---

*Ibrahim | [github.com/ibrahim-2010/cloud-native-eks](https://github.com/ibrahim-2010/cloud-native-eks) | [platinum-consults.com](http://platinum-consults.com)*
