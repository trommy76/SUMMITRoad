import Foundation

// MARK: - Questionnaire (modelled on TrainerRoad's Plan Builder questions)

enum Goal: String, Codable, CaseIterable, Identifiable {
    case raiseFTP, timeTrial, roadRace, century, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .raiseFTP: return "Raise my FTP"
        case .timeTrial: return "Time trial / sustained power"
        case .roadRace: return "Road race / criterium"
        case .century: return "Century / long event"
        case .general: return "General fitness"
        }
    }
}

enum Experience: String, Codable, CaseIterable, Identifiable {
    case new, intermediate, experienced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .new: return "New to structured training"
        case .intermediate: return "1-3 years of structured training"
        case .experienced: return "3+ years of structured training"
        }
    }
    var startLevel: Int {
        switch self {
        case .new: return 1
        case .intermediate: return 2
        case .experienced: return 3
        }
    }
}

enum Progression: String, Codable, CaseIterable, Identifiable {
    case conservative, standard, aggressive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conservative: return "Conservative (balancing a busy life / low sleep)"
        case .standard: return "Standard"
        case .aggressive: return "Aggressive (well rested, recovering well)"
        }
    }
    var levelPerWeek: Double {
        switch self {
        case .conservative: return 0.5
        case .standard: return 0.75
        case .aggressive: return 1.0
        }
    }
}

struct Questionnaire: Codable {
    var goal: Goal = .raiseFTP
    var experience: Experience = .intermediate
    var weeklyHours: Double = 5
    var availableDays: Set<Int> = [2, 4, 6, 7]     // Calendar weekday: 1=Sun ... 7=Sat
    var weeks: Int = 12
    var longestRideMinutes: Int = 120
    var progression: Progression = .standard
    var startDate: Date = Date()
}

// MARK: - Plan

struct PlannedWorkout: Codable, Identifiable {
    var id = UUID()
    var week: Int
    var date: Date
    var kind: WorkoutKind
    var level: Int
    var minutes: Int
    var phase: Phase
    var recoveryWeek: Bool
    var isLong: Bool
    var completedScore: Double?
    var completedDate: Date?
}

struct TrainingPlan: Codable {
    var questionnaire: Questionnaire
    var startFTP: Double
    var workouts: [PlannedWorkout]
    var levelAdjust: Int = 0
    var createdAt = Date()

    var weeks: Int { questionnaire.weeks }

    func isMissed(_ w: PlannedWorkout, now: Date = Date()) -> Bool {
        w.completedDate == nil && w.date < Calendar.current.startOfDay(for: now)
    }

    func next(now: Date = Date()) -> PlannedWorkout? {
        let upcoming = workouts.first { $0.completedDate == nil && !isMissed($0, now: now) }
        return upcoming ?? workouts.first { $0.completedDate == nil }
    }

    func currentWeek(now: Date = Date()) -> Int {
        let start = Calendar.current.startOfDay(for: questionnaire.startDate)
        let days = Calendar.current.dateComponents([.day], from: start, to: now).day ?? 0
        return max(1, min(weeks, days / 7 + 1))
    }

    func workout(for p: PlannedWorkout, ftp: Double) -> Workout {
        if p.kind.isTest { return WorkoutLibrary.make(p.kind, level: 1, ftp: ftp) }
        return WorkoutLibrary.make(p.kind, level: p.level + levelAdjust, ftp: ftp, minutes: p.minutes)
    }

    var completedCount: Int { workouts.filter { $0.completedDate != nil }.count }
}

// MARK: - Plan generation

enum PlanBuilder {

    static func keyKinds(phase: Phase, goal: Goal, week: Int, recovery: Bool) -> [WorkoutKind] {
        let alt = week % 2 == 0
        if recovery { return [.sweetSpot, .tempo, .tempo] }
        switch phase {
        case .base:
            return [.sweetSpot, alt ? .tempo : .sweetSpot, .tempo]
        case .build:
            switch goal {
            case .raiseFTP, .timeTrial: return [alt ? .overUnder : .threshold, .vo2, .sweetSpot]
            case .roadRace: return [.threshold, alt ? .vo2OnOff : .vo2, .overUnder]
            case .century, .general: return [.sweetSpot, alt ? .threshold : .overUnder, .tempo]
            }
        case .specialty:
            switch goal {
            case .raiseFTP, .timeTrial: return [.threshold, .overUnder, .vo2]
            case .roadRace: return [.vo2OnOff, .threshold, .overUnder]
            case .century, .general: return [.sweetSpot, .threshold, .tempo]
            }
        }
    }

    static func sessionsPerWeek(hours: Double) -> Int {
        if hours <= 4 { return 3 }
        if hours <= 6 { return 4 }
        if hours <= 9 { return 5 }
        return 6
    }

    static func generate(_ q: Questionnaire, ftp: Double) -> TrainingPlan {
        let cal = Calendar.current
        let weeks = q.weeks
        let baseWeeks = Int((Double(weeks) * 0.4).rounded())
        let specWeeks = weeks >= 10 ? 2 : 1
        let start = cal.startOfDay(for: q.startDate)
        var out: [PlannedWorkout] = []
        var trainingIdx = 0
        var lastLevel = q.experience.startLevel

        for w in 1...weeks {
            let recovery = (w % 4 == 0) || w == weeks
            let phase: Phase = w <= baseWeeks ? .base : (w <= weeks - specWeeks ? .build : .specialty)
            var level: Int
            if recovery {
                level = max(1, lastLevel - 2)
            } else {
                trainingIdx += 1
                level = min(8, q.experience.startLevel + Int(Double(trainingIdx - 1) * q.progression.levelPerWeek))
                lastLevel = level
            }

            // Candidate days this week
            var days: [Date] = []
            for d in 0..<7 {
                if let date = cal.date(byAdding: .day, value: 7 * (w - 1) + d, to: start),
                   q.availableDays.contains(cal.component(.weekday, from: date)) {
                    days.append(date)
                }
            }
            if days.isEmpty { continue }

            var n = min(sessionsPerWeek(hours: q.weeklyHours), days.count)
            if recovery { n = max(1, n - 1) }
            n = max(1, min(n, days.count))

            // Spread chosen days evenly through the available ones
            var picked: [Date] = []
            if n == days.count {
                picked = days
            } else if n == 1 {
                picked = [days[days.count - 1]]
            } else {
                for i in 0..<n {
                    let idx = Int((Double(i) * Double(days.count - 1) / Double(n - 1)).rounded())
                    picked.append(days[idx])
                }
            }

            var kinds = [WorkoutKind](repeating: .endurance, count: n)
            var long = [Bool](repeating: false, count: n)
            var longIdx = n - 1
            if let i = picked.lastIndex(where: { d in
                let wd = cal.component(.weekday, from: d)
                return wd == 7 || wd == 1
            }) { longIdx = i }
            if n >= 2 { long[longIdx] = true }

            var keyCount = n >= 5 ? 3 : 2
            if recovery { keyCount = 1 }
            keyCount = min(keyCount, n >= 2 ? n - 1 : 1)
            let keys = keyKinds(phase: phase, goal: q.goal, week: w, recovery: recovery)
            var k = 0
            for i in 0..<n where i != longIdx || n == 1 {
                if k >= keyCount { break }
                if i > 0 && kinds[i - 1] != .endurance { continue }
                kinds[i] = keys[k]
                k += 1
            }
            if k < keyCount {
                for i in 0..<n where (i != longIdx || n == 1) && kinds[i] == .endurance && k < keyCount {
                    kinds[i] = keys[k]
                    k += 1
                }
            }

            // Retests: start of each new block and the final week (article: assess every 4-6 weeks)
            var testSlot: Int? = nil
            if w > 1 && w % 4 == 1 && w <= weeks - 2 { testSlot = 0 }
            if w == weeks && n >= 2 { testSlot = (min(1, n - 1) == longIdx) ? 0 : min(1, n - 1) }
            if let t = testSlot { kinds[t] = .ftpRamp; long[t] = false }

            // Key workout levels
            func levelFor(_ keyIndex: Int) -> Int { keyIndex >= 2 ? max(1, level - 1) : level }
            var keySeen = 0
            var keyMinutes = 0
            var levels = [Int](repeating: level, count: n)
            for i in 0..<n where kinds[i] != .endurance && !kinds[i].isTest {
                levels[i] = levelFor(keySeen)
                keySeen += 1
                keyMinutes += WorkoutLibrary.make(kinds[i], level: levels[i], ftp: ftp).totalSeconds / 60
            }
            let testCount = kinds.filter { $0.isTest }.count
            keyMinutes += testCount * 60

            // Endurance minutes to fill the weekly hours target
            var target = q.weeklyHours * 60.0
            if recovery { target *= 0.6 }
            let enduranceSlots = (0..<n).filter { kinds[$0] == .endurance }
            var minutesFor = [Int](repeating: 60, count: n)
            if !enduranceSlots.isEmpty {
                let remaining = max(Double(60 * enduranceSlots.count), target - Double(keyMinutes))
                let hasLong = enduranceSlots.contains(longIdx) && n >= 2
                if hasLong {
                    let others = enduranceSlots.count - 1
                    var longMin = others == 0 ? remaining : remaining * 0.45
                    longMin = min(Double(q.longestRideMinutes), max(60, longMin))
                    minutesFor[longIdx] = Int((longMin / 5).rounded()) * 5
                    if others > 0 {
                        var each = (remaining - longMin) / Double(others)
                        each = min(90, max(45, each))
                        for s in enduranceSlots where s != longIdx { minutesFor[s] = Int((each / 5).rounded()) * 5 }
                    }
                } else {
                    var each = remaining / Double(enduranceSlots.count)
                    each = min(Double(q.longestRideMinutes), max(45, each))
                    for s in enduranceSlots { minutesFor[s] = Int((each / 5).rounded()) * 5 }
                }
            }

            for i in 0..<n {
                out.append(PlannedWorkout(week: w, date: picked[i], kind: kinds[i], level: levels[i],
                                          minutes: minutesFor[i], phase: phase, recoveryWeek: recovery,
                                          isLong: long[i]))
            }
        }
        return TrainingPlan(questionnaire: q, startFTP: ftp, workouts: out)
    }
}

// MARK: - Plan advice

struct Advice {
    var headline: String
    var detail: String
    var levelDelta: Int
    var retest: Bool
}

enum PlanAdvisor {
    static func assess(plan: TrainingPlan, rides: [RideSummary], now: Date = Date()) -> Advice {
        let planIDs = Set(plan.workouts.map { $0.id })
        let scored = rides
            .filter { r in r.plannedID.map { planIDs.contains($0) } ?? false }
            .compactMap { r in r.score.map { (r.date, $0.total) } }
            .sorted { $0.0 > $1.0 }
        let recent = Array(scored.prefix(3)).map { $0.1 }

        let twoWeeksAgo = now.addingTimeInterval(-14 * 86400)
        let missed = plan.workouts.filter { plan.isMissed($0, now: now) && $0.date > twoWeeksAgo }.count

        var headline = ""
        var detail = ""
        var delta = 0
        var retest = false

        if recent.count < 2 {
            headline = "Plan status: just getting started"
            detail = "Complete a couple more workouts and I'll tell you whether the plan needs adjusting."
        } else {
            let avg = recent.reduce(0, +) / Double(recent.count)
            if avg >= 92 && plan.levelAdjust >= 2 {
                headline = "Plan status: you're outgrowing it"
                detail = "Your last \(recent.count) rides averaged \(Int(avg)). You're nailing everything at the highest adjustment. Consider an early FTP test; your FTP is probably higher than the number we're using."
                retest = true
            } else if avg >= 88 {
                headline = "Plan status: excellent. Increasing difficulty"
                detail = "Your last \(recent.count) rides averaged \(Int(avg)). I've raised upcoming workouts one step so you keep progressing."
                delta = plan.levelAdjust < 2 ? 1 : 0
            } else if avg >= 72 {
                headline = "Plan status: on track"
                detail = "Your last \(recent.count) rides averaged \(Int(avg)). The plan is well matched to you. Keep stacking consistent weeks."
            } else if recent.count >= 2 && recent[0] < 60 && recent[1] < 60 {
                headline = "Plan status: needs a reset"
                detail = "Two hard sessions in a row scored below 60. Your FTP may be set too high, or you may be carrying fatigue. I've eased upcoming workouts. Rest well, then take an FTP test."
                delta = plan.levelAdjust > -2 ? -1 : 0
                retest = true
            } else {
                headline = "Plan status: slightly too hard"
                detail = "Your last \(recent.count) rides averaged \(Int(avg)). I've eased upcoming workouts one step. Check sleep, fuelling and stress; they matter as much as the workouts."
                delta = plan.levelAdjust > -2 ? -1 : 0
            }
        }
        if missed >= 3 {
            detail += " You've missed \(missed) sessions in the last two weeks. Consider rebuilding the plan with fewer training days so it fits your life."
        }
        return Advice(headline: headline, detail: detail, levelDelta: delta, retest: retest)
    }
}
