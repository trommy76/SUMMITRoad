import Foundation

/// The six power zones tracked as athlete levels. Each one is judged on the best power you have held for that
/// zone's reference duration, as a fraction of FTP, and mapped onto a 0-10 scale.
enum LevelZone: String, CaseIterable, Identifiable {
    case endurance = "Endurance", tempo = "Tempo", sweetSpot = "Sweet Spot"
    case threshold = "Threshold", vo2 = "VO2Max", anaerobic = "Anaerobic"
    var id: String { rawValue }

    /// Best-effort duration that represents the zone, in seconds.
    var seconds: Int {
        switch self {
        case .endurance: return 90 * 60
        case .tempo: return 45 * 60
        case .sweetSpot: return 30 * 60
        case .threshold: return 20 * 60
        case .vo2: return 5 * 60
        case .anaerobic: return 60
        }
    }

    var durationText: String { seconds >= 120 ? "\(seconds / 60) min" : "\(seconds) s" }

    /// Fraction of FTP that scores level 0 and level 10 for the reference duration.
    var range: (low: Double, high: Double) {
        switch self {
        case .endurance: return (0.40, 0.85)
        case .tempo: return (0.55, 0.95)
        case .sweetSpot: return (0.65, 1.05)
        case .threshold: return (0.70, 1.20)
        case .vo2: return (0.85, 1.45)
        case .anaerobic: return (1.00, 2.20)
        }
    }
}

typealias AthleteLevels = [LevelZone: Double]

enum Levels {
    /// How far back rides count towards your current levels.
    static let windowDays = 90

    /// Best average power over `seconds` consecutive 1 Hz samples, or nil if the ride was shorter.
    static func bestPower(_ power: [Int], seconds: Int) -> Double? {
        guard seconds > 0, power.count >= seconds else { return nil }
        var sum = 0
        for i in 0..<seconds { sum += power[i] }
        var best = sum
        for i in seconds..<power.count {
            sum += power[i] - power[i - seconds]
            best = max(best, sum)
        }
        return Double(best) / Double(seconds)
    }

    static func level(_ zone: LevelZone, watts: Double, ftp: Double) -> Double {
        guard ftp > 0 else { return 0 }
        let r = zone.range
        return min(10, max(0, (watts / ftp - r.low) / (r.high - r.low) * 10))
    }

    /// The level each zone reached in one ride (zones the ride was too short for are left out).
    static func levels(in ride: RideSummary, ftp: Double) -> AthleteLevels {
        let power = ride.samples.map { $0.power }
        var out: AthleteLevels = [:]
        for z in LevelZone.allCases {
            if let w = bestPower(power, seconds: z.seconds) { out[z] = level(z, watts: w, ftp: ftp) }
        }
        return out
    }

    /// Current levels: the best of each zone over the rides in the 90 days up to `date`.
    static func levels(rides: [RideSummary], asOf date: Date = Date(), ftp: Double) -> AthleteLevels {
        let from = date.addingTimeInterval(-Double(windowDays) * 86400)
        var out: AthleteLevels = Dictionary(uniqueKeysWithValues: LevelZone.allCases.map { ($0, 0.0) })
        for r in rides where r.date <= date && r.date >= from {
            for (z, v) in levels(in: r, ftp: ftp) { out[z] = max(out[z] ?? 0, v) }
        }
        return out
    }

    /// Levels just before and just after one ride, so a ride can show what it changed.
    static func change(for ride: RideSummary, in rides: [RideSummary], ftp: Double) -> (before: AthleteLevels, after: AthleteLevels) {
        let earlier = rides.filter { $0.id != ride.id && $0.date < ride.date }
        let before = levels(rides: earlier, asOf: ride.date, ftp: ftp)
        let after = levels(rides: earlier + [ride], asOf: ride.date, ftp: ftp)
        return (before, after)
    }

    /// Best power (W) held for the zone's duration within the window, for display next to the level.
    static func bestWatts(_ zone: LevelZone, rides: [RideSummary], asOf date: Date = Date()) -> Double? {
        let from = date.addingTimeInterval(-Double(windowDays) * 86400)
        return rides.filter { $0.date <= date && $0.date >= from }
            .compactMap { bestPower($0.samples.map { $0.power }, seconds: zone.seconds) }.max()
    }
}
