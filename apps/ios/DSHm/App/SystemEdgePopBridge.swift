import SwiftUI
import UIKit

/// — UIKit interop exception (approved, conditional on
/// empirical need; the need was proven on the iOS 26 simulator: with
/// `.toolbar(.hidden, for:.navigationBar)` the system edge-swipe pop stopped
/// firing while the programmatic pop still worked).
///
/// Why: SwiftUI's NavigationStack is backed by a UINavigationController, and
/// UIKit gates its own `interactivePopGestureRecognizer` (the native left-edge
/// swipe) when the navigation bar is hidden. This bridge ONLY flips that gate
/// back on: it replaces the recognizer's delegate with a minimal object that
/// reproduces UIKit's own rule ("begin only on a pushed page, stack depth > 1").
/// The recognizer's target/action — Apple's private interactive transition that
/// drives the system pop animation, shadow and finger tracking — is untouched.
/// No custom gesture recognizer, no custom animation, no UI is drawn in UIKit.
///
/// Scope: one file, attached once (RootView's session destination).
/// Rollback: delete this file and the `.background(SystemEdgePopBridge())`
/// line — everything else keeps working (the header back button pops the same
/// stack seam without it).
///
/// `DSHM_NAVDBG=1` (DEBUG) logs every gate/delegate/recognizer event through
/// `NavDiagnostics` — persisted to Documents/nav-events.log so a manual device
/// repro (jank / dead edge-swipe during subagent load) can be analyzed after
/// the fact; device app stdout is not otherwise capturable.
struct SystemEdgePopBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> WireView {
        let view = WireView()
        view.wire = { nav in
            context.coordinator.navigationController = nav
            NavTransitionGate.shared.navigationController = nav
            nav.interactivePopGestureRecognizer?.delegate = context.coordinator
            nav.interactivePopGestureRecognizer?.isEnabled = true
            NavDiagnostics.log("gate wired depth=\(nav.viewControllers.count) enabled=\(nav.interactivePopGestureRecognizer?.isEnabled ?? false)")
        }
        return view
    }

    func updateUIView(_ view: WireView, context: Context) {}

    func makeCoordinator() -> PopGate { PopGate() }

 /// UIKit's own begin-rule, reproduced (decision unit-tested below): never
 /// begin a pop from the stack root — with the system delegate replaced,
 /// UIKit would otherwise wedge the app on a root-level pop.
    final class PopGate: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let count = navigationController?.viewControllers.count ?? 0
            let allowed = count > 1
            NavDiagnostics.log("shouldBegin depth=\(count) -> \(allowed ? 1 : 0) state=\(gestureRecognizer.state.rawValue)")
            if allowed {
 // P0：interactive pop 即将开始 —— AppModel 的模型回写要等转场结束。
                NavTransitionGate.shared.noteTransitionStarted()
            }
            return allowed
        }

 /// device repro (user + nav-events.log): during the subagent
 /// load the message list is scrolling/decelerating, and with the minimal
 /// delegate the system edge pan LOST arbitration to the UIScrollView pan
 /// (many `shouldReceive touch`, no `shouldBegin`) — the bezel swipe only
 /// worked when the list happened to be still. Apple's own delegate lets
 /// the edge pan begin over live scrolling content (native apps pop while
 /// a list is still moving); restoring exactly that rule.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            NavDiagnostics.log("shouldReceive touch state=\(gestureRecognizer.state.rawValue)")
            return true
        }
    }

 /// Wires when the view reaches the window — by then the responder chain up
 /// to the enclosing UINavigationController is complete (viewDidLoad-time
 /// wiring races the push).
    final class WireView: UIView {
        var wire: ((UINavigationController) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            NavDiagnostics.log("wireView in window")
            var responder: UIResponder? = next
            while let current = responder {
                if let nav = current as? UINavigationController {
                    wire?(nav)
                    return
                }
                if let controller = current as? UIViewController, let nav = controller.navigationController {
                    wire?(nav)
                    return
                }
                responder = current.next
            }
        }
    }
}

#if DEBUG
/// DEBUG-only diagnostics sink for the native pop seam. Enabled by
/// `DSHM_NAVDBG=1`; appends lines to Documents/nav-events.log (and NSLog).
@MainActor
enum NavDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["DSHM_NAVDBG"] == "1"

    static func log(_ line: String) {
        guard isEnabled else { return }
        NSLog("[NAVDBG] %@", line)
        let stamp = Int(CACurrentMediaTime() * 1000)
        let text = "\(stamp)ms \(line)\n"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nav-events.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.data(using: .utf8)?.write(to: url)
        }
    }
}
#else
@MainActor
enum NavDiagnostics {
    static func log(_ line: String) {}
}
#endif
