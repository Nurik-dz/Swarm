#!/bin/zsh
# Builds and runs the nearby-Mac message checks (offline, no libtorrent needed).
set -e
cd "$(dirname "$0")/../.."
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-macos26.0 Tests/lanprotocol/main.swift Sources/Model/LanProtocol.swift -o build/lanprotocol
build/lanprotocol
