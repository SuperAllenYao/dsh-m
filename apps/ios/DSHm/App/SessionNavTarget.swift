import Foundation

/// One `NavigationStack` path element (: native system navigation —
/// the user asked for Apple's own edge-swipe back and push/pop transition).
///
/// Level 1 is a top-level session; level 2 is a subagent child whose durable
/// parent is the level-1 element. The path is a **derived** view of
/// `AppModel.route` + `AppModel.subagentRoute` (single source of truth), so the
/// visible stack can never drift from the app state: pushes mutate the model
/// (`openSession` / `openSubagentSession` / deep links), and the binding's `set`
/// only ever translates a user-driven pop back into the model.
struct SessionNavTarget: Hashable {
    var address: SessionFollowAddress
 /// Non-nil only on the level-2 subagent push (nil on the parent element).
    var subagentContext: SubagentSessionContext?
}
