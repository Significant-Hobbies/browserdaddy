import Foundation
import XCTest
@testable import BrowserDaddy

final class ArtworkResourcesTests: XCTestCase {
    func testBundledArtworkLoadsAndUnknownArtworkFallsBack() {
        XCTAssertNotNil(DaddyResources.url(forResource: "BrowserDaddyIcon"))
        XCTAssertNotNil(DaddyResources.url(forResource: "BrowserDaddyScout"))
        XCTAssertNil(DaddyResources.url(forResource: "missing-artwork"))
    }
}
