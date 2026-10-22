import XCTest
@testable import DSHm

/// Unified bottom-popup fitted-height math (see `Theme/SheetFit.swift`).
///
/// Height = grabber band + header + measured content, capped so long lists
/// scroll. The home-indicator band is painted by the popup's safe-area background
/// and is not part of the layout height.
final class SheetFitHeightTests: XCTestCase {

    func testFittedHeightAddsChromeAndBottomBand() {
        XCTAssertEqual(
            PopupHeight.fitted(
                contentHeight: 300,
                fixedHeight: 49,
                grabberChrome: 44,
                minHeight: 180,
                maxHeight: 900
            ),
            393
        )
    }

    func testFittedHeightClampsToMinimum() {
        XCTAssertEqual(
            PopupHeight.fitted(
                contentHeight: 10,
                fixedHeight: 49,
                grabberChrome: 44,
                minHeight: 180,
                maxHeight: 900
            ),
            180
        )
    }

    func testFittedHeightClampsToMaximum() {
        XCTAssertEqual(
            PopupHeight.fitted(
                contentHeight: 2_000,
                fixedHeight: 49,
                grabberChrome: 44,
                minHeight: 180,
                maxHeight: 800
            ),
            800
        )
    }

    func testFittedHeightFallsBackBeforeFirstLayout() {
        XCTAssertEqual(
            PopupHeight.fitted(
                contentHeight: 0,
                fixedHeight: 49,
                grabberChrome: 44,
                minHeight: 180,
                maxHeight: 900,
                fallbackHeight: 420
            ),
            420
        )
        // The fallback itself is clamped to the ceiling.
        XCTAssertEqual(
            PopupHeight.fitted(
                contentHeight: 0,
                minHeight: 180,
                maxHeight: 400,
                fallbackHeight: 420
            ),
            400
        )
    }

    func testFittedCeilingNeverBelowFloor() {
        XCTAssertEqual(
            PopupHeight.fitted(
                contentHeight: 0,
                minHeight: 300,
                maxHeight: 200,
                fallbackHeight: 100
            ),
            300
        )
    }
}
