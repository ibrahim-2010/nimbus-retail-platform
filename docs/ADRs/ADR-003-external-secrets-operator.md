# ADR-003: External Secrets Operator over Sealed Secrets for Secret Management

**Status:** Accepted  
**Date:** 2026-05-18  
**Deciders:** Platform team  

---

## Context

The Nimbus services require sensitive configuration: `JWT_SECRET`, `DATABASE_URL` (with embedded password), and `REDIS_URL`. These must reach pods as Kubernetes Secrets without appearing as plaintext in Git or shell history. Three options were evaluated:

| Option | Description |
|---|---|
| A | `kubectl create secret` – manual, run once per deployment |
| B | Sealed Secrets – encrypted secrets committed to Git |
| C | External Secrets Operator (ESO) + AWS Secrets Manager |

Option A was used as a starting point in Phase 3 and ruled out immediately – values entered on the command line appear in shell history, cannot be rotated without re-running commands, and are not recoverable if the cluster is destroyed. It is not a serious production option and is not compared further.

The real decision is **B vs C**.

---

## Decision

**Option C** – ESO with AWS Secrets Manager, using IRSA for authentication.

---

## Honest Trade-off Analysis

### The case FOR Sealed Secrets (rejected option)

Sealed Secrets is a legitimate, widely-deployed production approach used at many companies. The workflow is simple: run `kubeseal` to encrypt a secret with the cluster's public key, commit the encrypted blob to Git, and the Sealed Secrets controller decrypts it at runtime. There is no external dependency – if AWS Secrets Manager is unavailable, Sealed Secrets still works. The total setup is: one Helm chart install and one CLI tool (`kubeseal`). Teams already comfortable with GitOps find this natural because secrets live in the same repository as the rest of the configuration.

### Why we chose ESO instead

**Rotation without re-encryption.** With Sealed Secrets, rotating a secret requires re-running `kubeseal`, committing a new encrypted blob, and pushing. With ESO, you update the value in Secrets Manager and ESO syncs it within the `refreshInterval` (1 hour). No Git commit required.

**AWS-native audit trail.** Every `GetSecretValue` call appears in CloudTrail with timestamps, caller identity, and source IP. Sealed Secrets provides no equivalent – there is no record of when a secret was decrypted or by whom.

**IRSA scope.** The ESO service account is bound to an IAM role that can only read `nimbus-cluster/*` secrets. A compromised ESO pod cannot read secrets belonging to other clusters or projects.

**Cluster-independence.** Sealed Secrets encrypts with the cluster's public key. If the cluster is destroyed and the master key is lost, the secrets cannot be recovered – you must re-enter them. Secrets Manager has its own redundancy and survives cluster destruction.

---

## Consequences

**Positive:**
- Secret rotation requires no Git commits or Kubernetes operations
- Full CloudTrail audit trail for every secret access
- IRSA limits blast radius – ESO can only read `nimbus-cluster/*`
- Secrets survive cluster teardown and re-deployment
- `ExternalSecret` CRs are version-controlled (no sensitive values in the YAML)

**Negative:**
- ESO adds genuine operational complexity: the operator must be deployed and healthy before any service can start; a broken `SecretStore` or expired IRSA token blocks all pod startups
- Requires pre-creating secrets in Secrets Manager before first deployment – an extra manual step not present with Sealed Secrets
- AWS dependency: if Secrets Manager is unavailable and the Kubernetes Secret doesn't exist yet (new cluster), pods cannot start. Sealed Secrets has no such external dependency.
- ESO sync failure is silent by default – pods continue with stale secrets until the next successful sync

**What we'd reconsider:** For a team with no AWS footprint, or one that prioritises fully offline GitOps, Sealed Secrets is the better choice. ESO's advantage is strongest when you already have AWS Secrets Manager and CloudTrail as part of your security posture.
