# Security Policy

## Architecture Overview

Glim communicates exclusively on your local network using Philips Hue's CLIP v2 API with zero third-party SDKs, analytics, or Hue cloud dependencies:

- **TLS Certificate Pinning:** During pairing, Glim records the SHA-256 fingerprint of the Hue bridge's local HTTPS certificate, verifies that the leaf certificate subject names the bridge's own ID, and pins all subsequent CLIP v2 requests and Server-Sent Event streams strictly to that certificate.
- **Credential & State Storage:** Bridge credentials and the cached home snapshot are stored inside the shared App Group container (`group.com.robinvivant.glim`) so the app and `GlimWidgets` extension can share access locally without cloud sync.
- **Local Network Scope:** Glim requests `NSLocalNetworkUsageDescription` and `_hue._tcp` Bonjour discovery solely to locate and communicate with your Hue bridge on your LAN.

## Supported Versions

Security fixes are applied on `main`:

| Version | Supported |
|---|---|
| `1.0.x` | Yes |

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities or certificate-pinning bypasses.

Instead, report vulnerabilities privately via **GitHub Security Advisories** (`Security` -> `Advisories` -> `Report a vulnerability` on this repository), including reproduction steps and affected components without sharing personal bridge keys.
