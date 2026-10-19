#!/bin/zsh
# Installs two login agents for the current user:
#   <prefix>.locationserver  runs server.py on port 8765 (--lan, so the iPhone app can reach it)
#   <prefix>.locationrenew   every 6 h re-signs/reinstalls the iOS app before the free 7-day signing runs out
# Prefix: LABEL_PREFIX from ios/local.env, else "local.iphone-location".
# Python: Homebrew's python3 (launchd's /bin/zsh can't read ~/Downloads, ~/Documents, ~/Desktop).
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
[[ -f ios/local.env ]] && { set -a; source ios/local.env; set +a; }
PREFIX="${LABEL_PREFIX:-local.iphone-location}"
PY="$(command -v /opt/homebrew/bin/python3 || command -v python3)"
AG=~/Library/LaunchAgents
mkdir -p $AG

cat > $AG/$PREFIX.locationserver.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PREFIX.locationserver</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$HERE/server.py</string><string>8765</string><string>--lan</string></array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string><key>PYTHONUNBUFFERED</key><string>1</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HERE/server.log</string><key>StandardErrorPath</key><string>$HERE/server.log</string>
</dict></plist>
PL

cat > $AG/$PREFIX.locationrenew.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PREFIX.locationrenew</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$HERE/ios/auto_renew.py</string></array>
  <key>RunAtLoad</key><true/><key>StartInterval</key><integer>21600</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/locationrenew.log</string><key>StandardErrorPath</key><string>$HOME/Library/Logs/locationrenew.log</string>
</dict></plist>
PL

for name in locationserver locationrenew; do
  launchctl bootout gui/$(id -u)/$PREFIX.$name 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) $AG/$PREFIX.$name.plist
done
echo "Installed $PREFIX.locationserver and $PREFIX.locationrenew"
