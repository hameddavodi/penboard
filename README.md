# PenBoard

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Android](https://img.shields.io/badge/Android-10%2B-3DDC84?logo=android&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-13%2B-000?logo=apple)

Turn an Android tablet with a stylus into a pen board for your Mac — over
Bluetooth, no cables, no Wi-Fi needed.

<!-- TODO: demo GIF here -->

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
by macOS for any app that moves the mouse. PenBoard has no internet access, no
analytics, and collects nothing — see the [security model](docs/ARCHITECTURE.md#security-model).
The optional screen stream (below) is the one network feature: it serves video
only on your local network, only while its toggle is on, behind a random
128-bit URL token that rotates every time you enable it. The stream is not
encrypted — don't enable it on a Wi-Fi network you don't trust.

## Using it

| Action | Tablet | Mac |
|---|---|---|
| Toggle Draw/Laser | toolbar | menu bar or ⌥⌘D |
| Clear ink | toolbar | menu bar or ⌥⌘C |
| Color / width | toolbar (6 colors, 4 widths) | synced from tablet |
| Undo | toolbar | synced |
| Erase one stroke | hold the pen button, touch the stroke | — |
| Dim tablet screen, keep link alive | toolbar dim toggle | — |
| Choose which display to draw on | — | menu bar → Display |
| See the Mac screen on the tablet | toolbar stream toggle | menu bar → Stream Screen to Tablet |

Screen streaming needs both devices on the same Wi-Fi and a one-time
**Screen Recording** permission on the Mac (System Settings → Privacy &
Security → Screen Recording, then relaunch PenBoard). The tablet finds the Mac
automatically — no IP addresses. Switching the target display clears current
ink on both devices, same as switching modes.

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

If PenBoard is useful to you, you can
[buy me a coffee](https://buymeacoffee.com/your-username) ☕ <!-- TODO: real link -->

## License

[MIT](LICENSE) © 2026 Hamed Davoodi
