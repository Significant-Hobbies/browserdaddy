import Foundation
import NetworkExtension

final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var policy = BlockingPolicy()
    private var running = false
    private var scheduledFlows = ScheduledFlowRegistry<NEFilterSocketFlow>()
    private var configurationObservation: NSKeyValueObservation?
    private let rulesQueue = DispatchQueue(label: "BrowserDaddy.filter.configuration")
    private var scheduleTimer: DispatchSourceTimer?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        configurationObservation = observe(\.filterConfiguration, options: [.new]) { [weak self] _, _ in
            self?.rulesQueue.async { [weak self] in self?.reload() }
        }
        rulesQueue.sync {
            lock.lock()
            running = true
            lock.unlock()
            reload()
            let timer = DispatchSource.makeTimerSource(queue: rulesQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.reevaluateScheduledFlows() }
            scheduleTimer = timer
            timer.resume()
        }
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        configurationObservation = nil
        lock.lock()
        running = false
        policy = BlockingPolicy()
        scheduledFlows.removeAll()
        lock.unlock()
        rulesQueue.async { [weak self] in
            self?.scheduleTimer?.cancel()
            self?.scheduleTimer = nil
            completionHandler()
        }
    }

    private func reload() {
        let next = BlockingPolicy(vendorConfiguration: filterConfiguration.vendorConfiguration)
        lock.lock()
        guard running else { lock.unlock(); return }
        policy = next
        lock.unlock()
        reevaluateScheduledFlows()
    }

    private func reevaluateScheduledFlows() {
        let now = Date()
        lock.lock()
        guard running, scheduledFlows.count > 0 else { lock.unlock(); return }
        let snapshot = scheduledFlows
        let currentPolicy = policy
        lock.unlock()
        let blocked = snapshot.blockedIDs(by: currentPolicy, at: now)
        lock.lock()
        guard running else { lock.unlock(); return }
        let dropped = scheduledFlows.takeBlocked(ids: blocked)
        lock.unlock()
        for flow in dropped { update(flow, using: .drop(), for: .any) }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        let host = flow.url?.host ?? (flow as? NEFilterSocketFlow)?.remoteHostname
        lock.lock()
        defer { lock.unlock() }
        guard running else { return .drop() }
        if policy.blocks(hostname: host, outgoing: flow.direction == .outbound) { return .drop() }
        guard policy.hasSchedule(hostname: host) else { return .allow() }
        guard let socket = flow as? NEFilterSocketFlow, let host else { return .drop() }
        guard scheduledFlows.insert(socket, id: socket.identifier, hostname: host) else { return .drop() }
        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let flow = report.flow else { return }
        lock.lock()
        scheduledFlows.remove(id: flow.identifier)
        lock.unlock()
    }
}
