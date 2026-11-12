import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
#endif

@main
struct AIUsageApp: App {
    @Environment(\.scenePhase) private var phase
    init() {
        #if os(iOS)
        PhoneWatchBridge.shared.start()
        #endif
    }
    var body: some Scene {
        WindowGroup { Dashboard() }
        #if os(iOS)
        .backgroundTask(.appRefresh(PhoneWatchBridge.refreshIdentifier)) {
            await PhoneWatchBridge.shared.backgroundRefresh()
        }
        .onChange(of: phase) { _, value in
            // App.initではまだ.backgroundTaskのハンドラが登録されていない。
            // Scene構築後の状態遷移で初回予約と再予約を行う。
            if value == .active || value == .background {
                PhoneWatchBridge.shared.scheduleRefresh()
            }
        }
        #endif
    }
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
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 20) {
                        if geometry.size.width >= 640 {
                            HStack(alignment: .top, spacing: 20) {
                                accountColumn([.codex, .codex2])
                                accountColumn([.claude, .claude2])
                            }
                        } else {
                            accountColumn(Service.allCases)
                        }
                        Text("この端末から直接取得します。更新時刻は端末のタイムゾーンで表示します。ウィジェットの自動更新時刻はOSが決定します。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding()
                }
            }
            .navigationTitle("AI使用量")
            .onOpenURL { url in
                guard url.scheme == "aiusage-widget", url.host == "dashboard" else { return }
                #if os(macOS)
                NSApplication.shared.activate(ignoringOtherApps: true)
                #endif
            }
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
    private func accountColumn(_ services: [Service]) -> some View {
        VStack(spacing: 20) {
            ForEach(services) { service in
                VStack(alignment: .leading, spacing: 12) {
                    UsageCard(service: service, reading: readings[service], error: errors[service])
                    Button("認証情報を設定") { editing = service }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @MainActor func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        #if os(iOS)
        // ウィジェットの再読み込みはPhoneWatchBridge.refreshが行う。
        errors = await PhoneWatchBridge.shared.refresh()
        for service in Service.allCases { readings[service] = ReadingStore.read(service) }
        #else
        for service in Service.allCases {
            do {
                let reading = try await UsageFetcher.fetch(service)
                readings[service] = reading
                try ReadingStore.save(reading)
                errors.removeValue(forKey: service)
            } catch { errors[service] = error.localizedDescription }
        }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

struct CredentialEditor: View {
    var service: Service
    var onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
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
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                Text(service.title).font(.title2.bold())
                Spacer()
            }
            .padding(20)
            Divider()
            settingsForm.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("閉じる") { login.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: showsPaste ? 560 : 380)
        #else
        NavigationStack {
            settingsForm
                .navigationTitle(service.title)
                .toolbar { Button("閉じる") { login.cancel(); dismiss() } }
        }
        .frame(minWidth: 360, minHeight: 560)
        #endif
    }

    private var settingsForm: some View {
            Form {
                Section("Webでログイン") {
                    Text(service.title + "に登録するアカウントでログインしてください。")
                        .font(.callout)
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
                Text("認証情報はこの端末のKeychainに保存します。外部の中継サーバーやiCloudへ送信しません。")
                    .font(.caption).foregroundStyle(.secondary)
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
