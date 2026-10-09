import BrowserCore
import XCTest
@testable import BrowserDaddy

final class AppUpdatePolicyTests: XCTestCase {
    @MainActor func testSyncAndClassificationBothPreventRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: try ArchiveStore(url: directory.appendingPathComponent("fixture.db")), startCollection: {})
        let updates = AppUpdates()
        updates.start(model: model)
        XCTAssertTrue(updates.isIdle)
        model.extracting = true
        XCTAssertFalse(updates.isIdle)
        model.extracting = false
        model.classifying = true
        XCTAssertFalse(updates.isIdle)
        model.classifying = false
        XCTAssertTrue(updates.isIdle)
    }
}
