#!/bin/zsh
# Builds Glim and installs it on a connected iPhone.
#
#   scripts/install.sh            first iPhone that devicectl lists
#   scripts/install.sh <udid>     a specific device
#
# Needs an Apple account signed in to Xcode (Settings > Accounts). With a paid
# Apple Developer account the install stays valid for 1 year; with a free
# Personal Team it expires after 7 days (run this again to renew it).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f Config/Local.xcconfig ]]; then
  # Xcode caches the teams of its signed-in accounts once a project has been opened in it; the key that
  # holds them changed name between Xcode versions, so read the whole domain.
  team=$(defaults read com.apple.dt.Xcode 2>/dev/null \
    | sed -n 's/.*teamID = "\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p' | head -1 || true)
  if [[ -z "$team" ]]; then
    echo "No signing team found. Sign in to Xcode (Settings > Apple Accounts), open Glim.xcodeproj in it once,"
    echo "then run this again,"
    echo "or create Config/Local.xcconfig containing: DEVELOPMENT_TEAM = <your 10-character team id>"
    exit 1
  fi
  echo "DEVELOPMENT_TEAM = $team" > Config/Local.xcconfig
  echo "Using signing team $team (saved to Config/Local.xcconfig)"
fi

device=${1:-}
if [[ -z "$device" ]]; then
  listing=$(mktemp)
  xcrun devicectl list devices --json-output "$listing" >/dev/null
  device=$(python3 -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
phones = [d for d in devices
          if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"
          and d.get("hardwareProperties", {}).get("reality") != "simulated"]
# A phone this Mac knows but cannot reach right now is listed too; prefer one that is reachable.
phones.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") == "unavailable")
if phones:
    state = phones[0].get("connectionProperties", {}).get("tunnelState", "")
    print(phones[0]["hardwareProperties"]["udid"], state)' "$listing")
  rm -f "$listing"
  if [[ "$device" == *" unavailable" ]]; then
    echo "The iPhone is known to this Mac but not reachable. Connect it by cable, unlock it, and run this again."
    exit 1
  fi
  device=${device%% *}
fi
if [[ -z "$device" ]]; then
  echo "No iPhone found. Connect it by cable and unlock it; tap Trust if it asks."
  exit 1
fi

xcodegen generate --quiet
xcodebuild -project Glim.xcodeproj -scheme Glim -configuration Release \
  -destination "id=$device" -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
xcrun devicectl device install app --device "$device" build/Build/Products/Release-iphoneos/Glim.app
echo "Installed. On first launch, trust the developer under Settings > General > VPN & Device Management."
