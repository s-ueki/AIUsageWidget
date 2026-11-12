import Foundation

/// プロバイダーごとの登録枠。既存のrawValueはアカウント1の保存キーとして維持する。
enum Service: String, Codable, CaseIterable, Identifiable {
    case codex, claude, codex2, claude2
    static let allCases: [Service] = [.codex, .codex2, .claude, .claude2]
    static let overviewAccounts: [Service] = [.codex, .claude]
    var id: String { rawValue }
    var isCodex: Bool { self == .codex || self == .codex2 }
    var accountNumber: Int { self == .codex2 || self == .claude2 ? 2 : 1 }
    var title: String { (isCodex ? "CODEX" : "CLAUDE") + String(accountNumber) }
}

struct UsageWindow: Codable, Identifiable {
    var id: String
    var title: String
    var used: Double
    var reset: Date?
    var durationSeconds: Double? = nil
    var remaining: Double { max(0, min(100, 100 - used)) }
}

struct UsageReading: Codable {
    var service: Service
    var windows: [UsageWindow]
    var fetchedAt: Date
    var plan: String? = nil
    /// 端末の時計が戻された場合（取得日時が未来）は新しいとみなさない。
    func isFresh(within age: TimeInterval, now: Date = Date()) -> Bool {
        let elapsed = now.timeIntervalSince(fetchedAt)
        return elapsed >= 0 && elapsed < age
    }
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
        let endpoint = service.isCodex
            ? "https://chatgpt.com/backend-api/wham/usage"
            : "https://api.anthropic.com/api/oauth/usage"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !service.isCodex { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        if service.isCodex && !accountID.isEmpty {
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

    /// 上限超過（100超）は残量0%として扱う。枠ごと捨てると「制限なし」と誤表示されるため。
    /// 負の値・数値以外は不正な応答として捨てる。
    static func clampedUsage(_ value: Any?) -> Double? {
        guard let used = value as? Double, used.isFinite, used >= 0 else { return nil }
        return min(100, used)
    }

    static func parse(_ data: Data, service: Service) throws -> UsageReading {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        var windows: [UsageWindow] = []
        if service.isCodex, let limit = root["rate_limit"] as? [String: Any] {
            for (key, fallback) in [("primary_window", "セッション"), ("secondary_window", "週間")] {
                guard let row = limit[key] as? [String: Any],
                      let used = clampedUsage(row["used_percent"]) else { continue }
                let seconds = row["limit_window_seconds"] as? Double
                let title = seconds == 18000 ? "5時間" : seconds == 604800 ? "週間" : fallback
                let reset = (row["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                windows.append(UsageWindow(id: key, title: title, used: used, reset: reset,
                                           durationSeconds: seconds))
            }
        } else if !service.isCodex {
            for (key, title) in [("five_hour", "5時間"), ("seven_day", "週間")] {
                guard let row = root[key] as? [String: Any],
                      let used = clampedUsage(row["utilization"]) else { continue }
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
        return UsageReading(service: service, windows: windows, fetchedAt: Date(), plan: root["plan_type"] as? String)
    }
}
