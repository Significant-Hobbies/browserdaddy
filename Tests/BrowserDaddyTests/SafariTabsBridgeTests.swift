import XCTest
@testable import BrowserDaddy

final class SafariTabsBridgeTests: XCTestCase {
    @MainActor
    func testExtensionStateReplyCanArriveOffMainActor() async {
        let enabled = await SafariTabsBridge.extensionEnabled { _, completion in
            DispatchQueue.global().async {
                completion(nil, nil)
            }
        }
        XCTAssertFalse(enabled)
    }
}
