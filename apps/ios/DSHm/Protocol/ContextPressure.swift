import Foundation

/// v5.5 context-window usage derived from `projections.values.contextPressure`.
///
/// Wire shape (all fields optional; provider may not report usage yet):
/// ```json
/// { "pressureTokens": 12400, "projectedTokens": 13000, "contextWindow": 200000 }
/// ```
/// - `pressureTokens`: prompt size of the most recent request (uncached input +
///   cache read/write, excluding output).
/// - `projectedTokens`: estimated prompt size of the next request
///   (`pressureTokens` + locally sampled heuristic delta).
/// - `contextWindow`: capacity of the most recently recorded model route
///   (missing when no adapter reported it).
struct ContextPressureValue: Equatable, Sendable {
    var pressureTokens: Int?
    var projectedTokens: Int?
    var contextWindow: Int?

    init(
        pressureTokens: Int? = nil,
        projectedTokens: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.pressureTokens = pressureTokens
        self.projectedTokens = projectedTokens
        self.contextWindow = contextWindow
    }

    /// Parses `projections.values.contextPressure`.
    ///
    /// Returns `nil` when the projection is absent, is not an object, or carries
    /// none of the three known fields (nothing to display yet).
    init?(projection: JSONValue?) {
        guard let projection, projection.objectValue != nil else { return nil }
        let pressure = projection["pressureTokens"]?.int
        let projected = projection["projectedTokens"]?.int
        let window = projection["contextWindow"]?.int
        guard pressure != nil || projected != nil || window != nil else { return nil }
        self.init(pressureTokens: pressure, projectedTokens: projected, contextWindow: window)
    }

    /// Prompt tokens the next request will carry: the projection wins over the
    /// most recent provider report.
    var usedTokens: Int? { projectedTokens ?? pressureTokens }

    /// Rounded usage percentage; `nil` when usage or a positive window is unknown.
    ///
    /// Not clamped: a projected overshoot reports e.g. `150` rather than hiding
    /// the overflow.
    var percent: Int? {
        guard let usedTokens, let contextWindow, contextWindow > 0 else { return nil }
        return Int((Double(usedTokens) / Double(contextWindow) * 100).rounded())
    }

    /// v0.2.0 simplified status-strip cell: only the used percentage is shown.
    /// Four severity buckets drive the colour of the percentage text.
    enum UsageLevel: Equatable {
        case low        // < 50%
        case moderate   // 50% ..< 80%
        case high       // 80% ..< 90%
        case critical   // >= 90%
    }

    /// Severity bucket of `percent`; `nil` when usage or the window is unknown.
    var usageLevel: UsageLevel? {
        guard let percent else { return nil }
        if percent < 50 { return .low }
        if percent < 80 { return .moderate }
        if percent < 90 { return .high }
        return .critical
    }

    /// `6%` (or e.g. `150%` when the projection overshoots); `—` otherwise.
    var percentText: String {
        guard let percent else { return "—" }
        return "\(percent)%"
    }

    /// Compact window value (`1M`, `200k`); `nil` when the provider has not
    /// reported a positive capacity (the visual cell then shows `—`).
    var windowText: String? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        return Self.shortTokens(contextWindow)
    }

    /// v0.2.0 status-strip cell: window value + usage percentage, e.g. `1M · 53%`.
    ///
    /// - window + percent: `1M · 53%`
    /// - window known, usage not reported yet: `1M`
    /// - no window: `—`
    ///
    /// The visual cell renders the parts separately so the percentage keeps its
    /// four-bucket colour; VoiceOver keeps the precise `displayText`.
    var compactText: String {
        guard let windowText else { return "—" }
        guard let percent else { return windowText }
        return "\(windowText) · \(percent)%"
    }

    /// `12.4k / 200k · 6%`, `12.4k` (no window yet) or `—` (nothing reported).
    /// Still used for VoiceOver (the visual cell is simplified in v0.2.0).
    var displayText: String {
        guard let usedTokens else { return "—" }
        let usedText = Self.shortTokens(usedTokens)
        guard let contextWindow, contextWindow > 0 else { return usedText }
        let windowText = Self.shortTokens(contextWindow)
        guard let percent else { return "\(usedText) / \(windowText)" }
        return "\(usedText) / \(windowText) · \(percent)%"
    }

    /// Compact token count: `999` → `999`, `12400` → `12.4k`,
    /// `1200000` → `1.2M`. Locale independent; negative input clamps to `0`.
    static func shortTokens(_ value: Int) -> String {
        let clamped = max(0, value)
        if clamped < 1_000 { return "\(clamped)" }
        let thousands = Double(clamped) / 1_000
        if thousands < 999.95 { return short(thousands, suffix: "k") }
        let millions = Double(clamped) / 1_000_000
        return short(millions, suffix: "M")
    }

    private static func short(_ scaled: Double, suffix: String) -> String {
        let rounded = (scaled * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))\(suffix)" }
        return "\(rounded)\(suffix)"
    }
}

/// Pure lookups/merges for the throttled `session/list` refresh, kept free of
/// networking so they can be unit tested (v5.5 §14.5).
enum ContextPressureResolver {
    /// Finds the row of `sessionId` in a `session/list` response.
    ///
    /// Works for both normal sessions and subagent sessions: a subagent child is
    /// listed under its own child session id (`origin == "subagent"`), which is
    /// also the id used by `SessionFollowAddress.subagent(...).sessionId`.
    static func resolve(sessionId: String, sessions: [SessionListItem]) -> ContextPressureValue? {
        sessions.first { $0.sessionId == sessionId }?.contextPressure
    }

    /// Merges a refresh result into the last known value.
    ///
    /// - No row / no usable projection: keep `current` (avoids flicker while the
    ///   provider has not reported usage yet).
    /// - Partial projection: keep the missing fields from `current` so a refresh
    ///   that only knows the window does not blank out known usage.
    static func merge(
        current: ContextPressureValue?,
        incoming: ContextPressureValue?
    ) -> ContextPressureValue? {
        guard let incoming else { return current }
        guard let current else { return incoming }
        var merged = incoming
        if merged.usedTokens == nil {
            merged.pressureTokens = current.pressureTokens
            merged.projectedTokens = current.projectedTokens
        }
        if merged.contextWindow == nil {
            merged.contextWindow = current.contextWindow
        }
        return merged
    }

    /// One-call resolve + merge used by `SessionViewModel.refreshSessionListDerived`.
    static func refreshValue(
        current: ContextPressureValue?,
        sessionId: String,
        sessions: [SessionListItem]
    ) -> ContextPressureValue? {
        merge(
            current: current,
            incoming: resolve(sessionId: sessionId, sessions: sessions)
        )
    }
}
