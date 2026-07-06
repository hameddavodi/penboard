# ADR 0001 — Transport: BLE GATT

Date: 2026-07-06 · Status: Accepted

## Context
Tablet (Galaxy Tab S9 FE+, Android) must stream stylus events to macOS with
low latency, over Bluetooth. Candidates: BLE GATT, Bluetooth Classic RFCOMM,
Wi-Fi TCP.

## Decision
BLE GATT. Android app = GATT peripheral (`BluetoothLeAdvertiser` +
`BluetoothGattServer`), macOS app = central (CoreBluetooth `CBCentralManager`).
Encrypted characteristic permissions force bonding; app-level handshake with
6-digit confirm on top (cursor injection over radio = attack surface).

## Rationale
- Modern, non-deprecated APIs on both sides. macOS `IOBluetooth` (RFCOMM) is
  legacy — future-macOS risk.
- ~15–30 ms latency with batched notifications is inside the 40 ms budget for
  240 Hz stylus input (verified on real hardware before UI work).
- BLE bonding gives link encryption for free; RFCOMM security is DIY.
- Wi-Fi TCP is faster but not Bluetooth as required; kept as a contingency
  behind the same `Packets` codec in case peripheral-mode quirks ever make
  BLE unusable (see ARCHITECTURE.md, Known constraints).

## Consequences
- Throughput bounded by MTU + connection interval → dynamic batch sizing
  (PROTOCOL §2), 1-in-flight notify pacing.
- Samsung screen-off advertising throttle → foreground service +
  keep-screen-on-dimmed policy.
- Codec is transport-agnostic by design; transport swap = new carrier, same
  bytes.
