import XCTest
import BrowserCore
@testable import BrowserDaddy

final class BlockingSchedulePresentationTests: XCTestCase {
    private func schedule(_ host: String, days: Set<Int> = Set(1...7), start: Int = 600, end: Int = 0) -> ScheduledSiteBlock {
        ScheduledSiteBlock(hostname: BlockingHostname(host)!, weekdays: days, startMinute: start, endMinute: end)!
    }

    private func date(_ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1,
            hour: minute / 60, minute: minute % 60))!
    }

    func testGroupsOnlyIdenticalWindowsAndRetainsEverySavedHost() {
        let schedules: Set<ScheduledSiteBlock> = [
            schedule("x.com"), schedule("twitter.com"),
            schedule("x.com", days: [2, 3, 4, 5, 6]),
            schedule("x.com", start: 601), schedule("x.com", end: 1),
        ]
        let groups = BlockingScheduleGroup.grouping(schedules)
        XCTAssertEqual(groups.count, 4)
        let common = groups.first { $0.hosts.count == 2 }
        XCTAssertEqual(common?.hosts, ["twitter.com", "x.com"])
        XCTAssertEqual(common?.repeatLabel, "Every day")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.hosts.count }, schedules.count)
        XCTAssertEqual(groups.first { $0.window.weekdays == Set(2...6) }?.repeatLabel, "Weekdays")
    }

    func testMinutePrecisionAndMidnightAvailableWindow() throws {
        let group = try XCTUnwrap(BlockingScheduleGroup.grouping([schedule("x.com", start: 617) ]).first)
        XCTAssertEqual(group.blockedMinutes, 823)
        XCTAssertEqual(group.availableMinutes, 617)
        XCTAssertEqual(group.blockedIntervals, [617..<1440])
        XCTAssertEqual(BlockingScheduleGroup.duration(group.blockedMinutes), "13 hr 43 min")
        XCTAssertEqual(BlockingScheduleGroup.time(0), "Midnight")
        XCTAssertEqual(group.availableLabel, "Available Midnight–\(BlockingScheduleGroup.time(617))")
    }

    func testRepeatedHostWindowsSortByDaysThenStartThenEnd() {
        let schedules: Set<ScheduledSiteBlock> = [
            schedule("x.com", days: [3], start: 60, end: 120),
            schedule("x.com", days: [2], start: 61, end: 120),
            schedule("x.com", days: [2], start: 60, end: 121),
            schedule("x.com", days: [2], start: 60, end: 120),
            schedule("news.example", days: [7], start: 1, end: 2),
        ]
        let groups = BlockingScheduleGroup.grouping(schedules)
        XCTAssertEqual(groups.map(\.hosts), [["news.example"], ["x.com"], ["x.com"], ["x.com"], ["x.com"]])
        XCTAssertEqual(groups.map(\.window.weekdays), [[7], [2], [2], [2], [3]])
        XCTAssertEqual(groups.map(\.window.startMinute), [1, 60, 60, 61, 60])
        XCTAssertEqual(groups.map(\.window.endMinute), [2, 120, 121, 120, 120])
    }

    func testOvernightTimelineShowsBothClockSegments() throws {
        let group = try XCTUnwrap(BlockingScheduleGroup.grouping([schedule("news.example", days: [6], start: 1327, end: 83)]).first)
        XCTAssertTrue(group.continuesNextDay)
        XCTAssertEqual(group.blockedMinutes, 196)
        XCTAssertEqual(group.availableMinutes, 1244)
        XCTAssertEqual(group.blockedIntervals, [0..<83, 1327..<1440])
        XCTAssertEqual(group.availableLabel, "Available \(BlockingScheduleGroup.time(83))–\(BlockingScheduleGroup.time(1327))")
    }

    func testDaytimeTimelineAndAvailability() throws {
        let group = try XCTUnwrap(BlockingScheduleGroup.grouping([schedule("news.example", start: 60, end: 125)]).first)
        XCTAssertFalse(group.continuesNextDay)
        XCTAssertEqual(group.blockedMinutes, 65)
        XCTAssertEqual(group.blockedIntervals, [60..<125])
        XCTAssertEqual(group.availableLabel, "Available midnight–\(BlockingScheduleGroup.time(60)) and \(BlockingScheduleGroup.time(125))–midnight")
    }

    func testDraftKeepsMinutePrecisionAndDistinguishesMidnightFromOvernight() throws {
        var draft = BlockingScheduleDraft()
        draft.website = " news.example "
        draft.start = date(617)
        draft.end = date(0)
        let midnight = try XCTUnwrap(draft.schedule)
        XCTAssertEqual(midnight.hostname.value, "news.example")
        XCTAssertEqual(midnight.startMinute, 617)
        XCTAssertEqual(midnight.endMinute, 0)
        XCTAssertTrue(draft.timeExplanation.contains("midnight that night"))
        XCTAssertFalse(draft.timeExplanation.contains("following day"))
        draft.end = date(37)
        XCTAssertEqual(draft.schedule?.endMinute, 37)
        XCTAssertTrue(draft.timeExplanation.contains("following day"))
    }

    func testDraftRejectsInvalidDomainEmptyDaysAndEqualTimes() {
        var draft = BlockingScheduleDraft()
        XCTAssertNil(draft.schedule)
        draft.website = "https://news.example/path"
        XCTAssertNil(draft.schedule)
        draft.website = "news.example"
        draft.weekdays = []
        XCTAssertNil(draft.schedule)
        draft.weekdays = [2]
        draft.start = date(601)
        draft.end = date(601)
        XCTAssertNil(draft.schedule)
        draft.end = date(602)
        XCTAssertNotNil(draft.schedule)
        XCTAssertNil(draft.validationMessage)
    }
    @MainActor func testOrdinaryOpeningShowsBlockingButStartupChecksAvoidRealRules() {
        XCTAssertEqual(RootView.initialWorkspace(arguments: []), .blocking)
        XCTAssertEqual(RootView.initialWorkspace(arguments: ["--check-app-startup"]), .attention)
        XCTAssertEqual(RootView.initialWorkspace(arguments: ["--preview-fixture"]), .history)
        XCTAssertEqual(RootView.initialWorkspace(arguments: ["--preview-fixture", "--preview-blocking", "--check-app-startup"]), .blocking)
    }

    func testSaveWaitsForPersistedScheduleAndDoesNotDismissOnFailure() {
        let requested = schedule("news.example")
        var submission = BlockingScheduleSubmission.saving(requested)
        XCTAssertFalse(submission.resolve(saved: [], busy: true, error: ""))
        XCTAssertTrue(submission.isSaving)
        XCTAssertTrue(submission.resolve(saved: [requested], busy: true, error: ""))
        XCTAssertEqual(submission, .idle)
        submission = .saving(requested)
        XCTAssertFalse(submission.resolve(saved: [], busy: false, error: "Disk write failed"))
        XCTAssertEqual(submission, .failed("Disk write failed"))
        XCTAssertTrue(submission.canSubmit(requested, ready: true, busy: false, saved: []))
        submission = .failed("Synchronous rejection")
        XCTAssertFalse(submission.resolve(saved: [requested], busy: false, error: ""))
        XCTAssertEqual(submission.error, "Synchronous rejection")
    }

    func testSaveGatingPreventsDuplicatesLimitAndConcurrentRequests() {
        let requested = schedule("news.example")
        let idle = BlockingScheduleSubmission.idle
        XCTAssertTrue(idle.canSubmit(requested, ready: true, busy: false, saved: []))
        XCTAssertFalse(idle.canSubmit(nil, ready: true, busy: false, saved: []))
        XCTAssertFalse(idle.canSubmit(requested, ready: false, busy: false, saved: []))
        XCTAssertFalse(idle.canSubmit(requested, ready: true, busy: true, saved: []))
        XCTAssertFalse(idle.canSubmit(requested, ready: true, busy: false, saved: [requested]))
        XCTAssertFalse(BlockingScheduleSubmission.saving(requested).canSubmit(requested, ready: true, busy: false, saved: []))
        let full = Set((0..<ScheduledSiteBlock.maximumCount).map { schedule("site\($0).example") })
        XCTAssertFalse(idle.canSubmit(requested, ready: true, busy: false, saved: full))
    }

}
