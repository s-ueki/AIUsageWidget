import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let codex = try UsageClient.parse(Data(#"{"rate_limit":{"primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_at":1791800000},"secondary_window":{"used_percent":0,"limit_window_seconds":604800}}}"#.utf8), service: .codex)
check(codex.windows.count == 2, "Codex windows")
check(codex.windows[0].remaining == 68, "remaining conversion")
check(codex.windows[0].title == "5時間", "window duration")
check(codex.windows[1].remaining == 100, "zero usage")
check(codex.windows[1].reset == nil, "unknown reset")
let claude = try UsageClient.parse(Data(#"{"five_hour":{"utilization":17.5,"resets_at":"2026-10-12T12:00:00.000Z"},"seven_day":{"utilization":95,"resets_at":"2026-10-15T12:00:00Z"}}"#.utf8), service: .claude)
check(claude.windows[0].remaining == 82.5, "fractional utilization")
check(claude.windows.allSatisfy { $0.reset != nil }, "ISO date variants")
for payload in ["{}", "{\"five_hour\":null}", "{\"five_hour\":{\"utilization\":120}}"] {
    do { _ = try UsageClient.parse(Data(payload.utf8), service: .claude); fatalError("invalid data accepted") }
    catch {}
}
// OAuth（Webログイン）
check(OAuthRequest.challenge("dBjftJeZ4CVP-mJ92K-3KxtT7UONBB0Igr2Kgq8SJzQ") == "_1xsJRlgYjIvx4ipCFPZvXlojONzf9Q4WfBBI3MXRnw", "PKCE S256 (openssl計算値と一致)")
let request = OAuthRequest(service: .codex, redirectURI: "http://localhost:1455/auth/callback")
let query = URLComponents(url: request.authorizeURL, resolvingAgainstBaseURL: false)!.queryItems!
check(query.contains { $0.name == "code_challenge" && $0.value == OAuthRequest.challenge(request.verifier) }, "authorize challenge")
check(query.contains { $0.name == "redirect_uri" && $0.value == "http://localhost:1455/auth/callback" }, "authorize redirect")
let parsed = try OAuthClient.parseCallback("http://localhost:1455/auth/callback?code=abc&state=xyz")
check(parsed.code == "abc" && parsed.state == "xyz", "callback URL")
let pasted = try OAuthClient.parseCallback(" abc#xyz\n")
check(pasted.code == "abc" && pasted.state == "xyz", "code#state")
do { _ = try OAuthClient.parseCallback("http://localhost/callback?error=access_denied"); fatalError("denied accepted") } catch OAuthError.denied {}
let claims = OAuthRequest.base64URL(try JSONSerialization.data(withJSONObject: ["exp": 2000000000, "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"]]))
let jwt = "e30.\(claims).sig"
let codexCredential = try OAuthClient.credential(from: ["access_token": jwt, "id_token": jwt, "refresh_token": "r1"], service: .codex, previous: nil)
check(codexCredential.accountID == "acct-1" && codexCredential.refreshToken == "r1", "Codex account ID")
check(codexCredential.expiresAt == Date(timeIntervalSince1970: 2000000000) && !codexCredential.needsRefresh, "JWT expiry")
let refreshed = try OAuthClient.credential(from: ["access_token": "t2", "expires_in": 60], service: .claude, previous: Credential(token: "t1", accountID: "", refreshToken: "r1"))
check(refreshed.refreshToken == "r1" && refreshed.needsRefresh, "refresh keeps token, near expiry")
check(!Credential(token: "manual", accountID: "").needsRefresh, "manual token")
print("PASS: Codex/Claude usage parsing, remaining conversion, reset dates, invalid/missing response handling, OAuth PKCE/callback/token parsing")

// Watchへ送る表示データと、通信順序・ログアウトによるデータ消去。
let firstSnapshot = WatchSnapshot(sentAt: Date(timeIntervalSince1970: 100), readings: [codex, claude])
let encodedSnapshot = try JSONEncoder().encode(firstSnapshot)
let decodedSnapshot = try WatchSnapshot.decode(encodedSnapshot)
check(decodedSnapshot.reading(for: .codex)?.windows[0].remaining == 68, "Watch remaining preserved")
check(!String(decoding: encodedSnapshot, as: UTF8.self).contains("token"), "Watch packet contains no credential fields")
let clearedSnapshot = WatchSnapshot(sentAt: Date(timeIntervalSince1970: 200), readings: [])
check(clearedSnapshot.isNewer(than: firstSnapshot), "logout packet replaces previous readings")
check(!firstSnapshot.isNewer(than: clearedSnapshot), "delayed old packet rejected")
check(!clearedSnapshot.isNewer(than: clearedSnapshot), "duplicate packet ignored")
let decodedClearedSnapshot = try WatchSnapshot.decode(JSONEncoder().encode(clearedSnapshot))
check(decodedClearedSnapshot.readings.isEmpty, "empty snapshot is valid")
check(WatchPeriod.weekly.window(in: codex)?.id == "secondary_window", "Codex weekly selection")
check(WatchPeriod.weekly.window(in: claude)?.id == "seven_day", "Claude weekly selection")
// Codex may return the weekly limit as primary and the five-hour limit as secondary.
let reversedCodex = try UsageClient.parse(Data(#"{"rate_limit":{"primary_window":{"used_percent":72,"limit_window_seconds":604800},"secondary_window":{"used_percent":13,"limit_window_seconds":18000}}}"#.utf8), service: .codex)
check(WatchPeriod.session.window(in: reversedCodex)?.remaining == 87, "Codex reversed five-hour limit")
check(WatchPeriod.weekly.window(in: reversedCodex)?.remaining == 28, "Codex reversed weekly limit")
let reversedPacket = try WatchSnapshot.decode(JSONEncoder().encode(WatchSnapshot(sentAt: Date(), readings: [reversedCodex])))
check(WatchPeriod.session.window(in: reversedPacket.reading(for: .codex))?.remaining == 87, "duration survives Watch transport")
// Existing cached snapshots have no durationSeconds field.
var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reversedCodex)) as! [String: Any]
legacyJSON["windows"] = (legacyJSON["windows"] as! [[String: Any]]).map { row in
    var row = row
    row.removeValue(forKey: "durationSeconds")
    return row
}
let legacyCodex = try JSONDecoder().decode(UsageReading.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
check(WatchPeriod.session.window(in: legacyCodex)?.remaining == 87, "legacy reversed five-hour limit")
check(WatchPeriod.weekly.window(in: legacyCodex)?.remaining == 28, "legacy reversed weekly limit")
var weeklyOnly = reversedCodex
weeklyOnly.windows.removeLast()
check(WatchPeriod.session.window(in: weeklyOnly) == nil, "weekly-only limit must not appear as five-hour")
var unknownDuration = reversedCodex
unknownDuration.windows = [UsageWindow(id: "primary_window", title: "5時間", used: 10, durationSeconds: 3600)]
check(WatchPeriod.session.window(in: unknownDuration) == nil, "known duration takes precedence over legacy title")
check(WatchPeriod.session.limitAbsent(in: weeklyOnly), "weekly-only Codex has no five-hour limit")
check(!WatchPeriod.weekly.limitAbsent(in: weeklyOnly), "existing weekly limit is retained")
var sessionOnly = codex
sessionOnly.windows.removeLast()
check(WatchPeriod.weekly.limitAbsent(in: sessionOnly), "session-only Codex has no weekly limit")
for period in WatchPeriod.allCases {
    check(!period.limitAbsent(in: nil), "missing reading is not unlimited")
    check(!period.limitAbsent(in: unknownDuration), "unknown duration is not unlimited")
    check(!period.limitAbsent(in: codex), "both limits exist")
}
var claudeWeeklyOnly = claude
claudeWeeklyOnly.windows.removeFirst()
check(WatchPeriod.session.limitAbsent(in: claudeWeeklyOnly), "Claude weekly-only limit")
var claudeSessionOnly = claude
claudeSessionOnly.windows.removeLast()
check(WatchPeriod.weekly.limitAbsent(in: claudeSessionOnly), "Claude session-only limit")
var invalidSnapshot = firstSnapshot
invalidSnapshot.readings = [codex, codex]
do { _ = try WatchSnapshot.decode(JSONEncoder().encode(invalidSnapshot)); fatalError("duplicate services accepted") } catch {}
invalidSnapshot = firstSnapshot
invalidSnapshot.version = 99
do { _ = try WatchSnapshot.decode(JSONEncoder().encode(invalidSnapshot)); fatalError("unknown version accepted") } catch {}
print("PASS: Watch snapshot serialization, credential exclusion, missing data, ordering, period selection, invalid packet rejection")

// 複数の完了イベントが同時に発生しても、継続を二重再開しない。
let raceWinner: Int = try await withCheckedThrowingContinuation { continuation in
    let completion = OneShotContinuation<Int>(continuation)
    DispatchQueue.concurrentPerform(iterations: 100) { value in
        completion.resume(with: .success(value))
    }
}
check((0..<100).contains(raceWinner), "concurrent completion returns one result")
do {
    let _: Int = try await withCheckedThrowingContinuation { continuation in
        let completion = OneShotContinuation<Int>(continuation)
        check(completion.resume(with: .failure(OAuthError.cancelled)), "first failure accepted")
        check(!completion.resume(with: .success(1)), "late success ignored after failure")
    }
    fatalError("cancellation was not propagated")
} catch OAuthError.cancelled {}
print("PASS: concurrent one-shot completion and late completion after cancellation")
