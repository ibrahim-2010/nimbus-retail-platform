# ADR-002: Single Shared Helm Chart for All Services

**Status:** Accepted
**Date:** 2026-05-15
**Deciders:** Platform team

---

## Context

Five NimbusRetail microservices need Kubernetes packaging. Options considered:

| Option | Description |
|---|---|
| A | One independent Helm chart per service (5 charts) |
| B | One shared chart with per-service values files |
| C | Kustomize base + overlays |

## Decision

**Option B** – a single chart at `helm/nimbus-service/` with five
`values-<service>.yaml` overrides.

## Rationale

All five services share the same Kubernetes structure: a `Deployment`, a `ClusterIP`
`Service`, a named port `http`, probes at `/healthz` and `/readyz`, and optional HPA.
Duplicating the template logic across five charts would create five places to update
for every structural change (e.g. adding a sidecar, changing probe paths).

Per-service values files (`values-auth.yaml`, `values-catalog.yaml`, etc.) provide
full customisation of image repository, port, environment variables, secret references,
and HPA settings without duplicating template code.

ArgoCD supports this pattern natively – each child app references the same `path`
with a different `helm.valueFiles` entry.

**Option C (Kustomize)** is a legitimate alternative used in many production platforms, particularly where teams want to avoid Helm's templating complexity. Kustomize's patch-based model is conceptually simpler and avoids Helm's release state management. It was rejected here because the project already uses Helm for all operator deployments (Strimzi, Kyverno, ESO, monitoring) and mixing two packaging systems would add cognitive overhead without a clear benefit at this scale. If the team were starting from scratch with a preference for fewer abstractions, Kustomize would be a reasonable choice.

## Consequences

**Positive:**
- Single template to maintain for all structural changes
- Per-service values files are readable and self-documenting
- Adding a sixth service requires only a new values file and ArgoCD app

**Negative:**
- Services with fundamentally different structures (e.g. a StatefulSet) would need
  the shared chart extended or a separate chart
- `helm lint` must be run with a specific values file to be meaningful

**Mitigation:** `catalog-service` uses a separate secret (`nimbus-catalog-secrets`)
because its `DATABASE_URL` requires the `postgresql://` prefix for asyncpg, not
`postgres://`. This difference is handled entirely in the values file without
any template change.
