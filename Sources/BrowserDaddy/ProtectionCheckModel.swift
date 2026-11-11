import BrowserCore
import Combine
import Foundation
import Network

@MainActor
final class ProtectionCheckModel: ObservableObject {
    enum State: Equatable {
        case idle, running, finished(ProtectionCheckReport), cancelled, stale
    }

    @Published private(set) var state = State.idle
    @Published private(set) var observations: [ProtectionCheckTarget: ProbeObservation] = [:]
    private let prober: any ProtectionProbing
    private let deadline: Duration
    private let networkAllowed: Bool
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var receivedInitialPath = false

    init(prober: any ProtectionProbing = HTTPSProtectionProbe(), deadline: Duration = .seconds(8),
         networkAllowed: Bool? = nil) {
        self.prober = prober
        self.deadline = deadline
        self.networkAllowed = networkAllowed ?? !(CommandLine.arguments.contains("--preview-fixture")
            || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true)
    }

    var isRunning: Bool { state == .running }

    func start(configuration: BlockingConfiguration, eligible: Bool) {
        guard eligible, networkAllowed, !isRunning else { return }
        generation &+= 1
        let generation = generation
        let controlBlocked = configuration.blocks(hostname: ProtectionCheckTarget.allowed.rawValue, outgoing: true)
        let prober = prober
        let deadline = deadline
        observations = [:]
        state = .running
        task = Task { [weak self] in
            await withTaskGroup(of: Event.self) { group in
                for target in ProtectionCheckTarget.allCases {
                    group.addTask { .observation(target, await prober.probe(target)) }
                }
                group.addTask {
                    do { try await Task.sleep(for: deadline) }
                    catch { return .cancelled }
                    return .deadline
                }
                var results: [ProtectionCheckTarget: ProbeObservation] = [:]
                for await event in group {
                    guard !Task.isCancelled, let self, self.generation == generation else { group.cancelAll(); break }
                    switch event {
                    case .observation(let target, let observation): results[target] = observation
                    case .deadline:
                        for target in ProtectionCheckTarget.allCases where results[target] == nil { results[target] = .timeout }
                    case .cancelled: break
                    }
                    self.observations = results
                    if results.count == ProtectionCheckTarget.allCases.count {
                        group.cancelAll()
                        self.state = .finished(ProtectionCheckReport(checkedAt: Date(), observations: results,
                                                                    controlBlockedByRules: controlBlocked))
                        self.task = nil
                        break
                    }
                }
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        stop()
        state = .cancelled
    }

    func invalidate() {
        let hasCheck = state != .idle
        stop()
        if hasCheck { state = .stale }
    }

    private func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        observations = [:]
    }

    func startObservingNetwork() {
        guard monitor == nil else { return }
        invalidate()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        receivedInitialPath = false
        monitor.pathUpdateHandler = { [weak self, weak monitor] _ in
            Task { @MainActor [weak self] in
                guard let self, let monitor, self.monitor === monitor else { return }
                if self.receivedInitialPath { self.invalidate() }
                self.receivedInitialPath = true
            }
        }
        monitor.start(queue: DispatchQueue(label: "BrowserDaddy.protection-check.network"))
    }

    func stopObservingNetwork() {
        monitor?.cancel()
        monitor = nil
        receivedInitialPath = false
        invalidate()
    }

    private enum Event: Sendable {
        case observation(ProtectionCheckTarget, ProbeObservation), deadline, cancelled
    }
}
