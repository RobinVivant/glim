# Glim

Glim is a personal iPhone app that controls Philips Hue lights by talking straight to the Hue bridge on the home
network, with no cloud account and no loading screens.

The main screen has one row per room or zone. The row is its brightness slider: drag sideways to dim, tap the
power button to switch, tap the row to show its scenes and lights. A bar at the bottom turns everything off or sets
every room to its Nightlight scene. It opens from cached state, applies every touch at once, and follows the bridge's
event stream for changes made elsewhere.
The app and its widget are always dark, whatever the system appearance. The app uses Vero's teal and, on iOS 26
and later, Liquid Glass controls (a thin material on older versions).

## Quickstart

Run the app in the iOS Simulator against a pretend bridge, without touching real lights:

```bash
brew install xcodegen
scripts/mock-bridge.py 8443 &
xcodegen generate
xcodebuild -project Glim.xcodeproj -scheme Glim \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
xcrun simctl boot 'iPhone 17'
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Glim.app
SIMCTL_CHILD_GLIM_RESET=1 SIMCTL_CHILD_GLIM_BRIDGE_HOST=127.0.0.1:8443 \
  xcrun simctl launch booted com.robinvivant.glim
```

The app pairs with the mock by itself and shows four rooms and a zone.

## What it does

- Finds the bridge through mDNS and Philips' discovery endpoint, or takes its IP address, and pairs with the
  link button.
- Turns rooms, zones and single lights on and off, dims them, and sets white temperature and color.
- Recalls Hue scenes, and turns everything off with one button.
- Offers a Home Screen widget for a room in small, medium and large sizes: power, brightness steps (5, 25, 50, 75
  and 100%) and scenes. Edit Widget picks the room and which scenes it shows.
- Offers Control Center, Lock Screen and Action button controls: a room toggle, a scene, and all lights off.
- Exposes Shortcuts and Siri actions: toggle a room, set its power or brightness, activate a scene, all lights off.

## Install on an iPhone

1. Sign in to Xcode with your Apple account (Settings > Accounts).
2. On the phone, turn on Developer Mode (Settings > Privacy & Security).
3. Connect the phone and run:

    ```bash
    scripts/install.sh
    ```

4. On first launch, trust the developer under Settings > General > VPN & Device Management, then allow local
   network access when the app asks.
5. Press the link button on the bridge when the app asks for it.

With a free Apple account the install expires after 7 days. Running `scripts/install.sh` again renews it; the
pairing and widgets stay.

The signing team is read from Xcode and saved to `Config/Local.xcconfig`, which is not committed. The bundle
identifiers (`com.robinvivant.glim`) and the App Group are set in `project.yml` and `Shared/Glim.swift`.

## Layout

| Path | Contents |
|------|----------|
| `Packages/HueKit` | Hue client library: bridge API, pairing, discovery, event stream, home state, storage |
| `App` | The SwiftUI app |
| `Shared` | App Intents and constants compiled into both the app and the widget extension |
| `Widgets` | Home Screen widget and controls |
| `UITests` | UI tests that drive the app and its Home Screen widget against the mock bridge |
| `scripts` | Mock bridge, install script, icon generator |

`Glim.xcodeproj` is generated from `project.yml` by XcodeGen and is not committed.

## How it talks to the bridge

Glim uses the bridge's local HTTPS API (CLIP v2). The bridge's certificate comes from a private Signify CA, so
the app records the certificate it sees while pairing, checks that it names the bridge's own id, and afterwards
accepts only that certificate. The application key and the last known home state live in the App Group
container, where the widget extension reads them.

Writes are coalesced per light or room: one request in flight, and the newest value replaces queued ones, so
dragging a brightness bar sends a few requests and ends on the value under the finger.

Glim works on the home network only. It does not use the Hue cloud, so it cannot reach the lights from elsewhere.

## Tests

```bash
# Unit tests
cd Packages/HueKit && swift test

# The same plus end-to-end tests over HTTPS against the mock bridge
scripts/mock-bridge.py 8443 &
cd Packages/HueKit && HUE_MOCK_HOST=127.0.0.1:8443 swift test

# UI tests in the simulator (need a freshly started mock bridge; they assume its initial state)
xcodebuild -project Glim.xcodeproj -scheme Glim \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build test
```

`huectl` exercises the library against a real bridge from the Mac. It reads the application key from
`~/.secrets/hue-glim-dev.json`, the bridge's raw pairing answer:

```bash
cd Packages/HueKit
swift run huectl discover      # bridges on this network
swift run huectl rooms         # rooms, lights and scenes with their state
swift run huectl watch 30      # live events for 30 seconds
```
