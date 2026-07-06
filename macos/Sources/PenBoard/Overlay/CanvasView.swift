import Cocoa
import os

/// M2.2: renders strokes built from incoming POINT_BATCH points (Draw mode
/// only — `PenBoardApp` routes packets here or to `CursorInjector` depending on
/// mode). Layer-backed + dirty-rect invalidation keeps redraws cheap; the
/// Catmull-Rom math itself lives in `Stroke.append` (StrokeStore.swift), so a
/// new point only ever costs one small `NSBezierPath` segment, never a full
/// stroke rebuild.
final class CanvasView: NSView {

    private let log = Logger(subsystem: "it.aisma.penboard", category: "canvas")
    private let strokeStore = StrokeStore()

    private var color: NSColor = Palette.color(for: 4) // black default, matches prior STATE_SYNC default
    private var baseWidth: CGFloat = 4

    /// Barrel-button-held drag state (object eraser, D3).
    private var isErasing = false

    private var stallTimer: DispatchSourceTimer?
    /// PROTOCOL §4: force-close an open stroke after 500 ms without new points.
    private static let stallInterval: TimeInterval = 0.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        startStallTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        stallTimer?.cancel()
    }

    // MARK: Settings (STATE_SYNC / SET_COLOR / SET_WIDTH)

    func setColor(paletteIndex: UInt8) {
        color = Palette.color(for: paletteIndex)
    }

    func setBaseWidth(points: CGFloat) {
        baseWidth = points
    }

    // MARK: Ingest (Draw mode only)

    /// Consumes one POINT_BATCH's points in order, building/erasing strokes and
    /// invalidating only the redraw needed for what changed.
    func ingest(points: [Point]) {
        for point in points {
            guard let event = point.event else { continue }
            // View-local bounds (zero origin, same size as the overlay window) —
            // CoordinateMapper.overlayPoint works the same whether given a
            // screen-global frame or a local-origin bounds rect.
            let mapped = CoordinateMapper.overlayPoint(x: point.x, y: point.y, in: bounds)

            switch event {
            case .hoverMove, .hoverEnter, .hoverExit:
                continue // PROTOCOL §4: hover is ignored in Draw mode.

            case .penDown:
                if point.barrelButtonHeld {
                    isErasing = true
                    eraseIfHit(at: mapped)
                } else {
                    isErasing = false
                    let stroke = strokeStore.beginStroke(color: color, baseWidth: baseWidth)
                    if let dirty = stroke.append(position: mapped, pressure: normalizedPressure(point)) {
                        setNeedsDisplay(dirty)
                    }
                }

            case .penMove:
                if isErasing {
                    eraseIfHit(at: mapped)
                } else if let stroke = strokeStore.openStroke,
                    let dirty = stroke.append(position: mapped, pressure: normalizedPressure(point))
                {
                    setNeedsDisplay(dirty)
                }

            case .penUp:
                if isErasing {
                    eraseIfHit(at: mapped)
                    isErasing = false
                } else {
                    // Extend to the lift-off position itself before closing, so
                    // the final segment isn't silently dropped.
                    if let stroke = strokeStore.openStroke,
                        let dirty = stroke.append(position: mapped, pressure: normalizedPressure(point))
                    {
                        setNeedsDisplay(dirty)
                    }
                    strokeStore.closeOpenStroke()
                }
            }
        }
    }

    private func normalizedPressure(_ point: Point) -> Double {
        Double(point.pressure) / 65535.0
    }

    private func eraseIfHit(at point: CGPoint) {
        let tolerance = max(baseWidth, 12)
        if let dirty = strokeStore.eraseStroke(near: point, tolerance: tolerance) {
            setNeedsDisplay(dirty)
        }
    }

    // MARK: Undo / clear (menu, hotkeys, tablet toolbar)

    func undo() {
        if let dirty = strokeStore.undo() {
            setNeedsDisplay(dirty)
        }
    }

    func clear() {
        setNeedsDisplay(bounds)
        strokeStore.clear()
    }

    /// PROTOCOL §4: called when `Central` detects a STREAM seq gap — the dropped
    /// notification might have carried this stroke's PEN_UP, so close it now
    /// instead of silently appending later points to a stroke the tablet already
    /// considers finished. No redraw needed: closing changes routing, not pixels.
    func forceCloseOpenStroke() {
        strokeStore.closeOpenStroke()
    }

    // MARK: Stall force-close (PROTOCOL §4)

    private func startStallTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
        timer.setEventHandler { [weak self] in
            // Scheduled on the main queue, so this always runs on MainActor's
            // executor — assumeIsolated bridges the plain (non-isolated)
            // DispatchSourceTimer handler closure type into that context.
            MainActor.assumeIsolated {
                self?.checkStall()
            }
        }
        stallTimer = timer
        timer.resume()
    }

    private func checkStall() {
        guard let open = strokeStore.openStroke else { return }
        if Date().timeIntervalSince(open.lastUpdate) > Self.stallInterval {
            log.info("Force-closing stalled stroke (500 ms without points)")
            strokeStore.closeOpenStroke()
            isErasing = false
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for stroke in strokeStore.strokes {
            stroke.color.setStroke()
            for segment in stroke.segments where segment.bounds.intersects(dirtyRect) {
                segment.path.stroke()
            }
        }
    }

    // MARK: Debug replay (EXECUTION-PLAN §6 replay harness)

    /// Feeds a small built-in recorded point sequence through the exact same
    /// `ingest(points:)` path real STREAM packets use, so rendering can be
    /// verified without BLE/hardware (menu: Debug > Run Debug Replay; launch
    /// flag: `--debug-replay`, wired in PenBoardApp).
    func runDebugReplay() {
        log.info("Running debug replay (\(Self.debugReplayPoints.count) points)")
        ingest(points: Self.debugReplayPoints)
    }

    /// A wavy line with a pressure ramp, normalized 0...65535 (top-left origin),
    /// PEN_DOWN -> PEN_MOVE x N -> PEN_UP.
    static let debugReplayPoints: [Point] = {
        let steps = 40
        return (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let x = UInt16(10_000 + t * 45_000)
            let y = UInt16(30_000 + sin(t * .pi * 2) * 10_000)
            let pressure = UInt16(10_000 + t * 50_000)
            let event: Point.Event = i == 0 ? .penDown : (i == steps ? .penUp : .penMove)
            return Point(x: x, y: y, pressure: pressure, event: event)
        }
    }()
}

/// PROTOCOL §7 — fixed v1 palette (sRGB hex).
enum Palette {
    private static let hexByIndex: [UInt8: String] = [
        0: "E5484D", // Red
        1: "3B82F6", // Blue
        2: "30A46C", // Green
        3: "F5D90A", // Yellow
        4: "111111", // Black
        5: "FFFFFF", // White
    ]

    static func color(for index: UInt8) -> NSColor {
        guard let hex = hexByIndex[index], let color = NSColor(penBoardHex: hex) else { return .black }
        return color
    }
}

extension NSColor {
    fileprivate convenience init?(penBoardHex hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
