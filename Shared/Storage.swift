import Foundation
import Security

struct Credential: Codable {
    var token: String
    var accountID: String
    var refreshToken: String? = nil
    var expiresAt: Date? = nil
    var needsRefresh: Bool { refreshToken != nil && (expiresAt.map { $0.timeIntervalSinceNow < 300 } ?? false) }
}

/// アプリとウィジェットで共有するKeychain項目。無料のApple ID（Personal Team）でも使えるKeychain Sharingだけで受け渡します。
enum SharedKeychain {
    static func query(_ kind: String, _ service: Service) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: kind,
                                    kSecAttrAccount as String: service.rawValue,
                                    // macOSでもiOSと同じアクセスグループ方式のKeychainを使います。
                                    kSecUseDataProtectionKeychain as String: true]
        if let group = Bundle.main.object(forInfoDictionaryKey: "SharedKeychainGroup") as? String,
           !group.isEmpty, !group.contains("$(") { query[kSecAttrAccessGroup as String] = group }
        return query
    }
    static func read(_ kind: String, _ service: Service) -> Data? {
        var query = query(kind, service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func save(_ data: Data, _ kind: String, _ service: Service) throws {
        let base = query(kind, service)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw error(update) }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw error(status) }
    }
    static func delete(_ kind: String, _ service: Service) throws {
        let status = SecItemDelete(query(kind, service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    static func error(_ status: OSStatus) -> NSError {
        NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychainに保存・削除できませんでした（\(status)）。署名とKeychain Sharing設定を確認してください。"])
    }
}

enum CredentialStore {
    static let kind = "AIUsageWidget"
    static func read(_ service: Service) -> Credential? {
        SharedKeychain.read(kind, service).flatMap { try? JSONDecoder().decode(Credential.self, from: $0) }
    }
    static func save(_ credential: Credential, for service: Service) throws {
        try SharedKeychain.save(JSONEncoder().encode(credential), kind, service)
    }
    static func delete(_ service: Service) throws { try SharedKeychain.delete(kind, service) }
}

/// 取得した使用量。App Groupは無料アカウントで使えないため、これもKeychainで共有します。
enum ReadingStore {
    static let kind = "AIUsageWidget.reading"
    static func read(_ service: Service) -> UsageReading? {
        SharedKeychain.read(kind, service).flatMap { try? JSONDecoder().decode(UsageReading.self, from: $0) }
    }
    static func save(_ reading: UsageReading) throws {
        try SharedKeychain.save(JSONEncoder().encode(reading), kind, reading.service)
    }
    static func clear(_ service: Service) { try? SharedKeychain.delete(kind, service) }
}
