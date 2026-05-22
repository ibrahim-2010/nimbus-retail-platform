# ADR-001: Strimzi over Amazon MSK for Kafka

**Status:** Accepted  
**Date:** 2026-05-14  
**Deciders:** Platform team  

---

## Context

The NimbusRetail platform requires an Apache Kafka cluster for asynchronous event streaming between auth-service (producer: `users.registered`) and order-service (producer: `orders.created`) to notification-service (consumer).

Two options were evaluated:

| Option | Description |
|---|---|
| Amazon MSK | AWS managed Kafka service |
| Strimzi | CNCF-graduated Kafka operator for Kubernetes |

---

## Decision

**Use Strimzi** to run Kafka as pods inside the EKS cluster.

---

## Honest Trade-off Analysis

### The case FOR Amazon MSK (rejected option)

MSK is the operationally simpler choice. AWS manages broker health, storage scaling, OS patching, and cross-AZ replication automatically. If a broker dies, AWS replaces it without platform team involvement. MSK also integrates natively with AWS CloudWatch, IAM authentication, and VPC networking – no Kubernetes-specific knowledge required to operate it. For a production system where Kafka reliability is business-critical, MSK removes a significant on-call burden.

### Why we chose Strimzi instead

**Cost is the deciding factor.** MSK has a minimum cost of ~$450/month at 3 × `kafka.t3.small` brokers regardless of utilisation. Strimzi runs inside the existing t3.xlarge EKS node group at no additional AWS charge.

**GitOps consistency.** The Kafka cluster is declared as a `Kafka` CRD, version-controlled in Git, and deployed by ArgoCD – the same pattern as every other workload on the platform. With MSK, Kafka would be provisioned by Terraform and managed outside the GitOps model.

**KRaft mode.** Strimzi 0.42+ supports KRaft (ZooKeeper-free), which matches the local development setup (`apache/kafka:3.7.2` in docker-compose). This reduces the local-to-production environment gap.

---

## Consequences

**Positive:**
- Zero additional AWS cost
- Kafka configuration is version-controlled and GitOps-managed
- KRaft mode: no ZooKeeper pods to maintain
- Operator handles rolling broker upgrades

**Negative:**
- Kafka brokers consume real node resources: 3 brokers × ~512 MiB RAM + storage competes with application pods for node capacity
- Broker failure recovery is handled by the Strimzi operator, not AWS – if the operator itself has a bug or is misconfigured, recovery is manual
- No built-in cross-AZ replication managed by AWS; EBS volumes are AZ-pinned, so a full AZ failure loses that broker's data until the volume is recovered
- Strimzi operator upgrades must be managed manually and tested carefully – a failed upgrade can take down the entire Kafka cluster

**If the project were production-critical:** MSK would be the right call. The cost delta ($450/month) is trivial against the operational risk of self-managed Kafka in production. Strimzi is the right choice here because cost is the binding constraint for a lab environment.
