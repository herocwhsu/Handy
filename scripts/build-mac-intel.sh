#!/usr/bin/env bash
#
# Build (or run in dev mode) Handy on Intel Mac (x86_64-apple-darwin).
#
# Prebuilt ONNX Runtime binaries aren't published for Intel Macs, so this
# links against Homebrew's onnxruntime dynamically (ORT_LIB_LOCATION +
# ORT_PREFER_DYNAMIC_LINK). It also sets CMAKE_POLICY_VERSION_MINIMUM=3.5,
# needed on newer CMake versions to build transcribe-cpp's bundled
# dependencies that predate CMake's current minimum-policy requirement.
#
# Usage:
#   scripts/build-mac-intel.sh          # production build (bun run tauri build)
#   scripts/build-mac-intel.sh --dev    # dev server (bun run tauri dev)
#
# Any extra args are passed through to the underlying `bun run tauri` command.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this script only supports macOS." >&2
  exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "ERROR: this script is for Intel Macs (x86_64). Detected $(uname -m)." >&2
  echo "Apple Silicon Macs use the prebuilt ONNX Runtime and don't need this script." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew is required (https://brew.sh/) to install onnxruntime." >&2
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "ERROR: Bun is required (https://bun.sh/)." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: Rust/Cargo is required (https://rustup.rs/)." >&2
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "ERROR: Xcode Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

if ! brew list onnxruntime >/dev/null 2>&1; then
  echo "Installing onnxruntime via Homebrew..."
  brew install onnxruntime
fi

VAD_MODEL="src-tauri/resources/models/silero_vad_v4.onnx"
if [[ ! -f "$VAD_MODEL" ]]; then
  echo "Downloading VAD model..."
  mkdir -p "$(dirname "$VAD_MODEL")"
  curl -fL -o "$VAD_MODEL" https://blob.handy.computer/silero_vad_v4.onnx
fi

bun install

mode="build"
args=()
for arg in "$@"; do
  if [[ "$arg" == "--dev" ]]; then
    mode="dev"
  else
    args+=("$arg")
  fi
done

echo "Running: tauri $mode ${args[*]-}"
export ORT_LIB_LOCATION="$(brew --prefix onnxruntime)/lib"
export ORT_PREFER_DYNAMIC_LINK=1
export CMAKE_POLICY_VERSION_MINIMUM=3.5

exec bun run "tauri" "$mode" "${args[@]+"${args[@]}"}"
