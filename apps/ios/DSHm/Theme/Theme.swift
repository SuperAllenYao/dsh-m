import SwiftUI

/// Design token layer.
///
/// Source of truth: docs/design/ui-baseline.zh.md §1 (v5, locked) and
/// design/mockups/v5-field-driven/. All colors / radii / spacing / type ramp live
/// here; components must not hard-code visual constants. Visual change = edit the
/// baseline doc first, then this file only.
enum Theme {

    // MARK: - Color tokens (baseline §1)

    enum Palette {
        /// bg
        static let background = Color(hex: 0x06080D)
        /// surface
        static let surface = Color(hex: 0x0A0F16)
        /// surface-2
        static let surfaceRaised = Color(hex: 0x0C121B)
        /// border
        static let border = Color(hex: 0x1A2230)
        /// border-strong
        static let borderStrong = Color(hex: 0x263241)
        /// The single accent color. Live state + primary CTA only.
        static let accent = Color(hex: 0x22D3EE)
        /// accent-ink — text/icon on top of accent fills.
        static let accentInk = Color(hex: 0x041014)
        /// accent-soft — rgba(34,211,238,.10)
        static let accentSoft = Color(hex: 0x22D3EE).opacity(0.10)
        /// accent-border — rgba(34,211,238,.28)
        static let accentBorder = Color(hex: 0x22D3EE).opacity(0.28)
        /// text
        static let textPrimary = Color(hex: 0xE6EDF7)
        /// text-2
        static let textSecondary = Color(hex: 0x93A1B5)
        /// text-3 (13px auxiliary only; lift to text-2 in implementation where needed)
        static let textTertiary = Color(hex: 0x5F6E84)
        /// warn
        static let warning = Color(hex: 0xFBBF24)
        static let warningMuted = Color(hex: 0xFBBF24).opacity(0.12)
        static let warningBorder = Color(hex: 0xFBBF24).opacity(0.32)
        /// danger
        static let danger = Color(hex: 0xF87171)
        static let dangerMuted = Color(hex: 0xF87171).opacity(0.12)
        static let dangerBorder = Color(hex: 0xF87171).opacity(0.28)
        /// Code / diff blocks reuse surface-2 but a touch darker than cards.
        static let codeBackground = Color(hex: 0x070B11)
        /// Success keeps the single-accent rule: no extra green.
        static let success = Color(hex: 0x22D3EE)
    }

    // MARK: - Radius tokens

    enum Radius {
        static let xl: CGFloat = 20   // r-xl (sheets, big cards)
        static let lg: CGFloat = 14   // r-md (cards, inputs)
        static let sm: CGFloat = 10   // r-sm (chips, inner blocks)
        static let pill: CGFloat = 999
    }

    // MARK: - Spacing tokens (4/8/12/16/20/24/32 grid, page inset 20)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Page horizontal inset per baseline §1.
        static let pageInset: CGFloat = 20
    }

    // MARK: - Size tokens (component heights shared by the composer + status strip)

    enum Size {
        /// Composer input single-line height == send/abort button height (v5.5 §14.1).
        static let control: CGFloat = 44
        /// Fixed height of the grid status strip above the composer (v5.5 §14.6).
        static let statusStrip: CGFloat = 40
    }

    // MARK: - Type ramp (baseline §1: body 14/1.5, title 26/700, card 15/650, min 13)

    enum Typography {
        /// Page title — 26/700.
        static let display = Font.system(size: 26, weight: .bold)
        /// Card / screen section title — 15/650 (semibold is the closest system weight).
        static let cardTitle = Font.system(size: 15, weight: .semibold)
        static let title = Font.system(size: 20, weight: .semibold)
        static let headline = Font.system(size: 15, weight: .semibold)
        /// Body — 14/1.5.
        static let body = Font.system(size: 14, weight: .regular)
        static let bodyMedium = Font.system(size: 14, weight: .medium)
        static let callout = Font.system(size: 13, weight: .regular)
        /// Minimum UI size (13).
        static let caption = Font.system(size: 13, weight: .regular)
        static let captionMedium = Font.system(size: 13, weight: .medium)
        static let label = Font.system(size: 12, weight: .medium)
        /// Mono is used for commands / code / diffs only.
        static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let button = Font.system(size: 15, weight: .semibold)
    }

    // MARK: - Motion tokens (baseline §1: 160–200ms, cubic-bezier(.2,.8,.2,1))

    enum Motion {
        static let quick = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.16)
        static let standard = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)
        /// v5.5 §14.3 subagent capsule: one linear turn per 1.2s, forever.
        /// Reduce Motion renders the ring statically instead (SubagentCapsuleButton).
        static let ringRotation = Animation.linear(duration: 1.2).repeatForever(autoreverses: false)
    }
}

// MARK: - Hex color

extension Color {
    /// Creates a color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
