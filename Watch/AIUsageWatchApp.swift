import SwiftUI
import WatchKit

final class WatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        Task { @MainActor in
            for task in backgroundTasks {
                if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                    WatchReceiver.shared.handle(connectivity)
                } else if let refresh = task as? WKApplicationRefreshBackgroundTask {
                    WatchReceiver.shared.handle(refresh)
                } else {
                    task.setTaskCompletedWithSnapshot(false)
                }
            }
        }
    }
}

@main
struct AIUsageWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    init() { WatchReceiver.shared.start() }
    var body: some Scene { WindowGroup { WatchDashboard() } }
}

struct WatchDashboard: View {
    @ObservedObject private var receiver = WatchReceiver.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Service.allCases) { service in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(service.title).font(.headline).foregroundStyle(service.isCodex ? .cyan : .orange)
                        if let reading = receiver.snapshot?.reading(for: service) {
                            ForEach(reading.windows) { window in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(window.title).font(.caption)
                                        Spacer()
                                        Text("\(Int(window.remaining.rounded()))%")
                                            .font(.title3.bold()).monospacedDigit()
                                    }
                                    ProgressView(value: window.remaining, total: 100)
                                        .tint(service.isCodex ? .cyan : .orange)
                                    if let reset = window.reset {
                                        Text("リセット " + reset.formatted(.dateTime.month().day().hour().minute()))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Text("取得 " + reading.fetchedAt.formatted(.dateTime.month().day().hour().minute()))
                                .font(.caption2).foregroundStyle(.secondary)
                            if Date().timeIntervalSince(reading.fetchedAt) > WatchSnapshot.staleInterval {
                                Text("90分以上前のデータ").font(.caption2).foregroundStyle(.orange)
                            }
                        } else {
                            Text("未取得").foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
                Button { receiver.requestSync() } label: {
                    Label(receiver.syncing ? "同期中…" : "iPhoneと同期", systemImage: "arrow.triangle.2.circlepath")
                }.disabled(receiver.syncing)
                Text(receiver.status).font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 8)
        }
        .navigationTitle("AI使用量")
        .onChange(of: phase) { _, value in if value == .active { receiver.requestSync() } }
    }
}
