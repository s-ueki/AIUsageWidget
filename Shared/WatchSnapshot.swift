import Foundation

/// Watchへは表示データだけを渡す。認証情報は含めない。
struct WatchSnapshot: Codable {
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
    func window(in reading: UsageReading?) -> UsageWindow? {
        guard let reading else { return nil }
        let id: String
        switch (reading.service, self) {
        case (.codex, .session): id = "primary_window"
        case (.codex, .weekly): id = "secondary_window"
        case (.claude, .session): id = "five_hour"
        case (.claude, .weekly): id = "seven_day"
        }
        return reading.windows.first { $0.id == id }
    }
}
