import Foundation

enum Scoring {

    /// Smooths power with a 5 s trailing average to ignore pedal-stroke noise.
    private static func smoothed(_ samples: [Sample]) -> [Double] {
        var out: [Double] = []
        for i in 0..<samples.count {
            let lo = max(0, i - 4)
            var sum = 0.0
            for j in lo...i { sum += Double(samples[j].power) }
            out.append(sum / Double(i - lo + 1))
        }
        return out
    }

    /// Time (s) into its segment for each sample.
    private static func segmentOffsets(_ samples: [Sample]) -> [Int] {
        var out: [Int] = []
        var lastSeg = -1
        var off = 0
        for s in samples {
            if s.seg != lastSeg { lastSeg = s.seg; off = 0 }
            out.append(off)
            off += 1
        }
        return out
    }

    static func score(workout: Workout, samples: [Sample], maxHR: Int) -> ScoreBreakdown? {
        if workout.kind.isTest { return nil }
        if workout.segments.allSatisfy({ !$0.erg }) { return nil }   // free ride: nothing to score against
        guard !samples.isEmpty else { return nil }

        let sm = smoothed(samples)
        let offs = segmentOffsets(samples)

        // Completion: 40% time, 60% time spent in work segments.
        let total = max(1, workout.totalSeconds)
        let timeFrac = min(1.0, Double(samples.count) / Double(total))
        let plannedWork = max(1, workout.workSeconds)
        let doneWork = samples.filter { $0.kind.isWork }.count
        let workFrac = workout.workSeconds == 0 ? timeFrac : min(1.0, Double(doneWork) / Double(plannedWork))
        let completion = (0.4 * timeFrac + 0.6 * workFrac) * 100

        // Power: 100% within +/-5% of target, linear to 0 at +/-20%. Ignore the first 10 s of each segment.
        var powerPts = 0.0
        var powerN = 0.0
        var inTarget = 0.0
        for (i, s) in samples.enumerated() {
            guard let t = s.target, t > 0, offs[i] >= 10 else { continue }
            let dev = abs(sm[i] - Double(t)) / Double(t)
            let pts = max(0.0, 1.0 - max(0.0, dev - 0.05) / 0.15)
            let weight = s.kind.isWork ? 2.0 : 1.0
            powerPts += pts * weight
            powerN += weight
            if dev <= 0.05 { inTarget += weight }
        }
        let power = powerN > 0 ? powerPts / powerN * 100 : 0
        let timeIn = powerN > 0 ? inTarget / powerN * 100 : 0

        // Cadence: share of time inside the target band (5 rpm grace) in segments that define one.
        var cadN = 0.0, cadOK = 0.0, cadAvail = 0.0
        for (i, s) in samples.enumerated() {
            guard let range = s.kind.cadenceRange, offs[i] >= 10 else { continue }
            cadN += 1
            if let c = s.cad {
                cadAvail += 1
                if Double(c) >= range.lowerBound - 5 && Double(c) <= range.upperBound + 5 { cadOK += 1 }
            }
        }
        let cadence: Double? = (cadN > 0 && cadAvail / cadN > 0.5) ? cadOK / cadAvail * 100 : nil

        // Heart rate: share of time in the expected band (after a 90 s lag into the interval).
        var hrN = 0.0, hrPts = 0.0
        for (i, s) in samples.enumerated() {
            guard let range = s.kind.hrRange, let hr = s.hr, offs[i] >= 90 else { continue }
            let f = Double(hr) / Double(max(100, maxHR))
            hrN += 1
            if range.contains(f) {
                hrPts += 1
            } else {
                let miss = f < range.lowerBound ? range.lowerBound - f : f - range.upperBound
                hrPts += max(0, 1.0 - miss / 0.10)
            }
        }
        let hrScore: Double? = hrN >= 60 ? hrPts / hrN * 100 : nil

        var parts: [(Double, Double)] = [(completion, 0.35), (power, 0.35)]
        if let c = cadence { parts.append((c, 0.15)) }
        if let h = hrScore { parts.append((h, 0.15)) }
        let wsum = parts.reduce(0.0) { $0 + $1.1 }
        let total100 = parts.reduce(0.0) { $0 + $1.0 * $1.1 } / wsum

        return ScoreBreakdown(total: total100, completion: completion, power: power, cadence: cadence,
                              heartRate: hrScore, timeInTarget: timeIn)
    }
}

// MARK: - Feedback

enum FeedbackEngine {

    static func tier(_ s: Double) -> String {
        switch s {
        case 90...: return "Excellent"
        case 80..<90: return "Strong"
        case 70..<80: return "Solid"
        case 55..<70: return "Partial"
        default: return "Tough day"
        }
    }

    static func feedback(summary r: RideSummary, workout: Workout, maxHR: Int, previousFTP: Double?) -> [String] {
        var out: [String] = []

        if let ftp = r.ftpResult {
            if let old = previousFTP, old > 0 {
                let diff = ftp - old
                let pct = diff / old * 100
                if diff > 2 {
                    out.append("New FTP: \(Int(ftp)) W, up \(Int(diff)) W (\(String(format: "%.1f", pct))%) from \(Int(old)) W. Real progress. Your zones and every workout in the plan will now scale to it.")
                } else if diff < -2 {
                    out.append("New FTP: \(Int(ftp)) W, down \(Int(-diff)) W from \(Int(old)) W. That's okay. Fatigue, missed sessions, sleep and stress all show up in tests. Training at the right number matters more than the number itself.")
                } else {
                    out.append("New FTP: \(Int(ftp)) W, essentially unchanged from \(Int(old)) W. Consistency is working; the next block should move it.")
                }
            } else {
                out.append("Your FTP is \(Int(ftp)) W. All workouts and power zones are now based on this number.")
            }
            out.append("Retest every 4-6 weeks so your zones keep matching your fitness.")
            return out
        }

        if workout.kind.isTest {
            out.append("The test ended before I could calculate a reliable FTP. Make sure you can ride the full ramp or the full 20 minutes, then try again when rested.")
            return out
        }

        guard let sc = r.score else { return out }

        out.append("\(tier(sc.total)) session. Score \(Int(sc.total.rounded())) / 100.")

        if sc.completion < 90 {
            out.append("You completed about \(Int(sc.completion))% of the planned work. If you stopped because it was too hard, that's useful data. Two or three of these in a row means the plan or FTP needs easing.")
        }

        // Power vs target in work segments
        let work = r.samples.filter { $0.kind.isWork && $0.target != nil }
        if work.count > 60 {
            let act = work.map { Double($0.power) }.reduce(0, +) / Double(work.count)
            let tgt = work.map { Double($0.target ?? 0) }.reduce(0, +) / Double(work.count)
            if tgt > 0 {
                let ratio = act / tgt
                if ratio < 0.95 {
                    out.append("Average work power was \(Int(act)) W against a \(Int(tgt)) W target (\(Int(ratio * 100))%). You rode under target. Check fuelling beforehand and whether you started the session tired.")
                } else if ratio > 1.05 {
                    out.append("Average work power was \(Int(act)) W against a \(Int(tgt)) W target. Riding over target burns matches you'll want later in the interval. Stay on target.")
                }
            }
        }

        // Fade: first vs last work segment
        let workSegs = Array(Set(work.map { $0.seg })).sorted()
        if workSegs.count >= 3, let f = workSegs.first, let l = workSegs.last {
            let a = work.filter { $0.seg == f }.map { Double($0.power) }
            let b = work.filter { $0.seg == l }.map { Double($0.power) }
            let fa = Metrics.mean(a), lb = Metrics.mean(b)
            if fa > 0 && lb < fa * 0.93 {
                out.append("Power faded from \(Int(fa)) W in your first interval to \(Int(lb)) W in your last. Fade usually points to fatigue, fuelling or starting a touch too hard.")
            }
        }

        if let c = sc.cadence {
            if c >= 85 {
                out.append("Cadence was inside the target band \(Int(c))% of the time. Smooth pedalling.")
            } else {
                let cads = work.compactMap { $0.cad }
                let avg = cads.isEmpty ? 0 : cads.reduce(0, +) / cads.count
                out.append("Cadence was in range only \(Int(c))% of the time (work average \(avg) rpm). Aim for roughly 85-100 rpm on most intervals; lower cadence loads the muscles harder and tires them sooner.")
            }
        }

        if let h = sc.heartRate {
            if h >= 80 {
                out.append("Heart rate stayed in the expected zone for this workout. Your body responded as it should.")
            } else {
                let ws = r.samples.filter { $0.kind.hrRange != nil && $0.hr != nil }
                let kind = ws.first?.kind ?? .endurance
                if let range = kind.hrRange, !ws.isEmpty {
                    let avgHR = Double(ws.compactMap { $0.hr }.reduce(0, +)) / Double(ws.count)
                    let f = avgHR / Double(max(100, maxHR))
                    if f > range.upperBound {
                        out.append("Heart rate ran higher than expected (avg \(Int(avgHR)) bpm). Common causes: heat or poor fan cooling, dehydration, fatigue, caffeine, or an FTP set too high.")
                    } else if f < range.lowerBound {
                        out.append("Heart rate ran lower than expected (avg \(Int(avgHR)) bpm). That can mean you're fresh and strong, or that your max HR setting is too high. Check it in Settings.")
                    }
                }
            }
            if let drift = decoupling(r.samples), r.durationSeconds >= 40 * 60 {
                if drift > 5 {
                    out.append("Cardiac drift was \(String(format: "%.1f", drift))% (power-to-HR efficiency fell in the second half). Over 5% suggests fatigue, dehydration or limited aerobic base. Fuel and drink earlier next time.")
                } else {
                    out.append("Cardiac drift was only \(String(format: "%.1f", max(0, drift)))%, a sign of good aerobic durability.")
                }
            }
        }
        return out
    }

    /// Percent decline in power:HR efficiency between halves of the non-warm-up ride.
    static func decoupling(_ samples: [Sample]) -> Double? {
        let s = samples.filter { $0.hr != nil && $0.kind != .warmup && $0.kind != .cooldown && $0.kind != .recovery }
        guard s.count >= 20 * 60 else { return nil }
        let half = s.count / 2
        func ef(_ a: ArraySlice<Sample>) -> Double {
            let p = a.map { Double($0.power) }.reduce(0, +) / Double(a.count)
            let h = Double(a.compactMap { $0.hr }.reduce(0, +)) / Double(a.count)
            return h > 0 ? p / h : 0
        }
        let e1 = ef(s[0..<half])
        let e2 = ef(s[half...])
        guard e1 > 0 else { return nil }
        return (e1 - e2) / e1 * 100
    }
}
