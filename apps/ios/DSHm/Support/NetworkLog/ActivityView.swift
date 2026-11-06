import SwiftUI
import UIKit

/// Bridge for the single approved UIKit interop point: after the archive is built,
/// the settings row presents the system share sheet directly (user approval
/// 2026-11-06 in `AGENTS.md`; design DD-08). Every app-owned surface stays SwiftUI.
///
/// Present it from SwiftUI (`.sheet(isPresented:)`); the completion handler fires
/// for both "shared" and "cancelled" so the caller can dismiss + clean up.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
