import Foundation
import QuartzCore

/// L3e：
/// 详情加载时间线 —— AC-05/AC-06 的 App 侧取证。
///
/// 只记录、不设门：所有锚点用 `CACurrentMediaTime()`（单调钟，可跨线程比较），
/// 任何一端缺失时分段读数为 nil（E2E probe 串里记 -1）。与 ScrollHitchProbe 的
/// mark 互为印证：探针管「卡顿帧归因」，这里管「分段耗时」。
///
/// AC-05 的 DEC-07 分段口径（写测试断言用）：
/// - 有缓存路径：detailEnter→firstPageRequest ≤300ms（缓存 payload 读取即预取，
/// task-2 已有机制，本时间线补齐取证）；
/// - 无缓存路径：cursorArrive→firstPageRequest ≤300ms（快照 cursor 到达即发，
/// 不等首帧渲染、不等 reveal 定时器）；
/// - detailEnter→cursorArrive 是链路物理段（openStream + 首帧 RTT + 帧解码），
/// 只记录、不设门。
///
/// pageArrive→nextPageRequest 记录 L3c 流水线的决策开销：页 N 的原始 JSONValue
/// 到手即发出页 N+1 预取（实际请求发出只差一次主线程调度，由
/// fillNextPageRequest / fillFirstPageRequest 的 mark 与 firstPageRequestAt 覆盖）。
@MainActor
struct HistoryLoadTimeline: Equatable {
 /// VM init（与 DetailMetrics t0 同一口径：进入详情后的第一帧 app 内工作）。
    private(set) var detailEnterAt: CFTimeInterval?
 /// 冷入口：首个 live 快照把 cursor/front 写进 journal 的时刻（只认首个）。
    private(set) var cursorArriveAt: CFTimeInterval?
 /// 首页 session/page 请求实际发出的时刻（只记一次；预取/循环路径同口径）。
    private(set) var firstPageRequestAt: CFTimeInterval?
 /// 最近一页原始 JSONValue 到手（解码/合入尚未开始）。
    private(set) var lastPageArriveAt: CFTimeInterval?
 /// 最近一次「页 N 到手即发页 N+1 预取」的决策点（L3c）。
    private(set) var lastNextPageRequestAt: CFTimeInterval?
 /// 补齐完成（总耗时口径 = detailEnter→fillComplete，覆盖缓存恢复段）。
    private(set) var fillCompleteAt: CFTimeInterval?
 /// 补齐完成时累计合并的页数（与 historyFillPages 同源）。
    private(set) var pagesMerged = 0

    var hasFirstPageRequest: Bool { firstPageRequestAt != nil }

    mutating func markDetailEnter() {
        detailEnterAt = CACurrentMediaTime()
    }

 /// 只认首个 live 快照：重连的再快照不覆盖 AC-05 的冷入口锚点。
    mutating func markCursorArrive() {
        guard cursorArriveAt == nil else { return }
        cursorArriveAt = CACurrentMediaTime()
    }

    mutating func markFirstPageRequest() {
        guard firstPageRequestAt == nil else { return }
        firstPageRequestAt = CACurrentMediaTime()
    }

    mutating func markPageArrive() {
        lastPageArriveAt = CACurrentMediaTime()
    }

    mutating func markNextPageRequest() {
        lastNextPageRequestAt = CACurrentMediaTime()
    }

    mutating func markFillComplete(pages: Int) {
        fillCompleteAt = CACurrentMediaTime()
        pagesMerged = pages
    }

 // MARK: - 分段读数（毫秒）

 /// AC-05 有缓存路径硬线段（≤300ms）。
    var detailEnterToFirstPageRequestMs: Double? {
        segment(from: detailEnterAt, to: firstPageRequestAt)
    }

 /// AC-05 无缓存路径硬线段（≤300ms）。cursor 到达必须先于首页请求才有值：
 /// 有缓存路径预取先发、cursor 后到，本段为 nil、不参与判定。
    var cursorArriveToFirstPageRequestMs: Double? {
        guard let cursor = cursorArriveAt, let first = firstPageRequestAt,
              cursor < first else { return nil }
        return (first - cursor) * 1000
    }

 /// 物理段（openStream + 首帧 RTT + 帧解码）：只记录，不设门。
    var detailEnterToCursorArriveMs: Double? {
        segment(from: detailEnterAt, to: cursorArriveAt)
    }

 /// L3c 流水线决策开销：页 N 到手 → 页 N+1 预取发出。
    var pageArriveToNextPageRequestMs: Double? {
        segment(from: lastPageArriveAt, to: lastNextPageRequestAt)
    }

 /// 补齐总耗时（进入详情 → 补齐完成）。
    var detailEnterToFillCompleteMs: Double? {
        segment(from: detailEnterAt, to: fillCompleteAt)
    }

    private func segment(from: CFTimeInterval?, to: CFTimeInterval?) -> Double? {
        guard let from, let to, from <= to else { return nil }
        return (to - from) * 1000
    }
}
