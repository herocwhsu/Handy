#!/usr/bin/env bash
#
# Build (or run in dev mode) Handy on Intel Mac (x86_64-apple-darwin).
#
# Prebuilt ONNX Runtime binaries for current versions aren't published for
# Intel Macs, so this links against Homebrew's onnxruntime dynamically
# (ORT_LIB_LOCATION + ORT_PREFER_DYNAMIC_LINK). It also sets
# CMAKE_POLICY_VERSION_MINIMUM=3.5, needed on newer CMake versions to build
# transcribe-cpp's bundled dependencies that predate CMake's current
# minimum-policy requirement.
#
# Homebrew has no bottle for onnxruntime on macOS 13/Ventura and older
# (Tier 3 unsupported) and building it from source there routinely fails
# outright. If `brew install onnxruntime` fails, this script falls back to
# Microsoft's last prebuilt Intel macOS release (1.20.0 — they stopped
# publishing osx-x86_64 binaries after that), cached under
# ~/.cache/handy-build/ so the fallback only downloads once.
#
# On a production build, the onnxruntime dylib is then copied into
# Handy.app/Contents/Frameworks and the binary is repointed to load it
# @executable_path-relative — so the resulting .app/.dmg is self-contained
# and runs on other Intel Macs without them needing onnxruntime installed
# at all.
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

# Homebrew has no bottle for onnxruntime on macOS 13/Ventura and older (Tier 3
# unsupported), and building it from source there routinely fails outright —
# deep in onnxruntime's own CMake build, not something this script can work
# around. When that happens, fall back to Microsoft's last prebuilt Intel
# macOS release (they stopped publishing osx-x86_64 binaries after 1.20.0).
ONNXRUNTIME_PREBUILT_VERSION="1.20.0"
ONNXRUNTIME_PREBUILT_DIR="$HOME/.cache/handy-build/onnxruntime-osx-x86_64-${ONNXRUNTIME_PREBUILT_VERSION}"
USING_PREBUILT_ORT=0

if [[ -d "$ONNXRUNTIME_PREBUILT_DIR/lib" ]]; then
  echo "Using cached prebuilt onnxruntime at $ONNXRUNTIME_PREBUILT_DIR"
  USING_PREBUILT_ORT=1
elif ! brew list onnxruntime >/dev/null 2>&1; then
  echo "Installing onnxruntime via Homebrew..."
  if brew install onnxruntime; then
    :
  else
    echo "WARNING: brew install onnxruntime failed (expected on macOS 13/Ventura" >&2
    echo "and older — see docs.brew.sh/Support-Tiers). Falling back to Microsoft's" >&2
    echo "prebuilt ONNX Runtime ${ONNXRUNTIME_PREBUILT_VERSION} for Intel macOS." >&2
    mkdir -p "$(dirname "$ONNXRUNTIME_PREBUILT_DIR")"
    archive="$(mktemp -t onnxruntime-prebuilt).tgz"
    curl -fL -o "$archive" \
      "https://github.com/microsoft/onnxruntime/releases/download/v${ONNXRUNTIME_PREBUILT_VERSION}/onnxruntime-osx-x86_64-${ONNXRUNTIME_PREBUILT_VERSION}.tgz"
    tar xzf "$archive" -C "$(dirname "$ONNXRUNTIME_PREBUILT_DIR")"
    rm -f "$archive"
    USING_PREBUILT_ORT=1
  fi
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
if [[ "$USING_PREBUILT_ORT" -eq 1 ]]; then
  ORT_LIB_DIR="$ONNXRUNTIME_PREBUILT_DIR/lib"
else
  ORT_LIB_DIR="$(brew --prefix onnxruntime)/lib"
fi
export ORT_LIB_LOCATION="$ORT_LIB_DIR"
export ORT_PREFER_DYNAMIC_LINK=1
export CMAKE_POLICY_VERSION_MINIMUM=3.5

bun run "tauri" "$mode" "${args[@]+"${args[@]}"}"

# Bundle onnxruntime's dylib into the .app so other machines don't need
# onnxruntime installed at all. Homebrew's build links it at an absolute
# Homebrew path, which breaks on any machine that doesn't have the exact
# same brew install (see AGENTS.md/BUILD.md); Microsoft's prebuilt release
# links it @rpath-relative already, so it only needs an rpath added, not a
# reference rewrite.
if [[ "$mode" == "build" ]]; then
  APP_PATH="src-tauri/target/release/bundle/macos/Handy.app"
  BIN_PATH="$APP_PATH/Contents/MacOS/handy"
  if [[ "$USING_PREBUILT_ORT" -eq 1 ]]; then
    ORT_DYLIB_NAME="libonnxruntime.${ONNXRUNTIME_PREBUILT_VERSION}.dylib"
  else
    ORT_DYLIB_NAME="libonnxruntime.1.dylib"
  fi
  ORT_DYLIB_SRC="$ORT_LIB_DIR/$ORT_DYLIB_NAME"

  if [[ -f "$BIN_PATH" ]] && otool -L "$BIN_PATH" | grep -q "$ORT_DYLIB_NAME"; then
    echo "Bundling onnxruntime dylib into Handy.app for portability..."
    mkdir -p "$APP_PATH/Contents/Frameworks"
    cp -L "$ORT_DYLIB_SRC" "$APP_PATH/Contents/Frameworks/$ORT_DYLIB_NAME"
    if [[ "$USING_PREBUILT_ORT" -eq 1 ]]; then
      # Already @rpath/libonnxruntime.*.dylib — just give the binary an rpath
      # that resolves it inside the bundle. -f (force) is a no-op if a build
      # was already patched and re-run.
      install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN_PATH" 2>/dev/null || true
    else
      install_name_tool -change "$ORT_DYLIB_SRC" "@executable_path/../Frameworks/$ORT_DYLIB_NAME" "$BIN_PATH"
    fi
    codesign --force --deep --sign - "$APP_PATH"
    echo "Verifying onnxruntime reference is now bundle-relative:"
    otool -L "$BIN_PATH" | grep -i onnxruntime

    DMG_PATH=$(find src-tauri/target/release/bundle/dmg -maxdepth 1 -name "*.dmg" 2>/dev/null | head -1 || true)
    if [[ -n "$DMG_PATH" ]]; then
      echo "Regenerating $DMG_PATH from the now-self-contained app..."
      rm -f "$DMG_PATH"
      hdiutil create -volname Handy -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
    fi
  fi
fi
