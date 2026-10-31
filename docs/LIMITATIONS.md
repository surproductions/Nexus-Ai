# Known limitations

Stated plainly, as the project brief requires.

## Not verified on physical hardware
The app was developed in a Linux container and compiled on GitHub's macOS runners. **It has not been run on a physical iPhone by the author.** The logic tests pass and the app compiles cleanly. The following have not been exercised end to end on a device:
* llama.cpp generation speed and memory use for each catalog model;
* vision through `mtmd` with each model's `mmproj` adapter;
* background downloads of multi-GB files and SHA-256 verification time;
* voice mode (VAD thresholds were chosen from typical iPhone microphone levels and may need tuning);
* Apple Foundation Models streaming on iOS 26 devices.

Please report issues with device model, iOS version and the trace (long-press a message → Reasoning trace).

## Distribution
* The CI-built IPA is **unsigned**. It must be re-signed by a sideloading tool or your own developer account. Free Apple IDs expire sideloaded apps after 7 days.
* The `increased-memory-limit` entitlement only takes effect with a paid developer account that has the capability enabled. Without it, 9B models may not fit even on 12 GB iPhones; the app will refuse to load them rather than crash.

## Intelligence
* On-device models (0.8B–9B) are much smaller than frontier cloud models. Planning, tools and verification improve reliability, but knowledge breadth and deep reasoning are bounded by model size. The app says so in Max mode when a small model is used.
* The router's initial quality scores are priors from publisher-reported benchmarks until you run the evaluation suite on your device.
* Max mode can take minutes on a phone (several model calls, possibly a model swap).
* Only one llama.cpp model is resident at a time.
* No speculative decoding (see RESEARCH.md for why).
* Apple Intelligence has a 4K context and no image input. Its tokens per second are estimated from text length.

## Multimodal
* Full image understanding requires downloading a model's vision adapter (0.2–1 GB). Without one, images are described using Apple Vision OCR, classification and barcode detection only. The model is told it cannot see the image.
* No audio-input models; voice uses Apple's speech recognizer.
* Supported documents: PDF (with OCR for scanned pages), plain text, Markdown, RTF, HTML, JSON, CSV, source code, images. No DOCX/XLSX/PPTX parsing.

## Network features
* Keyless web search scrapes DuckDuckGo's HTML endpoint and Wikipedia; it may break if those pages change. A Brave Search API key is more reliable.
* Web pages are converted to text with a lightweight HTML stripper, not a full readability engine.

## iOS platform
* Generation stops when the app is backgrounded (iOS policy); downloads continue.
* The simulator is unsupported (the llama.cpp xcframework has no simulator slice).
* JavaScript evaluation for tools and tests uses JavaScriptCore on a separate thread with a 3-second wait. A runaway script cannot be force-killed and keeps its thread busy until it finishes.
