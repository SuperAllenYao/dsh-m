import SwiftUI

/// Top 2pt determinate bar for the background history filler.
///
/// Design: `<internal-doc>` (r2, approved
/// ). Pure overlay: 2pt tall, no layout contribution, no hit testing.
/// The track uses `Theme.Palette.border`; the fill uses the single accent color.
struct HistoryFillProgressBar: View {
    let progress: HistoryFillProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.Palette.border)
                Rectangle()
                    .fill(Theme.Palette.accent)
                    .frame(width: proxy.size.width * CGFloat(progress.fraction))
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : Theme.Motion.standard, value: progress.fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("历史加载进度"))
        .accessibilityValue("\(progress.percent)%")
        .accessibilityIdentifier("session-history-fill-progress")
    }
}
