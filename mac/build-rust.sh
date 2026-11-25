#!/usr/bin/env bash
# Build the bridge (shared/verso-bridge) for the Xcode projects: a static library for both Mac architectures, and with
# --ios one for the iPhone and one for the Simulator on an Apple silicon Mac, its Swift bindings, and an xcframework
# that wraps them (ARCHITECTURE.md, "Verso Drive on the Mac"), the apps' translations, and their version for Xcode.
# Runs on a Mac with the Rust targets added; xcodegen reads the results from mac/build/, for the Mac's project and for
# iOS's (ios/).
#
#   mac/build-rust.sh [debug|release] [--ios] [--tvos]      (release when not given)
#
# --tvos adds the Apple TV and its Simulator (ROADMAP.md, "Verso on the Apple TV"). Rust ships no standard library for
# tvOS, so those two are built with the nightly toolchain, which builds its own (`-Z build-std`):
# `rustup toolchain install nightly --profile minimal --component rust-src`, once.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: mac/build-rust.sh [debug|release] [--ios] [--tvos]"
profile=release
ios=no
tvos=no
for argument in "$@"; do
  case "$argument" in
    release | debug) profile=$argument ;;
    --ios) ios=yes ;;
    --tvos) tvos=yes ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
# Never an empty array: macOS's bash 3.2 calls one unbound under `set -u`.
case "$profile" in
  release) cargo_profile=(--release) ;;
  debug) cargo_profile=(--profile dev) ;;
esac
out=mac/build
# The release line's version (ci/version.sh), built into the core as Verso's Linux builds have it
# (`verso_core::product::VERSION`): Verso's Mac app says it in its user agent.
export VERSO_VERSION=$(ci/version.sh)
# The oldest macOS and iOS the apps run on (their project.yml's deploymentTarget): rustc and the C compiler behind
# ring and oslog both read them. Without them the C parts are built for the SDK's own version, newer than the apps'.
export MACOSX_DEPLOYMENT_TARGET=15.0
export IPHONEOS_DEPLOYMENT_TARGET=26.1
export TVOS_DEPLOYMENT_TARGET=26.0

# Where Homebrew's `rust` formula is installed beside Homebrew's rustup, its cargo comes first on the PATH and has only
# the host's standard library; rustup's own cargo has both targets. Put it first, for this script only.
if command -v brew >/dev/null && [ -x "$(brew --prefix rustup 2>/dev/null)/bin/cargo" ]; then
  PATH="$(brew --prefix rustup)/bin:$PATH"
fi
targets=(aarch64-apple-darwin x86_64-apple-darwin)
# The iPhone, and the Simulator on an Apple silicon Mac (the only Macs that build Verso for iOS).
ios_targets=(aarch64-apple-ios aarch64-apple-ios-sim)
# The Apple TV, and its Simulator on an Apple silicon Mac.
tvos_targets=(aarch64-apple-tvos aarch64-apple-tvos-sim)

libraries=()
for target in "${targets[@]}"; do
  cargo build -p verso-bridge --lib "${cargo_profile[@]}" --target "$target"
  libraries+=("target/$target/$profile/libverso_bridge.a")
done
# One library per platform in the xcframework: the Mac's two architectures in one, then the iPhone's and the
# Simulator's, each with the same headers.
platforms=(-library "$out/universal/libverso_bridge.a" -headers "$out/headers")
if [ "$ios" = yes ]; then
  for target in "${ios_targets[@]}"; do
    cargo build -p verso-bridge --lib "${cargo_profile[@]}" --target "$target"
    platforms+=(-library "target/$target/$profile/libverso_bridge.a" -headers "$out/headers")
  done
fi
if [ "$tvos" = yes ]; then
  for target in "${tvos_targets[@]}"; do
    cargo +nightly build -p verso-bridge --lib "${cargo_profile[@]}" -Z build-std=std,panic_abort --target "$target"
    platforms+=(-library "target/$target/$profile/libverso_bridge.a" -headers "$out/headers")
  done
fi

rm -rf "$out/VersoBridge.xcframework" "$out/Generated" "$out/headers" "$out/universal"
mkdir -p "$out/Generated" "$out/headers" "$out/universal"
lipo -create "${libraries[@]}" -output "$out/universal/libverso_bridge.a"

# The bindings come from the library's own metadata, so they always match what was built.
cargo run -q -p verso-bridge --features bindgen --bin uniffi-bindgen -- generate \
  --library "target/${targets[0]}/$profile/libverso_bridge.dylib" --language swift --out-dir "$out/Generated"
mv "$out/Generated/verso_bridgeFFI.h" "$out/headers/"
mv "$out/Generated/verso_bridgeFFI.modulemap" "$out/headers/module.modulemap"

xcodebuild -create-xcframework "${platforms[@]}" -output "$out/VersoBridge.xcframework" >/dev/null

# The app's texts in every language, from the catalogs the Linux apps read too (ARCHITECTURE.md, "Translations").
rm -rf "$out/Localization"
python3 po/i18n.py apple "$out/Localization"

# The release line's version (ci/version.sh), the same as the Linux packages', and the build number, the build's UTC
# time to the minute (20261122.1435), which rises with every build as TestFlight, the App Store and Sparkle need, also
# between two builds of one version; Config/Base.xcconfig reads them.
printf 'MARKETING_VERSION = %s\nCURRENT_PROJECT_VERSION = %s\n' "$(ci/version.sh)" "$(date -u +%Y%m%d.%H%M)" \
  > "$out/Version.xcconfig"
echo "built $out/VersoBridge.xcframework and $out/Generated/verso_bridge.swift ($profile$([ "$ios" = yes ] && echo ', with iOS')$([ "$tvos" = yes ] && echo ', with tvOS'))"
