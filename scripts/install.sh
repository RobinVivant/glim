#!/bin/zsh
# Builds Glim and installs it on a connected iPhone.
#
#   scripts/install.sh            first iPhone that devicectl lists
#   scripts/install.sh <udid>     a specific device
#
# Needs an Apple account signed in to Xcode (Settings > Accounts). With a free
# account the install expires after 7 days; run this again to renew it.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f Config/Local.xcconfig ]]; then
  team=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null \
    | sed -n 's/.*teamID = "\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p' | head -1)
  if [[ -z "$team" ]]; then
    echo "No signing team found. Sign in to Xcode (Settings > Accounts), then run this again,"
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
phones = [d for d in devices if d.get("hardwareProperties", {}).get("deviceType") == "iPhone"]
print(phones[0]["hardwareProperties"]["udid"] if phones else "")' "$listing")
  rm -f "$listing"
fi
if [[ -z "$device" ]]; then
  echo "No iPhone found. Connect it by cable or put it on this Wi-Fi, unlocked."
  exit 1
fi

xcodegen generate --quiet
xcodebuild -project Glim.xcodeproj -scheme Glim -configuration Release \
  -destination "id=$device" -derivedDataPath build -allowProvisioningUpdates -quiet build
xcrun devicectl device install app --device "$device" build/Build/Products/Release-iphoneos/Glim.app
echo "Installed. On first launch, trust the developer under Settings > General > VPN & Device Management."
