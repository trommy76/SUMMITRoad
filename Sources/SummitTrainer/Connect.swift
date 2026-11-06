import Foundation

/// What the server's "Connect an app" QR code carries: `summitroad://connect?server=…&user=…&password=…`.
/// The password is an app password made for this device, so it can be revoked on the website any time.
struct ConnectLink: Equatable {
    var server: String
    var user: String
    var password: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "summitroad", url.host?.lowercased() == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        server = value("server").trimmingCharacters(in: .whitespacesAndNewlines)
        user = value("user").trimmingCharacters(in: .whitespacesAndNewlines)
        password = value("password")
        if server.isEmpty || user.isEmpty || password.isEmpty { return nil }
    }
}
