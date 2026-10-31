# Benchmarks and evaluation

## Status of results

**No on-device numbers are published here yet.** This app was built and compiled on CI (macOS runners have no iPhone GPU), so no measurements on physical iPhones have been taken. Publishing estimates as measurements would be fabrication. Run the built-in tools on your device to get real numbers; they are stored locally and can be exported as JSON from the dashboard.

What *is* verified automatically on every build:

* the full app compiles for `iphoneos` with the iOS 26 SDK against llama.cpp b12018;
* a logic test suite (calculator, streaming output parser, UTF-8 decoding, chat templates, task classifier, plan parser, registry integrity, embeddings) runs on the macOS runner and must pass before the app is built (see `Tests/LogicTests`).

## Performance benchmark (Settings → Benchmarks & evaluation)

For a chosen model and mode, the runner:

1. unloads the model and measures a **cold load time**;
2. runs a short prompt → **time to first token (TTFT)**;
3. runs a sustained generation (128 tokens in Instant, 256 otherwise) → **decode tokens/second**;
4. runs a ~1,500-token prompt → **prompt-processing tokens/second** and long-prompt TTFT;
5. samples the app's `phys_footprint` every 100 ms → **peak memory**;
6. records **thermal state** and **battery level** before and after. iOS reports battery in coarse steps, so short runs often show no change, and that is reported as-is.

Each result records device, model, quantization, context size, mode and date. Apple Intelligence runs out of process, so its memory is not included in the app footprint; its token counts are estimates, which the result notes say explicitly.

## Evaluation suite (`nexus-eval-1.0`, 29 cases)

Identical prompts are sent through the **full NEXUS pipeline** (routing pinned to the chosen model, tools, verification), with personal memory disabled for isolation. Every case is graded automatically, with no LLM-as-judge:

| Group | Cases | Grading |
|---|---|---|
| Reasoning | time arithmetic, unit pricing, percentage (tool use), algebra, geometry, ordering logic, prime counting, series sum, schedule planning, ambiguous instruction | exact numeric answer within tolerance; clarification detection |
| Coding | palindrome, FizzBuzz, debugging, numeric-sort pitfall, test creation, code review | **generated JavaScript is executed** against test assertions in an isolated JavaScriptCore sandbox; regex/keyword checks for test-writing and review |
| General | exact list format, lowercase constraint, JSON output, word limit, knowledge (×2), explanation, multi-turn context retention, **2 hallucination probes about fictional works/treaties** | format validators, JSON parsing, keyword checks, uncertainty detection |
| Multimodal | invoice screenshot (OCR), red-circle visual question (needs a real vision model), document question | generated test images (rendered on device, deterministic) and keyword checks |

Reported per run: pass rate per group, **hallucination rate** (fictional-entity probes answered as if real), **math/tool-use success**, **median latency**, and per-case output, grader explanation and tools used.

### Comparing with external systems

Configure a cloud provider (e.g. Anthropic or OpenAI) in Settings, then choose it as the evaluation target. The same 29 prompts run through the same pipeline, so local models and frontier APIs are compared under identical conditions. Cloud latency includes network time.

### How results are used

The router replaces its prior for a (model, category) pair with `10 × pass-rate` from your latest completed run once at least two cases cover that category. Measured scores show in green in the model detail and comparison views; priors (from publisher-reported benchmarks, not NEXUS measurements) show in blue.

### Caveats

* 29 cases is a smoke-level suite: small differences between models are not statistically meaningful.
* The scores are pass rates on this suite, not a general intelligence measure.
* Sampling uses non-zero temperature in Thinking/Max modes, so repeated runs vary slightly.
