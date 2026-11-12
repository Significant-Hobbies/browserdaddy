import XCTest
@testable import BrowserDaddy

final class TrendLineTests: XCTestCase {
    @MainActor func testEmptySeriesHasNoDisplayedValue() {
        XCTAssertNil(TrendLine.displayedPoint(points: [], hover: nil))
        XCTAssertNil(TrendLine.displayedPoint(points: [], hover: 0))
    }

    @MainActor func testShortenedSeriesFallsBackToLatestValue() {
        XCTAssertEqual(TrendLine.displayedPoint(points: [12, 34], hover: 7), 34)
        XCTAssertEqual(TrendLine.displayedPoint(points: [12, 34], hover: -1), 34)
        XCTAssertEqual(TrendLine.displayedPoint(points: [12, 34], hover: nil), 34)
        XCTAssertEqual(TrendLine.displayedPoint(points: [12, 34], hover: 0), 12)
    }
}
