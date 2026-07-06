# Contributing to PenBoard

Issues and PRs welcome. A few ground rules keep the project easy to maintain.

## Build & test

**Android** (JDK 17+, Android SDK):

```bash
cd android
./gradlew :app:assembleDebug :app:testDebugUnitTest lint ktfmtCheck
```

All four must pass — lint runs with warnings-as-errors and ktfmt is the
formatting source of truth (`./gradlew ktfmtFormat` fixes style). `assembleRelease`
works without a keystore (it falls back to debug signing with a warning).

**macOS** (Xcode Command Line Tools are enough; full Xcode also works):

```bash
cd macos
swift build              # zero warnings expected
./scripts/test.sh        # NOT `swift test` — see docs/ARCHITECTURE.md
./scripts/build-app.sh   # assembles build/PenBoard.app
```

Bluetooth only works from the assembled `.app`, never `swift run`.

## Rules of the road

- **The wire contract is frozen.** `docs/PROTOCOL.md` §9 golden vectors are the
  law; any protocol change bumps the version byte and updates the vectors, and
  both codecs (`Packets.kt`, `Packets.swift`) must pass them byte-exact.
- **Zero third-party runtime dependencies** on both sides (AndroidX
  core/appcompat and system frameworks only). This is deliberate — smallest
  possible supply chain for an app that can move your mouse.
- Simplest robust implementation wins. No speculative abstraction.
- Validate every inbound byte; never log packet contents.
- Changes that touch pen input, BLE, or rendering should say in the PR what was
  tested on real hardware (tablet model, macOS version) — unit tests can't
  cover radio behavior.

## Reporting bugs

Include: tablet model + Android version, macOS version, what the tablet status
text and the Mac menu-bar status showed, and if possible a excerpt from
`log stream --predicate 'subsystem == "it.aisma.penboard"'` (Mac) or
`adb logcat -s PenBoard` (tablet).
