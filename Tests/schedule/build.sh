#!/bin/zsh
# Builds and runs the schedule-window checks.
set -e
cd "$(dirname "$0")/../.."
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-macos26.0 Tests/schedule/main.swift Sources/Model/Prefs.swift -o build/schedule
build/schedule
