import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var configuration = BlockingConfiguration()
    private var configurationObservation: NSKeyValueObservation?
    private let rulesQueue = DispatchQueue(label: "BrowserDaddy.filter.configuration")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            configurationObservation = observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
                self?.rulesQueue.async { [weak self] in try? self?.reload() }
            }
            try rulesQueue.sync { try reload() }
            completionHandler(nil)
        } catch {
            configurationObservation = nil
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        configurationObservation = nil
        completionHandler()
    }

    private func reload() throws {
        guard let data = filterConfiguration.vendorConfiguration?[BlockingConfiguration.providerRulesKey] as? Data else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let next = try BlockingConfiguration.decode(data)
        lock.lock()
        configuration = next
        lock.unlock()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let host = flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
        guard var host else { return .allow() }
        if host.hasSuffix(".") { host.removeLast() }
        lock.lock()
        let rules = configuration.rules
        lock.unlock()
        return rules.decision(for: host) == .blocked ? .drop() : .allow()
    }
}
