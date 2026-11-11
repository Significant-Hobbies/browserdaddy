import XCTest
@testable import BrowserCore

final class ScheduledSiteBlockTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func schedule(_ days: Set<Int> = [2], _ start: Int = 9 * 60, _ end: Int = 17 * 60,
                          host: String = "example.com") -> ScheduledSiteBlock {
        ScheduledSiteBlock(hostname: BlockingHostname(host)!, weekdays: days, startMinute: start, endMinute: end)!
    }
    private static let catalog = BlockingListCatalog { category in
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/BrowserDaddy/Resources/BlockingLists")
        return try Data(contentsOf: root.appendingPathComponent(category == .adult ? "Adult.txt" : "Gambling.txt"))
    }

    func testHalfOpenSameDayAndDNSBoundaries() {
        let value = schedule()
        for (time, active) in [("08:59", false), ("09:00", true), ("16:59", true), ("17:00", false)] {
            XCTAssertEqual(value.isActive(at: date("2026-11-09T\(time):00Z"), timeZone: utc), active)
        }
        XCTAssertFalse(value.isActive(at: date("2026-11-10T09:00:00Z"), timeZone: utc))
        XCTAssertTrue(value.matches(hostname: "A.Example.com."))
        XCTAssertFalse(value.matches(hostname: "badexample.com"))
        XCTAssertFalse(value.matches(hostname: "example.com.evil.test"))
    }

    func testOvernightWeekWrapAndMidnightEnd() {
        let overnight = schedule([7], 22 * 60, 2 * 60)
        XCTAssertTrue(overnight.isActive(at: date("2026-11-07T22:00:00Z"), timeZone: utc))
        XCTAssertTrue(overnight.isActive(at: date("2026-11-08T01:59:00Z"), timeZone: utc))
        XCTAssertFalse(overnight.isActive(at: date("2026-11-08T02:00:00Z"), timeZone: utc))
        XCTAssertFalse(overnight.isActive(at: date("2026-11-09T01:00:00Z"), timeZone: utc))
        let midnight = schedule([7], 22 * 60, 0)
        XCTAssertTrue(midnight.isActive(at: date("2026-11-07T23:59:00Z"), timeZone: utc))
        XCTAssertFalse(midnight.isActive(at: date("2026-11-08T00:00:00Z"), timeZone: utc))
    }

    func testLocalWallClockDSTFoldGapAndTimeZone() {
        let ny = TimeZone(identifier: "America/New_York")!
        let fold = schedule([1], 90, 105)
        XCTAssertTrue(fold.isActive(at: date("2026-11-01T05:35:00Z"), timeZone: ny))
        XCTAssertTrue(fold.isActive(at: date("2026-11-01T06:35:00Z"), timeZone: ny))
        XCTAssertFalse(fold.isActive(at: date("2026-11-01T06:45:00Z"), timeZone: ny))
        let gap = schedule([1], 120, 180)
        XCTAssertFalse(gap.isActive(at: date("2026-03-08T06:59:00Z"), timeZone: ny))
        XCTAssertFalse(gap.isActive(at: date("2026-03-08T07:00:00Z"), timeZone: ny))
        XCTAssertTrue(schedule().isActive(at: date("2026-11-09T14:00:00Z"), timeZone: ny))
        XCTAssertFalse(schedule().isActive(at: date("2026-11-09T14:00:00Z"), timeZone: TimeZone(identifier: "Asia/Kolkata")!))
    }

    func testValidationRejectsInvalidWindowsAndSerializedValues() throws {
        let host = BlockingHostname("example.com")!
        for (days, start, end) in [(Set<Int>(), 1, 2), ([0], 1, 2), ([8], 1, 2), ([1], -1, 2), ([1], 1, 1440), ([1], 1, 1)] {
            XCTAssertNil(ScheduledSiteBlock(hostname: host, weekdays: days, startMinute: start, endMinute: end))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule())) as? [String: Any])
        object["weekdays"] = [0]
        XCTAssertThrowsError(try JSONDecoder().decode(ScheduledSiteBlock.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testCommittedUnionRoundTripsAndFloorAlwaysDominatesSchedule() throws {
        var local = BlockingConfiguration()
        local.strictUnknownDestinations = true
        local.scheduledSites = [schedule(), schedule([2], 10, 20, host: "youtube.com")]
        var native = BlockingConfiguration()
        native.scheduledSites = [schedule([3], 60, 120, host: "news.test")]
        let rules = try CommittedBlockingRules(preserving: [local, native], catalog: Self.catalog)
        XCTAssertFalse(rules.configuration.strictUnknownDestinations)
        XCTAssertEqual(rules.configuration.scheduledSites, local.scheduledSites.union(native.scheduledSites))
        XCTAssertEqual(try BlockingConfiguration.decode(rules.configuration.localData()), rules.configuration)
        let payload = try rules.providerPayload()
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(payload.data, catalog: Self.catalog), rules.configuration)
        let policy = try BlockingPolicy(data: payload.data, catalog: Self.catalog)
        let outside = date("2026-11-09T08:00:00Z")
        XCTAssertTrue(policy.blocks(hostname: "www.youtube.com", outgoing: true, at: outside, timeZone: utc))
        XCTAssertFalse(policy.blocks(hostname: "example.com", outgoing: true, at: outside, timeZone: utc))
        XCTAssertTrue(policy.hasSchedule(hostname: "sub.example.com"))
        XCTAssertTrue(policy.blocks(hostname: "sub.example.com", outgoing: true, at: date("2026-11-09T09:00:00Z"), timeZone: utc))
        XCTAssertFalse(policy.blocks(hostname: nil, outgoing: true, at: outside, timeZone: utc))
    }

    func testNewVersionsRequireValidNonemptySchedulesAndCannotDowngrade() throws {
        var configuration = BlockingConfiguration()
        configuration.scheduledSites = [schedule()]
        var provider = try XCTUnwrap(JSONSerialization.jsonObject(with: configuration.providerData()) as? [String: Any])
        XCTAssertEqual(provider["version"] as? Int, 3)
        for invalid in [NSNull(), [], [["hostname": ["value": "example.com"], "weekdays": [], "startMinute": 1, "endMinute": 2]]] as [Any] {
            provider["scheduledSites"] = invalid
            XCTAssertThrowsError(try BlockingConfiguration.decodeProvider(JSONSerialization.data(withJSONObject: provider)))
            XCTAssertThrowsError(try BlockingConfiguration.recoverProviderAdditions(JSONSerialization.data(withJSONObject: provider)))
        }
        provider = try XCTUnwrap(JSONSerialization.jsonObject(with: configuration.providerData()) as? [String: Any])
        provider["version"] = 2
        XCTAssertThrowsError(try BlockingConfiguration.decodeProvider(JSONSerialization.data(withJSONObject: provider)))
        XCTAssertThrowsError(try BlockingConfiguration.recoverProviderAdditions(JSONSerialization.data(withJSONObject: provider)))
        var local = try XCTUnwrap(JSONSerialization.jsonObject(with: configuration.localData()) as? [String: Any])
        XCTAssertEqual(local["version"] as? Int, 2)
        local.removeValue(forKey: "scheduledSites")
        XCTAssertThrowsError(try BlockingConfiguration.decode(JSONSerialization.data(withJSONObject: local)))
        let legacy = BlockingConfiguration()
        XCTAssertEqual(try BlockingConfiguration.decode(legacy.localData()).version, 1)
        XCTAssertEqual(try BlockingConfiguration.decodeProvider(legacy.providerData()).scheduledSites, [])
    }

    func testFlowRegistryRetainsLiveSlotsUntilClosureAndDropsOnceAtBoundary() throws {
        var configuration = BlockingConfiguration()
        configuration.scheduledSites = [schedule()]
        let policy = try BlockingPolicy(data: configuration.providerData(), catalog: Self.catalog)
        var flows = ScheduledFlowRegistry<String>(maximumCount: 2)
        let first = UUID(), second = UUID(), overflow = UUID()
        XCTAssertTrue(flows.insert("first", id: first, hostname: "sub.example.com"))
        XCTAssertTrue(flows.insert("second", id: second, hostname: "example.com"))
        XCTAssertFalse(flows.insert("overflow", id: overflow, hostname: "example.com"))
        XCTAssertEqual(flows.takeBlocked(by: policy, at: date("2026-11-09T08:59:00Z"), timeZone: utc), [])
        XCTAssertEqual(Set(flows.takeBlocked(by: policy, at: date("2026-11-09T09:00:00Z"), timeZone: utc)), ["first", "second"])
        XCTAssertEqual(flows.count, 2)
        XCTAssertEqual(flows.takeBlocked(by: policy, at: date("2026-11-09T09:01:00Z"), timeZone: utc), [])
        XCTAssertFalse(flows.insert("replacement", id: first, hostname: "example.com"))
        XCTAssertFalse(flows.insert("overflow", id: overflow, hostname: "example.com"))
        flows.remove(id: first)
        XCTAssertTrue(flows.insert("overflow", id: overflow, hostname: "example.com"))
        XCTAssertEqual(flows.takeBlocked(by: BlockingPolicy(), at: date("2026-11-09T17:00:00Z"), timeZone: utc), [])
        flows.removeAll()
        XCTAssertEqual(flows.count, 0)
    }

    func testScheduleLimitRejectsBeforeProducingCommittedPayload() throws {
        let base = try CommittedBlockingRules(catalog: Self.catalog)
        var configuration = base.configuration
        configuration.scheduledSites = Set((0...ScheduledSiteBlock.maximumCount).map { schedule([2], $0, $0 + 1) })
        XCTAssertThrowsError(try configuration.localData())
        XCTAssertThrowsError(try CommittedBlockingRules(preserving: [configuration], catalog: Self.catalog).providerPayload())
    }
}
