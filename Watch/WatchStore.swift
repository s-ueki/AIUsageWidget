import Foundation

enum WatchStore {
    private static let kind = "AIUsageWidget.watchSnapshot"
    static func read() -> WatchSnapshot? {
        SharedKeychain.read(kind, .codex).flatMap { try? WatchSnapshot.decode($0) }
    }
    static func save(_ snapshot: WatchSnapshot) throws {
        try SharedKeychain.save(JSONEncoder().encode(snapshot), kind, .codex)
    }
}
