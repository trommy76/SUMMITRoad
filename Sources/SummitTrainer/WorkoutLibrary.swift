import Foundation

/// Builds structured workouts. Levels 1-8 progress in difficulty (based on the
/// Base -> Build -> Specialty approach in TrainerRoad's "How to Increase FTP" guide).
enum WorkoutLibrary {

    // MARK: Building blocks

    static func warm(_ minutes: Int = 10) -> [Segment] {
        [Segment(label: "Warm-up", seconds: minutes * 60, startPct: 0.45, endPct: 0.70, kind: .warmup)]
    }

    static func cool(_ minutes: Int = 5) -> [Segment] {
        [Segment(label: "Cool-down", seconds: minutes * 60, startPct: 0.60, endPct: 0.40, kind: .cooldown)]
    }

    static func intervals(count: Int, workSec: Int, workPct: Double, restSec: Int, restPct: Double,
                          kind: SegmentKind, label: String) -> [Segment] {
        var out: [Segment] = []
        for i in 1...count {
            out.append(Segment(label: "\(label) \(i)/\(count)", seconds: workSec, startPct: workPct,
                               kind: kind, group: i, groupTotal: count))
            if i < count && restSec > 0 {
                out.append(Segment(label: "Recover", seconds: restSec, startPct: restPct, kind: .recovery))
            }
        }
        return out
    }

    private static func lv(_ level: Int) -> Int { max(1, min(8, level)) }

    // MARK: Level tables

    private static let sweetSpotTable: [(Int, Int)] = [(2, 10), (2, 12), (2, 15), (3, 12), (2, 20), (3, 15), (3, 18), (3, 20)]
    private static let thresholdTable: [(Int, Int)] = [(2, 8), (2, 10), (3, 8), (2, 12), (3, 10), (2, 15), (3, 12), (3, 15)]
    private static let tempoTable: [(Int, Int)] = [(1, 30), (1, 40), (2, 20), (1, 50), (2, 25), (1, 60), (2, 30), (1, 75)]
    // count, workSec, workPct, restSec
    private static let vo2Table: [(Int, Int, Double, Int)] = [
        (5, 180, 1.05, 180), (6, 180, 1.06, 180), (7, 180, 1.06, 240), (5, 240, 1.06, 240),
        (6, 240, 1.06, 240), (5, 300, 1.05, 300), (6, 300, 1.05, 300), (5, 360, 1.05, 300)
    ]
    private static let overUnderCounts: [Int] = [2, 2, 3, 3, 3, 4, 4, 4]

    // MARK: Public factory

    static func make(_ kind: WorkoutKind, level: Int, ftp: Double, minutes: Int = 60) -> Workout {
        let l = lv(level)
        switch kind {
        case .sweetSpot:
            let (n, m) = sweetSpotTable[l - 1]
            let segs = warm(10) + intervals(count: n, workSec: m * 60, workPct: 0.90, restSec: 300, restPct: 0.55,
                                            kind: .sweetSpot, label: "Sweet Spot") + cool(5)
            return Workout(name: "Sweet Spot \(n)×\(m)", kind: kind, ftp: ftp, segments: segs)

        case .threshold:
            let (n, m) = thresholdTable[l - 1]
            let pct = l <= 2 ? 0.98 : 1.0
            let segs = warm(12) + intervals(count: n, workSec: m * 60, workPct: pct, restSec: 300, restPct: 0.55,
                                            kind: .threshold, label: "Threshold") + cool(5)
            return Workout(name: "Threshold \(n)×\(m)", kind: kind, ftp: ftp, segments: segs)

        case .tempo:
            let (n, m) = tempoTable[l - 1]
            let segs = warm(10) + intervals(count: n, workSec: m * 60, workPct: 0.80, restSec: 300, restPct: 0.55,
                                            kind: .tempo, label: "Tempo") + cool(5)
            return Workout(name: "Tempo \(n)×\(m)", kind: kind, ftp: ftp, segments: segs)

        case .vo2:
            let (n, w, p, r) = vo2Table[l - 1]
            let segs = warm(12) + intervals(count: n, workSec: w, workPct: p, restSec: r, restPct: 0.50,
                                            kind: .vo2, label: "VO2 Max") + cool(5)
            return Workout(name: "VO2 Max \(n)×\(w / 60)", kind: kind, ftp: ftp, segments: segs)

        case .vo2OnOff:
            let sets = l <= 3 ? 2 : 3
            var segs = warm(12)
            for s in 1...sets {
                for _ in 1...8 {
                    segs.append(Segment(label: "30s ON · Set \(s)/\(sets)", seconds: 30, startPct: 1.25,
                                        kind: .vo2, group: s, groupTotal: sets))
                    segs.append(Segment(label: "30s OFF · Set \(s)/\(sets)", seconds: 30, startPct: 0.50,
                                        kind: .recovery, group: s, groupTotal: sets))
                }
                if s < sets {
                    segs.append(Segment(label: "Set recovery", seconds: 300, startPct: 0.55, kind: .recovery))
                }
            }
            segs += cool(5)
            return Workout(name: "VO2 On-Offs \(sets) sets", kind: kind, ftp: ftp, segments: segs)

        case .overUnder:
            let n = overUnderCounts[l - 1]
            let steps: [Double] = [0.95, 1.00, 1.05, 1.00, 0.95]
            var segs = warm(12)
            for i in 1...n {
                for p in steps {
                    segs.append(Segment(label: "Over-Under \(i)/\(n) · \(Int((p * 100).rounded()))%", seconds: 120,
                                        startPct: p, kind: .threshold, group: i, groupTotal: n))
                }
                if i < n { segs.append(Segment(label: "Recover", seconds: 300, startPct: 0.55, kind: .recovery)) }
            }
            segs += cool(5)
            return Workout(name: "Over-Unders \(n)×10", kind: kind, ftp: ftp, segments: segs)

        case .endurance:
            let m = max(30, minutes)
            var segs: [Segment] = []
            segs.append(Segment(label: "Warm-up", seconds: 300, startPct: 0.45, endPct: 0.65, kind: .warmup))
            segs.append(Segment(label: "Endurance", seconds: (m - 10) * 60, startPct: 0.65, kind: .endurance))
            segs.append(Segment(label: "Cool-down", seconds: 300, startPct: 0.60, endPct: 0.45, kind: .cooldown))
            return Workout(name: "Endurance \(m)", kind: kind, ftp: ftp, segments: segs)

        case .ftpRamp:
            return rampTest(estimatedFTP: ftp)

        case .ftp20:
            return twentyMinuteTest(estimatedFTP: ftp)
        }
    }

    // MARK: FTP tests

    /// Ramp test: 1-minute steps, FTP = 75% of best 1-minute power.
    static func rampTest(estimatedFTP est: Double) -> Workout {
        let start = max(50.0, (est * 0.40 / 5).rounded() * 5)
        let step = max(10.0, (est * 0.065 / 5).rounded() * 5)
        var segs: [Segment] = []
        segs.append(Segment(label: "Warm-up", seconds: 300, startPct: (est * 0.45 / 5).rounded() * 5,
                            endPct: start, kind: .warmup, absolute: true))
        for i in 0..<30 {
            let w = start + Double(i) * step
            segs.append(Segment(label: "Step \(i + 1) · \(Int(w)) W", seconds: 60, startPct: w,
                                kind: .test, absolute: true, group: i + 1, groupTotal: 30))
        }
        return Workout(name: "FTP Ramp Test", kind: .ftpRamp, ftp: est, segments: segs)
    }

    /// 20-minute test: FTP = 95% of the 20-minute average.
    static func twentyMinuteTest(estimatedFTP est: Double) -> Workout {
        var segs: [Segment] = []
        segs.append(Segment(label: "Warm-up", seconds: 600, startPct: 0.50, endPct: 0.75, kind: .warmup))
        for i in 1...3 {
            segs.append(Segment(label: "Fast pedal \(i)/3", seconds: 60, startPct: 0.95, kind: .vo2))
            segs.append(Segment(label: "Easy", seconds: 60, startPct: 0.50, kind: .recovery))
        }
        segs.append(Segment(label: "Easy spin", seconds: 180, startPct: 0.50, kind: .recovery))
        segs.append(Segment(label: "5-min opener", seconds: 300, startPct: 1.15, kind: .vo2))
        segs.append(Segment(label: "Recover", seconds: 600, startPct: 0.50, kind: .recovery))
        segs.append(Segment(label: "20-MIN ALL-OUT", seconds: 1200, startPct: 0, kind: .test, erg: false))
        segs.append(Segment(label: "Cool-down", seconds: 600, startPct: 0.55, endPct: 0.40, kind: .cooldown))
        return Workout(name: "FTP 20-Minute Test", kind: .ftp20, ftp: est, segments: segs)
    }
}
