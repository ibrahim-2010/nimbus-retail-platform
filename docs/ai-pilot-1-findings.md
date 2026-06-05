# Pilot 1 Findings: AI-Assisted DevOps Workflow

**Tool used:** Claude Code (CLI) – Anthropic  
**Working environment:** nimbus-retail-platform repository  
**Period:** Phase 3, Days 1–2

---

## Summary

AI tooling produced usable first drafts for all five tasks. The time savings were real on mechanical and boilerplate-heavy work (Helm chart scaffolding, Mermaid diagram, Python translation). The tool required more supervision on tasks that needed knowledge of the existing codebase structure – it had to read the repo before writing, and on one task (Kyverno policy) it initially missed that the policies already existed and needed upgrading rather than creating from scratch.

Overall recommendation: **use AI tooling unsupervised for boilerplate and translation; require human review for anything touching security policy or shared infrastructure.**

---

## Task Results

### Task 1 – Helm chart for audit-service

| Metric | Value |
|---|---|
| Estimated unassisted time | 45–60 min |
| AI-assisted time | ~15 min |
| Corrections required | 1 |
| Confidence to commit | High |

**What the AI did well:** Correctly identified that the right approach was to extend the shared `helm/nimbus-service/` chart rather than create a standalone chart. Generated all three new templates (ServiceAccount, NetworkPolicy, ServiceMonitor) with the correct Helm syntax, feature-flag pattern (`enabled: false` defaults), and proper label selectors. `values-audit.yaml` followed the existing conventions without being told.

**What required correction:** The initial NetworkPolicy template was too restrictive – it blocked the ALB. Required one round of review to add the open ingress block for ALB traffic, consistent with the existing namespace-level policies.

**Would you trust this unsupervised?** No – any NetworkPolicy change requires a human to trace the full traffic path. One wrong rule blocks production traffic silently.

---

### Task 2 – Kyverno policy (require limits + reject latest)

| Metric | Value |
|---|---|
| Estimated unassisted time | 30–40 min |
| AI-assisted time | ~10 min |
| Corrections required | 1 |
| Confidence to commit | High |

**What the AI did well:** Read the existing `kyverno-policies.yaml` before writing anything. Correctly identified that `disallow-latest-tag` was in `Audit` mode, not `Enforce`, and flagged that the task required a promotion rather than a new policy. Generated the full Kyverno test suite (`kyverno-test.yaml` + four resource fixtures) with correct pass/fail expectations.

**What required correction:** Initial test resource for `pod-missing-limits` included a `resources:` block with requests but no limits – the Kyverno pattern syntax requires the `limits` key to be absent entirely, not just empty. Required one correction to remove the partial block.

**Would you trust this unsupervised?** No – `validationFailureAction: Enforce` blocks pod admission cluster-wide. Any policy change in Enforce mode needs a human sign-off. The test suite is trustworthy unsupervised.

---

### Task 3 – Kafka consumer lag runbook

| Metric | Value |
|---|---|
| Estimated unassisted time | 60–90 min |
| AI-assisted time | ~20 min |
| Corrections required | 0 |
| Confidence to commit | High |

**What the AI did well:** Produced a structured, actionable runbook that mirrors the platform's actual tooling (Strimzi CLI, kubectl, Grafana). The three remediation scenarios (scale up, rollback, scale-out) directly correspond to the Operator Copilot scenarios in Pilot 3. Included specific verification commands with the actual Kafka bootstrap address from the repo.

**What required correction:** Nothing – runbook was correct on first output.

**Would you trust this unsupervised?** Yes, with one caveat: the runbook must be reviewed by whoever owns the service before publishing. The AI correctly wrote the procedure but cannot know if the team has a different preferred escalation path or on-call rotation.

---

### Task 4 – Bash → Python translation (bootstrap.sh)

| Metric | Value |
|---|---|
| Estimated unassisted time | 90–120 min |
| AI-assisted time | ~25 min |
| Corrections required | 1 |
| Confidence to commit | Medium |

**What the AI did well:** Correctly mapped every Bash section to idiomatic `boto3` calls. Preserved the idempotency logic (check-then-create pattern). Structured logging output is genuine JSON (not just `print()`), uses a proper `logging.Formatter` subclass, and carries structured fields. Error handling uses `ClientError` with error code inspection – not bare `except`.

**What required correction:** The S3 bucket creation call included `CreateBucketConfiguration` with `LocationConstraint` for `us-east-1`, which is actually invalid – AWS rejects a LocationConstraint for `us-east-1`. Required one fix to make the `CreateBucketConfiguration` parameter conditional on non-us-east-1 regions (which the original Bash script also got wrong, silently).

**Would you trust this unsupervised?** No – any AWS infrastructure script that creates or modifies state needs a human dry-run review. The AI caught a latent bug in the original Bash script, which is a positive signal, but that also means the AI can introduce its own subtle ones.

---

### Task 5 – Mermaid sequence diagram

| Metric | Value |
|---|---|
| Estimated unassisted time | 20–30 min |
| AI-assisted time | ~5 min |
| Corrections required | 0 |
| Confidence to commit | High |

**What the AI did well:** Correctly traced the full OrderCreated path including the synchronous cart lookup that precedes the Kafka produce. Used activation bars to clearly show where the HTTP response returns versus where the async notification happens. Added accurate notes referencing the consumer group name and topic partition count from the actual cluster config.

**Would you trust this unsupervised?** Yes – diagrams are documentation. The worst failure mode is an inaccurate diagram, which a human reviewer will catch.

---

## Overall Time Summary

| Task | Unassisted estimate | AI-assisted | Time saved |
|---|---|---|---|
| Helm chart | 45–60 min | 15 min | ~35 min |
| Kyverno policy + tests | 30–40 min | 10 min | ~25 min |
| Runbook | 60–90 min | 20 min | ~55 min |
| Bash → Python | 90–120 min | 25 min | ~75 min |
| Mermaid diagram | 20–30 min | 5 min | ~20 min |
| **Total** | **245–340 min** | **75 min** | **~210 min** |

Effective time saved: roughly 3.5 hours across the five tasks – a 3–4× speedup on first-draft production.

---

## Where AI tooling adds the most value

1. **Boilerplate generation** – Helm templates, Kyverno test fixtures, Mermaid syntax. The output is structurally correct and follows conventions without being told explicitly.
2. **Format translation** – Bash to Python is exactly the kind of mechanical work where AI shines. The logic is the same; only the syntax and idioms change.
3. **Documentation** – Runbooks and diagrams that require no cluster knowledge are high-value, low-risk AI outputs.

## Where AI tooling needs supervision

1. **Security policy changes** – Any Kyverno policy in `Enforce` mode, any NetworkPolicy change. These block admission or traffic. A wrong rule costs an incident.
2. **AWS infrastructure scripts** – The S3 `us-east-1` bug is a good example: a subtle API constraint that is not in the model's training data for this specific SDK version.
3. **Anything referencing live cluster state** – The AI cannot know your actual partition counts, consumer group names, or current replica counts without reading the cluster. Review every reference to live state.

## Recommendation

**Tier 1 – unsupervised (with post-commit review):** diagrams, runbooks, test fixtures for existing policies, changelog entries, README updates.

**Tier 2 – AI drafts, human reviews before merge:** Helm chart additions, Python scripts, new Kyverno policies in Audit mode.

**Tier 3 – AI drafts, senior review + staging test before merge:** Any Enforce-mode policy, any NetworkPolicy change, any AWS infrastructure script, any mutating kubectl operation in a runbook.
