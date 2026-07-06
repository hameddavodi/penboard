import Cocoa
import Testing

@testable import PenBoard

/// PROTOCOL §5: "UNDO ... Remove last completed stroke." Android skips an
/// in-progress stroke when computing "last completed"; these tests pin that
/// same behavior on the Mac side (the regression this file guards against: a
/// mid-flight UNDO killing the live stroke and orphaning its remaining
/// PEN_MOVEs).
struct StrokeStoreTests {

    @Test func undoLeavesSoleOpenStrokeIntact() {
        let store = StrokeStore()
        let open = store.beginStroke(color: .black, baseWidth: 4)
        open.append(position: CGPoint(x: 0, y: 0), pressure: 0.5)
        open.append(position: CGPoint(x: 10, y: 10), pressure: 0.5)

        #expect(store.strokes.count == 1)
        let dirty = store.undo()
        #expect(dirty == nil)
        #expect(store.strokes.count == 1)
        #expect(store.strokes.first === open)
        #expect(open.isOpen == true)
    }

    @Test func undoRemovesLastCompletedStrokeButKeepsTrailingOpenStroke() {
        let store = StrokeStore()

        let completed = store.beginStroke(color: .black, baseWidth: 4)
        completed.append(position: CGPoint(x: 0, y: 0), pressure: 0.5)
        completed.append(position: CGPoint(x: 10, y: 10), pressure: 0.5)
        store.closeOpenStroke()
        #expect(completed.isOpen == false)

        let open = store.beginStroke(color: .black, baseWidth: 4)
        open.append(position: CGPoint(x: 20, y: 20), pressure: 0.5)

        #expect(store.strokes.count == 2)
        let dirty = store.undo()
        #expect(dirty != nil)
        #expect(store.strokes.count == 1)
        #expect(store.strokes.first === open)
        #expect(open.isOpen == true)
    }

    @Test func undoOnEmptyStoreReturnsNil() {
        let store = StrokeStore()
        #expect(store.undo() == nil)
    }
}
