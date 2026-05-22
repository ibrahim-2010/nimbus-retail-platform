# ADR-004: Kyverno over OPA/Gatekeeper for Admission Control

**Status:** Accepted
**Date:** 2026-05-19
**Deciders:** Platform team

---

## Context

The platform requires a Kubernetes admission controller to enforce security policies:
no privileged containers, mandatory resource limits, image tag discipline. Options:

| Option | Description |
|---|---|
| A | OPA / Gatekeeper – Rego policies, CNCF graduated |
| B | Kyverno – Kubernetes-native YAML policies, CNCF graduated |
| C | Pod Security Standards (built-in) – namespace-level only |

## Decision

**Option B** – Kyverno.

## Rationale

**OPA/Gatekeeper** requires writing policies in Rego, a purpose-built policy language.
Rego is powerful but has a steep learning curve and is difficult to test locally
without the `opa` CLI.

**Kyverno** policies are written in YAML using Kubernetes-native patterns (selectors,
patterns, JSON patches). A platform engineer familiar with Kubernetes manifests can
read and write Kyverno policies without learning a new language.

**Pod Security Standards** (Option C) operate at the namespace level with three
fixed profiles (Privileged, Baseline, Restricted). They cannot enforce custom rules
such as "require resource limits" or "disallow `:latest` tag."

**The honest case for OPA/Gatekeeper:** Rego is more expressive than Kyverno's YAML DSL for complex policies – cross-resource validation, external data lookups, and multi-step logic are significantly easier in Rego. Gatekeeper also has a larger production footprint at enterprise scale. The trade-off is real: a team that invests in learning Rego gets a more powerful policy engine. For this project, the policies required (resource limits, privileged containers, image tags, labels) are simple enough that Kyverno's YAML DSL handles them without limitation. If the project needed complex multi-resource policies, OPA would be the better choice.

Both OPA and Kyverno are CNCF-graduated, so maturity is not a differentiator. Kyverno's simpler authoring model is the deciding factor for this project's policy requirements.

## Consequences

**Positive:**
- Policies are readable YAML – reviewable in pull requests without Rego knowledge
- `Audit` mode allows gradual policy rollout without breaking existing workloads
- `PolicyReport` CRs provide a queryable violation log

**Negative:**
- Kyverno runs in `kyverno` namespace and adds ~200 MiB memory overhead
- Complex policies (multi-resource dependencies) are harder in Kyverno than Rego

**Policy rollout strategy:**
- `Enforce` immediately: `disallow-privileged-containers`, `require-resource-limits`
  (the Helm chart already sets limits on all Nimbus pods)
- `Audit` first: `disallow-latest-tag`, `require-app-label`
  (switch to `Enforce` after confirming all workloads are compliant via `PolicyReport`)
