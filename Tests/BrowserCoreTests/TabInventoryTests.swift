import AppKit
import XCTest
@testable import BrowserCore

final class TabInventoryTests: XCTestCase {
    func testSafariPrivateAndUnknownPagesNeverBecomeEntries() {
        let url = URL(string: "https://example.com/private")!
        XCTAssertNil(SafariTabWire.regularEntry(window: 1, index: 1,
                                                isPrivate: true, url: url,
                                                title: "Private"))
        XCTAssertNil(SafariTabWire.regularEntry(window: 1, index: 1,
                                                isPrivate: nil, url: url,
                                                title: "Unknown"))
        let normal = SafariTabWire.regularEntry(window: 1, index: 2,
                                                isPrivate: false, url: url,
                                                title: "Normal")
        XCTAssertEqual(normal?.url, url.absoluteString)
        XCTAssertEqual(normal?.title, "Normal")
        XCTAssertEqual(TabInventory.state(for: .safari), .unsupported)
        XCTAssertEqual(TabInventory.state(for: .firefox), .unsupported)
    }
}
