import AppKit
import BrowserCore
import NetworkExtension
import SystemExtensions
import SwiftUI

@MainActor
final class BlockingController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var configuration = BlockingConfiguration()
    @Published private(set) var status = "Checking filter…"
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published var error = ""
    private let preview: Bool
    private var rulesURL: URL?
    private var manager: NEFilterManager { .shared() }

    override init() {
        preview = CommandLine.arguments.contains("--preview-fixture")
            || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true
        super.init()
        do {
            if preview {
                rulesURL = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserDaddy-blocking-preview-\(UUID().uuidString).json")
            } else {
                rulesURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BlockingConfiguration.group)?
                    .appendingPathComponent(BlockingConfiguration.filename)
            }
            guard let rulesURL else { throw CocoaError(.fileNoSuchFile) }
            if FileManager.default.fileExists(atPath: rulesURL.path) {
                configuration = try BlockingConfiguration.load(from: rulesURL)
            } else {
                configuration.categories = [.adult, .gambling]
                for category in BlockingCategory.allCases {
                    let name = category == .adult ? "Adult" : "Gambling"
                    guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    configuration.lists[category] = try BlockingConfiguration.parseList(String(contentsOf: url, encoding: .utf8))
                }
                try configuration.save(to: rulesURL)
            }
        } catch { self.error = "Could not load local blocking rules: \(error.localizedDescription)" }
        refresh()
    }

    var extensionBundled: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(BlockingConfiguration.extensionID).systemextension").path)
    }

    func refresh() {
        guard !preview else { status = "Preview · filter inactive"; return }
        guard extensionBundled else { status = "Filter not installed in this build"; return }
        manager.loadFromPreferences { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                if let failure { self.error = failure.localizedDescription; self.status = "Filter status unavailable"; return }
                let ours = self.manager.providerConfiguration?.filterDataProviderBundleIdentifier == BlockingConfiguration.extensionID
                self.enabled = ours && self.manager.isEnabled
                self.status = self.enabled ? "Filter configured · runtime unverified" : "Filter off"
            }
        }
    }

    func save(_ value: BlockingConfiguration) {
        do {
            guard let rulesURL else { throw CocoaError(.fileNoSuchFile) }
            try value.save(to: rulesURL)
            configuration = value
            error = ""
        } catch { self.error = "Rules were not saved: \(error.localizedDescription)" }
    }

    func addSite(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = BlockingHostname(text) else {
            error = "Enter a domain such as example.com, without a path or scheme."
            return false
        }
        var value = configuration
        value.sites.insert(host)
        save(value)
        return configuration.sites.contains(host)
    }

    func importList(_ category: BlockingCategory) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a UTF-8 domain list for \(category.title). One domain per line, or hosts-file format."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let hosts = try BlockingConfiguration.parseList(String(contentsOf: url, encoding: .utf8))
            var value = configuration
            value.lists[category] = hosts
            save(value)
        } catch { self.error = "List was not imported. Use a nonempty domain or hosts list under 32 MB." }
    }

    func activate() {
        guard !preview, extensionBundled, rulesURL != nil, !busy else { return }
        busy = true
        status = "Waiting for macOS approval…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func setEnabled(_ value: Bool) {
        guard !preview, !busy else { return }
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
                let config = NEFilterProviderConfiguration()
                config.filterBrowsers = true
                config.filterSockets = true
                config.filterDataProviderBundleIdentifier = BlockingConfiguration.extensionID
                self.manager.providerConfiguration = config
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
        if let failure { error = failure.localizedDescription }
        refresh()
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = "Approve BrowserDaddy in System Settings → Login Items & Extensions" }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                            withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.finish(error) }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.busy = false
            if result == .completed { self.setEnabled(true) }
            else { self.status = "Restart your Mac to finish installing the filter" }
        }
    }
}
