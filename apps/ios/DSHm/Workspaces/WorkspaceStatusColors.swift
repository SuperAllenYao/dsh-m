import SwiftUI

extension Theme.Palette {
 /// Info blue (status scale, task-7): the "not started" (blank) session state.
 /// Declared here instead of Theme/Theme.swift so the workspace work owns its
 /// status-color token; still a Theme token (no raw color literals at call sites).
    static let info = Color(hex: 0x60A5FA)

 /// v5.4 session-list status scale: in-progress orange-amber.
    static let running = Color(hex: 0xF59E0B)

 /// v5.4 session-list status scale: waiting for a human answer (tool approval or
 /// user question) green.
    static let waiting = Color(hex: 0x34D399)
}
