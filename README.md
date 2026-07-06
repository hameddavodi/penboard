# PenBoard

[![Latest release](https://img.shields.io/github/v/release/hameddavodi/penboard?label=download&sort=semver)](../../releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Android](https://img.shields.io/badge/Android-10%2B-3DDC84?logo=android&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-13%2B-000?logo=apple)

Turn an Android tablet with a stylus into a pen board for your Mac — over
Bluetooth, no cables, no Wi-Fi needed. Pressure-sensitive on-screen annotation
and a pen-driven laser pointer for presentations, teaching, and screen sharing.

**➡️ [Download the latest release](../../releases/latest)** (Mac app + tablet APK)

<!-- demo GIF -->

Two modes, toggled from the tablet toolbar, the Mac menu bar, or ⌥⌘D:

- **✏️ Draw** — pressure-sensitive ink on a transparent, click-through overlay
  above whatever is on your Mac screen (any app, browser, PDF). Your mouse
  keeps working underneath. Great for teaching, code review, and design
  walkthroughs.
- **🔴 Laser** — pen hover moves the real macOS cursor; pen touch clicks and
  drags. Built for presenting: when you share a Chrome **tab** in Google Meet,
  Meet's laser pointer follows your pen.

Built and tested with a Galaxy Tab S9 FE+ (S Pen); any Android 10+ device with
an active stylus should work. Palm rejection is automatic — only stylus input
is captured.

## Install

Grab both halves from [Releases](../../releases):

**Mac** — download `PenBoard.app.zip`, unzip, move to Applications, then
right-click → Open the first time (the app is not notarized; macOS warns once).
If Gatekeeper still refuses: `xattr -dr com.apple.quarantine /Applications/PenBoard.app`.

**Tablet** — download `penboard.apk` on the tablet and open it. Android asks
once to allow installs from your browser ("install unknown apps") and may show
a Play Protect prompt — this is normal for any app installed outside the Play
Store. Or install via adb: `adb install -r penboard.apk`.

## First connect

1. Tablet: open PenBoard, grant the Bluetooth (and notification) permissions →
   status shows **Advertising**. While advertising, the app temporarily sets
   the tablet's Bluetooth name to "PenBoard" (Android has no
   per-advertisement name API); the original name is restored when it stops.
2. Mac: launch PenBoard (menu-bar icon), allow Bluetooth → it finds the tablet
   and macOS shows a **pairing dialog once** — accept.
3. Both screens show a **6-digit code**. If they match, confirm on the Mac.
   Trust is stored; future reconnects are automatic and silent.

**For Laser mode (one-time):** the first activation asks for the
**Accessibility** permission — that's what allows moving the cursor. Grant it
in System Settings → Privacy & Security → Accessibility.

Why these permissions: Bluetooth is the transport; Accessibility is required
by macOS for any app that moves the mouse. PenBoard has no network access, no
analytics, and collects nothing — see the [security model](docs/ARCHITECTURE.md#security-model).

## Using it

| Action | Tablet | Mac |
|---|---|---|
| Toggle Draw/Laser | toolbar | menu bar or ⌥⌘D |
| Clear ink | toolbar | menu bar or ⌥⌘C |
| Color / width | toolbar (6 colors, 4 widths) | synced from tablet |
| Undo | toolbar | synced |
| Erase one stroke | hold the pen button, touch the stroke | — |
| Dim tablet screen, keep link alive | toolbar dim toggle | — |

Presenting in Meet:
- Sharing a **Chrome tab** → viewers see the cursor only → use **Laser**.
- Sharing the **entire screen** → viewers see your ink → **Draw** works too.
- Switching Draw→Laser clears current ink on both devices.

## Build from source

**Android** (JDK 17+, Android SDK):

```bash
cd android
./gradlew :app:assembleRelease    # unsigned-fallback build works out of the box
```

To sign releases, copy `keystore.properties.template` to `keystore.properties`
and point it at your keystore.

**macOS** (Xcode Command Line Tools are enough):

```bash
cd macos
./scripts/build-app.sh            # → build/PenBoard.app
```

Optional: `./scripts/make-signing-cert.sh` once creates a local signing cert so
the Accessibility grant survives rebuilds. Tests: `./scripts/test.sh`.

## How it works

Android app = BLE GATT peripheral streaming normalized stylus points
(x, y, pressure, flags) as batched notifications; Mac app = CoreBluetooth
central rendering them (Draw) or injecting cursor events (Laser). Encrypted
bonded link + user-confirmed pairing code; every packet schema-validated.

Details: [Architecture](docs/ARCHITECTURE.md) ·
[Wire protocol](docs/PROTOCOL.md) ·
[Why BLE GATT](docs/adr/0001-transport-ble-gatt.md)

## Troubleshooting

- **No pairing dialog on Mac** — run the built `.app`; Bluetooth prompts never
  fire under `swift run`.
- **Re-pair from scratch** — forget "PenBoard" in both devices' Bluetooth
  settings, relaunch both apps.
- **Laser stopped working after rebuilding from source** —
  `tccutil reset Accessibility <bundle id>` and re-grant (or use the signing
  cert above).
- **Check rendering without a tablet** — Mac menu bar → Debug → Replay.
- **Check link latency** — Mac menu bar → Debug → latency HUD.

## Support

PenBoard is free and open source. If it's useful to you, starring the repo ⭐
helps others find it.

<!-- To add a Buy Me a Coffee button: put your handle below and also set
     `buy_me_a_coffee:` in .github/FUNDING.yml.
[☕ Buy me a coffee](https://buymeacoffee.com/YOUR_HANDLE)
-->

## License

[MIT](LICENSE) © 2026 Hamed Davoodi
