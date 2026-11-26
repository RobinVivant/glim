# Changelog

All notable changes to Glim are documented in this file.

## [1.0.0] - 2026-11-26

### Added

- Local-only Philips Hue CLIP v2 client (`HueKit`) with bridge discovery (mDNS + Philips discovery endpoint), certificate pinning, SSE live event stream, optimistic coalesced command queue, and `huectl` CLI tool.
- Dark-first iOS SwiftUI app with full-width brightness slider rows, expandable rooms and zones, scene dot pickers, individual light color/temperature controls, and one-tap All Off / Nightlight bar.
- Home Screen room widgets (Small, Medium, Large with brightness steps, scenes, and light switches), Control Center / Lock Screen controls, and Siri / App Intents (`AllLightsOffIntent`, `ToggleRoomIntent`, `ActivateSceneIntent`).
- Open-source repository scaffolding: MIT `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `Config/Local.xcconfig.example`, GitHub Actions CI (`HueKit` unit + mock-bridge HTTPS tests), custom Liquid Glass icon, social banner, and simulator screenshots.
