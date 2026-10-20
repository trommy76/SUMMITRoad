import Foundation

/// Optional sync with a SummitRoad home server (see /server). Rides, .FIT files and FTP history are kept per user.
/// Rides never change once saved, so syncing is "add whatever the other side is missing", plus delete markers.
@MainActor
final class SyncClient: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var lastSync: Date?

    private let store: Store
    private let passwordKey = "sync.password"

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    enum SyncError: Error, LocalizedError {
        case notConfigured, unauthorized, http(Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sync is not set up."
            case .unauthorized: return "The server rejected the username or password."
            case .http(let c): return "Server error \(c)."
            }
        }
    }

    init(store: Store) { self.store = store }

    // MARK: Configuration

    var baseURL: URL? {
        guard let s = store.profile.syncURL, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var configured: Bool {
        baseURL != nil && !(store.profile.syncUser ?? "").isEmpty && Keychain.get(passwordKey) != nil
    }

    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return s }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func authHeader(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, type: String = "application/json",
                      base: URL? = nil, auth: String? = nil) async throws -> (Data, Int) {
        guard let base = base ?? baseURL else { throw SyncError.notConfigured }
        let header: String
        if let auth = auth {
            header = auth
        } else if let u = store.profile.syncUser, let p = Keychain.get(passwordKey) {
            header = authHeader(user: u, password: p)
        } else {
            throw SyncError.notConfigured
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(header, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        if let b = body {
            req.httpBody = b
            req.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw SyncError.unauthorized }
        return (d, code)
    }

    /// Tests the login and, if it works, saves it. Returns true on success.
    func connect(urlString: String, user: String, password: String) async -> Bool {
        let norm = SyncClient.normalize(urlString)
        let u = user.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: norm), !u.isEmpty, !password.isEmpty else {
            status = "Enter the server address, username and password."
            return false
        }
        busy = true
        defer { busy = false }
        status = "Connecting…"
        do {
            let (d, code) = try await send("GET", "api/ping", base: url, auth: authHeader(user: u, password: password))
            guard code == 200 else { throw SyncError.http(code) }
            let ver = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["server"] as? String
            store.profile.syncURL = norm
            store.profile.syncUser = u
            Keychain.set(password, for: passwordKey)
            status = "Connected as \(u)" + (ver.map { " (server v\($0))" } ?? "") + "."
            return true
        } catch {
            status = "Could not connect: \(error.localizedDescription)"
            return false
        }
    }

    func disconnect() {
        store.profile.syncURL = nil
        store.profile.syncUser = nil
        store.profile.syncUploadOK = nil
        Keychain.delete(passwordKey)
        status = "Sync turned off. Your local data is untouched."
    }

    // MARK: Automatic hooks

    func rideSaved(_ r: RideSummary) {
        guard configured else { return }
        Task { _ = await pushRide(r) }
    }

    func rideDeleted(_ id: UUID) {
        guard configured else { return }
        Task { _ = try? await send("DELETE", "api/rides/\(id.uuidString)") }
    }

    func ftpAdded(_ e: FTPEntry) {
        guard configured else { return }
        Task { _ = await pushFTP(e) }
    }

    /// Runs shortly after launch. Always downloads; uploads only if the user has agreed to upload their data.
    func autoSync() async {
        guard configured else { return }
        await syncAll(upload: store.profile.syncUploadOK == true, download: true, quiet: true)
    }

    // MARK: Push

    private func pushRide(_ r: RideSummary) async -> Bool {
        do {
            let json = try Data(contentsOf: store.dir.appendingPathComponent("rides/\(r.id.uuidString).json"))
            let (_, code) = try await send("PUT", "api/rides/\(r.id.uuidString)", body: json)
            if code == 410 {                               // deleted elsewhere
                store.delete(ride: r, fromSync: true)
                return false
            }
            guard (200..<300).contains(code) else { throw SyncError.http(code) }
            let fit = (try? Data(contentsOf: store.fitURL(for: r))) ?? FITEncoder.encode(r)
            _ = try await send("PUT", "api/rides/\(r.id.uuidString)/fit", body: fit, type: "application/octet-stream")
            return true
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
            return false
        }
    }

    private func pushFTP(_ e: FTPEntry) async -> Bool {
        do {
            let (_, code) = try await send("PUT", "api/ftp/\(e.id.uuidString)", body: try encoder.encode(e))
            return (200..<300).contains(code)
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Full sync

    private struct RemoteRide: Decodable {
        let id: String
        let deleted: Bool?
    }

    /// Two-way sync. `upload` sends local rides/FTP results the server lacks; `download` fetches the server's.
    func syncAll(upload: Bool, download: Bool, quiet: Bool = false) async {
        guard configured, !busy else { return }
        busy = true
        defer { busy = false }
        if !quiet { status = "Syncing…" }
        var up = 0, down = 0, removed = 0, failed = 0
        do {
            let (data, code) = try await send("GET", "api/rides")
            guard code == 200 else { throw SyncError.http(code) }
            let remote = try decoder.decode([RemoteRide].self, from: data)
            let active = Set(remote.filter { $0.deleted != true }.map { $0.id.uppercased() })
            let deleted = Set(remote.filter { $0.deleted == true }.map { $0.id.uppercased() })

            for r in store.rides {
                let id = r.id.uuidString.uppercased()
                if deleted.contains(id) {
                    if download { store.delete(ride: r, fromSync: true); removed += 1 }
                } else if upload && !active.contains(id) {
                    if await pushRide(r) { up += 1 } else { failed += 1 }
                }
            }

            if download {
                let local = Set(store.rides.map { $0.id.uuidString.uppercased() })
                for id in active where !local.contains(id) {
                    let (d, c) = try await send("GET", "api/rides/\(id)")
                    if c == 200, let ride = try? decoder.decode(RideSummary.self, from: d) {
                        store.save(ride: ride, fromSync: true)
                        down += 1
                    } else { failed += 1 }
                }
            }

            try await syncFTP(upload: upload, download: download, up: &up, down: &down)
            lastSync = Date()
            var parts: [String] = []
            if up > 0 { parts.append("uploaded \(up)") }
            if down > 0 { parts.append("downloaded \(down)") }
            if removed > 0 { parts.append("removed \(removed) deleted") }
            if failed > 0 { parts.append("\(failed) failed") }
            if !quiet || !parts.isEmpty || failed > 0 {
                status = "Sync complete: " + (parts.isEmpty ? "everything is up to date." : parts.joined(separator: ", ") + ".")
            }
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func syncFTP(upload: Bool, download: Bool, up: inout Int, down: inout Int) async throws {
        let (data, code) = try await send("GET", "api/ftp")
        guard code == 200 else { throw SyncError.http(code) }
        let remote = try decoder.decode([FTPEntry].self, from: data)
        let remoteIDs = Set(remote.map { $0.id })
        let localIDs = Set(store.profile.ftpHistory.map { $0.id })

        if upload {
            for e in store.profile.ftpHistory where !remoteIDs.contains(e.id) {
                if await pushFTP(e) { up += 1 }
            }
        }
        if download {
            let missing = remote.filter { !localIDs.contains($0.id) }
            if !missing.isEmpty {
                var p = store.profile
                p.ftpHistory = (p.ftpHistory + missing).sorted { $0.date < $1.date }
                if let latest = p.ftpHistory.last, (p.ftpDate ?? .distantPast) < latest.date {
                    p.ftp = latest.ftp
                    p.ftpDate = latest.date
                }
                store.profile = p
                down += missing.count
            }
        }
    }
}
