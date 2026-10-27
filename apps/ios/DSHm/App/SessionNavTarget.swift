import Foundation
import SwiftUI

/// One `NavigationStack` path element (: native system navigation —
/// the user asked for Apple's own edge-swipe back and push/pop transition).
///
/// Level 1 is a top-level session; level 2 is a subagent child whose durable
/// parent is the level-1 element. The path is a **derived** view of
/// `AppModel.route` + `AppModel.subagentRoute` (single source of truth), so the
/// visible stack can never drift from the app state: pushes mutate the model
/// (`openSession` / `openSubagentSession` / deep links), and the binding's `set`
/// only ever translates a user-driven pop back into the model.
/// 详情页是否位于导航栈顶。
///
/// P0：父会话 detail 被子会话 push 覆盖后仍挂在栈里，若继续参与
/// 渲染/模型发布就是纯浪费（父会话此时可能仍在流式更新）。SessionDetailView
/// 读到 false 时暂停派生发布（数据加载/订阅不暂停）。默认 true（独立使用场景）。
private struct SessionDetailIsTopmostKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var sessionDetailIsTopmost: Bool {
        get { self[SessionDetailIsTopmostKey.self] }
        set { self[SessionDetailIsTopmostKey.self] = newValue }
    }
}

struct SessionNavTarget: Hashable {
    var address: SessionFollowAddress
 /// Non-nil only on the level-2 subagent push (nil on the parent element).
    var subagentContext: SubagentSessionContext?
}
