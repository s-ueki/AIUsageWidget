import Foundation

/// Watchへは表示データだけを渡す。認証情報は含めない。
struct WatchSnapshot: Codable {
    /// Watchアプリと文字盤で共通のデータ鮮度判定（90分）。
    static let staleInterval: TimeInterval = 90 * 60
    static let messageKey = "aiUsageSnapshot"
    static let requestKey = "requestAIUsageSnapshot"
    var version = 1
    var sentAt: Date
    var readings: [UsageReading]

    func reading(for service: Service) -> UsageReading? {
        readings.first { $0.service == service }
    }

    static func decode(_ data: Data) throws -> WatchSnapshot {
        guard data.count <= 64 * 1024 else { throw UsageError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.sentAt.timeIntervalSince1970.isFinite,
              value.readings.count <= Service.allCases.count,
              Set(value.readings.map(\.service)).count == value.readings.count else {
            throw UsageError.invalidResponse
        }
        for reading in value.readings {
            guard reading.fetchedAt.timeIntervalSince1970.isFinite,
                  !reading.windows.isEmpty, reading.windows.count <= 10 else { throw UsageError.invalidResponse }
            for window in reading.windows {
                guard window.used.isFinite, (0...100).contains(window.used),
                      window.id.count <= 100, window.title.count <= 100,
                      window.reset?.timeIntervalSince1970.isFinite != false else { throw UsageError.invalidResponse }
            }
        }
        return value
    }

    func isNewer(than previous: WatchSnapshot?) -> Bool {
        previous.map { sentAt > $0.sentAt } ?? true
    }
}

enum WatchPeriod: String, CaseIterable {
    case session, weekly
    var title: String { self == .session ? "5時間" : "週間" }
    /// A reading containing only the other known period represents an absent limit.
    /// Missing readings and unrecognized periods must remain unknown.
    func limitAbsent(in reading: UsageReading?) -> Bool {
        guard let reading, reading.windows.count == 1, window(in: reading) == nil else { return false }
        let other: WatchPeriod = self == .session ? .weekly : .session
        return other.window(in: reading) != nil
    }
    func window(in reading: UsageReading?) -> UsageWindow? {
        guard let reading else { return nil }
        if reading.service.isCodex {
            // primary/secondary are not period identifiers. Prefer API duration.
            let seconds: Double = self == .session ? 18000 : 604800
            if let window = reading.windows.first(where: { $0.durationSeconds == seconds }) {
                return window
            }
            // Older iPhone versions send only the title derived from the duration.
            return reading.windows.first {
                $0.durationSeconds == nil &&
                    ($0.title == title || (self == .session && $0.title == "セッション"))
            }
        }
        let id = self == .session ? "five_hour" : "seven_day"
        return reading.windows.first { $0.id == id }
    }
}
