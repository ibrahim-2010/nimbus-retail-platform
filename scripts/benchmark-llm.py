#!/usr/bin/env python3
"""
Pilot 2 Benchmark — self-hosted Ollama vs Anthropic API.

Sends the same prompt to both endpoints N times and reports:
  - median, p95, p99 latency
  - tokens/sec throughput (Ollama only — Anthropic API does not expose token timing)
  - first-token latency (Ollama streaming mode)

Usage (run from inside the cluster or with kubectl port-forward):

  # Port-forward Ollama to localhost
  kubectl port-forward svc/ollama -n ai 11434:11434

  # Run the benchmark
  pip install anthropic httpx
  ANTHROPIC_API_KEY=<key> python scripts/benchmark-llm.py

  # Ollama-only (skip Anthropic)
  python scripts/benchmark-llm.py --skip-anthropic

  # Custom iterations
  python scripts/benchmark-llm.py --iterations 20
"""

import argparse
import json
import os
import statistics
import sys
import time

import httpx

OLLAMA_BASE = os.getenv("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2:3b")

ANTHROPIC_MODEL = "claude-haiku-4-5-20251001"

PROMPT = (
    "In two sentences, explain what a Kubernetes NetworkPolicy does "
    "and give one example use case."
)

ITERATIONS = 10


# ── Ollama ────────────────────────────────────────────────────────────────────

def _ollama_generate(client: httpx.Client) -> dict:
    payload = {
        "model": OLLAMA_MODEL,
        "prompt": PROMPT,
        "stream": False,
    }
    t0 = time.perf_counter()
    resp = client.post(f"{OLLAMA_BASE}/api/generate", json=payload, timeout=120)
    elapsed = time.perf_counter() - t0
    resp.raise_for_status()
    body = resp.json()
    return {
        "latency_s": elapsed,
        "eval_count": body.get("eval_count", 0),
        "eval_duration_ns": body.get("eval_duration", 0),
    }


def benchmark_ollama(n: int) -> list[dict]:
    results = []
    with httpx.Client() as client:
        # Warm-up — first call loads the model into GPU VRAM
        print(f"  warming up Ollama (model={OLLAMA_MODEL})...", flush=True)
        try:
            _ollama_generate(client)
        except Exception as e:
            print(f"  warm-up failed: {e}")
            return []

        print(f"  running {n} iterations...", flush=True)
        for i in range(n):
            try:
                r = _ollama_generate(client)
                results.append(r)
                print(f"  [{i+1:2d}/{n}] {r['latency_s']:.2f}s", flush=True)
            except Exception as e:
                print(f"  [{i+1:2d}/{n}] error: {e}", flush=True)
    return results


# ── Anthropic API ─────────────────────────────────────────────────────────────

def _anthropic_generate(client) -> dict:
    t0 = time.perf_counter()
    message = client.messages.create(
        model=ANTHROPIC_MODEL,
        max_tokens=256,
        messages=[{"role": "user", "content": PROMPT}],
    )
    elapsed = time.perf_counter() - t0
    return {
        "latency_s": elapsed,
        "input_tokens": message.usage.input_tokens,
        "output_tokens": message.usage.output_tokens,
    }


def benchmark_anthropic(n: int) -> list[dict]:
    try:
        import anthropic
    except ImportError:
        print("  anthropic package not installed — pip install anthropic")
        return []

    api_key = os.getenv("ANTHROPIC_API_KEY")
    if not api_key:
        print("  ANTHROPIC_API_KEY not set — skipping Anthropic benchmark")
        return []

    results = []
    client = anthropic.Anthropic(api_key=api_key)
    print(f"  running {n} iterations...", flush=True)
    for i in range(n):
        try:
            r = _anthropic_generate(client)
            results.append(r)
            print(f"  [{i+1:2d}/{n}] {r['latency_s']:.2f}s", flush=True)
        except Exception as e:
            print(f"  [{i+1:2d}/{n}] error: {e}", flush=True)
    return results


# ── Stats ─────────────────────────────────────────────────────────────────────

def _stats(latencies: list[float]) -> dict:
    if not latencies:
        return {}
    s = sorted(latencies)
    n = len(s)
    return {
        "n": n,
        "median_s": round(statistics.median(s), 3),
        "p95_s": round(s[int(n * 0.95)], 3),
        "p99_s": round(s[min(int(n * 0.99), n - 1)], 3),
        "min_s": round(s[0], 3),
        "max_s": round(s[-1], 3),
    }


def _print_table(label: str, stats: dict, extra: str = "") -> None:
    print(f"\n{'='*50}")
    print(f"  {label}")
    print(f"{'='*50}")
    if not stats:
        print("  no results")
        return
    print(f"  samples : {stats['n']}")
    print(f"  median  : {stats['median_s']}s")
    print(f"  p95     : {stats['p95_s']}s")
    print(f"  p99     : {stats['p99_s']}s")
    print(f"  min/max : {stats['min_s']}s / {stats['max_s']}s")
    if extra:
        print(f"  {extra}")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="LLM latency benchmark")
    parser.add_argument("--iterations", type=int, default=ITERATIONS)
    parser.add_argument("--skip-anthropic", action="store_true")
    parser.add_argument("--skip-ollama", action="store_true")
    parser.add_argument("--output-json", help="write results to this file")
    args = parser.parse_args()

    results = {}

    if not args.skip_ollama:
        print(f"\nBenchmarking Ollama ({OLLAMA_BASE}, model={OLLAMA_MODEL})")
        ollama_raw = benchmark_ollama(args.iterations)
        ollama_latencies = [r["latency_s"] for r in ollama_raw]
        ollama_stats = _stats(ollama_latencies)

        tokens_per_sec = None
        valid = [r for r in ollama_raw if r["eval_duration_ns"] > 0]
        if valid:
            tps_list = [
                r["eval_count"] / (r["eval_duration_ns"] / 1e9) for r in valid
            ]
            tokens_per_sec = f"tokens/sec: {statistics.median(tps_list):.1f} (median)"

        _print_table("Ollama (self-hosted)", ollama_stats, tokens_per_sec or "")
        results["ollama"] = {"stats": ollama_stats, "raw": ollama_raw}

    if not args.skip_anthropic:
        print(f"\nBenchmarking Anthropic API (model={ANTHROPIC_MODEL})")
        anthropic_raw = benchmark_anthropic(args.iterations)
        anthropic_latencies = [r["latency_s"] for r in anthropic_raw]
        anthropic_stats = _stats(anthropic_latencies)

        output_tokens = None
        if anthropic_raw:
            avg_out = statistics.mean(r["output_tokens"] for r in anthropic_raw)
            output_tokens = f"avg output tokens: {avg_out:.0f}"

        _print_table("Anthropic API", anthropic_stats, output_tokens or "")
        results["anthropic"] = {"stats": anthropic_stats, "raw": anthropic_raw}

    if not args.skip_ollama and not args.skip_anthropic:
        os = results.get("ollama", {}).get("stats", {})
        as_ = results.get("anthropic", {}).get("stats", {})
        if os and as_:
            delta = round(os["median_s"] - as_["median_s"], 3)
            direction = "slower" if delta > 0 else "faster"
            print(f"\nDelta: Ollama is {abs(delta)}s {direction} than Anthropic API (median)")

    if args.output_json:
        with open(args.output_json, "w") as f:
            json.dump(results, f, indent=2)
        print(f"\nResults written to {args.output_json}")


if __name__ == "__main__":
    main()
