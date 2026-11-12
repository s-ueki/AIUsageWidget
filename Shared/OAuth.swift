import Foundation
import CryptoKit
import Security

/// 各CLIの公式ログインと同じOAuth（PKCE）設定。非公開仕様のため、CLI側の変更で動かなくなる可能性があります。
struct OAuthConfig {
    var clientID: String
    var authorizeURL: String
    var tokenURL: String
    var scope: String
    var port: UInt16  // 0なら空いているポートを使う
    var callbackPath: String
    var extraParameters: [(String, String)]
    var loginHost: String

    static func of(_ service: Service) -> OAuthConfig {
        switch service {
        case .codex, .codex2:
            // Codex CLIと同じ登録。リダイレクト先はlocalhost:1455固定です。
            return OAuthConfig(clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
                               authorizeURL: "https://auth.openai.com/oauth/authorize",
                               tokenURL: "https://auth.openai.com/oauth/token",
                               scope: "openid profile email offline_access",
                               port: 1455, callbackPath: "/auth/callback",
                               extraParameters: [("id_token_add_organizations", "true"),
                                                 ("codex_cli_simplified_flow", "true"),
                                                 ("originator", "codex_cli_rs")],
                               loginHost: "chatgpt.com")
        case .claude, .claude2:
            // Claude Codeの「Claudeアカウントでログイン」と同じ登録。
            return OAuthConfig(clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                               authorizeURL: "https://claude.ai/oauth/authorize",
                               tokenURL: "https://platform.claude.com/v1/oauth/token",
                               scope: "org:create_api_key user:profile user:inference",
                               port: 0, callbackPath: "/callback",
                               extraParameters: [("code", "true")],
                               loginHost: "claude.ai")
        }
    }
    func redirectURI(port: UInt16) -> String { "http://localhost:\(port)\(callbackPath)" }
}

/// 1回分のログイン要求（PKCEのverifierとstateを保持）。
struct OAuthRequest {
    let service: Service
    let verifier = OAuthRequest.random(32)
    let state = OAuthRequest.random(32)
    let redirectURI: String

    var authorizeURL: URL {
        let config = OAuthConfig.of(service)
        var components = URLComponents(string: config.authorizeURL)!
        components.queryItems = [("response_type", "code"), ("client_id", config.clientID),
                                 ("redirect_uri", redirectURI), ("scope", config.scope),
                                 ("code_challenge", Self.challenge(verifier)),
                                 ("code_challenge_method", "S256"), ("state", state)]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
            + config.extraParameters.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthError: LocalizedError {
    case cancelled, noPendingLogin, invalidCallback, stateMismatch, denied(String), token(Int), invalidToken, portInUse
    var errorDescription: String? {
        switch self {
        case .cancelled: return "ログインを中止しました。"
        case .noPendingLogin: return "先に「Webでログイン」を開始してください。"
        case .invalidCallback: return "ログイン後のURLまたはコードを読み取れませんでした。"
        case .stateMismatch: return "ログイン要求が一致しません。もう一度「Webでログイン」からやり直してください。"
        case .denied(let reason): return "ログインが拒否されました（\(reason)）。"
        case .token(let code):
            if code == 400 || code == 401 { return "ログイン情報の確認・更新に失敗しました（\(code)）。再度ログインしてください。" }
            return "トークンを取得できませんでした（\(code)）。"
        case .invalidToken: return "トークンの応答を読み取れませんでした。サービス側の仕様変更の可能性があります。"
        case .portInUse: return "ログイン受付用のポートを開けませんでした。Codex CLIのログイン画面などが開いていれば閉じてから再試行してください。"
        }
    }
}

enum OAuthClient {
    /// コールバックURL（?code=…&state=…）、または「code#state」形式の貼り付け文字列を解釈します。
    static func parseCallback(_ input: String) throws -> (code: String, state: String?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let items = URLComponents(string: text)?.queryItems, !items.isEmpty {
            let value = { (name: String) in items.first { $0.name == name }?.value }
            if let error = value("error") { throw OAuthError.denied(value("error_description") ?? error) }
            if let code = value("code"), !code.isEmpty { return (code, value("state")) }
        }
        guard !text.isEmpty, !text.contains("://"), !text.contains(" ") else { throw OAuthError.invalidCallback }
        let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    static func exchange(callback: String, request: OAuthRequest) async throws -> Credential {
        let (code, state) = try parseCallback(callback)
        if let state, state != request.state { throw OAuthError.stateMismatch }
        let config = OAuthConfig.of(request.service)
        var body = ["grant_type": "authorization_code", "code": code, "client_id": config.clientID,
                    "redirect_uri": request.redirectURI, "code_verifier": request.verifier]
        if !request.service.isCodex { body["state"] = request.state }
        // Codexはフォーム形式、ClaudeはJSON形式で送ります（各CLIと同じ）。
        let json = try await post(config.tokenURL, body: body, form: request.service.isCodex)
        return try credential(from: json, service: request.service, previous: nil)
    }

    static func refresh(_ credential: Credential, service: Service) async throws -> Credential {
        guard let refreshToken = credential.refreshToken else { throw OAuthError.token(401) }
        let config = OAuthConfig.of(service)
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": config.clientID]
        if service.isCodex { body["scope"] = "openid profile email" }
        let json = try await post(config.tokenURL, body: body, form: false)
        return try self.credential(from: json, service: service, previous: credential)
    }

    static func credential(from json: [String: Any], service: Service, previous: Credential?) throws -> Credential {
        guard let token = json["access_token"] as? String, !token.isEmpty else { throw OAuthError.invalidToken }
        var accountID = previous?.accountID ?? ""
        let claims = (json["id_token"] as? String).flatMap(jwtClaims) ?? jwtClaims(token)
        let accessClaims = jwtClaims(token)
        let auth = (accessClaims?["https://api.openai.com/auth"] as? [String: Any])
            ?? (claims?["https://api.openai.com/auth"] as? [String: Any])
        let profile = accessClaims?["https://api.openai.com/profile"] as? [String: Any]
        let account = json["account"] as? [String: Any]
        let organization = json["organization"] as? [String: Any]
        let accountLabel = (account?["email_address"] as? String)
            ?? (account?["email"] as? String) ?? (claims?["email"] as? String)
            ?? (profile?["email"] as? String) ?? (claims?["name"] as? String)
            ?? previous?.accountLabel
        let plan = (auth?["chatgpt_plan_type"] as? String)
            ?? (organization?["organization_type"] as? String) ?? previous?.plan
        if service.isCodex {
            let claims = (json["id_token"] as? String).flatMap(jwtClaims) ?? jwtClaims(token)
            if let auth = claims?["https://api.openai.com/auth"] as? [String: Any],
               let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { accountID = id }
        }
        let expiresAt = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
            ?? (jwtClaims(token)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Credential(token: token, accountID: accountID,
                          refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
                          expiresAt: expiresAt, accountLabel: accountLabel, plan: plan,
                          profileFetchedAt: previous?.profileFetchedAt)
    }

    static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func post(_ url: String, body: [String: String], form: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if form {
            var components = URLComponents()
            components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponentsは「+」をエスケープしないため個別に置き換えます。
            request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OAuthError.invalidToken }
        guard response.statusCode == 200 else { throw OAuthError.token(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthError.invalidToken }
        return json
    }
}

/// プロセス内の同一キーの処理を共有し、呼び出し元ごとにキャンセルする。
/// 通常は最後の待機者が離れたときに停止する。認証更新は保存完了まで継続できる。
/// 世代IDで古い処理の完了を区別する。
actor SharedAsyncRequests<Key: Hashable & Sendable, Value: Sendable> {
    private struct Request {
        let generation: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var requests: [Key: Request] = [:]
    private let cancelWhenUnobserved: Bool

    init(cancelWhenUnobserved: Bool = true) {
        self.cancelWhenUnobserved = cancelWhenUnobserved
    }

    func waiterCount(for key: Key) -> Int { requests[key]?.waiters.count ?? 0 }

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let waiter = UUID()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if requests[key] != nil {
                    requests[key]?.waiters[waiter] = continuation
                } else {
                    let generation = UUID()
                    let task = Task {
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        self.finish(key, generation: generation, result: result)
                    }
                    requests[key] = Request(generation: generation, task: task, waiters: [waiter: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancel(key, waiter: waiter) }
        }
        // 完了とキャンセルが競合した場合も、キャンセルされた呼び出し元には結果を返さない。
        try Task.checkCancellation()
        return value
    }

    private func cancel(_ key: Key, waiter: UUID) {
        guard var request = requests[key], let continuation = request.waiters.removeValue(forKey: waiter) else { return }
        if request.waiters.isEmpty && cancelWhenUnobserved {
            requests.removeValue(forKey: key)
            request.task.cancel()
        } else {
            requests[key] = request
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ key: Key, generation: UUID, result: Result<Value, Error>) {
        guard let request = requests[key], request.generation == generation else { return }
        requests.removeValue(forKey: key)
        for continuation in request.waiters.values { continuation.resume(with: result) }
    }
}

/// 保存済みの認証情報で使用量を取得します。期限切れ間近・401時は更新用トークンで自動更新します。
enum UsageFetcher {
    /// ウィジェットが通信せずに保存済みの数値を使う期間。
    static let widgetCacheAge: TimeInterval = 5 * 60

    private static let inFlight = SharedAsyncRequests<Service, UsageReading>()
    // 更新送信後のキャンセルで、ローテーション済みのトークンを失わないようにする。
    // 待機者が0人でも登録を維持し、新しい要求にも同じ更新を共有する。
    // OSによるプロセスの停止・終了や通信断まで防ぐものではない。
    private static let tokenRefreshes = SharedAsyncRequests<Service, Credential>(cancelWhenUnobserved: false)

    static func fetch(_ service: Service) async throws -> UsageReading {
        try await inFlight.value(for: service) { try await fetchNow(service) }
    }

    private static func fetchNow(_ service: Service) async throws -> UsageReading {
        guard var credential = CredentialStore.read(service) else { throw UsageError.noCredential }
        if credential.needsRefresh { credential = try await refresh(credential, service) }
        let reading: UsageReading
        do {
            reading = try await UsageClient.fetch(service, token: credential.token, accountID: credential.accountID)
        } catch UsageError.http(let code) where (code == 401 || code == 403) && credential.refreshToken != nil {
            credential = try await refresh(credential, service)
            reading = try await UsageClient.fetch(service, token: credential.token, accountID: credential.accountID)
        }
        // 既存の保存データでもJWTに含まれる表示情報を復元する。
        var display = (try? OAuthClient.credential(from: ["access_token": credential.token], service: service, previous: credential)) ?? credential
        if !service.isCodex,
           display.profileFetchedAt.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            // 表示用情報の失敗で、取得済みの使用量までエラーにしない。
            if let profile = try? await AccountDisplay.fetchClaudeProfile(token: credential.token) {
                display.accountLabel = profile.account ?? display.accountLabel
                display.plan = profile.plan ?? display.plan
                display.profileFetchedAt = Date()
            }
        }
        if let plan = reading.plan { display.plan = plan }
        // ログイン変更・ログアウト中に古い資格情報を書き戻さない。
        if var latest = CredentialStore.read(service), latest.token == credential.token {
            latest.accountLabel = display.accountLabel
            latest.plan = display.plan
            latest.profileFetchedAt = display.profileFetchedAt
            try? CredentialStore.save(latest, for: service)
        }
        return reading
    }

    static func refresh(_ credential: Credential, _ service: Service) async throws -> Credential {
        try await tokenRefreshes.value(for: service) {
            // 待機中に別の取得が更新済みなら、その認証情報を再利用する。
            guard let current = CredentialStore.read(service) else { throw UsageError.noCredential }
            if current.token != credential.token || current.refreshToken != credential.refreshToken { return current }
            do {
                let updated = try await OAuthClient.refresh(current, service: service)
                // ログアウトや別アカウントへのログイン後に古い認証情報を書き戻さない。
                guard let latest = CredentialStore.read(service) else { throw UsageError.noCredential }
                guard latest.token == current.token, latest.refreshToken == current.refreshToken else { return latest }
                // リクエストからKeychain保存までを共有Task内で完了させる。
                try CredentialStore.save(updated, for: service)
                return updated
            } catch {
                // 別プロセスで更新済みの場合の救済。プロセス間の完全な排他ではない。
                if let latest = CredentialStore.read(service), latest.token != current.token { return latest }
                throw error
            }
        }
    }
}


/// 複数のコールバックが競合しても、継続を再開するのは一度だけ。
/// 可変状態はすべてlockで保護し、resume自体はロックの外で実行する。
final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}


/// 表示用情報のみ。プランが分からない場合は残量から推測しない。
enum AccountDisplay {
    static func planName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "プラン未取得" }
        switch raw.lowercased() {
        case "free", "claude_free": return "Free"
        case "plus": return "Plus"
        case "pro", "claude_pro": return "Pro"
        case "max", "claude_max": return "Max"
        case "team", "claude_team": return "Team"
        case "enterprise", "claude_enterprise": return "Enterprise"
        case "business": return "Business"
        case "edu": return "Edu"
        default: return raw
        }
    }

    static func claudeProfile(_ json: [String: Any]) -> (account: String?, plan: String?) {
        let account = json["account"] as? [String: Any]
        let organization = json["organization"] as? [String: Any]
        return ((account?["email"] as? String) ?? (account?["email_address"] as? String),
                organization?["organization_type"] as? String)
    }

    static func fetchClaudeProfile(token: String) async throws -> (account: String?, plan: String?) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 5
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        return claudeProfile(json)
    }
}
