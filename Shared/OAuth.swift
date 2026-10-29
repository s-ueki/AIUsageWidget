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
        case .codex:
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
        case .claude:
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
        if request.service == .claude { body["state"] = request.state }
        // Codexはフォーム形式、ClaudeはJSON形式で送ります（各CLIと同じ）。
        let json = try await post(config.tokenURL, body: body, form: request.service == .codex)
        return try credential(from: json, service: request.service, previous: nil)
    }

    static func refresh(_ credential: Credential, service: Service) async throws -> Credential {
        guard let refreshToken = credential.refreshToken else { throw OAuthError.token(401) }
        let config = OAuthConfig.of(service)
        var body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": config.clientID]
        if service == .codex { body["scope"] = "openid profile email" }
        let json = try await post(config.tokenURL, body: body, form: false)
        return try self.credential(from: json, service: service, previous: credential)
    }

    static func credential(from json: [String: Any], service: Service, previous: Credential?) throws -> Credential {
        guard let token = json["access_token"] as? String, !token.isEmpty else { throw OAuthError.invalidToken }
        var accountID = previous?.accountID ?? ""
        if service == .codex {
            let claims = (json["id_token"] as? String).flatMap(jwtClaims) ?? jwtClaims(token)
            if let auth = claims?["https://api.openai.com/auth"] as? [String: Any],
               let id = auth["chatgpt_account_id"] as? String, !id.isEmpty { accountID = id }
        }
        let expiresAt = (json["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
            ?? (jwtClaims(token)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return Credential(token: token, accountID: accountID,
                          refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
                          expiresAt: expiresAt)
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

/// 保存済みの認証情報で使用量を取得します。期限切れ間近・401時は更新用トークンで自動更新します。
enum UsageFetcher {
    static func fetch(_ service: Service) async throws -> UsageReading {
        guard var credential = CredentialStore.read(service) else { throw UsageError.noCredential }
        if credential.needsRefresh { credential = try await refresh(credential, service) }
        do {
            return try await UsageClient.fetch(service, token: credential.token, accountID: credential.accountID)
        } catch UsageError.http(let code) where (code == 401 || code == 403) && credential.refreshToken != nil {
            credential = try await refresh(credential, service)
            return try await UsageClient.fetch(service, token: credential.token, accountID: credential.accountID)
        }
    }

    static func refresh(_ credential: Credential, _ service: Service) async throws -> Credential {
        do {
            let updated = try await OAuthClient.refresh(credential, service: service)
            try CredentialStore.save(updated, for: service)
            return updated
        } catch {
            // アプリとウィジェットが同時に更新した場合、先に保存された新しいトークンを使います。
            if let latest = CredentialStore.read(service), latest.token != credential.token { return latest }
            throw error
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
