#!/bin/zsh
# Builds one of the app-level tests against the real app sources, then runs it.
#   Tests/run.sh harness light swiftui        crash stress (set FRAME=h and FASTHUMAN=1 or HUMAN=1)
#   Tests/run.sh states <out-dir> <dl-dir>    draws every torrent state (needs internet)
#   Tests/run.sh play <dl-dir>                real torrent: plays while downloading, seeks (internet)
#   Tests/run.sh stream <dir> <dl> <seed-state> [KB/s]   local seeder, audiobook with index at end
#   Tests/run.sh subs <dir> <dl> <seed-state>            local seeder, subtitles
# Always set SWARM_STATE_DIR to a scratch folder so the real torrents are never touched.
# (Standalone ones: Tests/smart/build.sh, Tests/schedule/build.sh, Tests/subtitles via swiftc, see the guide.)
# NOBUILD=1 runs the last build again (for loops); the first run of a loop builds.
set -e
cd "$(dirname "$0")/.."
NAME="$1"; shift
if [ "$NOBUILD" = "1" ] && [ -x "build/$NAME" ]; then exec "build/$NAME" "$@"; fi
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
LT=$(brew --prefix libtorrent-rasterbar)
[ -f build/TorrentBridge.o ] || ./build.sh >/dev/null
# SwarmApp.swift has @main, which clashes with a test's main.swift: compile it without.
TMP=$(mktemp -d)
sed 's/^@main//' Sources/App/SwarmApp.swift > "$TMP/SwarmApp.swift"
swiftc -swift-version 5 -O -sdk "$SDK" -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Bridge/TorrentBridge.h \
  "Tests/$NAME/main.swift" "$TMP/SwarmApp.swift" $(ls Sources/{App,Model,Views,System}/*.swift | grep -v SwarmApp.swift) \
  build/TorrentBridge.o -L"$LT/lib" -ltorrent-rasterbar -lc++ -Xlinker -rpath -Xlinker "$LT/lib" -o "build/$NAME" 2>&1 | grep -E "error" || true
rm -rf "$TMP"
exec "build/$NAME" "$@"
