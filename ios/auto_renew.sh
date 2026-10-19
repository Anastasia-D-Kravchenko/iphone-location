#!/bin/zsh
# Run by a login agent (see README) every 6 hours.
# Reinstalls the Location app (fresh 7-day free signing) when it expires in < 48 h
# and the iPhone is reachable (cable or same Wi-Fi). Otherwise does nothing.
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
cd "$(dirname "$0")"
set -a; source ./local.env; set +a
DEVICE=$IPHONE_UDID
APP=build/Build/Products/Release-iphoneos/LocationRemote.app
LOG=auto_renew.log
note() { osascript -e "display notification \"$1\" with title \"Location app\"" >/dev/null 2>&1; }
say() { echo "$(date '+%F %T') $1" >> $LOG; }

expiry=$(security cms -D -i $APP/embedded.mobileprovision 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
left=999999
if [[ -n $expiry ]]; then
  left=$(( $(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expiry" +%s) - $(date +%s) ))
fi
[[ -n ${FORCE:-} ]] && left=0
if (( left > 48 * 3600 )); then
  say "ok, $(( left / 3600 )) h left (expires $expiry)"
  exit 0
fi

if ! xcrun devicectl device info details --device $DEVICE 2>&1 | grep -q "Device State: connected"; then
  # Ask CoreDevice to connect (works on the same Wi-Fi), then check again.
  xcrun devicectl device info lockState --device $DEVICE >/dev/null 2>&1
  if ! xcrun devicectl device info details --device $DEVICE 2>&1 | grep -q "Device State: connected"; then
    say "needs renewal ($(( left / 3600 )) h left) but iPhone not reachable"
    (( left < 24 * 3600 )) && note "Expires in $(( left / 3600 )) h. Bring the iPhone home (Wi-Fi) or plug it in."
    exit 0
  fi
fi

say "renewing ($(( left / 3600 )) h left)"
# Xcode reuses a cached profile until it expires; removing our app's cached copy makes it
# issue a fresh 7-day one (tested 19.10). Apple can always re-issue it, nothing is lost.
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for f in "$PROFILES"/*.mobileprovision(N); do
  if security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null | grep -q "$BUNDLE_ID$"; then
    rm -f "$f"
  fi
done
if NO_LAUNCH=1 ./build_install.sh >> $LOG 2>&1; then
  say "renewed"
  note "Renewed for 7 more days."
else
  say "renew FAILED, see above"
  note "Automatic renewal failed. Run ios/build_install.sh with the iPhone plugged in."
fi
