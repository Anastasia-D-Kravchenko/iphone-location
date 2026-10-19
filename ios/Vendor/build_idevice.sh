#!/bin/zsh
# Rebuilds Vendor/idevice/libidevice_ffi.a + idevice.h (not in git: the library is ~200 MB).
# idevice (MIT, github.com/jkcoxson/idevice) at a fixed commit + IDEVICE_PATCH.diff, which adds:
#   pairable_host_accept_ext       iOS 27 "pair with host" flow without Rust mDNS (Bonjour from Swift)
#   tunnel_create_rppairing_ble    Apple Watch tunnel: RemotePairing over a Bluetooth control channel
#   coredevice_location_set/clear  CoreDevice location service (the one `devicectl simulate location` uses)
# Needs Rust (rustup) with: rustup target add aarch64-apple-ios
set -euo pipefail
cd "$(dirname "$0")"
REV=3854a5df4a5a6dee71ffce4d8befc2ea356a8065
WORK="${IDEVICE_SRC:-${TMPDIR:-/tmp}/idevice-src}"
[[ -d "$WORK/.git" ]] || git clone https://github.com/jkcoxson/idevice "$WORK"
git -C "$WORK" fetch -q origin
git -C "$WORK" checkout -q "$REV" 2>/dev/null || true
git -C "$WORK" reset -q --hard "$REV"
git -C "$WORK" apply "$PWD/idevice/IDEVICE_PATCH.diff"
(cd "$WORK/ffi" && IPHONEOS_DEPLOYMENT_TARGET=18.0 cargo build --release --target aarch64-apple-ios)
cp "$WORK/target/aarch64-apple-ios/release/libidevice_ffi.a" idevice/
cp "$WORK/ffi/idevice.h" idevice/
git -C "$WORK" reset -q --hard "$REV"   # leave the checkout clean for the next run
echo "Done: Vendor/idevice/libidevice_ffi.a"
