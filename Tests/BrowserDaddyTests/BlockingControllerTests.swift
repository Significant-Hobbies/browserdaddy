import XCTest
import BrowserCore
import NetworkExtension
import SystemExtensions
@testable import BrowserDaddy

final class BlockingControllerTests: XCTestCase {
    private static let listRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/BrowserDaddy/Resources/BlockingLists")
    private static let catalog = BlockingListCatalog { category in
        try Data(contentsOf: listRoot.appendingPathComponent(category == .adult ? "Adult.txt" : "Gambling.txt"))
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<30000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for controller", file: file, line: line)
    }

    private func rulesFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("rules.json")
    }

    @MainActor
    func testMigrationPreservesLocalAndLegacyNativeActiveExtrasAndRawMismatch() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var local = BlockingConfiguration()
        local.sites = [BlockingHostname("local.test")!]
        try local.save(to: file)
        let original = try Data(contentsOf: file)
        var native = BlockingConfiguration()
        native.sites = [BlockingHostname("native.test")!]
        native.categories = [.adult]
        native.lists[.adult] = [BlockingHostname("active-custom.test")!]
        native.lists[.gambling] = [BlockingHostname("inactive-custom.test")!]
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: nil, legacyPayload: try native.localData()))
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { controller.ready && !controller.busy && controller.status.contains("differ") }
        for name in ["local.test", "native.test", "active-custom.test", "youtube.com"] {
            XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname(name)!))
        }
        XCTAssertFalse(controller.configuration.sites.contains(BlockingHostname("inactive-custom.test")!))
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-commitment")), original)
        XCTAssertEqual(preferences.applyCount, 0)
        controller.enable()
        try await waitUntil { preferences.applyCount == 1 && !controller.busy }
        let applied = try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.state.payload), catalog: Self.catalog)
        XCTAssertEqual(applied, controller.configuration)
        XCTAssertTrue(preferences.state.enabled)
    }

    @MainActor
    func testFirstApplyActivatesBeforeDeliveryThenAddReusesActivationAndPreservesNativeOnlySite() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let initial = try CommittedBlockingRules(catalog: Self.catalog)
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: try initial.providerPayload().data))
        var complete: (@MainActor () -> Void)?
        var activations = 0
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { activations += 1; complete = $0 })
        try await waitUntil { controller.ready && !controller.busy }
        controller.enable()
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(controller.busy)
        XCTAssertEqual(preferences.applyCount, 0)
        complete?()
        try await waitUntil { preferences.applyCount == 1 && !controller.busy }
        let nativeOnly = try initial.addingSite(BlockingHostname("native-only.test")!)
        preferences.state = BlockingFilterState(enabled: true, payload: try nativeOnly.providerPayload().data)
        XCTAssertTrue(controller.addSite("added.test"))
        try await waitUntil { preferences.applyCount == 2 && !controller.busy }
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname("native-only.test")!))
        XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname("added.test")!))
        XCTAssertEqual(try BlockingConfiguration.load(from: file), controller.configuration)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.state.payload), catalog: Self.catalog), controller.configuration)
    }

    @MainActor
    func testPendingApprovalCannotDeliverUntilActivationCompletes() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = MemoryBlockingPreferences()
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { _ in })
        try await waitUntil { controller.ready && !controller.busy }
        controller.enable()
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
        controller.requestNeedsUserApproval(request)
        try await waitUntil { !controller.busy }
        controller.enable()
        XCTAssertEqual(preferences.applyCount, 0)
        controller.request(request, didFinishWithResult: .completed)
        try await waitUntil { preferences.applyCount == 1 && !controller.busy }
        XCTAssertTrue(preferences.state.enabled)
    }

    @MainActor
    func testFailedActivationAndSaveDoNotRetryButKeepRequestedAdditions() async throws {
        for failActivation in [true, false] {
            let file = try rulesFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: try BlockingConfiguration().providerData()))
            if !failActivation { preferences.applyFailure = CocoaError(.fileWriteNoPermission) }
            var attempts = 0
            var controller: BlockingController!
            controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
                extensionAvailable: true, extensionActivation: { complete in
                    attempts += 1
                    if failActivation {
                        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: BlockingConfiguration.extensionID, queue: .main)
                        controller.request(request, didFailWithError: CocoaError(.fileReadUnknown))
                    } else { complete() }
                })
            try await waitUntil { controller.ready && !controller.busy }
            XCTAssertTrue(controller.addSite("retained.test"))
            try await waitUntil { attempts == 1 && !controller.busy && controller.error.contains("not updated") }
            for _ in 0..<100 { await Task.yield() }
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(preferences.applyCount, failActivation ? 0 : 1)
            XCTAssertTrue(try BlockingConfiguration.load(from: file).sites.contains(BlockingHostname("retained.test")!))
        }
    }

    @MainActor
    func testNewerRefreshAndAddIgnoreStalePreferenceReply() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: try BlockingConfiguration().providerData()))
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { controller.ready && !controller.busy }
        preferences.holdNextLoad = true
        controller.refresh()
        try await waitUntil { preferences.pending != nil }
        XCTAssertTrue(controller.addSite("newer.test"))
        controller.refresh()
        try await waitUntil { preferences.applyCount == 1 && !controller.busy }
        preferences.releaseLoad(BlockingFilterState(enabled: false, payload: nil))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(controller.enabled)
        XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname("newer.test")!))
        XCTAssertEqual(preferences.applyCount, 1)
    }

    @MainActor
    func testUnreadablePreferencesOrCorruptLocalDataNeverReplaceSavedBytes() async throws {
        for corruptLocal in [true, false] {
            let file = try rulesFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let original = corruptLocal ? Data("corrupt".utf8) : try BlockingConfiguration().localData()
            try original.write(to: file)
            let preferences = MemoryBlockingPreferences()
            if !corruptLocal { preferences.loadFailure = CocoaError(.fileReadNoPermission) }
            let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
                extensionAvailable: true, extensionActivation: { $0() })
            try await waitUntil { !controller.busy }
            XCTAssertFalse(controller.ready)
            XCTAssertFalse(controller.loadError.isEmpty)
            XCTAssertFalse(controller.addSite("example.com"))
            controller.enable()
            XCTAssertEqual(preferences.applyCount, 0)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("pre-commitment").path))
        }
    }

    @MainActor
    func testBadPresentNativeRulesArePreservedBeforeProtectedRepairWithoutLegacyFallback() async throws {
        var legacy = BlockingConfiguration()
        legacy.sites = [BlockingHostname("stale-legacy.test")!]
        let wrongTypeArchive = try PropertyListSerialization.data(fromPropertyList: [
            BlockingConfiguration.providerRulesKey: 17,
            BlockingConfiguration.legacyProviderRulesKey: try legacy.localData()
        ], format: .binary, options: 0)
        for state in [
            BlockingFilterState(enabled: true, payload: Data("bad".utf8), legacyPayload: try legacy.localData()),
            BlockingFilterState(enabled: true, payload: nil, legacyPayload: try legacy.localData(), currentRulesPresent: true),
            BlockingFilterState(enabled: true, payload: nil, legacyRulesPresent: true),
            BlockingFilterState(enabled: true, payload: nil, legacyPayload: try legacy.localData(), currentRulesPresent: true,
                nativeConfigurationData: wrongTypeArchive)
        ] {
            let file = try rulesFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            var local = BlockingConfiguration()
            local.sites = [BlockingHostname("local.test")!]
            let original = try local.localData()
            try original.write(to: file)
            let preferences = MemoryBlockingPreferences(state: state)
            let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
                extensionAvailable: true, extensionActivation: { $0() })
            try await waitUntil { !controller.busy }
            XCTAssertTrue(controller.ready)
            guard controller.ready else { continue }
            XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname("local.test")!))
            XCTAssertFalse(controller.configuration.sites.contains(BlockingHostname("stale-legacy.test")!))
            XCTAssertTrue(controller.error.contains("could not be recovered"))
            let backups = try nativeRecoveryCopies(for: file)
            XCTAssertEqual(backups.count, 1)
            let archive = try XCTUnwrap(backups.first)
            if let nativeConfigurationData = state.nativeConfigurationData {
                XCTAssertEqual(try Data(contentsOf: archive), nativeConfigurationData)
            }
            let recovered = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: archive), format: nil) as? [String: Any])
            XCTAssertEqual(recovered[BlockingConfiguration.providerRulesKey] as? Data, state.payload)
            XCTAssertEqual(recovered[BlockingConfiguration.legacyProviderRulesKey] as? Data, state.legacyPayload)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            preferences.beforeApply = { XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path)) }
            let closed = BlockingPolicy(vendorConfiguration: [BlockingConfiguration.providerRulesKey: state.payload as Any,
                BlockingConfiguration.legacyProviderRulesKey: try legacy.localData()], catalog: Self.catalog)
            XCTAssertTrue(closed.blocks(hostname: "unlisted.test", outgoing: true))
            controller.enable()
            try await waitUntil { preferences.applyCount == 1 && !controller.busy }
            let repaired = try BlockingPolicy(data: XCTUnwrap(preferences.state.payload), catalog: Self.catalog)
            XCTAssertFalse(repaired.blocks(hostname: "unlisted.test", outgoing: true))
            XCTAssertTrue(repaired.blocks(hostname: "local.test", outgoing: true))
            XCTAssertTrue(repaired.blocks(hostname: "youtube.com", outgoing: true))
            XCTAssertTrue(repaired.blocks(hostname: nil, outgoing: true))
            XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("pre-commitment")), original)
        }
    }

    private func nativeRecoveryCopies(for file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: file.appendingPathExtension("native-recovery"), includingPropertiesForKeys: nil)
    }

    @MainActor
    func testStaleV2PreservesExplicitAndActiveInlineExtrasAndRepairsWithVerifiedFloor() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var native = try CommittedBlockingRules(catalog: Self.catalog).configuration
        native.sites = [BlockingHostname("native-only.test")!]
        native.lists[.gambling] = [BlockingHostname("inline-extra.test")!]
        let raw = Data(String(decoding: try native.providerData(), as: UTF8.self)
            .replacingOccurrences(of: "4eb9d0d020d546521c4d90485d7c423f6fbb1336e880d003fd08dcce5c7675d3", with: String(repeating: "0", count: 64)).utf8)
        XCTAssertThrowsError(try BlockingConfiguration.decodeProvider(raw, catalog: Self.catalog))
        let closed = BlockingPolicy(committedProviderData: raw, catalog: Self.catalog)
        XCTAssertTrue(closed.blocks(hostname: "unlisted.test", outgoing: true))
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: raw))
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.ready)
        guard controller.ready else { return }
        for host in ["native-only.test", "inline-extra.test", "youtube.com"] {
            XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname(host)!))
        }
        let recovery = try XCTUnwrap(nativeRecoveryCopies(for: file).first)
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: recovery), format: nil) as? [String: Any])
        XCTAssertEqual(archive[BlockingConfiguration.providerRulesKey] as? Data, raw)
        XCTAssertEqual(preferences.applyCount, 0)
        controller.enable()
        try await waitUntil { preferences.applyCount == 1 && !controller.busy }
        let applied = try BlockingConfiguration.decodeProvider(XCTUnwrap(preferences.state.payload), catalog: Self.catalog)
        XCTAssertEqual(applied, controller.configuration)
        XCTAssertTrue(applied.blocks(hostname: "inline-extra.test", outgoing: true))
        XCTAssertTrue(applied.blocks(hostname: "native-only.test", outgoing: true))
        XCTAssertTrue(applied.strictUnknownDestinations)
    }

    @MainActor
    func testNativeRecoveryWriteFailurePreventsLocalMigrationAndNativeOverwrite() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = try BlockingConfiguration().localData()
        try original.write(to: file)
        try Data("not a directory".utf8).write(to: file.appendingPathExtension("native-recovery"))
        let raw = Data("bad-native".utf8)
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: raw))
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { !controller.busy }
        XCTAssertFalse(controller.ready)
        controller.enable()
        XCTAssertEqual(preferences.applyCount, 0)
        XCTAssertEqual(preferences.state.payload, raw)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("pre-commitment").path))
    }

    @MainActor
    func testNativeRecoveryFailureDuringAddAndApplyPreservesReadyStores() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = MemoryBlockingPreferences()
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { controller.ready && !controller.busy }
        let original = try Data(contentsOf: file)
        let raw = Data("malformed current native rules".utf8)
        preferences.state = BlockingFilterState(enabled: true, payload: raw)
        try Data("not a directory".utf8).write(to: file.appendingPathExtension("native-recovery"))
        XCTAssertTrue(controller.addSite("unsaved.test"))
        try await waitUntil { !controller.busy && controller.error.contains("not saved") }
        controller.enable()
        try await waitUntil { !controller.busy && controller.error.contains("not updated") }
        XCTAssertEqual(preferences.applyCount, 0)
        XCTAssertEqual(preferences.state.payload, raw)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(controller.configuration.sites.contains(BlockingHostname("unsaved.test")!))
    }

    @MainActor
    func testRefreshRetriesInitialNativeReadBeforeLocalMigration() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let original = try BlockingConfiguration().localData()
        try original.write(to: file)
        var native = BlockingConfiguration()
        native.sites = [BlockingHostname("native-retry.test")!]
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: try native.providerData()))
        preferences.loadFailure = CocoaError(.fileReadNoPermission)
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { !controller.busy }
        XCTAssertFalse(controller.ready)
        XCTAssertEqual(try Data(contentsOf: file), original)
        preferences.loadFailure = nil
        preferences.holdNextLoad = true
        controller.refresh()
        try await waitUntil { preferences.pending != nil }
        XCTAssertEqual(try Data(contentsOf: file), original)
        preferences.releaseLoad(preferences.state)
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.ready)
        XCTAssertTrue(controller.configuration.sites.contains(BlockingHostname("native-retry.test")!))
        XCTAssertEqual(preferences.applyCount, 0)
    }

    @MainActor
    func testExtensionlessLoadsAndAddsLocalRulesWithoutPrivilegedPreferences() async throws {
        for preview in [false, true] {
            let file = try rulesFile()
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            let preferences = MemoryBlockingPreferences()
            preferences.loadFailure = CocoaError(.fileReadNoPermission)
            let controller = BlockingController(rulesURL: file, preview: preview, preferences: preferences, extensionAvailable: preview)
            try await waitUntil { !controller.busy }
            XCTAssertTrue(controller.ready)
            guard controller.ready else { continue }
            XCTAssertTrue(controller.addSite("local-only.test"))
            try await waitUntil { !controller.busy }
            controller.refresh()
            XCTAssertEqual(preferences.loadCount, 0)
            XCTAssertEqual(preferences.applyCount, 0)
            XCTAssertTrue(try BlockingConfiguration.load(from: file).sites.contains(BlockingHostname("local-only.test")!))
        }
    }

    @MainActor
    func testOversizeLocalMigrationLeavesOriginalAndNoBackup() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var legacy = BlockingConfiguration()
        legacy.categories = [.adult]
        legacy.lists[.adult] = Set((0..<20000).map { BlockingHostname("large-\($0).test")! })
        try legacy.save(to: file)
        let original = try Data(contentsOf: file)
        let preferences = MemoryBlockingPreferences()
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { !controller.busy }
        XCTAssertFalse(controller.ready)
        XCTAssertTrue(controller.loadError.contains("macOS filter limit"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("pre-commitment").path))
        XCTAssertEqual(preferences.applyCount, 0)
    }

    @MainActor
    func testPreferenceReadFailureDuringAddAndApplyPreservesBothStores() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: try BlockingConfiguration().providerData()))
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { controller.ready && !controller.busy }
        let original = try Data(contentsOf: file)
        let native = preferences.state.payload
        preferences.loadFailure = CocoaError(.fileReadNoPermission)
        XCTAssertTrue(controller.addSite("unwritten.test"))
        try await waitUntil { !controller.busy && controller.error.contains("not saved") }
        controller.enable()
        try await waitUntil { !controller.busy && controller.error.contains("not updated") }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(preferences.state.payload, native)
        XCTAssertEqual(preferences.applyCount, 0)
    }

    @MainActor
    func testOversizeNativeAdditionsRejectAddBeforeLocalOrNativeMutation() async throws {
        let file = try rulesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = MemoryBlockingPreferences(state: BlockingFilterState(enabled: true, payload: try BlockingConfiguration().providerData()))
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences,
            extensionAvailable: true, extensionActivation: { $0() })
        try await waitUntil { controller.ready && !controller.busy }
        let original = try Data(contentsOf: file)
        var large = BlockingConfiguration()
        large.sites = Set((0..<20000).map { BlockingHostname("large-\($0).test")! })
        let native = try large.localData()
        preferences.state = BlockingFilterState(enabled: true, payload: nil, legacyPayload: native)
        XCTAssertTrue(controller.addSite("added.test"))
        try await waitUntil { !controller.busy && !controller.error.isEmpty }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(preferences.state.legacyPayload, native)
        XCTAssertEqual(preferences.applyCount, 0)
        XCTAssertFalse(controller.configuration.sites.contains(BlockingHostname("added.test")!))
        XCTAssertTrue(controller.error.contains("macOS filter limit"))
    }

    func testNativeSecureArchiveFitsProtectedFloorWithCustomCategoryAddition() throws {
        var legacy = BlockingConfiguration()
        legacy.categories = [.adult]
        legacy.lists[.adult] = [BlockingHostname("custom-adult.test")!]
        let rules = try CommittedBlockingRules(preserving: [legacy], catalog: Self.catalog)
            .addingSite(BlockingHostname("added.test")!)
        let config = NEFilterProviderConfiguration()
        config.vendorConfiguration = [BlockingConfiguration.providerRulesKey: try rules.providerPayload().data]
        config.filterBrowsers = true
        config.filterSockets = true
        config.filterDataProviderBundleIdentifier = BlockingConfiguration.extensionID
        let archive = try NSKeyedArchiver.archivedData(withRootObject: config, requiringSecureCoding: true)
        XCTAssertLessThan(archive.count, 480 * 1024)
        print("Native protected NEFilterProviderConfiguration secure archive \(archive.count) bytes")
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

}

@MainActor
private final class MemoryBlockingPreferences: BlockingPreferences {
    var state: BlockingFilterState
    var pending: CheckedContinuation<BlockingFilterState, Error>?
    var applyFailure: Error?
    var loadFailure: Error?
    var applyCount = 0
    var holdNextLoad = false
    var loadCount = 0
    var beforeApply: (() -> Void)?

    init(state: BlockingFilterState = BlockingFilterState(enabled: false, payload: nil)) { self.state = state }

    func load() async throws -> BlockingFilterState {
        loadCount += 1
        if let loadFailure { throw loadFailure }
        if holdNextLoad {
            holdNextLoad = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return state
    }

    func apply(_ payload: CommittedBlockingPayload) async throws {
        beforeApply?()
        applyCount += 1
        if let applyFailure { throw applyFailure }
        state = BlockingFilterState(enabled: true, payload: payload.data)
    }

    func releaseLoad(_ state: BlockingFilterState) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: state)
    }
}
