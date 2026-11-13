import Combine
import Foundation
import WatchConnectivity
import WidgetKit
import WatchKit
import OSLog

@MainActor
final class WatchReceiver: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchReceiver()
    @Published private(set) var snapshot = WatchStore.read()
    @Published private(set) var status = "iPhoneでアプリを開き、使用量を更新してください。"
    @Published private(set) var syncing = false
    private let logger = Logger(subsystem: "com.s-ueki7.aiusage.watch", category: "BackgroundRefresh")
    private let refreshDateKey = "watch.nextBackgroundRefresh"
    private var refreshTasks: [UUID: WKApplicationRefreshBackgroundTask] = [:]
    private var started = false
    private var requestID: UUID?
    private var pendingObservation: NSKeyValueObservation?
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []

    func start() {
        scheduleRefresh()
        guard WCSession.isSupported(), !started else { return }
        started = true
        WCSession.default.delegate = self
        pendingObservation = WCSession.default.observe(\.hasContentPending, options: [.new]) { _, _ in
            Task { @MainActor in self.completeBackgroundTasks() }
        }
        WCSession.default.activate()
    }

    // 希望時刻であり、実際の実行間隔はwatchOSの予算・接続状態に依存する。
    private func scheduleRefresh(force: Bool = false) {
        let now = Date()
        let defaults = UserDefaults.standard
        if !force, defaults.double(forKey: refreshDateKey) > now.timeIntervalSince1970 { return }
        let date = now.addingTimeInterval(15 * 60)
        defaults.set(date.timeIntervalSince1970, forKey: refreshDateKey)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: date, userInfo: nil) { error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                if defaults.double(forKey: self.refreshDateKey) == date.timeIntervalSince1970 {
                    defaults.removeObject(forKey: self.refreshDateKey)
                }
                self.logger.error("Watch refresh scheduling failed: \(message, privacy: .public)")
            }
        }
    }

    func handle(_ task: WKApplicationRefreshBackgroundTask) {
        let id = UUID()
        refreshTasks[id] = task
        scheduleRefresh(force: true)
        logger.info("Watch background sync requested")
        requestSync()
        // セッション有効化・到達可能通知を待つが、OSの実行枠を使い切らない。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if let pending = self.refreshTasks.removeValue(forKey: id) {
                pending.setTaskCompletedWithSnapshot(false)
                self.logger.info("Watch background sync wait ended")
            }
        }
    }

    private func completeRefreshTasks() {
        for task in refreshTasks.values { task.setTaskCompletedWithSnapshot(false) }
        refreshTasks.removeAll()
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
                defer { self.completeRefreshTasks() }
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
        completeRefreshTasks()
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
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            if !self.refreshTasks.isEmpty, WCSession.default.isReachable { self.requestSync() }
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
