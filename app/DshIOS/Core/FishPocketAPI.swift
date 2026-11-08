import Foundation
import Security

/// The Fish Pocket service: an account with credits that pays for DeepSeek models,
/// next to signing in to DeepSeek and adding an API key.
///
/// The service is a separate, closed-source backend. This app only talks to its
/// public HTTP API: account calls carry the user's session, and the engine's
/// `fish-pocket` model route carries a per-device runtime key that can only spend
/// credits. Without `FishPocketAPIURL` in Info.plist (forks, local builds) the
/// whole feature stays hidden.
enum FishPocketAPI {
    static let baseURL: URL? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "FishPocketAPIURL") as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" else { return nil }
        return url
    }()

    static var available: Bool { baseURL != nil }

    /// The engine credential the `fish-pocket` route reads (`llm-pi-ai` profile in engine/ios.patch.yml).
    static let runtimeKeyRef = "FISH_POCKET_RUNTIME_KEY"
    /// The engine's model route id.
    static let provider = "fish-pocket"
}

/// A failed Fish Pocket call: the server's `{error: {code, message}}`, or a transport failure.
struct FishPocketError: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var resendAt: Date?

    var errorDescription: String? { message }

    static func transport(_ error: Error) -> FishPocketError {
        FishPocketError(status: 0, code: "network", message: String(localized: "网络连接失败，请稍后再试。"))
    }
}

/// Plain JSON calls to the Fish Pocket API.
struct FishPocketHTTP: Sendable {
    let base: URL

    func send(_ method: String, _ path: String, body: JSON? = nil, bearer: String? = nil) async throws -> JSON {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FishPocketError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
        guard (200..<300).contains(status) else {
            let error = reply["error"]
            throw FishPocketError(
                status: status,
                code: error["code"].string ?? "HTTP_\(status)",
                message: error["message"].string ?? String(localized: "请求失败（HTTP \(status)）"),
                resendAt: error["resendAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        return reply
    }
}

/// The Fish Pocket session and runtime key, kept in the Keychain on this device only.
enum FishPocketKeychain {
    private static let service = "com.wsw.dsh-ios.fish-pocket"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store a value; nil removes it.
    static func write(_ account: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
