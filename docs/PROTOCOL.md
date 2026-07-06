# PenBoard BLE Protocol — v1

Status: LOCKED for v1. Any change bumps the version byte and this doc.
Transport: BLE GATT. Android = peripheral/GATT server. macOS = central/GATT client.
All multi-byte integers are **little-endian**. All packets are schema-validated on
receipt; malformed input is dropped and counted (see §8).

---

## 1. GATT layout

Fixed random UUIDs (generated 2026-07-06, do not regenerate):

| Item | UUID | Properties | Permissions (Android side) |
|---|---|---|---|
| **PenBoard Service** | `C5F1A9E2-7B34-4E86-9D12-8A50C3B7F6D4` | primary | — |
| **STREAM** characteristic | `C5F1A9E3-7B34-4E86-9D12-8A50C3B7F6D4` | notify | `PERMISSION_READ_ENCRYPTED` on CCCD |
| **CONTROL** characteristic | `C5F1A9E4-7B34-4E86-9D12-8A50C3B7F6D4` | write (with response) + notify | `PERMISSION_WRITE_ENCRYPTED`, CCCD encrypted |
| **INFO** characteristic | `C5F1A9E5-7B34-4E86-9D12-8A50C3B7F6D4` | read | `PERMISSION_READ_ENCRYPTED` |

Direction of traffic:

- **STREAM** — tablet → Mac only. Point-batch packets (§4). High rate.
- **CONTROL** — bidirectional. Mac writes control packets; tablet sends control
  packets as notifications. Low rate.
- **CCCD** = standard Client Characteristic Configuration Descriptor
  (`00002902-0000-1000-8000-00805F9B34FB`) on STREAM and CONTROL.

Encrypted permissions on every characteristic force SMP pairing/bonding on first
access — this is what triggers the OS-level bond (macOS pairing dialog + Android
confirm). Unbonded reads/writes are rejected by the stack, not by app code.

Advertising: connectable, service UUID `C5F1A9E2-…` in the primary advertisement,
`ADVERTISE_MODE_LOW_LATENCY`, TX power included. Local name `PenBoard`.

## 2. MTU and batching assumptions

- Central (macOS) negotiates ATT MTU automatically; CoreBluetooth exposes no
  explicit request API. Apple hardware typically negotiates ≥185, often up to 527.
- Peripheral learns the value via `BluetoothGattServerCallback.onMtuChanged`.
- **Max packet size = negotiated ATT_MTU − 3** (notification payload limit).
- **Conservative floor: assume 185 → 182-byte payload** until `onMtuChanged` fires.
- One packet per notification. Never fragment a packet across notifications;
  never concatenate two packets in one notification.
- Max points per POINT_BATCH = `floor((maxPayload − 5) / 7)` → 25 at MTU 185,
  capped at **40** absolute (receiver rejects `count > 40`).
- Pacing: Android sends at most **one in-flight notification**; the next notify
  waits for `onNotificationSent`. Points produced meanwhile are coalesced into the
  next batch. Under backpressure, drop oldest `PEN_MOVE`/`HOVER_MOVE` points first;
  **never drop `PEN_DOWN`, `PEN_UP`, `HOVER_ENTER`, `HOVER_EXIT`**.
- Tablet requests 2M PHY where supported; not required for correctness.

## 3. Common packet header

Every packet on STREAM or CONTROL starts:

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | u8 | `version` | `0x01` |
| 1 | u8 | `type` | `0x01` POINT_BATCH · `0x02` CONTROL |

Receiver rules: unknown `version` → send `ERROR(1)` then disconnect. Unknown
`type` → drop packet, count as malformed.

## 4. POINT_BATCH packet (type 0x01, STREAM only)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | u8 | version | `0x01` |
| 1 | u8 | type | `0x01` |
| 2 | u16 | seq | per-connection, starts 0, wraps at 65535 |
| 4 | u8 | count | 1–40; must match remaining length exactly |
| 5 | 7×count | points | packed, no padding |

Per point (7 bytes):

| Offset | Size | Field | Notes |
|---|---|---|---|
| +0 | u16 | x | normalized 0–65535, left → right |
| +1 | u16 | y | normalized 0–65535, top → bottom |
| +4 | u16 | pressure | 0–65535; 0 while hovering |
| +6 | u8 | flags | see below |

`flags` bit layout:

| Bits | Meaning |
|---|---|
| 0–2 | event: `1` PEN_DOWN · `2` PEN_MOVE · `3` PEN_UP · `4` HOVER_MOVE · `5` HOVER_ENTER · `6` HOVER_EXIT · `0`,`7` invalid (reject point) |
| 3 | barrel button held (`1` = pressed). Eraser semantics are decided by the Mac renderer, not encoded here. |
| 4–7 | reserved; sender writes 0; receiver ignores but logs non-zero |

Validation: `len == 5 + 7*count`, `1 ≤ count ≤ 40`, every point's event field in
1–6. Any failure → whole packet dropped, malformed counter++.

`seq` gaps are logged (stack dropped a notification) but do not error; strokes
self-heal on the next PEN_DOWN. A PEN_UP that never arrives is force-closed by
the Mac after **500 ms** without points for the active stroke.

Semantics by mode (Mac side): in **Draw**, contact events build strokes and hover
is ignored; in **Laser**, HOVER_MOVE moves the cursor, PEN_DOWN/UP = mouse
down/up (PEN_MOVE while down = drag). Same packet format in both modes.

## 5. CONTROL packet (type 0x02, CONTROL characteristic)

| Offset | Size | Field |
|---|---|---|
| 0 | u8 | version = `0x01` |
| 1 | u8 | type = `0x02` |
| 2 | u8 | opcode |
| 3 | u8 | length = payload byte count |
| 4… | bytes | payload |

Validation: `len == 4 + length`, opcode known, payload length matches the table.
Mismatch → drop + malformed counter++.

| Opcode | Name | Payload | Direction | Meaning |
|---|---|---|---|---|
| `0x01` | SET_MODE | u8: `0` draw, `1` laser | both | Either side may switch; receiver applies and echoes nothing (last-writer-wins) |
| `0x02` | SET_COLOR | u8 palette index 0–5 | both | Palette fixed in v1 (see §7) |
| `0x03` | SET_WIDTH | u8 base width, 1–64 pt (clamp) | both | Base width; pressure scales 0.25×–1.75× |
| `0x04` | UNDO | — (length 0) | tablet → Mac | Remove last completed stroke |
| `0x05` | CLEAR | — | both | Remove all strokes |
| `0x06` | PING | u32 sender ms-timestamp (low 32 bits) | Mac → tablet | Sent every 2 s |
| `0x07` | PONG | u32 echoed timestamp | tablet → Mac | Immediate echo |
| `0x08` | HELLO | u8 proto version + u32 random token | Mac → tablet | Handshake, §6 |
| `0x09` | HELLO_OK | u8 proto version | tablet → Mac | Token code is on tablet screen |
| `0x0A` | ERROR | u8 code | both | `1` version mismatch · `2` malformed flood · `3` internal |
| `0x0B` | STATE_SYNC | u8 mode + u8 color + u8 width | Mac → tablet | Full state push after (re)connect |

## 6. Handshake / auth sequence

Two layers: **link layer** (BLE bond, encrypted) and **app layer** (first-connect
human confirmation on the Mac — cursor injection over radio is the attack
surface, so a bonded radio alone is not sufficient trust).

1. Tablet advertises service `C5F1A9E2-…` (foreground service running).
2. Mac scans for that service UUID only. First time: user clicks *Connect* in the
   menu bar. Later: auto-connect to the stored peripheral identifier.
3. Mac connects, discovers services/characteristics, reads **INFO**.
   Encrypted permission triggers SMP pairing → OS bond (macOS dialog + tablet
   confirm). INFO payload: `u8 protoVersion | u8 capsBitmask | utf8 deviceName`
   (caps bits reserved, 0 in v1).
4. Version check: major mismatch → Mac shows error, disconnects. (v1: byte equality.)
5. Mac subscribes to CONTROL notifications, then writes
   **HELLO** `{proto=0x01, token=random u32}` (fresh token per handshake, from a CSPRNG).
6. Tablet displays `token % 1_000_000` as a zero-padded 6-digit code and replies
   **HELLO_OK**. Mac shows a confirmation dialog with the same code:
   *"Pair with 'PenBoard' — code 928559?"*
   - First connect: user must confirm on the Mac. On confirm, Mac persists the
     peripheral identifier as trusted (UserDefaults; token is never persisted).
   - Reconnect of a trusted+bonded peripheral: dialog skipped, handshake still runs.
7. Mac subscribes to STREAM, then writes **STATE_SYNC** (authoritative state lives
   on the Mac; tablet toolbar adopts it).
8. Streaming enabled. Tablet MUST NOT notify on STREAM before HELLO_OK is sent;
   Mac MUST ignore any STREAM packet that arrives before the user trust gate passed.
9. Keepalive: Mac PINGs every 2 s. **3 consecutive missed PONGs → disconnect** and
   enter the reconnect loop. Tablet drops the "connected" UI state if no PING for 10 s.

## 7. v1 palette (SET_COLOR indices)

| Index | Color | sRGB hex |
|---|---|---|
| 0 | Red | `#E5484D` |
| 1 | Blue | `#3B82F6` |
| 2 | Green | `#30A46C` |
| 3 | Yellow | `#F5D90A` |
| 4 | Black | `#111111` |
| 5 | White | `#FFFFFF` |

## 8. Error handling rules

- Malformed packet (any validation failure in §3–§5): drop, log, counter++.
- **> 10 malformed packets within 60 s** → send `ERROR(2)`, disconnect. Mac side
  additionally requires manual reconnect (button) after a malformed-flood, so a
  hostile peer cannot ride the auto-reconnect loop.
- Version mismatch: `ERROR(1)` + disconnect, no retry until app update.
- Writes to CONTROL from an unbonded/unencrypted link never reach app code
  (stack rejects); if one is observed anyway, treat as malformed.
- All bounds-checked parsing; no packet field is ever used as an allocation size
  beyond the 512-byte hard cap on any inbound buffer.
- Laser-mode safety clamp (Mac): injected cursor positions are clamped to the
  target display bounds; click events are rate-limited to 20/s.

## 9. Golden test vectors (both codecs must pass byte-exact)

POINT_BATCH — seq 5, 2 points: (1000, 2000, p 30000, PEN_DOWN), (1010, 2020, p 32000, PEN_MOVE):

```
01 01 05 00 02 E8 03 D0 07 30 75 01 F2 03 E4 07 00 7D 02
```

CONTROL SET_COLOR index 2:

```
01 02 02 01 02
```

CONTROL PING ts=123456:

```
01 02 06 04 40 E2 01 00
```

CONTROL HELLO proto 1, token 0xDEADBEEF (6-digit code: 928559):

```
01 02 08 05 01 EF BE AD DE
```

Negative vectors (must be rejected): truncated batch `01 01 00 00 02 E8 03`,
zero-count batch `01 01 00 00 00`, event=0 flags, version `02` anything,
`count=41` batch, CONTROL with `length` ≠ actual payload.
