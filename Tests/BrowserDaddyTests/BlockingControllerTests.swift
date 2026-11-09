import XCTest
import BrowserCore
import NetworkExtension
import SystemExtensions
@testable import BrowserDaddy

final class BlockingControllerTests: XCTestCase {
    @MainActor
    func testFailedActivationDoesNotRetryPendingRuleDelivery() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData())
        var failActivation: (() -> Void)?
        var attempts = 0
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { _ in
                attempts += 1
                if attempts == 1 { failActivation?() }
            })
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
        failActivation = { controller.request(request, didFailWithError: CocoaError(.fileReadUnknown)) }
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        var changed = initial
        changed.strictUnknownDestinations = true
        controller.save(changed)
        for _ in 0..<1000 where attempts == 0 { try await Task.sleep(for: .milliseconds(1)) }
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(preferences.saveCount, 0)
        XCTAssertTrue(controller.error.contains("not updated"))
    }

    @MainActor
    func testDisableDuringApprovalStaysOffAfterActivationCompletes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData())
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { _ in })
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        controller.setEnabled(true)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
        controller.requestNeedsUserApproval(request)
        for _ in 0..<1000 where controller.busy { try await Task.sleep(for: .milliseconds(1)) }
        controller.setEnabled(false)
        for _ in 0..<1000 where controller.busy || preferences.saveCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(preferences.state.enabled)
        controller.request(request, didFinishWithResult: .completed)
        for _ in 0..<100 { await Task.yield() }
        XCTAssertFalse(preferences.state.enabled)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(preferences.saveCount, 1)
    }

    @MainActor
    func testLegacyOversizeCustomRulesRemainEditableAndCanBeDisabled() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        var initial = BlockingConfiguration()
        initial.categories = [.adult]
        initial.lists[.adult] = Set((0..<20000).map { BlockingHostname("custom-\($0).test")! })
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try BlockingConfiguration().providerData())
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        for _ in 0..<5000 where controller.busy || !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(controller.ready)
        XCTAssertTrue(controller.loadError.isEmpty)
        XCTAssertEqual(controller.configuration, initial)
        controller.setEnabled(true)
        XCTAssertEqual(preferences.saveCount, 0)
        XCTAssertTrue(controller.error.contains("cannot be applied"))
        var changed = initial
        changed.categories = []
        controller.save(changed)
        for _ in 0..<5000 where controller.busy || preferences.saveCount == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(preferences.saveCount, 1)
        XCTAssertEqual(try BlockingConfiguration.load(from: file), changed)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.savedPayload)), changed.activeConfiguration)
        XCTAssertEqual(controller.status, "Filter configured · runtime unverified")
    }

    @MainActor
    func testFirstEnableReplacesExtensionBeforeSavingAndRuleEditsReuseActivation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData())
        var completeActivation: (@MainActor () -> Void)?
        var activations = 0
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { completion in
                activations += 1
                completeActivation = completion
            })
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        controller.setEnabled(true)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(preferences.saveCount, 0)
        XCTAssertTrue(controller.busy)
        completeActivation?()
        for _ in 0..<1000 where preferences.saveCount == 0 || controller.busy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(preferences.saveCount, 1)
        var changed = initial
        changed.strictUnknownDestinations = true
        controller.save(changed)
        for _ in 0..<1000 where preferences.saveCount < 2 || controller.busy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(preferences.saveCount, 2)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.savedPayload)), changed)
    }

    @MainActor
    func testOversizeCustomEditPreservesLocalFileAndNativePreferences() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let original = try Data(contentsOf: file)
        let payload = try initial.providerData()
        let preferences = MemoryBlockingPreferences(payload: payload)
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true, extensionActivation: { $0() })
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        var changed = initial
        changed.categories = [.adult]
        changed.lists[.adult] = Set((0..<20000).map { BlockingHostname("custom-\($0).test")! })
        controller.save(changed)
        for _ in 0..<5000 where controller.busy { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.configuration, initial)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(preferences.state.payload, payload)
        XCTAssertEqual(preferences.saveCount, 0)
        XCTAssertTrue(controller.error.contains("macOS filter limit"))
    }

    func testNativeSecureArchiveFitsCompletePinnedSelection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BrowserDaddy/Resources/BlockingLists")
        var rules = BlockingConfiguration()
        rules.categories = [.adult, .gambling]
        rules.strictUnknownDestinations = true
        rules.sites = Set(["youtube.com", "youtu.be", "youtube-nocookie.com", "reddit.com", "redd.it", "instagram.com"].map { BlockingHostname($0)! })
        for category in BlockingCategory.allCases {
            let name = category == .adult ? "Adult" : "Gambling"
            rules.lists[category] = try BlockingConfiguration.parseList(String(contentsOf: root.appendingPathComponent(name + ".txt"), encoding: .utf8))
        }
        let config = NEFilterProviderConfiguration()
        config.vendorConfiguration = [BlockingConfiguration.providerRulesKey: try rules.providerData()]
        config.filterBrowsers = true
        config.filterSockets = true
        config.filterDataProviderBundleIdentifier = BlockingConfiguration.extensionID
        let archive = try NSKeyedArchiver.archivedData(withRootObject: config, requiringSecureCoding: true)
        XCTAssertLessThan(archive.count, 480 * 1024)
        print("Native NEFilterProviderConfiguration secure archive \(archive.count) bytes")
    }

    @MainActor
    func testNewerRefreshCannotDiscardPendingRuleDelivery() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData(), holdLoadNumber: 2)
        defer { preferences.releaseFirstLoad() }
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true, extensionActivation: { $0() })
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        var changed = initial
        changed.strictUnknownDestinations = true
        controller.save(changed)
        for _ in 0..<1000 where preferences.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(preferences.pending)
        controller.refresh()
        for _ in 0..<1000 where preferences.savedPayload == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.savedPayload)), changed)
        preferences.releaseFirstLoad()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(controller.enabled)
    }

    @MainActor
    func testFailedPreferenceSaveRetainsLocalRulesWithoutRetryLoop() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData())
        preferences.saveFailure = CocoaError(.fileWriteNoPermission)
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true, extensionActivation: { $0() })
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        var changed = initial
        changed.strictUnknownDestinations = true
        controller.save(changed)
        for _ in 0..<1000 where preferences.saveCount == 0 || controller.busy { try await Task.sleep(for: .milliseconds(1)) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(preferences.saveCount, 1)
        XCTAssertEqual(try BlockingConfiguration.load(from: file), changed)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.state.payload)), initial)
        XCTAssertTrue(controller.error.contains("not updated"))
    }

    @MainActor
    func testPreferenceQueueOrdersOperationsAndRecoversAfterFailure() async throws {
        let queue = BlockingPreferenceQueue()
        var gate: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let first = Task {
            try await queue.run {
                events.append("load started")
                await withCheckedContinuation { gate = $0 }
                throw CocoaError(.fileReadNoPermission)
            } as Void
        }
        for _ in 0..<1000 where gate == nil { try await Task.sleep(for: .milliseconds(1)) }
        let second = Task { try await queue.run { events.append("save completed"); return 7 } }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(events, ["load started"])
        gate?.resume()
        _ = try? await first.value
        let result = try await second.value
        XCTAssertEqual(result, 7)
        XCTAssertEqual(events, ["load started", "save completed"])
    }

    @MainActor
    func testSaveDuringInitialRefreshStillAppliesRulesAndIgnoresStaleReply() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData(), holdFirstLoad: true)
        defer { preferences.releaseFirstLoad() }
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true, extensionActivation: { $0() })
        for _ in 0..<1000 where preferences.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(preferences.pending)
        XCTAssertTrue(controller.ready)
        var changed = controller.configuration
        changed.strictUnknownDestinations = true
        controller.save(changed)
        for _ in 0..<1000 where preferences.savedPayload == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(try BlockingConfiguration.load(from: file), changed)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.savedPayload)), changed)
        preferences.releaseFirstLoad()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(controller.enabled)
        XCTAssertFalse(controller.busy)
    }

    @MainActor
    func testCorruptLocalRulesCannotPreventDisablingAnExistingFilter() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let original = Data("corrupt".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = try BlockingConfiguration().providerData()
        let preferences = MemoryBlockingPreferences(payload: payload, holdFirstLoad: false)
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true, extensionActivation: { $0() })
        for _ in 0..<1000 where !controller.enabled { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(controller.ready)
        XCTAssertTrue(controller.enabled)
        controller.setEnabled(false)
        for _ in 0..<1000 where preferences.state.enabled { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(preferences.state.enabled)
        XCTAssertEqual(preferences.state.payload, payload)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testFailedLoadCannotOverwriteTheSavedRules() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let original = Data("unreadable rules retained for recovery".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = BlockingController(rulesURL: file, preview: true)
        for _ in 0..<1000 where controller.busy {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.ready)
        XCTAssertFalse(controller.error.isEmpty)
        XCTAssertFalse(controller.addSite("example.com"))
        controller.save(BlockingConfiguration())
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}

@MainActor
private final class MemoryBlockingPreferences: BlockingPreferences {
    var state: BlockingFilterState
    var savedPayload: Data?
    var pending: CheckedContinuation<BlockingFilterState, Error>?
    var saveFailure: Error?
    var saveCount = 0
    private let heldLoad: Int?
    private var loadCount = 0

    init(payload: Data, holdFirstLoad: Bool = false, holdLoadNumber: Int? = nil) {
        state = BlockingFilterState(enabled: true, payload: payload)
        heldLoad = holdLoadNumber ?? (holdFirstLoad ? 1 : nil)
    }

    func load() async throws -> BlockingFilterState {
        loadCount += 1
        if let heldLoad, loadCount == heldLoad {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return state
    }

    func save(enabled: Bool, payload: Data?) async throws {
        saveCount += 1
        if let saveFailure { throw saveFailure }
        savedPayload = payload
        state = BlockingFilterState(enabled: enabled, payload: payload ?? state.payload)
    }

    func releaseFirstLoad() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: BlockingFilterState(enabled: false, payload: nil))
    }
}
