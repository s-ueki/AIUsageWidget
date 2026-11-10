import AuthenticationServices
import Network
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// ログイン後のリダイレクト（http://localhost:…）を端末内だけで受け取る最小限のHTTPサーバー。
final class LoopbackServer {
    private let listener: NWListener
    private let path: String
    private let queue = DispatchQueue(label: "AIUsage.loopback")
    var onCallback: ((String) -> Void)?

    init(port: UInt16, path: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try port == 0 ? NWListener(using: parameters)
                                 : NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.path = path
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let completion = OneShotContinuation(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    completion.resume(with: .success(listener.port?.rawValue ?? 0))
                case .failed, .waiting, .cancelled:
                    if completion.resume(with: .failure(OAuthError.portInUse)) {
                        listener.cancel()
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: buffer[..<end.lowerBound])
            } else if done || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let line = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ").map(String.init)
        let url = parts.count >= 2 ? "http://localhost" + parts[1] : ""
        let matched = parts.first == "GET" && URLComponents(string: url)?.path == path
        let body = Data((matched
            ? "<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width\"><title>AI使用量</title><p style=\"font:17px -apple-system;text-align:center;margin-top:48px\">ログイン情報を受け取りました。アプリに戻ってください。</p>"
            : "Not Found").utf8)
        let header = "HTTP/1.1 \(matched ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        if matched { onCallback?(url) }
    }
}

/// ブラウザ画面でログインし、受け取ったコードをトークンに交換します。
@MainActor
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<String, Error>?
    /// 自動で戻れなかった場合に、貼り付けたURL/コードで完了できるよう直近の要求を保持します。
    private(set) var pending: OAuthRequest?

    func start(_ service: Service) async throws -> Credential {
        cancel()
        let config = OAuthConfig.of(service)
        let server = try LoopbackServer(port: config.port, path: config.callbackPath)
        defer { server.stop() }
        let port = try await server.start()
        let request = OAuthRequest(service: service, redirectURI: config.redirectURI(port: port))
        pending = request
        let callback: String = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            server.onCallback = { [weak self] url in
                Task { @MainActor [weak self] in self?.finish(.success(url)) }
            }
            // リダイレクトはlocalhostのサーバーで受け取るため、このスキームは使われません。
            let session = ASWebAuthenticationSession(url: request.authorizeURL, callbackURLScheme: "aiusage-login") { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.finish(.failure(OAuthError.cancelled)) }
            }
            session.presentationContextProvider = self
            // 前回のブラウザログインを使い回さず、登録するアカウントを選べるようにする。
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { finish(.failure(OAuthError.cancelled)) }
        }
        return try await complete(callback)
    }

    func complete(_ callback: String) async throws -> Credential {
        guard let pending else { throw OAuthError.noPendingLogin }
        let credential = try await OAuthClient.exchange(callback: callback, request: pending)
        self.pending = nil
        return credential
    }

    func cancel() { finish(.failure(OAuthError.cancelled)) }

    private func finish(_ result: Result<String, Error>) {
        let session = self.session
        self.session = nil
        session?.cancel()
        continuation?.resume(with: result)
        continuation = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
            #endif
        }
    }
}
