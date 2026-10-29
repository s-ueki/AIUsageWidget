import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    var readings: [Service: UsageReading] = [:]
    var errors: [Service: String] = [:]
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        var entry = UsageEntry(date: Date())
        for service in Service.allCases { entry.readings[service] = ReadingStore.read(service) }
        completion(entry)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            var entry = UsageEntry(date: Date())
            async let codex = Self.refresh(.codex)
            async let claude = Self.refresh(.claude)
            let results = await (codex, claude)
            for (service, reading, error) in [results.0, results.1] {
                entry.readings[service] = reading
                entry.errors[service] = error
            }
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }
    static func refresh(_ service: Service) async -> (Service, UsageReading?, String?) {
        let cached = ReadingStore.read(service)
        guard CredentialStore.read(service) != nil else {
            return (service, cached, "アプリで認証情報を設定")
        }
        do {
            let reading = try await UsageFetcher.fetch(service)
            try ReadingStore.save(reading)
            return (service, reading, nil)
        } catch { return (service, cached, error.localizedDescription) }
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    let services: [Service]
    @Environment(\.widgetFamily) var family
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(services) { service in
                UsageCard(service: service, reading: entry.readings[service], error: entry.errors[service], compact: true, dense: family == .systemSmall)
                if service != services.last { Divider() }
            }
        }.containerBackground(for: .widget) { Rectangle().fill(Color.black.gradient) }
        // 背景は常に黒なので、端末がライトモードでも文字色をダーク用にします（preferredColorSchemeはウィジェットでは効きません）。
        .environment(\.colorScheme, .dark)
    }
}

struct CombinedWidget: Widget {
    let kind = "AIUsageCombined"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { UsageWidgetView(entry: $0, services: Service.allCases) }
            .configurationDisplayName("Codex・Claude Code")
            .description("両サービスの残量とリセット日時")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct SingleWidget: Widget {
    let service: Service
    init() { service = .codex }
    init(service: Service) { self.service = service }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsage-\(service.rawValue)", provider: UsageProvider()) { UsageWidgetView(entry: $0, services: [service]) }
            .configurationDisplayName(service.title)
            .description("残量とリセット日時")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AIUsageWidgets: WidgetBundle {
    var body: some Widget {
        CombinedWidget()
        SingleWidget(service: .codex)
        SingleWidget(service: .claude)
    }
}
