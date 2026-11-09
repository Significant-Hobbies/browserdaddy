import AppKit
import BrowserCore
import NetworkExtension
import SystemExtensions
import SwiftUI

struct BlockingFilterState: Sendable {
    let enabled: Bool
    let payload: Data?
}

@MainActor
protocol BlockingPreferences {
    func load() async throws -> BlockingFilterState
    func save(enabled: Bool, payload: Data?) async throws
}

@MainActor
final class BlockingPreferenceQueue {
    private var tail: Task<Void, Never>?
    func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}

@MainActor
private final class SystemBlockingPreferences: BlockingPreferences {
    private let manager = NEFilterManager.shared()
    private let queue = BlockingPreferenceQueue()

    func load() async throws -> BlockingFilterState {
        try await queue.run { try await self.loadCurrent() }
    }

    private func loadCurrent() async throws -> BlockingFilterState {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let ours = manager.providerConfiguration?.filterDataProviderBundleIdentifier == BlockingConfiguration.extensionID
        return BlockingFilterState(enabled: ours && manager.isEnabled,
                                   payload: ours ? manager.providerConfiguration?.vendorConfiguration?[BlockingConfiguration.providerRulesKey] as? Data : nil)
    }

    func save(enabled: Bool, payload: Data?) async throws {
        try await queue.run { try await self.saveCurrent(enabled: enabled, payload: payload) }
    }

    private func saveCurrent(enabled: Bool, payload: Data?) async throws {
        _ = try await loadCurrent()
        if let existing = manager.providerConfiguration,
           existing.filterDataProviderBundleIdentifier != BlockingConfiguration.extensionID {
            throw NSError(domain: "Blocking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another filter configuration is present. It was not changed."])
        }
        if enabled {
            guard let payload else { throw CocoaError(.fileReadCorruptFile) }
            let config = NEFilterProviderConfiguration()
            config.vendorConfiguration = [BlockingConfiguration.providerRulesKey: payload]
            config.filterBrowsers = true
            config.filterSockets = true
            config.filterDataProviderBundleIdentifier = BlockingConfiguration.extensionID
            manager.providerConfiguration = config
        }
        manager.localizedDescription = "BrowserDaddy site blocking"
        manager.isEnabled = enabled
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

@MainActor
final class BlockingController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    private enum RuleDelivery { case current, pending, failed }
    private var ruleDelivery = RuleDelivery.current
    static let shared = BlockingController()
    @Published private(set) var ready = false
    private var pendingApproval = false
    private var activationRequest: OSSystemExtensionRequest?
    private var payload: Data?
    @Published private(set) var configuration = BlockingConfiguration()
    @Published private(set) var status = "Checking filter…"
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published var error = ""
    @Published private(set) var loadError = ""
    private var refreshGeneration: UInt64 = 0
    private let preview: Bool
    private var rulesURL: URL?
    private let preferences: any BlockingPreferences
    private let extensionAvailable: Bool?

    init(rulesURL suppliedURL: URL? = nil, preview suppliedPreview: Bool? = nil,
         preferences: (any BlockingPreferences)? = nil, extensionAvailable: Bool? = nil) {
        self.preferences = preferences ?? SystemBlockingPreferences()
        self.extensionAvailable = extensionAvailable
        preview = suppliedPreview ?? (CommandLine.arguments.contains("--preview-fixture")
            || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true)
        super.init()
        rulesURL = suppliedURL ?? (preview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("BrowserDaddy-blocking-preview-\(UUID().uuidString).json")
            : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BlockingConfiguration.group)?
                .appendingPathComponent(BlockingConfiguration.filename))
        let url = rulesURL
        status = "Loading local rules…"
        busy = true
        Task {
            do {
                let (loaded, data) = try await Task.detached(priority: .userInitiated) {
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    var loaded = BlockingConfiguration()
                    if FileManager.default.fileExists(atPath: url.path) {
                        loaded = try BlockingConfiguration.load(from: url)
                    } else {
                        loaded.categories = [.adult, .gambling]
                        for category in BlockingCategory.allCases {
                            let name = category == .adult ? "Adult" : "Gambling"
                            guard let resource = Bundle.module.url(forResource: name, withExtension: "txt") else {
                                throw CocoaError(.fileNoSuchFile)
                            }
                            loaded.lists[category] = try BlockingConfiguration.parseList(String(contentsOf: resource, encoding: .utf8))
                        }
                        try loaded.save(to: url)
                    }
                    return (loaded, try loaded.providerData())
                }.value
                configuration = loaded
                payload = data
                ready = true
                busy = false
                refresh()
            } catch {
                busy = false
                self.error = "Could not load local blocking rules. Editing is disabled to preserve the saved file: \(error.localizedDescription)"
                loadError = self.error
                status = "Rules unavailable · saved file preserved"
                refresh()
            }
        }
    }

    var extensionBundled: Bool {
        extensionAvailable ?? FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(BlockingConfiguration.extensionID).systemextension").path)
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        guard !(busy && !ready) else { return }
        guard !pendingApproval else { status = "Approve BrowserDaddy in System Settings → Login Items & Extensions"; return }
        guard !preview else { status = "Preview · filter inactive"; return }
        guard extensionBundled else { status = "Filter not installed in this build"; return }
        Task {
            do {
                let state = try await preferences.load()
                guard refreshGeneration == generation else { return }
                enabled = state.enabled
                if ruleDelivery == .pending && enabled && !busy { setEnabled(true); return }
                guard self.enabled else {
                    ruleDelivery = .current
                    self.status = "Filter off"
                    return
                }
                guard self.ready else { self.status = "Filter configured · local rules unavailable"; return }
                let applied = state.payload
                let expected = self.configuration
                let matches = await Task.detached {
                    applied.flatMap { try? BlockingConfiguration.decode($0) } == expected
                }.value
                guard self.refreshGeneration == generation else { return }
                self.status = matches ? "Filter configured · runtime unverified" : "Saved rules differ from filter · apply saved rules"
            } catch {
                guard refreshGeneration == generation else { return }
                let message = "Could not read filter preferences: \(error.localizedDescription)"
                if self.error.isEmpty { self.error = message }
                else if !self.error.contains(message) { self.error += " " + message }
                status = "Filter status unavailable"
            }
        }
    }

    func save(_ value: BlockingConfiguration) {
        guard ready, !busy, let rulesURL else { return }
        refreshGeneration &+= 1
        busy = true
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let data = try value.providerData()
                    try value.save(to: rulesURL)
                    return data
                }.value
                configuration = value
                payload = data
                ruleDelivery = .pending
                error = ""
                busy = false
                refresh()
            } catch {
                busy = false
                self.error = "Rules were not saved: \(error.localizedDescription)"
                refresh()
            }
        }
    }

    func addSite(_ input: String) -> Bool {
        guard ready, !busy else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = BlockingHostname(text) else {
            error = "Enter a domain such as example.com, without a path or scheme."
            return false
        }
        var value = configuration
        value.sites.insert(host)
        save(value)
        return true
    }

    func importList(_ category: BlockingCategory) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a UTF-8 domain list for \(category.title). One domain per line, or hosts-file format."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ready, !busy else { return }
        busy = true
        Task {
            do {
                let hosts = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    return try BlockingConfiguration.parseList(String(contentsOf: url, encoding: .utf8))
                }.value
                var value = configuration
                value.lists[category] = hosts
                busy = false
                save(value)
            } catch {
                busy = false
                self.error = "List was not imported. Use a nonempty domain or hosts list under 32 MB."
                refresh()
            }
        }
    }

    func activate() {
        guard !preview, ready, extensionBundled, !pendingApproval, !busy else { return }
        busy = true
        status = "Waiting for macOS approval…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
        activationRequest = request
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func setEnabled(_ value: Bool) {
        guard !preview, !busy, !(value && pendingApproval) else { return }
        guard !value || (ready && payload != nil) else {
            if error.isEmpty { error = "Load valid local rules before enabling the filter." }
            return
        }
        refreshGeneration &+= 1
        busy = true
        Task {
            do {
                try await preferences.save(enabled: value, payload: value ? payload : nil)
                ruleDelivery = .current
                finish(nil)
            } catch {
                ruleDelivery = .failed
                finish(error)
            }
        }
    }

    private func finish(_ failure: Error?) {
        busy = false
        if let failure { error = "Filter preferences were not updated; saved local rules may differ: \(failure.localizedDescription)" }
        refresh()
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.pendingApproval = true
            self.busy = false
            self.status = "Approve BrowserDaddy in System Settings → Login Items & Extensions"
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                            withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in
            self.activationRequest = nil
            self.pendingApproval = false
            self.finish(error)
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.activationRequest = nil
            self.pendingApproval = false
            self.busy = false
            if result == .completed { self.setEnabled(true) }
            else { self.status = "Restart your Mac to finish installing the filter" }
        }
    }
}
