import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    var readings: [Service: UsageReading] = [:]
    var errors: [Service: String] = [:]
}

struct UsageProvider: TimelineProvider {
    var services: [Service] = Service.overviewAccounts
    var includesAllAccountsInLarge = false
    private func accounts(for family: WidgetFamily) -> [Service] {
        if includesAllAccountsInLarge && family == .systemLarge { return Service.allCases }
        return services
    }
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        var entry = UsageEntry(date: Date())
        for service in accounts(for: context.family) { entry.readings[service] = ReadingStore.read(service) }
        completion(entry)
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            var entry = UsageEntry(date: Date())
            await withTaskGroup(of: (Service, UsageReading?, String?).self) { group in
                for service in accounts(for: context.family) { group.addTask { await Self.refresh(service) } }
                for await (service, reading, error) in group {
                    entry.readings[service] = reading
                    entry.errors[service] = error
                }
            }
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }
    static func refresh(_ service: Service) async -> (Service, UsageReading?, String?) {
        let cached = ReadingStore.read(service)
        guard CredentialStore.read(service) != nil else {
            return (service, cached, "アプリで認証情報を設定")
        }
        // アプリや他のウィジェットが取得した直後は通信せず、保存済みの数値を使う。
        if let cached, cached.isFresh(within: UsageFetcher.widgetCacheAge) { return (service, cached, nil) }
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
    var includesAllAccountsInLarge = false
    @Environment(\.widgetFamily) var family
    private var showsAllAccounts: Bool {
        return includesAllAccountsInLarge && family == .systemLarge
    }
    private func card(_ service: Service) -> some View {
        UsageCard(service: service, reading: entry.readings[service], error: entry.errors[service], compact: true, dense: family == .systemSmall)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    var body: some View {
        Group {
            if showsAllAccounts {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        card(.codex)
                        Divider()
                        card(.claude)
                    }.frame(maxHeight: .infinity, alignment: .top)
                    Divider()
                    HStack(alignment: .top, spacing: 14) {
                        card(.codex2)
                        Divider()
                        card(.claude2)
                    }.frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(services) { service in
                        card(service)
                        if service != services.last { Divider() }
                    }
                }
            }
        }
        .containerBackground(for: .widget) { Rectangle().fill(Color.black.gradient) }
        .widgetURL(URL(string: "aiusage-widget://dashboard"))
        // 背景は常に黒なので、端末がライトモードでも文字色をダーク用にします（preferredColorSchemeはウィジェットでは効きません）。
        .environment(\.colorScheme, .dark)
    }
}

struct CombinedWidget: Widget {
    let kind = "AIUsageCombined"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider(includesAllAccountsInLarge: true)) { UsageWidgetView(entry: $0, services: Service.overviewAccounts, includesAllAccountsInLarge: true) }
            .configurationDisplayName("Codex・Claude 一覧")
            .description("中サイズはCODEX1・CLAUDE1、大サイズは全4アカウントを表示")
            .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct SingleWidget: Widget {
    let service: Service
    init() { service = .codex }
    init(service: Service) { self.service = service }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsage-\(service.rawValue)", provider: UsageProvider(services: [service])) { UsageWidgetView(entry: $0, services: [service]) }
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
        SingleWidget(service: .codex2)
        SingleWidget(service: .claude2)
    }
}
