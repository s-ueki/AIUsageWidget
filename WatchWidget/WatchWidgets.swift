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
    private var name: String { service.title }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                if let window {
                    Gauge(value: window.remaining, in: 0...100) {
                        Text((service.isCodex ? "CX" : "CL") + String(service.accountNumber))
                    } currentValueLabel: {
                        Text("\(Int(window.remaining.rounded()))").minimumScaleFactor(0.6)
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(stale ? .gray : service.isCodex ? .cyan : .orange)
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
        // Interpolated localization text is unsupported in widget metadata.
        .configurationDisplayName(service.title + "・" + period.title)
        .description("iPhoneで取得した残量を表示します。")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct OverviewPeriodBar: View {
    let title: String
    let remaining: Double?
    let color: Color
    var limitAbsent = false

    private var amount: String {
        limitAbsent ? "なし" : remaining.map { "\(Int($0.rounded()))%" } ?? "—"
    }
    private var fraction: Double { min(1, max(0, (remaining ?? (limitAbsent ? 100 : 0)) / 100)) }

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(title).font(.system(size: 9))
                Spacer(minLength: 0)
                Text(amount).font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
            .lineLimit(1).minimumScaleFactor(0.75)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18))
                    if fraction > 0 {
                        Capsule().fill(color).frame(width: geometry.size.width * fraction)
                    }
                }
            }
            .frame(height: 4)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (limitAbsent ? "制限なし" : "の残量" + amount))
    }
}

enum WatchOverviewSelection: String, CaseIterable {
    case codex1, codex2, codexBoth, claude1, claude2, claudeBoth, pair1, pair2

    var services: [Service] {
        switch self {
        case .codex1: return [.codex]
        case .codex2: return [.codex2]
        case .codexBoth: return [.codex, .codex2]
        case .claude1: return [.claude]
        case .claude2: return [.claude2]
        case .claudeBoth: return [.claude, .claude2]
        case .pair1: return [.codex, .claude]
        case .pair2: return [.codex2, .claude2]
        }
    }
    var title: String {
        switch self {
        case .codexBoth: return "CODEX1&2"
        case .claudeBoth: return "CLAUDE1&2"
        default: return services.map(\.title).joined(separator: "&")
        }
    }
    // 配置済みのCODEX1・CLAUDE1はそのまま継続する。
    var kind: String { self == .pair1 ? "WatchUsageOverview" : "WatchUsageOverview-" + rawValue }
}

struct WatchOverviewView: View {
    let entry: WatchEntry
    var selection: WatchOverviewSelection = .pair1

    var body: some View {
        VStack(spacing: 5) {
            if selection.services.count == 1 {
                Text(selection.title)
                    .font(.system(size: 12, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(selection.services) { service in
                let reading = entry.snapshot?.reading(for: service)
                let session = WatchPeriod.session.window(in: reading)
                let weekly = WatchPeriod.weekly.window(in: reading)
                let stale = reading.map { entry.date.timeIntervalSince($0.fetchedAt) > 3600 } ?? false
                HStack(spacing: 7) {
                    if selection.services.count > 1 {
                        Text(service.title)
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 45, alignment: .leading)
                    }
                    OverviewPeriodBar(title: "5時間", remaining: session?.remaining,
                                      color: stale ? .gray : service.isCodex ? .cyan : .yellow,
                                      limitAbsent: WatchPeriod.session.limitAbsent(in: reading))
                        .frame(maxWidth: .infinity)
                        .widgetAccentable()
                    OverviewPeriodBar(title: "週", remaining: weekly?.remaining,
                                      color: stale ? .gray : service.isCodex ? .blue : .orange,
                                      limitAbsent: WatchPeriod.weekly.limitAbsent(in: reading))
                        .frame(maxWidth: .infinity)
                }
                .accessibilityElement(children: .combine)
            }
            Group {
                if let oldest = entry.snapshot?.readings.filter { selection.services.contains($0.service) }.map(\.fetchedAt).min() {
                    Text("取得 " + oldest.formatted(.dateTime.hour().minute())
                         + (entry.date.timeIntervalSince(oldest) > 3600 ? "・更新待ち" : ""))
                } else {
                    Text("iPhoneで使用量を更新")
                }
            }
            .font(.system(size: 8)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WatchOverviewWidget: Widget {
    let selection: WatchOverviewSelection
    init() { selection = .pair1 }
    init(_ selection: WatchOverviewSelection) { self.selection = selection }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: selection.kind, provider: WatchProvider()) { entry in
            WatchOverviewView(entry: entry, selection: selection)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName(selection.title)
        .description("選んだアカウントの5時間・週間残量をグラフ付きで表示します。")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// Both arcs start at six o'clock and reach twelve o'clock at 100%.
struct RemainingHalfArc: Shape {
    let fraction: Double
    let isLeft: Bool

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, fraction))
        guard progress > 0 else { return Path() }
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(90),
                    endAngle: .degrees(90 + (isLeft ? 180 : -180) * progress),
                    clockwise: !isLeft)
        return path
    }
}

struct DualPeriodGauge: View {
    let service: Service
    let sessionRemaining: Double?
    let weeklyRemaining: Double?
    var sessionLimitAbsent = false
    var weeklyLimitAbsent = false
    var stale = false

    private var sessionColor: Color { stale ? .gray : service.isCodex ? .cyan : .yellow }
    private var weeklyColor: Color { stale ? .gray : service.isCodex ? .blue : .orange }
    private func amount(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let lineWidth = size * 0.065
            ZStack {
                Circle().stroke(Color.primary.opacity(0.18), lineWidth: lineWidth)
                RemainingHalfArc(fraction: (sessionRemaining ?? (sessionLimitAbsent ? 100 : 0)) / 100, isLeft: true)
                    .stroke(sessionColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .widgetAccentable()
                RemainingHalfArc(fraction: (weeklyRemaining ?? (weeklyLimitAbsent ? 100 : 0)) / 100, isLeft: false)
                    .stroke(weeklyColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                VStack(spacing: size * 0.025) {
                    HStack(spacing: 2) {
                        Text(service.title)
                        if stale { Image(systemName: "clock") }
                    }
                    .font(.system(size: size * 0.115, weight: .bold))
                    HStack(spacing: 1) {
                        Text("5時間").font(.system(size: size * 0.105))
                        Spacer(minLength: 0)
                        Text(sessionLimitAbsent ? "なし" : amount(sessionRemaining))
                            .font(.system(size: size * 0.18, weight: .bold))
                    }
                    .foregroundStyle(sessionColor)
                    .widgetAccentable()
                    HStack(spacing: 1) {
                        Text("週").font(.system(size: size * 0.105))
                        Spacer(minLength: 0)
                        Text(weeklyLimitAbsent ? "なし" : amount(weeklyRemaining))
                            .font(.system(size: size * 0.18, weight: .bold))
                    }
                    .foregroundStyle(weeklyColor)
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: size * 0.70)
            }
            .padding(lineWidth / 2 + 1)
            .frame(width: size, height: size)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(service.title
                            + (sessionLimitAbsent ? "、5時間制限なし" : "、5時間の残量" + amount(sessionRemaining))
                            + (weeklyLimitAbsent ? "、週間制限なし" : "、週間の残量" + amount(weeklyRemaining))
                            + (stale ? "、1時間以上前のデータ" : ""))
    }
}

struct WatchDualPeriodView: View {
    let entry: WatchEntry
    let service: Service

    var body: some View {
        let reading = entry.snapshot?.reading(for: service)
        let sessionWindow = WatchPeriod.session.window(in: reading)
        let weeklyWindow = WatchPeriod.weekly.window(in: reading)
        DualPeriodGauge(service: service,
                        sessionRemaining: sessionWindow?.remaining,
                        weeklyRemaining: weeklyWindow?.remaining,
                        sessionLimitAbsent: WatchPeriod.session.limitAbsent(in: reading),
                        weeklyLimitAbsent: WatchPeriod.weekly.limitAbsent(in: reading),
                        stale: reading.map { entry.date.timeIntervalSince($0.fetchedAt) > 3600 } ?? false)
            .containerBackground(for: .widget) { Color.black }
    }
}

struct WatchDualPeriodWidget: Widget {
    let service: Service
    init() { service = .codex }
    init(_ service: Service) { self.service = service }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchUsage-Dual-" + service.rawValue, provider: WatchProvider()) {
            WatchDualPeriodView(entry: $0, service: service)
        }
        .configurationDisplayName(service.title + "・5時間と週")
        .description("左が5時間、右が週間の残量。下が0%、真上が100%です。")
        .supportedFamilies([.accessoryCircular])
        .contentMarginsDisabled()
    }
}

@main
struct AIUsageWatchWidgets: WidgetBundle {
    var body: some Widget {
        RectangularWatchWidgets().body
        WatchUsageWidget(.codex, .session)
        WatchUsageWidget(.codex, .weekly)
        WatchUsageWidget(.claude, .session)
        WatchUsageWidget(.claude, .weekly)
        WatchDualPeriodWidget(.codex)
        WatchDualPeriodWidget(.claude)
        SecondAccountWatchWidgets().body
    }
}

// WidgetBundleBuilderの要素数を抑えるため、追加分を別のbundleにまとめる。
struct SecondAccountWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchUsageWidget(.codex2, .session)
        WatchUsageWidget(.codex2, .weekly)
        WatchUsageWidget(.claude2, .session)
        WatchUsageWidget(.claude2, .weekly)
        WatchDualPeriodWidget(.codex2)
        WatchDualPeriodWidget(.claude2)
    }
}

struct RectangularWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchOverviewWidget(.codex1)
        WatchOverviewWidget(.codex2)
        WatchOverviewWidget(.codexBoth)
        WatchOverviewWidget(.claude1)
        WatchOverviewWidget(.claude2)
        WatchOverviewWidget(.claudeBoth)
        WatchOverviewWidget(.pair1)
        WatchOverviewWidget(.pair2)
    }
}
