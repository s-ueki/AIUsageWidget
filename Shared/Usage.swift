import Foundation

enum Service: String, Codable, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

struct UsageWindow: Codable, Identifiable {
    var id: String
    var title: String
    var used: Double
    var reset: Date?
    var remaining: Double { max(0, min(100, 100 - used)) }
}

struct UsageReading: Codable {
    var service: Service
    var windows: [UsageWindow]
    var fetchedAt: Date
}

enum UsageError: LocalizedError {
    case noCredential, http(Int), invalidResponse
    var errorDescription: String? {
        switch self {
        case .noCredential: return "認証情報をアプリで登録してください。"
        case .http(let code):
            if code == 401 || code == 403 { return "認証が拒否されました（\(code)）。認証情報の更新や権限の確認が必要です。" }
            if code == 429 { return "取得回数の上限です。時間をおいて更新してください。" }
            return "サービスからエラーが返されました（\(code)）。"
        case .invalidResponse: return "使用量を読み取れませんでした。サービス側の仕様変更の可能性があります。"
        }
    }
}

enum UsageClient {
    static func fetch(_ service: Service, token: String, accountID: String = "") async throws -> UsageReading {
        guard !token.isEmpty else { throw UsageError.noCredential }
        let endpoint = service == .codex
            ? "https://chatgpt.com/backend-api/wham/usage"
            : "https://api.anthropic.com/api/oauth/usage"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if service == .claude { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        if service == .codex && !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        guard response.statusCode == 200 else { throw UsageError.http(response.statusCode) }
        return try parse(data, service: service)
    }

    static func parse(_ data: Data, service: Service) throws -> UsageReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        var windows: [UsageWindow] = []
        if service == .codex, let limit = root["rate_limit"] as? [String: Any] {
            for (key, fallback) in [("primary_window", "セッション"), ("secondary_window", "週間")] {
                guard let row = limit[key] as? [String: Any], let used = row["used_percent"] as? Double,
                      used.isFinite, (0...100).contains(used) else { continue }
                let seconds = row["limit_window_seconds"] as? Double
                let title = seconds == 18000 ? "5時間" : seconds == 604800 ? "週間" : fallback
                let reset = (row["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                windows.append(UsageWindow(id: key, title: title, used: used, reset: reset))
            }
        } else if service == .claude {
            for (key, title) in [("five_hour", "5時間"), ("seven_day", "週間")] {
                guard let row = root[key] as? [String: Any], let used = row["utilization"] as? Double,
                      used.isFinite, (0...100).contains(used) else { continue }
                var reset: Date?
                if let string = row["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    reset = formatter.date(from: string)
                    if reset == nil {
                        formatter.formatOptions = [.withInternetDateTime]
                        reset = formatter.date(from: string)
                    }
                }
                windows.append(UsageWindow(id: key, title: title, used: used, reset: reset))
            }
        }
        guard !windows.isEmpty else { throw UsageError.invalidResponse }
        return UsageReading(service: service, windows: windows, fetchedAt: Date())
    }
}
