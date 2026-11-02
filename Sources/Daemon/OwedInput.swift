import Foundation
import GRDB

/// Text a session was given and hasn't typed: what was sent and a child's report. Taken for a session that isn't running, or
/// stops running, it waits here and is typed once it runs again (`LiveSession.giveBack`). Limit: a running session's is in
/// memory, so a crash of the background service loses it.
struct OwedInput: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var session: String, text: String, draft = false, paste = false, report = false
}
