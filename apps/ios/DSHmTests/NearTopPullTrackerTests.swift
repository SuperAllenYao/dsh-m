import XCTest
@testable import DSHm

/// 「下拉加载更早」触发判定的单测（纯逻辑）。
///
/// 两次真机回归都锁定在这里：
/// 1) 2026-10-22 第一次：用「手势起止 offset 差」算位移，贴顶 rubber-band 回弹后
///    恒为 0 → 永不触发。修正为手势过程中累计 **峰值**。
/// 2) 2026-10-22 第二次（用户反馈）：必须**越过距离立即触发**，不能等回弹到顶。
///    修正为 updateOffset 内即时判定，一次手势只触发一次。
final class NearTopPullTrackerTests: XCTestCase {

    /// 贴顶下拉：峰值一旦越过 240pt 就在拖动过程中立即返回 true（不等松手/回弹）。
    func testPullAtTopTriggersImmediatelyDuringDrag() {
        var tracker = NearTopPullTracker()
        XCTAssertTrue(tracker.isNearTop)
        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(-120), "未到阈值不触发")
        XCTAssertTrue(tracker.updateOffset(-380), "越过阈值的那一帧应立即触发")
        // 继续拖/回弹都不再重复触发
        XCTAssertFalse(tracker.updateOffset(-420))
        XCTAssertFalse(tracker.updateOffset(0))
        XCTAssertFalse(tracker.gestureEnded(), "同一次手势不重复触发")
    }

    /// 贴顶轻搓（峰值 < 240pt）不触发——用户要求「放大 2 倍」的意图。
    func testSmallWiggleAtTopDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(-30))
        XCTAssertFalse(tracker.updateOffset(-80))
        XCTAssertFalse(tracker.updateOffset(0))
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 中段一路拉到顶部：在「到达顶部附近且峰值越阈值」的那一帧立即触发。
    func testPullFromMidListToTopTriggersWhenReachingTop() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(1200)
        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(900))
        XCTAssertFalse(tracker.updateOffset(400), "还没到顶部附近，不触发")
        XCTAssertTrue(tracker.updateOffset(0), "到达顶部立即触发")
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 拉了很长距离但松手时没有到达顶部附近 → 不触发（避免半路误加载）。
    func testPullEndingAwayFromTopDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(3000)
        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(2500))
        XCTAssertFalse(tracker.updateOffset(2400))
        XCTAssertFalse(tracker.isNearTop)
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 程序化滚动（贴底跟随/锚点恢复）不经过手势：不得触发加载。
    func testProgrammaticScrollWithoutGestureDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        XCTAssertFalse(tracker.updateOffset(1800))
        XCTAssertFalse(tracker.updateOffset(600))
        XCTAssertFalse(tracker.updateOffset(0))
        XCTAssertFalse(tracker.gestureEnded(), "没有 gestureBegan 的滚动不能算用户下拉")
    }

    /// 连续多次下拉：每次手势都能独立触发（回归 §4.2「连续下拉每次有效」）。
    func testConsecutiveGesturesEachTrigger() {
        var tracker = NearTopPullTracker()

        tracker.gestureBegan()
        XCTAssertTrue(tracker.updateOffset(-300))
        XCTAssertFalse(tracker.gestureEnded())

        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(-20), "第二次轻搓不触发")
        XCTAssertFalse(tracker.gestureEnded())

        tracker.gestureBegan()
        XCTAssertTrue(tracker.updateOffset(-260), "第三次仍应触发")
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 阈值边界：offset == 240 算顶部附近，241 不算。
    func testNearTopThresholdBoundary() {
        var tracker = NearTopPullTracker()
        tracker.updateOffset(240)
        XCTAssertTrue(tracker.isNearTop)
        tracker.updateOffset(241)
        XCTAssertFalse(tracker.isNearTop)
    }

    /// 峰值在回弹前累计：先在拖动中越过阈值 → 立即触发；回弹不影响结论。
    func testPeakIsAccumulatedBeforeBounce() {
        var tracker = NearTopPullTracker()
        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(-100))
        XCTAssertEqual(tracker.maxPullDistance, 100)
        XCTAssertTrue(tracker.updateOffset(-260), "峰值越过阈值立即触发")
        tracker.updateOffset(-90)
        tracker.updateOffset(0)
        XCTAssertFalse(tracker.gestureEnded())
    }

    /// 慢拖但峰值不够（快速轻弹）不触发。
    func testShortFlickDoesNotTrigger() {
        var tracker = NearTopPullTracker()
        tracker.gestureBegan()
        XCTAssertFalse(tracker.updateOffset(-90))
        XCTAssertFalse(tracker.updateOffset(-140))
        XCTAssertFalse(tracker.gestureEnded())
    }
}
