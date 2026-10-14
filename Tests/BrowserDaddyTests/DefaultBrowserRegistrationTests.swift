import XCTest
@testable import BrowserDaddy

final class DefaultBrowserRegistrationTests: XCTestCase {
    @MainActor func testRegistersBothSchemesBeforeReportingSuccess() async throws {
        var schemes: [String] = []
        let appURL = URL(fileURLWithPath: "/Applications/BrowserDaddy.app")
        try await DefaultBrowserRegistration.register(
            bundleID: "test.browserdaddy",
            applicationURL: appURL,
            setDefault: { schemes.append($0) },
            handlerID: { _ in "test.browserdaddy" },
            handlerURL: { _ in appURL })
        XCTAssertEqual(schemes, ["http", "https"])
    }

    @MainActor func testRejectsAHandlerThatDidNotChange() async {
        do {
            try await DefaultBrowserRegistration.register(
                bundleID: "test.browserdaddy",
                applicationURL: URL(fileURLWithPath: "/Applications/BrowserDaddy.app"),
                setDefault: { _ in },
                handlerID: { url in url.path == "/Applications/BrowserDaddy.app"
                    ? "test.browserdaddy" : "other.browser" },
                handlerURL: { scheme in URL(fileURLWithPath: scheme == "http"
                    ? "/Applications/BrowserDaddy.app" : "/tmp/BrowserDaddy.app") })
            XCTFail("Expected a handler mismatch")
        } catch DefaultBrowserRegistration.Error.handlerMismatch {
            // The system must confirm both schemes before the UI reports success.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor func testRejectsAnotherCopyWithTheSameBundleID() async {
        do {
            try await DefaultBrowserRegistration.register(
                bundleID: "test.browserdaddy",
                applicationURL: URL(fileURLWithPath: "/Applications/BrowserDaddy.app"),
                setDefault: { _ in },
                handlerID: { _ in "test.browserdaddy" },
                handlerURL: { _ in URL(fileURLWithPath: "/tmp/BrowserDaddy.app") })
            XCTFail("Expected another copy to be rejected")
        } catch DefaultBrowserRegistration.Error.handlerMismatch {
            // A matching identifier does not prove which installed copy receives links.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor func testResolvesSymlinksBeforeComparingPaths() {
        XCTAssertTrue(DefaultBrowserRegistration.isSameApplication(
            URL(fileURLWithPath: "/tmp"),
            as: URL(fileURLWithPath: "/private/tmp")))
    }

    @MainActor func testMissingBundleIDNeverRequestsAChange() async {
        var calls = 0
        do {
            try await DefaultBrowserRegistration.register(
                bundleID: nil,
                applicationURL: URL(fileURLWithPath: "/Applications/BrowserDaddy.app"),
                setDefault: { _ in calls += 1 },
                handlerID: { _ in "" },
                handlerURL: { _ in nil })
            XCTFail("Expected a missing bundle identifier error")
        } catch DefaultBrowserRegistration.Error.missingBundleIdentifier {
            XCTAssertEqual(calls, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
