#!/usr/bin/env bash
# Prepares a buildable Xcode project on a Mac:
#   1. downloads the pinned llama.cpp XCFramework (or builds it from source if the asset is missing)
#   2. generates NexusAI.xcodeproj with XcodeGen
set -euo pipefail
cd "$(dirname "$0")/.."

LLAMA_TAG="${LLAMA_TAG:-$(grep -E '^\s*LLAMA_TAG:' .github/workflows/ios.yml | awk '{print $2}')}"
echo "llama.cpp tag: ${LLAMA_TAG}"

if [ ! -d Vendor/llama.xcframework ]; then
  mkdir -p Vendor
  URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-xcframework.zip"
  TMP="$(mktemp -d)"
  if curl -fL -o "$TMP/llama.zip" "$URL"; then
    unzip -q "$TMP/llama.zip" -d "$TMP/x"
    mv "$(find "$TMP/x" -maxdepth 3 -name llama.xcframework -type d | head -1)" Vendor/llama.xcframework
  else
    echo "Release asset not found; building from source (takes a while)…"
    git clone --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$TMP/src"
    (cd "$TMP/src" && ./build-xcframework.sh ios-device)
    mv "$TMP/src/build-apple/llama.xcframework" Vendor/llama.xcframework
  fi
  rm -rf "$TMP"
fi

command -v xcodegen >/dev/null || { echo "Installing XcodeGen via Homebrew…"; brew install xcodegen; }
xcodegen generate
echo "Done. Open NexusAI.xcodeproj, select your Team under Signing & Capabilities, and run on a physical iPhone."
