import XCTest
@testable import DSHm

/// Unified bottom-popup height math (see `Theme/SheetFit.swift`).
///
/// Default height = grabber band + header + measured content, capped so long
/// lists scroll. Resizable popups clamp that default into fixed bounds: the
/// floor is a content-independent comfort height (max(240pt, 32% of the screen))
/// so a tall diff can always be dragged back down; the ceiling is ~92% of the
/// screen. The home-indicator band is painted by the popup's safe-area background
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

    // MARK: - Resizable popup math (v0.2.8 task-2)

    /// iPhone-class screen: 852pt -> floor = max(240, 32%) = 272.64, ceiling = 92% = 783.84.
    private var phoneBounds: PopupHeight.ResizeBounds {
        PopupHeight.resizeBounds(screenHeight: 852)
    }

    func testResizeBoundsUseFixedComfortFloorIndependentOfContent() {
        let bounds = phoneBounds
        XCTAssertEqual(bounds.floor, 272.64, accuracy: 0.01)
        XCTAssertEqual(bounds.ceiling, 783.84, accuracy: 0.01)
        // A small screen keeps the 240pt absolute floor.
        let small = PopupHeight.resizeBounds(screenHeight: 568)
        XCTAssertEqual(small.floor, 240, accuracy: 0.01)
        XCTAssertEqual(small.ceiling, 522.56, accuracy: 0.01)
        // The ceiling can never drop below the floor.
        let tiny = PopupHeight.resizeBounds(screenHeight: 200)
        XCTAssertEqual(tiny.floor, tiny.ceiling, accuracy: 0.01)
    }

    func testDefaultHeightClampsContentFitIntoFixedBounds() {
        let bounds = phoneBounds
        // Short content opens at the fixed floor, not at the content height.
        XCTAssertEqual(PopupHeight.initialHeight(fittedHeight: 200, bounds: bounds), bounds.floor)
        XCTAssertEqual(PopupHeight.initialHeight(fittedHeight: 500, bounds: bounds), 500)
        // Tall content opens at the ceiling but can still be dragged down later.
        XCTAssertEqual(PopupHeight.initialHeight(fittedHeight: 2_000, bounds: bounds), bounds.ceiling)
        XCTAssertEqual(
            PopupHeight.resolvedHeight(userHeight: nil, fittedHeight: 900, bounds: bounds),
            bounds.ceiling
        )
    }

    func testAutoExpandRaisesOnlyShortPopupsIntoBand() {
        let bounds = phoneBounds
        let short = PopupHeight.autoExpandHeight(currentHeight: 300, screenHeight: 852, bounds: bounds)
        XCTAssertEqual(short, 553.8, accuracy: 0.01, "65% of the screen is the middle of the band")
        XCTAssertEqual(
            PopupHeight.autoExpandHeight(currentHeight: 620, screenHeight: 852, bounds: bounds),
            620,
            "a sheet already at/above the band is left alone"
        )
        let fromFloor = PopupHeight.autoExpandHeight(
            currentHeight: bounds.floor,
            screenHeight: 852,
            bounds: bounds
        )
        XCTAssertEqual(fromFloor, 553.8, accuracy: 0.01)
        XCTAssertLessThanOrEqual(fromFloor, bounds.ceiling)
    }

    func testResizeDragGrowsWhenDraggedUp() {
        let drag = PopupHeight.resizeDrag(startHeight: 500, translation: -120, bounds: phoneBounds)
        XCTAssertEqual(drag.height, 620)
        XCTAssertEqual(drag.overscroll, 0)
    }

    func testResizeDragShrinksTallContentDownToFixedFloor() {
        // Regression for the review: tall content must stay draggable down (the
        // floor is the fixed comfort height, not the content-fitted height).
        let bounds = phoneBounds
        let tall = PopupHeight.initialHeight(fittedHeight: 2_000, bounds: bounds)
        XCTAssertEqual(tall, bounds.ceiling)
        let shrunk = PopupHeight.resizeDrag(startHeight: tall, translation: 300, bounds: bounds)
        XCTAssertEqual(shrunk.height, tall - 300)
        XCTAssertEqual(shrunk.overscroll, 0)
        let atFloor = PopupHeight.resizeDrag(startHeight: tall, translation: 1_000, bounds: bounds)
        XCTAssertEqual(atFloor.height, bounds.floor)
        XCTAssertGreaterThan(atFloor.overscroll, PopupHeight.dismissThreshold)
    }

    func testResizeDragPastFloorBecomesOverscroll() {
        let bounds = phoneBounds
        // 300 - 140 = 160, i.e. 112.64pt below the 272.64 floor: not enough to dismiss.
        let drag = PopupHeight.resizeDrag(startHeight: 300, translation: 140, bounds: bounds)
        XCTAssertEqual(drag.height, bounds.floor)
        XCTAssertEqual(drag.overscroll, bounds.floor - 160, accuracy: 0.001)
        XCTAssertLessThan(drag.overscroll, PopupHeight.dismissThreshold)
        // The dismiss threshold is measured below the floor, not from the touch point.
        let dismiss = PopupHeight.resizeDrag(startHeight: 300, translation: 500, bounds: bounds)
        XCTAssertEqual(dismiss.height, bounds.floor)
        XCTAssertGreaterThan(dismiss.overscroll, PopupHeight.dismissThreshold)
    }

    func testResizeDragClampsToCeiling() {
        let drag = PopupHeight.resizeDrag(startHeight: 700, translation: -400, bounds: phoneBounds)
        XCTAssertEqual(drag.height, phoneBounds.ceiling)
        XCTAssertEqual(drag.overscroll, 0)
    }

    func testResolvedHeightClampsUserHeightIntoFixedBounds() {
        let bounds = phoneBounds
        XCTAssertEqual(
            PopupHeight.resolvedHeight(userHeight: 640, fittedHeight: 420, bounds: bounds),
            640
        )
        XCTAssertEqual(
            PopupHeight.resolvedHeight(userHeight: 200, fittedHeight: 420, bounds: bounds),
            bounds.floor
        )
        XCTAssertEqual(
            PopupHeight.resolvedHeight(userHeight: 900, fittedHeight: 420, bounds: bounds),
            bounds.ceiling
        )
    }

    // MARK: - Unified diff rows (v0.2.8 task-2)

    private func hunk(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        lines: [String]
    ) -> ChangesDiffValue.Hunk {
        ChangesDiffValue.Hunk(
            oldStart: oldStart,
            oldLines: oldLines,
            newStart: newStart,
            newLines: newLines,
            lines: lines
        )
    }

    func testDiffLineClassificationAndMarkerStripping() {
        XCTAssertEqual(DiffRowBuilder.kind(ofRawLine: "+let a = 1"), .added)
        XCTAssertEqual(DiffRowBuilder.kind(ofRawLine: "-let a = 1"), .removed)
        XCTAssertEqual(DiffRowBuilder.kind(ofRawLine: " let a = 1"), .context)
        XCTAssertEqual(DiffRowBuilder.kind(ofRawLine: ""), .context)
        XCTAssertEqual(DiffRowBuilder.kind(ofRawLine: "\\ No newline at end of file"), .context)

        XCTAssertEqual(DiffRowBuilder.code(ofRawLine: "+let a = 1"), "let a = 1")
        XCTAssertEqual(DiffRowBuilder.code(ofRawLine: "-let a = 1"), "let a = 1")
        XCTAssertEqual(DiffRowBuilder.code(ofRawLine: " let a = 1"), "let a = 1")
        XCTAssertEqual(
            DiffRowBuilder.code(ofRawLine: "\\ No newline at end of file"),
            "\\ No newline at end of file"
        )
    }

    func testDiffLineNumbersWalkOldAndNewFiles() {
        let display = DiffRowBuilder.build(
            hunks: [
                hunk(
                    oldStart: 10,
                    oldLines: 3,
                    newStart: 10,
                    newLines: 3,
                    lines: [" context a", "-removed b", "+added c", " context d"]
                )
            ]
        )
        XCTAssertEqual(display.hunks.count, 1)
        XCTAssertEqual(display.truncatedLineCount, 0)
        XCTAssertEqual(display.hunks[0].header, "@@ -10,3 +10,3 @@")
        let rows = display.hunks[0].lines
        XCTAssertEqual(rows.map(\.kind), [.context, .removed, .added, .context])
        // context advances both sides
        XCTAssertEqual(rows[0].oldNumber, 10)
        XCTAssertEqual(rows[0].newNumber, 10)
        // removed advances only the old counter
        XCTAssertEqual(rows[1].oldNumber, 11)
        XCTAssertNil(rows[1].newNumber)
        // added advances only the new counter
        XCTAssertNil(rows[2].oldNumber)
        XCTAssertEqual(rows[2].newNumber, 11)
        // context after the edit is already past both counters
        XCTAssertEqual(rows[3].oldNumber, 12)
        XCTAssertEqual(rows[3].newNumber, 12)
        XCTAssertEqual(rows.map(\.text), ["context a", "removed b", "added c", "context d"])
    }

    func testDiffLineNumbersFallBackToZeroWhenHunkOmitsStarts() {
        let display = DiffRowBuilder.build(
            hunks: [
                ChangesDiffValue.Hunk(
                    oldStart: nil,
                    oldLines: nil,
                    newStart: nil,
                    newLines: nil,
                    lines: [" same"]
                )
            ]
        )
        XCTAssertEqual(display.hunks[0].header, "@@ -0,0 +0,0 @@")
        XCTAssertEqual(display.hunks[0].lines[0].oldNumber, 0)
        XCTAssertEqual(display.hunks[0].lines[0].newNumber, 0)
    }

    func testDiffRowBuilderCapsAtTwoThousandLines() {
        XCTAssertEqual(DiffRowBuilder.maxLines, 2_000)
        let lines = (0..<2_001).map { " line " + String($0) }
        let display = DiffRowBuilder.build(
            hunks: [
                hunk(oldStart: 1, oldLines: 2_001, newStart: 1, newLines: 2_001, lines: lines)
            ]
        )
        XCTAssertEqual(display.hunks.count, 1)
        XCTAssertEqual(display.hunks[0].lines.count, 2_000)
        XCTAssertEqual(display.truncatedLineCount, 1)
    }

    func testDiffRowBuilderCapsAcrossHunks() {
        let first = hunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" a", " b", " c"])
        let second = hunk(oldStart: 9, oldLines: 3, newStart: 9, newLines: 3, lines: [" d", " e", " f"])
        let third = hunk(oldStart: 20, oldLines: 2, newStart: 20, newLines: 2, lines: [" g", " h"])
        let display = DiffRowBuilder.build(hunks: [first, second, third], maxLines: 4)
        XCTAssertEqual(display.hunks.count, 2)
        XCTAssertEqual(display.hunks[0].lines.count, 3)
        XCTAssertEqual(display.hunks[1].lines.count, 1)
        // second hunk: 2 dropped lines, third hunk: 2 dropped lines
        XCTAssertEqual(display.truncatedLineCount, 4)
    }

    func testDiffRowBuilderHandlesMissingHunks() {
        XCTAssertTrue(DiffRowBuilder.build(hunks: nil).isEmpty)
        XCTAssertTrue(DiffRowBuilder.build(hunks: []).isEmpty)
    }
}

