import Foundation

// MARK: - Segment / workout model

enum SegmentKind: String, Codable {
    case warmup, cooldown, recovery, endurance, tempo, sweetSpot, threshold, vo2, anaerobic, test, drill

    var title: String {
        switch self {
        case .warmup: return "Warm-up"
        case .cooldown: return "Cool-down"
        case .recovery: return "Recovery"
        case .endurance: return "Endurance"
        case .tempo: return "Tempo"
        case .sweetSpot: return "Sweet Spot"
        case .threshold: return "Threshold"
        case .vo2: return "VO2 Max"
        case .anaerobic: return "Anaerobic"
        case .test: return "FTP Test"
        case .drill: return "Drill"
        }
    }

    var isWork: Bool {
        switch self {
        case .tempo, .sweetSpot, .threshold, .vo2, .anaerobic, .test: return true
        default: return false
        }
    }

    /// Expected steady-state heart rate as a fraction of max HR.
    var hrRange: ClosedRange<Double>? {
        switch self {
        case .endurance: return 0.60...0.80
        case .tempo: return 0.72...0.85
        case .sweetSpot: return 0.78...0.90
        case .threshold: return 0.84...0.95
        case .vo2: return 0.88...1.0
        default: return nil
        }
    }

    /// Target cadence band in rpm.
    var cadenceRange: ClosedRange<Double>? {
        switch self {
        case .endurance, .tempo, .sweetSpot: return 80...100
        case .threshold: return 85...100
        case .vo2: return 90...110
        default: return nil
        }
    }
}

enum WorkoutKind: String, Codable, CaseIterable {
    case endurance, tempo, sweetSpot, threshold, overUnder, vo2, vo2OnOff, ftpRamp, ftp20, adhoc

    var title: String {
        switch self {
        case .endurance: return "Endurance"
        case .tempo: return "Tempo"
        case .sweetSpot: return "Sweet Spot"
        case .threshold: return "Threshold"
        case .overUnder: return "Over-Unders"
        case .vo2: return "VO2 Max"
        case .vo2OnOff: return "VO2 Max On-Offs"
        case .ftpRamp: return "Ramp Test"
        case .ftp20: return "20-Minute Test"
        case .adhoc: return "Workout"
        }
    }

    var isTest: Bool { self == .ftpRamp || self == .ftp20 }

    var blurb: String {
        switch self {
        case .endurance: return "Low-stress aerobic work. Improves fat use, oxygen delivery and fatigue resistance."
        case .tempo: return "Steady moderate effort that builds aerobic strength and muscular endurance."
        case .sweetSpot: return "Efficient muscular-endurance work just below threshold. The backbone of Base."
        case .threshold: return "Riding at FTP. Directly raises the power you can sustain."
        case .overUnder: return "Steps around FTP (95-105%) that train you to clear lactate while riding hard."
        case .vo2: return "Longer intervals just above FTP that grow aerobic capacity."
        case .vo2OnOff: return "Short, very hard repeats. Big aerobic gains for little time."
        case .ftpRamp: return "Step-by-step ramp until failure. FTP = 75% of best 1-minute power."
        case .ftp20: return "Warm-up, a hard opener, then a 20-minute all-out effort. FTP = 95% of average."
        case .adhoc: return "An ad-hoc workout scaled to your current FTP."
        }
    }
}

enum Phase: String, Codable {
    case base, build, specialty
    var title: String {
        switch self {
        case .base: return "Base"
        case .build: return "Build"
        case .specialty: return "Specialty"
        }
    }
}

struct Segment: Codable, Identifiable {
    var id = UUID()
    var label: String
    var seconds: Int
    var startPct: Double      // fraction of FTP, or watts when `absolute`
    var endPct: Double
    var kind: SegmentKind
    var absolute: Bool
    var erg: Bool             // false = free ride (no ERG target)
    var group: Int?
    var groupTotal: Int?

    init(label: String, seconds: Int, startPct: Double, endPct: Double? = nil, kind: SegmentKind,
         absolute: Bool = false, erg: Bool = true, group: Int? = nil, groupTotal: Int? = nil) {
        self.label = label
        self.seconds = seconds
        self.startPct = startPct
        self.endPct = endPct ?? startPct
        self.kind = kind
        self.absolute = absolute
        self.erg = erg
        self.group = group
        self.groupTotal = groupTotal
    }

    func startWatts(ftp: Double) -> Double { absolute ? startPct : startPct * ftp }
    func endWatts(ftp: Double) -> Double { absolute ? endPct : endPct * ftp }

    func targetWatts(ftp: Double, at t: Int) -> Double {
        let f = seconds > 0 ? min(1.0, Double(t) / Double(seconds)) : 0
        let a = startWatts(ftp: ftp)
        let b = endWatts(ftp: ftp)
        return a + (b - a) * f
    }
}

struct Workout: Codable, Identifiable {
    var id = UUID()
    var name: String
    var kind: WorkoutKind
    var ftp: Double
    var segments: [Segment]
    var note: String? = nil

    var totalSeconds: Int { segments.reduce(0) { $0 + $1.seconds } }

    var estimatedTSS: Double {
        if kind.isTest { return 0 }
        var total = 0.0
        for s in segments {
            let mid = (s.startPct + s.endPct) / 2
            total += mid * mid * Double(s.seconds)
        }
        return total / 3600.0 * 100.0
    }

    func startSecond(ofSegment index: Int) -> Int {
        var t = 0
        for i in 0..<min(index, segments.count) { t += segments[i].seconds }
        return t
    }

    var workSeconds: Int { segments.filter { $0.kind.isWork }.reduce(0) { $0 + $1.seconds } }
}

// MARK: - Power zones

enum PowerZones {
    static func name(forPercent p: Double) -> String {
        switch p {
        case ..<0.56: return "Recovery"
        case ..<0.76: return "Endurance"
        case ..<0.88: return "Tempo"
        case ..<0.95: return "Sweet Spot"
        case ..<1.06: return "Threshold"
        case ..<1.21: return "VO2 Max"
        default: return "Anaerobic"
        }
    }
}

// MARK: - Recorded data

struct Sample: Codable {
    var t: Int
    var power: Int
    var hr: Int?
    var cad: Int?
    var target: Int?
    var kind: SegmentKind
    var seg: Int
    var speed: Double?        // km/h as reported by the trainer (nil on rides recorded before this was captured)
}

struct ScoreBreakdown: Codable {
    var total: Double
    var completion: Double
    var power: Double
    var cadence: Double?
    var heartRate: Double?
    var timeInTarget: Double
}

struct RideSummary: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var workoutName: String
    var workoutKind: WorkoutKind
    var plannedID: UUID?
    var ftp: Double
    var plannedSeconds: Int
    var durationSeconds: Int
    var avgPower: Double
    var np: Double
    var intensityFactor: Double
    var tss: Double
    var kj: Double
    var avgHR: Int?
    var maxHR: Int?
    var avgCadence: Int?
    var score: ScoreBreakdown?
    var feedback: [String] = []
    var ftpResult: Double?
    var stravaID: Int?
    var samples: [Sample]
}

// MARK: - Profile

struct FTPEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var ftp: Double
    var method: String
}

struct Profile: Codable {
    var ftp: Double?
    var ftpDate: Date?
    var maxHR: Int = 185
    var voiceCues: Bool = false
    var autoUpload: Bool = false
    var ftpHistory: [FTPEntry] = []
    var trainerID: String?
    var hrID: String?
    var stravaClientID: String = ""
    var syncURL: String?
    var syncUser: String?
    var syncUploadOK: Bool?
    var planUpdatedAt: Double?        // epoch seconds of the last local plan change (used to sync the plan)
    var settingsUpdatedAt: Double?    // same, for maxHR / voice cues / auto-upload
}

// MARK: - Metrics

enum Metrics {
    static func normalizedPower(_ p: [Double]) -> Double {
        guard !p.isEmpty else { return 0 }
        guard p.count >= 30 else { return p.reduce(0, +) / Double(p.count) }
        var rolling: [Double] = []
        var sum = p[0..<30].reduce(0, +)
        rolling.append(sum / 30)
        for i in 30..<p.count {
            sum += p[i] - p[i - 30]
            rolling.append(sum / 30)
        }
        var fourth = 0.0
        for r in rolling { fourth += pow(r, 4) }
        return pow(fourth / Double(rolling.count), 0.25)
    }

    static func tss(np: Double, ftp: Double, seconds: Int) -> Double {
        guard ftp > 0 else { return 0 }
        let intensity = np / ftp
        return Double(seconds) * np * intensity / (ftp * 3600.0) * 100.0
    }

    static func bestAverage(_ p: [Double], window: Int) -> Double {
        guard p.count >= window, window > 0 else { return 0 }
        var sum = p[0..<window].reduce(0, +)
        var best = sum
        if p.count > window {
            for i in window..<p.count {
                sum += p[i] - p[i - window]
                best = max(best, sum)
            }
        }
        return best / Double(window)
    }

    static func mean(_ v: [Double]) -> Double {
        v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
    }
}

func formatTime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%02d:%02d", m, sec)
}
