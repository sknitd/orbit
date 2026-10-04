import Foundation
import Security
import SwiftUI

@MainActor
enum OnlineServiceKeychain {
    private static let service = "com.sknitd.NotchOrbitPlus.online-services"
    static func read(_ account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed { throw OnlineServiceError.message("Unlock your login Keychain in Keychain Access, then retry.") }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw OnlineServiceError.message("Could not read the saved key from Keychain (\(status)).")
        }
        return text
    }
    static func save(_ value: String, account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw OnlineServiceError.message("Enter a valid API key or token.")
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let changes: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw OnlineServiceError.message("Keychain could not save the key (\(updated)).") }
        var item = query; item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw OnlineServiceError.message("Keychain could not save the key (\(status)).") }
    }
    static func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OnlineServiceError.message("Keychain could not remove the key (\(status)).") }
    }
}

enum OnlineServiceError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

private final class OnlineNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // API credentials may never travel to a redirect target.
        completionHandler(nil)
    }
}

enum OnlineServiceHTTPS {
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.fragment == nil, let host = url.host?.lowercased() else { return false }
        let hosts: Set<String> = ["geocoding-api.open-meteo.com", "api.open-meteo.com", "www.alphavantage.co",
            "api.stripe.com", "api.lemonsqueezy.com", "api.gumroad.com", "live.dodopayments.com",
            "api.polar.sh", "api.paddle.com", "api.frankfurter.dev"]
        return hosts.contains(host) || host.range(of: #"^[a-z0-9][a-z0-9-]*\.myshopify\.com$"#, options: .regularExpression) != nil
    }
    static func url(_ base: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base) else { throw OnlineServiceError.message("Invalid provider URL.") }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, allowed(url) else { throw OnlineServiceError.message("Provider URL must use an approved HTTPS host.") }
        return url
    }
    static func load(_ url: URL, headers: [String: String] = [:], jsonBody: Data? = nil) async throws -> Data {
        guard allowed(url) else { throw OnlineServiceError.message("Unapproved provider URL.") }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: OnlineNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = jsonBody == nil ? "GET" : "POST"
        if jsonBody != nil {
            guard url.host?.hasSuffix(".myshopify.com") == true, url.path.hasSuffix("/graphql.json") else {
                throw OnlineServiceError.message("Only the read-only Shopify GraphQL query may use POST.")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = jsonBody
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw OnlineServiceError.message("Provider request failed (HTTP \(status)). Check the key, read permissions and provider rate limit.")
            }
            guard response.expectedContentLength <= 4 * 1024 * 1024 else { throw OnlineServiceError.message("Provider response is too large.") }
            var data = Data()
            for try await byte in bytes {
                if data.count >= 4 * 1024 * 1024 { throw OnlineServiceError.message("Provider response exceeds 4 MB.") }
                data.append(byte)
            }
            try Task.checkCancellation(); return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as OnlineServiceError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw OnlineServiceError.message("The provider could not be reached. Check your connection and try again.")
        }
    }
}

@MainActor
struct OnlineStatusView: View {
    let busy: Bool
    let error: String?
    let cancel: @MainActor () -> Void
    var body: some View {
        if busy { HStack { ProgressView().controlSize(.small); Text("Loading…"); Button("Cancel") { cancel() } } }
        if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
    }
}

func onlineAmount(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
func onlineRoundedUSD(_ value: Decimal) -> String {
    let formatter = NumberFormatter(); formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: value)) ?? onlineAmount(value)
}
