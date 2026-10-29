import SwiftUI
import WidgetKit

@main
struct AIUsageApp: App {
    init() {
        #if os(iOS)
        PhoneWatchBridge.shared.start()
        #endif
    }
    var body: some Scene { WindowGroup { Dashboard() } }
}

struct Dashboard: View {
    private var stateReadings = SwiftUI.State<[Service: UsageReading]>(initialValue: [:])
    private var readings: [Service: UsageReading] {
        get { stateReadings.wrappedValue }
        nonmutating set { stateReadings.wrappedValue = newValue }
    }
    private var stateErrors = SwiftUI.State<[Service: String]>(initialValue: [:])
    private var errors: [Service: String] {
        get { stateErrors.wrappedValue }
        nonmutating set { stateErrors.wrappedValue = newValue }
    }
    private var stateEditing = SwiftUI.State<Service?>(initialValue: nil)
    private var editing: Service? {
        get { stateEditing.wrappedValue }
        nonmutating set { stateEditing.wrappedValue = newValue }
    }
    private var stateRefreshing = SwiftUI.State<Bool>(initialValue: false)
    private var refreshing: Bool {
        get { stateRefreshing.wrappedValue }
        nonmutating set { stateRefreshing.wrappedValue = newValue }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(Service.allCases) { service in
                        VStack(alignment: .leading, spacing: 12) {
                            UsageCard(service: service, reading: readings[service], error: errors[service])
                            Button("認証情報を設定") { editing = service }
                        }
                        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                    Text("この端末から直接取得します。更新時刻は端末のタイムゾーンで表示します。ウィジェットの自動更新時刻はOSが決定します。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("AI使用量")
            .toolbar { Button { Task { await refresh() } } label: {
                if refreshing { ProgressView() } else { Label("更新", systemImage: "arrow.clockwise") }
            }.disabled(refreshing) }
            .sheet(item: stateEditing.projectedValue) { service in
                CredentialEditor(service: service) {
                    readings.removeValue(forKey: service)
                    errors.removeValue(forKey: service)
                    Task { await refresh() }
                }
            }
            .task {
                for service in Service.allCases { readings[service] = ReadingStore.read(service) }
                await refresh()
            }
        }.frame(minWidth: 300, minHeight: 440)
    }
    @MainActor func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            WidgetCenter.shared.reloadAllTimelines()
            #if os(iOS)
            PhoneWatchBridge.shared.publish()
            #endif
        }
        for service in Service.allCases {
            do {
                let reading = try await UsageFetcher.fetch(service)
                readings[service] = reading
                try ReadingStore.save(reading)
                errors.removeValue(forKey: service)
            } catch { errors[service] = error.localizedDescription }
        }
    }
}

struct CredentialEditor: View {
    var service: Service
    var onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var stateToken = SwiftUI.State<String>(initialValue: "")
    private var token: String {
        get { stateToken.wrappedValue }
        nonmutating set { stateToken.wrappedValue = newValue }
    }
    private var stateAccountid = SwiftUI.State<String>(initialValue: "")
    private var accountID: String {
        get { stateAccountid.wrappedValue }
        nonmutating set { stateAccountid.wrappedValue = newValue }
    }
    private var stateError = SwiftUI.State<String?>(initialValue: nil)
    private var error: String? {
        get { stateError.wrappedValue }
        nonmutating set { stateError.wrappedValue = newValue }
    }
    private var stateLogin = SwiftUI.State<WebLogin>(initialValue: WebLogin())
    private var login: WebLogin { stateLogin.wrappedValue }
    private var stateLoggingIn = SwiftUI.State<Bool>(initialValue: false)
    private var loggingIn: Bool {
        get { stateLoggingIn.wrappedValue }
        nonmutating set { stateLoggingIn.wrappedValue = newValue }
    }
    private var stateShowsPaste = SwiftUI.State<Bool>(initialValue: false)
    private var showsPaste: Bool {
        get { stateShowsPaste.wrappedValue }
        nonmutating set { stateShowsPaste.wrappedValue = newValue }
    }
    private var stateCallback = SwiftUI.State<String>(initialValue: "")
    private var callback: String {
        get { stateCallback.wrappedValue }
        nonmutating set { stateCallback.wrappedValue = newValue }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Webでログイン（推奨）") {
                    Text("\(OAuthConfig.of(service).loginHost)のログイン画面を開き、ログイン後にアクセストークンと更新用トークンを自動で保存します。期限切れ時も自動で更新します。")
                    Button {
                        Task { await webLogin { try await login.start(service) } }
                    } label: {
                        if loggingIn { ProgressView() } else { Label("Webでログイン", systemImage: "person.badge.key") }
                    }.disabled(loggingIn)
                    if showsPaste {
                        Text("自動で戻らない場合は、ログイン後に表示されたページのURL（またはコード）を貼り付けてください。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("http://localhost…/callback?code=…", text: stateCallback.projectedValue)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("貼り付けた内容でログインを完了") {
                            Task { await webLogin { try await login.complete(callback) } }
                        }.disabled(loggingIn || callback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("手動で登録") {
                    Text("\(service.title)の使用量取得用アクセストークンを登録します。通常のAPIキーではありません。手動登録したトークンは自動更新されないため、期限切れ時は再登録が必要です。")
                    SecureField("アクセストークン", text: stateToken.projectedValue)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if service == .codex { TextField("ChatGPT Account ID（必要な場合）", text: stateAccountid.projectedValue) }
                    Text("認証情報はこの端末のKeychainに保存します。外部の中継サーバーやiCloudへ送信しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存") {
                        store(Credential(token: token.trimmingCharacters(in: .whitespacesAndNewlines), accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }.disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button("認証情報と表示データを削除", role: .destructive) {
                    do {
                        try CredentialStore.delete(service)
                        ReadingStore.clear(service)
                        #if os(iOS)
                        PhoneWatchBridge.shared.publish()
                        #endif
                        WidgetCenter.shared.reloadAllTimelines()
                        onChanged(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
            .navigationTitle(service.title)
            .toolbar { Button("閉じる") { login.cancel(); dismiss() } }
        }.frame(minWidth: 360, minHeight: 560)
    }
    @MainActor func webLogin(_ action: () async throws -> Credential) async {
        loggingIn = true
        defer { loggingIn = false }
        error = nil
        do { store(try await action()) } catch {
            showsPaste = login.pending != nil
            self.error = error.localizedDescription
        }
    }
    func store(_ credential: Credential) {
        do {
            try CredentialStore.save(credential, for: service)
            ReadingStore.clear(service)
            #if os(iOS)
            PhoneWatchBridge.shared.publish()
            #endif
            WidgetCenter.shared.reloadAllTimelines()
            onChanged(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
