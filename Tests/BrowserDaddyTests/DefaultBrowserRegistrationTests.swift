import XCTest
@testable import BrowserDaddy

final class DefaultBrowserRegistrationTests: XCTestCase {
    @MainActor func testRegistersBothSchemesBeforeReportingSuccess() async throws {
        var schemes: [String] = []
        try await DefaultBrowserRegistration.register(
            bundleID: "test.browserdaddy",
            setDefault: { schemes.append($0) },
            handlerID: { _ in "test.browserdaddy" })
        XCTAssertEqual(schemes, ["http", "https"])
    }

    @MainActor func testRejectsAHandlerThatDidNotChange() async {
        do {
            try await DefaultBrowserRegistration.register(
                bundleID: "test.browserdaddy",
                setDefault: { _ in },
                handlerID: { scheme in scheme == "http" ? "test.browserdaddy" : "other.browser" })
            XCTFail("Expected a handler mismatch")
        } catch DefaultBrowserRegistration.Error.handlerMismatch {
            // The system must confirm both schemes before the UI reports success.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor func testMissingBundleIDNeverRequestsAChange() async {
        var calls = 0
        do {
            try await DefaultBrowserRegistration.register(
                bundleID: nil,
                setDefault: { _ in calls += 1 },
                handlerID: { _ in "" })
            XCTFail("Expected a missing bundle identifier error")
        } catch DefaultBrowserRegistration.Error.missingBundleIdentifier {
            XCTAssertEqual(calls, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
