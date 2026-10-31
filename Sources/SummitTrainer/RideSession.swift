import Foundation
import AVFoundation

enum RideState { case ready, waiting, running, paused, finished }

enum CoachMessages {
    static let general = [
        "You're doing great. Keep it smooth.",
        "Strong work. Stay relaxed in the shoulders.",
        "Every pedal stroke is building a faster you.",
        "This is where fitness is made. Keep going.",
        "Breathe deep, loose hands, quiet upper body.",
        "Consistency beats heroics. You're right on it.",
        "Nice and steady. You've got this."
    ]
    static let hard = [
        "It's supposed to feel hard. That's the work paying off.",
        "Stay tall, breathe out slowly. One minute at a time.",
        "Your future self is thanking you right now.",
        "Dig in. You've done harder than this.",
        "Don't negotiate with the interval. Just turn the pedals.",
        "Strong legs, calm mind. Stay on target."
    ]
    static let easy = [
        "Easy now. Spin loose, sip some fluid.",
        "Recover well. The next one is easier if you let this one work.",
        "Shake out your arms, relax your grip, breathe."
    ]
    static func random(for kind: SegmentKind) -> String {
        switch kind {
        case .recovery, .warmup, .cooldown: return easy.randomElement() ?? ""
        case .threshold, .vo2, .anaerobic, .test: return hard.randomElement() ?? ""
        default: return general.randomElement() ?? ""
        }
    }
}

@MainActor
final class RideSession: ObservableObject {
    let workout: Workout
    let planned: PlannedWorkout?
    let ftp: Double
    let maxHR: Int
    let ble: BLEManager

    @Published var state: RideState = .ready
    @Published var elapsed = 0
    @Published var segIndex = 0
    @Published var segElapsed = 0
    @Published var power = 0
    @Published var hr: Int?
    @Published var cadence: Int?
    @Published var targetPower: Int?
    @Published var message = "Ready when you are. Start pedalling to begin."
    @Published var countdown: Int?
    @Published var intensityScale = 1.0
    @Published var voice: Bool
    @Published var samples: [Sample] = []
    @Published var np = 0.0
    @Published var tss = 0.0
    @Published var kj = 0.0
    @Published var avgPower = 0.0
    @Published var testEnded = false
    @Published var waitingPower = 0          // live readings shown while waiting for the first pedal strokes
    @Published var waitingCadence: Int?
    var waitForPedal = true                  // false: Start Workout begins at once
    var autoPause = true                     // pause when pedalling stops, resume when it starts again
    @Published var autoPaused = false        // the current pause was automatic, so pedalling resumes it
    /// Set for a simulated route ride: gradient is sent to the trainer and progress comes from power, gradient and weight.
    var route: RouteRide?
    @Published var distanceM = 0.0           // metres ridden along the chosen section
    @Published var routeGrade = 0.0
    @Published var routeEle = 0.0
    @Published var speedKmh = 0.0
    var lastGradeSent: Double?
    private var lastGradeSentAt = -100
    private var routeCues = Set<Int>()
    /// Where the "are they pedalling?" check gets its readings (replaceable so it can be tested without a trainer).
    lazy var readings: () -> LiveReading = { [weak self] in self?.ble.snapshot() ?? LiveReading() }

    var onFinish: ((RideSummary) -> Void)?

    private var timer: Timer?
    private var waitTimer: Timer?
    private var pauseTimer: Timer?
    private var stoppedSeconds = 0
    private var pedalPolls = 0
    private var lastSentTarget = -1
    private var lowCadenceSeconds = 0
    private var highHRSeconds = 0
    private var cadenceWarnedAt = -100
    private var hrWarnedAt = -100
    private let speech = AVSpeechSynthesizer()
    private var startDate = Date()

    init(workout: Workout, planned: PlannedWorkout?, ble: BLEManager, ftp: Double, maxHR: Int, voice: Bool) {
        self.workout = workout
        self.planned = planned
        self.ble = ble
        self.ftp = ftp
        self.maxHR = maxHR
        self.voice = voice
    }

    var segment: Segment { workout.segments[min(segIndex, workout.segments.count - 1)] }
    var totalSeconds: Int { workout.totalSeconds }
    var intervalRemaining: Int { segment.seconds - segElapsed }
    var workoutRemaining: Int { totalSeconds - elapsed }
    var routeRemaining: Double { max(0, (route?.length ?? 0) - distanceM) }
    var avgSpeedKmh: Double { elapsed > 0 ? distanceM / Double(elapsed) * 3.6 : 0 }
    var routeClimbed: Double { route.map { $0.route.ascent(from: $0.startM, to: $0.startM + distanceM) } ?? 0 }
    var endTime: Date {
        if route != nil {                                          // remaining distance at the average speed so far
            let avg = elapsed >= 30 ? distanceM / Double(elapsed) : 8.0
            return Date().addingTimeInterval(routeRemaining / max(3.0, avg))
        }
        return Date().addingTimeInterval(Double(workoutRemaining))
    }

    var nextSegment: Segment? {
        segIndex + 1 < workout.segments.count ? workout.segments[segIndex + 1] : nil
    }

    var currentTarget: Int? {
        guard segment.erg else { return nil }
        return Int(segment.targetWatts(ftp: ftp, at: segElapsed).rounded())
    }

    var intervalLabel: String {
        let s = segment
        if let g = s.group, let t = s.groupTotal, s.kind.isWork { return "\(s.kind.title) \(g) of \(t)" }
        return s.label
    }

    // Interval stats
    var intervalSamples: [Sample] { samples.filter { $0.seg == segIndex } }
    var intPower: Int {
        let s = intervalSamples
        return s.isEmpty ? 0 : s.map { $0.power }.reduce(0, +) / s.count
    }
    var intHR: Int? {
        let h = intervalSamples.compactMap { $0.hr }
        return h.isEmpty ? nil : h.reduce(0, +) / h.count
    }
    var intCadence: Int? {
        let c = intervalSamples.compactMap { $0.cad }
        return c.isEmpty ? nil : c.reduce(0, +) / c.count
    }

    // MARK: Control

    /// "Start Workout": wait until the rider is actually pedalling, then begin. Skips the wait for the demo trainer or when
    /// the setting is off.
    func armStart() {
        guard state == .ready else { return }
        if ble.demoMode || !waitForPedal { begin(); return }
        state = .waiting
        pedalPolls = 0
        waitingPower = 0
        waitingCadence = nil
        message = "Start pedalling to begin."
        say("Start pedalling whenever you're ready. The workout begins when you do.")
        waitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollForPedalling() }
        }
    }

    /// Pedalling = real power (20 W+) or a cadence of 30 rpm+, seen for three checks in a row (1.5 s), so one bump
    /// of the pedals doesn't start it.
    private func pollForPedalling() {
        guard state == .waiting else { return }
        let r = readings()
        waitingPower = r.power ?? 0
        waitingCadence = r.cadence
        let pedalling = (r.power ?? 0) >= 20 || (r.cadence ?? 0) >= 30
        pedalPolls = pedalling ? pedalPolls + 1 : 0
        if pedalPolls >= 3 { begin() }
    }

    func begin() {
        guard state == .ready || state == .waiting else { return }
        waitTimer?.invalidate()
        waitTimer = nil
        state = .running
        startDate = Date()
        ble.startWorkout()
        onSegmentStart(first: true)
        applyTarget(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func togglePause() {
        if state == .running {
            pause(auto: false)
            say("Paused. Take a breath. Press resume when you're ready.")
        } else if state == .paused {
            resume()
            say("Back at it. Let's go!")
        }
    }

    private func pause(auto: Bool) {
        guard state == .running else { return }
        state = .paused
        autoPaused = auto
        stoppedSeconds = 0
        timer?.invalidate()
        timer = nil
        ble.pauseWorkout()
        ble.setTargetPower(50)
        if auto {
            message = "Paused: you stopped pedalling. Start pedalling to carry on."
            pedalPolls = 0
            pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollForResume() }
            }
        } else {
            message = "Paused. Press Resume when you're ready."
        }
    }

    private func resume() {
        guard state == .paused else { return }
        pauseTimer?.invalidate()
        pauseTimer = nil
        state = .running
        autoPaused = false
        stoppedSeconds = 0
        message = "Back at it."
        ble.startWorkout()
        applyTarget(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// After an automatic pause: same test as the start (real power or a cadence, three checks in a row), so a single
    /// bump of the pedals doesn't resume it.
    private func pollForResume() {
        guard state == .paused, autoPaused else { return }
        let r = readings()
        let pedalling = (r.power ?? 0) >= 20 || (r.cadence ?? 0) >= 30
        pedalPolls = pedalling ? pedalPolls + 1 : 0
        if pedalPolls >= 3 {
            resume()
            say("Back at it. Let's go!")
        }
    }

    /// Stopped = no power and no cadence. Route rides are left alone (coasting down a descent is normal there) and so is the
    /// ramp test, which ends when you can't keep going.
    private func checkStopped() -> Bool {
        guard autoPause, route == nil, workout.kind != .ftpRamp else { return false }
        let stopped = power < 10 && (cadence ?? 0) < 10
        stoppedSeconds = stopped ? stoppedSeconds + 1 : 0
        return stoppedSeconds >= 5
    }

    func skipInterval() {
        guard state == .running || state == .paused else { return }
        advanceSegment()
    }

    func adjustIntensity(_ delta: Double) {
        intensityScale = max(0.5, min(1.5, intensityScale + delta))
        applyTarget(force: true)
        say("Intensity \(Int((intensityScale * 100).rounded())) percent")
    }

    func end() {
        timer?.invalidate()
        timer = nil
        waitTimer?.invalidate()
        waitTimer = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        if state != .finished {
            state = .finished
            ble.setTargetPower(0)
            ble.stopWorkout()
            onFinish?(makeSummary())
        }
    }

    // MARK: Tick

    private func tick() {
        guard state == .running else { return }
        if route != nil { routeTick(); return }
        let seg = segment
        let r = readings()
        power = r.power ?? 0
        hr = r.hr
        cadence = r.cadence
        if checkStopped() {
            pause(auto: true)
            say("Paused: you stopped pedalling. Start pedalling to carry on.")
            return
        }
        let base = seg.erg ? Int(seg.targetWatts(ftp: ftp, at: segElapsed).rounded()) : nil
        targetPower = base.map { Int((Double($0) * intensityScale).rounded()) }

        // Ad-hoc rides are scored against the intensity the rider chose; plan rides keep the planned target.
        let recorded = workout.kind == .adhoc ? targetPower : base
        samples.append(Sample(t: elapsed, power: power, hr: hr, cad: cadence, target: recorded, kind: seg.kind, seg: segIndex, speed: r.speed))
        updateMetrics()

        elapsed += 1
        segElapsed += 1
        applyTarget(force: false)
        coach(for: seg)

        if workout.kind == .ftpRamp && seg.kind == .test && checkRampFailure(target: base ?? 0) {
            testEnded = true
            say("That's it. Great effort. Test complete.")
            end()
            return
        }

        if segElapsed >= seg.seconds { advanceSegment() }
    }

    private func updateMetrics() {
        let p = samples.map { Double($0.power) }
        avgPower = Metrics.mean(p)
        np = Metrics.normalizedPower(p)
        kj = p.reduce(0, +) / 1000.0
        tss = Metrics.tss(np: np, ftp: ftp, seconds: p.count)
    }

    private func checkRampFailure(target: Int) -> Bool {
        guard segElapsed >= 15, samples.count >= 10, target > 0 else { return false }
        let last = samples.suffix(10)
        let avgP = Double(last.map { $0.power }.reduce(0, +)) / 10.0
        let cads = last.compactMap { $0.cad }
        let lowCad = cads.count >= 8 && cads.reduce(0, +) / cads.count < 45
        return avgP < Double(target) * 0.75 || lowCad
    }

    /// One second of a route ride: work out the speed from the power just ridden, move along the road, and tell the
    /// trainer the new gradient.
    private func routeTick() {
        guard let rr = route else { return }
        let r = readings()
        power = r.power ?? 0
        hr = r.hr
        cadence = r.cadence
        let here = rr.route.sample(at: rr.startM + distanceM)
        routeGrade = here.grade
        routeEle = here.ele
        let v = RoutePhysics.speed(power: Double(power), grade: here.grade, mass: rr.mass)       // m/s
        speedKmh = v * 3.6
        let where_ = rr.route.coordinate(at: rr.startM + distanceM)
        samples.append(Sample(t: elapsed, power: power, hr: hr, cad: cadence, target: nil, kind: .endurance, seg: 0,
                              speed: speedKmh, alt: here.ele, grade: here.grade, lat: where_?.lat, lon: where_?.lon))
        updateMetrics()
        elapsed += 1
        segElapsed += 1
        distanceM += v
        sendRouteGrade(force: false)
        routeCue(rr)
        if distanceM >= rr.length {
            say("Route complete. Great ride!")
            end()
        }
    }

    private func sendRouteGrade(force: Bool) {
        guard let rr = route else { return }
        let g = rr.route.sample(at: rr.startM + distanceM).grade
        if force || lastGradeSent == nil || abs(g - (lastGradeSent ?? 0)) >= 0.3 || elapsed - lastGradeSentAt >= 10 {
            lastGradeSent = g
            lastGradeSentAt = elapsed
            ble.setGrade(g)
        }
    }

    private func routeCue(_ rr: RouteRide) {
        let frac = distanceM / max(1, rr.length)
        for pct in [25, 50, 75] where frac >= Double(pct) / 100 && !routeCues.contains(pct) {
            routeCues.insert(pct)
            say("\(pct) percent done. \(String(format: "%.1f", routeRemaining / 1000)) kilometres to go.")
        }
        if routeRemaining <= 1000 && rr.length > 3000 && !routeCues.contains(1000) {
            routeCues.insert(1000)
            say("One kilometre to go.")
        }
    }

    private func applyTarget(force: Bool) {
        if route != nil { sendRouteGrade(force: force); return }
        let seg = segment
        if seg.erg {
            let t = Int((seg.targetWatts(ftp: ftp, at: segElapsed) * intensityScale).rounded())
            if force || t != lastSentTarget {
                lastSentTarget = t
                ble.setTargetPower(t)
            }
        } else if force || lastSentTarget != -2 {
            lastSentTarget = -2
            ble.setGrade(2.0)
        }
    }

    private func advanceSegment() {
        segIndex += 1
        segElapsed = 0
        countdown = nil
        if segIndex >= workout.segments.count {
            segIndex = workout.segments.count - 1
            say("Workout complete. Outstanding effort!")
            end()
            return
        }
        onSegmentStart(first: false)
        applyTarget(force: true)
    }

    // MARK: Coaching cues

    private func say(_ text: String) {
        message = text
        if voice {
            let u = AVSpeechUtterance(string: text)
            u.rate = 0.5
            speech.speak(u)
        }
    }

    private func onSegmentStart(first: Bool) {
        let s = segment
        let dur = formatTime(s.seconds)
        if first {
            if workout.kind.isTest {
                say("Let's find your FTP. Start easy and let the effort build. Ride honestly.")
            } else {
                say("Let's go! \(workout.name). Warm up smoothly, and settle into your rhythm.")
            }
            return
        }
        switch s.kind {
        case .recovery:
            say("Recover. Spin easy for \(dur). Breathe and drink.")
        case .cooldown:
            say("Cool-down time. Spin easy, you earned it.")
        case .test where workout.kind == .ftpRamp:
            if segIndex == 1 {
                say("The ramp starts now. The trainer raises the power every minute. Keep spinning and stay relaxed.")
            } else if segIndex % 5 == 0 {
                say("Step up to \(Int(s.startPct)) watts. Keep spinning, stay relaxed.")
            }
        case .test:
            say("All-out 20 minutes! Pace it evenly. Start at a strong but sustainable effort, and empty the tank in the last 5.")
        default:
            if let g = s.group, let t = s.groupTotal, s.kind.isWork, t > 1 {
                let w = Int((s.startWatts(ftp: ftp)).rounded())
                if g == t {
                    say("Final interval, \(g) of \(t). \(w) watts for \(dur). Finish strong!")
                } else {
                    say("Interval \(g) of \(t). \(w) watts for \(dur). You've got this.")
                }
            } else {
                say("\(s.label): \(Int(s.startWatts(ftp: ftp).rounded())) watts for \(dur).")
            }
        }
    }

    private func coach(for seg: Segment) {
        let rem = seg.seconds - segElapsed      // after increment
        let totalRem = totalSeconds - elapsed

        if rem <= 5 && rem > 0 && seg.seconds >= 20 {
            countdown = rem
        } else if totalRem <= 5 && totalRem > 0 {
            countdown = totalRem
        } else {
            countdown = nil
        }

        if workout.kind == .ftpRamp && seg.kind == .test { return }

        if seg.seconds >= 150 && rem == 60 {
            say("One minute to go. \(CoachMessages.random(for: seg.kind))")
        } else if seg.seconds >= 90 && rem == 30 {
            if let n = nextSegment, n.kind == .recovery || n.kind == .cooldown {
                say("30 seconds left. Almost done with this one, you're doing great.")
            } else {
                say("30 seconds left. Hold your form.")
            }
        } else if rem == 10 && seg.seconds >= 30 {
            if workout.kind == .ftpRamp && seg.kind == .warmup {
                say("The ramp starts in 10 seconds. The trainer will raise the power every minute. Just keep pedalling.")
            } else if let n = nextSegment {
                say("10 seconds. Next up: \(n.label) at \(Int(n.startWatts(ftp: ftp).rounded())) watts.")
            } else {
                say("10 seconds to the finish. Give it everything!")
            }
        } else if seg.seconds >= 240 && segElapsed == seg.seconds / 2 && seg.kind.isWork {
            say("Halfway through this interval (\(formatTime(rem)) to go). Strong work.")
        } else if seg.seconds >= 300 && segElapsed > 0 && segElapsed % 150 == 0 && rem > 75 {
            say(CoachMessages.random(for: seg.kind))
        } else if elapsed == totalSeconds / 4 {
            say("A quarter of the workout is done. Nice rhythm.")
        } else if elapsed == totalSeconds / 2 {
            say("Halfway through the workout. You're doing great, keep it up.")
        } else if elapsed == totalSeconds * 3 / 4 {
            say("Three quarters done. Only \(formatTime(totalRem)) left. Finish it off.")
        } else {
            cueFeedback(seg: seg)
        }
    }

    private func cueFeedback(seg: Segment) {
        guard seg.kind.isWork, segElapsed > 20 else { lowCadenceSeconds = 0; highHRSeconds = 0; return }
        if let range = seg.kind.cadenceRange, let c = cadence {
            if Double(c) < range.lowerBound - 5 { lowCadenceSeconds += 1 } else { lowCadenceSeconds = 0 }
            if lowCadenceSeconds >= 20 && elapsed - cadenceWarnedAt > 90 {
                cadenceWarnedAt = elapsed
                say("Cadence is a bit low at \(c). Spin up toward \(Int(range.lowerBound + 5)) or more.")
                return
            }
        }
        if let h = hr, let range = seg.kind.hrRange {
            if Double(h) / Double(maxHR) > range.upperBound + 0.05 { highHRSeconds += 1 } else { highHRSeconds = 0 }
            if highHRSeconds >= 45 && elapsed - hrWarnedAt > 180 {
                hrWarnedAt = elapsed
                say("Heart rate is running high. Relax, breathe, sip some water, and keep the cadence smooth.")
            }
        }
    }

    // MARK: Summary

    private func makeSummary() -> RideSummary {
        let p = samples.map { Double($0.power) }
        let npv = Metrics.normalizedPower(p)
        let hrs = samples.compactMap { $0.hr }
        let cads = samples.compactMap { $0.cad }.filter { $0 > 0 }
        let dur = samples.count

        var result: Double?
        if workout.kind == .ftpRamp {
            let testP = samples.filter { $0.kind == .test }.map { Double($0.power) }
            let best = Metrics.bestAverage(testP, window: 60)
            if best > 0 { result = (best * 0.75).rounded() }
        } else if workout.kind == .ftp20 {
            let testP = samples.filter { $0.kind == .test }.map { Double($0.power) }
            if testP.count >= 15 * 60 { result = (Metrics.mean(testP) * 0.95).rounded() }
        }

        var r = RideSummary(
            date: startDate, workoutName: workout.name, workoutKind: workout.kind, plannedID: planned?.id,
            ftp: ftp, plannedSeconds: totalSeconds, durationSeconds: dur,
            avgPower: Metrics.mean(p), np: npv, intensityFactor: ftp > 0 ? npv / ftp : 0,
            tss: Metrics.tss(np: npv, ftp: ftp, seconds: dur), kj: p.reduce(0, +) / 1000.0,
            avgHR: hrs.isEmpty ? nil : hrs.reduce(0, +) / hrs.count,
            maxHR: hrs.max(),
            avgCadence: cads.isEmpty ? nil : cads.reduce(0, +) / cads.count,
            score: Scoring.score(workout: workout, samples: samples, maxHR: maxHR),
            feedback: [], ftpResult: result, stravaID: nil, samples: samples)
        r.feedback = []
        return r
    }
}
