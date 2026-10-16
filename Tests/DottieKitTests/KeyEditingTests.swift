import XCTest
@testable import DottieKit

final class KeyEditingTests: XCTestCase {
    private let id = UUID()
    private func timeline() -> Timeline {
        var tl = Timeline(fps: 10, duration: 2)
        tl.setKey(Keyframe(t: 0, x: 0), for: id)
        tl.setKey(Keyframe(t: 1, x: 100, ease: .easeIn), for: id)
        return tl
    }

    func testMoveRetimesSnapsToFramesAndGrowsTheTimeline() {
        var tl = timeline()
        tl.moveKey(of: id, from: 1, to: 2.73)
        XCTAssertEqual(tl.track(for: id)?.keys.map(\.t), [0, 2.7])
        XCTAssertEqual(tl.key(of: id, at: 2.7)?.ease, .easeIn, "the key keeps what it sets")
        XCTAssertEqual(tl.duration, 2.7)
        tl.moveKey(of: id, from: 2.7, to: -1)
        XCTAssertEqual(tl.track(for: id)?.keys.map(\.t), [0], "dropped onto the key at 0, merged")
        XCTAssertEqual(tl.key(of: id, at: 0)?.x, 100)
    }

    func testCopyLeavesTheOriginal() {
        var tl = timeline()
        tl.moveKey(of: id, from: 1, to: 1.5, copy: true)
        XCTAssertEqual(tl.track(for: id)?.keys.map(\.t), [0, 1, 1.5])
        XCTAssertEqual(tl.key(of: id, at: 1.5)?.x, 100)
    }

    func testRemoveAndEase() {
        var tl = timeline()
        tl.setEase(.hold, of: id, at: 0)
        XCTAssertEqual(tl.key(of: id, at: 0)?.ease, .hold)
        tl.setEase(.linear, of: id, at: 0)
        XCTAssertNil(tl.key(of: id, at: 0)?.ease)
        tl.removeKey(of: id, at: 1)
        XCTAssertEqual(tl.track(for: id)?.keys.map(\.t), [0])
        tl.removeKey(of: id, at: 0)
        XCTAssertNil(tl.track(for: id), "an empty track goes")
        tl.moveKey(of: UUID(), from: 0, to: 1)   // nothing there: no-op
        XCTAssertTrue(tl.tracks.isEmpty)
    }
}
