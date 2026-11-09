import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var policy = BlockingPolicy()
    private var configurationObservation: NSKeyValueObservation?
    private let rulesQueue = DispatchQueue(label: "BrowserDaddy.filter.configuration")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            configurationObservation = observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
                self?.rulesQueue.async { [weak self] in try? self?.reload() }
            }
            try rulesQueue.sync { try reload() }
            completionHandler(nil)
        } catch { completionHandler(nil) }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        configurationObservation = nil
        completionHandler()
    }

    private func reload() throws {
        guard let data = filterConfiguration.vendorConfiguration?[BlockingConfiguration.providerRulesKey] as? Data else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let next = try BlockingPolicy(data: data)
        lock.lock()
        policy = next
        lock.unlock()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let host = flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
        lock.lock()
        let policy = self.policy
        lock.unlock()
        return policy.blocks(hostname: host, outgoing: flow.direction == .outbound) ? .drop() : .allow()
    }
}
