import BrowserCore
import Combine
@testable import BrowserDaddy
import XCTest

@MainActor
final class FocusPublicationTests: XCTestCase {
    func testOnlyChangedFocusFieldsPublishAndUnavailableURLsClear() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-focus-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            store: try ArchiveStore(url: directory.appendingPathComponent("fixture.db")),
            startCollection: {}
        )
        var apps: [String] = []
        var urls: [String] = []
        var changes = 0
        let appSubscription = model.$nowApp.dropFirst().sink { apps.append($0) }
        let urlSubscription = model.$nowURL.dropFirst().sink { urls.append($0) }
        let changeSubscription = model.objectWillChange.sink { changes += 1 }
        defer {
            appSubscription.cancel()
            urlSubscription.cancel()
            changeSubscription.cancel()
        }

        model.updateCurrentFocus(app: "", url: "")
        XCTAssertEqual(changes, 0)
        model.updateCurrentFocus(app: "Google Chrome", url: "https://fixture.example/first")
        XCTAssertEqual(model.nowApp, "Google Chrome")
        XCTAssertEqual(model.nowURL, "https://fixture.example/first")
        model.updateCurrentFocus(app: "Google Chrome", url: "https://fixture.example/first")
        XCTAssertEqual(changes, 2)
        model.updateCurrentFocus(app: "Google Chrome", url: "https://fixture.example/second")
        XCTAssertEqual(changes, 3)
        model.updateCurrentFocus(app: "Brave Browser", url: "https://fixture.example/second")
        XCTAssertEqual(changes, 4)
        model.updateCurrentFocus(app: "Brave Browser", url: "")
        XCTAssertEqual(model.nowURL, "")
        XCTAssertEqual(changes, 5)
        model.updateCurrentFocus(app: "", url: "")
        model.updateCurrentFocus(app: "", url: "")

        XCTAssertEqual(model.nowApp, "")
        XCTAssertEqual(model.nowURL, "")
        XCTAssertEqual(apps, ["Google Chrome", "Brave Browser", ""])
        XCTAssertEqual(urls, ["https://fixture.example/first", "https://fixture.example/second", ""])
        XCTAssertEqual(changes, 6)
        XCTAssertFalse(model.watcher.isRunning)
    }
}
