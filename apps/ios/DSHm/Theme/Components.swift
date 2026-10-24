import SwiftUI

// MARK: - Surfaces

/// Standard card surface: surface fill + hairline border + r-md radius.
struct CardSurface: ViewModifier {
    var emphasized: Bool = false
    var radius: CGFloat = Theme.Radius.lg
    var padding: CGFloat? = Theme.Spacing.m

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(emphasized ? Theme.Palette.accentBorder : Theme.Palette.border, lineWidth: 1)
            )
    }
}

extension View {
    func cardSurface(emphasized: Bool = false, radius: CGFloat = Theme.Radius.lg, padding: CGFloat? = Theme.Spacing.m) -> some View {
        modifier(CardSurface(emphasized: emphasized, radius: radius, padding: padding))
    }

 /// Applies the single-accent CTA glow (baseline §1: <=1 per screen, area <5%).
    func accentGlow(active: Bool = true) -> some View {
        shadow(color: active ? Theme.Palette.accent.opacity(0.35) : .clear, radius: 12, x: 0, y: 2)
    }
}

// MARK: - Status

struct StatusDot: View {
    var color: Color = Theme.Palette.accent
    var size: CGFloat = 6
    var pulsing: Bool = false

    @State private var visible = true

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulsing && !visible ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: visible)
            .onAppear {
                if pulsing { visible = false }
            }
            .accessibilityHidden(true)
    }
}

/// Small pill chip (approval badge, permission chip, counts).
struct Chip: View {
    var text: String
    var color: Color = Theme.Palette.textSecondary
    var background: Color = Theme.Palette.surfaceRaised
    var borderColor: Color = Theme.Palette.border
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(Theme.Typography.label)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 1))
    }
}

struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(L10n.t(text))
            .font(Theme.Typography.captionMedium)
            .foregroundStyle(Theme.Palette.textTertiary)
            .textCase(nil)
    }
}

// MARK: - Buttons

/// Primary CTA: accent fill, accent-ink label. Glow is opt-in per screen.
struct PrimaryButtonStyle: ButtonStyle {
    var glow: Bool = false
    var enabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .foregroundStyle(enabled ? Theme.Palette.accentInk : Theme.Palette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(enabled ? Theme.Palette.accent : Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .accentGlow(active: glow && enabled)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

/// Secondary / destructive outline button.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.textPrimary
    var border: Color = Theme.Palette.borderStrong
    var width: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .foregroundStyle(tint)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
            .frame(height: 46)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Tool glyphs (v5 05: tool-call rows use a glyph + name)

enum ToolGlyph {
    static func symbol(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "bash", "run_code", "job_output", "job_kill", "job_list": return "terminal"
        case "read": return "doc.text"
        case "edit", "write": return "square.and.pencil"
        case "grep": return "magnifyingglass"
        case "glob": return "folder"
        case "web_search": return "globe"
        case "web_fetch": return "safari"
        case "read_image": return "photo"
        case "todo_write": return "checklist"
        case "subagent", "spawn_teammate", "send_message", "wait_agent", "interrupt_agent", "list_agents": return "person.2"
        case "agent", "task": return "person.2"
        case "present": return "shippingbox"
        case "ask_user_question": return "questionmark.bubble"
        default: return "wrench.and.screwdriver"
        }
    }

    static func displayName(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "bash": return "Bash"
        case "run_code": return "Run code"
        case "read": return "Read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "web_search": return "Web search"
        case "web_fetch": return "Web fetch"
        case "read_image": return "Read image"
        case "todo_write": return "Todo"
        case "present": return "Deliverables"
        case "ask_user_question": return "Ask"
        default: return toolName
        }
    }
}

// MARK: - Empty / error states

struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(L10n.t(title))
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Palette.textSecondary)
            if let message {
                Text(L10n.t(message))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xxl)
    }
}

struct InlineErrorView: View {
    var message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.danger)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let retry {
                Button(L10n.t("重试"), action: retry)
                    .font(Theme.Typography.captionMedium)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(Theme.Spacing.s)
        .background(Theme.Palette.dangerMuted, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.dangerBorder, lineWidth: 1))
    }
}


// MARK: - Brand / screen chrome

/// App mark used in the top-left of screens ("DSH·m" with accent glyph).
struct BrandMark: View {
    var showWordmark: Bool = true

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.Palette.accentSoft)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.Palette.accentBorder, lineWidth: 1))
                Text(">_")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .frame(width: 30, height: 30)
            if showWordmark {
                Text("DSH·m")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DSH-m")
    }
}

/// Connection state pill: dot + label (+ optional detail).
struct ConnectionStatusPill: View {
    var phase: LinkService.Phase
    var detail: String? = nil

    private var dotColor: Color {
        switch phase {
        case .connected: return Theme.Palette.accent
        case .connecting, .reconnecting: return Theme.Palette.warning
        case .unpaired, .disconnected: return Theme.Palette.textTertiary
        case .needsRepair: return Theme.Palette.danger
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: dotColor, size: 6, pulsing: phase.isBusy)
            Text(phase.label)
                .font(Theme.Typography.captionMedium)
                .foregroundStyle(phase.isConnected ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
 // The brand row now also carries the app version, so the pill must
 // stay single-line and let the host detail truncate instead.
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 6)
        .background(Theme.Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.border, lineWidth: 1))
        .accessibilityIdentifier("connection-status")
    }
}

/// Big screen title stack (display + subtitle).
struct ScreenTitle: View {
    var title: String
    var subtitle: String?
 /// workspace list: place the subtitle on the title's right on the
 /// same line (trailing-truncated) instead of stacking it underneath.
    var subtitleInline: Bool = false

    var body: some View {
        if subtitleInline {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                titleText
                if let subtitle, !subtitle.isEmpty {
                    Text(L10n.t(subtitle))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                titleText
                if let subtitle, !subtitle.isEmpty {
                    Text(L10n.t(subtitle))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var titleText: some View {
        Text(L10n.t(title))
            .font(Theme.Typography.display)
            .foregroundStyle(Theme.Palette.textPrimary)
    }
}

/// Folder glyph for a workspace group header.
///
/// SF Symbols ships no open-folder glyph, so the glyph is self-drawn from one
/// fixed back plate (the closed folder silhouette) plus **one animatable front
/// cover**. On toggle the cover's outline morphs from the closed silhouette into
/// the tilted open position — revealing the back plate's tab/lid — while the
/// tint cross-fades from textTertiary to accent. Both directions are driven by
/// `Theme.Motion.folder`: it is a single icon changing shape, never a symbol
/// swap, and the 18x15 pt canvas keeps the row from shifting.
struct WorkspaceFolderIcon: View {
    var expanded: Bool

    private static let glyphSize = CGSize(width: 18, height: 15)

    private var progress: CGFloat { expanded ? 1 : 0 }

    var body: some View {
        ZStack {
 // Back plate = closed folder silhouette. It sits behind the closed
 // cover and is revealed above it once the cover swings open.
            WorkspaceFolderBackPlate()
                .fill(Theme.Palette.textTertiary.opacity(0.10))
                .overlay(WorkspaceFolderBackPlate().stroke(Theme.Palette.textTertiary, lineWidth: 1.1))
                .opacity(expanded ? 0 : 1)
            WorkspaceFolderBackPlate()
                .fill(Theme.Palette.accent.opacity(0.14))
                .overlay(WorkspaceFolderBackPlate().stroke(Theme.Palette.accent.opacity(0.65), lineWidth: 0.9))
                .opacity(expanded ? 1 : 0)
 // Front cover — the animated part. Gray outline fades out while the
 // accent fill fades in; the outline itself interpolates closed→open.
            WorkspaceFolderFrontCover(progress: progress)
                .stroke(Theme.Palette.textTertiary, lineWidth: 1.1)
                .opacity(expanded ? 0 : 1)
            WorkspaceFolderFrontCover(progress: progress)
                .fill(Theme.Palette.accent)
                .opacity(expanded ? 1 : 0)
        }
        .frame(width: Self.glyphSize.width, height: Self.glyphSize.height)
        .animation(Theme.Motion.folder, value: expanded)
        .accessibilityHidden(true)
    }
}

/// Back plate: tab + body silhouette; identical to the closed icon outline, so
/// the closed cover sits exactly on top of it.
private struct WorkspaceFolderBackPlate: Shape {
    func path(in rect: CGRect) -> Path {
        Self.polygon(Self.points, in: rect)
    }

    static let points: [CGPoint] = [
        CGPoint(x: 0.06, y: 0.24),
        CGPoint(x: 0.44, y: 0.24),
        CGPoint(x: 0.52, y: 0.34),
        CGPoint(x: 0.94, y: 0.34),
        CGPoint(x: 0.94, y: 0.88),
        CGPoint(x: 0.84, y: 0.94),
        CGPoint(x: 0.16, y: 0.94),
        CGPoint(x: 0.06, y: 0.88)
    ]

    static func polygon(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in points.enumerated() {
            let resolved = CGPoint(x: rect.minX + point.x * rect.width,
                                   y: rect.minY + point.y * rect.height)
            if index == 0 {
                path.move(to: resolved)
            } else {
                path.addLine(to: resolved)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// Front cover outline: animates between the closed silhouette and the tilted
/// open cover position (top edge swings down/out, revealing the back plate).
private struct WorkspaceFolderFrontCover: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        let points = zip(Self.closedPoints, Self.openPoints).map { closed, open in
            CGPoint(x: closed.x + (open.x - closed.x) * clamped,
                    y: closed.y + (open.y - closed.y) * clamped)
        }
        return WorkspaceFolderBackPlate.polygon(points, in: rect)
    }

 /// Closed: the front of the folder, coincident with the back plate.
    private static let closedPoints: [CGPoint] = [
        CGPoint(x: 0.06, y: 0.24),
        CGPoint(x: 0.44, y: 0.24),
        CGPoint(x: 0.52, y: 0.34),
        CGPoint(x: 0.94, y: 0.34),
        CGPoint(x: 0.94, y: 0.88),
        CGPoint(x: 0.84, y: 0.94),
        CGPoint(x: 0.16, y: 0.94),
        CGPoint(x: 0.06, y: 0.88)
    ]

 /// Open: the cover has swung down/out; its sloped top edge reveals the lid.
    private static let openPoints: [CGPoint] = [
        CGPoint(x: 0.02, y: 0.48),
        CGPoint(x: 0.36, y: 0.44),
        CGPoint(x: 0.52, y: 0.44),
        CGPoint(x: 0.96, y: 0.40),
        CGPoint(x: 0.96, y: 0.88),
        CGPoint(x: 0.84, y: 0.94),
        CGPoint(x: 0.16, y: 0.94),
        CGPoint(x: 0.02, y: 0.88)
    ]
}

// MARK: - Formatters

enum DisplayFormat {
    static func relativeTime(_ epochMillis: Int64?) -> String {
        guard let epochMillis else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = L10n.displayLocale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func clock(_ epochMillis: Int64?) -> String {
        guard let epochMillis else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func bytes(_ count: Int?) -> String {
        guard let count else { return "" }
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / 1024 / 1024)
    }

    static func duration(_ millis: Int64?) -> String {
        guard let millis else { return "" }
        if millis < 1000 { return "\(millis)ms" }
        return String(format: "%.1fs", Double(millis) / 1000)
    }
}
