# Runbook: Kafka Consumer Lag Growing on orders.created

**Service affected:** notification-service (consumer group: `notification-service-group`)  
**Topic:** `orders.created`  
**Severity:** High — unfulfilled orders mean customers receive no confirmation  
**On-call escalation:** If lag exceeds 10,000 messages or does not decrease within 15 minutes of remediation, escalate to the platform lead.

---

## What is consumer lag?

Consumer lag is the difference between the latest message offset produced to a Kafka topic and the latest offset committed by a consumer group. A lag of 0 means the consumer is caught up. A growing lag means the consumer is falling behind the producer.

```
lag = end_offset - committed_offset   (per partition, summed across all partitions)
```

---

## 1. Detect

### Grafana (preferred)
Open the **NimbusRetail Kafka** dashboard → panel **Consumer Lag by Group**. Filter by group `notification-service-group` and topic `orders.created`. A rising slope that does not level off is the signal.

### kubectl — check consumer pods
```bash
kubectl get pods -n nimbus -l app=notification-service
```
Expected: all pods `Running`, `READY 1/1`, low restart count.

If pods are absent, in `CrashLoopBackOff`, or in `Pending`, the consumer is not running — that is the cause.

### Strimzi kafka-consumer-groups (run from a Kafka client pod)
```bash
# Exec into the kafka client pod
kubectl exec -it -n kafka deploy/kafka-client -- bash

# List lag for the consumer group
kafka-consumer-groups.sh \
  --bootstrap-server nimbus-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092 \
  --group notification-service-group \
  --describe
```

Output columns to check: `LAG`, `CONSUMER-ID`. A `LAG` > 0 with no `CONSUMER-ID` means no active consumer is assigned to that partition.

---

## 2. Diagnose

Work through these in order. Stop at the first positive finding.

### A. Consumer pods are not running

```bash
kubectl get pods -n nimbus -l app=notification-service
kubectl describe pod -n nimbus <pod-name>
kubectl logs -n nimbus <pod-name> --previous
```

Common causes:
- `CrashLoopBackOff` with `KAFKA_BROKERS` env var wrong → check the Helm values
- `OOMKilled` → pod ran out of memory, increase `resources.limits.memory`
- `ImagePullBackOff` → ECR image does not exist or IAM role missing

### B. Consumer pods are running but lag is still growing

The consumer is running but processing too slowly. Check:

```bash
# Is the pod hitting CPU limits?
kubectl top pod -n nimbus -l app=notification-service

# Are there errors in the logs?
kubectl logs -n nimbus -l app=notification-service --tail=200 | grep -i "error\|warn\|exception"
```

Common causes:
- Downstream call (email/SMS API) is slow or timing out → logs will show repeated timeout errors
- CPU throttling → `kubectl top` shows CPU near the limit; increase `resources.limits.cpu`

### C. Producer spike — lag is growing faster than normal

```bash
# Count messages produced in the last minute
kafka-consumer-groups.sh \
  --bootstrap-server nimbus-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092 \
  --group notification-service-group \
  --describe | awk '{print $5}' | tail -n +2 | paste -sd+ | bc
```

If end offsets are jumping by thousands per minute, a producer bug or load test is flooding the topic. Check order-service logs.

---

## 3. Remediate

### Scenario A: Consumer pods are down → scale up

**Get approval before running.** This changes cluster state.

```bash
kubectl scale deployment notification-service -n nimbus --replicas=2
```

Verify lag starts dropping within 60 seconds:
```bash
watch -n 5 'kubectl exec -n kafka deploy/kafka-client -- \
  kafka-consumer-groups.sh \
  --bootstrap-server nimbus-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092 \
  --group notification-service-group \
  --describe | grep orders.created'
```

### Scenario B: Consumer is running but crashing → rollback

**Get approval before running.**

```bash
# Check rollout history
kubectl rollout history deployment/notification-service -n nimbus

# Roll back to previous revision
kubectl rollout undo deployment/notification-service -n nimbus

# Watch pods restart cleanly
kubectl rollout status deployment/notification-service -n nimbus
```

### Scenario C: Consumer is slow → temporary scale-out

Kafka partitions are the unit of parallelism. You can only have as many active consumers as partitions. Check partition count first:

```bash
kafka-topics.sh \
  --bootstrap-server nimbus-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092 \
  --describe --topic orders.created | grep PartitionCount
```

If partitions > current replicas, scale up:
```bash
kubectl scale deployment notification-service -n nimbus --replicas=<partition-count>
```

---

## 4. Verify

After remediation, confirm lag is draining:

```bash
# Run every 30s for 3 minutes
for i in {1..6}; do
  kubectl exec -n kafka deploy/kafka-client -- \
    kafka-consumer-groups.sh \
    --bootstrap-server nimbus-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092 \
    --group notification-service-group \
    --describe | grep orders.created
  sleep 30
done
```

Success criterion: `LAG` column decreasing each iteration, reaching 0.

---

## 5. Post-incident

1. Record the incident in the team log with: start time, cause, action taken, time to resolution.
2. If caused by a pod crash, open a ticket to fix the root cause before closing.
3. If consumer throughput was the bottleneck, consider increasing the partition count on `orders.created` (requires coordination with order-service team — partition changes are destructive if done wrong).
4. Check Grafana for any downstream impact: order completion rate, email delivery rate.
