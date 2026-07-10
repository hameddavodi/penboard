import CoreBluetooth
import Foundation
import os

/// Menu-bar-facing connection bucket. `StatusMenu` shows exactly these three states
/// plus the last RTT.
@MainActor
protocol CentralStatusDelegate: AnyObject {
    func central(_ central: Central, didChangeState state: Central.ConnectionState)
    func central(_ central: Central, didUpdateRTTMillis ms: Double)
}

/// M2.2/M3.2 wiring: inbound STREAM point batches and tablet-originated CONTROL
/// opcodes, forwarded to whatever owns the draw/laser mode state machine
/// (`PenBoardApp`). Kept separate from `CentralStatusDelegate` because this is a
/// different concern (packets, not connection state) with a different owner.
@MainActor
protocol CentralPacketDelegate: AnyObject {
    func central(_ central: Central, didReceivePointBatch batch: PointBatch)
    func central(_ central: Central, didReceiveTabletControl packet: ControlPacket)
    /// §4: a STREAM seq gap means a dropped notification, possibly containing
    /// the open stroke's PEN_UP — the conformer should force-close whatever
    /// stroke is currently open so the gap doesn't silently merge two strokes.
    func centralDidDetectStreamSequenceGap(_ central: Central)
}

/// BLE central state machine per docs/PROTOCOL.md: poweredOn → scan by service UUID →
/// connect on first hit → discover services/characteristics → read INFO → subscribe
/// CONTROL → HELLO → trust dialog → subscribe STREAM → STATE_SYNC → connected, with a
/// 1→10 s backoff reconnect loop. Reconnects always by `CBPeripheral.identifier`
/// (risk R1 — never by MAC).
/// All mutable state is confined to the serial `queue` (CoreBluetooth callbacks are
/// delivered on that same queue, and public entry points hop onto it before touching
/// anything) — `@unchecked Sendable` documents that self-managed synchronization.
final class Central: NSObject, @unchecked Sendable {

    enum ConnectionState: Equatable {
        case disconnected
        case pairing
        case connected
    }

    // MARK: GATT layout (docs/PROTOCOL.md §1 — fixed, do not regenerate)

    // Computed (not stored) so these aren't flagged as shared mutable global state for
    // the non-Sendable CBUUID class under Swift 6 strict concurrency.
    private static var serviceUUID: CBUUID { CBUUID(string: "C5F1A9E2-7B34-4E86-9D12-8A50C3B7F6D4") }
    private static var streamCharUUID: CBUUID { CBUUID(string: "C5F1A9E3-7B34-4E86-9D12-8A50C3B7F6D4") }
    private static var controlCharUUID: CBUUID { CBUUID(string: "C5F1A9E4-7B34-4E86-9D12-8A50C3B7F6D4") }
    private static var infoCharUUID: CBUUID { CBUUID(string: "C5F1A9E5-7B34-4E86-9D12-8A50C3B7F6D4") }

    // MARK: Internal phase (finer-grained than the public ConnectionState bucket)

    private enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        case discoveringServices
        case discoveringCharacteristics
        case readingInfo
        case subscribingControl
        case handshaking
        case awaitingTrust
        case subscribingStream
        case syncingState
        case connected
        /// §8 flood gate / §6 declined-trust / version-mismatch terminal states:
        /// only `userInitiatedConnect()` (menu click) may leave this state.
        case waitingManualReconnect
        case backingOff(attempt: Int)
    }

    weak var delegate: CentralStatusDelegate?
    weak var packetDelegate: CentralPacketDelegate?

    private let log = Logger(subsystem: "it.aisma.penboard", category: "ble.central")
    private let queue = DispatchQueue(label: "it.aisma.penboard.ble")
    private var manager: CBCentralManager!

    private var peripheral: CBPeripheral?
    private var infoCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var streamCharacteristic: CBCharacteristic?
    private var deviceName: String = "PenBoard"

    private var phase: Phase = .idle {
        didSet { if oldValue != phase { publishState() } }
    }

    private var handshakeToken: UInt32?
    private var handshakeTimeoutTimer: DispatchSourceTimer?
    private let floodGate = MalformedFloodGate()
    private var malformedTotal = 0

    private var pingTimer: DispatchSourceTimer?
    private var lastPingTimestamp: UInt32?
    private var lastPingSentAt: Date?
    private var missedPongCount = 0

    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectTimeoutTimer: DispatchSourceTimer?

    private var activityToken: NSObjectProtocol?

    /// §4: last STREAM seq observed on the current connection, for gap detection.
    private var lastStreamSeq: UInt16?

    // MARK: Local state mirror (M4.2 — STATE_SYNC re-push on every reconnect)

    /// Mirrors `PenBoardApp`'s live mode/color/width, updated via
    /// `updateLocalState(mode:color:width:)`. Confined to `queue` like all other
    /// mutable state here so `sendStateSync()` can read it synchronously without
    /// crossing actors.
    private var localMode: UInt8 = 0
    private var localColor: UInt8 = 4
    private var localWidth: UInt8 = 4

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Public entry points (safe to call from the main thread)

    /// Called once at app launch. The state machine actually starts from
    /// `centralManagerDidUpdateState` once CoreBluetooth reports `.poweredOn`.
    func start() {
        log.info("Central starting")
    }

    /// Menu bar "Connect" action: first-time pairing, or clearing the manual-reconnect
    /// gate after a malformed-packet flood / declined trust / version mismatch.
    func userInitiatedConnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.floodGate.reset()
            self.reconnectAttempt = 0
            self.reconnectWorkItem?.cancel()
            self.phase = .idle
            self.beginConnectionAttempt()
        }
    }

    /// Called by `PenBoardApp` whenever local mode/color/width changes, so the
    /// next STATE_SYNC (including on reconnect) reflects it. Safe to call from
    /// the main thread.
    func updateLocalState(mode: UInt8, color: UInt8, width: UInt8) {
        queue.async { [weak self] in
            guard let self else { return }
            self.localMode = mode
            self.localColor = color
            self.localWidth = width
        }
    }

    /// Public entry point for Mac-originated CONTROL sends (mode/color/width/
    /// clear from the menu bar or global hotkeys). Safe to call from the main
    /// thread; no-ops if not currently connected.
    func sendControl(_ packet: ControlPacket) {
        queue.async { [weak self] in
            self?.sendControlBestEffort(packet)
        }
    }

    // MARK: Connection lifecycle

    private func beginConnectionAttempt() {
        guard manager.state == .poweredOn else { return }
        guard case .idle = phase else { return }

        // Only the first attempt (reconnectAttempt == 0, i.e. right after
        // userInitiatedConnect()/onConnected() reset it) tries the fast
        // identifier-based path. retrievePeripherals(withIdentifiers:) reads
        // from a local, mostly-static cache, so if that peripheral isn't
        // actually reachable (BLE stack just reset after a reboot, tablet's
        // resolvable address hasn't been re-resolved yet, ...) every retry
        // would otherwise ask for the exact same unreachable peripheral
        // forever. Falling back to a live scan after the first failure finds
        // the tablet by whatever address it's currently advertising under.
        if reconnectAttempt == 0,
            let trustedID = Prefs.trustedPeripheralID,
            let existing = manager.retrievePeripherals(withIdentifiers: [trustedID]).first
        {
            log.info("Reconnecting to trusted peripheral by identifier")
            connect(to: existing)
        } else {
            log.info("Scanning for PenBoard service")
            phase = .scanning
            manager.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    private func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        manager.connect(peripheral, options: nil)
        armConnectTimeout()
    }

    /// CoreBluetooth connect attempts never time out on their own (Apple docs:
    /// "connection attempts don't time out"). Without a local watchdog, a
    /// peripheral that's unreachable under its retained identifier — common
    /// right after a reboot or Bluetooth reset — parks the state machine in
    /// `.connecting` forever with no error ever reported.
    private static let connectTimeoutSeconds: TimeInterval = 10

    private func armConnectTimeout() {
        connectTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.connectTimeoutSeconds)
        timer.setEventHandler { [weak self] in self?.handleConnectTimeout() }
        connectTimeoutTimer = timer
        timer.resume()
    }

    /// Cancelling a still-pending (not yet `didConnect`) connection reports
    /// through `didFailToConnect`, not `didDisconnectPeripheral` — so this
    /// routes into the existing `scheduleReconnect()` backoff/retry path,
    /// which (per `beginConnectionAttempt()` above) now falls back to
    /// scanning on the next attempt.
    private func handleConnectTimeout() {
        guard case .connecting = phase else { return }
        log.error("Connect attempt timed out — cancelling and retrying")
        cancelConnection()
    }

    /// Cancels the link and lets `centralManager(_:didDisconnectPeripheral:error:)`
    /// decide whether to reschedule (it inspects `phase`, so callers that need the
    /// manual-reconnect gate must set `phase = .waitingManualReconnect` *before*
    /// calling this).
    private func cancelConnection() {
        guard let peripheral else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    private func scheduleReconnect() {
        peripheral = nil
        reconnectAttempt += 1
        let delaySeconds = min(10.0, pow(2.0, Double(reconnectAttempt - 1)))
        phase = .backingOff(attempt: reconnectAttempt)
        log.info("Reconnect attempt \(self.reconnectAttempt, privacy: .public) in \(delaySeconds, privacy: .public)s")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.phase = .idle
            self.beginConnectionAttempt()
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    private func teardownSession() {
        pingTimer?.cancel()
        pingTimer = nil
        lastPingTimestamp = nil
        lastPingSentAt = nil
        missedPongCount = 0
        handshakeTimeoutTimer?.cancel()
        handshakeTimeoutTimer = nil
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
        lastStreamSeq = nil
        infoCharacteristic = nil
        controlCharacteristic = nil
        streamCharacteristic = nil
        handshakeToken = nil
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
        }
        activityToken = nil
    }

    // MARK: Status publishing

    private func publishState() {
        let state: ConnectionState
        switch phase {
        case .idle, .backingOff, .waitingManualReconnect:
            state = .disconnected
        case .connected:
            state = .connected
        default:
            state = .pairing
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.central(self, didChangeState: state)
        }
    }

    // MARK: Malformed-packet accounting (§8)

    /// Reason is a structural error kind for logs, never packet content (AISMA §7 redaction).
    private func recordMalformed(reason: String) {
        malformedTotal += 1
        log.error("Malformed packet (\(reason, privacy: .public)); total=\(self.malformedTotal, privacy: .public)")
        if floodGate.recordMalformed() {
            log.error("Malformed-packet flood threshold exceeded — disconnecting, manual reconnect required")
            sendControlBestEffort(.error(2))
            phase = .waitingManualReconnect
            cancelConnection()
        }
    }

    private func sendControlBestEffort(_ packet: ControlPacket) {
        guard let peripheral, let control = controlCharacteristic else { return }
        peripheral.writeValue(Packets.encodeControl(packet), for: control, type: .withResponse)
    }

    // MARK: Handshake (§6)

    private func beginHandshake() {
        guard let peripheral, let control = controlCharacteristic else { return }
        do {
            let token = try Handshake.generateToken()
            handshakeToken = token
            phase = .handshaking
            let packet = ControlPacket.hello(protoVersion: Packets.version, token: token)
            peripheral.writeValue(Packets.encodeControl(packet), for: control, type: .withResponse)
            armHandshakeTimeout()
        } catch {
            log.error("Handshake token generation failed — retrying connection")
            phase = .idle
            cancelConnection()
        }
    }

    /// §6: nothing in the protocol guarantees HELLO_OK ever arrives (dropped
    /// write, wedged peripheral, …). Without a local timer a bad handshake parks
    /// the UI in "Pairing…" forever with no watchdog running (the ping timer
    /// only starts once `onConnected()` runs, i.e. after the handshake succeeds).
    private static let handshakeTimeoutSeconds: TimeInterval = 8

    private func armHandshakeTimeout() {
        handshakeTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.handshakeTimeoutSeconds)
        timer.setEventHandler { [weak self] in self?.handleHandshakeTimeout() }
        handshakeTimeoutTimer = timer
        timer.resume()
    }

    private func handleHandshakeTimeout() {
        guard case .handshaking = phase else { return }
        log.error("Handshake timed out waiting for HELLO_OK — disconnecting and retrying")
        cancelConnection()
    }

    private func proceedAfterHelloOk() {
        guard let peripheral, let token = handshakeToken else { return }
        if Handshake.isTrusted(peripheral.identifier) {
            log.info("Trusted peripheral reconnecting — skipping confirm dialog")
            subscribeStream()
        } else {
            phase = .awaitingTrust
            let identifier = peripheral.identifier
            Handshake.presentTrustDialog(deviceName: deviceName, token: token) { [weak self] confirmed in
                guard let self else { return }
                self.queue.async {
                    guard case .awaitingTrust = self.phase else { return }
                    if confirmed {
                        Handshake.markTrusted(identifier)
                        self.log.info("User confirmed trust")
                        self.subscribeStream()
                    } else {
                        self.log.info("User declined trust — disconnecting")
                        self.phase = .waitingManualReconnect
                        self.cancelConnection()
                    }
                }
            }
        }
    }

    private func subscribeStream() {
        guard let peripheral, let stream = streamCharacteristic else { return }
        phase = .subscribingStream
        peripheral.setNotifyValue(true, for: stream)
    }

    private func sendStateSync() {
        guard let peripheral, let control = controlCharacteristic else { return }
        phase = .syncingState
        // Authoritative state lives on the Mac (§5 STATE_SYNC); mirrors whatever
        // PenBoardApp last pushed via updateLocalState(mode:color:width:), so a
        // reconnect always re-syncs the tablet to current mode/color/width.
        let packet = ControlPacket.stateSync(mode: localMode, color: localColor, width: localWidth)
        peripheral.writeValue(Packets.encodeControl(packet), for: control, type: .withResponse)
        phase = .connected
        onConnected()
    }

    private func onConnected() {
        reconnectAttempt = 0
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "PenBoard BLE session active"
        )
        startPingTimer()
    }

    // MARK: Keepalive (§6 step 9)

    private func startPingTimer() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sendPing() }
        pingTimer = timer
        timer.resume()
    }

    private func sendPing() {
        guard case .connected = phase, let peripheral, let control = controlCharacteristic else { return }

        if lastPingTimestamp != nil {
            missedPongCount += 1
            log.error("Missed PONG (\(self.missedPongCount, privacy: .public)/3)")
            if missedPongCount >= 3 {
                log.error("3 consecutive missed PONGs — disconnecting")
                cancelConnection()
                return
            }
        }

        let ts = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000))
        lastPingTimestamp = ts
        lastPingSentAt = Date()
        peripheral.writeValue(Packets.encodeControl(.ping(ts)), for: control, type: .withResponse)
    }

    private func handlePong(_ timestamp: UInt32) {
        guard timestamp == lastPingTimestamp, let sentAt = lastPingSentAt else {
            log.debug("Stale or unexpected PONG ignored")
            return
        }
        missedPongCount = 0
        lastPingTimestamp = nil
        let rttMs = Date().timeIntervalSince(sentAt) * 1000
        log.info("RTT \(rttMs, privacy: .public) ms")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.central(self, didUpdateRTTMillis: rttMs)
        }
    }

    // MARK: INFO characteristic (§6 step 3)

    private func handleInfo(_ data: Data?) {
        guard let data, data.count >= 2 else {
            recordMalformed(reason: "INFO payload too short")
            return
        }
        let bytes = [UInt8](data)
        let protoVersion = bytes[0]
        // bytes[1] = capsBitmask, reserved/0 in v1.
        let nameBytes = bytes.count > 2 ? Array(bytes[2...]) : []
        deviceName = String(bytes: nameBytes, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "PenBoard"

        guard protoVersion == Packets.version else {
            log.error("INFO protocol version mismatch — ERROR(1) + disconnect, no auto-retry")
            phase = .waitingManualReconnect
            sendControlBestEffort(.error(1))
            cancelConnection()
            return
        }

        guard let control = controlCharacteristic else {
            recordMalformed(reason: "CONTROL characteristic missing after INFO read")
            return
        }
        phase = .subscribingControl
        peripheral?.setNotifyValue(true, for: control)
    }

    // MARK: CONTROL notifications

    private func handleControlNotification(_ data: Data?) {
        guard let data else { return }
        switch Packets.decode(data) {
        case .success(.control(let packet)):
            handle(packet)
        case .success(.pointBatch):
            recordMalformed(reason: "point batch received on CONTROL characteristic")
        case .failure(.versionMismatch):
            log.error("Version mismatch on CONTROL — ERROR(1) + disconnect")
            phase = .waitingManualReconnect
            sendControlBestEffort(.error(1))
            cancelConnection()
        case .failure(let error):
            recordMalformed(reason: "\(error)")
        }
    }

    private func handle(_ packet: ControlPacket) {
        switch packet {
        case .helloOk(let protoVersion):
            guard case .handshaking = phase else { return }
            guard protoVersion == Packets.version else {
                log.error("HELLO_OK protocol version mismatch — ERROR(1) + disconnect")
                phase = .waitingManualReconnect
                sendControlBestEffort(.error(1))
                cancelConnection()
                return
            }
            handshakeTimeoutTimer?.cancel()
            handshakeTimeoutTimer = nil
            proceedAfterHelloOk()
        case .pong(let timestamp):
            handlePong(timestamp)
        case .undo, .clear, .setMode, .setColor, .setWidth:
            // §6 step 8's trust gate applies here too, not just to STREAM: a
            // bonded-but-unconfirmed peripheral must not be able to flip mode,
            // clear the canvas, or pollute Prefs before the user confirms the
            // trust dialog. Handshake opcodes (helloOk/pong/error above) are
            // intentionally not gated — they're what gets us to the gate.
            guard isPastTrustGate else {
                log.error("Ignoring tablet CONTROL opcode \(packet.opcode, privacy: .public) received before trust gate")
                return
            }
            log.debug("Received tablet control opcode \(packet.opcode, privacy: .public)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.packetDelegate?.central(self, didReceiveTabletControl: packet)
            }
        case .error(let code):
            log.error("Peripheral reported ERROR(\(code, privacy: .public))")
        case .hello, .ping, .stateSync:
            // Mac-to-tablet-only opcodes; receiving them from the tablet is a protocol
            // violation.
            recordMalformed(reason: "Mac-only opcode received from peripheral")
        }
    }

    // MARK: STREAM notifications

    private var isPastTrustGate: Bool {
        switch phase {
        case .subscribingStream, .syncingState, .connected: return true
        default: return false
        }
    }

    private func handleStreamNotification(_ data: Data?) {
        guard let data else { return }
        // §6 step 8: "Mac MUST ignore any STREAM packet that arrives before the user
        // trust gate passed." We only subscribe post-trust, but guard defensively too.
        guard isPastTrustGate else {
            log.error("Ignoring STREAM packet received before trust gate")
            return
        }
        switch Packets.decode(data) {
        case .success(.pointBatch(let batch)):
            checkStreamSequenceGap(batch.seq)
            log.debug("STREAM batch seq=\(batch.seq, privacy: .public) count=\(batch.points.count, privacy: .public)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.packetDelegate?.central(self, didReceivePointBatch: batch)
            }
        case .success(.control):
            recordMalformed(reason: "control packet received on STREAM characteristic")
        case .failure(.versionMismatch):
            log.error("Version mismatch on STREAM — ERROR(1) + disconnect")
            phase = .waitingManualReconnect
            sendControlBestEffort(.error(1))
            cancelConnection()
        case .failure(let error):
            recordMalformed(reason: "\(error)")
        }
    }

    /// §4: "seq gaps are logged... but do not error." A gap means the stack
    /// dropped a notification, which might have carried a PEN_UP — tell the
    /// delegate to force-close whatever stroke is open so the gap doesn't
    /// silently merge two strokes into one.
    private func checkStreamSequenceGap(_ seq: UInt16) {
        defer { lastStreamSeq = seq }
        guard let last = lastStreamSeq else { return }
        let expected = last &+ 1
        guard seq != expected else { return }
        log.error("STREAM seq gap: expected \(expected, privacy: .public), got \(seq, privacy: .public)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.packetDelegate?.centralDidDetectStreamSequenceGap(self)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension Central: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.info("Bluetooth powered on")
            beginConnectionAttempt()
        case .poweredOff:
            log.error("Bluetooth powered off")
            teardownSession()
            reconnectWorkItem?.cancel()
            peripheral = nil
            phase = .idle
        case .unauthorized:
            log.error("Bluetooth unauthorized (TCC)")
            phase = .idle
        case .unsupported:
            log.error("Bluetooth unsupported on this Mac")
            phase = .idle
        case .resetting:
            // bluetoothd restarting (common around reboot/wake/sleep) drops any
            // in-flight peripheral references without a didDisconnect callback.
            // Without resetting phase to .idle here, the later .poweredOn
            // callback's `guard case .idle = phase` in beginConnectionAttempt()
            // silently no-ops forever, leaving the app looking "connected" or
            // "pairing" while the link is actually gone until relaunch.
            log.error("Bluetooth resetting — tearing down and waiting for poweredOn")
            teardownSession()
            reconnectWorkItem?.cancel()
            peripheral = nil
            phase = .idle
        case .unknown:
            log.info("Bluetooth state unknown")
        @unknown default:
            log.info("Bluetooth state unrecognized")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard case .scanning = phase else { return }
        manager.stopScan()
        log.info("Discovered PenBoard peripheral — connecting")
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
        log.info("Link-layer connected — discovering services")
        phase = .discoveringServices
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
        log.error("Failed to connect: \(String(describing: error), privacy: .public)")
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        log.info("Disconnected: \(String(describing: error), privacy: .public)")
        teardownSession()
        if case .waitingManualReconnect = phase {
            return
        }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension Central: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            log.error("Service discovery failed: \(String(describing: error), privacy: .public)")
            cancelConnection()
            return
        }
        phase = .discoveringCharacteristics
        peripheral.discoverCharacteristics(
            [Self.streamCharUUID, Self.controlCharUUID, Self.infoCharUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard error == nil, let characteristics = service.characteristics else {
            log.error("Characteristic discovery failed: \(String(describing: error), privacy: .public)")
            cancelConnection()
            return
        }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.infoCharUUID: infoCharacteristic = characteristic
            case Self.controlCharUUID: controlCharacteristic = characteristic
            case Self.streamCharUUID: streamCharacteristic = characteristic
            default: break
            }
        }
        guard let info = infoCharacteristic, controlCharacteristic != nil, streamCharacteristic != nil else {
            log.error("Missing expected PenBoard characteristic(s)")
            cancelConnection()
            return
        }
        phase = .readingInfo
        peripheral.readValue(for: info)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard error == nil else {
            log.error("Read/notify error: \(String(describing: error), privacy: .public)")
            return
        }
        switch characteristic.uuid {
        case Self.infoCharUUID:
            handleInfo(characteristic.value)
        case Self.controlCharUUID:
            handleControlNotification(characteristic.value)
        case Self.streamCharUUID:
            handleStreamNotification(characteristic.value)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        if let error {
            log.error("Write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard error == nil else {
            log.error("Failed to subscribe: \(String(describing: error), privacy: .public)")
            cancelConnection()
            return
        }
        switch characteristic.uuid {
        case Self.controlCharUUID where characteristic.isNotifying && phase == .subscribingControl:
            beginHandshake()
        case Self.streamCharUUID where characteristic.isNotifying && phase == .subscribingStream:
            sendStateSync()
        default:
            break
        }
    }
}
