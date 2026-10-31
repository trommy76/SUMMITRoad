import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var profile = Profile() { didSet {
        if !loading && !applyingRemote && (oldValue.maxHR != profile.maxHR || oldValue.voiceCues != profile.voiceCues
                                          || oldValue.autoUpload != profile.autoUpload) {
            profile.settingsUpdatedAt = Date().timeIntervalSince1970
            profile.settingsDirty = true
            settingsChangeCount += 1
            onSettingsChanged?()
        }
        write(profile, "profile.json")
    } }
    @Published var plan: TrainingPlan? { didSet {
        if !loading && !applyingRemote {
            profile.planUpdatedAt = Date().timeIntervalSince1970
            profile.planDirty = true
            planChangeCount += 1
            onPlanChanged?()
        }
        if !loading { if let p = plan { write(p, "plan.json") } else { remove("plan.json") } }
    } }
    @Published var hasPreviousPlan = false
    /// Unsent plan changes. A plan edited under an older version (timestamp but no revision record) counts as unsent, so
    /// updating can never quietly replace it with an older copy from the server.
    var planIsDirty: Bool { profile.planDirty ?? (profile.planRev == nil && profile.planUpdatedAt != nil) }
    var settingsIsDirty: Bool { profile.settingsDirty ?? (profile.settingsRev == nil && profile.settingsUpdatedAt != nil) }
    var planChangeCount = 0               // counts local plan edits so a finished push only clears "unsent" if nothing changed meanwhile
    var settingsChangeCount = 0
    @Published var rides: [RideSummary] = []
    @Published var routes: [Route] = []

    /// Hooks used by the optional home-server sync.
    var onRideSaved: ((RideSummary) -> Void)?
    var onRideDeleted: ((UUID) -> Void)?
    var onFTPAdded: ((FTPEntry) -> Void)?
    var onPlanChanged: (() -> Void)?
    var onSettingsChanged: (() -> Void)?
    private var loading = true            // true while loading from disk, so that does not count as a change
    var applyingRemote = false            // true while applying plan/settings that came from the server

    let dir: URL
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

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let custom = ProcessInfo.processInfo.environment["SUMMITROAD_DATA_DIR"], !custom.isEmpty {
            dir = URL(fileURLWithPath: custom, isDirectory: true)    // testing / separate profiles on one Mac
        } else {
            dir = base.appendingPathComponent("SummitTrainer", isDirectory: true)
        }
        for sub in ["", "rides", "fit", "routes"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        if let p: Profile = read("profile.json") { profile = p }
        if let p: TrainingPlan = read("plan.json") { plan = p }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("rides"), includingPropertiesForKeys: nil) {
            rides = files.filter { $0.pathExtension == "json" }
                .compactMap { try? decoder.decode(RideSummary.self, from: Data(contentsOf: $0)) }
                .sorted { $0.date > $1.date }
        }
        reloadRoutes()
        hasPreviousPlan = FileManager.default.fileExists(atPath: dir.appendingPathComponent("plan.previous.json").path)
        loading = false
    }

    /// Adopt the server's plan. If this Mac had unsent changes they are kept as the "previous plan" so nothing is lost.
    func applyRemote(plan newPlan: TrainingPlan?, rev: Int, updated: Double) {
        if let local = plan, planIsDirty { backupPreviousPlan(local) }
        applyingRemote = true
        plan = newPlan
        profile.planRev = rev
        profile.planUpdatedAt = updated
        profile.planDirty = false
        applyingRemote = false
    }

    func markPlanPushed(rev: Int, changeCount: Int) {
        profile.planRev = rev
        if planChangeCount == changeCount { profile.planDirty = false }
    }

    func applyRemote(maxHR: Int, voiceCues: Bool, autoUpload: Bool, rev: Int, updated: Double) {
        applyingRemote = true
        profile.maxHR = maxHR
        profile.voiceCues = voiceCues
        profile.autoUpload = autoUpload
        profile.settingsRev = rev
        profile.settingsUpdatedAt = updated
        profile.settingsDirty = false
        applyingRemote = false
    }

    func markSettingsPushed(rev: Int, changeCount: Int) {
        profile.settingsRev = rev
        if settingsChangeCount == changeCount { profile.settingsDirty = false }
    }

    private func backupPreviousPlan(_ p: TrainingPlan) {
        write(p, "plan.previous.json")
        hasPreviousPlan = true
    }

    /// Brings back the plan this Mac replaced when it took the server's version. It counts as a new edit and syncs.
    func restorePreviousPlan() {
        guard let p: TrainingPlan = read("plan.previous.json") else { return }
        plan = p
        remove("plan.previous.json")
        hasPreviousPlan = false
    }

    private func write<T: Encodable>(_ v: T, _ name: String) {
        if let d = try? encoder.encode(v) { try? d.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }
    private func read<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(T.self, from: d)
    }
    private func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }

    func save(ride: RideSummary, fromSync: Bool = false) {
        if let i = rides.firstIndex(where: { $0.id == ride.id }) { rides[i] = ride } else { rides.insert(ride, at: 0) }
        write(ride, "rides/\(ride.id.uuidString).json")
        try? FITEncoder.encode(ride).write(to: fitURL(for: ride), options: .atomic)
        if !fromSync { onRideSaved?(ride) }
    }

    // MARK: Routes (GPX files kept in the app's data folder, never synced or uploaded)

    var routesDir: URL { dir.appendingPathComponent("routes", isDirectory: true) }

    func reloadRoutes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: routesDir, includingPropertiesForKeys: nil)) ?? []
        routes = files.filter { $0.pathExtension.lowercased() == "gpx" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? RouteBuilder.route(fromGPX: data, name: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Validates a GPX file and copies it into the routes folder under the given name.
    @discardableResult
    func importRoute(from url: URL, name: String) throws -> Route {
        let data = try Data(contentsOf: url)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()'&."))
        var clean = String(name.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { clean = "Route" }
        let route = try RouteBuilder.route(fromGPX: data, name: clean)      // throws if it is not usable
        try data.write(to: routesDir.appendingPathComponent(clean + ".gpx"), options: .atomic)
        reloadRoutes()
        return route
    }

    func deleteRoute(_ r: Route) {
        try? FileManager.default.removeItem(at: routesDir.appendingPathComponent(r.name + ".gpx"))
        reloadRoutes()
    }

    func fitURL(for r: RideSummary) -> URL { dir.appendingPathComponent("fit/\(r.id.uuidString).fit") }

    func delete(ride: RideSummary, fromSync: Bool = false) {
        rides.removeAll { $0.id == ride.id }
        remove("rides/\(ride.id.uuidString).json")
        remove("fit/\(ride.id.uuidString).fit")
        remove("cards/\(ride.id.uuidString).png")
        if !fromSync { onRideDeleted?(ride.id) }
    }

    func setFTP(_ ftp: Double, method: String) {
        profile.ftp = ftp
        profile.ftpDate = Date()
        let entry = FTPEntry(date: Date(), ftp: ftp, method: method)
        profile.ftpHistory.append(entry)
        onFTPAdded?(entry)
    }
}

@MainActor
final class AppState: ObservableObject {
    let store = Store()
    let ble = BLEManager()
    let strava = StravaClient()
    let updater = Updater()
    lazy var sync = SyncClient(store: store)
    /// Held for the life of the app so the Mac (and display) never idle-sleeps mid-ride.
    private let sleepBlocker = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .userInitiated],
        reason: "SummitRoad is running")

    @Published var session: RideSession?
    @Published var review: RideSummary?
    @Published var uploadMessage = ""

    init() {
        ble.onRememberTrainer = { [weak self] id in self?.store.profile.trainerID = id.uuidString }
        ble.onRememberHR = { [weak self] id in self?.store.profile.hrID = id.uuidString }
        store.onRideSaved = { [weak self] r in self?.sync.rideSaved(r) }
        store.onRideDeleted = { [weak self] id in self?.sync.rideDeleted(id) }
        store.onFTPAdded = { [weak self] e in self?.sync.ftpAdded(e) }
        store.onPlanChanged = { [weak self] in self?.sync.planChanged() }
        store.onSettingsChanged = { [weak self] in self?.sync.settingsChanged() }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.updater.check(silent: true)
            await self?.sync.autoSync()
        }
        sync.isRiding = { [weak self] in self?.session != nil }
        sync.startAutoPull()
        ble.reconnectKnown(trainerID: store.profile.trainerID, hrID: store.profile.hrID)
    }

    var ftp: Double? { store.profile.ftp }

    func start(_ workout: Workout, planned: PlannedWorkout? = nil, intensity: Double = 1.0) {
        guard session == nil else { return }
        let s = RideSession(workout: workout, planned: planned, ble: ble,
                            ftp: workout.kind.isTest ? workout.ftp : (store.profile.ftp ?? workout.ftp),
                            maxHR: store.profile.maxHR, voice: store.profile.voiceCues)
        s.intensityScale = intensity
        s.waitForPedal = store.profile.waitForPedal ?? true
        s.autoPause = store.profile.autoPause ?? true
        s.onFinish = { [weak self] summary in self?.finish(summary, workout: workout) }
        session = s
    }

    /// Starts a simulated route ride: the trainer's resistance follows the road's gradient.
    func startRoute(_ ride: RouteRide, effort: Double = 0.65) {
        guard session == nil else { return }
        let ftpNow = store.profile.ftp ?? 200
        let estimate = RoutePhysics.estimatedSeconds(route: ride.route, from: ride.startM, to: ride.endM, power: ftpNow * effort, mass: ride.mass)
        var w = Workout(name: "\(ride.route.name) · \(String(format: "%.1f", ride.length / 1000)) km", kind: .adhoc, ftp: ftpNow,
                        segments: [Segment(label: "Route", seconds: max(60, Int(estimate)), startPct: 0, kind: .endurance, erg: false)])
        w.note = "Simulated ride: the trainer's resistance follows the road's gradient, so your effort decides your speed."
        let s = RideSession(workout: w, planned: nil, ble: ble, ftp: ftpNow, maxHR: store.profile.maxHR, voice: store.profile.voiceCues)
        s.route = ride
        s.waitForPedal = store.profile.waitForPedal ?? true
        s.autoPause = store.profile.autoPause ?? true
        s.onFinish = { [weak self] summary in self?.finish(summary, workout: w) }
        session = s
    }

    func discardSession() {
        session?.onFinish = nil
        session?.end()
        session = nil
    }

    private func finish(_ raw: RideSummary, workout: Workout) {
        var r = raw
        let prevFTP = store.profile.ftp
        r.feedback = FeedbackEngine.feedback(summary: r, workout: workout, maxHR: store.profile.maxHR, previousFTP: prevFTP)

        // Plan bookkeeping and adaptive advice
        if var plan = store.plan, let pid = r.plannedID, let i = plan.workouts.firstIndex(where: { $0.id == pid }),
           r.durationSeconds > 120 {
            plan.workouts[i].completedDate = Date()
            plan.workouts[i].completedScore = r.score?.total
            var rides = store.rides
            rides.insert(r, at: 0)
            if !workout.kind.isTest {
                let advice = PlanAdvisor.assess(plan: plan, rides: rides)
                plan.levelAdjust = max(-2, min(2, plan.levelAdjust + advice.levelDelta))
                r.feedback.append(advice.headline + ". " + advice.detail)
                if advice.retest { r.feedback.append("Recommendation: schedule an FTP test within the next week.") }
            }
            store.plan = plan
        }

        if r.durationSeconds > 120 { store.save(ride: r) }
        session = nil
        review = r

        if r.durationSeconds > 120 && store.profile.autoUpload && strava.connected {
            Task { await uploadToStrava(r) }
        }
    }

    func applyFTP(_ ftp: Double, from ride: RideSummary) {
        store.setFTP(ftp, method: ride.workoutKind.title)
    }

    func uploadToStrava(_ ride: RideSummary) async {
        guard let data = try? Data(contentsOf: store.fitURL(for: ride)) else {
            uploadMessage = "Ride file not found."
            return
        }
        uploadMessage = "Uploading to Strava…"
        do {
            let desc = "SummitRoad · \(ride.workoutName) · NP \(Int(ride.np)) W · TSS \(Int(ride.tss))"
                + (ride.score.map { " · Score \(Int($0.total))" } ?? "")
            let id = try await strava.upload(fit: data, name: ride.workoutName, description: desc,
                                             virtual: ride.samples.contains { $0.lat != nil })
            var updated = ride
            updated.stravaID = id
            store.save(ride: updated)
            if review?.id == ride.id { review = updated }
            uploadMessage = "Uploaded to Strava."
        } catch {
            uploadMessage = error.localizedDescription
        }
    }
}
