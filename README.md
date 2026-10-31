# NEXUS AI

A local-first AI assistant for iPhone. NEXUS runs open-weight language and vision models **on the device** with llama.cpp (Metal) and Apple's Foundation Models. It works fully offline, and it can optionally use web research and cloud models when you allow it.

**Download (unsigned IPA, built by CI):** https://github.com/surproductions/Nexus-Ai/releases/latest/download/NexusAI.ipa
Install instructions: [docs/INSTALL.md](docs/INSTALL.md)

## What it does

* **Three intelligence modes**
  * **Instant**: the fastest capable model, one streamed pass.
  * **Thinking**: a stronger model with thinking mode and a bounded tool loop (calculator, units, dates, memory, documents, JavaScript, web).
  * **Max Intelligence**: planning, specialist agents (reasoning, coding, research, document, vision), streamed synthesis, deterministic checks (exact math, JS/JSON validity), independent verification and a single revision pass, all under explicit time/token/call budgets.
* **Adaptive model routing** across installed GGUF models, Apple Intelligence and optional cloud providers. Routing weighs task type, mode, free memory, thermal state and your own on-device evaluation results. A manual override is always available.
* **Curated model catalog**: Qwen3.5 (0.8B/2B/4B/9B, with vision adapters), Gemma 4 E2B/E4B, Phi-4-mini, Llama 3.2 3B, Qwen2.5-Coder 7B. Every entry carries its exact size, SHA-256, license, provenance and memory estimate. Downloads are background, resumable and checksum-verified. You can also import your own GGUF.
* **Hardware-aware**: detects device, chip, RAM, GPU family, the real per-app memory limit, thermal state, battery and storage. Assigns a Low / Balanced / High profile. Refuses loads that would likely be killed by iOS, picks the largest context that fits, and unloads on memory warnings.
* **Memory you control**: long-term memories (preferences, facts, instructions, decisions, knowledge) and project memory (summary, decisions, tasks, notes, documents). Semantic + keyword retrieval with duplicate detection and relevance/recency scoring. Nothing is stored without an explicit "remember…" or your approval. Export/import supported.
* **Multimodal**: real on-device image understanding through llama.cpp's mtmd with each model's vision adapter, grounded by Apple Vision OCR/classification. PDF/text/code/image documents are indexed locally (OCR for scanned pages), with summarization, search and Q&A with page citations.
* **Voice**: hands-free conversation with on-device speech recognition, voice-activity detection, sentence-streamed speech synthesis, and barge-in interruption.
* **Privacy**: an Offline-Only switch, per-feature network consent (all off by default except model downloads), a local log of every outbound request, Keychain for API keys, AES-256-GCM encryption of conversations/memories/documents, optional Face ID lock, no telemetry.
* **Evaluation & benchmarks**: an in-app performance benchmark (load time, TTFT, decode and prompt tok/s, peak memory, thermal, battery) and a 29-case evaluation suite with automatic graders, including executed JavaScript tests and hallucination probes. It runs identically against local models and cloud providers.

## Project layout

```
NexusAI/            Swift sources (see docs/ARCHITECTURE.md)
  App/ UI/ Inference/ Registry/ Routing/ Reasoning/ Tools/ Memory/
  Documents/ Vision/ Voice/ Hardware/ Security/ Evaluation/ Resources/
Tests/LogicTests/   Pure-logic tests, run on every CI build
project.yml         XcodeGen spec (NexusAI.xcodeproj is generated)
scripts/bootstrap.sh  Fetch llama.xcframework + generate the Xcode project
.github/workflows/  CI: tests → build → package IPA → GitHub release
docs/               Architecture, research notes, install, benchmarks, limitations
```

## Documentation

* [Architecture](docs/ARCHITECTURE.md)
* [Research & technology decisions](docs/RESEARCH.md)
* [Installation & signing](docs/INSTALL.md)
* [Benchmarks & evaluation methodology](docs/BENCHMARKS.md)
* [Known limitations](docs/LIMITATIONS.md)

## Honest status

The app compiles for iOS on CI and its logic tests pass on every build. It has **not yet been run on a physical iPhone by the author**. See [LIMITATIONS.md](docs/LIMITATIONS.md) for exactly what has and hasn't been verified. No benchmark numbers are published until they're measured on real devices.

## Licenses

App source: MIT. llama.cpp/ggml: MIT. Model weights are not redistributed; they download from their publishers under their own licenses (Apache-2.0, MIT, Llama 3.2 Community License).
