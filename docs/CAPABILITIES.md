# NEXUS AI capability matrix

This document classifies every capability into the four categories the project brief requires, based on what the code does and on the platform's real limits. "Verified on device" is a separate question: **nothing in this table has been run on a physical iPhone by the author yet** (see [LIMITATIONS.md](LIMITATIONS.md)). Everything listed compiles and is wired end to end, and the deterministic parts are unit-tested on every CI build.

Target device: **iPhone 18 Pro Max** (identifiers `iPhone19,2`, `iPhone19,3`, `iPhone19,7`, A20 Pro, 12 GB RAM, iOS 27). Specs were checked against Apple's spec page and device databases in October 2026. NEXUS still sizes everything at runtime from `ProcessInfo.physicalMemory` and `os_proc_available_memory()` rather than trusting these numbers.

## 1. Fully supported locally (works offline)

| Capability | How |
|---|---|
| Chat in Instant / Thinking / Max | llama.cpp (Metal) with LFM2.5 1.2B, Qwen3.5 0.8B–9B, Gemma 4 E2B/E4B, Phi-4-mini, Llama 3.2 3B, Qwen2.5-Coder 7B; Apple Foundation Models |
| Configurable model per mode and per memory class | `ModePolicy` (Settings → Model configuration); measured auto-configuration |
| Tool calling | Exact calculator/units/dates; FunctionGemma 270M as a tool-selection specialist (proposals validated) |
| Image understanding | Vision-language models via llama.cpp mtmd (Qwen3.5 / Gemma 4 vision adapters) plus Apple Vision OCR, classification, barcodes, faces |
| Multiple images per conversation, follow-up questions | Images numbered across the conversation; the most recent images are re-sent to vision models for follow-ups; per-image analysis is stored with the message |
| Screenshots, charts, diagrams, technical photos | Same vision path; OCR gives exact text |
| Video understanding | Metadata, scene-change detection, key-frame sampling, OCR and labels per frame, VLM frame captions, on-device speech transcription, timestamped dossier, focus window for "what happens at 2:30?", clickable timestamps |
| Multiple-video comparison | Up to 3 most recent videos included as labelled dossiers |
| Documents | PDF/text/RTF/HTML/code ingestion, OCR for scanned pages, hybrid search, summaries, Q&A with page citations |
| Image generation | Apple Image Playground (`ImageCreator`, Animation/Illustration/Sketch); Stable Diffusion 2.1 Core ML on the Neural Engine (512×512, photorealistic/custom styles, variations, seeds) |
| Reference-guided image generation | SD 2.1 image-to-image (strength control); Image Playground image concepts |
| Background removal | Vision foreground-instance mask (subject lifting) |
| Background replacement | Subject lift + locally generated background + composite |
| Enhancement, warmth, 2× upscale | Core Image (classic processing, labelled as non-generative) |
| Vertical (9:16) video version | AVFoundation crop/export |
| Media library | Folders, rename, favorites, delete, history, reopen, reuse prompt, metadata (prompt, model, provider, settings, local/remote, date), share, save to Photos |
| Provenance | IPTC Digital Source Type `trainedAlgorithmicMedia` + description on saved images; description/software metadata on videos; provider C2PA manifests preserved |
| Voice | On-device speech recognition, VAD, streaming TTS, barge-in |
| Memory, projects, encryption, network log, Offline-Only | As in v1.0 |

## 2. Partially supported locally

| Capability | Local part | Limitation |
|---|---|---|
| Natural-language image editing ("make it more realistic") | SD 2.1 image-to-image re-imagines the whole image from the original prompt plus the instruction | Not region-precise. Precise instruction-following edits need a remote provider (OpenAI, FLUX Kontext) |
| Object removal / replacement | Via image-to-image | No masked inpainting model is shipped locally; masked edits use OpenAI's edit endpoint |
| Aspect ratios for local SD | Center-crop of 512×512 output | Lower effective resolution for non-square output |
| Photorealism with Image Playground | — | Not available on the iOS 26 SDK the app is built with (iOS 27 adds it; requires Xcode 27) |
| Upscaling | 2× Lanczos plus sharpening | Not AI super-resolution |
| Video speech | On-device transcription, chunked | Speaker separation unavailable; transcription capped at 2/10/30 minutes by mode |
| Video object tracking | Per-frame detection labels | No continuous tracking |
| Video extension | Last frame extracted and clips joined locally | The new clip itself needs a connected video model |

## 3. Available only through connected providers (opt-in, require internet)

| Capability | Providers |
|---|---|
| Text-to-video, image-to-video | OpenAI Sora 2 (4/8/12 s, 720p portrait/landscape); fal.ai Veo 3 (8 s, optional audio), Kling 2.1 (5/10 s) |
| Video remix / refinement preserving intent | OpenAI remix endpoint; otherwise re-generation from original prompt + change |
| High-resolution / photoreal image generation, transparent backgrounds | OpenAI gpt-image (1024–1536 px), FLUX (fal.ai) |
| Precise instruction edits, masked edits | OpenAI image edits, FLUX Kontext |
| Connected Max (frontier reasoning) | Anthropic or any OpenAI-compatible provider |
| Web research, connectors | DuckDuckGo/Wikipedia (keyless), Firecrawl, Tavily, Brave, any MCP server |

Every remote request requires the matching toggle (off by default), is blocked by Offline-Only, is recorded in the local network log, and produces media or messages labelled **Remote**. Uploaded videos are never sent to cloud services for analysis.

## 4. Not currently technically practical (and therefore not offered)

| Capability | Why |
|---|---|
| Local video generation | State-of-the-art video diffusion models need tens of GB of memory and minutes of datacenter GPU time per clip; no open model produces usable video within an iPhone's ~6–8 GB per-app memory and thermal envelope |
| Local high-resolution (≥1024 px) photoreal image generation on iPhone | SDXL-class Core ML models exist but take minutes per image and risk memory termination; not shipped |
| Speaker diarization on device | No public iOS API |
| Speculative decoding for Qwen3.5 | Hybrid recurrent state can't be partially rolled back (see RESEARCH.md) |
| Using iOS 27 Image Playground features (photorealistic style, sizes, editing) | Requires the iOS 27 SDK, which the CI runner's Xcode 26.6 doesn't include |

## Intelligence modes × Creative Studio

| Mode | Media understanding | Generation |
|---|---|---|
| Instant | 8 key frames, labels and OCR, 2-minute transcript, fast image descriptions | Local first (Image Playground, then SD); no prompt rewriting |
| Thinking | 16 key frames with VLM captions, 10-minute transcript, multi-image comparison | Local model develops the prompt; local providers preferred |
| Max | 32 key frames, 16 captions, 30-minute transcript, multi-agent analysis | Prompt development, remote providers preferred **only if cloud generation is enabled**; otherwise local |

A mode never implies an unavailable capability. When nothing can serve a request, NEXUS explains what is missing and how to enable it, and never shows placeholder media.
