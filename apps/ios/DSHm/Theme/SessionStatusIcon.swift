import SwiftUI

/// Seven-state session status (design v6 §2): the A-form, single-color linear
/// icon set shared by the detail header and the session-list status row.
///
/// Priority/semantics live in the resolver (SessionListStatusResolver); a
/// status maps to a kind via SessionListStatus.kind. Semantic colors follow
/// v6 §2: offline #5F6E84, approval #FBBF24, answer #34D399, running #22D3EE,
/// not-started #60A5FA, idle #93A1B5, error #F87171. Every value resolves to an
/// existing Theme.Palette token (no raw color literals here).
enum SessionStatusKind {
    case offline
    case approval
    case answer
    case running
    case notStarted
    case idle
    case error

    var color: Color {
        switch self {
        case .offline: return Theme.Palette.textTertiary    // #5F6E84
        case .approval: return Theme.Palette.warning        // #FBBF24
        case .answer: return Theme.Palette.waiting          // #34D399
        case .running: return Theme.Palette.accent          // #22D3EE
        case .notStarted: return Theme.Palette.info         // #60A5FA
        case .idle: return Theme.Palette.textSecondary      // #93A1B5
        case .error: return Theme.Palette.danger            // #F87171
        }
    }
}

/// v6 status icon: 24-unit linear drawing, stroked single-color (1.7pt at
/// 24pt, round cap/join), scaled to size.
///
/// Motion is non-linear and per state (v6 §0):
/// - running: 1.4s ease-in-out 360° rotation;
/// - approval: 1.0s one-way (2.0s round trip) overshoot breathing, opacity
/// 1 <-> 0.55 and scale 1 <-> 1.10;
/// - answer: 1.2s one-way (2.4s round trip) fast-out/slow-in float, y 0 <-> -2.
///
/// All motion is disabled when Accessibility / Reduce Motion is on. The icon is
/// purely presentational; the status text next to it carries the semantics.
struct SessionStatusIcon: View {
    var kind: SessionStatusKind
    var size: CGFloat = 24
 /// Motion amplitude multiplier. 1.0 = list/baseline; the detail header
 /// passes 1.3 (user requirement: bigger answer bounce).
    var motionScale: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

 /// Design view box; every path below is authored in these units.
    private static let viewBox: CGFloat = 24

    @ViewBuilder
    var body: some View {
        let base = icon
            .frame(width: Self.viewBox, height: Self.viewBox)
            .scaleEffect(size / Self.viewBox)
            .frame(width: size, height: size)

        if kind == .running {
 // 时间驱动：角度按单调递增的相位计算（始终顺时针），每圈用
 // cubic-bezier(.45,0,.25,1) 加减速。不用.repeatForever：动画重启时
 // SwiftUI 会从当前角度插值回 0，观感上变成“时而顺时针、时而逆时针”。
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
                base.rotationEffect(.degrees(Self.runningRotationDegrees(at: context.date)))
            }
            .accessibilityHidden(true)
        } else {
            base
                .scaleEffect(kind == .approval && active ? 1.10 : 1)
                .opacity(kind == .approval && active ? 0.55 : 1)
                .offset(y: kind == .answer ? (active ? -2 * motionScale * size / Self.viewBox : 0) : 0)
                .animation(animation, value: active)
                .onAppear { restartAnimation() }
                .onChange(of: kind) { _, _ in restartAnimation() }
                .onChange(of: reduceMotion) { _, _ in restartAnimation() }
                .accessibilityHidden(true)
        }
    }

 // MARK: - Motion

    private var animation: Animation? {
        guard !reduceMotion else { return nil }
        switch kind {
        case .running:
 // running 由 TimelineView 时间驱动，不使用隐式 repeatForever 动画。
            return nil
        case .approval:
            return .timingCurve(0.34, 1.56, 0.64, 1, duration: 1.0)
                .repeatForever(autoreverses: true)
        case .answer:
            return .timingCurve(0.16, 1, 0.3, 1, duration: 1.2)
                .repeatForever(autoreverses: true)
        case .offline, .notStarted, .idle, .error:
            return nil
        }
    }

 /// Starts (or restarts) the state's repeating animation. Restarting matters
 /// when the same icon slot switches kind: active is already true then, so a
 /// plain body re-render would not retrigger.animation(value:).
    private func restartAnimation() {
        guard !reduceMotion else {
            active = false
            return
        }
        active = false
        DispatchQueue.main.async { active = true }
    }

 // MARK: - Running rotation (time-driven, clockwise)

 /// running 每圈周期（秒）。
    static let runningRotationPeriod: TimeInterval = 1.4

 /// running 图标在当前时刻的旋转角度：相位 [0,1) 经 cubic-bezier(.45,0,.25,1)
 /// 映射到 [0°, 360°)，随真实时间单调递增（永不回卷），观感始终顺时针。
    static func runningRotationDegrees(at date: Date,
                                       period: TimeInterval = runningRotationPeriod) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        let phase = seconds.truncatingRemainder(dividingBy: period) / period
        return 360 * cubicBezierY(phase, x1: 0.45, y1: 0, x2: 0.25, y2: 1)
    }

 /// CSS `cubic-bezier(x1, y1, x2, y2)` 的 y(t)：牛顿法解 x(u)=t 后取 y(u)。
 /// x 控制点在 [0,1]；y 可越界（回弹）。纯函数，便于单测。
    static func cubicBezierY(_ t: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let target = min(max(t, 0), 1)
        var u = target
        for _ in 0..<8 {
            let x = bezierComponent(u, p1: x1, p2: x2) - target
            let slope = bezierDerivative(u, p1: x1, p2: x2)
            if abs(slope) < 1e-7 { break }
            u = min(max(u - x / slope, 0), 1)
        }
        return bezierComponent(u, p1: y1, p2: y2)
    }

    private static func bezierComponent(_ u: Double, p1: Double, p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u
    }

    private static func bezierDerivative(_ u: Double, p1: Double, p2: Double) -> Double {
        let v = 1 - u
        return 3 * v * v * p1 + 6 * v * u * (p2 - p1) + 3 * u * u * (1 - p2)
    }

 // MARK: - Drawing

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .idle:
            Self.idleCircle.stroke(kind.color, style: strokeStyle)
        case .running:
            ZStack {
                Self.runningArc.stroke(kind.color, style: strokeStyle)
                Self.runningDot.fill(kind.color)
            }
        case .approval:
            ZStack {
                Self.approvalShield.stroke(kind.color, style: strokeStyle)
                Self.approvalMark.stroke(kind.color, style: strokeStyle)
                Self.approvalDot.fill(kind.color)
            }
        case .answer:
            ZStack {
                Self.answerBubble.stroke(kind.color, style: strokeStyle)
                Self.answerDot.fill(kind.color)
            }
        case .notStarted:
            ZStack {
                Self.dashedCircle.stroke(
                    kind.color,
                    style: StrokeStyle(
                        lineWidth: 1.7,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [3.1, 2.7]
                    )
                )
                Self.plusMark.stroke(kind.color, style: strokeStyle)
            }
        case .offline:
            ZStack {
                Self.offlineCloud.stroke(kind.color, style: strokeStyle)
                Self.offlineSlash.stroke(kind.color, style: strokeStyle)
            }
        case .error:
            ZStack {
                Self.errorCircle.stroke(kind.color, style: strokeStyle)
                Self.errorCross.stroke(kind.color, style: strokeStyle)
            }
        }
    }

 // MARK: - Path data (24-unit view box, copied from the v6 design source)

    private static let idleCircle = circle(radius: 7.2)
    private static let dashedCircle = circle(radius: 7.2)
    private static let errorCircle = circle(radius: 8.1)

    private static let runningArc = SVGPath.path(from: "M12 4.7 A7.3 7.3 0 1 1 6.84 6.84")
    private static let runningDot = dot(x: 12, y: 12, radius: 1.75)

 /// Shield outline. The two rounded bottom halves are cubic beziers in the
 /// source SVG; SVGPath only parses M/L/H/V/A/Z, so they are appended with
 /// the exact control points here.
    private static let approvalShield: Path = {
        var path = SVGPath.path(from: "M12 3.2 l7.1 2.55 v5.35")
        path.addCurve(
            to: CGPoint(x: 12, y: 20.2),
            control1: CGPoint(x: 19.1, y: 15.3),
            control2: CGPoint(x: 16.2, y: 18.52)
        )
        path.addCurve(
            to: CGPoint(x: 4.9, y: 11.1),
            control1: CGPoint(x: 7.8, y: 18.52),
            control2: CGPoint(x: 4.9, y: 15.3)
        )
        path.addLine(to: CGPoint(x: 4.9, y: 5.75))
        path.closeSubpath()
        return path
    }()
    private static let approvalMark = SVGPath.path(from: "M12 7.9 v4.7")
    private static let approvalDot = dot(x: 12, y: 15.8, radius: 0.95)

 /// Speech bubble plus its question-mark hook. The hook's tail is a cubic in
 /// the source SVG; appended by hand for the same reason as the shield.
    private static let answerBubble: Path = {
        var path = SVGPath.path(
            from: "M20.4 11.55 a7.6 7.6 0 0 1 -11.05 6.79 L4.6 20 l1.62 -4.9 A7.6 7.6 0 1 1 20.4 11.55 z"
        )
        path.addPath(questionHook)
        return path
    }()
    private static let questionHook: Path = {
        var path = SVGPath.path(from: "M9.85 9.4 a2.2 2.2 0 1 1 3.12 1.97")
        path.addCurve(
            to: CGPoint(x: 11.95, y: 13.09),
            control1: CGPoint(x: 12.25, y: 11.74),
            control2: CGPoint(x: 11.95, y: 12.27)
        )
        return path
    }()
    private static let answerDot = dot(x: 11.95, y: 15.9, radius: 0.92)

    private static let plusMark = SVGPath.path(from: "M12 9.3 v5.4 M9.3 12 h5.4")

 /// Cloud outline authored as cubic beziers (the original three sweep=0
 /// arcs converted with W3C endpoint-to-center math). The SVGPath arc
 /// renderer uses an unsigned control-point coefficient for negative
 /// sweeps, so the same geometry expressed as arcs came out as a zigzag;
 /// cubics render identically on every parser and keep PinMark untouched.
    private static let offlineCloud = SVGPath.path(
        from: "M7.1 18.3 L16.45 18.3 "
            + "C18.3632 18.3059 19.9563 16.8335 20.1008 14.9257 "
            + "C20.2453 13.018 18.8922 11.3224 17 11.04 "
            + "C16.5089 8.8102 14.6568 7.1379 12.3887 6.8761 "
            + "C10.1205 6.6143 7.9362 7.8207 6.95 9.88 "
            + "C4.6249 9.9214 2.7736 11.8399 2.815 14.165 "
            + "C2.8564 16.4901 4.7749 18.3414 7.1 18.3 Z"
    )
    private static let offlineSlash = SVGPath.path(from: "M4.7 4.6 l14.6 14.8")

    private static let errorCross = SVGPath.path(from: "M9.55 9.55 l4.9 4.9 M14.45 9.55 l-4.9 4.9")

    private static func circle(radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: 12 - radius, y: 12 - radius, width: radius * 2, height: radius * 2))
    }

    private static func dot(x: CGFloat, y: CGFloat, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
}
