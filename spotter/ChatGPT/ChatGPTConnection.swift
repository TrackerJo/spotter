import Foundation
import Observation
import AuthenticationServices
import Security
import Network
import UIKit

struct ChatGPTCredentials: Codable {
    var clientID: String
    var subject: String
    var email: String
    var accessToken: String
    var refreshToken: String?
    var idToken: String
    var scopes: [String]
    var expiresAt: Date
    var welcomed: Bool = false
    var usesPlan: Bool { scopes.contains("chatgpt.tokens.use.direct") }
}

enum ChatGPTKeychain {
    static let service = "com.kazoom.spotter.chatgpt"
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ChatGPTError(message: "Unlock your iPhone to access the ChatGPT connection.") }
        return result as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw ChatGPTError(message: "Could not securely save the ChatGPT connection.") }
        } else if status != errSecSuccess { throw ChatGPTError(message: "Could not securely update the ChatGPT connection.") }
    }
    static func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTError(message: "Could not remove the ChatGPT credentials. Unlock your iPhone and try again.") }
    }
}

@MainActor @Observable final class ChatGPTConnection: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var credentials: ChatGPTCredentials?
    private(set) var busy = false
    var error: String?
    var showWelcome = false
    private var webSession: ASWebAuthenticationSession?
    private var listener: ChatGPTLoopback?
    private var refreshTask: Task<ChatGPTCredentials, Error>?
    private var pendingClientID: String?
    private var generation = UUID()
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    var connected: Bool { credentials != nil }
    var usesPlan: Bool { credentials?.usesPlan == true }
    var email: String { credentials?.email ?? "ChatGPT account" }

    override init() {
        super.init()
        do {
            if let data = try ChatGPTKeychain.read("credentials") { credentials = try JSONDecoder().decode(ChatGPTCredentials.self, from: data) }
        } catch { self.error = "The saved ChatGPT connection could not be opened. \(error.localizedDescription)" }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    private func hostID() throws -> String {
        if let data = try ChatGPTKeychain.read("host"), let id = String(data: data, encoding: .utf8) { return id }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        try ChatGPTKeychain.write(Data(id.utf8), account: "host")
        return id
    }
    func connect() async {
        guard !busy else { return }
        busy = true; error = nil
        let version = generation
        defer { busy = false; webSession?.cancel(); webSession = nil; listener?.stop(); listener = nil }
        do {
            let state = try ChatGPTOAuth.random(), nonce = try ChatGPTOAuth.random(), verifier = try ChatGPTOAuth.random()
            if let refreshTask { _ = try await refreshTask.value }
            let pending = credentials
            let registeredClient = pending?.clientID ?? pendingClientID
            let loopback = ChatGPTLoopback()
            listener = loopback
            let redirect = try await loopback.start(expectedState: state)
            var url = URLComponents(string: ChatGPTOAuth.issuer + "/api/accounts/authorize")!
            var values = ["client_id": registeredClient ?? "dynamic_agent_client", "ext_agent_host_id": try hostID(), "response_type": "code", "redirect_uri": redirect.absoluteString, "scope": ChatGPTOAuth.scopes, "resource": ChatGPTOAuth.resource, "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": ChatGPTOAuth.challenge(verifier)]
            if let pending {
                values["id_token_hint"] = pending.idToken
                if !pending.email.isEmpty { values["login_hint"] = pending.email }
                if !pending.usesPlan { values["prompt"] = "consent" }
            } else if registeredClient == nil { values["agent_name_hint"] = "Spotter" }
            url.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
            let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "spotter") { _, failure in
                if failure != nil { loopback.fail(ChatGPTError(message: "ChatGPT sign-in was canceled. You can try again.")) }
            }
            session.presentationContextProvider = self
            webSession = session
            guard session.start() else { throw ChatGPTError(message: "Could not open ChatGPT sign-in.") }
            let callback = try await loopback.callback()
            let grant = try ChatGPTOAuth.callback(callback, state: state, clientID: registeredClient)
            pendingClientID = grant.clientID
            let token = try await tokenRequest(["grant_type": "authorization_code", "client_id": grant.clientID, "code": grant.code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "resource": ChatGPTOAuth.resource])
            let saved = try await validate(token, clientID: grant.clientID, nonce: nonce, prior: pending)
            guard version == generation else { throw CancellationError() }
            try save(saved)
            if saved.usesPlan && !saved.welcomed { showWelcome = true }
        } catch { self.error = error.localizedDescription }
    }
    func cancelSignIn() { generation = UUID(); listener?.fail(CancellationError()); webSession?.cancel() }
    func acknowledgeWelcome() {
        guard var saved = credentials else { return }
        saved.welcomed = true
        do { try save(saved); showWelcome = false } catch { self.error = error.localizedDescription }
    }
    private func save(_ value: ChatGPTCredentials) throws {
        try ChatGPTKeychain.write(JSONEncoder().encode(value), account: "credentials")
        credentials = value
    }
    private func tokenRequest(_ values: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/api/accounts/oauth/token")!)
        request.httpMethod = "POST"; request.httpBody = ChatGPTOAuth.form(values)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTError(message: "ChatGPT could not renew or complete sign-in. Please reconnect your account.") }
        return token
    }
    private func validate(_ token: [String: Any], clientID: String, nonce: String?, prior: ChatGPTCredentials?) async throws -> ChatGPTCredentials {
        guard let access = token["access_token"] as? String, !access.isEmpty,
              let idToken = token["id_token"] as? String ?? prior?.idToken,
              (token["token_type"] as? String)?.lowercased() == "bearer" else { throw ChatGPTError(message: "ChatGPT returned incomplete credentials.") }
        var claims: [String: Any]
        if token["id_token"] != nil {
            let (data, response) = try await URLSession.shared.data(from: URL(string: ChatGPTOAuth.issuer + "/.well-known/jwks.json")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let jwks = try JSONSerialization.jsonObject(with: data) as? [String: Any], let keys = jwks["keys"] as? [[String: Any]] else { throw ChatGPTError(message: "Could not verify ChatGPT’s signed identity. Try again.") }
            claims = try ChatGPTOAuth.verifyIDToken(idToken, jwks: keys, clientID: clientID, nonce: nonce)
        } else {
            guard nonce == nil, let prior else { throw ChatGPTError(message: "ChatGPT did not return a signed identity.") }
            claims = ["sub": prior.subject, "email": prior.email]
        }
        let subject = claims["sub"] as! String
        guard prior == nil || prior?.subject == subject else { throw ChatGPTError(message: "This ChatGPT connection belongs to another account. Disconnect first to change accounts.") }
        let scopes = (token["scope"] as? String)?.split(separator: " ").map(String.init) ?? (nonce == nil ? prior?.scopes ?? [] : [])
        return ChatGPTCredentials(clientID: clientID, subject: subject, email: claims["email"] as? String ?? "ChatGPT account", accessToken: access, refreshToken: token["refresh_token"] as? String ?? prior?.refreshToken, idToken: idToken, scopes: scopes, expiresAt: Date().addingTimeInterval(token["expires_in"] as? Double ?? 3600), welcomed: prior?.welcomed ?? false)
    }
    func accessToken() async throws -> String {
        guard let saved = credentials, saved.usesPlan else { throw ChatGPTError(message: "Continue with ChatGPT and allow plan usage to use this feature.") }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let refresh = saved.refreshToken else { throw ChatGPTError(message: "Your ChatGPT connection expired. Reconnect to continue.") }
        let version = generation
        let task = Task { @MainActor in
            let token = try await self.tokenRequest(["grant_type": "refresh_token", "client_id": saved.clientID, "refresh_token": refresh, "resource": ChatGPTOAuth.resource])
            let updated = try await self.validate(token, clientID: saved.clientID, nonce: nil, prior: saved)
            guard version == self.generation else { throw CancellationError() }
            try self.save(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }
    func disconnect() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        var revoked = credentials?.refreshToken == nil
        if let saved = credentials, let refresh = saved.refreshToken {
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: ChatGPTOAuth.issuer + "/.well-known/openid-configuration")!)
                let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if let endpoint = config?["revocation_endpoint"] as? String, let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com" {
                    for attempt in 0..<2 {
                        var request = URLRequest(url: url); request.httpMethod = "POST"
                        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                        request.httpBody = ChatGPTOAuth.form(["token": refresh, "token_type_hint": "refresh_token", "client_id": saved.clientID])
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if (response as? HTTPURLResponse)?.statusCode == 200 { revoked = true; break }
                        if attempt == 0 { try await Task.sleep(for: .seconds(1)) }
                    }
                }
            } catch { /* Local disconnect still clears protected credentials below. */ }
        }
        do {
            try ChatGPTKeychain.remove("credentials"); credentials = nil; pendingClientID = nil
            if !revoked { error = "Disconnected on this iPhone. Remote revocation could not be confirmed. Remove Spotter in ChatGPT settings to end its access there." }
        } catch { self.error = error.localizedDescription }
    }
}

// Dynamic OSS registration requires a real 127.0.0.1 callback. Bind only to
// loopback and keep the authentication session open while the listener runs.
@MainActor final class ChatGPTLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var expectedState = ""
    private var redirect: URL?
    func start(expectedState: String) async throws -> URL {
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in self.receive(connection, buffer: Data()) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    if let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") {
                        self.redirect = url; self.ready?.resume(returning: url); self.ready = nil
                    }
                case .failed(let error): self.fail(error)
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.fail(ChatGPTError(message: "ChatGPT sign-in timed out. Please try again."))
        }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }
    func callback() async throws -> URL {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func fail(_ error: Error) {
        ready?.resume(throwing: error); ready = nil
        finish(.failure(error))
    }
    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value; waiting?.resume(with: value); waiting = nil
        timeout?.cancel()
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            Task { @MainActor in
                let combined = buffer + (data ?? Data())
                guard combined.count <= 16384, error == nil else { connection.cancel(); return }
                guard let request = String(data: combined, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, buffer: combined) } else { connection.cancel() }
                    return
                }
                let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", let redirect = self.redirect,
                      let url = URL(string: String(parts[1]), relativeTo: redirect)?.absoluteURL,
                      url.host == "127.0.0.1", url.port == redirect.port, url.path == "/auth/callback",
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value == self.expectedState else {
                    connection.send(content: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }); return
                }
                // No credentials or authorization codes enter the page or app deep link.
                let body = "<!doctype html><html><body><p>Return to Spotter to finish connecting.</p><a href='spotter://chatgpt-connected'>Return to Spotter</a></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                self.finish(.success(url))
            }
        }
    }
    func stop() {
        timeout?.cancel(); listener?.cancel()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener = nil
        if result == nil { fail(CancellationError()) }
    }
}
