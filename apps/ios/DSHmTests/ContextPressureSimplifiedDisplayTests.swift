import XCTest
@testable import DSHm

/// v0.2.0 simplified context-window cell: window value + percentage text +
/// severity buckets.
final class ContextPressureSimplifiedDisplayTests: XCTestCase {

    private func value(used: Int?, window: Int?) -> ContextPressureValue {
        ContextPressureValue(pressureTokens: used, projectedTokens: nil, contextWindow: window)
    }

    // MARK: - Compact cell text (window · percentage)

    func testCompactTextShowsWindowAndPercentage() {
        XCTAssertEqual(value(used: 12_400, window: 200_000).compactText, "200k · 6%")
        XCTAssertEqual(value(used: 530_000, window: 1_000_000).compactText, "1M · 53%")
        XCTAssertEqual(value(used: 0, window: 200_000).compactText, "200k · 0%")
    }

    func testCompactTextOvershootIsNotClamped() {
        XCTAssertEqual(value(used: 300_000, window: 200_000).compactText, "200k · 150%")
    }

    func testCompactTextShowsWindowOnlyWhenUsageUnknown() {
        XCTAssertEqual(value(used: nil, window: 1_000_000).compactText, "1M")
        XCTAssertEqual(value(used: nil, window: 200_000).windowText, "200k")
    }

    func testCompactTextFallsBackToDashWithoutWindow() {
        XCTAssertEqual(ContextPressureValue().compactText, "—")
        XCTAssertEqual(value(used: 12_400, window: nil).compactText, "—")
        XCTAssertEqual(value(used: 12_400, window: 0).compactText, "—")
        XCTAssertNil(value(used: 12_400, window: 0).windowText)
    }

    // MARK: - Percentage-only text

    func testPercentTextOnlyShowsPercentage() {
        XCTAssertEqual(value(used: 12_400, window: 200_000).percentText, "6%")
        XCTAssertEqual(value(used: 0, window: 200_000).percentText, "0%")
        XCTAssertEqual(value(used: 200_000, window: 200_000).percentText, "100%")
    }

    func testPercentTextOvershootIsNotClamped() {
        XCTAssertEqual(value(used: 300_000, window: 200_000).percentText, "150%")
    }

    func testPercentTextFallsBackToDash() {
        XCTAssertEqual(ContextPressureValue().percentText, "—")
        XCTAssertEqual(value(used: 12_400, window: nil).percentText, "—")
        XCTAssertEqual(value(used: nil, window: 200_000).percentText, "—")
        XCTAssertEqual(value(used: 12_400, window: 0).percentText, "—")
    }

    func testUsageLevelThresholds() {
        XCTAssertEqual(value(used: 49, window: 100).usageLevel, .low)
        XCTAssertEqual(value(used: 50, window: 100).usageLevel, .moderate)
        XCTAssertEqual(value(used: 79, window: 100).usageLevel, .moderate)
        XCTAssertEqual(value(used: 80, window: 100).usageLevel, .high)
        XCTAssertEqual(value(used: 89, window: 100).usageLevel, .high)
        XCTAssertEqual(value(used: 90, window: 100).usageLevel, .critical)
        XCTAssertEqual(value(used: 100, window: 100).usageLevel, .critical)
        XCTAssertEqual(value(used: 300, window: 200).usageLevel, .critical) // 150%
    }

    func testUsageLevelNilWithoutPercentage() {
        XCTAssertNil(ContextPressureValue().usageLevel)
        XCTAssertNil(value(used: 12_400, window: nil).usageLevel)
        XCTAssertNil(value(used: nil, window: 200_000).usageLevel)
    }

    /// The old exact-token text stays available for VoiceOver, but the visual
    /// cell no longer depends on it.
    func testDetailedTextKeptForAccessibility() {
        XCTAssertEqual(value(used: 12_400, window: 200_000).displayText, "12.4k / 200k · 6%")
    }
}
