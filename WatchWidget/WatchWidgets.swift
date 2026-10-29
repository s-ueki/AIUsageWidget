import SwiftUI
import WidgetKit

struct WatchEntry: TimelineEntry {
    var date: Date
    var snapshot: WatchSnapshot?
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        completion(WatchEntry(date: Date(), snapshot: WatchStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        let now = Date()
        let snapshot = WatchStore.read()
        // 取得から1時間経過したとき、データが古いことを表示へ反映する。
        let boundaries = snapshot?.readings.map { $0.fetchedAt.addingTimeInterval(3601) }.filter { $0 > now } ?? []
        let entries = ([now] + boundaries).sorted().map { WatchEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct WatchComplicationView: View {
    let entry: WatchEntry
    let service: Service
    let period: WatchPeriod
    @Environment(\.widgetFamily) private var family
    private var reading: UsageReading? { entry.snapshot?.reading(for: service) }
    private var window: UsageWindow? { period.window(in: reading) }
    private var stale: Bool { reading.map { entry.date.timeIntervalSince($0.fetchedAt) > 3600 } ?? false }
    private var amount: String { window.map { "\(Int($0.remaining.rounded()))%" } ?? "—" }
    private var name: String { service == .codex ? "Codex" : "Claude" }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let window {
                    Gauge(value: window.remaining, in: 0...100) {
                        Text(service == .codex ? "CX" : "CL")
                    } currentValueLabel: {
                        Text("\(Int(window.remaining.rounded()))").minimumScaleFactor(0.6)
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(stale ? .gray : service == .codex ? .cyan : .orange)
                } else { Text("—").font(.title2) }
            case .accessoryInline:
                Text("\(name) \(period.title) \(amount)\(stale ? "・古いデータ" : "")")
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name)・\(window?.title ?? period.title)").font(.caption)
                    HStack {
                        Text(amount).font(.title2.bold()).monospacedDigit()
                        Spacer()
                        if stale { Image(systemName: "clock.badge.exclamationmark") }
                    }
                    if let reading {
                        Text("取得 " + reading.fetchedAt.formatted(.dateTime.hour().minute()))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else { Text("iPhoneで更新してください").font(.caption2) }
                }
            }
        }
        .containerBackground(for: .widget) { Color.black }
        .accessibilityLabel("\(name)、\(period.title)、残り\(amount)\(stale ? "、1時間以上前のデータ" : "")")
    }
}

struct WatchUsageWidget: Widget {
    let service: Service
    let period: WatchPeriod
    init() { service = .codex; period = .session }
    init(_ service: Service, _ period: WatchPeriod) { self.service = service; self.period = period }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchUsage-\(service.rawValue)-\(period.rawValue)", provider: WatchProvider()) {
            WatchComplicationView(entry: $0, service: service, period: period)
        }
        .configurationDisplayName("\(service.title)・\(period.title)")
        .description("iPhoneで取得した残量を表示します。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct WatchOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchUsageOverview", provider: WatchProvider()) { entry in
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Service.allCases) { service in
                    let reading = entry.snapshot?.reading(for: service)
                    let window = WatchPeriod.session.window(in: reading)
                    HStack {
                        Text(service == .codex ? "Codex" : "Claude").font(.caption)
                        Spacer()
                        Text(window.map { "\(Int($0.remaining.rounded()))%" } ?? "—")
                            .font(.headline).monospacedDigit()
                    }
                }
                if let oldest = entry.snapshot?.readings.map(\.fetchedAt).min() {
                    Text("取得 " + oldest.formatted(.dateTime.month().day().hour().minute())
                         + (entry.date.timeIntervalSince(oldest) > 3600 ? "・更新待ち" : ""))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("iPhoneで使用量を更新").font(.caption2).foregroundStyle(.secondary)
                }
            }.containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Codex・Claude")
        .description("両サービスのセッション残量。詳細はタップして確認できます。")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct AIUsageWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchOverviewWidget()
        WatchUsageWidget(.codex, .session)
        WatchUsageWidget(.codex, .weekly)
        WatchUsageWidget(.claude, .session)
        WatchUsageWidget(.claude, .weekly)
    }
}
