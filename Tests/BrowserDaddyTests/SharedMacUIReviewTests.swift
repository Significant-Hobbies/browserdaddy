import AppKit
import BrowserCore
import SaaSMakerUI
import SwiftUI
import XCTest
@testable import BrowserDaddy

/// Opt-in real-view host. It never launches BrowserDaddyApp, installs hotkeys,
/// starts collection, or registers a system extension. The parent captures the
/// normal window and acknowledges it by creating `done` beside `ready.json`.
@MainActor
final class SharedMacUIReviewTests: XCTestCase {
    func testSharedMacUIReviewHost() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BROWSERDADDY_UI_REVIEW"] == "1")
        let output = try XCTUnwrap(environment["BROWSERDADDY_UI_REVIEW_DIR"])
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let doneURL = outputURL.appendingPathComponent("done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: doneURL.path), "Use a fresh review directory")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDaddy-UI-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suiteName = "BrowserDaddy-UI-fixture-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = try ArchiveStore(url: temporary.appendingPathComponent("archive.db"))
        store.metaSet("onboarded", "1")
        let source = HistorySource(browser: "chrome", profile: "Fixture", path: temporary, engine: .chromium)
        let pages = [
            ("https://developer.apple.com/documentation/swiftui", "SwiftUI documentation"),
            ("https://github.com/example/project/pulls", "Pull requests · example/project"),
            ("https://docs.example.test/a-long-guide", "A longer guide title for reviewing native row truncation and alignment")
        ]
        try store.merge(visits: pages.enumerated().map { index, page in
            HistoryVisit(browser: "chrome", profile: "Fixture", visitID: Int64(index + 1),
                         url: page.0, title: page.1, visitedAt: Date().addingTimeInterval(-Double(index * 600)),
                         visitCount: 1, typedCount: 0, transition: "link", fromVisit: nil)
        }, source: source)
        let model = AppModel(store: store, startCollection: {}, previewFixture: true,
                             browserGrantStore: BrowserGrantStore(defaults: preferences))
        model.alertConfig.enabled = true
        model.alertConfig.dailyMinutes = 120
        model.alertConfig.streakMinutes = 30
        model.alertConfig.agentMinutes = 60
        model.alertConfig.siteCaps = ["docs.example.test": 45]
        await model.reload()
        XCTAssertEqual(model.historyRows.count, 3)
        model.tabGroups = [.init(kind: .chrome, state: .tabs(pages.enumerated().map { index, page in
            BrowserTab(browser: .chrome, window: 1, index: index + 1, url: page.0, title: page.1)
        }))]


        var rules = BlockingConfiguration()
        rules.scheduledSites = [try XCTUnwrap(ScheduledSiteBlock(
            hostname: BlockingHostname("x.com")!, weekdays: Set(1...7), startMinute: 600, endMinute: 0))]
        let rulesURL = temporary.appendingPathComponent("rules.json")
        try rules.save(to: rulesURL)
        let blockingPreferences = FixtureBlockingPreferences()
        let controller = BlockingController(rulesURL: rulesURL, preview: true,
            preferences: blockingPreferences, extensionAvailable: false,
            extensionActivation: { _ in XCTFail("A UI fixture must not activate an extension") })
        for _ in 0..<2_000 {
            if !controller.busy { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(controller.ready, controller.error)
        let state = UIReviewState()
        if let scene = environment["BROWSERDADDY_UI_REVIEW_SCENE"] {
            state.scene = try XCTUnwrap(UIReviewScene(rawValue: scene))
        }
        let width = Double(environment["BROWSERDADDY_UI_REVIEW_WIDTH"] ?? "1240") ?? 1_240
        XCTAssertTrue((920...1_600).contains(width))
        let height = Double(environment["BROWSERDADDY_UI_REVIEW_HEIGHT"] ?? "800") ?? 800
        XCTAssertTrue((620...1_200).contains(height))
        let fontURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SaaSMakerUI_SaaSMakerUI.bundle")
        XCTAssertTrue(BrowserUIResources.registerFonts(in: Bundle(url: fontURL)))
        if environment["BROWSERDADDY_SWIFTUI_SCENE_REVIEW"] == "1" {
            let driver = SceneReviewDriver(outputURL: outputURL, width: width, height: height) {
                AnyView(UIReviewHost(model: model, controller: controller, state: state)
                    .browserTheme(BrowserTheme.palette).buttonStyle(SMMacButtonStyle(.secondary)))
            }
            SceneReviewApp.driver = driver
            defer { SceneReviewApp.driver = nil }
            driver.begin()
            // App.main() is SwiftUI's real @main entry point. It creates this
            // test-only WindowGroup; BrowserDaddyApp is never initialized.
            SceneReviewApp.main()
            driver.finish()
            try JSONSerialization.data(withJSONObject: [
                "nativePreferencesLoads": blockingPreferences.loadCount,
                "nativePreferencesApplies": blockingPreferences.applyCount,
                "blockingEnabled": controller.enabled
            ], options: [.prettyPrinted, .sortedKeys])
                .write(to: outputURL.appendingPathComponent("state.json"), options: .atomic)
            XCTAssertNil(driver.writeError)
            XCTAssertTrue(driver.wroteReady, "The real SwiftUI scene must appear")
            XCTAssertEqual(blockingPreferences.loadCount, 0)
            XCTAssertEqual(blockingPreferences.applyCount, 0)
            XCTAssertFalse(controller.enabled)
            return
        }
        let host = NSHostingView(rootView: UIReviewHost(model: model, controller: controller, state: state)
            .browserTheme(BrowserTheme.palette).buttonStyle(SMMacButtonStyle(.secondary)))
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: width, height: height),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "BrowserDaddy · Direction A fixture"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 920, height: 620)
        window.contentView = host
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let ready: [String: Any] = [
            "windowTitle": window.title,
            "fixture": true,
            "viewContentOnly": false,
            "logicalContentWidth": width,
            "logicalContentHeight": height,
            "nativeWindowNumber": window.windowNumber,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "nativeWindowWidth": window.frame.width,
            "nativeWindowHeight": window.frame.height,
            "nativeContentWidth": host.bounds.width,
            "nativeContentHeight": host.bounds.height,
            "scenes": UIReviewScene.allCases.map(\.rawValue),
            "doneFile": doneURL.path,
            "readOnlyScenes": UIReviewScene.allCases.map(\.rawValue),
            "note": "Production content, Sync and About are disabled for screenshot review. Sidebar navigation is available and changes only the fixture workspace. No content control may open URLs, write the clipboard, request access, change login, request notifications or trigger external tagging."
        ]
        try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputURL.appendingPathComponent("ready.json"), options: .atomic)
        let started = Date()
        var writeError: Error?
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if FileManager.default.fileExists(atPath: doneURL.path)
                    || Date().timeIntervalSince(started) >= 120 {
                    NSApplication.shared.stop(nil)
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApplication.shared.postEvent(event, atStart: false)
                    }
                    return
                }
                let snapshot: [String: Any] = [
                    "initialScene": state.scene.rawValue,
                    "search": model.searchTerm,
                    "historyRows": model.historyRows.count,
                    "blockingReady": controller.ready,
                    "nativePreferencesLoads": blockingPreferences.loadCount,
                    "nativePreferencesApplies": blockingPreferences.applyCount,
                    "nativeWindowWidth": window.frame.width,
                    "nativeWindowHeight": window.frame.height,
                    "nativeContentWidth": host.bounds.width,
                    "nativeContentHeight": host.bounds.height
                ]
                do {
                    try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                        .write(to: outputURL.appendingPathComponent("state.json"), options: .atomic)
                } catch { writeError = error }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        NSApplication.shared.run()
        timer.invalidate()
        if let writeError { throw writeError }
        XCTAssertEqual(blockingPreferences.loadCount, 0)
        XCTAssertEqual(blockingPreferences.applyCount, 0)
        XCTAssertFalse(controller.enabled)
    }
}

/// Kept in the default-skipped test target: no production executable, startup,
/// controller or preference route is used to prove native SwiftUI scene chrome.
@MainActor
private struct SceneReviewApp: App {
    static var driver: SceneReviewDriver?
    var body: some Scene {
        WindowGroup(SceneReviewDriver.title) {
            if let driver = Self.driver {
                driver.content()
                    .frame(minWidth: 920, minHeight: 620)
                    .smWorkspaceWindowChrome()
                    .browserTheme(BrowserTheme.palette)
                    .onAppear { driver.begin() }
            }
        }
        .defaultSize(width: Self.driver?.width ?? 1240, height: Self.driver?.height ?? 800)
        .windowStyle(.titleBar)
    }
}

@MainActor
private final class SceneReviewDriver {
    static let title = "BrowserDaddy · SwiftUI scene fixture"
    let outputURL: URL
    let width: Double
    let height: Double
    let content: () -> AnyView
    private var timer: Timer?
    private weak var window: NSWindow?
    private(set) var writeError: Error?
    private(set) var wroteReady = false

    init(outputURL: URL, width: Double, height: Double, content: @escaping () -> AnyView) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.content = content
    }

    func begin() {
        guard timer == nil else { return }
        let started = Date()
        NSApplication.shared.setActivationPolicy(.regular)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !self.wroteReady, let window = NSApplication.shared.windows.first(where: {
                    $0.title == Self.title && $0.isVisible
                }) {
                    self.window = window
                    window.makeKeyAndOrderFront(nil)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    do {
                        let ready: [String: Any] = [
                            "windowTitle": Self.title, "fixture": true, "actualSwiftUIWindowGroup": true,
                            "nativeWindowNumber": window.windowNumber,
                            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                            "nativeWindowWidth": window.frame.width, "nativeWindowHeight": window.frame.height,
                            "nativeContentWidth": window.contentView?.bounds.width ?? 0,
                            "nativeContentHeight": window.contentView?.bounds.height ?? 0,
                            "nativeTitlebarAppearsTransparent": window.titlebarAppearsTransparent,
                            "doneFile": self.outputURL.appendingPathComponent("done").path,
                            "note": "Real SwiftUI App.main WindowGroup with isolated models, preview controller and disabled content actions. No BrowserDaddyApp, collection, hotkeys or live filter preferences."
                        ]
                        try JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted, .sortedKeys])
                            .write(to: self.outputURL.appendingPathComponent("ready.json"), options: .atomic)
                        self.wroteReady = true
                    } catch { self.writeError = error }
                }
                if self.writeError != nil
                    || FileManager.default.fileExists(atPath: self.outputURL.appendingPathComponent("done").path)
                    || Date().timeIntervalSince(started) >= 120 {
                    NSApplication.shared.stop(nil)
                    if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                        modifierFlags: [], timestamp: 0, windowNumber: self.window?.windowNumber ?? 0,
                        context: nil, subtype: 0, data1: 0, data2: 0) {
                        NSApplication.shared.postEvent(event, atStart: false)
                    }
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        window?.close()
    }
}

@MainActor
private final class FixtureBlockingPreferences: BlockingPreferences {
    var loadCount = 0
    var applyCount = 0
    func load() async throws -> BlockingFilterState {
        loadCount += 1
        return BlockingFilterState(enabled: false, payload: nil)
    }
    func apply(_ payload: CommittedBlockingPayload) async throws { applyCount += 1 }
}

private enum UIReviewScene: String, CaseIterable, Identifiable {
    case history = "History", blocking = "Blocking", alerts = "Alerts", permissions = "Permissions"
    case attention = "Attention", tabs = "Tabs", dashboard = "Dashboard", router = "Router"
    var id: Self { self }
    var workspace: Workspace? { Workspace(rawValue: rawValue) }
}

@MainActor
private final class UIReviewState: ObservableObject {
    @Published var scene = UIReviewScene.history
}

private struct UIReviewHost: View {
    let model: AppModel
    let controller: BlockingController
    @ObservedObject var state: UIReviewState
    @StateObject private var protection = ProtectionCheckModel(networkAllowed: false)

    var body: some View {
        Group {
            if state.scene == .alerts {
                AlertSettingsView().padding(30).frame(maxWidth: 520).disabled(true)
            } else {
                RootView(reviewWorkspace: state.scene.workspace ?? .history, blockingController: controller,
                         protectionCheck: protection)
            }
        }
        .environmentObject(model)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .smWorkspaceWindowChrome()
    }
}
