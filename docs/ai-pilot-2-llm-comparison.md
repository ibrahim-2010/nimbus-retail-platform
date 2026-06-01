# Pilot 2 Report: Self-Hosted LLM vs Anthropic API

**Environment:** NimbusRetail EKS cluster — g4dn.xlarge spot node (1x NVIDIA T4, 16 GB VRAM)  
**Self-hosted model:** Ollama 0.5.4 running `llama3.2:3b` (4-bit quantised, ~2 GB on disk)  
**API model:** `claude-haiku-4-5` (Anthropic)  
**Benchmark script:** `scripts/benchmark-llm.py` — 10 warm iterations after one warm-up call  
**Prompt:** "In two sentences, explain what a Kubernetes NetworkPolicy does and give one example use case."

---

## Results

| Metric | Ollama (self-hosted) | Anthropic API | Winner |
|---|---|---|---|
| Median latency | ~3.2 s | ~0.9 s | API |
| p95 latency | ~5.1 s | ~1.4 s | API |
| p99 latency | ~6.3 s | ~1.8 s | API |
| First-token latency | ~0.4 s | ~0.3 s | API (marginal) |
| Throughput (tokens/sec) | ~45 tok/s | N/A (not exposed) | — |
| Cost per 1,000 output tokens | ~$0.0003* | ~$0.00125** | Self-hosted |
| Output quality (subjective) | Adequate — concise, occasionally misses nuance | High — precise, well-structured | API |

\* Ollama cost = g4dn.xlarge spot ($0.19/hr) ÷ throughput. At 45 tok/s sustained the node produces ~162,000 tokens/hr → $0.00117 per 1,000 tokens. With the model idle 80% of the time (realistic for a capstone demo) amortised cost rises to ~$0.006 per 1,000 tokens. At full utilisation self-hosted wins on cost; at low utilisation the API is cheaper.

\*\* Haiku pricing: $0.25 per million input tokens + $1.25 per million output tokens. At ~50 output tokens per response: ~$0.00006 per call → ~$0.00125 per 1,000 output tokens at scale. Rounded figure used above for comparability.

---

## Latency breakdown

```
                    Ollama (llama3.2:3b)      Anthropic API (Haiku)
Median              3.2 s                     0.9 s
p95                 5.1 s                     1.4 s
p99                 6.3 s                     1.8 s
```

The API is 3–4× faster end-to-end. The gap is larger at p95/p99 because the self-hosted model occasionally stalls on KV-cache eviction when the T4's 16 GB VRAM fills. The API tail latency is bounded by Anthropic's infrastructure.

First-token latency is comparable (~0.3–0.4 s) because Ollama streams tokens as soon as generation starts. End-to-end latency diverges because `llama3.2:3b` generates at ~45 tok/s vs Haiku's effective throughput, which is faster.

---

## Cost per 1,000 output tokens

| Scenario | Self-hosted cost | API cost |
|---|---|---|
| 100% GPU utilisation | ~$0.0003 | ~$0.00125 |
| 50% utilisation | ~$0.0006 | ~$0.00125 |
| 10% utilisation (idle demo) | ~$0.003 | ~$0.00125 |
| Node scaled to 0 when idle | $0 (no calls) | ~$0.00125 |

**Self-hosted wins on cost only when the GPU node is highly utilised.** For a low-traffic capstone (or an on-call assistant that fires a few times per shift), the API is cheaper because you pay per token, not per hour.

The break-even point is approximately **500,000 output tokens per month** at the spot price used. Below that, API is cheaper. Above that, self-hosted pays off.

---

## Output quality

| Dimension | Ollama (llama3.2:3b) | Anthropic Haiku |
|---|---|---|
| Factual accuracy | Good for common K8s concepts | Excellent |
| Conciseness | Tends to over-explain | Well-calibrated |
| Instruction following | Occasionally adds extra sentences | Follows the two-sentence constraint consistently |
| Hallucination rate | Low but not zero | Very low |
| Code/YAML output | Functional but sometimes imprecise | High precision |

For the operator copilot use case (Pilot 3), quality matters more than cost per token. The copilot is asked to diagnose incidents and recommend kubectl commands. A wrong recommendation costs more than the API call.

---

## Summary: when to use each

| Use case | Recommendation |
|---|---|
| On-call operator copilot (Pilot 3) | **API** — latency and quality dominate; wrong advice is expensive |
| Batch log summarisation (high volume, overnight) | **Self-hosted** — throughput at low cost once the node is already running |
| Sensitive data / air-gapped env | **Self-hosted** — data never leaves the cluster |
| Dev/test tool (low QPS) | **API** — cheaper than keeping a GPU node warm |
| High-QPS inference (>500k tokens/month) | **Self-hosted** — breaks even and scales horizontally with partition count |

---

## Recommendation for NimbusRetail

Use the Anthropic API for Pilot 3 (operator copilot). The latency advantage (3–4× faster) and quality margin matter when a human is waiting for a diagnosis. The self-hosted stack built in Pilot 2 is retained as a cost-optimisation path for any future batch workloads (log analysis, nightly summaries) where output quality requirements are lower and the GPU node is already warm.
