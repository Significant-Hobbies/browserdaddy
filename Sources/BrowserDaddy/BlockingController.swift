import AppKit
import BrowserCore
import NetworkExtension
import SystemExtensions
import SwiftUI

@MainActor
final class BlockingController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
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
    private let preview: Bool
    private var rulesURL: URL?
    private var manager: NEFilterManager { .shared() }

    init(rulesURL suppliedURL: URL? = nil, preview suppliedPreview: Bool? = nil) {
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
                status = "Rules unavailable · saved file preserved"
                refresh()
            }
        }
    }

    var extensionBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(BlockingConfiguration.extensionID).systemextension").path)
    }

    func refresh() {
        guard !pendingApproval else { status = "Approve BrowserDaddy in System Settings → Login Items & Extensions"; return }
        guard !preview else { status = "Preview · filter inactive"; return }
        guard extensionBundled else { status = "Filter not installed in this build"; return }
        manager.loadFromPreferences { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.error = failure.localizedDescription; self.status = "Filter status unavailable"; return }
                let ours = self.manager.providerConfiguration?.filterDataProviderBundleIdentifier == BlockingConfiguration.extensionID
                self.enabled = ours && self.manager.isEnabled
                guard self.enabled else { self.status = "Filter off"; return }
                guard self.ready else { self.status = "Filter configured · local rules unavailable"; return }
                let applied = self.manager.providerConfiguration?.vendorConfiguration?[BlockingConfiguration.providerRulesKey] as? Data
                let expected = self.configuration
                let matches = await Task.detached {
                    applied.flatMap { try? BlockingConfiguration.decode($0) } == expected
                }.value
                self.status = matches ? "Filter configured · runtime unverified" : "Saved rules differ from filter · apply saved rules"
            }
        }
    }

    func save(_ value: BlockingConfiguration) {
        guard ready, !busy, let rulesURL else { return }
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
                error = ""
                busy = false
                if enabled { setEnabled(true) }
            } catch {
                busy = false
                self.error = "Rules were not saved: \(error.localizedDescription)"
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
        guard !preview, !busy, !pendingApproval else { return }
        guard !value || (ready && payload != nil) else {
            error = "Load valid local rules before enabling the filter."
            return
        }
        busy = true
        manager.loadFromPreferences { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.finish(failure); return }
                if let existing = self.manager.providerConfiguration,
                   existing.filterDataProviderBundleIdentifier != BlockingConfiguration.extensionID {
                    self.finish(NSError(domain: "Blocking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another filter configuration is present. It was not changed."]))
                    return
                }
                if value, let payload = self.payload {
                    let config = NEFilterProviderConfiguration()
                    config.vendorConfiguration = [BlockingConfiguration.providerRulesKey: payload]
                    config.filterBrowsers = true
                    config.filterSockets = true
                    config.filterDataProviderBundleIdentifier = BlockingConfiguration.extensionID
                    self.manager.providerConfiguration = config
                }
                self.manager.localizedDescription = "BrowserDaddy site blocking"
                self.manager.isEnabled = value
                self.manager.saveToPreferences { failure in
                    Task { @MainActor in self.finish(failure) }
                }
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
