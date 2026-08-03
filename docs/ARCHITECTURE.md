# PenBoard — Architecture

An Android tablet with an active stylus becomes a pen board for a Mac, over
Bluetooth LE. Built and tested with a Galaxy Tab S9 FE+ (S Pen); any Android
device that reports `TOOL_TYPE_STYLUS` events should work.

## Components

```
android/   Kotlin app — stylus capture + BLE GATT peripheral
macos/     Swift menu-bar app — BLE central, overlay renderer, cursor injection
docs/      PROTOCOL.md (wire contract) · ADRs
```

### Android (peripheral)

- `ui/PadView` — full-screen pad. Accepts only stylus/eraser `MotionEvent`s
  (finger and palm are ignored — free palm rejection). Consumes historical
  samples so 120–240 Hz stylus rates survive Android's event batching. Points
  are normalized to 0–65535 over a 16:10 letterboxed rect. Local ink mirror so
  the user sees what they draw.
- `ble/PenGattServer` + `ble/PenAdvertiser` — GATT service (see PROTOCOL §1)
  with encrypted characteristics (forces bonding). The primary advertisement
  carries only the 128-bit service UUID — flags (3) + UUID (18) = 21 of the 31
  legacy-PDU bytes; the device name rides in the scan response, which has its
  own 31-byte budget. Anything more overflows and Samsung's stack rejects it
  with `ADVERTISE_FAILED_DATA_TOO_LARGE`.
- `ble/NotifyQueue` — one notification in flight at a time (paced by
  `onNotificationSent`), coalescing and a drop policy that never drops
  stroke-critical events (pen down/up). Batch size follows the negotiated MTU.
- `service/PenBoardService` — foreground service (`connectedDevice` type) that
  owns the BLE stack, survives activity death, re-advertises with backoff on
  disconnect, and caches handshake/state events so a backgrounded UI can catch
  up on reattach.

### macOS (central)

- `Stream/` (v1.1) — optional Mac→tablet screen streaming: `ScreenStreamer`
  captures the selected display via ScreenCaptureKit (~12 fps, JPEG),
  `MJPEGServer` serves it as MJPEG-over-HTTP on an ephemeral TCP port
  advertised via Bonjour (`_penboard-stream._tcp`) with a per-toggle random
  token in the TXT record; the tablet's `stream/` package (NsdManager
  discovery + raw-socket client + incremental MJPEG parser) renders it under
  the pad. Always off at launch, never persisted; requires the Screen
  Recording permission.


- `BLE/Central` — CoreBluetooth state machine: scan by service UUID → connect →
  handshake → subscribe → stream. Reconnects by CoreBluetooth peripheral
  identifier (never MAC address — Android rotates private addresses) with
  1→10 s backoff. Sequence-number gaps are logged and force-close the open
  stroke.
- `Overlay/` — Draw mode. A borderless, transparent, click-through `NSWindow`
  (`ignoresMouseEvents = true`, level `.statusBar`, joins all Spaces +
  full-screen apps) over the live screen. Strokes are smoothed with Catmull-Rom
  interpolation; pressure modulates width; the S Pen barrel button erases whole
  strokes. The mouse keeps working underneath at all times.
- `Laser/CursorInjector` — Laser mode. Pen hover moves the real cursor via
  `CGEvent` (posted to the HID event tap); pen touch = left click/drag. This is
  what makes Chrome/Meet's built-in laser pointer follow the pen during **tab**
  screen-share, where an overlay would be invisible to viewers. Requires the
  Accessibility permission (`Perm/AccessibilityGate`). Hover uses a light
  low-pass filter, not Catmull-Rom — the cursor must not lag.
- `Map/CoordinateMapper` — the single place that converts protocol coordinates
  (0–65535, top-left origin) into AppKit window points (bottom-left origin) and
  CGEvent global points (top-left origin). Three coordinate systems, one
  unit-tested funnel.

## Why BLE GATT (and not RFCOMM or Wi-Fi)

See `docs/adr/0001-transport-ble-gatt.md`. Short version: modern non-deprecated
APIs on both platforms, bonding gives link encryption for free, and measured
latency fits the budget. The packet codec is transport-agnostic, so a TCP
carrier could be added without touching the protocol.

## Security model

Letting a radio peer move your mouse is an attack surface, and the design
treats it as one:

1. GATT characteristics require encryption → the OS forces a bond.
2. A bond alone is not trust: an application-level handshake derives a 6-digit
   code shown on both screens; the user must confirm it on the Mac
   (PROTOCOL §6). Until then, neither stream nor control packets are accepted.
3. Every inbound packet is schema-validated; malformed packets are counted and
   a flood (>10/60 s) disconnects and disables auto-reconnect.
4. Clicks are rate-limited (≤20/s) and cursor positions clamped to the display.
5. The pen/control path is Bluetooth-only with no network listeners; packet
   contents are never logged.
6. Screen streaming (v1.1, opt-in per session) is the exception: it opens a
   TCP listener on all interfaces while enabled. Access control is a random
   128-bit token minted per toggle-ON — but note the token is published in
   the Bonjour TXT record, i.e. readable by every device on the LAN, and the
   stream is plain HTTP (no TLS) with no binding to the BLE-trusted peer.
   Against a hostile local network this protects nothing: treat the v1.1
   stream as trusted-LAN-only. (Deriving a shared secret over the
   BLE-encrypted CONTROL channel instead is the known fix; it requires a
   protocol version bump and is deliberately out of scope for v1.1.) Idle
   connections that never present the token are dropped after 5 s.

## Testing

- The packet codec is implemented twice (Kotlin + Swift) against shared golden
  byte vectors in PROTOCOL §9 — both suites must pass byte-exact, which pins
  the wire contract without any shared code.
- `CoordinateMapper` / `PadCoordinateMapper`, the notify-queue drop policy, and
  the stylus point extractor are unit-tested on their respective sides.
- The Mac app has a debug replay (menu bar → Debug) that feeds a recorded
  stroke through the full pipeline — rendering is verifiable without a tablet.

## Known constraints

- One display (the main one) in v1; the mapper is display-parameterized so
  multi-display is a contained extension.
- The pad maps 16:10 → the Mac's display; on non-16:10 displays ink stretches
  slightly.
- Samsung stops BLE advertising when the screen turns fully off — the app keeps
  the screen on and offers a dim toggle instead.
- Screen-share of a single Chrome **tab** captures only the tab plus cursor, so
  Draw-mode ink is invisible to viewers there; that is exactly why Laser mode
  drives the real cursor. Full-screen shares show the ink.
- macOS builds need only the Xcode Command Line Tools; run tests via
  `macos/scripts/test.sh` (on CLT-only machines, bare `swift test` finds no
  XCTest and silently runs zero tests — the script wires the in-toolchain
  Swift Testing framework instead).
