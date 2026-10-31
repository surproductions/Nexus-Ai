# NEXUS AI — Architecture

NEXUS is a native Swift/SwiftUI iOS app (iOS 17+, iOS 26 SDK). The source tree in `NexusAI/` is organized by module:

| Module | Folder | Responsibility |
|---|---|---|
| UI | `UI/` | SwiftUI screens: Chat, Workspace (Research + Documents), Models, Memory, Settings, Voice, dashboards |
| App | `App/` | Composition root (`AppModel`), chat view model, app entry point |
| Inference engine | `Inference/` | `InferenceBackend` protocol; llama.cpp runtime (`LlamaRuntime`), Apple Foundation Models backend, cloud providers, chat templates, streaming output parser |
| Model registry | `Registry/` | Curated catalog (sizes, SHA-256, licenses, priors), installed-model tracking, loading/unloading, background downloads |
| Model routing | `Routing/` | Deterministic task classifier, adaptive model router |
| Agent orchestration | `Reasoning/` | Orchestrator, agent roles, planning, budgets, verification |
| Tools | `Tools/` | Calculator (exact parser), unit converter, dates, JavaScript sandbox, web search/fetch, tool-call parser |
| Memory | `Memory/` | SQLite storage, embeddings, long-term/project memory, encrypted conversations |
| Documents / Vision / Voice | `Documents/`, `Vision/`, `Voice/` | PDF/text ingestion with OCR, Apple Vision analysis, speech recognition + TTS with VAD and barge-in |
| Hardware | `Hardware/` | Device detection, memory/thermal/battery/storage telemetry, admission control |
| Security | `Security/` | Network gate (consent, Offline-Only, request log), Keychain, AES-GCM vault, biometrics |
| Evaluation | `Evaluation/` | Reproducible eval suite with automatic graders, performance benchmark runner |

## Request lifecycle

```
User message
  └─ TaskClassifier            (deterministic, µs)   → category, complexity, math expr, needs-current-info …
  └─ MemoryExtractor           ("remember…"/"forget…" handled without a model)
  └─ ModelRouter               (mode × task × installed × memory headroom × thermal × measured eval scores × override)
  └─ Context gathering
       ├─ standing instructions + project context
       ├─ semantic memory retrieval (hybrid: embedding cosine + keyword + importance, recency-decayed)
       ├─ document retrieval (hybrid search over chunks, ≤3 per document)
       ├─ on-device image analysis (Vision OCR, classifier, barcodes, faces)
       ├─ exact tools (calculator / unit conversion / date) — injected as authoritative results
       └─ web research (only if enabled + online + mode ≠ Instant)
  └─ Backend acquisition       (admission check → load → fallback to next candidate on OOM/load failure)
  └─ Execution
       Instant  : one streamed generation, thinking off, no tool loop
       Thinking : thinking on (if supported), streamed, bounded tool loop
       Max      : plan → specialist agents (may swap models) → streamed synthesis → deterministic checks → independent verification → optional revision
  └─ Persistence (encrypted), memory suggestions (approval required)
```

## Inference engine

* **llama.cpp b12018** via the official `llama.xcframework` (Metal GPU offload of all layers, flash attention auto, optional q8_0 KV cache above 8K context). The runtime owns one model + context on a private serial queue, streams tokens, decodes split UTF-8 safely, and **reuses the KV-cache prefix** between turns (falls back to a full re-evaluation for hybrid/recurrent models that cannot drop a partial sequence).
* **Multimodal**: `libmtmd` (bundled in the xcframework) loads a model's `mmproj` vision adapter. Images are converted to packed RGB and evaluated with `mtmd_helper_eval_chunks`.
* **Apple Foundation Models** (iOS 26, Apple Intelligence devices): zero-download ~3B model that runs out-of-process (no app memory cost). Weak-linked so the app still runs on iOS 17–25.
* **Cloud** (optional): OpenAI-compatible (`/chat/completions`, SSE) and Anthropic Messages API (SSE), with image support. Keys in Keychain. Every request passes `NetworkGate`.
* **Chat templates** are rendered natively per family (Qwen3.5 ChatML+`<think>`, Gemma 4 `<|turn>`/`<|channel>`, Phi-4, Llama 3, ChatML). Imported GGUFs use the template embedded in the file via `llama_chat_apply_template`.
* **Output parsing**: a streaming parser separates thinking from visible text, enforces stop strings and holds back partial markers so they never flash in the UI.

## Routing

`ModelRouter` scores each feasible candidate (installed + fits in memory at a usable context):

* quality `q` = measured pass rate × 10 from your latest on-device eval run for that model and category (≥2 cases), else a prior derived from publisher-reported benchmarks (labelled as such in the UI);
* speed `s` from parameter count and quantization;
* Instant: `0.35q + 0.65s` (+1.5 if already loaded; requires q ≥ 3) · Thinking: `0.7q + 0.3s` (+0.8 loaded) · Max: `q + 0.1s`;
* thermal Serious/Critical biases toward faster models; vision requests penalize models without a vision adapter;
* cloud is a candidate only in Max mode when the user enabled cloud for Max;
* a manual override always wins if it is feasible; otherwise the user is told why it was not used.

Specialist agents in Max mode only swap models when the specialist's quality advantage is ≥ 1.0, because a reload costs seconds.

## Memory safety

`HardwareMonitor.canLoad` compares an estimate (weights + KV-cache × context + compute buffers + vision adapter) with `os_proc_available_memory()` plus memory reclaimable from the currently loaded model, with an 18% safety margin (40% under Critical thermal). If a model doesn't fit at the preferred context, the context is halved down to 1,024 tokens; if it still doesn't fit, the load is refused (never attempted). Models are unloaded on iOS memory warnings unless a generation is in progress.

## Budgets

| Mode | Model calls | Tool calls | Tokens/call | Wall clock |
|---|---|---|---|---|
| Instant | 1 | 0 (deterministic pre-tools only) | 768 | 60 s |
| Thinking | 5 | 3 | 2,048 (+1,024 thinking) | 180 s |
| Max | 10 | 8 | 3,072 (+1,024 thinking) | 420 s |

The verifier runs once and can trigger at most one revision, so there are no reflection loops.

## Data at rest

* SQLite (`nexus.sqlite`, WAL) with iOS Data Protection.
* Conversations, memories, projects, research reports and document chunk text are sealed with **AES-256-GCM** (`Vault`) using a random key stored in the Keychain (`AfterFirstUnlockThisDeviceOnly`).
* Attachments and imported documents use `FileProtectionType.complete`.
* Model weights live in Application Support, excluded from iCloud backup.

## Why these technology choices

See [RESEARCH.md](RESEARCH.md).
