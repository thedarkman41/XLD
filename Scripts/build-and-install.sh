#!/bin/bash
#
# build-and-install.sh — build XLD (Release), ad-hoc sign it, and install the
# signed app to ~/Applications, which is the canonical run location. The build
# itself goes to a throwaway derivedData dir (XLD_DERIVED_DATA, default
# ~/scratch/xld-dd) — that dir is pure build scratch and can be deleted any time;
# only ~/Applications/XLD.app is the app you run.
#
# Usage: Scripts/build-and-install.sh [--no-launch]
#
# Notes:
#  - This is an old project pinned to the 10.4u SDK, so the SDK/arch overrides
#    below are required (SDKROOT=macosx, x86_64 only — this is an Intel Mac).
#  - Code signing is disabled during the xcodebuild and done by hand afterward:
#    ~/Applications is on the /Volumes/Faraday file-provider volume, which stamps
#    com.apple.FinderInfo, so codesign fails unless we xattr -cr before AND after
#    signing (and sign nested bundles/frameworks first).
#
set -euo pipefail

# Resolve and prove the repo root (never trust cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ ! -f "$REPO/XLD/XLD_export.xcodeproj/project.pbxproj" ]; then
	echo "error: $REPO is not the XLD repo root (no XLD/XLD_export.xcodeproj)" >&2
	exit 1
fi

DD="${XLD_DERIVED_DATA:-$HOME/scratch/xld-dd}"
APPDIR="$HOME/Applications"
DEST="$APPDIR/XLD.app"
BUILT="$DD/Build/Products/Release/XLD.app"
LAUNCH=1
[ "${1:-}" = "--no-launch" ] && LAUNCH=0

mkdir -p "$APPDIR"

echo "==> Building XLD (Release) -> $DD"
xcodebuild -project "$REPO/XLD/XLD_export.xcodeproj" -scheme XLD -configuration Release \
	-derivedDataPath "$DD" \
	SDKROOT=macosx MACOSX_DEPLOYMENT_TARGET=10.13 ARCHS=x86_64 VALID_ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
	GCC_VERSION=com.apple.compilers.llvm.clang.1_0 \
	CODE_SIGN_IDENTITY="" CODE_SIGNING_ALLOWED=NO \
	OTHER_LDFLAGS='$(inherited) -L/usr/local/lib -lsndfile -lcddb -lsoxr -lcrypto -framework SystemConfiguration' \
	build

if [ ! -d "$BUILT" ]; then
	echo "error: build product not found at $BUILT" >&2
	exit 1
fi

echo "==> Quitting any running XLD"
osascript -e 'tell application "XLD" to quit' 2>/dev/null || true
for _ in $(seq 1 8); do pgrep -x XLD >/dev/null || break; sleep 1; done
if pgrep -x XLD >/dev/null; then pkill -x XLD || true; sleep 1; fi

echo "==> Installing to $DEST"
rm -rf "$DEST"
/bin/cp -R "$BUILT" "$DEST"

echo "==> Signing $DEST (xattr dance for the Faraday file-provider volume)"
/usr/bin/xattr -cr "$DEST"
find "$DEST/Contents/PlugIns" "$DEST/Contents/Frameworks" -maxdepth 1 \
	\( -name "*.bundle" -o -name "*.framework" \) 2>/dev/null | while read -r b; do
	/usr/bin/xattr -cr "$b"
	/usr/bin/codesign --force --sign - "$b" >/dev/null 2>&1 || true
done
/usr/bin/codesign --force --deep --sign - "$DEST"
/usr/bin/xattr -cr "$DEST"
/usr/bin/codesign --verify --deep --strict "$DEST"
echo "    signed + verified"

if [ "$LAUNCH" = "1" ]; then
	echo "==> Launching $DEST"
	open "$DEST"
	sleep 2
	echo "    pid: $(pgrep -x XLD || echo none)"
fi

echo "==> Done. XLD installed at $DEST"
echo "    (build scratch $DD is disposable; delete it any time to reclaim space)"
