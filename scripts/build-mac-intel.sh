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
# Missing prerequisites (Homebrew, Bun, Rust, cmake) are installed automatically.
# Xcode Command Line Tools can't be installed non-interactively (Apple's
# installer is a GUI popup), so that one still requires a manual re-run.
#
# Over SSH: the DMG bundler drives Finder via AppleScript to style the
# installer window, which needs a WindowServer connection an SSH shell
# doesn't have — it fails with AppleEvent timeout (-1712). When run over
# SSH, this script exports CI=true, which Tauri's bundle_dmg.sh checks
# (tauri-apps/tauri#592) to skip that styling step and produce a plain DMG.
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

if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" && -z "${CI:-}" ]]; then
  echo "Running over SSH: exporting CI=true to skip the DMG's Finder AppleScript styling step (needs a GUI session)."
  export CI=true
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are missing. Launching the installer..."
  xcode-select --install
  echo "ERROR: finish the Xcode Command Line Tools install (GUI popup), then re-run this script." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is missing. Installing..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  if [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  elif [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew install failed or isn't on PATH. See https://brew.sh/" >&2
  exit 1
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "Bun is missing. Installing..."
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "ERROR: Bun install failed or isn't on PATH. See https://bun.sh/" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust/Cargo is missing. Installing..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: Rust install failed or isn't on PATH. See https://rustup.rs/" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is missing. Installing via Homebrew..."
  brew install cmake
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
has_config=0
for arg in "$@"; do
  if [[ "$arg" == "--dev" ]]; then
    mode="dev"
  else
    [[ "$arg" == "--config" ]] && has_config=1
    args+=("$arg")
  fi
done

# Without a TAURI_SIGNING_PRIVATE_KEY, the updater artifact step fails the
# whole build even though the .app/.dmg bundled fine. Since this is an
# unsigned test build (no signing keys configured), disable updater
# artifacts by default — same override the CI fork-build workflow uses.
if [[ "$mode" == "build" && $has_config -eq 0 && -z "${TAURI_SIGNING_PRIVATE_KEY:-}" ]]; then
  args+=(--config '{"bundle":{"createUpdaterArtifacts":false}}')
fi

echo "Running: tauri $mode ${args[*]-}"
export ORT_LIB_LOCATION="$(brew --prefix onnxruntime)/lib"
export ORT_PREFER_DYNAMIC_LINK=1
export CMAKE_POLICY_VERSION_MINIMUM=3.5

exec bun run "tauri" "$mode" "${args[@]+"${args[@]}"}"
