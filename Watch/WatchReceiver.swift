import Combine
import Foundation
import WatchConnectivity
import WidgetKit
import WatchKit

@MainActor
final class WatchReceiver: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchReceiver()
    @Published private(set) var snapshot = WatchStore.read()
    @Published private(set) var status = "iPhoneでアプリを開き、使用量を更新してください。"
    @Published private(set) var syncing = false
    private var started = false
    private var requestID: UUID?
    private var pendingObservation: NSKeyValueObservation?
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    func start() {
        guard WCSession.isSupported(), !started else { return }
        started = true
        WCSession.default.delegate = self
        pendingObservation = WCSession.default.observe(\.hasContentPending, options: [.new]) { _, _ in
            Task { @MainActor in self.completeBackgroundTasks() }
        }
        WCSession.default.activate()
    }

    func handle(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTasks.append(task)
        start()
        completeBackgroundTasks()
    }

    private func completeBackgroundTasks() {
        guard WCSession.default.activationState == .activated,
              !WCSession.default.hasContentPending else { return }
        for task in backgroundTasks { task.setTaskCompletedWithSnapshot(false) }
        backgroundTasks.removeAll()
    }

    func requestSync() {
        start()
        guard !syncing else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            status = "iPhoneと接続待ちです。iPhoneでアプリを開いてください。"
            return
        }
        let id = UUID()
        requestID = id
        syncing = true
        status = "iPhoneの取得済みデータを同期中…"
        session.sendMessage([WatchSnapshot.requestKey: true], replyHandler: { message in
            let data = message[WatchSnapshot.messageKey] as? Data
            Task { @MainActor in
                guard self.requestID == id else { return }
                self.requestID = nil
                self.syncing = false
                if let data { self.receive(data) }
                else { self.status = "データを受信できませんでした。iPhoneでアプリを更新してください。" }
            }
        }, errorHandler: { _ in
            Task { @MainActor in self.finishRequest(id) }
        })
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self.finishRequest(id)
        }
    }

    private func finishRequest(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        syncing = false
        status = "同期できませんでした。iPhoneでアプリを開いて再度お試しください。"
    }

    private func receive(_ data: Data) {
        defer { completeBackgroundTasks() }
        do {
            let incoming = try WatchSnapshot.decode(data)
            guard incoming.isNewer(than: snapshot) else { return }
            try WatchStore.save(incoming)
            snapshot = incoming
            status = incoming.readings.isEmpty ? "iPhoneでログインし、使用量を更新してください。" : "iPhoneの取得済みデータを表示しています。"
            WidgetCenter.shared.reloadAllTimelines()
        } catch { status = "受信データを保存できませんでした。署名とKeychain共有を確認してください。" }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let data = session.receivedApplicationContext[WatchSnapshot.messageKey] as? Data
        Task { @MainActor in
            if let data { self.receive(data) }
            if error == nil { self.requestSync() }
            self.completeBackgroundTasks()
        }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchSnapshot.messageKey] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchSnapshot.messageKey] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchSnapshot.messageKey] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }
}
