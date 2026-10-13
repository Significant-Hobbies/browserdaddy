import XCTest
@testable import BrowserDaddy

@MainActor
final class ClipboardLinkTests: XCTestCase {
    func testRejectsCopiedLinksWithoutHTTPHost() {
        for value in ["https://", "http:example.com", "https:///path", "mailto:person@example.com", "plain text", ""] {
            XCTAssertNil(AppModel.clipboardURL(from: value), value)
        }
        XCTAssertNil(AppModel.clipboardURL(from: nil))
    }

    func testKeepsValidHTTPLinksAndTrimsClipboardWhitespace() {
        XCTAssertEqual(AppModel.clipboardURL(from: " \nhttps://example.com/path?q=1#anchor\n")?.absoluteString,
                       "https://example.com/path?q=1#anchor")
        XCTAssertEqual(AppModel.clipboardURL(from: "http://localhost:8080/")?.host, "localhost")
    }
}
