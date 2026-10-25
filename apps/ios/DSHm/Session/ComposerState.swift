import SwiftUI

// MARK: - Composer button state machine (v5.4)

/// Which action the single composer button exposes.
enum ComposerAction: Equatable {
    case send
    case abort
}

/// Resolved state of the unified send/abort button.
///
/// User-confirmed v5.4 rules:
/// - draft has text -> send (enabled; queues while a turn runs)
/// - draft empty + turn running -> abort
/// - draft empty + turn idle -> send (disabled)
/// - unary prompt in flight -> spinner, disabled
struct ComposerButtonState: Equatable {
    var action: ComposerAction
    var isEnabled: Bool
    var showsSpinner: Bool = false

    static func resolve(draft: String, isRunning: Bool, sending: Bool) -> ComposerButtonState {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if sending {
            return ComposerButtonState(action: .send, isEnabled: false, showsSpinner: true)
        }
        if hasText {
            return ComposerButtonState(action: .send, isEnabled: true)
        }
        if isRunning {
            return ComposerButtonState(action: .abort, isEnabled: true)
        }
        return ComposerButtonState(action: .send, isEnabled: false)
    }
}

// MARK: - Client-side prompt queue (v5.4)

/// One message waiting for the current turn to finish. While a turn runs, sends
/// are queued on the client; tapping the queue bar turns the oldest one into an
/// immediate `session/prompt mode=steer`.
struct QueuedPrompt: Identifiable, Equatable {
    var id: String
    var text: String

    init(id: String = UUID().uuidString.lowercased(), text: String) {
        self.id = id
        self.text = text
    }

    var firstLine: String {
        PromptQueue.previewLine(text, limit: Int.max)
    }
}

/// Pure client-side FIFO of prompts (no networking) so the queue semantics are
/// unit-testable: enqueue -> take first (send/flush) -> optionally restore on
/// failure.
struct PromptQueue: Equatable {
    private(set) var items: [QueuedPrompt] = []

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
    var first: QueuedPrompt? { items.first }

 /// Thin-bar copy: `排队中 N 条 · <首行…> · 点击立即介入` (nil when empty).
    var bannerText: String? {
        guard let first else { return nil }
        return "排队中 \(count) 条 · \(PromptQueue.previewLine(first.text)) · 点击立即介入"
    }

 /// Localized display copy (the canonical `bannerText` stays Chinese for tests).
    var localizedBannerText: String? {
        guard let first else { return nil }
        return L10n.f("排队中 %lld 条 · %@ · 点击立即介入", count, PromptQueue.previewLine(first.text))
    }

    mutating func enqueue(text: String) {
        items.append(QueuedPrompt(text: text))
    }

 /// Removes and returns the oldest prompt (used for steer + turn-end flush).
    mutating func takeFirst() -> QueuedPrompt? {
        guard !items.isEmpty else { return nil }
        return items.removeFirst()
    }

 /// Puts a prompt back at the front after a failed send.
    mutating func restore(_ prompt: QueuedPrompt) {
        items.insert(prompt, at: 0)
    }

    mutating func removeAll() {
        items.removeAll()
    }

 /// First display line of a queued prompt, truncated for the thin bar.
    static func previewLine(_ text: String, limit: Int = 24) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "…" }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

/// When the next queued prompt must be flushed automatically: on the running ->
/// idle transition (turn/end), never while the turn is still running.
enum SessionQueuePolicy {
    static func shouldFlush(wasRunning: Bool, isRunning: Bool, queuedCount: Int) -> Bool {
        wasRunning && !isRunning && queuedCount > 0
    }
}

// MARK: - Connection indicator (v5.4)

/// Semantic connection states rendered as the session detail subtitle dot.
enum ConnectionStatusKind: Equatable {
    case connected
    case connecting
    case disconnected
    case unpaired

    static func kind(for phase: LinkService.Phase) -> ConnectionStatusKind {
        switch phase {
        case .connected: return .connected
        case .connecting, .reconnecting: return .connecting
        case .disconnected, .needsRepair: return .disconnected
        case .unpaired: return .unpaired
        }
    }
}

/// Colour + animation mapping for the connection dot (pure, unit-testable).
enum ConnectionIndicator {
    static func color(for kind: ConnectionStatusKind) -> Color {
        switch kind {
        case .connected: return Theme.Palette.accent       // 已连接 = accent 青
        case .connecting: return Theme.Palette.warning     // 连接中/重连 = warning 橙
        case .disconnected: return Theme.Palette.danger    // 已断开 = danger 红
        case .unpaired: return Theme.Palette.textTertiary  // 未配对 = 灰
        }
    }

    static func isPulsing(_ kind: ConnectionStatusKind) -> Bool {
        kind == .connecting
    }

    static func color(for phase: LinkService.Phase) -> Color {
        color(for: ConnectionStatusKind.kind(for: phase))
    }
}
