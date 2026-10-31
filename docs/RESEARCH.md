# Phase 1 — Research notes and technology decisions (October 2026)

## Runtimes evaluated

| Option | Verdict | Reasoning |
|---|---|---|
| **llama.cpp (GGUF, Metal)** | **Adopted, primary engine** | Supports the current small-model families on day one (`qwen35`, `gemma4`, `phi3`, `llama` architectures are present at b12018), every k-quant/i-quant, Metal offload on all A15+ GPUs, an official prebuilt `llama.xcframework`, and `libmtmd` for vision adapters. Pinned at **b12018**; the Swift bridge is written against that tag's `llama.h`/`mtmd.h`. |
| **Apple Foundation Models** | **Adopted, complementary** | Free, no download, runs out-of-process on the Neural Engine/GPU, so it costs the app no memory. Limited to ~3B, 4K context, no image input; used for Instant mode and as a fallback on Apple Intelligence devices. |
| MLX Swift | Not adopted | Excellent on Mac; on iPhone it requires the increased-memory entitlement for anything beyond ~3B and lacks a vision path as mature as mtmd for these model families. Two GPU runtimes in one app would double binary size and memory pressure for little gain. |
| Core ML (converted LLMs) | Not adopted | Third-party LLM conversion with stateful KV cache works only for specific architectures and requires per-model conversion and hosting of converted weights; it cannot run hybrid (Gated DeltaNet) models like Qwen3.5. The Neural Engine is used indirectly through Apple Foundation Models. |
| Cloud-only | Rejected | Violates the offline requirement. Cloud is an optional provider layer. |

## Models evaluated

All sizes and SHA-256 hashes in the registry were read from the Hugging Face API at development time.

| Model | Params | License | Why |
|---|---|---|---|
| Qwen3.5 0.8B / 2B / 4B / 9B | dense hybrid | Apache-2.0 | Current best-in-class small family: native thinking mode, tool calling, 262K native context, and official vision adapters. Hybrid attention keeps KV-cache memory low, which matters more than raw parameter count on phones. |
| Gemma 4 E2B / E4B | 2B / 4B effective | Apache-2.0 | Per-layer-embedding edge architecture, natural writing, vision adapters. Larger files than their effective size suggests. |
| Phi-4-mini | 3.8B | MIT | Strong math/reasoning per parameter; full attention (higher KV memory). |
| Llama 3.2 3B | 3.2B | Llama 3.2 Community License | Widely used, well understood baseline; included for comparison. |
| Qwen2.5-Coder 7B | 7.6B | Apache-2.0 | Code specialist for the Coding agent on 8–12 GB devices. (The 3B coder is under a non-commercial research license and was excluded.) |

Excluded: gated repositories that require a Hugging Face login (cannot be downloaded anonymously in-app), and models whose licenses forbid redistribution of quantized derivatives.

## Quantization

* **Q4_K_M** is the default: the best accuracy/size trade-off for 2–4B models on phones.
* **Q6_K** is offered for Qwen3.5 4B ("high fidelity") to show the trade-off explicitly.
* **IQ4_XS** (importance-matrix 4-bit) for Qwen3.5 9B: ~10% smaller than Q4_K_M at similar quality, which decides whether 9B fits in a 12 GB iPhone's per-app limit.
* **Q3_K_M** for Qwen3.5 9B "compact" on 8 GB devices: lower quality, but a 9B model at 3-bit often still beats a 4B at 4-bit. The admission check decides whether it can be loaded.
* 8-bit and BF16 were rejected for on-device use (2–4× the memory for marginal gains at these sizes).
* q8_0 **KV-cache quantization** is enabled automatically above 8K context (requires flash attention).

## Techniques considered

| Technique | Status |
|---|---|
| KV-cache prefix reuse across turns | Implemented |
| KV-cache quantization | Implemented (q8_0 above 8K context) |
| Context compression | Implemented as retrieval: memories and documents are retrieved by relevance instead of stuffing full histories; history is trimmed newest-first to the window |
| Flash attention | Enabled (auto) |
| Model loading/unloading, admission control | Implemented |
| Speculative decoding | **Not implemented.** The recommended Qwen3.5 models are hybrid recurrent models; verifying drafted tokens requires rolling back recurrent state, which llama.cpp cannot do partially for these architectures (`llama_memory_seq_rm` fails). Gemma 4 ships MTP draft heads, but llama.cpp's public C API does not expose MTP decoding at b12018. |
| Pruning / distillation | Not applicable at runtime; we use already-distilled small models. |
| Mixture-of-experts | Qwen3.5 MoE variants exist but the smallest is far too large for phones. |
| Neural Engine for third-party LLMs | Not possible without Core ML conversion (see above). |
| Background inference | iOS does not allow sustained background GPU work; generation stops when the app is suspended. Downloads use a background `URLSession`. |

## Hardware assumptions (verified at runtime, not hard-coded)

* Physical RAM from `ProcessInfo.physicalMemory`; the real per-app limit from `os_proc_available_memory()`.
* iPhone 15 Pro/16/17 have 8 GB; iPhone 17 Pro/Pro Max/Air have 12 GB. Without the increased-memory-limit entitlement, an app typically gets roughly half to two-thirds of RAM.
* Metal GPU family is detected (Apple 7–9+). All supported models offload every layer to the GPU.
