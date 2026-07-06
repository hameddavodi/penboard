import Cocoa

/// M2.2: stroke data model + list management. Rendering-shaped work (Catmull-Rom
/// smoothing) lives here too, but only as an incremental cache each `Stroke`
/// builds as points arrive — `CanvasView` never rebuilds a whole stroke to
/// redraw it, it just strokes the cached segments that intersect the dirty rect.
final class Stroke {
    let id = UUID()
    var color: NSColor
    var baseWidth: CGFloat

    /// AppKit-space points (already mapped via `CoordinateMapper`), paired with
    /// normalized 0...1 pressure, in arrival order.
    private(set) var rawPoints: [(position: CGPoint, pressure: Double)] = []

    /// One small Catmull-Rom cubic per consecutive point pair, pre-built so
    /// redraw only ever strokes cached paths.
    private(set) var segments: [(path: NSBezierPath, bounds: CGRect)] = []

    var lastUpdate = Date()
    var isOpen = true

    init(color: NSColor, baseWidth: CGFloat) {
        self.color = color
        self.baseWidth = baseWidth
    }

    /// Appends a point and, once there are 2+ points, builds the new segment
    /// between the previous point and this one. Returns the bounding box that
    /// needs to be redrawn, or `nil` for the first point (nothing to stroke yet).
    ///
    /// Catmull-Rom needs points before and after the segment for its tangents;
    /// since points arrive live there is no "after" point yet, so the segment's
    /// end tangent duplicates the end point itself (a standard, stable
    /// approximation for live/streaming smoothing — it just means the very last
    /// segment's exit tangent is a straight continuation rather than curving
    /// toward a future point that doesn't exist yet).
    @discardableResult
    func append(position: CGPoint, pressure: Double) -> CGRect? {
        rawPoints.append((position, pressure))
        lastUpdate = Date()
        guard rawPoints.count >= 2 else { return nil }

        let n = rawPoints.count
        let p0 = rawPoints[n >= 3 ? n - 3 : n - 2].position
        let p1 = rawPoints[n - 2].position
        let p2 = rawPoints[n - 1].position
        let p3 = p2

        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)

        let avgPressure = (rawPoints[n - 2].pressure + rawPoints[n - 1].pressure) / 2
        // PLAN.md/EXECUTION-PLAN M2.2: pressure -> width, base width x 0.25...1.75.
        let width = baseWidth * CGFloat(0.25 + 1.5 * avgPressure)

        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = width
        path.move(to: p1)
        path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)

        let bounds = path.bounds.insetBy(dx: -width, dy: -width)
        segments.append((path, bounds))
        return bounds
    }

    /// Whole-stroke bounding box, for undo/erase redraw invalidation.
    var bounds: CGRect {
        segments.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    /// Distance from `point` to the nearest raw segment — used by the
    /// barrel-button object eraser (D3: whole-stroke removal on hit).
    func distance(to point: CGPoint) -> CGFloat {
        guard rawPoints.count >= 2 else {
            guard let only = rawPoints.first else { return .greatestFiniteMagnitude }
            return hypot(only.position.x - point.x, only.position.y - point.y)
        }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<rawPoints.count {
            let d = Self.distance(from: point, toSegment: rawPoints[i - 1].position, rawPoints[i].position)
            best = min(best, d)
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let projected = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(p.x - projected.x, p.y - projected.y)
    }
}

/// Stroke list: undo = pop last, clear = all (PLAN.md M2.2 scope).
final class StrokeStore {
    private(set) var strokes: [Stroke] = []

    @discardableResult
    func beginStroke(color: NSColor, baseWidth: CGFloat) -> Stroke {
        let stroke = Stroke(color: color, baseWidth: baseWidth)
        strokes.append(stroke)
        return stroke
    }

    var openStroke: Stroke? {
        guard let last = strokes.last, last.isOpen else { return nil }
        return last
    }

    func closeOpenStroke() {
        strokes.last?.isOpen = false
    }

    /// Undo = remove the last COMPLETED stroke (§5). A trailing in-progress
    /// (open) stroke is left alone — killing it mid-flight would orphan whatever
    /// PEN_MOVEs are still in transit for it, and Android's UNDO skips it too.
    @discardableResult
    func undo() -> CGRect? {
        guard let index = strokes.lastIndex(where: { !$0.isOpen }) else { return nil }
        return strokes.remove(at: index).bounds
    }

    func clear() {
        strokes.removeAll()
    }

    /// D3 object eraser: removes the topmost (most recently drawn) stroke within
    /// `tolerance` of `point`, if any. Returns its bounds for redraw.
    @discardableResult
    func eraseStroke(near point: CGPoint, tolerance: CGFloat) -> CGRect? {
        guard let index = strokes.lastIndex(where: { $0.distance(to: point) <= tolerance }) else { return nil }
        return strokes.remove(at: index).bounds
    }
}
