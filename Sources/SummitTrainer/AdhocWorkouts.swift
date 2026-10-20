import Foundation

/// Ad-hoc workouts that sit outside the training plan. All power targets are fractions of the rider's FTP;
/// the Workouts screen lets the rider scale the whole session up or down before starting.
struct AdhocWorkout: Identifiable {
    enum Category: String, CaseIterable {
        case easy = "Easy & Recovery"
        case endurance = "Endurance & Tempo"
        case drills = "Drills"
        case hard = "Hard Efforts"
    }

    struct Option: Identifiable {
        let label: String
        let value: Int
        var id: Int { value }
    }

    let id: String
    let name: String
    let category: Category
    let icon: String
    let blurb: String
    let optionTitle: String
    let options: [Option]
    let defaultValue: Int
    let build: (_ ftp: Double, _ value: Int) -> Workout
}

enum AdhocLibrary {
    private static func make(_ name: String, _ note: String, _ ftp: Double, _ segs: [Segment]) -> Workout {
        var w = Workout(name: name, kind: .adhoc, ftp: ftp, segments: segs)
        w.note = note
        return w
    }

    private static func minutes(_ values: [Int]) -> [AdhocWorkout.Option] {
        values.map { AdhocWorkout.Option(label: "\($0) min", value: $0) }
    }

    private static func levels(_ items: [(String, Int)]) -> [AdhocWorkout.Option] {
        items.map { AdhocWorkout.Option(label: $0.0, value: $0.1) }
    }

    /// Reuse a plan workout builder as an ad-hoc session.
    private static func wrap(_ kind: WorkoutKind, level: Int, ftp: Double, note: String) -> Workout {
        let w = WorkoutLibrary.make(kind, level: level, ftp: ftp)
        return make(w.name, note, ftp, w.segments)
    }

    static let all: [AdhocWorkout] = [
        // MARK: Easy & Recovery
        AdhocWorkout(
            id: "freeride", name: "Just Ride", category: .easy, icon: "bicycle",
            blurb: "Free ride with no targets. The trainer simulates a flat road and you choose the effort.",
            optionTitle: "Duration", options: minutes([15, 20, 30, 45, 60, 90, 120]), defaultValue: 30,
            build: { ftp, m in
                make("Just Ride \(m)", "Free ride: no ERG targets. Ride at whatever effort you like.", ftp,
                     [Segment(label: "Free ride", seconds: m * 60, startPct: 0, kind: .endurance, erg: false)])
            }),
        AdhocWorkout(
            id: "easyspin", name: "Easy Spin", category: .easy, icon: "leaf",
            blurb: "Gentle ERG spin at about half your FTP. Flushes the legs the day after hard work.",
            optionTitle: "Duration", options: minutes([20, 30, 45, 60]), defaultValue: 30,
            build: { ftp, m in
                make("Easy Spin \(m)", "Very easy and steady. Keep the cadence light and the shoulders loose.", ftp, [
                    Segment(label: "Warm-up", seconds: 180, startPct: 0.40, endPct: 0.50, kind: .warmup),
                    Segment(label: "Easy spin", seconds: (m - 6) * 60, startPct: 0.50, kind: .recovery),
                    Segment(label: "Cool-down", seconds: 180, startPct: 0.50, endPct: 0.40, kind: .cooldown)])
            }),

        // MARK: Endurance & Tempo
        AdhocWorkout(
            id: "endurance", name: "Endurance Ride", category: .endurance, icon: "figure.outdoor.cycle",
            blurb: "Steady aerobic riding at about 65% of FTP. Builds the base under everything else.",
            optionTitle: "Duration", options: minutes([30, 45, 60, 90, 120]), defaultValue: 60,
            build: { ftp, m in
                make("Endurance \(m)", "Conversational pace. You should be able to chat the whole way.", ftp, [
                    Segment(label: "Warm-up", seconds: 300, startPct: 0.45, endPct: 0.65, kind: .warmup),
                    Segment(label: "Endurance", seconds: (m - 10) * 60, startPct: 0.65, kind: .endurance),
                    Segment(label: "Cool-down", seconds: 300, startPct: 0.60, endPct: 0.45, kind: .cooldown)])
            }),
        AdhocWorkout(
            id: "surges", name: "Endurance + Surges", category: .endurance, icon: "waveform.path.ecg",
            blurb: "Endurance riding with a 30-second surge every 5 minutes to keep it interesting.",
            optionTitle: "Duration", options: minutes([45, 60, 90]), defaultValue: 60,
            build: { ftp, m in
                var segs = [Segment(label: "Warm-up", seconds: 300, startPct: 0.45, endPct: 0.65, kind: .warmup)]
                var remaining = (m - 10) * 60
                while remaining >= 270 {
                    segs.append(Segment(label: "Endurance", seconds: 240, startPct: 0.65, kind: .endurance))
                    segs.append(Segment(label: "Surge", seconds: 30, startPct: 0.88, kind: .tempo))
                    remaining -= 270
                }
                if remaining > 0 { segs.append(Segment(label: "Endurance", seconds: remaining, startPct: 0.65, kind: .endurance)) }
                segs.append(Segment(label: "Cool-down", seconds: 300, startPct: 0.60, endPct: 0.45, kind: .cooldown))
                return make("Endurance + Surges \(m)", "Steady endurance with short tempo surges. Settle back down after each one.", ftp, segs)
            }),
        AdhocWorkout(
            id: "tempo", name: "Tempo Ride", category: .endurance, icon: "speedometer",
            blurb: "One continuous block at 80% of FTP. Builds aerobic strength and muscular endurance.",
            optionTitle: "Tempo block", options: minutes([20, 30, 40, 60]), defaultValue: 30,
            build: { ftp, m in
                make("Tempo \(m)", "Steady, controlled and a little uncomfortable. Hold the target.", ftp, [
                    Segment(label: "Warm-up", seconds: 600, startPct: 0.45, endPct: 0.70, kind: .warmup),
                    Segment(label: "Tempo", seconds: m * 60, startPct: 0.80, kind: .tempo),
                    Segment(label: "Cool-down", seconds: 300, startPct: 0.60, endPct: 0.40, kind: .cooldown)])
            }),

        // MARK: Drills
        AdhocWorkout(
            id: "spinups", name: "Spin-Ups", category: .drills, icon: "arrow.up.right.circle",
            blurb: "Six one-minute bursts of high cadence (110+ rpm) with easy spinning between. Smooths your pedal stroke.",
            optionTitle: "Style", options: levels([("Standard", 6)]), defaultValue: 6,
            build: { ftp, reps in
                var segs = WorkoutLibrary.warm(8)
                for i in 1...reps {
                    segs.append(Segment(label: "Spin up fast, 110 plus rpm", seconds: 60, startPct: 0.60, kind: .drill, group: i, groupTotal: reps))
                    if i < reps { segs.append(Segment(label: "Easy spin", seconds: 120, startPct: 0.50, kind: .recovery)) }
                }
                segs += WorkoutLibrary.cool(5)
                return make("Spin-Ups \(reps)×1", "Ramp the cadence up over the first 20 seconds and hold it smooth with no bouncing.", ftp, segs)
            }),
        AdhocWorkout(
            id: "ladder", name: "Cadence Ladder", category: .drills, icon: "chart.bar.xaxis",
            blurb: "Spin up then spin down: climb from 90 to 120 rpm in 10 rpm steps, then step back down to 70.",
            optionTitle: "Rounds", options: levels([("1 round", 1), ("2 rounds", 2)]), defaultValue: 1,
            build: { ftp, rounds in
                var segs = WorkoutLibrary.warm(8)
                let cadences = [90, 100, 110, 120, 110, 100, 90, 80, 70]
                for r in 1...rounds {
                    for c in cadences {
                        segs.append(Segment(label: "Cadence \(c) rpm", seconds: 60, startPct: 0.60, kind: .drill))
                    }
                    if r < rounds { segs.append(Segment(label: "Easy spin", seconds: 180, startPct: 0.50, kind: .recovery)) }
                }
                segs += WorkoutLibrary.cool(5)
                return make("Cadence Ladder ×\(rounds)", "Match each cadence for the full minute. Stay smooth, and stay light at the top.", ftp, segs)
            }),
        AdhocWorkout(
            id: "onelegged", name: "One-Leg Drills", category: .drills, icon: "figure.walk",
            blurb: "Alternate 30 seconds on each leg at low power. Fixes dead spots in your pedal stroke.",
            optionTitle: "Sets", options: levels([("3 sets", 3), ("4 sets", 4), ("5 sets", 5)]), defaultValue: 4,
            build: { ftp, sets in
                var segs = WorkoutLibrary.warm(10)
                for s in 1...sets {
                    for _ in 1...2 {
                        segs.append(Segment(label: "Right leg only", seconds: 30, startPct: 0.45, kind: .drill, group: s, groupTotal: sets))
                        segs.append(Segment(label: "Left leg only", seconds: 30, startPct: 0.45, kind: .drill, group: s, groupTotal: sets))
                    }
                    segs.append(Segment(label: "Both legs, easy spin", seconds: 90, startPct: 0.50, kind: .recovery))
                }
                segs += WorkoutLibrary.cool(5)
                return make("One-Leg Drills \(sets) sets", "Unclip the idle foot and rest it on a stool or the frame. Think about pulling through the top and bottom of the stroke.", ftp, segs)
            }),
        AdhocWorkout(
            id: "lowcadence", name: "Low-Cadence Strength", category: .drills, icon: "gearshape.2",
            blurb: "Five 3-minute efforts at 60-70 rpm at 75% of FTP. Builds pedalling strength without a lot of fatigue.",
            optionTitle: "Style", options: levels([("Standard", 5)]), defaultValue: 5,
            build: { ftp, reps in
                var segs = WorkoutLibrary.warm(10)
                for i in 1...reps {
                    segs.append(Segment(label: "Low cadence, 60 to 70 rpm", seconds: 180, startPct: 0.75, kind: .drill, group: i, groupTotal: reps))
                    if i < reps { segs.append(Segment(label: "Easy spin", seconds: 120, startPct: 0.50, kind: .recovery)) }
                }
                segs += WorkoutLibrary.cool(5)
                return make("Low-Cadence Strength \(reps)×3", "Push the big gear smoothly. Keep your upper body quiet and your knees tracking straight.", ftp, segs)
            }),

        // MARK: Hard Efforts
        AdhocWorkout(
            id: "pyramid", name: "Threshold Pyramid", category: .hard, icon: "triangle",
            blurb: "Efforts at FTP that climb in length and come back down, with 2 minutes of recovery between.",
            optionTitle: "Peak", options: levels([("1-2-3-2-1", 3), ("1-2-3-4-3-2-1", 4)]), defaultValue: 3,
            build: { ftp, peak in
                let steps = Array(1...peak) + Array((1..<peak).reversed())
                var segs = WorkoutLibrary.warm(12)
                for (i, m) in steps.enumerated() {
                    segs.append(Segment(label: "Pyramid \(m) min", seconds: m * 60, startPct: 1.0, kind: .threshold,
                                        group: i + 1, groupTotal: steps.count))
                    if i < steps.count - 1 { segs.append(Segment(label: "Recover", seconds: 120, startPct: 0.50, kind: .recovery)) }
                }
                segs += WorkoutLibrary.cool(5)
                return make("Threshold Pyramid", "Hold FTP through every step. Use the recoveries to breathe down and reset.", ftp, segs)
            }),
        AdhocWorkout(
            id: "sweetspot", name: "Sweet Spot", category: .hard, icon: "flame",
            blurb: "Long intervals at 90% of FTP. The most time-efficient way to build sustainable power.",
            optionTitle: "Size", options: levels([("Easier", 2), ("Standard", 4), ("Harder", 7)]), defaultValue: 4,
            build: { ftp, lvl in wrap(.sweetSpot, level: lvl, ftp: ftp, note: "Just below threshold: hard but controlled. Stay seated and smooth.") }),
        AdhocWorkout(
            id: "threshold", name: "Threshold", category: .hard, icon: "bolt",
            blurb: "Intervals right at FTP. Directly raises the power you can sustain.",
            optionTitle: "Size", options: levels([("Easier", 2), ("Standard", 4), ("Harder", 6)]), defaultValue: 4,
            build: { ftp, lvl in wrap(.threshold, level: lvl, ftp: ftp, note: "On the edge of sustainable. Settle in early and hold steady.") }),
        AdhocWorkout(
            id: "overunders", name: "Over-Unders", category: .hard, icon: "arrow.up.arrow.down",
            blurb: "Two-minute steps either side of FTP (95-105%) that train you to clear lactate while riding hard.",
            optionTitle: "Size", options: levels([("Easier", 1), ("Standard", 3), ("Harder", 6)]), defaultValue: 3,
            build: { ftp, lvl in wrap(.overUnder, level: lvl, ftp: ftp, note: "Stay composed through the changes of pace. Don't chase the numbers.") }),
        AdhocWorkout(
            id: "vo2", name: "VO2 Max Intervals", category: .hard, icon: "heart.fill",
            blurb: "Three to six-minute efforts just above FTP that grow your aerobic ceiling.",
            optionTitle: "Size", options: levels([("Easier", 1), ("Standard", 3), ("Harder", 5)]), defaultValue: 3,
            build: { ftp, lvl in wrap(.vo2, level: lvl, ftp: ftp, note: "Hard and breathless. Start controlled so you can finish the last one.") }),
        AdhocWorkout(
            id: "vo2onoff", name: "30/30 On-Offs", category: .hard, icon: "timer",
            blurb: "Thirty seconds hard, thirty seconds easy, in sets. Big aerobic gains for little time.",
            optionTitle: "Size", options: levels([("Easier", 1), ("Harder", 4)]), defaultValue: 1,
            build: { ftp, lvl in wrap(.vo2OnOff, level: lvl, ftp: ftp, note: "Go hard on the 'on' half and truly rest on the 'off' half.") }),
    ]
}
