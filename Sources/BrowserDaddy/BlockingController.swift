import AppKit
import BrowserCore
import NetworkExtension
import SystemExtensions
import SwiftUI

struct BlockingFilterState: Sendable {
    let enabled: Bool
    let payload: Data?
    var legacyPayload: Data? = nil
    var currentRulesPresent = false
    var legacyRulesPresent = false

    nonisolated func decodedRules(catalog: BlockingListCatalog) throws -> BlockingConfiguration? {
        if currentRulesPresent || payload != nil {
            guard let payload else { throw CocoaError(.fileReadCorruptFile) }
            return try BlockingConfiguration.decodeProvider(payload, catalog: catalog)
        }
        if legacyRulesPresent || legacyPayload != nil {
            guard let legacyPayload else { throw CocoaError(.fileReadCorruptFile) }
            guard legacyPayload.count <= 512 * 1024 else { throw BlockingTransportError.configurationTooLarge }
            return try BlockingConfiguration.decode(legacyPayload)
        }
        return nil
    }
}

@MainActor
protocol BlockingPreferences {
    func load() async throws -> BlockingFilterState
    func apply(_ payload: CommittedBlockingPayload) async throws
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
        let vendor = ours ? manager.providerConfiguration?.vendorConfiguration : nil
        return BlockingFilterState(enabled: ours && manager.isEnabled,
            payload: vendor?[BlockingConfiguration.providerRulesKey] as? Data,
            legacyPayload: vendor?[BlockingConfiguration.legacyProviderRulesKey] as? Data,
            currentRulesPresent: vendor?.keys.contains(BlockingConfiguration.providerRulesKey) == true,
            legacyRulesPresent: vendor?.keys.contains(BlockingConfiguration.legacyProviderRulesKey) == true)
    }

    func apply(_ payload: CommittedBlockingPayload) async throws {
        try await queue.run { try await self.applyCurrent(payload) }
    }

    private func applyCurrent(_ payload: CommittedBlockingPayload) async throws {
        _ = try await loadCurrent()
        if let existing = manager.providerConfiguration,
           existing.filterDataProviderBundleIdentifier != BlockingConfiguration.extensionID {
            throw NSError(domain: "Blocking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another filter configuration is present. It was not changed."])
        }
        let config = NEFilterProviderConfiguration()
        config.vendorConfiguration = [BlockingConfiguration.providerRulesKey: payload.data]
        config.filterBrowsers = true
        config.filterSockets = true
        config.filterDataProviderBundleIdentifier = BlockingConfiguration.extensionID
        manager.providerConfiguration = config
        manager.localizedDescription = "BrowserDaddy site blocking"
        manager.isEnabled = true
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
    private var activationVerified = false
    private let extensionActivation: ((@escaping @MainActor () -> Void) -> Void)?
    private var committed: CommittedBlockingRules?
    private var payload: CommittedBlockingPayload?
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
         preferences: (any BlockingPreferences)? = nil, extensionAvailable: Bool? = nil,
         extensionActivation: ((@escaping @MainActor () -> Void) -> Void)? = nil) {
        self.preferences = preferences ?? SystemBlockingPreferences()
        self.extensionAvailable = extensionAvailable
        self.extensionActivation = extensionActivation
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
                let state = preview ? BlockingFilterState(enabled: false, payload: nil) : try await self.preferences.load()
                enabled = state.enabled
                let loaded = try await Task.detached(priority: .userInitiated) {
                    guard let url else { throw CocoaError(.fileNoSuchFile) }
                    var previous: [BlockingConfiguration] = []
                    if FileManager.default.fileExists(atPath: url.path) {
                        previous.append(try BlockingConfiguration.load(from: url))
                    }
                    if let native = try state.decodedRules(catalog: Self.bundledListCatalog) { previous.append(native) }
                    let rules = try CommittedBlockingRules(preserving: previous, catalog: Self.bundledListCatalog)
                    let payload = try rules.providerPayload()
                    try rules.save(to: url)
                    return (rules, payload)
                }.value
                committed = loaded.0
                payload = loaded.1
                configuration = loaded.0.configuration
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

    nonisolated private static let bundledListCatalog = BlockingListCatalog { category in
        let name = category == .adult ? "Adult" : "Gambling"
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            throw BlockingTransportError.missingResource
        }
        return try Data(contentsOf: url)
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
                if ruleDelivery == .pending && enabled && !busy { enable(); return }
                guard self.enabled else {
                    ruleDelivery = .current
                    self.status = "Filter disabled in macOS · enable protected rules"
                    return
                }
                guard self.ready else { self.status = "Filter configured · local rules unavailable"; return }
                guard let payload else { return }
                let matches = payload.matches(state.payload)
                guard self.refreshGeneration == generation else { return }
                self.status = matches ? "Filter configured · runtime unverified" : "Saved rules differ from filter · apply protected rules"
            } catch {
                guard refreshGeneration == generation else { return }
                let message = "Could not read filter preferences: \(error.localizedDescription)"
                if self.error.isEmpty { self.error = message }
                else if !self.error.contains(message) { self.error += " " + message }
                status = "Filter status unavailable"
            }
        }
    }

    func addSite(_ input: String) -> Bool {
        guard ready, !busy, let committed, let rulesURL else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = BlockingHostname(text) else {
            error = "Enter a domain such as example.com, without a path or scheme."
            return false
        }
        refreshGeneration &+= 1
        busy = true
        Task {
            do {
                let state = preview ? BlockingFilterState(enabled: false, payload: nil) : try await preferences.load()
                let value = try await Task.detached(priority: .userInitiated) {
                    let previous = try state.decodedRules(catalog: Self.bundledListCatalog)
                    let merged = try previous.map { try committed.preserving($0) } ?? committed
                    let value = try merged.addingSite(host)
                    let payload = try value.providerPayload()
                    try value.save(to: rulesURL)
                    return (value, payload)
                }.value
                self.committed = value.0
                payload = value.1
                configuration = value.0.configuration
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
        return true
    }

    private func activate() {
        guard !preview, ready, extensionBundled, !pendingApproval, !busy else { return }
        activationVerified = false
        busy = true
        status = "Waiting for macOS approval…"
        if let extensionActivation {
            extensionActivation { [weak self] in self?.finishActivation() }
            return
        }
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
        activationRequest = request
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func enable() {
        guard !preview, !busy, !pendingApproval, ready, let committed, let rulesURL else { return }
        if !activationVerified { activate(); return }
        refreshGeneration &+= 1
        busy = true
        Task {
            do {
                let state = try await preferences.load()
                let value = try await Task.detached(priority: .userInitiated) {
                    let previous = try state.decodedRules(catalog: Self.bundledListCatalog)
                    let value = try previous.map { try committed.preserving($0) } ?? committed
                    let payload = try value.providerPayload()
                    try value.save(to: rulesURL)
                    return (value, payload)
                }.value
                self.committed = value.0
                payload = value.1
                configuration = value.0.configuration
                try await preferences.apply(value.1)
                ruleDelivery = .current
                finish(nil)
            } catch {
                ruleDelivery = .failed
                finish(error)
            }
        }
    }

    private func finishActivation() {
        activationVerified = true
        busy = false
        enable()
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
            self.activationVerified = false
            self.ruleDelivery = .failed
            self.finish(error)
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.activationRequest = nil
            self.pendingApproval = false
            self.busy = false
            if result == .completed { self.finishActivation() }
            else {
                self.activationVerified = false
                self.ruleDelivery = .failed
                self.status = "Restart your Mac to finish installing the filter"
            }
        }
    }
}
