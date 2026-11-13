import AppKit
import BrowserCore
import Foundation
import SaaSMakerUI
import SwiftUI

/// Standalone test application. The generated package excludes the product's
/// entry point, delegate, startup coordinator, menu bar and collection bootstrap.
@main
@MainActor
struct BrowserDaddySceneReviewApp: App {
    private let fixture: SceneFixture

    init() {
        do { fixture = try SceneFixture() }
        catch {
            FileHandle.standardError.write(Data("Scene fixture initialization failed\n".utf8))
            exit(78)
        }
    }

    var body: some Scene {
        WindowGroup(SceneFixture.title) {
            RootView(reviewWorkspace: .blocking, blockingController: fixture.controller,
                     protectionCheck: fixture.protection)
                .environmentObject(fixture.model)
                .frame(minWidth: 920, minHeight: 620)
                .smWorkspaceWindowChrome()
                .browserTheme(BrowserTheme.palette)
                .buttonStyle(SMMacButtonStyle(.secondary))
                .disabled(true)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {}
        }
    }
}

@MainActor
private final class SceneFixture {
    static let title = "BrowserDaddy · Standalone SwiftUI fixture"
    let model: AppModel
    let controller: BlockingController
    let protection: ProtectionCheckModel
    private let native: SceneFixturePreferences
    private let output: URL
    private let temporary: URL
    private let defaults: UserDefaults
    private let suiteName: String
    private var timer: Timer?
    private var firstVisible: Date?
    private var wroteReady = false
    private var stopping = false

    init() throws {
        let arguments = CommandLine.arguments
        func argument(_ name: String) throws -> String {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return arguments[index + 1]
        }
        guard Bundle.main.bundleIdentifier?.hasPrefix("com.significanthobbies.browserdaddy.scene-review.") == true else {
            throw CocoaError(.executableNotLoadable)
        }
        let expectedHome = URL(fileURLWithPath: try argument("--fixture-home"), isDirectory: true)
        guard FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL == expectedHome.standardizedFileURL else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard BrowserUIResources.loaded else { throw CocoaError(.fileReadCorruptFile) }
        protection = ProtectionCheckModel(networkAllowed: false)
        native = SceneFixturePreferences()
        output = URL(fileURLWithPath: try argument("--fixture-output"), isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("ready.json").path),
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("done").path),
              !FileManager.default.fileExists(atPath: output.appendingPathComponent("finished.json").path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        temporary = expectedHome.appendingPathComponent("SceneFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        suiteName = "BrowserDaddy-standalone-fixture-\(UUID().uuidString)"
        do {
            guard let defaults = UserDefaults(suiteName: suiteName) else { throw CocoaError(.fileWriteUnknown) }
            self.defaults = defaults
            let store = try ArchiveStore(url: temporary.appendingPathComponent("archive.db"))
            store.metaSet("onboarded", "1")
            model = AppModel(store: store, startCollection: {}, previewFixture: true,
                             browserGrantStore: BrowserGrantStore(defaults: defaults))
            var rules = BlockingConfiguration()
            rules.scheduledSites = [ScheduledSiteBlock(hostname: BlockingHostname("x.com")!,
                weekdays: Set(1...7), startMinute: 600, endMinute: 0)!]
            let rulesURL = temporary.appendingPathComponent("rules.json")
            try rules.save(to: rulesURL)
            controller = BlockingController(rulesURL: rulesURL, preview: true, preferences: native,
                extensionAvailable: false, extensionActivation: { _ in
                    preconditionFailure("A fixture must never request extension activation")
                })
        } catch {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        Task { await model.reload() }
        let started = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !self.stopping else { return }
                if !self.wroteReady, self.controller.ready, !self.controller.busy,
                   let window = NSApplication.shared.windows.first(where: { $0.title == Self.title && $0.isVisible }) {
                    window.contentView?.layoutSubtreeIfNeeded()
                    if self.firstVisible == nil {
                        self.firstVisible = Date()
                        window.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    } else if Date().timeIntervalSince(self.firstVisible!) >= 0.2 {
                        do {
                            let ready: [String: Any] = [
                                "windowTitle": Self.title, "fixture": true, "actualSwiftUIWindowGroup": true,
                                "nativeWindowNumber": window.windowNumber,
                                "processIdentifier": ProcessInfo.processInfo.processIdentifier,
                                "nativeWindowWidth": window.frame.width, "nativeWindowHeight": window.frame.height,
                                "nativeContentWidth": window.contentView?.bounds.width ?? 0,
                                "nativeContentHeight": window.contentView?.bounds.height ?? 0,
                                "nativeTitlebarAppearsTransparent": window.titlebarAppearsTransparent,
                                "privateHomeVerified": true,
                                "fixtureTitleDiffersFromProduction": true,
                                "allFixtureContentDisabled": true,
                                "doneFile": self.output.appendingPathComponent("done").path
                            ]
                            try self.write(ready, name: "ready.json")
                            self.wroteReady = true
                        } catch { self.stop(success: false) }
                    }
                }
                if FileManager.default.fileExists(atPath: self.output.appendingPathComponent("done").path) {
                    self.stop(success: self.wroteReady)
                } else if Date().timeIntervalSince(started) >= 120 {
                    self.stop(success: false)
                }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func write(_ value: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }

    private func stop(success: Bool) -> Never {
        stopping = true
        timer?.invalidate()
        let previewState = controller.status == "Preview · filter inactive"
        let isolated = native.loadCount == 0 && native.applyCount == 0 && !controller.enabled && previewState
        do {
            defaults.removePersistentDomain(forName: suiteName)
            try FileManager.default.removeItem(at: temporary)
            let state: [String: Any] = ["nativePreferencesLoads": native.loadCount,
                "nativePreferencesApplies": native.applyCount, "blockingEnabled": controller.enabled,
                "isolationVerified": isolated, "fixtureCleanupCompleted": true,
                "previewStateConfirmed": previewState, "preferenceCountersAreRegressionTripwires": true,
                "sceneReady": wroteReady, "successful": success && isolated]
            try write(state, name: "finished.json")
            FileHandle.standardOutput.write(Data("Standalone scene fixture finished; isolation=\(isolated)\n".utf8))
            exit(success && isolated ? 0 : 1)
        } catch { exit(1) }
    }
}

@MainActor
private final class SceneFixturePreferences: BlockingPreferences {
    private(set) var loadCount = 0
    private(set) var applyCount = 0
    func load() async throws -> BlockingFilterState {
        loadCount += 1
        return BlockingFilterState(enabled: false, payload: nil)
    }
    func apply(_ payload: CommittedBlockingPayload) async throws { applyCount += 1 }
}
