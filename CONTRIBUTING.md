# Contributing to Glim

Contributions are welcome for bug fixes, HueKit CLIP v2 improvements, widget enhancements, accessibility improvements, and tests.

## Local Development Setup

### Prerequisites

- macOS 26+ with Xcode 27.2+ (Swift 6.0+ and iOS 26/27 SDKs)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate `Glim.xcodeproj` from `project.yml`
- An Apple Developer Team ID if building for a physical iPhone (simulator and `HueKit` package tests run without signing)

### Configure Local Signing (Optional for Device Builds)

To run on a physical iPhone without modifying tracked files:

1. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored):

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

2. Set `DEVELOPMENT_TEAM = YOUR_TEAM_ID` inside `Config/Local.xcconfig`.
3. Run `xcodegen generate` after changing `project.yml`.

### Running Tests & Builds

```bash
# HueKit unit tests
cd Packages/HueKit && swift test

# HueKit end-to-end HTTPS tests against the mock bridge
scripts/mock-bridge.py 8443 &
MOCK_PID=$!
cd Packages/HueKit && HUE_MOCK_HOST=127.0.0.1:8443 swift test
kill "$MOCK_PID"

# Unsigned iOS Simulator build
xcodegen generate
xcodebuild -project Glim.xcodeproj \
  -scheme Glim \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
  CODE_SIGNING_ALLOWED=NO build
```

## Pull Request Guidelines

- Keep `Swift 6` concurrency checks warning-free.
- Never commit personal Hue bridge application keys, local network IP addresses, Apple Developer Team IDs, device UDIDs, provisioning profiles, or signing certificates.
- Never target a real bridge in automated tests; use `scripts/mock-bridge.py`.
- Run `swift test` in `Packages/HueKit` (with and without `HUE_MOCK_HOST=127.0.0.1:8443`) and verify `Glim` builds before opening a PR.
