import XCTest
import BrowserCore
@testable import BrowserDaddy

final class BlockingControllerTests: XCTestCase {
    @MainActor
    func testSaveDuringInitialRefreshStillAppliesRulesAndIgnoresStaleReply() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let initial = BlockingConfiguration()
        try initial.save(to: file)
        let preferences = MemoryBlockingPreferences(payload: try initial.providerData(), holdFirstLoad: true)
        defer { preferences.releaseFirstLoad() }
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true)
        for _ in 0..<1000 where preferences.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(preferences.pending)
        XCTAssertTrue(controller.ready)
        var changed = controller.configuration
        changed.strictUnknownDestinations = true
        controller.save(changed)
        for _ in 0..<1000 where preferences.savedPayload == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(try BlockingConfiguration.load(from: file), changed)
        XCTAssertEqual(try BlockingConfiguration.decode(XCTUnwrap(preferences.savedPayload)), changed)
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
        let controller = BlockingController(rulesURL: file, preview: false, preferences: preferences, extensionAvailable: true)
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
    private var holdFirstLoad: Bool

    init(payload: Data, holdFirstLoad: Bool) {
        state = BlockingFilterState(enabled: true, payload: payload)
        self.holdFirstLoad = holdFirstLoad
    }

    func load() async throws -> BlockingFilterState {
        if holdFirstLoad {
            holdFirstLoad = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return state
    }

    func save(enabled: Bool, payload: Data?) async throws {
        savedPayload = payload
        state = BlockingFilterState(enabled: enabled, payload: payload ?? state.payload)
    }

    func releaseFirstLoad() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: BlockingFilterState(enabled: false, payload: nil))
    }
}
