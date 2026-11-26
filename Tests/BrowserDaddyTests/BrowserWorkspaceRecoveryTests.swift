import Foundation
import XCTest
@testable import BrowserDaddy

final class BrowserWorkspaceRecoveryTests: XCTestCase {
    @MainActor func testRetryPreservesExistingArchiveAndDistinguishesFreshSetup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let browser = EmbeddedBrowser(directory: folder)
        browser.resume()
        XCTAssertFalse(browser.needsRecovery)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        browser.resume()
        XCTAssertTrue(browser.needsRecovery)
        XCTAssertTrue(browser.problem?.contains("missing") == true)
        let file = folder.appendingPathComponent("browserdaddy.db")
        let damaged = Data("sample damaged archive".utf8)
        try damaged.write(to: file)
        browser.resume()
        XCTAssertTrue(browser.needsRecovery)
        XCTAssertNil(browser.model)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }
}
