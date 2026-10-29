import SwiftUI

struct UsageCard: View {
    var service: Service
    var reading: UsageReading?
    var error: String?
    var compact = false
    /// 小サイズ用。全ての枠を表示したまま、文字と余白を詰めます。
    var dense = false
    var tint: Color { service == .codex ? .cyan : .orange }
    /// 標準の.secondaryは暗い背景で読みにくいため、少し明るめの補助色を使います。
    var subtle: Color { Color.primary.opacity(0.8) }
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 4 : compact ? 3 : 12) {
            Text(service.title.uppercased()).font(dense ? .caption.bold() : .headline).foregroundStyle(tint)
            if let reading {
                ForEach(reading.windows) { window in
                    VStack(alignment: .leading, spacing: dense ? 1 : compact ? 1 : 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(dense ? window.title : window.title + "・残り").font(dense ? .caption2 : .caption)
                            Spacer(minLength: 0)
                            Text("\(Int(window.remaining.rounded()))%")
                                .font(.system(size: dense ? 15 : compact ? 20 : 36, weight: .bold, design: .rounded))
                                .foregroundStyle(window.remaining <= 10 ? .red : tint)
                                .monospacedDigit().minimumScaleFactor(0.7)
                        }
                        ProgressView(value: window.remaining, total: 100).tint(tint)
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
