import Foundation
import Network
import os

/// A5/C1-C4 (Feature 2 MVP): the MJPEG-over-HTTP server + Bonjour
/// advertisement. Own serial queue, same `@unchecked Sendable` +
/// serial-queue-confinement pattern as `Central`/`ScreenStreamer` — all
/// mutable state (listener, token, current client) is only ever touched
/// confined to `queue`, which is also the queue NWListener/NWConnection
/// deliver their callbacks on (`start(queue:)` on the same queue both times).
///
/// R-5: the Bonjour TXT `tok` is the only access control in v1 — no TLS, no
/// pairing-derived secret (non-goal). R-6: `NWListener(using:on:)` binds all
/// interfaces; the token path plus a LAN-only threat model is the accepted v1
/// mitigation (documented in the plan's risk register, not re-litigated here).
final class MJPEGServer: NSObject, @unchecked Sendable {

    /// C1: Bonjour service type, fixed by contract.
    private static let serviceType = "_penboard-stream._tcp"
    /// C3: bounded read of the request line only — the server never reads
    /// the socket again after that.
    private static let requestReadCap = 1024

    private let log = Logger(subsystem: "it.aisma.penboard", category: "stream.server")
    private let queue = DispatchQueue(label: "it.aisma.penboard.stream.server")

    private var listener: NWListener?
    private var token: String?
    /// C3: the server holds exactly one streaming client; a new connection
    /// presenting a valid token replaces (closes) the old one.
    private var client: NWConnection?
    /// Accepted connections that haven't presented a request yet. Tracked so
    /// teardown can reach them and so a peer that connects and sends nothing
    /// (port scanner, Slowloris) is cancelled after a timeout instead of
    /// being kept alive forever by its pending receive callback.
    private var pendingConnections: [NWConnection] = []
    private static let requestTimeoutSeconds: TimeInterval = 5
    /// C4 backpressure: skip a push if the previous one hasn't completed —
    /// only the latest frame is ever queued for a slow client, never a
    /// growing buffer.
    private var isSending = false
    /// Most recent frame, replayed to a newly adopted client. ScreenCaptureKit
    /// only delivers `.complete` frames when the screen changes, so without
    /// this a tablet connecting to a static screen (a slide, a paused video)
    /// stays blank until something on the Mac moves. Cleared on teardown so a
    /// frame never outlives its token.
    private var lastFrame: Data?

    /// Surfaced so `StreamController` (A6) can react to listener failures
    /// (e.g. the OS refusing to bind/advertise) the same way
    /// `ScreenStreamer.onStopped` surfaces capture failures. Always fires on
    /// `queue`.
    var onFailure: ((Error) -> Void)?

    /// C1/C2: starts listening on an OS-assigned ephemeral port and
    /// advertises via Bonjour with `token` in the TXT record (C2: `v`/`tok`
    /// keys). Safe to call again — tears down any previous listener/client
    /// first (this is also the token-rotation path: a fresh toggle-ON gets a
    /// fresh token per C2, which is why a stale client must always be
    /// dropped here rather than kept around).
    func start(token: String) {
        let newListener: NWListener
        do {
            newListener = try NWListener(using: .tcp, on: .any)
        } catch {
            log.error("NWListener creation failed: \(String(describing: error), privacy: .public)")
            onFailure?(error)
            return
        }

        // C2: TXT record — `v` pins the stream-contract version (independent
        // of the BLE protocol version); unknown keys are ignored by the
        // tablet, so nothing else needs to go in here for v1.
        newListener.service = NWListener.Service(
            name: nil,
            type: Self.serviceType,
            domain: nil,
            txtRecord: NWTXTRecord(["v": "1", "tok": token])
        )
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log.info("MJPEG listener ready on port \(newListener.port?.rawValue ?? 0, privacy: .public)")
            case .failed(let error):
                self.log.error("MJPEG listener failed: \(String(describing: error), privacy: .public)")
                self.onFailure?(error)
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        queue.sync {
            teardownLocked()
            self.token = token
            self.listener = newListener
        }
        newListener.start(queue: queue)
    }

    /// C1: stops serving and withdraws the Bonjour advertisement (implicit on
    /// listener cancel) plus closes any active client. Idempotent.
    func stop() {
        queue.sync {
            teardownLocked()
            token = nil
        }
    }

    /// C4: pushes one already-JPEG-encoded frame to the current client, if
    /// any. Safe to call from any thread — `ScreenStreamer.onFrame` fires on
    /// its own capture queue, not this server's queue — this hops onto
    /// `queue` itself before touching any state.
    func push(frame: Data) {
        queue.async { [weak self] in
            guard let self, self.listener != nil else { return }
            self.lastFrame = frame
            guard let client = self.client else { return }
            self.send(frame, to: client)
        }
    }

    /// C4 backpressure: drops `frame` if a send is still in flight.
    private func send(_ frame: Data, to client: NWConnection) {
        guard !isSending else { return }
        isSending = true
        let part = MJPEGWire.part(jpeg: frame)
        client.send(
            content: part,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                // `isSending` belongs to the current client only. A replaced
                // client's late completion (adopt() already reset the flag and
                // may have the replay frame in flight) must not clear it, or
                // the next push would stack a second send behind that one.
                self.queue.async {
                    if self.client === client { self.isSending = false }
                }
                if let error {
                    self.log.error("Frame send failed: \(String(describing: error), privacy: .public)")
                }
            }
        )
    }

    /// Must only run confined to `queue` (via `queue.sync` above, or already
    /// running on `queue` via a listener/connection callback).
    private func teardownLocked() {
        client?.cancel()
        client = nil
        isSending = false
        lastFrame = nil
        for pending in pendingConnections { pending.cancel() }
        pendingConnections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func removePending(_ connection: NWConnection) {
        pendingConnections.removeAll { $0 === connection }
    }

    // MARK: New connections (C3)

    private func handleNewConnection(_ connection: NWConnection) {
        pendingConnections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { connection.cancel() }
            switch state {
            case .failed, .cancelled:
                self.removePending(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A peer that connects and never sends a request would otherwise be
        // held alive forever by the pending receive below.
        queue.asyncAfter(deadline: .now() + Self.requestTimeoutSeconds) { [weak self, weak connection] in
            guard let self, let connection else { return }
            if self.pendingConnections.contains(where: { $0 === connection }) {
                self.log.info("Dropping connection that sent no request within timeout")
                connection.cancel()
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.requestReadCap) { [weak self] data, _, _, error in
            guard let self else { return }
            self.removePending(connection)
            guard
                error == nil, let data, let path = MJPEGWire.requestPath(from: data),
                let token = self.token, MJPEGWire.pathMatches(path: path, token: token)
            else {
                self.reject(connection)
                return
            }
            self.adopt(connection)
        }
    }

    /// C3: valid token — send the response header and adopt as the single
    /// streaming client, replacing (closing) whatever client was there
    /// before. This is also the reconnect path (C3): the tablet just opens a
    /// fresh connection and the old one gets closed here.
    private func adopt(_ connection: NWConnection) {
        client?.cancel()
        isSending = false
        client = connection
        // Watch the adopted client's state: a dead client (tablet slept, left
        // Wi-Fi, or closed) must release its socket and clear the slot —
        // Network.framework only frees a connection on explicit cancel, and
        // nothing else ever clears `client` until the next adopt/teardown.
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed:
                connection.cancel()
                fallthrough
            case .cancelled:
                if self.client === connection {
                    self.log.info("Streaming client disconnected")
                    self.client = nil
                    self.isSending = false
                }
            default:
                break
            }
        }
        connection.send(
            content: MJPEGWire.responseHeader(),
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.log.error("Header send failed: \(String(describing: error), privacy: .public)")
                }
            }
        )
        log.info("Streaming client connected")
        if let lastFrame { send(lastFrame, to: connection) }
    }

    /// C3: wrong method/path/token -> 404 + close immediately, no body.
    private func reject(_ connection: NWConnection) {
        connection.send(
            content: MJPEGWire.notFoundResponse(),
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}
