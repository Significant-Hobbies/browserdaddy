import AppKit
import BrowserCore
import ServiceManagement
@testable import BrowserDaddy
import XCTest

@MainActor
final class MenuLifecycleTests: XCTestCase {
    private func makeModel() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-menu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ArchiveStore(url: directory.appendingPathComponent("fixture.db"))
        store.metaSet("onboarded", "1")
        return (AppModel(store: store, startCollection: {}), directory)
    }

    func testClosingLastWindowKeepsRoutingAndCollectionAlive() {
        let delegate = BrowserDaddyAppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
        XCTAssertTrue(DaddyQuitReview.shouldQuit(appName: "BrowserDaddy", activeWork: nil))
    }

    func testQuitReviewCoversSyncAndClassification() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(model.activeWorkDescription)
        model.extracting = true
        XCTAssertEqual(model.activeWorkDescription, "History sync is still running.")
        model.extracting = false
        model.classifying = true
        XCTAssertEqual(model.activeWorkDescription, "Classification is still running.")
        model.classifying = false
        XCTAssertNil(model.activeWorkDescription)
    }

    func testMenuKeepsNeverSyncedFailedAndSuccessfulSyncDistinct() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(model.menuStatus, "History not synced yet")
        let synced = Date(timeIntervalSince1970: 1_800_000_000)
        model.finishExtract(needsAttention: false, at: synced)
        XCTAssertEqual(model.lastSuccessfulSyncAt, synced)
        XCTAssertTrue(model.menuStatus.hasPrefix("Last history sync "))
        model.finishExtract(needsAttention: true, at: synced.addingTimeInterval(60))
        XCTAssertEqual(model.lastSuccessfulSyncAt, synced)
        XCTAssertEqual(model.menuStatus, "Last history sync needs attention")
        model.extracting = true
        XCTAssertEqual(model.menuStatus, "Syncing local history…")
    }

    func testCompletionNoticesPostOnlyWhenEnabledAndNoWindowIsVisible() async throws {
        XCTAssertTrue(DaddyCompletionNotices.shouldPost(enabled: true, hasVisibleWindow: false))
        XCTAssertFalse(DaddyCompletionNotices.shouldPost(enabled: true, hasVisibleWindow: true))
        XCTAssertFalse(DaddyCompletionNotices.shouldPost(enabled: false, hasVisibleWindow: false))
        let suite = "BrowserDaddy-notices-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(DaddyCompletionNotices.isAvailable)
        let enabled = await DaddyCompletionNotices.setEnabled(true, defaults: defaults)
        XCTAssertFalse(enabled)
        XCTAssertFalse(DaddyCompletionNotices.isEnabled(defaults))
    }

    func testLaunchAtLoginReflectsTheSystemStateAfterEachChange() {
        var status = SMAppService.Status.notRegistered
        var failRegister = false
        var registeredStatus = SMAppService.Status.enabled
        let login = DaddyLaunchAtLogin(service: .init(
            status: { status },
            register: {
                if failRegister { throw CocoaError(.featureUnsupported) }
                status = registeredStatus
            },
            unregister: { status = .notRegistered }
        ))
        XCTAssertFalse(login.isEnabled)
        login.set(true)
        XCTAssertTrue(login.isEnabled)
        XCTAssertNil(login.message)
        login.set(false)
        XCTAssertFalse(login.isEnabled)
        failRegister = true
        login.set(true)
        XCTAssertFalse(login.isEnabled)
        XCTAssertEqual(login.message, DaddyLaunchAtLogin.failureMessage)
        failRegister = false
        registeredStatus = .requiresApproval
        login.set(true)
        XCTAssertFalse(login.isEnabled)
        XCTAssertEqual(login.message, DaddyLaunchAtLogin.approvalMessage)
    }
}
