import Foundation
import CryptoKit
import Security

struct ChatGPTError: LocalizedError {
    let message: String
    var code: String? = nil
    var errorDescription: String? { message }
    var isUsageLimit: Bool { code == "subscription_sharing_usage_limit_exceeded" }
}

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ value: String) -> Data? {
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTError(message: "Could not prepare secure sign-in. Try again.") }
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    static func callback(_ url: URL, state: String, clientID: String?) throws -> (code: String, clientID: String) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("state") == state, items.filter({ $0.name == "state" }).count == 1 else { throw ChatGPTError(message: "Sign-in could not be verified. Please start again.") }
        if value("error") != nil { throw ChatGPTError(message: "ChatGPT sign-in was declined. You can try again when ready.") }
        guard let code = value("code"), !code.isEmpty, let issued = value("client_id") ?? clientID,
              issued != "dynamic_agent_client", !issued.isEmpty, clientID == nil || issued == clientID else {
            throw ChatGPTError(message: "ChatGPT registration was incomplete or changed accounts. Please start again.")
        }
        return (code, issued)
    }

    // Verify the signed identity before trusting account metadata or saving credentials.
    static func verifyIDToken(_ token: String, jwks: [[String: Any]], clientID: String, nonce: String?, now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let body = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let kid = header["kid"] as? String, let jwk = jwks.first(where: { $0["kid"] as? String == kid }) else {
            throw ChatGPTError(message: "ChatGPT returned an invalid signed identity.")
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        var valid = false
        if header["alg"] as? String == "RS256", jwk["kty"] as? String == "RSA",
           let n = (jwk["n"] as? String).flatMap(decode), let e = (jwk["e"] as? String).flatMap(decode) {
            func der(_ tag: UInt8, _ bytes: Data) -> Data {
                let count = bytes.count
                let length: [UInt8] = count < 128 ? [UInt8(count)] : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
                return Data([tag] + length) + bytes
            }
            func integer(_ data: Data) -> Data {
                var bytes = Data(data.drop(while: { $0 == 0 }))
                if bytes.first.map({ $0 >= 128 }) == true { bytes.insert(0, at: 0) }
                return der(0x02, bytes)
            }
            let keyData = der(0x30, integer(n) + integer(e))
            let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
            if let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) {
                valid = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
            }
        } else if header["alg"] as? String == "ES256", jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256",
                  let x = (jwk["x"] as? String).flatMap(decode), let y = (jwk["y"] as? String).flatMap(decode),
                  let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            valid = key.isValidSignature(sig, for: signed)
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard valid, claims["iss"] as? String == issuer, audiences.contains(clientID),
              (audiences.count <= 1 || claims["azp"] as? String == clientID),
              (claims["azp"] == nil || claims["azp"] as? String == clientID),
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              nonce == nil || claims["nonce"] as? String == nonce,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30 else {
            throw ChatGPTError(message: "ChatGPT identity verification failed. Please sign in again.")
        }
        return claims
    }
}

struct ChatGPTDraft: Decodable {
    var csv: String
    var explanation: String
    static func parse(_ text: String) throws -> Self {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = text.data(using: .utf8), let draft = try? JSONDecoder().decode(Self.self, from: data) else {
            throw ChatGPTError(message: "ChatGPT did not return a usable CSV draft. Try again with more detail.")
        }
        guard !draft.csv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTError(message: draft.explanation.isEmpty ? "ChatGPT could not prepare a faithful draft. Add more detail and try again." : draft.explanation)
        }
        return draft
    }
}

struct ChatGPTStream {
    private(set) var text = ""
    private(set) var output: [[String: Any]] = []
    private(set) var completed = false
    private var items: [Int: [String: Any]] = [:]
    private var parts: [Int: [Int: String]] = [:]
    private var refusal = ""

    private mutating func updateText(_ event: [String: Any], append: Bool) {
        let outputIndex = event["output_index"] as? Int ?? 0
        let contentIndex = event["content_index"] as? Int ?? 0
        if append { parts[outputIndex, default: [:]][contentIndex, default: ""] += event["delta"] as? String ?? "" }
        else { parts[outputIndex, default: [:]][contentIndex] = event["text"] as? String ?? "" }
        text = parts.keys.sorted().flatMap { index in
            (parts[index] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        }.joined()
    }

    mutating func consume(_ data: String) throws {
        guard data != "[DONE]", let bytes = data.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "response.output_text.delta": updateText(event, append: true)
        case "response.output_text.done": updateText(event, append: false)
        case "response.refusal.delta": refusal += event["delta"] as? String ?? ""
        case "response.refusal.done": refusal = event["refusal"] as? String ?? refusal
        case "response.output_item.done":
            if let index = event["output_index"] as? Int, let item = event["item"] as? [String: Any] { items[index] = item }
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else { throw ChatGPTError(message: "ChatGPT did not complete its response.") }
            let finalOutput = response["output"] as? [[String: Any]] ?? []
            if !finalOutput.isEmpty {
                for (index, item) in finalOutput.enumerated() {
                    items[index] = (items[index] ?? [:]).merging(item) { old, new in
                        // Retain completed streamed content when final metadata
                        // omits it, including encrypted reasoning for tool turns.
                        if new is NSNull { return old }
                        if let values = new as? [Any], values.isEmpty { return old }
                        return new
                    }
                }
            }
            output = items.keys.sorted().compactMap { items[$0] }
            let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            let finalText = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }.joined()
            // Some routes supply the full content in item/text events and only
            // completion metadata at the end. Never erase a received answer.
            if !finalText.isEmpty { text = finalText }
            if text.isEmpty {
                text = content.filter { $0["type"] as? String == "refusal" }.compactMap { $0["refusal"] as? String }.joined()
                if text.isEmpty { text = refusal }
            }
            if !text.isEmpty, finalText.isEmpty, let index = output.lastIndex(where: { $0["type"] as? String == "message" }),
               (output[index]["content"] as? [[String: Any]] ?? []).isEmpty {
                output[index]["content"] = [["type": "output_text", "text": text]]
            }
            if !text.isEmpty && !output.contains(where: { $0["type"] as? String == "message" }) {
                output.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
            }
            completed = true
        case "response.failed", "error":
            let response = event["response"] as? [String: Any] ?? event
            let error = response["error"] as? [String: Any] ?? response
            let code = error["code"] as? String
            let message = code == "subscription_sharing_usage_limit_exceeded" ? "ChatGPT usage limit reached. Review your plan or Spotter’s limit in Manage usage." : code == "subscription_sharing_user_not_eligible" ? "ChatGPT plan usage is unavailable for this account or workspace." : error["message"] as? String ?? "ChatGPT could not complete this request. Try again."
            throw ChatGPTError(message: message, code: code)
        case "response.incomplete": throw ChatGPTError(message: "ChatGPT’s response was incomplete. Try again.")
        default: break
        }
    }
    func finish() throws {
        guard completed else { throw ChatGPTError(message: "The connection ended before ChatGPT finished. Your data has not changed.") }
    }
}
