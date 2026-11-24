#!/bin/zsh
# The live check of the endpoint calls through the shared Rust core (Tests/CoreTransportLiveCheck.swift), on a Mac
# after mac/build-rust.sh: it builds the VersoCore module as the Xcode project does, then the client's API files
# with the check, and runs it. IMMICH_URL, IMMICH_EMAIL and IMMICH_PASSWORD choose the server and the account;
# Immich's public demo by default.
#
#   mac/Verso/check-core.sh
set -euo pipefail
cd "$(dirname "$0")"
bridge=../build
out=build/core-check
mkdir -p "$out"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

# The bindings for Swift 5's checking, as in the project (project.yml, VersoCore).
swiftc -parse-as-library -emit-library -static -emit-module -module-name VersoCore -swift-version 5 \
  -I "$bridge/headers" "$bridge/Generated/verso_bridge.swift" VersoCore/CoreConnection.swift \
  -emit-module-path "$out/VersoCore.swiftmodule" -o "$out/libVersoCore.a"
swiftc -parse-as-library -swift-version 6 -I "$out" -I "$bridge/headers" \
  Verso/API/*.swift Verso/Core/CoreTransport.swift Verso/App/CoreTimeline.swift Verso/Support/Formatters.swift Tests/CoreTransportLiveCheck.swift \
  "$out/libVersoCore.a" "$bridge/universal/libverso_bridge.a" \
  -framework Security -framework SystemConfiguration -o "$out/check"
"$out/check"
