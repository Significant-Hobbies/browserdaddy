import AppKit
import XCTest
@testable import BrowserCore

final class TabInventoryTests: XCTestCase {
    func testInstalledBrowserInventoryScriptsCompile() {
        var checked = 0
        for kind in [BrowserKind.chrome, .brave]
            where BrowserOpener.appURL(for: kind) != nil {
            guard let source = TabInventory.listScript(kind: kind),
                  let script = NSAppleScript(source: source) else {
                XCTFail("Missing inventory script for \(kind.displayName)")
                continue
            }
            var error: NSDictionary?
            XCTAssertTrue(script.compileAndReturnError(&error),
                          "\(kind.displayName): \(error?.description ?? "unknown error")")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testEveryChromiumInventoryScriptFiltersNonNormalWindows() {
        for kind in [BrowserKind.chrome, .brave, .edge, .vivaldi, .arc,
                     .opera, .chromium] {
            let source = TabInventory.listScript(kind: kind)
            XCTAssertNotNil(source, kind.displayName)
            XCTAssertTrue(
                source?.contains("mode of window w") ?? false,
                "\(kind.displayName) inventory lacks the incognito window filter")
        }
    }

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
        XCTAssertNil(TabInventory.listScript(kind: .safari))
        XCTAssertNil(FrontmostTab.tabScript(kind: .safari))
    }
}
