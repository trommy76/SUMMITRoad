import Foundation
import AppKit

/// Optional sync with a SummitRoad home server (see /server). Rides, .FIT files and FTP history are kept per user.
/// Rides never change once saved, so syncing is "add whatever the other side is missing", plus delete markers.
@MainActor
final class SyncClient: ObservableObject {
    @Published var status = ""
    @Published var busy = false
    @Published var lastSync: Date?
    @Published var serverVersion: String?
    @Published var planConflict = false      // the plan changed on this Mac and on the server: waiting for the user to choose
    var isRiding: () -> Bool = { false }
    private var pullTask: Task<Void, Never>?
    private var lastAutoPull = Date.distantPast

    private let store: Store
    private var settingsPush: Task<Void, Never>?
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
            case .unauthorized: return "The server rejected the username or password. If two-factor sign-in is on, use an app password from the website's Settings page instead of your normal password."
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
        req.setValue("SummitRoad", forHTTPHeaderField: "X-Requested-With")   // required by the server for writes
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
            serverVersion = ver
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
    func planChanged() {
        guard configured else { return }
        Task { await pushPlan() }
    }

    func settingsChanged() {
        guard configured else { return }
        settingsPush?.cancel()
        settingsPush = Task {                       // wait a moment so dragging a stepper sends one update
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { await pushSettings() }
        }
    }

    func autoSync() async {
        guard configured else { return }
        lastAutoPull = Date()
        await refreshServerVersion()
        await syncAll(upload: store.profile.syncUploadOK == true, download: true, quiet: true)
    }

    /// Keeps this Mac current while the app stays open: checks the server every few minutes and whenever the app comes
    /// to the front. Skipped during a ride so the plan never changes underneath you.
    func startAutoPull() {
        let seconds = Double(ProcessInfo.processInfo.environment["SUMMITROAD_SYNC_INTERVAL"] ?? "") ?? 300
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                await self?.backgroundPull(minGap: 0)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.backgroundPull(minGap: 60) }
        }
    }

    private func backgroundPull(minGap: TimeInterval) async {
        guard configured, !busy, !isRiding(), Date().timeIntervalSince(lastAutoPull) >= minGap else { return }
        await autoSync()
    }

    private func refreshServerVersion() async {
        if let (d, code) = try? await send("GET", "api/ping"), code == 200 {
            serverVersion = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["server"] as? String
        }
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
        await refreshServerVersion()
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
            let notes = await syncDocs(upload: upload, download: download)
            lastSync = Date()
            var parts: [String] = []
            if up > 0 { parts.append("uploaded \(up)") }
            if down > 0 { parts.append("downloaded \(down)") }
            if removed > 0 { parts.append("removed \(removed) deleted") }
            if failed > 0 { parts.append("\(failed) failed") }
            parts += notes
            if !quiet || !parts.isEmpty || failed > 0 {
                status = "Sync complete: " + (parts.isEmpty ? "everything is up to date." : parts.joined(separator: ", ") + ".")
            }
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: Plan and settings: versioned documents
    //
    // The server numbers every saved version. A Mac remembers the revision it last synced and whether it has changes
    // the server hasn't seen. That gives three cases, so nothing is overwritten by accident:
    //   server unchanged, Mac changed  -> send the change (the server checks the revision it was based on)
    //   server changed, Mac unchanged  -> take the server's version
    //   both changed                   -> a conflict: keep both and ask (plan), or newest edit wins (settings)

    struct SettingsDoc: Codable {
        var maxHR: Int
        var voiceCues: Bool
        var autoUpload: Bool
    }
    private struct DocIn<T: Decodable>: Decodable {
        let updated: Double
        let rev: Int?
        let deleted: Bool?
        let data: T?
    }
    private struct DocOut<T: Encodable>: Encodable {
        let updated: Double
        let deleted: Bool
        let data: T?
        let baseRev: Int
        let force: Bool
        let device: String
    }
    private struct PutReply: Decodable { let rev: Int? }
    private enum PutResult { case applied(Int), conflict }

    private var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    private func fetchDoc<T: Decodable>(_ name: String, as: T.Type) async throws -> DocIn<T>? {
        let (d, code) = try await send("GET", "api/docs/\(name)")
        if code == 404 { return nil }
        guard code == 200 else { throw SyncError.http(code) }
        return try decoder.decode(DocIn<T>.self, from: d)
    }

    private func putDoc<T: Encodable>(_ name: String, updated: Double, deleted: Bool, data: T?, baseRev: Int, force: Bool = false) async throws -> PutResult {
        let body = try encoder.encode(DocOut(updated: updated, deleted: deleted, data: data, baseRev: baseRev, force: force, device: deviceName))
        let (d, code) = try await send("PUT", "api/docs/\(name)", body: body)
        if code == 409 { return .conflict }
        guard (200..<300).contains(code) else { throw SyncError.http(code) }
        return .applied((try? decoder.decode(PutReply.self, from: d))?.rev ?? baseRev + 1)
    }

    private var currentSettings: SettingsDoc {
        SettingsDoc(maxHR: store.profile.maxHR, voiceCues: store.profile.voiceCues, autoUpload: store.profile.autoUpload)
    }

    private func conflictMessage() {
        status = "Your training plan was also changed on another Mac. Nothing was overwritten. Open Settings > Home Server to choose which to keep."
    }

    private func pushPlan() async {
        do {
            let count = store.planChangeCount
            let result = try await putDoc("plan", updated: store.profile.planUpdatedAt ?? Date().timeIntervalSince1970,
                                          deleted: store.plan == nil, data: store.plan, baseRev: store.profile.planRev ?? 0)
            switch result {
            case .applied(let rev):
                store.markPlanPushed(rev: rev, changeCount: count)
                planConflict = false
            case .conflict:
                planConflict = true
                conflictMessage()
            }
        } catch { status = "Sync failed: \(error.localizedDescription)" }
    }

    private func pushSettings() async {
        do {
            let count = store.settingsChangeCount
            let result = try await putDoc("settings", updated: store.profile.settingsUpdatedAt ?? Date().timeIntervalSince1970,
                                          deleted: false, data: currentSettings, baseRev: store.profile.settingsRev ?? 0)
            switch result {
            case .applied(let rev): store.markSettingsPushed(rev: rev, changeCount: count)
            case .conflict: _ = await syncDocs(upload: false, download: true)      // sort it out with the rule for settings
            }
        } catch { status = "Sync failed: \(error.localizedDescription)" }
    }

    /// The user chose the server's plan in a conflict. This Mac's version is kept as the "previous plan".
    func keepServerPlan() async {
        do {
            guard let r = try await fetchDoc("plan", as: TrainingPlan.self) else { return }
            store.applyRemote(plan: r.deleted == true ? nil : r.data, rev: r.rev ?? 1, updated: r.updated)
            planConflict = false
            status = "Using the server's plan. The version on this Mac was kept: Settings > Home Server > Restore the plan this Mac replaced."
        } catch { status = "Sync failed: \(error.localizedDescription)" }
    }

    /// The user chose this Mac's plan in a conflict. The server keeps the version it replaces in its history.
    func useThisMacsPlan() async {
        do {
            let count = store.planChangeCount
            if case .applied(let rev) = try await putDoc("plan", updated: Date().timeIntervalSince1970, deleted: store.plan == nil, data: store.plan,
                                                         baseRev: store.profile.planRev ?? 0, force: true) {
                store.markPlanPushed(rev: rev, changeCount: count)
                planConflict = false
                status = "This Mac's plan is now the server's plan. The other version is in the website's version history."
            }
        } catch { status = "Sync failed: \(error.localizedDescription)" }
    }

    /// `upload` also sends a plan or settings that predate sync and have never been changed since (only if the server has none).
    private func syncDocs(upload: Bool, download: Bool) async -> [String] {
        var notes: [String] = []
        do {
            // ----- Plan
            let remotePlan = try await fetchDoc("plan", as: TrainingPlan.self)
            let planDirty = store.planIsDirty
            let planRev = store.profile.planRev ?? 0
            if let r = remotePlan {
                let remoteRev = r.rev ?? 1
                if remoteRev == planRev {
                    planConflict = false
                    if planDirty {
                        let count = store.planChangeCount
                        switch try await putDoc("plan", updated: store.profile.planUpdatedAt ?? Date().timeIntervalSince1970,
                                                deleted: store.plan == nil, data: store.plan, baseRev: planRev) {
                        case .applied(let rev): store.markPlanPushed(rev: rev, changeCount: count); notes.append("training plan uploaded")
                        case .conflict: planConflict = true
                        }
                    }
                } else if !planDirty {
                    planConflict = false
                    if download {
                        store.applyRemote(plan: r.deleted == true ? nil : r.data, rev: remoteRev, updated: r.updated)
                        notes.append("training plan updated from the server")
                    }
                } else {
                    planConflict = true                      // changed here AND on the server: keep both, let the user choose
                    notes.append("plan conflict: choose which to keep in Settings")
                }
            } else if store.plan != nil && (planDirty || upload) {
                let count = store.planChangeCount
                if case .applied(let rev) = try await putDoc("plan", updated: store.profile.planUpdatedAt ?? Date().timeIntervalSince1970,
                                                             deleted: false, data: store.plan, baseRev: 0) {
                    store.markPlanPushed(rev: rev, changeCount: count)
                    notes.append("training plan uploaded")
                }
            }

            // ----- Settings (small: if both sides changed, the newest edit wins)
            let remoteSettings = try await fetchDoc("settings", as: SettingsDoc.self)
            let setDirty = store.settingsIsDirty
            let setRev = store.profile.settingsRev ?? 0
            if let r = remoteSettings {
                let remoteRev = r.rev ?? 1
                let takeRemote = { (s: SettingsDoc) in
                    self.store.applyRemote(maxHR: s.maxHR, voiceCues: s.voiceCues, autoUpload: s.autoUpload, rev: remoteRev, updated: r.updated)
                    notes.append("settings updated from the server")
                }
                if remoteRev == setRev {
                    if setDirty {
                        let count = store.settingsChangeCount
                        if case .applied(let rev) = try await putDoc("settings", updated: store.profile.settingsUpdatedAt ?? Date().timeIntervalSince1970,
                                                                     deleted: false, data: currentSettings, baseRev: setRev) {
                            store.markSettingsPushed(rev: rev, changeCount: count)
                        }
                    }
                } else if !setDirty {
                    if download, let s = r.data { takeRemote(s) }
                } else if (store.profile.settingsUpdatedAt ?? 0) > r.updated {
                    let count = store.settingsChangeCount
                    if case .applied(let rev) = try await putDoc("settings", updated: store.profile.settingsUpdatedAt ?? Date().timeIntervalSince1970,
                                                                 deleted: false, data: currentSettings, baseRev: setRev, force: true) {
                        store.markSettingsPushed(rev: rev, changeCount: count)
                    }
                } else if download, let s = r.data {
                    takeRemote(s)
                }
            } else if setDirty || upload {
                let count = store.settingsChangeCount
                if case .applied(let rev) = try await putDoc("settings", updated: store.profile.settingsUpdatedAt ?? Date().timeIntervalSince1970,
                                                             deleted: false, data: currentSettings, baseRev: 0) {
                    store.markSettingsPushed(rev: rev, changeCount: count)
                }
            }
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
        return notes
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
