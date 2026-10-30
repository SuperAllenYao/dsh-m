import SwiftUI
import UIKit

/// DD-18（r3.3，经用户批准）：左滑手势的 UIKit 桥接层。
///
/// 只替换**手势识别层**——卡片内容、rail 按钮、圆角裁切仍是 SwiftUI（BASIS-34）。
/// 用 `UIPanGestureRecognizer` 取代 SwiftUI `.simultaneousGesture(DragGesture)`，
/// 因为后者在 `ScrollView` 内会被父级 scroll 抢走（BASIS-33）。
///
/// 仲裁（coordinator 实现 `UIGestureRecognizerDelegate`）：
/// - `gestureRecognizerShouldBegin`：水平意图门（`|vx| > |vy| * 1.2`）；收起态只接
/// 左滑，展开态双向。注意这是 UIKit 的**一次性起判**（DD-18 ①）。
/// - `shouldRecognizeSimultaneouslyWith` 恒 `true`：不允许父级 `UIScrollView` 的
/// pan 取消本识别器（这正是 SwiftUI 手势失败的原因）。
/// - `shouldReceive`：触点必须落在本视图 bounds 内（防御识别区被放大到共享宿主）。
///
/// 横向接管期间把最近的 `UIScrollView.isScrollEnabled` 置 `false`、结束时恢复，
/// 保证横向拖动期间纵向不抢（AC-21 ⑦）；找不到 ScrollView 时跳过隔离，只记
/// DEBUG 日志（DD-18 的推断路径，见设计 §5 第 5 条）。
struct SwipePanGesture: UIGestureRecognizerRepresentable {
    var sessionId: String
 /// 手势开始时的展开态（由卡片 `open` 传入，`.began` 时定格）。
    var isOpen: Bool
    @Binding var offsetX: CGFloat
    @Binding var isDragging: Bool
 /// 横向接管开始（父级把 `swipedSessionId` 改成本行）。
    var onBegan: (String) -> Void
 /// 松手停靠结果：true = 停在展开位，false = 收起。父级据此重写 `swipedSessionId`。
    var onSettle: (String, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
 // 不吞掉按钮点击：rail 按钮的 tap 必须继续生效（AC-21⑧）。
        recognizer.cancelsTouchesInView = false
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
 // 闭包/绑定随 SwiftUI 每次渲染重建，保持 coordinator 看到最新状态。
        context.coordinator.parent = self
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.parent = self
        context.coordinator.handle(recognizer)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipePanGesture

 /// 最近的宿主 ScrollView（弱引用；横向接管期间关闭它的滚动）。
        private weak var scrollView: UIScrollView?
 /// `shouldReceive` 从触点视图链上记下的 ScrollView 兜底（不保证命中）。
        private weak var hitScrollView: UIScrollView?
        private var scrollWasEnabled = true
 /// `.began` 时定格：起始露出量与该行是否已展开（停靠判定用，不随回调变化）。
        private var startOffset: CGFloat = 0
        private var startOpen = false

        init(parent: SwipePanGesture) {
            self.parent = parent
        }

 // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return SwipeIntent.shouldBegin(
                velocityX: velocity.x,
                velocityY: velocity.y,
                isOpen: parent.isOpen
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
 // DD-18 ②：恒 true，否则父级 ScrollView 的 pan 会在识别瞬间让本识别器失败。
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            guard view.bounds.contains(touch.location(in: view)) else { return false }
 // 兜底：识别器自身视图可能挂在 SwiftUI 的 recognition host 上；触点所在
 // 视图链更接近真实内容，先记下来供 `.began` 的滚动隔离使用。
            if hitScrollView == nil {
                hitScrollView = Self.enclosingScrollView(from: touch.view)
            }
            return true
        }

 // MARK: - 状态机

        func handle(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: pan.view)
            let velocity = pan.velocity(in: pan.view)

            switch pan.state {
            case .began:
                startOpen = parent.isOpen
                startOffset = startOpen ? -SwipeCardGeometry.openWidth : 0
                parent.isDragging = true
                parent.onBegan(parent.sessionId)
                disableEnclosingScrollView(from: pan.view)
                log("began", translation: translation, offsetX: parent.offsetX,
                    scrollEnabled: scrollView?.isScrollEnabled)

            case .changed:
 // DD-18：不允许多滑（无整滑触发）；露出量夹在 [-openWidth, 0]。
                let proposed = startOffset + translation.x
                parent.offsetX = min(0, max(-SwipeCardGeometry.openWidth, proposed))
                log("changed", translation: translation, offsetX: parent.offsetX,
                    scrollEnabled: scrollView?.isScrollEnabled)

            case .ended, .cancelled, .failed:
                let target = SwipeIntent.settleTarget(
                    startOpen: startOpen,
                    dx: translation.x,
                    offset: parent.offsetX,
                    velocityX: velocity.x,
                    openWidth: SwipeCardGeometry.openWidth
                )
                let willOpen = target < 0
                withAnimation(Theme.Motion.quick) { parent.offsetX = target }
                restoreEnclosingScrollView()
                parent.isDragging = false
                let phase = pan.state == .ended ? "ended" : "cancelled"
                log(phase, translation: translation, offsetX: target,
                    decision: willOpen, scrollEnabled: scrollView?.isScrollEnabled)
                parent.onSettle(parent.sessionId, willOpen)

            default:
                break
            }
        }

 // MARK: - 滚动隔离

        private func disableEnclosingScrollView(from view: UIView?) {
            scrollView = nil
 // DD-18：优先沿 recognizer.view 向上找；识别器若被 SwiftUI 挂在
 // recognition host 上导致找不到，再用触点视图链的兜底。
            let enclosing = Self.enclosingScrollView(from: view) ?? hitScrollView
            guard let enclosing else {
                #if DEBUG
                let chain = Self.viewChain(from: view)
                SwipeDebugLog.log("pan scrollview not found sid=\(parent.sessionId) chain=\(chain)")
                #endif
                return
            }
            scrollView = enclosing
            scrollWasEnabled = enclosing.isScrollEnabled
            enclosing.isScrollEnabled = false
        }

        private func restoreEnclosingScrollView() {
            scrollView?.isScrollEnabled = scrollWasEnabled
        }

        private static func enclosingScrollView(from view: UIView?) -> UIScrollView? {
            var current = view
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }

 /// DEBUG：识别器视图向上最多 10 层的类名，用于确认宿主查找是否命中。
        private static func viewChain(from view: UIView?) -> String {
            var names: [String] = []
            var current = view
            while let candidate = current, names.count < 10 {
                names.append(String(describing: type(of: candidate)))
                current = candidate.superview
            }
            return names.joined(separator: ">")
        }

 // MARK: - DEBUG 真值日志

 /// DD-18 真值格式：`pan <began|changed|ended|cancelled> dx=… dy=… offsetX=…
 /// decision=open|close scrollEnabled=…`（decision 仅 ended/cancelled 有）。
 /// 生产构建里 `SwipeDebugLog` 不存在，整段为 no-op。
        private func log(
            _ phase: String,
            translation: CGPoint,
            offsetX: CGFloat,
            decision: Bool? = nil,
            scrollEnabled: Bool?
        ) {
            #if DEBUG
            var line = String(
                format: "pan %@ dx=%.1f dy=%.1f offsetX=%.1f",
                phase, translation.x, translation.y, offsetX
            )
            if let decision {
                line += decision ? " decision=open" : " decision=close"
            }
            if let scrollEnabled {
                line += scrollEnabled ? " scrollEnabled=true" : " scrollEnabled=false"
            } else {
                line += " scrollEnabled=unavailable"
            }
            SwipeDebugLog.log(line)
            #endif
        }
    }
}
