import SwiftUI

struct UsageCard: View {
    var service: Service
    var reading: UsageReading?
    var error: String?
    var compact = false
    /// 小サイズ用。全ての枠を表示したまま、文字と余白を詰めます。
    var dense = false
    var tint: Color { service.isCodex ? .cyan : .orange }
    /// Watchの2期間メーターと同じ配色。配列の順序ではなく期間で判定する。
    private func graphColor(for window: UsageWindow) -> Color {
        let weekly: Bool
        if !service.isCodex {
            weekly = window.id == "seven_day"
        } else if let seconds = window.durationSeconds {
            weekly = seconds == 604800
        } else {
            weekly = window.title == "週間"
        }
        return service.isCodex ? (weekly ? .blue : .cyan) : (weekly ? .orange : .yellow)
    }
    /// 標準の.secondaryは暗い背景で読みにくいため、少し明るめの補助色を使います。
    var subtle: Color { Color.primary.opacity(0.8) }
    private func accountDetails(_ credential: Credential?) -> some View {
        Text(credential.map {
            ($0.accountLabel ?? "アカウント未取得") + " · " + AccountDisplay.planName(reading?.plan ?? $0.plan)
        } ?? "未ログイン")
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 4 : compact ? 3 : 12) {
            if compact {
                Text(service.title).font(dense ? .caption.bold() : .headline).foregroundStyle(tint)
            } else {
                let credential = CredentialStore.read(service)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(service.title).font(.headline).foregroundStyle(tint)
                        accountDetails(credential)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.title).font(.headline).foregroundStyle(tint)
                        accountDetails(credential)
                    }
                }
            }
            if let reading {
                ForEach(reading.windows) { window in
                    let color = graphColor(for: window)
                    VStack(alignment: .leading, spacing: dense ? 1 : compact ? 1 : 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(dense ? window.title : window.title + "・残り").font(dense ? .caption2 : .caption)
                            Spacer(minLength: 0)
                            Text("\(Int(window.remaining.rounded()))%")
                                .font(.system(size: dense ? 15 : compact ? 20 : 36, weight: .bold, design: .rounded))
                                .foregroundStyle(window.remaining <= 10 ? .red : color)
                                .monospacedDigit().minimumScaleFactor(0.7)
                        }
                        ProgressView(value: window.remaining, total: 100).tint(color)
                        if let reset = window.reset {
                            if dense {
                                // 過ぎている場合は色で示し、行数を増やさない
                                Text("リセット " + reset.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))
                                    .font(.system(size: 10)).foregroundStyle(reset <= Date() ? .orange : subtle)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                            } else {
                                Text("リセット " + reset.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.caption2).foregroundStyle(subtle)
                                if reset <= Date() { Text("リセット時刻を過ぎています・更新待ち").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                    }
                }
                if !dense {
                    Text("取得 " + reading.fetchedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption2).foregroundStyle(subtle)
                }
            } else {
                Text("—% パーセント未取得").font(dense ? .caption : .title3).foregroundStyle(subtle)
            }
            if let error { Text(error).font(dense ? .system(size: 10) : .caption2).foregroundStyle(.orange).lineLimit(compact || dense ? 1 : nil) }
        }
    }
}
