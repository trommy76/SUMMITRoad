import Foundation
import AppKit
import Network
import Security

enum Keychain {
    private static let service = "SummitTrainer"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

enum StravaError: Error, LocalizedError {
    case notConnected, http(Int, String), timeout
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Strava is not connected. Open Settings to connect."
        case .http(let c, let m): return "Strava error \(c): \(m)"
        case .timeout: return "Strava is still processing the upload. Check your Strava feed shortly."
        }
    }
}

/// Strava OAuth (loopback redirect on http://localhost:8723/callback) and FIT upload.
/// In your Strava API app settings, set "Authorization Callback Domain" to: localhost
@MainActor
final class StravaClient: ObservableObject {
    @Published var athlete: String?
    @Published var status = ""
    @Published var connected = Keychain.get("strava.refresh") != nil

    private var listener: NWListener?
    private let port: UInt16 = 8723
    private var redirect: String { "http://localhost:\(port)/callback" }

    // MARK: OAuth

    func connect(clientID: String, clientSecret: String) {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            status = "Enter your Strava Client ID and Client Secret first."
            return
        }
        Keychain.set(clientSecret, for: "strava.secret")
        status = "Waiting for you to approve in the browser…"
        startListener(clientID: clientID, secret: clientSecret)
        var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "activity:write,activity:read")
        ]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    func disconnect() {
        ["strava.access", "strava.refresh", "strava.expires"].forEach { Keychain.delete($0) }
        connected = false
        athlete = nil
        status = "Disconnected."
    }

    private func startListener(clientID: String, secret: String) {
        listener?.cancel()
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else {
            status = "Could not open local port \(port) for the Strava callback."
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                var code: String?
                if let d = data, let text = String(data: d, encoding: .utf8),
                   let line = text.components(separatedBy: "\r\n").first,
                   let range = line.range(of: "code=") {
                    let rest = line[range.upperBound...]
                    code = String(rest.prefix { $0 != "&" && $0 != " " })
                }
                let ok = code != nil
                let body = ok ? "<h2>SummitRoad is connected to Strava.</h2><p>You can close this tab.</p>"
                              : "<h2>Strava authorization failed.</h2>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body style='font-family:-apple-system;text-align:center;margin-top:80px'>\(body)</body></html>"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                Task { @MainActor in
                    self?.listener?.cancel()
                    self?.listener = nil
                    if let code = code {
                        await self?.exchange(code: code, clientID: clientID, secret: secret)
                    } else {
                        self?.status = "Strava authorization was denied."
                    }
                }
            }
        }
        l.start(queue: .main)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_at: Int
        let athlete: Athlete?
        struct Athlete: Decodable { let firstname: String?; let lastname: String? }
    }

    private func form(_ pairs: [String: String]) -> Data {
        let s = pairs.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
        return Data(s.utf8)
    }

    private func exchange(code: String, clientID: String, secret: String) async {
        var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": clientID, "client_secret": secret, "code": code, "grant_type": "authorization_code"])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                status = "Strava token exchange failed."
                return
            }
            let t = try JSONDecoder().decode(TokenResponse.self, from: data)
            save(t)
            Keychain.set(clientID, for: "strava.clientid")
            athlete = [t.athlete?.firstname, t.athlete?.lastname].compactMap { $0 }.joined(separator: " ")
            connected = true
            status = "Connected to Strava."
        } catch {
            status = "Strava connection error: \(error.localizedDescription)"
        }
    }

    private func save(_ t: TokenResponse) {
        Keychain.set(t.access_token, for: "strava.access")
        Keychain.set(t.refresh_token, for: "strava.refresh")
        Keychain.set(String(t.expires_at), for: "strava.expires")
    }

    private func accessToken() async throws -> String {
        guard let refresh = Keychain.get("strava.refresh") else { throw StravaError.notConnected }
        let exp = Int(Keychain.get("strava.expires") ?? "0") ?? 0
        if let access = Keychain.get("strava.access"), exp > Int(Date().timeIntervalSince1970) + 60 { return access }
        guard let id = Keychain.get("strava.clientid"), let secret = Keychain.get("strava.secret") else {
            throw StravaError.notConnected
        }
        var req = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": id, "client_secret": secret, "refresh_token": refresh, "grant_type": "refresh_token"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw StravaError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        save(t)
        return t.access_token
    }

    // MARK: Upload

    private struct UploadStatus: Decodable {
        let id: Int?
        let status: String?
        let error: String?
        let activity_id: Int?
    }

    /// Uploads a FIT file. Returns the Strava activity id once processing completes.
    func upload(fit: Data, name: String, description: String) async throws -> Int? {
        let token = try await accessToken()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ k: String, _ v: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        field("data_type", "fit")
        field("name", name)
        field("description", description)
        field("trainer", "1")
        field("commute", "0")
        field("sport_type", "Ride")
        field("external_id", "summit-\(UUID().uuidString)")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"ride.fit\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fit)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        status = "Uploading to Strava…"
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw StravaError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let first = try JSONDecoder().decode(UploadStatus.self, from: data)
        guard let uploadID = first.id else { return first.activity_id }

        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var r = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(uploadID)")!)
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (d, _) = try await URLSession.shared.data(for: r)
            let s = try JSONDecoder().decode(UploadStatus.self, from: d)
            if let err = s.error, !err.isEmpty { throw StravaError.http(422, err) }
            if let aid = s.activity_id {
                status = "Uploaded to Strava."
                return aid
            }
        }
        throw StravaError.timeout
    }
}
