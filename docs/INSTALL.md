# Installing NEXUS AI

## Option A — Install the prebuilt IPA (no Mac required)

Every push to `main` is built by GitHub Actions on a macOS runner (Xcode 26, iOS 26 SDK) and published as a release:

**https://github.com/surproductions/Nexus-Ai/releases/latest/download/NexusAI.ipa**

The IPA is **unsigned**, because no Apple signing identity is available to the build server. iOS only installs signed apps, so a sideloading tool re-signs it with your Apple ID:

* **AltStore / SideStore** (free Apple ID): add the IPA from Files → My Apps → `+`. Free accounts must refresh every 7 days.
* **Sideloadly** (Mac/Windows): drag the IPA in, enter your Apple ID, install.
* **Your own developer account**: `codesign`/`zsign` or Xcode (see Option B).

The release also includes `NexusAI.ipa.sha256` so you can verify the download:

```bash
shasum -a 256 NexusAI.ipa   # compare with NexusAI.ipa.sha256
```

Requirements: iPhone with A15 Bionic or newer (iPhone 13 and later) on iOS 17 or later. Apple Intelligence features need iOS 26 on a supported device. Local models need free storage for their weights (0.5–5.2 GB each).

## Option B — Build from source with Xcode

Requirements: a Mac with Xcode 26 (iOS 26 SDK) and Homebrew.

```bash
git clone https://github.com/surproductions/Nexus-Ai.git
cd Nexus-Ai
./scripts/bootstrap.sh          # fetches llama.xcframework (b12018) and generates NexusAI.xcodeproj
open NexusAI.xcodeproj
```

In Xcode:

1. Select the **NexusAI** target → **Signing & Capabilities** → choose your Team. Change the bundle identifier (`ai.nexus.assistant`) if it's taken.
2. *(Paid accounts, recommended)* Keep the **Increased Memory Limit** capability (`NexusAI/Resources/NexusAI.entitlements`). It lets larger models fit. Free accounts: remove the entitlement file from build settings if signing fails.
3. Pick your iPhone as the run destination and press **Run**. The simulator is not supported because llama.cpp's xcframework ships device slices only, and local LLM inference needs the device GPU.

### Archive a signed IPA

```bash
xcodebuild -project NexusAI.xcodeproj -scheme NexusAI -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/NexusAI.xcarchive archive \
  DEVELOPMENT_TEAM=YOURTEAMID
xcodebuild -exportArchive -archivePath build/NexusAI.xcarchive \
  -exportOptionsPlist exportOptions.plist -exportPath build/ipa
```

with an `exportOptions.plist` whose `method` is `development`, `ad-hoc` or `app-store-connect`.

## First run

1. The onboarding screen shows your device's profile (Low / Balanced / High performance).
2. Open **Models**. The header recommends models for your device; each row shows whether it fits in memory. Qwen3.5 2B (1.3 GB) is a good first download, Qwen3.5 4B for Thinking mode. Add the *vision adapter* for image understanding.
3. Downloads run in the background, can be paused and resumed, and are verified against SHA-256 before use.
4. Return to **Chat**, pick **Instant / Thinking / Max**, and start. Everything runs on device unless you enable web research or a cloud provider under **Settings → Privacy & network**.

You can also copy your own `.gguf` files into NEXUS's folder in the Files app; they are imported automatically.
