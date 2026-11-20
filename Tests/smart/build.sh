#!/bin/zsh
# Builds and runs the SmartPicks checks. usage: Tests/smart/build.sh
set -e
cd "$(dirname "$0")/../.."
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Bridge/TorrentBridge.h \
  Tests/smart/main.swift Sources/Model/Smart.swift Sources/Model/Torrent.swift Sources/Model/Format.swift build/TorrentBridge.o \
  -L"$(brew --prefix libtorrent-rasterbar)/lib" -ltorrent-rasterbar -lc++ -o build/smart
build/smart
