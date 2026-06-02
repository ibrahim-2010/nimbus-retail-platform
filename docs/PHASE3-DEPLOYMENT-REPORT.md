# Phase 3 Deployment – Issues, Challenges & Solutions Report

**Project:** NimbusRetail Platform – Operator Copilot (AI Agent)
**Phase:** 3 – Operator Copilot deployment to EKS
**Date:** 2026-06-02
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
model: claude-3-5-sonnet-latest — model not found
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

**Root Cause (initial diagnosis):**
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
# Output: pods listed correctly — confirmed K8s API works, problem is stdout
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
The EKS cluster's aws-auth ConfigMap only granted access to the IAM role used by the Jenkins server (the cluster creator). The local Windows user (`ibj2010`) was not in the access list.

**Solution:**
Rather than creating a new IAM role for the local user and updating aws-auth (which adds complexity and attack surface), all `kubectl` operations were run directly on the Jenkins server, which already has the correct IAM role. The Jenkins server is the authoritative operator for the cluster.

```bash
# SSH to Jenkins server, then run kubectl there
kubectl create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY=<key> \
  -n operator-copilot
```

---

## Issue 7 – audit-service ImagePullBackOff

**Component:** `nimbus-audit` ArgoCD application
**Symptom:** ArgoCD showed `nimbus-audit` as Degraded. The audit-service pod was in `ImagePullBackOff`.
**Error:**
```
Failed to pull image "022374769206.dkr.ecr.us-east-1.amazonaws.com/nimbus/audit-service:1":
  repository does not exist or may require 'docker login'
```

**Root Cause (two separate gaps):**

1. `audit-service` was missing from `local.nimbus_services` in `ecr.tf` — so no ECR repository had ever been created for it by Terraform.
2. `audit-service` was missing from the `SERVICE_NAME` choices parameter in `Jenkinsfile-Nimbus` — so no pipeline build had ever pushed an image.

**Solution:**

Added `audit-service` to both files:

`EKS-Terraform/ecr.tf`:
```hcl
nimbus_services = toset([
  "auth-service",
  "audit-service",   # added
  ...
])
```

`Jenkins-Pipeline-Code/Jenkinsfile-Nimbus`:
```groovy
choices: ['auth-service', 'audit-service', 'catalog-service', ...]
```

Then:
1. Ran the Infrastructure pipeline to apply the ECR repo creation via Terraform.
2. Triggered the Nimbus pipeline with `SERVICE_NAME=audit-service` to build and push the image.

---

## Issue 8 – GPU Node Group DEGRADED (Spot Capacity Exhausted)

**Component:** EKS `gpu-nodes` node group, `nimbus-ollama` ArgoCD application
**Symptom:** `nimbus-ollama` Degraded. Ollama pod stuck in `Pending` with repeated scheduling failure events.
**Error:**
```
Warning  FailedScheduling  0/2 nodes are available: 2 node(s) didn't match Pod's node affinity/selector.
```
```
AsgInstanceLaunchFailures: Could not launch Spot Instances.
UnfulfillableCapacity – Unable to fulfill capacity due to your request configuration.
```

**Root Cause:**
The `gpu-nodes` node group was configured with `capacity_type = "SPOT"` using `g4dn.xlarge`. AWS had no available spot capacity for this instance type in `us-east-1a` / `us-east-1b` at the time of the request.

**Attempted fix:** Changed `capacity_type` from `"SPOT"` to `"ON_DEMAND"` in Terraform and ran the infrastructure pipeline.

---

## Issue 9 – GPU Node Group CREATE_FAILED (vCPU Quota = 0)

**Component:** EKS `gpu-nodes` node group (continued from Issue 8)
**Symptom:** After switching to `ON_DEMAND`, the infrastructure pipeline failed.
**Error:**
```
Error: waiting for EKS Node Group (nimbus-cluster:gpu-nodes) create: unexpected state 'CREATE_FAILED'.
AsgInstanceLaunchFailures: VcpuLimitExceeded –
You have requested more vCPU capacity than your current vCPU limit of 0 allows
for the instance bucket that the specified instance type belongs to.
```

**Root Cause:**
AWS enforces per-account vCPU quotas by instance family. The G-series (GPU) instance quota on this AWS account is `0` — the default for new/student accounts. No G-series instance can launch (spot or on-demand) until a quota increase is approved.

`g4dn.xlarge` requires 4 vCPUs from the `Running On-Demand G and VT instances` quota.

**Resolution (in progress):**
1. Reverted `capacity_type` back to `"SPOT"` and set `gpu_node_desired_size = 0` to stop provisioning attempts and eliminate cost.
2. Submitted an AWS Service Quotas request to increase `Running On-Demand G and VT instances` to 4 vCPUs in `us-east-1`.
   ```bash
   aws service-quotas request-service-quota-increase \
     --service-code ec2 \
     --quota-code L-DB2E81BA \
     --desired-value 4 \
     --region us-east-1
   ```
3. Once approved, `gpu_node_desired_size` will be set back to `1` and the infrastructure pipeline re-run.

**Status:** Pending AWS approval (typically 4–24 hours).

---

## Summary Table

| # | Issue | Component | Root Cause | Resolution |
|---|-------|-----------|------------|------------|
| 1 | pydantic version conflict | Docker build | Overly strict pin vs mcp 1.2.0 requirement | Changed to `pydantic>=2.10.1` |
| 2 | ModuleNotFoundError: operator_copilot | Agent harness | Hardcoded relative path broke in container | Dynamic path probe for container vs local layout |
| 3 | Retired model ID | Anthropic API | `claude-3-5-sonnet-latest` retired | Updated to `claude-sonnet-4-6` |
| 4 | Tool calls hanging (event loop) | MCP server | Sync K8s client blocking asyncio loop | `run_in_executor` to offload sync calls |
| 5 | Tool calls hanging (stdout corruption) | MCP server | structlog writing to stdout, corrupting JSON-RPC stream | Redirected structlog to stderr |
| 6 | kubectl Unauthorized locally | Local workstation | Local IAM user not in EKS aws-auth | Run kubectl on Jenkins server (has cluster-creator role) |
| 7 | audit-service ImagePullBackOff | ArgoCD / ECR | Missing from ecr.tf and Jenkinsfile | Added to both; ran Terraform + Jenkins pipeline |
| 8 | GPU node DEGRADED – spot unavailable | EKS node group | g4dn.xlarge spot capacity exhausted in us-east-1 | Attempted switch to on-demand |
| 9 | GPU node CREATE_FAILED – vCPU quota | EKS node group | G-series vCPU quota = 0 on this account | Quota increase requested; GPU scaled to 0 pending approval |

---

## Current State (2026-06-02)

| Component | Status |
|-----------|--------|
| Operator Copilot agent | Working – diagnosing live cluster issues via Claude API |
| All services (auth, catalog, cart, order, notification) | Green in ArgoCD |
| audit-service | Green after ECR + Jenkinsfile fix and pipeline run |
| nimbus-ollama | Degraded – GPU node pending vCPU quota approval |
| GPU node group | Scaled to 0, quota increase submitted |

**Next action:** Once AWS approves the G-series vCPU quota, set `gpu_node_desired_size = 1` in `nimbus.tfvars`, run the infrastructure pipeline, and complete the Ollama demo recording.
