# Phase 3 Deployment – Issues, Challenges & Solutions Report

**Project:** NimbusRetail Platform – Operator Copilot (AI Agent)
**Phase:** 3 – Operator Copilot deployment to EKS
**Last Updated:** 2026-06-05
**Environment:** EKS (nimbus-cluster, us-east-1), ECR, ArgoCD, Jenkins CI/CD

---

## Overview

Phase 3 introduced an AI-powered operator copilot – an MCP (Model Context Protocol) server exposing Kubernetes diagnostic tools, wired to an Anthropic Claude LLM via an agent harness. The agent was containerised, pushed to ECR, and deployed to the EKS cluster via ArgoCD. This report documents every issue encountered during deployment, its root cause, and how it was resolved.

---

## Issue 1 – Dependency Conflict: pydantic Version

**Component:** `operator-copilot` Docker image build
**Symptom:** `pip install` failed during `docker build` with a resolver conflict.
**Error:**
```
mcp 1.2.0 requires pydantic>=2.10.1, but you have pydantic 2.9.2 which is incompatible.
```

**Root Cause:**
`requirements.txt` pinned `pydantic==2.9.2`. The `mcp` library version 1.2.0 raised its minimum pydantic requirement to `>=2.10.1` in a patch release, making the pin too strict.

**Solution:**
Changed the pin to a minimum-version constraint:
```diff
- pydantic==2.9.2
+ pydantic>=2.10.1
```

**File:** `mcp-server/requirements.txt`

---

## Issue 2 – ModuleNotFoundError: operator_copilot

**Component:** Agent harness spawning the MCP server subprocess
**Symptom:** The MCP server process exited immediately with:
```
ModuleNotFoundError: No module named 'operator_copilot'
```

**Root Cause:**
`StdioServerParameters` was constructed with `cwd="../mcp-server/src"`. In the container, the working directory resolved to `/mcp-server/src` (which does not exist). The container layout places the module at `/app/src/operator_copilot/`, so the relative path assumption broke at runtime.

**Solution:**
Replaced the hardcoded relative path with a dynamic probe that checks both possible layouts:
```python
_candidates = [
    Path(__file__).parent.parent / "src",          # container: /app/src
    Path(__file__).parent.parent / "mcp-server" / "src",  # local checkout
]
_mcp_src = next((p for p in _candidates if p.exists()), None)
server_params = StdioServerParameters(
    command="python",
    args=["-m", "operator_copilot"],
    cwd=str(_mcp_src) if _mcp_src else None,
    env={**os.environ, "PYTHONPATH": str(_mcp_src)} if _mcp_src else None,
)
```

**File:** `examples/example_agent.py`

---

## Issue 3 – Retired Model ID

**Component:** Anthropic API call in agent harness
**Symptom:** API returned a 404/not-found error on startup.
**Error:**
```
model: claude-3-5-sonnet-latest – model not found
```

**Root Cause:**
The starter code referenced `claude-3-5-sonnet-latest`, which had been retired from the Anthropic API by the time of deployment.

**Solution:**
Updated the model ID to the current active model:
```diff
- model="claude-3-5-sonnet-latest",
+ model="claude-sonnet-4-6",
```

**File:** `examples/example_agent.py`

---

## Issue 4 – Tool Calls Hanging (Event Loop Blocking)

**Component:** MCP server `call_tool` handler
**Symptom:** Agent called a tool (e.g. `list_pods`); no response was returned; the agent hung indefinitely.

**Root Cause:**
The Kubernetes Python client is synchronous. Calling it directly inside an `async` function blocks the asyncio event loop, preventing the MCP server from writing the JSON-RPC response back to stdout.

**Solution:**
Wrapped all Kubernetes dispatch calls with `run_in_executor` to offload to a thread pool, freeing the event loop:
```python
loop = asyncio.get_running_loop()
result = await loop.run_in_executor(
    None, lambda: asyncio.run(dispatch[name](**arguments))
)
```

**Note:** This fixed the event loop blocking, but tool calls still hung. See Issue 5 for the true root cause.

**File:** `mcp-server/src/operator_copilot/__init__.py`

---

## Issue 5 – stdout Corruption: structlog Writing to MCP Protocol Stream

**Component:** MCP server logging configuration
**Symptom:** Even after the `run_in_executor` fix, tool calls returned no data to the agent. A direct `kubectl exec` test proved the Kubernetes API calls themselves were working fine inside the pod.

**Root Cause (confirmed):**
`structlog` defaults to writing to `stdout`. The MCP protocol is stdio-based – the server communicates exclusively via JSON-RPC messages on stdout. Every time the server logged an audit entry, the JSON log line was injected into the protocol stream, corrupting the response frame. The MCP client received malformed JSON and silently discarded it.

**Diagnosis method:**
```bash
kubectl exec -n operator-copilot <pod> -- python3 -c "
import asyncio
from operator_copilot.tools.k8s import list_pods
print(asyncio.run(list_pods()))
"
# Output: pods listed correctly – confirmed K8s API works, problem is stdout
```

**Solution:**
Redirected structlog output to stderr, leaving stdout exclusively for the MCP protocol:
```python
import sys
structlog.configure(
    processors=[structlog.processors.JSONRenderer()],
    logger_factory=structlog.PrintLoggerFactory(sys.stderr),
)
```

**File:** `mcp-server/src/operator_copilot/__init__.py`

**Key lesson:** Any library that writes to stdout will silently break an stdio-based protocol. Audit all dependencies for default output destinations before deploying an MCP server.

---

## Issue 6 – kubectl Unauthorized on Local Machine

**Component:** Local developer workstation kubectl access
**Symptom:** Running `kubectl create secret` locally returned:
```
error: You must be logged in to the server (Unauthorized)
```

**Root Cause:**
The EKS cluster's aws-auth ConfigMap only granted access to the IAM role used by the Jenkins server (the cluster creator). The local Windows user was not in the access list.

**Solution:**
All `kubectl` operations were run directly on the Jenkins server, which already has the correct IAM role. The Jenkins server is the authoritative operator for the cluster.

```bash
# SSH to Jenkins server, then run kubectl there
kubectl create secret generic operator-copilot-secrets \
  --from-literal=ANTHROPIC_API_KEY=<key> \
  -n operator-copilot
```

---

## Issue 7 – audit-service ECR Repository and Pipeline Missing

**Component:** `nimbus-audit` ArgoCD application
**Symptom:** ArgoCD showed `nimbus-audit` as Degraded. The audit-service pod was in `ImagePullBackOff`.
**Error:**
```
Failed to pull image "022374769206.dkr.ecr.us-east-1.amazonaws.com/nimbus/audit-service:1":
  repository does not exist or may require 'docker login'
```

**Root Cause:**
`audit-service` was missing from `local.nimbus_services` in `ecr.tf` so no ECR repository was ever created by Terraform.

**Solution:**
Added `audit-service` to `ecr.tf`:
```hcl
nimbus_services = toset([
  "auth-service",
  "audit-service",   # added
  ...
])
```

Ran the Infrastructure pipeline to create the ECR repository.

---

## Issue 8 – GPU Node Group DEGRADED (Spot Capacity Exhausted)

**Component:** EKS `gpu-nodes` node group, `nimbus-ollama` ArgoCD application
**Symptom:** `nimbus-ollama` Degraded. Ollama pod stuck in `Pending`.
**Error:**
```
AsgInstanceLaunchFailures: Could not launch Spot Instances.
UnfulfillableCapacity – Unable to fulfill capacity due to your request configuration.
```

**Root Cause:**
`capacity_type = "SPOT"` with `g4dn.xlarge` – AWS had no available spot capacity for this instance type in `us-east-1a` / `us-east-1b`.

**Resolution:**
Set `gpu_node_desired_size = 0` to stop provisioning attempts. Submitted AWS Service Quotas increase request for `Running On-Demand G and VT instances` (quota code `L-DB2E81BA`) to 4 vCPUs, then changed `capacity_type` to `"ON_DEMAND"`.

---

## Issue 9 – GPU Node Group CREATE_FAILED (vCPU Quota = 0)

**Component:** EKS `gpu-nodes` node group
**Symptom:** After switching to `ON_DEMAND`, infrastructure pipeline failed.
**Error:**
```
Error: waiting for EKS Node Group (nimbus-cluster:gpu-nodes) create: unexpected state 'CREATE_FAILED'.
VcpuLimitExceeded – current vCPU limit of 0 for G and VT instance bucket.
```

**Root Cause:**
G-series vCPU on-demand quota was 0 on this account (default for new accounts). Spot and on-demand quotas are tracked separately – the initial approval was for on-demand, so the SPOT node group still hit `MaxSpotInstanceCountExceeded`.

**Resolution:**
1. Escalated to AWS support (initial automatic rejection, appealed with use case detail).
2. On-demand quota approved at 4 vCPUs.
3. Changed `capacity_type = "ON_DEMAND"` in `gpu-node-group.tf`.
4. Manually deleted the CREATE_FAILED node group via AWS CLI before re-running Terraform:
   ```bash
   aws eks delete-nodegroup \
     --cluster-name nimbus-cluster \
     --nodegroup-name gpu-nodes \
     --region us-east-1
   ```

---

## Issue 10 – nvidia-device-plugin DaemonSet DESIRED=0 (Attempt 1)

**Component:** `helm_release.nvidia_device_plugin` in `gpu-node-group.tf`
**Symptom:** After GPU node joined the cluster, `kubectl get ds nvidia-device-plugin -n kube-system` showed `DESIRED=0`. Ollama pod stayed `Pending` with `Insufficient nvidia.com/gpu`.

**Root Cause:**
Chart version 0.17.0 requires Node Feature Discovery (NFD) labels by default. The DaemonSet pod spec contains a `nodeAffinity` requiring one of:
- `feature.node.kubernetes.io/pci-10de.present=true`
- `feature.node.kubernetes.io/cpu-model.vendor_id=NVIDIA`
- `nvidia.com/gpu.present=true`

NFD is not deployed in this cluster, so none of these labels exist on the GPU node.

**First fix (partial – see Issue 12 for full resolution):**
Added `affineToTaintsAndTolerations = false` to the Helm values in `gpu-node-group.tf`, believing this would suppress the NFD nodeAffinity. It did not – this parameter only controls affinity auto-generated from the tolerations list, not the hardcoded NFD affinity in the chart template.

**Immediate workaround applied:**
```bash
kubectl label node <gpu-node> feature.node.kubernetes.io/pci-10de.present=true
```

---

## Issue 11 – operator-copilot ECR Repository Missing from Terraform

**Component:** `EKS-Terraform/ecr.tf`
**Symptom:** After cluster destroy and redeploy, the operator-copilot pod went into `ImagePullBackOff`. The ECR repository `operator-copilot` no longer existed.

**Root Cause:**
`destroy.sh` Phase 10 explicitly deletes the `operator-copilot` ECR repository. The repository was originally created manually – it was never in Terraform. After every destroy+redeploy cycle, the repo was gone and image pushes failed.

**Solution:**
Added `aws_ecr_repository.operator_copilot` and `aws_ecr_lifecycle_policy.operator_copilot` to `ecr.tf`. The repository is now created automatically by the Infrastructure pipeline on every fresh deployment.

**File:** `EKS-Terraform/ecr.tf`

---

## Issue 12 – nvidia-device-plugin DaemonSet DESIRED=0 (Attempt 2 – Permanent Fix)

**Component:** `helm_release.nvidia_device_plugin` in `gpu-node-group.tf`
**Symptom:** After cluster rebuild, `DESIRED=0` persisted despite `affineToTaintsAndTolerations = false` already committed. Inspecting the live DaemonSet confirmed the NFD affinity was still present:
```bash
kubectl get ds nvidia-device-plugin -n kube-system \
  -o jsonpath='{.spec.template.spec.affinity}' | python3 -m json.tool
# Output showed: feature.node.kubernetes.io/pci-10de.present, cpu-model.vendor_id=NVIDIA, nvidia.com/gpu.present
```

**Root Cause (confirmed):**
`affineToTaintsAndTolerations = false` only suppresses affinity auto-generated from the tolerations list. Chart 0.17.0 always injects NFD-based `nodeAffinity` via a separate template path that this flag does not control.

**Permanent fix:**
Replaced `affineToTaintsAndTolerations = false` approach with an explicit `affinity` override in the Helm values that pins scheduling to `workload=gpu` nodes, completely replacing the chart's generated affinity:
```hcl
affinity = {
  nodeAffinity = {
    requiredDuringSchedulingIgnoredDuringExecution = {
      nodeSelectorTerms = [{
        matchExpressions = [{
          key      = "workload"
          operator = "In"
          values   = ["gpu"]
        }]
      }]
    }
  }
}
```

**File:** `EKS-Terraform/gpu-node-group.tf`

---

## Issue 13 – destroy.sh Missing Terraform State rm for Phase 3 Namespaces

**Component:** `destroy.sh` Phase 9
**Symptom:** `terraform destroy` produced errors for `kubernetes_namespace.ai` and `kubernetes_namespace.operator_copilot` – both were already deleted in Phase 6 but still in Terraform state.

**Root Cause:**
Phase 9 removed state for `monitoring`, `argocd`, `kafka`, and `nimbus` namespaces before running `terraform destroy`, but `ai` and `operator_copilot` (both added in Phase 3) were omitted from the `terraform state rm` block.

**Solution:**
Added both to the Phase 9 state removal block in `destroy.sh`:
```bash
terraform state rm kubernetes_namespace.ai               2>/dev/null || true
terraform state rm kubernetes_namespace.operator_copilot 2>/dev/null || true
```

**File:** `destroy.sh`

---

## Issue 14 – operator-copilot Namespace Missing When Creating Kubernetes Secret

**Component:** `operator-copilot` namespace, `operator-copilot-secrets` secret
**Symptom:** `kubectl create secret` failed immediately with:
```
error: failed to create secret unknown (post secrets)
```

**Root Cause:**
The `operator-copilot` namespace had not been created yet at the time the secret creation was attempted. The Terraform-managed namespace resource exists in `namespaces.tf`, but Terraform must complete its apply before the namespace is available. The error message "unknown (post secrets)" is Kubernetes's way of reporting a missing namespace – it is not related to the secret value itself.

**Solution:**
Verify the namespace exists before creating the secret:
```bash
kubectl get ns operator-copilot   # confirm it exists first
kubectl create secret generic operator-copilot-secrets \
  -n operator-copilot \
  --from-literal=ANTHROPIC_API_KEY=<key>
```

If the namespace is missing, create it manually or wait for the Infrastructure pipeline to complete.

---

## Issue 15 – audit-service Source Code Missing from nimbus-retail-starter

**Component:** `nimbus-retail-starter` repository, `nimbus-audit-service` Jenkins job
**Symptom:** `nimbus-retail-starter/services/audit-service` does not exist. The Jenkins Nimbus pipeline fails at the `Checkout App Code` and `SonarQube Analysis` stages because the service directory is not present.

**Root Cause:**
`audit-service` was added as a Phase 3 Helm deployment (`values-audit.yaml`) and ECR repository, but its application source code was never added to the `nimbus-retail-starter` repository.

**Immediate workaround (for demo):**
Built a minimal Node.js Express service directly on the Jenkins server that satisfies the health check endpoints (`/healthz`, `/readyz`) and Prometheus metrics endpoint (`/metrics`), then pushed it manually to ECR with tag `1` (matching the pinned tag in `values-audit.yaml`).

**Permanent fix required:**
Add a full `audit-service` implementation to `nimbus-retail-starter/services/audit-service/` – a Kafka consumer that processes audit events published by the operator-copilot, with proper `/healthz`, `/readyz`, and `/metrics` endpoints.

---

## Issue 16 – nimbus-audit-service Job Missing from JCasC

**Component:** `Jenkins-Server-TF/jcasc/jenkins.yaml`
**Symptom:** Jenkins had no `nimbus-audit-service` pipeline job. When `audit-service` needed to be built, there was no automated job to trigger.

**Root Cause:**
When `audit-service` was added to Phase 3, the corresponding JCasC job definition was not added to `jenkins.yaml`. The `setup-jcasc.sh` script downloads `jenkins.yaml` from GitHub on every Jenkins setup – so the missing job was propagated to every fresh Jenkins deployment.

**Solution:**
Added `nimbus-audit-service` pipeline job to `jenkins.yaml` following the same pattern as the other five service jobs, with `audit-service` as the default `SERVICE_NAME` parameter.

**Files:** `Jenkins-Server-TF/jcasc/jenkins.yaml`, `Jenkins-Server-TF/jcasc/setup-jcasc.sh`

---

## Summary Table

| # | Issue | Component | Root Cause | Resolution |
|---|-------|-----------|------------|------------|
| 1 | pydantic version conflict | Docker build | Strict pin vs mcp 1.2.0 requirement | Changed to `pydantic>=2.10.1` |
| 2 | ModuleNotFoundError: operator_copilot | Agent harness | Hardcoded relative path broke in container | Dynamic path probe |
| 3 | Retired model ID | Anthropic API | `claude-3-5-sonnet-latest` retired | Updated to `claude-sonnet-4-6` |
| 4 | Tool calls hanging (event loop) | MCP server | Sync K8s client blocking asyncio | `run_in_executor` to offload sync calls |
| 5 | Tool calls hanging (stdout corruption) | MCP server | structlog writing to stdout, corrupting JSON-RPC | Redirected structlog to stderr |
| 6 | kubectl Unauthorized locally | Local workstation | Local IAM user not in EKS aws-auth | Run kubectl on Jenkins server |
| 7 | audit-service ImagePullBackOff | ArgoCD / ECR | Missing from ecr.tf | Added to ecr.tf; ran Infrastructure pipeline |
| 8 | GPU node DEGRADED – spot unavailable | EKS node group | g4dn.xlarge spot capacity exhausted | Switched to ON_DEMAND; submitted quota increase |
| 9 | GPU node CREATE_FAILED – vCPU quota | EKS node group | G-series vCPU quota = 0; spot/on-demand quotas are separate | AWS quota approved; deleted CREATE_FAILED group via CLI; re-ran pipeline |
| 10 | nvidia-device-plugin DESIRED=0 (attempt 1) | Helm / DaemonSet | NFD labels absent; `affineToTaintsAndTolerations=false` ineffective | Manual node label as workaround |
| 11 | operator-copilot ECR repo lost on redeploy | Terraform / ECR | Repo created manually, not in Terraform; deleted by destroy.sh | Added to ecr.tf |
| 12 | nvidia-device-plugin DESIRED=0 (permanent fix) | Helm / DaemonSet | Chart 0.17.0 injects NFD affinity regardless of `affineToTaintsAndTolerations` | Explicit `affinity` override in Helm values pinned to `workload=gpu` |
| 13 | destroy.sh Terraform state rm incomplete | destroy.sh | `ai` and `operator_copilot` namespaces missing from Phase 9 state rm | Added both to state rm block |
| 14 | Secret creation failed (namespace missing) | Kubernetes | Namespace not yet created when secret was attempted | Verify namespace exists before `kubectl create secret` |
| 15 | audit-service source code missing | nimbus-retail-starter | Service added to platform but not to app repo | Built minimal Node.js placeholder for demo; permanent implementation pending |
| 16 | nimbus-audit-service job missing from JCasC | Jenkins / JCasC | Job not added to jenkins.yaml when audit-service was introduced | Added job definition to jenkins.yaml |

---

## Current State (2026-06-05)

| Component | Status |
|-----------|--------|
| All 15 ArgoCD applications | Synced / Healthy |
| auth, catalog, cart, order, notification services | Green |
| audit-service | Green (minimal placeholder image, tag 1) |
| operator-copilot AI agent | Green – running, API key injected via secret |
| Ollama (self-hosted LLM) | Green – Tesla T4 detected, CUDA v12, 14.6 GiB VRAM |
| GPU node (g4dn.xlarge ON_DEMAND) | Ready, `nvidia.com/gpu=1` registered |
| nvidia-device-plugin DaemonSet | DESIRED=1, READY=1 |
| Observability (Prometheus, Grafana, Loki, Tempo) | Green |
| Security (Kyverno, ESO) | Green |

**Platform is fully deployed and demo-ready.**

**Remaining known gap:** `audit-service` has no source code in `nimbus-retail-starter`. The Jenkins `nimbus-audit-service` pipeline job exists but will fail at the SonarQube stage until a proper implementation is added to the app repository.
