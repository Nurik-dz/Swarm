#!/bin/zsh
# Builds Swarm.app next to this script with the Command Line Tools (no Xcode),
# with libtorrent and OpenSSL copied inside the app, ad-hoc signed.
set -e
cd "$(dirname "$0")"
APP="build/Swarm.app"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk   # SDK 27 turns @State into a macro whose plugin only ships with Xcode
LT=$(brew --prefix libtorrent-rasterbar)
LTLIB=$(cd "$LT/lib" && pwd -P)
mkdir -p build
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# 1. The bridge (Objective-C++ around libtorrent). Flags from libtorrent-rasterbar.pc.
clang++ -std=c++17 -O2 -fobjc-arc -fexceptions -mmacosx-version-min=26.0 -isysroot "$SDK" \
  -I"$LT/include" -I/opt/homebrew/include \
  -DTORRENT_LINKING_SHARED -DBOOST_ASIO_NO_DEPRECATED -DBOOST_SYSTEM_USE_UTF8 -DTORRENT_ABI_VERSION=2 \
  -DTORRENT_USE_OPENSSL -DTORRENT_USE_LIBCRYPTO -DTORRENT_SSL_PEERS \
  -c Sources/Bridge/TorrentBridge.mm -o build/TorrentBridge.o

# 2. The app.
swiftc -swift-version 5 -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos26.0 \
  -import-objc-header Sources/Bridge/TorrentBridge.h \
  Sources/*/*.swift build/TorrentBridge.o \
  -L"$LTLIB" -ltorrent-rasterbar -lc++ \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$APP/Contents/MacOS/Swarm"

# 3. Copy libtorrent and the OpenSSL it uses into the app, pointing each at
#    the copies (so a Homebrew upgrade can never break Swarm).
bundle_lib() {   # $1 = path as referenced
  local src="$1" name=$(basename "$1") dep
  [ -f "$APP/Contents/Frameworks/$name" ] && return
  cp -L "$src" "$APP/Contents/Frameworks/$name"
  chmod u+w "$APP/Contents/Frameworks/$name"
  install_name_tool -id "@rpath/$name" "$APP/Contents/Frameworks/$name"
  for dep in $(otool -L "$src" | awk 'NR>1 {print $1}' | grep '^/opt/homebrew'); do
    bundle_lib "$dep"
    install_name_tool -change "$dep" "@rpath/$(basename $dep)" "$APP/Contents/Frameworks/$name"
  done
}
for top in $(otool -L "$APP/Contents/MacOS/Swarm" | awk 'NR>1 {print $1}' | grep '^/opt/homebrew'); do
  bundle_lib "$top"
  install_name_tool -change "$top" "@rpath/$(basename $top)" "$APP/Contents/MacOS/Swarm"
done
# Nothing may still point outside the app.
if otool -L "$APP"/Contents/MacOS/Swarm "$APP"/Contents/Frameworks/*.dylib | grep -q /opt/homebrew; then
  echo "error: a library still points at Homebrew"; exit 1
fi

cp Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

for lib in "$APP"/Contents/Frameworks/*.dylib; do codesign --force --sign - "$lib"; done
codesign --force --sign - -r='designated => identifier "com.nurik.swarm"' "$APP"
echo "Built $APP"
