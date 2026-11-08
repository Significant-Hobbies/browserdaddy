import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var configuration = BlockingConfiguration()
    private var timer: DispatchSourceTimer?
    private var rulesURL: URL?
    private var modified: Date?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BlockingConfiguration.group) else {
            completionHandler(CocoaError(.fileReadNoPermission))
            return
        }
        rulesURL = root.appendingPathComponent(BlockingConfiguration.filename)
        do {
            try reload()
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "BrowserDaddy.filter.rules"))
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler { [weak self] in try? self?.reload() }
            timer = source
            source.resume()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        timer?.cancel()
        timer = nil
        completionHandler()
    }

    private func reload() throws {
        guard let rulesURL else { throw CocoaError(.fileNoSuchFile) }
        let date = try rulesURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard modified == nil || date != modified else { return }
        let next = try BlockingConfiguration.load(from: rulesURL)
        lock.lock()
        configuration = next
        lock.unlock()
        modified = date
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
