import SwiftUI

/// inverted list 几何语义取证（r7-inverted 前置实验)。
/// DSHM_ROTATION_PROBE=1 启动。三个挂法变体并排对照（数据都正序 0..49，行内反转）：
/// - V1 ROT-POS-INNER：ScrollView{}.scrollPosition($p).rotationEffect(.pi)
/// - V2 SCALE-POS-INNER：ScrollView{}.scrollPosition($p).scaleEffect(x:-1,y:-1)
/// - V3 SCALE-POS-OUTER：ScrollView{}.scaleEffect(x:-1,y:-1).scrollPosition($p)
/// 每块取证：初始物化/视觉方向、tap 命中、程序化 scrollTo(edge:.bottom)、拖动后采样。
struct RotationProbeView: View {
    var body: some View {
        VStack(spacing: 4) {
            MountProbeView(variantID: "V1", kind: .rotPosInner)
            Divider()
            MountProbeView(variantID: "V2", kind: .scalePosInner)
            Divider()
            MountProbeView(variantID: "V3", kind: .scalePosOuter)
        }
        .ignoresSafeArea()
    }
}

/// 单个挂法变体的取证块。
private struct MountProbeView: View {
    enum Kind {
        case rotPosInner       // scrollPosition 在内，rotation 在外
        case scalePosInner     // scrollPosition 在内，scale 在外
        case scalePosOuter     // scale 在内，scrollPosition 在外
    }

    let variantID: String
    let kind: Kind

    @State private var probe = "init"
    @State private var tapped = "none"
    @State private var position = ScrollPosition()

    private var rows: [Int] { Array(0..<50) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(variantID) \(probe)")
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .accessibilityIdentifier("probe-label-\(variantID)")
                Spacer()
                Text("tap=\(tapped)")
                    .font(.system(size: 9, design: .monospaced))
                    .accessibilityIdentifier("tap-readout-\(variantID)")
                Button("GO-BOTTOM") { withAnimation(nil) { position.scrollTo(edge: .bottom) } }
                    .font(.system(size: 9, design: .monospaced))
                    .accessibilityIdentifier("go-bottom-\(variantID)")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.yellow.opacity(0.6))

            scrollViewCore
                .frame(maxHeight: .infinity)

            TimelineView(.periodic(from: .now, by: 0.15)) { _ in
                Text("offset-probe-\(variantID)")
                    .font(.system(size: 1))
                    .frame(width: 2, height: 2)
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("offset-probe-\(variantID)")
                    .accessibilityValue(probe)
            }
        }
    }

    @ViewBuilder
    private var scrollViewCore: some View {
        switch kind {
        case .rotPosInner:
            baseScrollView
                .scrollPosition($position)
                .rotationEffect(.radians(.pi))
        case .scalePosInner:
            baseScrollView
                .scrollPosition($position)
                .scaleEffect(x: -1, y: -1)
        case .scalePosOuter:
            baseScrollView
                .scaleEffect(x: -1, y: -1)
                .scrollPosition($position)
        }
    }

    private var baseScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self) { i in
                    Text("R\(variantID)-\(i)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(i % 2 == 0 ? Color.blue.opacity(0.10) : Color.clear)
                        .rotationEffect(.radians(.pi))
                        .onTapGesture { tapped = "hit=\(i)" }
                }
            }
        }
        .onScrollGeometryChange(for: String.self) { geometry in
            "off=\(Int(geometry.contentOffset.y + geometry.contentInsets.top)) ch=\(Int(geometry.contentSize.height)) vh=\(Int(geometry.containerSize.height))"
        } action: { _, new in
            probe = new
        }
    }
}
