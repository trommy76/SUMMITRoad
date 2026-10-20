import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var profile = Profile() { didSet { write(profile, "profile.json") } }
    @Published var plan: TrainingPlan? { didSet { if let p = plan { write(p, "plan.json") } else { remove("plan.json") } } }
    @Published var rides: [RideSummary] = []

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
        dir = base.appendingPathComponent("SummitTrainer", isDirectory: true)
        for sub in ["", "rides", "fit"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        if let p: Profile = read("profile.json") { profile = p }
        if let p: TrainingPlan = read("plan.json") { plan = p }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("rides"), includingPropertiesForKeys: nil) {
            rides = files.filter { $0.pathExtension == "json" }
                .compactMap { try? decoder.decode(RideSummary.self, from: Data(contentsOf: $0)) }
                .sorted { $0.date > $1.date }
        }
    }

    private func write<T: Encodable>(_ v: T, _ name: String) {
        if let d = try? encoder.encode(v) { try? d.write(to: dir.appendingPathComponent(name), options: .atomic) }
    }
    private func read<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(T.self, from: d)
    }
    private func remove(_ name: String) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }

    func save(ride: RideSummary) {
        if let i = rides.firstIndex(where: { $0.id == ride.id }) { rides[i] = ride } else { rides.insert(ride, at: 0) }
        write(ride, "rides/\(ride.id.uuidString).json")
        try? FITEncoder.encode(ride).write(to: fitURL(for: ride), options: .atomic)
    }

    func fitURL(for r: RideSummary) -> URL { dir.appendingPathComponent("fit/\(r.id.uuidString).fit") }

    func delete(ride: RideSummary) {
        rides.removeAll { $0.id == ride.id }
        remove("rides/\(ride.id.uuidString).json")
        remove("fit/\(ride.id.uuidString).fit")
    }

    func setFTP(_ ftp: Double, method: String) {
        profile.ftp = ftp
        profile.ftpDate = Date()
        profile.ftpHistory.append(FTPEntry(date: Date(), ftp: ftp, method: method))
    }
}

@MainActor
final class AppState: ObservableObject {
    let store = Store()
    let ble = BLEManager()
    let strava = StravaClient()
    let updater = Updater()

    @Published var session: RideSession?
    @Published var review: RideSummary?
    @Published var uploadMessage = ""

    init() {
        ble.onRememberTrainer = { [weak self] id in self?.store.profile.trainerID = id.uuidString }
        ble.onRememberHR = { [weak self] id in self?.store.profile.hrID = id.uuidString }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.updater.check(silent: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.ble.reconnectKnown(trainerID: self.store.profile.trainerID, hrID: self.store.profile.hrID)
        }
    }

    var ftp: Double? { store.profile.ftp }

    func start(_ workout: Workout, planned: PlannedWorkout? = nil) {
        guard session == nil else { return }
        let s = RideSession(workout: workout, planned: planned, ble: ble,
                            ftp: workout.kind.isTest ? workout.ftp : (store.profile.ftp ?? workout.ftp),
                            maxHR: store.profile.maxHR, voice: store.profile.voiceCues)
        s.onFinish = { [weak self] summary in self?.finish(summary, workout: workout) }
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
            let id = try await strava.upload(fit: data, name: ride.workoutName, description: desc)
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
