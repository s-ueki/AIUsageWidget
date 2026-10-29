#if os(iOS)
import Foundation
import WatchConnectivity

@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()
    private var started = false

    func start() {
        guard WCSession.isSupported(), !started else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func payload() throws -> [String: Any] {
        let snapshot = WatchSnapshot(sentAt: Date(), readings: Service.allCases.compactMap(ReadingStore.read))
        return [WatchSnapshot.messageKey: try JSONEncoder().encode(snapshot)]
    }

    func publish() {
        guard WCSession.isSupported() else { return }
        start()
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let data = try payload()
            try session.updateApplicationContext(data)
            if session.isReachable { session.sendMessage(data, replyHandler: nil, errorHandler: { _ in }) }
        } catch {
            // 数値はKeychainに残る。次回のアプリ起動・更新・Watchからの要求時に再送する。
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in if error == nil { self.publish() } }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[WatchSnapshot.requestKey] as? Bool == true else { replyHandler([:]); return }
        Task { @MainActor in
            // Watchからの同期要求では、iPhoneが最後に取得した数値を返す。
            // OAuth更新を同時実行せず、iPhone側の認証状態を維持する。
            replyHandler((try? self.payload()) ?? [:])
        }
    }
}
#endif
