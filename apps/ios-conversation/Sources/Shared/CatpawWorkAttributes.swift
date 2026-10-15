import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// Shared between the app target and the `CatpawWidgets` extension.
/// `ContentState` is exactly the APNs `content-state` of docs/backend/proactive-tasks.md
/// (`{title, body, kind, taskID}`) so server `live_activity_update` pushes decode unchanged.
struct CatpawWorkAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var body: String
        /// Server event kind (`reminder_due|task_created|task_updated|agent_message`) or a client turn kind
        /// (`working|done|failed|needs_user`). Unknown kinds render as working.
        var kind: String
        var taskID: String

        /// Presentation-only mapping; not encoded.
        enum Status: Hashable { case working, needsUser, reminder, done, failed }
        var status: Status {
            switch kind {
            case Kind.done: return .done
            case Kind.failed: return .failed
            case Kind.needsUser: return .needsUser
            case "reminder_due": return .reminder
            default: return .working
            }
        }
        enum Kind {
            static let working = "working", done = "done", failed = "failed", needsUser = "needs_user"
            /// r11 client turn phases (status stays `.working`; they only change the cat head pose).
            static let thinking = "thinking", tool = "tool", writing = "writing"
        }
        /// Cat head pose for the Live Activity / Dynamic Island.
        enum Pose: Hashable { case thinking, tool, writing, waiting, done, failed }
        var pose: Pose {
            switch kind {
            case Kind.thinking, Kind.working: return .thinking
            case Kind.tool: return .tool
            case Kind.writing: return .writing
            case Kind.done: return .done
            case Kind.failed: return .failed
            default: return .waiting
            }
        }
    }
    var taskID: String
    var conversationID: String
    var title: String
}
#endif
