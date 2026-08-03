PenBoard 1.1.1 is a stability and bug-fix release on top of 1.1.0 — no new features, a lot fewer ways for a session to wedge. Both halves must be updated together.

## Fixed

- **Laser mode can no longer leave your Mac's mouse button stuck.** If the pen-up event was lost over Bluetooth (or you switched modes mid-drag), the Mac was left drag-selecting under every mouse move until you clicked. The injected button is now always released when its pen-up can no longer arrive.
- **First-time pairing no longer times out while you answer the dialogs.** The tablet used to drop the link 10 seconds in — less time than it takes to confirm the macOS pairing dialog and the 6-digit code. Setup now gets a proper grace period.
- **Screen streaming reliably stops when you toggle it off.** Previously a quick toggle could leave macOS screen capture running (purple indicator on) with the menu showing OFF. Dead tablet connections are also cleaned up instead of leaking, and a streaming failure now turns the toggle off instead of capturing forever.
- **Declining the macOS pairing dialog no longer parks the app in "Pairing…" forever**, and a stalled connection attempt now times out and retries instead of requiring a relaunch.
- **Rotating the tablet no longer corrupts the ink.** Strokes drawn before a rotation used to redraw displaced (even over the letterbox bars); now both sides clear together, matching what the Mac does on a display change.
- **Palm-then-pen input fixes.** Resting a palm before or while using the S Pen could eat the stroke's end (leaking it on the Mac) or deaden the pen entirely; the stylus is now tracked by tool type rather than assuming it's the first touch point.
- Many smaller connection-recovery and thread-safety fixes on both platforms, plus corrected protocol documentation.

## ⚠️ Android update note — uninstall required

This release's APK is signed with a **different key** than 1.1.0. Android will refuse to install it over the existing app. Uninstall PenBoard on the tablet first, then install the new APK. (Your Mac-side pairing/trust is unaffected; you will need to re-pair once after reinstalling.)

## Download & install

You need **both** halves.

**Mac** — download `PenBoard.app.zip`, unzip, move `PenBoard.app` to Applications, then **right-click → Open** the first time (the app isn't notarized, so macOS warns once). If Gatekeeper still refuses:
```
xattr -dr com.apple.quarantine /Applications/PenBoard.app
```
macOS may re-prompt once for the Bluetooth/Accessibility/Screen Recording permissions after updating.

**Tablet** — uninstall the old PenBoard first (see above), then download `penboard.apk` on the tablet and open it. Or via adb:
```
adb uninstall it.aisma.penboard
adb install penboard.apk
```

Then open both apps and follow the on-screen pairing (a 6-digit code appears on each device — confirm it matches). Full walkthrough in the [README](https://github.com/hameddavodi/penboard#first-connect).

## Requirements

- **Mac:** macOS 13 (Ventura) or newer, Bluetooth. Screen streaming needs the **Screen Recording** permission (one-time prompt).
- **Tablet:** Android 10 or newer with an active stylus (built and tested on a Galaxy Tab S9 FE+ with S Pen)

## Security note

Screen streaming remains local-Wi-Fi-only, off by default, behind a random per-session URL token — but the stream is **not encrypted** and the token is discoverable by devices on the same network: don't enable it on a Wi-Fi network you don't trust (now documented in `docs/ARCHITECTURE.md`). Everything else (pairing, ink, cursor control) stays on the Bluetooth link.
