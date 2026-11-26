import AppKit
import BrowserCore
import SaaSMakerUI
import SwiftUI

/// The unified host receives URL events centrally; BrowserDaddy retains its own
/// GURL registration and Sparkle updater only in the standalone executable.
@MainActor public enum BrowserWorkspaceRuntime {
    public static func start() { EmbeddedBrowser.shared.resume() }

    @discardableResult public static func handleURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        start()
        return EmbeddedBrowser.shared.model?.route(url) ?? false
    }

    public static var activeWorkDescription: String? { EmbeddedBrowser.shared.model?.activeWorkDescription }
}

@MainActor private final class EmbeddedBrowser: ObservableObject {
    static let shared = EmbeddedBrowser()
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("daddyrad/Browser/Archive", isDirectory: true)
    private var database: URL { directory.appendingPathComponent("browserdaddy.db") }
    @Published private(set) var model: AppModel?
    @Published private(set) var preparing = false
    @Published private(set) var problem: String?

    func resume() {
        guard model == nil, !preparing, FileManager.default.fileExists(atPath: database.path) else { return }
        do {
            let app = AppModel(store: try ArchiveStore(url: database))
            self.model = app
            app.boot()
            if BlockingController.hostIncludesFilter { _ = BlockingController.shared }
            LinkRouterService.shared.install(handlesAppleEvents: false)
            problem = nil
        } catch {
            problem = "Could not open the local browsing archive. Check disk space and access, then retry."
        }
    }

    func prepare(importing source: URL?) {
        guard !preparing, model == nil else { return }
        preparing = true
        problem = nil
        let directory = directory
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let scoped = source?.startAccessingSecurityScopedResource() ?? false
                    defer { if scoped { source?.stopAccessingSecurityScopedResource() } }
                    try BrowserWorkspaceArchive.create(at: directory, importing: source)
                }.value
                preparing = false
                resume()
            } catch {
                preparing = false
                resume()
                if model == nil {
                    problem = "Could not prepare the archive. Choose a readable BrowserDaddy database and retry. Existing archives are preserved."
                }
            }
        }
    }
}

public struct BrowserWorkspaceView: View {
    private let route: String
    @ObservedObject private var browser = EmbeddedBrowser.shared
    public init(route: String) { self.route = route }

    public var body: some View {
        Group {
            if let model = browser.model {
                EmbeddedBrowserContent(model: model, route: route)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Browsing archive").font(.title2.bold())
                    Text("Bring a copy of your BrowserDaddy archive, or start a local archive. Choose browser folders and collection permissions in setup.")
                    HStack {
                        Button("Import BrowserDaddy archive…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            panel.message = "Choose browserdaddy.db from the BrowserDaddy application support folder."
                            if panel.runModal() == .OK, let url = panel.url { browser.prepare(importing: url) }
                        }
                        Button("Start new archive") { browser.prepare(importing: nil) }
                    }
                    .disabled(browser.preparing)
                    if browser.preparing { ProgressView("Preparing archive…") }
                    if let problem = browser.problem { Text(problem).foregroundStyle(.secondary) }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { BrowserWorkspaceRuntime.start() }
        .browserTheme(BrowserTheme.palette)
        .buttonStyle(SMMacButtonStyle(.secondary))
    }
}

private struct EmbeddedBrowserContent: View {
    @ObservedObject var model: AppModel
    let route: String
    var body: some View {
        Group {
            if model.needsOnboarding {
                OnboardingView()
            } else if let workspace = Workspace.allCases.first(where: { $0.rawValue.lowercased() == route.lowercased() }) {
                if workspace == .blocking && !BlockingController.hostIncludesFilter {
                    ContentUnavailableView {
                        Label("Website blocking requires the signed filter", systemImage: "shield")
                    } description: {
                        Text("Manage existing rules in BrowserDaddy until this installation includes the approved system extension.")
                    } actions: {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.significanthobbies.browserdaddy") {
                            Button("Open BrowserDaddy") {
                                NSWorkspace.shared.openApplication(at: app, configuration: .init())
                            }
                        }
                    }
                } else {
                    RootView(embeddedWorkspace: workspace).id(workspace)
                }
            } else {
                ContentUnavailableView("Browser workspace unavailable", systemImage: "rectangle.stack")
            }
        }
        .environmentObject(model)
    }
}

public struct BrowserWorkspaceSettings: View {
    @ObservedObject private var browser = EmbeddedBrowser.shared
    public init() {}
    public var body: some View {
        Group {
            if let model = browser.model { BrowserSettingsContent(model: model) }
            else { Text("Open Browser to set up the local archive.") }
        }
        .onAppear { BrowserWorkspaceRuntime.start() }
    }
}

public struct BrowserWorkspaceMenu: View {
    @ObservedObject private var browser = EmbeddedBrowser.shared
    public init() {}
    public var body: some View {
        if let model = browser.model { EmbeddedBrowserMenuContent(model: model) }
    }
}

private struct EmbeddedBrowserMenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        DaddyMenuStatus(message: model.menuStatus)
        Button("Choose browser for copied link") { model.openClipboardLink() }
        Button("Sync browser history") { model.syncHistoryNow() }
            .disabled(model.needsOnboarding || model.extracting)
        DaddyCompletionNoticeToggle(title: "Notify When Sync or Classification Finishes")
    }
}
