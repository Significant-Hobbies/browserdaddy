import XCTest
import BrowserCore
@testable import BrowserDaddy

final class BlockingControllerTests: XCTestCase {
    @MainActor
    func testFailedLoadCannotOverwriteTheSavedRules() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let original = Data("unreadable rules retained for recovery".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = BlockingController(rulesURL: file, preview: true)
        for _ in 0..<1000 where controller.busy {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.ready)
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertFalse(controller.addSite("example.com"))
        controller.save(BlockingConfiguration())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
