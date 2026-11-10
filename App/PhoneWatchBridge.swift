#if os(iOS)
import Foundation
import WatchConnectivity
import BackgroundTasks
import WidgetKit
import OSLog
import UIKit

@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchBridge()
    private var started = false
    private var pendingPriorityTransfer = false
    static let refreshIdentifier = "com.s-ueki7.aiusage.ios.refresh"
    private var refreshTask: Task<[Service: String], Never>?
    private let logger = Logger(subsystem: "com.s-ueki7.aiusage.ios", category: "BackgroundRefresh")

    func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.error("Background refresh scheduling failed: \(error.localizedDescription, privacy: .public)") }
    }

    func backgroundRefresh() async {
        scheduleRefresh()
        logger.info("Background refresh started")
        _ = await refresh(maxAge: 5 * 60)
        logger.info("Background refresh finished")
    }

    // 同じプロセスの画面・バックグラウンド・Watch要求は一つの取得処理を共有する。
    // OSからキャンセルされた場合は通信も止め、失敗したサービスのキャッシュは残す。
    func refresh(maxAge: TimeInterval = 0) async -> [Service: String] {
        if let refreshTask { return await refreshTask.value }
        let work = Task { @MainActor () -> [Service: String] in
            var errors: [Service: String] = [:]
            await withTaskGroup(of: (Service, String?).self) { group in
                for service in Service.allCases {
                    guard CredentialStore.read(service) != nil else {
                        errors[service] = UsageError.noCredential.localizedDescription
                        continue
                    }
                    if let cached = ReadingStore.read(service),
                       Date().timeIntervalSince(cached.fetchedAt) < maxAge { continue }
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let reading = try await UsageFetcher.fetch(service)
                            try Task.checkCancellation()
                            try ReadingStore.save(reading)
                            return (service, nil)
                        } catch { return (service, error.localizedDescription) }
                    }
                }
                for await (service, error) in group { errors[service] = error }
            }
            WidgetCenter.shared.reloadAllTimelines()
            self.publish(prioritize: true)
            return errors
        }
        refreshTask = work
        let errors = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        refreshTask = nil
        return errors
    }

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

    func publish(prioritize: Bool = false) {
        pendingPriorityTransfer = pendingPriorityTransfer || prioritize
        guard WCSession.isSupported() else { return }
        start()
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let data = try payload()
            try session.updateApplicationContext(data)
            // 優先転送枠を短時間の再送で消費しない。通常のcontext転送は常に残す。
            let last = UserDefaults.standard.double(forKey: "watch.lastComplicationTransfer")
            if pendingPriorityTransfer, session.isComplicationEnabled,
               session.remainingComplicationUserInfoTransfers > 0,
               Date().timeIntervalSince1970 - last >= 30 * 60 {
                session.transferCurrentComplicationUserInfo(data)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "watch.lastComplicationTransfer")
            }
            pendingPriorityTransfer = false
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
            // 即時返信後も取得を継続できる実行時間を要求する。OSの期限で通信を止める。
            let lease = PhoneRefreshLease()
            lease.begin { self.refreshTask?.cancel() }
            defer { lease.end() }
            replyHandler((try? self.payload()) ?? [:])
            _ = await self.refresh(maxAge: 5 * 60)
        }
    }
}
// Watchからの要求でiPhoneが起きた場合の短い実行時間を管理する。
@MainActor
private final class PhoneRefreshLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin(onExpire: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Watch usage refresh") { [weak self] in
            Task { @MainActor in
                onExpire()
                self?.end()
            }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
