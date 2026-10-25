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
struct SystemEdgePopBridge: UIViewRepresentable {
    func makeUIView(context: Context) -> WireView {
        let view = WireView()
        view.wire = { nav in
            context.coordinator.navigationController = nav
            nav.interactivePopGestureRecognizer?.delegate = context.coordinator
            nav.interactivePopGestureRecognizer?.isEnabled = true
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
            (navigationController?.viewControllers.count ?? 0) > 1
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
