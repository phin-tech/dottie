import XCTest
@testable import DottieKit
#if canImport(Darwin)
import Darwin
#endif

/// `LiveClient.current`, what `dottie render` and `inspect` read: the app's open copy when there is one.
final class LiveClientTests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        // Short, so it fits sockaddr_un.
        socketPath = "/tmp/dottie-test-\(UUID().uuidString.prefix(8)).sock"
        setenv("DOTTIE_LIVE_SOCKET", socketPath, 1)
    }

    override func tearDown() {
        unsetenv("DOTTIE_LIVE_SOCKET")
        unlink(socketPath)
        super.tearDown()
    }

    private func file(_ text: String) -> DottieFile {
        var page = DottieDocument()
        page.elements = [Element(kind: .rectangle, frame: CGRect(x: 0, y: 0, width: 10, height: 10), layerID: page.layers[0].id, text: text)]
        return DottieFile(pages: [page])
    }

    /// Answers one `get` with `response`, on a background thread.
    private func serveOnce(_ response: LiveResponse?) -> XCTestExpectation {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = LiveSocket.address(socketPath)!
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        Darwin.listen(fd, 1)
        let done = expectation(description: "served")
        Thread.detachNewThread {
            defer { close(fd); done.fulfill() }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            _ = LiveSocket.readLine(fd: client)
            // nil: hold the connection without answering, as a hung app would.
            guard let response else { usleep(800_000); return }
            _ = LiveSocket.writeAll(fd: client, try! JSONEncoder().encode(response))
        }
        return done
    }

    func testNoAppGivesTheDiskCopyQuietly() {
        let disk = file("saved")
        let r = LiveClient.current(path: "/tmp/x.dottie", disk: disk)
        XCTAssertEqual(r?.file, disk)
        XCTAssertEqual(r?.unsaved, false)
        XCTAssertNil(LiveClient.current(path: "/tmp/x.dottie", disk: nil))
    }

    func testOpenDocumentWithUnsavedEditsWins() {
        let disk = file("saved"), live = file("edited by an agent")
        let served = serveOnce(LiveResponse(open: true, file: live))
        let r = LiveClient.current(path: "/tmp/x.dottie", disk: disk)
        XCTAssertEqual(r?.file, live)
        XCTAssertEqual(r?.unsaved, true)
        wait(for: [served], timeout: 5)
    }

    func testOpenDocumentMatchingDiskIsNotUnsaved() {
        let disk = file("saved")
        let served = serveOnce(LiveResponse(open: true, file: disk))
        XCTAssertEqual(LiveClient.current(path: "/tmp/x.dottie", disk: disk)?.unsaved, false)
        wait(for: [served], timeout: 5)
    }

    func testFileNotOpenGivesTheDiskCopy() {
        let disk = file("saved")
        let served = serveOnce(LiveResponse(open: false))
        XCTAssertEqual(LiveClient.current(path: "/tmp/x.dottie", disk: disk)?.file, disk)
        wait(for: [served], timeout: 5)
    }

    func testAnAppThatDoesNotAnswerTimesOutToDisk() {
        let disk = file("saved")
        let served = serveOnce(nil)
        let start = Date()
        let r = LiveClient.current(path: "/tmp/x.dottie", disk: disk, timeout: 0.2)
        XCTAssertEqual(r?.file, disk)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.7)
        wait(for: [served], timeout: 5)
    }
}
